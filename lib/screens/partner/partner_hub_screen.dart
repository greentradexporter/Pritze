import 'package:flutter/material.dart';

import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/app_ui.dart';
import '../salon/salon_dashboard_screen.dart';

class PartnerHubScreen extends StatelessWidget {
  const PartnerHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const AppBottomNav(selectedIndex: 2),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          children: [
            _PartnerCard(
              icon: Icons.dashboard_customize,
              color: AppColors.primary,
              title: 'Salon owner',
              subtitle:
                  'Register your shop, add services, manage staff, and control booking status.',
              primaryLabel: 'Register or manage shop',
              onTap: () {
                final appState = AppStateScope.read(context);
                if (appState.hasActiveCustomerSession) {
                  _showRoleConflict(
                    context,
                    'This phone number is already registered as a customer. '
                    'Sign out before using a different salon owner account.',
                  );
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SalonDashboardScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRoleConflict(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PartnerCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String primaryLabel;
  final VoidCallback onTap;

  const _PartnerCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.primaryLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SoftIconBox(icon: icon, color: color, size: 54),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.arrow_forward),
              label: Text(primaryLabel),
            ),
          ),
        ],
      ),
    );
  }
}
