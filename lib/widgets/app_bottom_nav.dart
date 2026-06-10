import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../screens/customer/customer_home_screen.dart';
import '../screens/customer/my_bookings_screen.dart';
import '../screens/partner/partner_hub_screen.dart';
import '../state/app_state_scope.dart';

class AppBottomNav extends StatelessWidget {
  final int selectedIndex;

  const AppBottomNav({super.key, required this.selectedIndex});

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: (index) {
        if (index == selectedIndex) {
          return;
        }
        if (index == 0 || index == 1) {
          AppStateScope.read(context).selectRole(UserRole.customer);
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
          icon: Icon(Icons.receipt_long_outlined),
          selectedIcon: Icon(Icons.receipt_long),
          label: 'Bookings',
        ),
        NavigationDestination(
          icon: Icon(Icons.business_center_outlined),
          selectedIcon: Icon(Icons.business_center),
          label: 'Partner',
        ),
      ],
    );
  }

  Widget _screenFor(int index) {
    switch (index) {
      case 1:
        return const MyBookingsScreen();
      case 2:
        return const PartnerHubScreen();
      case 0:
      default:
        return const CustomerHomeScreen();
    }
  }
}
