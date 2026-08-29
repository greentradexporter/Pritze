import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/app_ui.dart';

const _referralBaseUrl = 'https://trimtime-46539.web.app/r';

class ReferralScreen extends StatefulWidget {
  final UserRole role;

  const ReferralScreen({super.key, required this.role});

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  Future<(ReferralCodes, ReferralSummary)>? _referralData;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _referralData ??= _loadReferralData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Refer and invite')),
      body: FutureBuilder<(ReferralCodes, ReferralSummary)>(
        future: _referralData,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return _ReferralLoadError(
              message: _friendlyReferralError(snapshot.error),
              onRetry: () => setState(() {
                _referralData = _loadReferralData();
              }),
            );
          }
          final (codes, summary) = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
            children: [
              GlassCard(
                color: AppColors.champagne,
                child: Column(
                  children: [
                    const SoftIconBox(
                      icon: Icons.card_giftcard_rounded,
                      color: AppColors.primary,
                      size: 54,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.role == UserRole.customer
                          ? 'Invite friends to Pritze'
                          : 'Grow the Pritze community',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.role == UserRole.customer
                          ? 'Your code can be used only by a new customer.'
                          : 'Use the correct code for a new customer or a new salon owner.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _ReferralCodeCard(
                key: const ValueKey('customer-referral-code-card'),
                title: 'Invite a customer',
                subtitle:
                    'Qualifies after the customer completes their first booking',
                rewardText: _referralRewardText(
                  inviterAmount: summary.customerInviterRewardProin,
                  referredAmount: summary.customerReferredRewardProin,
                  referredLabel: 'new customer',
                ),
                code: codes.customerInviteCode,
                message: _customerShareMessage(
                  codes.customerInviteCode,
                  summary,
                ),
              ),
              if (widget.role == UserRole.owner &&
                  codes.salonInviteCode.isNotEmpty) ...[
                const SizedBox(height: 14),
                _ReferralCodeCard(
                  key: const ValueKey('salon-referral-code-card'),
                  title: 'Invite a salon',
                  subtitle:
                      'Qualifies after the new salon is approved and completes its first booking',
                  rewardText: _referralRewardText(
                    inviterAmount: summary.salonInviterRewardProin,
                    referredAmount: summary.salonReferredRewardProin,
                    referredLabel: 'new salon',
                  ),
                  code: codes.salonInviteCode,
                  message: _salonShareMessage(codes.salonInviteCode, summary),
                ),
              ],
              const SizedBox(height: 14),
              _ReferralProgressCard(summary: summary, role: widget.role),
            ],
          );
        },
      ),
    );
  }

  Future<(ReferralCodes, ReferralSummary)> _loadReferralData() {
    final appState = AppStateScope.read(context);
    return Future<(ReferralCodes, ReferralSummary)>.microtask(() async {
      final codesFuture = appState.ensureReferralCodes();
      final summaryFuture = appState.getReferralSummary();
      final codes = await codesFuture;
      final summary = await summaryFuture;
      return (codes, summary);
    });
  }
}

class _ReferralCodeCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String rewardText;
  final String code;
  final String message;

  const _ReferralCodeCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.rewardText,
    required this.code,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 3),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.champagne,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.toll_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    rewardText,
                    key: ValueKey('referral-reward-$code'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.mint,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.primary.withAlpha(45)),
            ),
            child: SelectableText(
              code,
              key: ValueKey('referral-code-$code'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 5,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Referral code copied.')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Builder(
                  builder: (buttonContext) => FilledButton.icon(
                    key: ValueKey('share-referral-$code'),
                    onPressed: () => _share(buttonContext),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Share'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    await SharePlus.instance.share(
      ShareParams(
        text: message,
        subject: 'Join me on Pritze',
        sharePositionOrigin: origin,
      ),
    );
  }
}

class _ReferralProgressCard extends StatelessWidget {
  final ReferralSummary summary;
  final UserRole role;

  const _ReferralProgressCard({required this.summary, required this.role});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Referral progress',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          _ReferralProgressRow(
            label: 'Customers',
            pending: summary.pendingCustomerCount,
            qualified: summary.qualifiedCustomerCount,
          ),
          if (role == UserRole.owner) ...[
            const Divider(height: 22),
            _ReferralProgressRow(
              label: 'Salons',
              pending: summary.pendingSalonCount,
              qualified: summary.qualifiedSalonCount,
            ),
          ],
          const Divider(height: 24),
          Row(
            children: [
              const SoftIconBox(
                icon: Icons.workspace_premium_rounded,
                color: AppColors.primary,
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Earned from referrals',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${summary.earnedReferralProin} Proin',
                      key: const ValueKey('referral-earned-proin'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReferralProgressRow extends StatelessWidget {
  final String label;
  final int pending;
  final int qualified;

  const _ReferralProgressRow({
    required this.label,
    required this.pending,
    required this.qualified,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        AppPill(
          icon: Icons.hourglass_top_rounded,
          label: '$pending pending',
          color: AppColors.primaryDark,
          backgroundColor: AppColors.champagne,
        ),
        const SizedBox(width: 8),
        AppPill(
          icon: Icons.verified_rounded,
          label: '$qualified qualified',
          color: AppColors.success,
          backgroundColor: AppColors.mint,
        ),
      ],
    );
  }
}

class _ReferralLoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ReferralLoadError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off_rounded, size: 44),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

String _referralRewardText({
  required int inviterAmount,
  required int referredAmount,
  required String referredLabel,
}) {
  if (inviterAmount <= 0 && referredAmount <= 0) {
    return 'No referral reward campaign is active right now';
  }
  if (inviterAmount == referredAmount && inviterAmount > 0) {
    return 'You and the $referredLabel each earn $inviterAmount Proin';
  }
  return 'You earn $inviterAmount Proin · The $referredLabel earns $referredAmount Proin';
}

String _customerShareMessage(String code, ReferralSummary summary) {
  final reward =
      summary.customerInviterRewardProin > 0 ||
          summary.customerReferredRewardProin > 0
      ? 'After your first completed booking, you earn ${summary.customerReferredRewardProin} Proin and I earn ${summary.customerInviterRewardProin} Proin. '
      : '';
  return 'Join Pritze as a customer. ${reward}Use my referral code $code during registration: $_referralBaseUrl/$code?role=customer';
}

String _salonShareMessage(String code, ReferralSummary summary) {
  final reward =
      summary.salonInviterRewardProin > 0 ||
          summary.salonReferredRewardProin > 0
      ? 'After your salon is approved and completes its first booking, you earn ${summary.salonReferredRewardProin} Proin and I earn ${summary.salonInviterRewardProin} Proin. '
      : '';
  return 'Join Pritze as a salon owner. ${reward}Use my referral code $code during registration: $_referralBaseUrl/$code?role=owner';
}

String _friendlyReferralError(Object? error) {
  return friendlyErrorMessage(
    error,
    fallback: 'Could not load referral codes. Please try again.',
  );
}
