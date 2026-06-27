import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'screens/customer/customer_home_screen.dart';
import 'services/firebase_bootstrap.dart';
import 'state/app_state_scope.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final firebase = await FirebaseBootstrap.initialize();

  if (!firebase.enabled) {
    runApp(FirebaseUnavailableApp(error: firebase.error));
    return;
  }
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

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
      home: const CustomerHomeScreen(),
      debugShowCheckedModeBanner: false,
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
