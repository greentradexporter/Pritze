import 'package:flutter/material.dart';

import '../screens/customer/customer_home_screen.dart';
import '../screens/customer/customer_profile_screen.dart';
import '../screens/customer/my_bookings_screen.dart';
import '../screens/partner/partner_hub_screen.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import 'booking_status_timeline.dart';

class AppBottomNav extends StatelessWidget {
  final int selectedIndex;

  const AppBottomNav({super.key, required this.selectedIndex});

  @override
  Widget build(BuildContext context) {
    final activeBooking = AppStateScope.watch(context).activeCustomerBooking;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (activeBooking != null)
          CurrentBookingBottomPanel(
            booking: activeBooking,
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const MyBookingsScreen())),
          ),
        DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: AppColors.line)),
          ),
          child: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) {
              if (index == selectedIndex) {
                return;
              }
              final appState = AppStateScope.read(context);
              final opensCustomerArea = index == 0 || index == 1;
              if (opensCustomerArea && appState.hasActiveOwnerSession) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'This account is registered as a salon owner and cannot be '
                      'used as a customer.',
                    ),
                  ),
                );
                return;
              }
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => _screenFor(index)),
                (route) => false,
              );
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.explore_outlined),
                selectedIcon: Icon(Icons.explore),
                label: 'Discover',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Profile',
              ),
              NavigationDestination(
                icon: Icon(Icons.business_center_outlined),
                selectedIcon: Icon(Icons.business_center),
                label: 'Partner',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _screenFor(int index) {
    switch (index) {
      case 1:
        return const CustomerProfileScreen();
      case 2:
        return const PartnerHubScreen();
      case 0:
      default:
        return const CustomerHomeScreen();
    }
  }
}
