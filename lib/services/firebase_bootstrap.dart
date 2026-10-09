import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

const firebaseFunctionsRegion = 'asia-south1';

class FirebaseBootstrap {
  final bool enabled;
  final FirebaseFirestore? firestore;
  final FirebaseFunctions? functions;
  final FirebaseAuth? auth;
  final FirebaseMessaging? messaging;
  final FirebaseStorage? storage;
  final Object? error;

  const FirebaseBootstrap._({
    required this.enabled,
    this.firestore,
    this.functions,
    this.auth,
    this.messaging,
    this.storage,
    this.error,
  });

  static Future<FirebaseBootstrap> initialize() async {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      return FirebaseBootstrap._(enabled: false, error: error);
    }

    // App Check and the debug-only phone-auth preference are platform setup,
    // not prerequisites for drawing the first usable frame. Start them now
    // and let them finish while the user sees the locally restored home.
    unawaited(_configurePlatformServices());

    return FirebaseBootstrap._(
      enabled: true,
      firestore: FirebaseFirestore.instance,
      functions: FirebaseFunctions.instanceFor(region: firebaseFunctionsRegion),
      auth: FirebaseAuth.instance,
      messaging: FirebaseMessaging.instance,
      storage: FirebaseStorage.instance,
    );
  }

  static Future<void> _configurePlatformServices() async {
    try {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: kReleaseMode
            ? const AndroidPlayIntegrityProvider()
            : const AndroidDebugProvider(),
        providerApple: kReleaseMode
            ? const AppleAppAttestWithDeviceCheckFallbackProvider()
            : const AppleDebugProvider(),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Firebase App Check activation failed: $error');
      }
    }

    if (kDebugMode && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await FirebaseAuth.instance.setSettings(forceRecaptchaFlow: true);
      } catch (error) {
        debugPrint('Firebase Auth debug reCAPTCHA fallback failed: $error');
      }
    }
  }
}
