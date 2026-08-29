import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'models/app_models.dart';
import 'screens/customer/customer_home_screen.dart';
import 'screens/salon/salon_dashboard_screen.dart';
import 'screens/referrals/referral_onboarding_screen.dart';
import 'services/firebase_bootstrap.dart';
import 'services/referral_link_service.dart';
import 'state/app_state_scope.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'widgets/trimtime_logo.dart';
import 'widgets/customer_booking_confirmation_gate.dart';
import 'widgets/app_update_prompt.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReferralLinkService.initialize();
  final firebase = await FirebaseBootstrap.initialize();

  if (!firebase.enabled) {
    runApp(FirebaseUnavailableApp(error: firebase.error));
    return;
  }
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  runApp(
    AppStateProvider(
      createAppState: () => FirebaseAppState(
        firestore: firebase.firestore!,
        functions: firebase.functions!,
        auth: firebase.auth!,
        messaging: firebase.messaging!,
        storage: firebase.storage!,
      ),
      child: const TrimtimeApp(),
    ),
  );
}

class TrimtimeApp extends StatelessWidget {
  const TrimtimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pritze',
      theme: AppTheme.build(),
      // Keep the update prompt inside the app Navigator so its mandatory
      // dialog can always be presented above the currently visible route.
      home: const AppUpdatePrompt(child: AppEntryScreen()),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppEntryScreen extends StatelessWidget {
  const AppEntryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    if (appState.isRestoringSession) {
      return const _SessionRestoreScreen();
    }
    if (appState.activeRole != null && appState.referralOnboardingRequired) {
      return const ReferralOnboardingScreen();
    }
    return switch (appState.activeRole) {
      UserRole.owner => const SalonDashboardScreen(),
      UserRole.barber => const CustomerHomeScreen(),
      UserRole.customer || null => const CustomerBookingConfirmationGate(
        child: CustomerHomeScreen(),
      ),
    };
  }
}

class _SessionRestoreScreen extends StatelessWidget {
  const _SessionRestoreScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TrimtimeLogo(size: 60, shadow: false),
              SizedBox(height: 20),
              SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(height: 12),
              Text(
                'Opening Pritze',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FirebaseUnavailableApp extends StatelessWidget {
  final Object? error;

  const FirebaseUnavailableApp({super.key, this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pritze',
      theme: AppTheme.build(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Firebase is not configured',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  error?.toString() ??
                      'Add Firebase configuration before running the app.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}
