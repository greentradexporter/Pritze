import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../utils/rating_utils.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/auth_login_panel.dart';
import '../referrals/referral_screen.dart';
import 'customer_profile_editor.dart';
import 'my_bookings_screen.dart';

class CustomerProfileScreen extends StatelessWidget {
  const CustomerProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final account = appState.hasActiveCustomerSession
        ? appState.customerAccount
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          CustomerNotificationButton(
            onNotificationOpened: (destination, {bookingId}) {
              if (destination == AppNotificationDestination.bookings) {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
                );
              }
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: const AppBottomNav(selectedIndex: 1),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
        children: [
          if (account == null)
            _LoggedOutProfile(onLogin: () => _showLogin(context))
          else ...[
            _ProfileHero(
              account: account,
              onEdit: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CustomerProfileEditor(account: account),
                ),
              ),
            ),
            const SizedBox(height: 18),
            _PersonalDetails(account: account),
            if (account.stylePhotoUrls.isNotEmpty) ...[
              const SizedBox(height: 18),
              _StyleGallery(photoUrls: account.stylePhotoUrls),
            ],
            const SizedBox(height: 22),
            _SalonRatingsSection(
              account: account,
              ratings: appState.customerSalonRatings,
            ),
            const SizedBox(height: 18),
            _FeedbackSharedSection(feedback: appState.customerSalonFeedback),
            const SizedBox(height: 18),
            const _ProinWalletCard(),
          ],
          const SizedBox(height: 22),
          const SectionHeader(title: 'Account'),
          const SizedBox(height: 10),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('customer-profile-bookings'),
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Bookings'),
                  subtitle: const Text('Upcoming, completed and cancelled'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
                  ),
                ),
                const Divider(height: 1),
                if (account != null) ...[
                  ListTile(
                    key: const ValueKey('customer-profile-referrals'),
                    leading: const Icon(Icons.redeem_outlined),
                    title: const Text('Refer and invite'),
                    subtitle: const Text('Share your customer referral code'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            const ReferralScreen(role: UserRole.customer),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                ],
                ListTile(
                  key: const ValueKey('customer-profile-notifications'),
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Notifications'),
                  subtitle: const Text('Booking and appointment updates'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openCustomerNotifications(
                    context,
                    onNotificationOpened: (destination, {bookingId}) {
                      if (destination == AppNotificationDestination.bookings) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const MyBookingsScreen(),
                          ),
                        );
                      }
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('customer-profile-support'),
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('Support'),
                  subtitle: const Text('Contact Pritze support'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showSupportSheet(context),
                ),
              ],
            ),
          ),
          if (account != null) ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              key: const ValueKey('customer-profile-logout'),
              onPressed: () async {
                final didLogout = await confirmAndLogout(context);
                if (didLogout && context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(
                      builder: (_) => const CustomerProfileScreen(),
                    ),
                    (route) => false,
                  );
                }
              },
              icon: const Icon(Icons.logout),
              label: const Text('Log out'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showLogin(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          4,
          18,
          MediaQuery.viewInsetsOf(sheetContext).bottom + 18,
        ),
        child: SingleChildScrollView(
          child: AuthLoginPanel(
            role: UserRole.customer,
            embedded: true,
            onLoggedIn: () => Navigator.pop(sheetContext),
          ),
        ),
      ),
    );
  }
}

class _ProinWalletCard extends StatefulWidget {
  const _ProinWalletCard();

  @override
  State<_ProinWalletCard> createState() => _ProinWalletCardState();
}

class _ProinWalletCardState extends State<_ProinWalletCard> {
  final _couponController = TextEditingController();
  final _couponFocusNode = FocusNode();
  bool _refreshing = false;
  bool _couponSubmitting = false;
  String _error = '';

