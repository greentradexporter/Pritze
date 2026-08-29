import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import 'customer_feedback_screen.dart';

class CustomerCompletionReceiptScreen extends StatelessWidget {
  final Booking booking;
  final bool dialogMode;

  const CustomerCompletionReceiptScreen({
    super.key,
    required this.booking,
    this.dialogMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(booking.salonId);
    final content = ListView(
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
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.champagne.withAlpha(110),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'Pay ₹${booking.customerPayableAmount} at the salon counter',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.primaryDark,
                    fontWeight: FontWeight.w800,
                  ),
                ),
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
            if (dialogMode) {
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
    if (dialogMode) return SafeArea(child: Material(child: content));
    return Scaffold(
      appBar: AppBar(title: const Text('Payment summary')),
      body: content,
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
