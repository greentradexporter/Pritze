import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/app_ui.dart';
import '../barber/barber_dashboard_screen.dart';
import '../customer/customer_home_screen.dart';
import '../salon/salon_dashboard_screen.dart';

class PartnerHubScreen extends StatelessWidget {
  const PartnerHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const AppBottomNav(selectedIndex: 2),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          children: [
            const AppHeroHeader(
              eyebrow: 'Partner space',
              title: 'Run the shop side from one place',
              subtitle:
                  'Owners manage listings and teams. Barbers join salons and track the day.',
              icon: Icons.business_center,
            ),
            const SizedBox(height: 22),
            SectionHeader(
              title: 'Choose your workspace',
              actionLabel: 'Customer app',
              onAction: () {
                AppStateScope.read(context).selectRole(UserRole.customer);
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const CustomerHomeScreen()),
                  (route) => false,
                );
              },
            ),
            const SizedBox(height: 10),
            _PartnerCard(
              icon: Icons.dashboard_customize,
              color: AppColors.primary,
              title: 'Salon owner',
              subtitle:
                  'Register your shop, add services, manage staff, and control booking status.',
              primaryLabel: 'Register or manage shop',
              onTap: () {
                AppStateScope.read(context).selectRole(UserRole.owner);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SalonDashboardScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _PartnerCard(
              icon: Icons.badge,
              color: AppColors.coral,
              title: 'Barber',
              subtitle:
                  'Join a shop, view assigned customers, and update work status.',
              primaryLabel: 'Open barber tools',
              onTap: () {
                AppStateScope.read(context).selectRole(UserRole.barber);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const BarberDashboardScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
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
      onTap: onTap,
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
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                primaryLabel,
                style: TextStyle(color: color, fontWeight: FontWeight.w900),
              ),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward, size: 18, color: color),
            ],
          ),
        ],
      ),
    );
  }
}