  @override
  void dispose() {
    _couponController.dispose();
    _couponFocusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing || !mounted) return;
    setState(() {
      _refreshing = true;
      _error = '';
    });
    try {
      await AppStateScope.read(context).refreshCustomerProinWallet();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = friendlyErrorMessage(
            error,
            fallback: 'We could not load your Proin balance. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _claimCoupon() async {
    if (_couponSubmitting) return;
    final code = _couponController.text.trim();
    if (code.isEmpty) {
      _couponFocusNode.requestFocus();
      return;
    }
    setState(() {
      _couponSubmitting = true;
      _error = '';
    });
    try {
      final result = await AppStateScope.read(context).claimProinCoupon(code);
      if (!mounted) return;
      _couponController.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      final expiresAt = result.expiresAt;
      final expiryText = expiresAt == null
          ? ''
          : ' Valid until ${_proinDate(expiresAt)}.';
      final message = result.alreadyClaimed
          ? 'This coupon was already added to your Proin balance.'
          : '${result.amountProin} Proin added to your balance.$expiryText';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = friendlyErrorMessage(
            error,
            fallback: 'This coupon could not be applied. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _couponSubmitting = false);
    }
  }

  Future<void> _openActivity() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ProinActivitySheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wallet = AppStateScope.watch(context).customerProinWallet;
    final expiry = wallet.nextExpiryAt;
    final expiryLabel = expiry == null
        ? 'No Proin expiring soon'
        : '${expiry.day.toString().padLeft(2, '0')}/'
              '${expiry.month.toString().padLeft(2, '0')}/${expiry.year}';
    return Container(
      key: const ValueKey('customer-proin-wallet'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4E2214), Color(0xFF9A4B24)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2A5A260F),
            blurRadius: 22,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(32),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(Icons.toll_rounded, color: Color(0xFFFFD58D)),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your Proin',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Promotional rewards · 1 Proin = ₹1',
                      style: TextStyle(color: Color(0xFFEFC9B2), fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _refreshing ? null : _refresh,
                tooltip: 'Refresh balance',
                color: Colors.white,
                icon: _refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            '${wallet.availableProin}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 38,
              height: 1,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'available Proin',
            style: TextStyle(color: Color(0xFFFFE7D7)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ProinMetric(
                  label: 'Reserved',
                  value: '${wallet.reservedProin}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ProinMetric(label: 'Next expiry', value: expiryLabel),
              ),
            ],
          ),
          if (wallet.expiringLots.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(22),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withAlpha(28)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Upcoming expiries',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final lot in wallet.expiringLots.take(3))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.schedule_rounded,
                            size: 15,
                            color: Color(0xFFFFD58D),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '${lot.amountProin} Proin · ${_proinSourceLabel(lot.sourceType)}',
                              style: const TextStyle(
                                color: Color(0xFFFFE7D7),
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Text(
                            _proinDate(lot.expiresAt),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (wallet.expiringLots.length > 3)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        '+${wallet.expiringLots.length - 3} more expiry records',
                        style: const TextStyle(
                          color: Color(0xFFEFC9B2),
                          fontSize: 10,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              key: const ValueKey('customer-proin-safe-error'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(20),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0x66FFD5D5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: Color(0xFFFFD5D5),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error,
                      style: const TextStyle(
                        color: Color(0xFFFFE7E7),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('customer-proin-coupon-field'),
            controller: _couponController,
            focusNode: _couponFocusNode,
            enabled: !_couponSubmitting,
            textCapitalization: TextCapitalization.characters,
            maxLength: 20,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
              TextInputFormatter.withFunction((oldValue, newValue) {
                return newValue.copyWith(
                  text: newValue.text.toUpperCase(),
                  selection: TextSelection.collapsed(
                    offset: newValue.text.length,
                  ),
                );
              }),
            ],
            onSubmitted: (_) => _claimCoupon(),
            decoration: InputDecoration(
              hintText: 'Put your coupon',
              counterText: '',
              filled: true,
              fillColor: Colors.white,
              hintStyle: TextStyle(
                color: AppColors.primaryDark.withAlpha(150),
                fontWeight: FontWeight.w700,
              ),
              prefixIcon: const Icon(Icons.confirmation_number_outlined),
              suffixIcon: IconButton(
                key: const ValueKey('customer-proin-apply-coupon'),
                tooltip: 'Apply coupon',
                onPressed: _couponSubmitting ? null : _claimCoupon,
                icon: _couponSubmitting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward_rounded),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: const ValueKey('customer-proin-view-activity'),
              onPressed: _openActivity,
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('View Proin activity'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFFE7D7),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Proin can only reduce eligible booking prices. It cannot be purchased, transferred, withdrawn or exchanged for cash.',
            style: TextStyle(
              color: Color(0xFFEFC9B2),
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

String _proinDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/'
    '${date.month.toString().padLeft(2, '0')}/${date.year}';

String _proinSourceLabel(String value) {
  return switch (value.trim()) {
    'coupon' => 'Coupon',
    'referral_customer' => 'Customer referral',
    'referral_salon' => 'Salon referral',
    'promotion' => 'Promotion',
    'manual' => 'Support credit',
    _ => 'Reward',
  };
}

class _ProinActivitySheet extends StatefulWidget {
  const _ProinActivitySheet();

  @override
  State<_ProinActivitySheet> createState() => _ProinActivitySheetState();
}

class _ProinActivitySheetState extends State<_ProinActivitySheet> {
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await AppStateScope.read(context).refreshCustomerProinActivity();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = friendlyErrorMessage(
            error,
            fallback: 'We could not load your Proin activity. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = AppStateScope.watch(context).customerProinActivity;
    return FractionallySizedBox(
      heightFactor: 0.82,
      child: Material(
        key: const ValueKey('customer-proin-activity-sheet'),
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(35),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 10, 12),
              child: Row(
                children: [
                  const SoftIconBox(
                    icon: Icons.toll_rounded,
                    color: AppColors.primary,
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Proin activity',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          'Rewards earned, used, returned and expired',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _loading ? null : _refresh,
                    tooltip: 'Refresh activity',
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading && entries.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _error.isNotEmpty && entries.isEmpty
                  ? _ProinActivityMessage(
                      icon: Icons.cloud_off_outlined,
                      message: _error,
                      actionLabel: 'Try again',
                      onAction: _refresh,
                    )
                  : entries.isEmpty
                  ? const _ProinActivityMessage(
                      icon: Icons.receipt_long_outlined,
                      message: 'Your Proin activity will appear here.',
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, index) =>
                            _ProinActivityTile(entry: entries[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProinActivityMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  const _ProinActivityMessage({
    required this.icon,
    required this.message,
    this.actionLabel = '',
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: AppColors.primary),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onAction != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProinActivityTile extends StatelessWidget {
  final ProinActivityEntry entry;

  const _ProinActivityTile({required this.entry});

  ({String title, String subtitle, IconData icon, Color color, String amount})
  get presentation {
    switch (entry.type) {
      case 'grant':
        final source = entry.sourceType == 'coupon'
            ? 'Coupon reward'
            : entry.sourceType == 'referral'
            ? 'Referral reward'
            : 'Promotional reward';
        return (
          title: 'Proin earned',
          subtitle: source,
          icon: Icons.add_circle_outline_rounded,
          color: const Color(0xFF16845B),
          amount: '+${entry.amountProin}',
        );
      case 'reserve':
        return (
          title: 'Held for booking',
          subtitle: 'Reserved until the booking is completed or cancelled',
          icon: Icons.lock_clock_outlined,
          color: AppColors.amber,
          amount: '-${entry.amountProin}',
        );
      case 'release':
        return (
          title: 'Proin returned',
          subtitle: entry.expiredProin > 0
              ? '${entry.expiredProin} expired while the booking was open'
              : 'Booking hold released',
          icon: Icons.replay_circle_filled_outlined,
          color: const Color(0xFF16845B),
          amount: '+${entry.restoredProin}',
        );
      case 'redeem':
        return (
          title: 'Used at salon',
          subtitle: 'Applied to your completed booking',
          icon: Icons.shopping_bag_outlined,
          color: AppColors.primary,
          amount: '${entry.amountProin} used',
        );
      case 'expire':
        return (
          title: 'Proin expired',
          subtitle: 'The reward validity ended',
          icon: Icons.event_busy_outlined,
          color: Colors.redAccent,
          amount: '-${entry.amountProin}',
        );
      case 'revoke':
        return (
          title: 'Balance adjusted',
          subtitle: 'Unused promotional Proin removed by Pritze',
          icon: Icons.remove_circle_outline_rounded,
          color: Colors.redAccent,
          amount: '-${entry.amountProin}',
        );
      default:
        return (
          title: 'Proin activity',
          subtitle: entry.sourceType.isEmpty
              ? 'Account update'
              : entry.sourceType,
          icon: Icons.toll_outlined,
          color: AppColors.primary,
          amount: '${entry.amountProin}',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = presentation;
    final date = entry.createdAt.toLocal();
    final dateLabel =
        '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year} · '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: item.color.withAlpha(45)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 12,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          SoftIconBox(icon: item.icon, color: item.color, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  item.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 5),
                Text(dateLabel, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            item.amount,
            style: TextStyle(color: item.color, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _ProinMetric extends StatelessWidget {
  final String label;
  final String value;

  const _ProinMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(24),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFFEFC9B2), fontSize: 11),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoggedOutProfile extends StatelessWidget {
  final VoidCallback onLogin;

  const _LoggedOutProfile({required this.onLogin});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SoftIconBox(
            icon: Icons.person_outline,
            color: AppColors.primary,
            size: 52,
          ),
          const SizedBox(height: 12),
          Text(
            'Your account',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 5),
          Text(
            'Log in to manage your details, style preferences and bookings.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const ValueKey('customer-profile-login'),
            onPressed: onLogin,
            icon: const Icon(Icons.login),
            label: const Text('Log in'),
          ),
        ],
      ),
    );
  }
}

class _ProfileHero extends StatelessWidget {
  final UserAccount account;
  final VoidCallback onEdit;

  const _ProfileHero({required this.account, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, AppColors.champagne.withAlpha(210)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gold.withAlpha(80)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: AppColors.mint,
            foregroundColor: AppColors.primary,
            backgroundImage: account.photoUrl.isEmpty
                ? null
                : NetworkImage(account.photoUrl),
            child: account.photoUrl.isNotEmpty
                ? null
                : Text(
                    account.name.trim().isEmpty
                        ? 'C'
                        : account.name.trim().characters.first.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 3),
                Text(
                  account.contact,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (account.salonRatingCount > 0) ...[
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        color: AppColors.amber,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${formatRating(account.salonRating)} from ${account.salonRatingCount} salon ${account.salonRatingCount == 1 ? 'visit' : 'visits'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton.filledTonal(
            key: const ValueKey('edit-customer-profile'),
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit profile',
          ),
        ],
      ),
    );
  }
}

class _PersonalDetails extends StatelessWidget {
  final UserAccount account;

  const _PersonalDetails({required this.account});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'About you'),
          const SizedBox(height: 10),
          _ProfileDetail(
            icon: Icons.wc_outlined,
            label: 'Gender',
            value: account.gender.isEmpty
                ? 'Not added'
                : account.gender.replaceAll('-', ' '),
          ),
          const Divider(height: 20),
          _ProfileDetail(
            icon: Icons.cake_outlined,
            label: 'Birthdate',
            value: account.birthDate.isEmpty ? 'Not added' : account.birthDate,
          ),
          const Divider(height: 20),
          const _ProfileDetail(
            icon: Icons.auto_awesome_outlined,
            label: 'Preferred styles',
            value: '',
          ),
          const SizedBox(height: 8),
          if (account.preferredStyles.isEmpty)
            Text(
              'No preferences added yet.',
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final style in account.preferredStyles)
                  Chip(label: Text(style)),
              ],
            ),
        ],
      ),
    );
  }
}

class _ProfileDetail extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ProfileDetail({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (value.isNotEmpty)
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }
}

class _StyleGallery extends StatelessWidget {
  final List<String> photoUrls;

  const _StyleGallery({required this.photoUrls});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Styles you like'),
        const SizedBox(height: 10),
        SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photoUrls.length,
            separatorBuilder: (_, _) => const SizedBox(width: 9),
            itemBuilder: (context, index) => ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                photoUrls[index],
                width: 112,
                height: 112,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: AppColors.champagne,
                  child: SizedBox(
                    width: 112,
                    child: Icon(Icons.image_outlined),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SalonRatingsSection extends StatelessWidget {
  final UserAccount account;
  final List<CustomerSalonRating> ratings;

  const _SalonRatingsSection({required this.account, required this.ratings});

  @override
  Widget build(BuildContext context) {
    return _ExpandableRatingsCard(
      toggleKey: const ValueKey('ratings-from-salons-toggle'),
      title: 'Ratings from salons',
      subtitle: ratings.isEmpty
          ? 'No ratings yet'
          : '${formatRating(account.salonRating)} average · ${ratings.length} ${ratings.length == 1 ? 'visit' : 'visits'}',
      icon: Icons.reviews_outlined,
      child: ratings.isEmpty
          ? const Text('No salon has rated a completed visit yet.')
          : Column(
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.star_rounded,
                      color: AppColors.amber,
                      size: 30,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatRating(account.salonRating),
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(width: 6),
                    Text('across ${ratings.length} visits'),
                  ],
                ),
                for (final rating in ratings) ...[
                  const Divider(height: 22),
                  _RatingEntry(
                    salonName: rating.salonName,
                    rating: rating.rating,
                    note: rating.note,
                  ),
                ],
              ],
            ),
    );
  }
}

class _FeedbackSharedSection extends StatelessWidget {
  final List<SalonFeedback> feedback;

  const _FeedbackSharedSection({required this.feedback});

  @override
  Widget build(BuildContext context) {
    return _ExpandableRatingsCard(
      toggleKey: const ValueKey('ratings-given-to-salons-toggle'),
      title: 'Ratings you gave salons',
      subtitle: feedback.isEmpty
          ? 'No ratings shared yet'
          : '${feedback.length} ${feedback.length == 1 ? 'review' : 'reviews'} shared',
      icon: Icons.rate_review_outlined,
      child: feedback.isEmpty
          ? const Text('Your completed-visit feedback will appear here.')
          : Column(
              children: [
                for (var index = 0; index < feedback.length; index++) ...[
                  if (index > 0) const Divider(height: 22),
                  _RatingEntry(
                    salonName: feedback[index].salonName,
                    rating: feedback[index].rating,
                    note: feedback[index].note,
                  ),
                ],
              ],
            ),
    );
  }
}

class _ExpandableRatingsCard extends StatefulWidget {
  final Key toggleKey;
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  const _ExpandableRatingsCard({
    required this.toggleKey,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  @override
  State<_ExpandableRatingsCard> createState() => _ExpandableRatingsCardState();
}

class _ExpandableRatingsCardState extends State<_ExpandableRatingsCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            key: widget.toggleKey,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 4,
            ),
            leading: SoftIconBox(
              icon: widget.icon,
              color: AppColors.primary,
              size: 42,
            ),
            title: Text(
              widget.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(widget.subtitle),
            trailing: AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    children: [
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: widget.child,
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _RatingEntry extends StatelessWidget {
  final String salonName;
  final int rating;
  final String note;

  const _RatingEntry({
    required this.salonName,
    required this.rating,
    required this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SoftIconBox(
          icon: Icons.storefront_outlined,
          color: AppColors.primary,
          size: 40,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(salonName, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 3),
              Row(
                children: [
                  for (var index = 0; index < 5; index++)
                    Icon(
                      index < rating
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: AppColors.amber,
                      size: 17,
                    ),
                ],
              ),
              if (note.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(note, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
