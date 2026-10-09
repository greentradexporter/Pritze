import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import 'customer_feedback_screen.dart';

typedef UpiPaymentLauncher = Future<bool> Function(Uri uri);

class CustomerCompletionReceiptScreen extends StatefulWidget {
  final Booking booking;
  final bool dialogMode;
  final UpiPaymentLauncher? launchUpi;

  const CustomerCompletionReceiptScreen({
    super.key,
    required this.booking,
    this.dialogMode = false,
    this.launchUpi,
  });

  @override
  State<CustomerCompletionReceiptScreen> createState() =>
      _CustomerCompletionReceiptScreenState();
}

class _CustomerCompletionReceiptScreenState
    extends State<CustomerCompletionReceiptScreen> {
  Future<CompletedBookingUpiPaymentDetails>? _paymentDetails;
  bool _initialized = false;
  bool _handoffOpened = false;
  bool _launching = false;

  Booking get booking => widget.booking;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _loadPaymentDetails();
  }

  void _loadPaymentDetails() {
    final appState = AppStateScope.read(context);
    _paymentDetails = appState.getCompletedBookingUpiPaymentDetails(booking.id);
    appState.hasOpenedUpiPayment(booking.id).then((opened) {
      if (mounted && opened != _handoffOpened) {
        setState(() => _handoffOpened = opened);
      }
    });
  }

  void _retryPaymentDetails() => setState(_loadPaymentDetails);

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(booking.salonId);
    final content = ListView(
      cacheExtent: 2000,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      children: [
        const Icon(Icons.verified_rounded, size: 72, color: AppColors.success),
        const SizedBox(height: 16),
        Text(
          'Service completed',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Thank you for using Pritze.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                salon?.name ?? 'Salon',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(booking.resolvedServiceName()),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Divider(height: 1),
              ),
              if (booking.servicePriceBreakdown.length > 1)
                for (final entry in booking.servicePriceBreakdown.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ReceiptLine(
                      label:
                          booking.serviceNameBreakdown[entry.key] ??
                          appState
                              .getService(booking.salonId, entry.key)
                              ?.name ??
                          'Booked service',
                      amount: entry.value,
                    ),
                  ),
              _ReceiptLine(
                label: 'Service amount',
                amount: booking.servicePrice,
              ),
              const SizedBox(height: 10),
              _ReceiptLine(
                label: booking.hasDiscount
                    ? '${booking.discountCampaignName} discount'
                    : 'Discount',
                amount: -booking.discountAmount,
                color: AppColors.success,
              ),
              if (booking.proinRedeemedAmount > 0) ...[
                const SizedBox(height: 10),
                _ReceiptLine(
                  label: 'Proin used',
                  amount: -booking.proinRedeemedAmount,
                  color: AppColors.success,
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Divider(height: 1),
              ),
              _ReceiptLine(
                label: 'Final price',
                amount: booking.customerPayableAmount,
                emphasized: true,
              ),
              if (booking.cashbackProinAmount > 0) ...[
                const SizedBox(height: 10),
                Text(
                  booking.discountCashbackStatus == 'awarded'
                      ? '+${booking.cashbackProinAmount} Proin cashback earned'
                      : '+${booking.cashbackProinAmount} Proin cashback after service completion',
                  style: const TextStyle(
                    color: AppColors.success,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FutureBuilder<CompletedBookingUpiPaymentDetails>(
                future: _paymentDetails,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const _PaymentCardLoading();
                  }
                  if (snapshot.hasError || !snapshot.hasData) {
                    return _PaymentUnavailableCard(
                      amountInr: booking.customerPayableAmount,
                      retry: _retryPaymentDetails,
                    );
                  }
                  final details = snapshot.data!;
                  if (details.amountInr == 0) {
                    return const _NothingToPayCard();
                  }
                  if (!details.paymentAvailable) {
                    return _PaymentUnavailableCard(
                      amountInr: details.amountInr,
                    );
                  }
                  return _buildDirectPaymentCard(details);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () {
            final route = MaterialPageRoute<void>(
              builder: (_) => CustomerFeedbackScreen(booking: booking),
            );
            if (widget.dialogMode) {
              Navigator.of(context, rootNavigator: true).pushReplacement(route);
            } else {
              Navigator.pushReplacement(context, route);
            }
          },
          icon: const Icon(Icons.star_rounded),
          label: const Text('Continue to feedback'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Maybe later'),
        ),
      ],
    );
    if (widget.dialogMode) return SafeArea(child: Material(child: content));
    return Scaffold(
      appBar: AppBar(title: const Text('Payment summary')),
      body: content,
    );
  }

  Widget _buildDirectPaymentCard(CompletedBookingUpiPaymentDetails details) {
    return Container(
      key: const Key('direct-upi-payment-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFF5E6), Color(0xFFFFFAF3)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                color: AppColors.primary,
              ),
              SizedBox(width: 8),
              Text(
                'Pay salon directly',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            details.salonName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            'Exact amount ₹${details.amountInr}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('pay-via-upi-button'),
              onPressed: _launching ? null : () => _openUpi(details),
              icon: _launching
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_new_rounded),
              label: Text(
                _handoffOpened ? 'Open UPI payment again' : 'Pay via UPI',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (details.qrCodeUrl.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _showQr(details),
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: const Text('View QR'),
                ),
              TextButton.icon(
                onPressed: () => _copyUpiId(details.upiId),
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy UPI ID'),
              ),
            ],
          ),
          if (_handoffOpened) ...[
            const SizedBox(height: 6),
            const Text(
              'Before retrying, check your UPI app for an existing payment attempt.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Payment goes directly to the salon. Pritze does not verify or collect it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _openUpi(CompletedBookingUpiPaymentDetails details) async {
    final uri = Uri.tryParse(details.upiUri);
    if (uri == null || uri.scheme != 'upi') {
      _showUpiUnavailable();
      return;
    }
    setState(() => _launching = true);
    var opened = false;
    try {
      opened = await (widget.launchUpi ?? _launchUpiExternally)(uri);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    setState(() {
      _launching = false;
      if (opened) _handoffOpened = true;
    });
    if (!opened) {
      _showUpiUnavailable();
      return;
    }
    await AppStateScope.read(context).markUpiPaymentOpened(booking.id);
  }

  Future<bool> _launchUpiExternally(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication);
  }

  void _showUpiUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No UPI app found. Please pay at the salon counter.'),
      ),
    );
  }

  Future<void> _copyUpiId(String upiId) async {
    await Clipboard.setData(ClipboardData(text: upiId));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('UPI ID copied.')));
  }

  Future<void> _showQr(CompletedBookingUpiPaymentDetails details) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Pay ${details.salonName}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                '₹${details.amountInr}',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 18),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 320,
                  maxWidth: 320,
                ),
                child: Image.network(
                  details.qrCodeUrl,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const SizedBox(
                          height: 220,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                  errorBuilder: (context, error, stackTrace) => const SizedBox(
                    height: 180,
                    child: Center(
                      child: Text(
                        'QR could not be loaded. Use UPI or copy the UPI ID.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                details.upiId,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _copyUpiId(details.upiId),
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy UPI ID'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaymentCardLoading extends StatelessWidget {
  const _PaymentCardLoading();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('direct-upi-payment-loading'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.champagne.withAlpha(70),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text('Loading salon payment options…'),
        ],
      ),
    );
  }
}

class _PaymentUnavailableCard extends StatelessWidget {
  final int amountInr;
  final VoidCallback? retry;

  const _PaymentUnavailableCard({required this.amountInr, this.retry});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('direct-upi-payment-unavailable'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.champagne.withAlpha(110),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Text(
            'Online payment is unavailable. Please pay ₹$amountInr at the salon counter.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.primaryDark,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (retry != null)
            TextButton(onPressed: retry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _NothingToPayCard extends StatelessWidget {
  const _NothingToPayCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('nothing-to-pay-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.success.withAlpha(24),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Text(
        'Nothing to pay',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.success, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _ReceiptLine extends StatelessWidget {
  final String label;
  final int amount;
  final bool emphasized;
  final Color? color;

  const _ReceiptLine({
    required this.label,
    required this.amount,
    this.emphasized = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final display = amount < 0 ? '-₹${amount.abs()}' : '₹$amount';
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: color ?? AppColors.ink,
              fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        Text(
          display,
          style: TextStyle(
            color: color ?? AppColors.ink,
            fontSize: emphasized ? 22 : 15,
            fontWeight: emphasized ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
