import 'dart:async';

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
import 'widgets/ios_owner_booking_request_gate.dart';
import 'widgets/app_update_prompt.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw a native-looking Flutter launch screen immediately. Firebase core is
  // local work, but starting it before `runApp` used to leave iOS showing its
  // static launch screen until all plugin setup had reached Dart.
  runApp(const PritzeBootstrapApp());
}

class PritzeBootstrapApp extends StatefulWidget {
  const PritzeBootstrapApp({super.key});

  @override
  State<PritzeBootstrapApp> createState() => _PritzeBootstrapAppState();
}

class _PritzeBootstrapAppState extends State<PritzeBootstrapApp> {
  FirebaseBootstrap? _firebase;

  @override
  void initState() {
    super.initState();
    unawaited(_startFirebase());
  }

  Future<void> _startFirebase() async {
    final firebase = await FirebaseBootstrap.initialize();
    if (!mounted) return;
    if (firebase.enabled) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }
    setState(() => _firebase = firebase);
  }

  @override
  Widget build(BuildContext context) {
    final firebase = _firebase;
    if (firebase == null) {
      return MaterialApp(
        title: 'Pritze',
        theme: AppTheme.build(),
        home: const _SessionRestoreScreen(),
        debugShowCheckedModeBanner: false,
      );
    }

    if (!firebase.enabled) {
      return FirebaseUnavailableApp(error: firebase.error);
    }

    return AppStateProvider(
      createAppState: () => FirebaseAppState(
        firestore: firebase.firestore!,
        functions: firebase.functions!,
        auth: firebase.auth!,
        messaging: firebase.messaging!,
        storage: firebase.storage!,
      ),
      child: const TrimtimeApp(),
    );
  }
}

class TrimtimeApp extends StatefulWidget {
  const TrimtimeApp({super.key});

  @override
  State<TrimtimeApp> createState() => _TrimtimeAppState();
}

class _TrimtimeAppState extends State<TrimtimeApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Deep-link discovery is useful for referral onboarding, but asking the
    // operating system for an initial link must never delay the first frame.
    unawaited(ReferralLinkService.initialize());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Pritze',
      theme: AppTheme.build(),
      // These listeners must outlive individual pages. Several customer and
      // owner navigation flows replace the complete route stack, so placing
      // them in `home` silently disabled popups after the first navigation.
      builder: (context, child) => AppUpdatePrompt(
        navigatorKey: _navigatorKey,
        child: IosOwnerBookingRequestGate(
          navigatorKey: _navigatorKey,
          child: CustomerBookingConfirmationGate(
            navigatorKey: _navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
      home: const AppEntryScreen(),
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
      UserRole.customer || null => const CustomerHomeScreen(),
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
