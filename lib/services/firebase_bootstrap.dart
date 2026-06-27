import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

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
      await FirebaseAppCheck.instance.activate(
        providerAndroid: kReleaseMode
            ? const AndroidPlayIntegrityProvider()
            : const AndroidDebugProvider(),
        providerApple: kReleaseMode
            ? const AppleAppAttestWithDeviceCheckFallbackProvider()
            : const AppleDebugProvider(),
      );
      final auth = FirebaseAuth.instance;
      return FirebaseBootstrap._(
        enabled: true,
        firestore: FirebaseFirestore.instance,
        functions: FirebaseFunctions.instance,
        auth: auth,
        messaging: FirebaseMessaging.instance,
        storage: FirebaseStorage.instance,
      );
    } catch (error) {
      return FirebaseBootstrap._(enabled: false, error: error);
    }
  }
}
