import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class FirebaseBootstrap {
  final bool enabled;
  final FirebaseFirestore? firestore;
  final FirebaseAuth? auth;
  final Object? error;

  const FirebaseBootstrap._({
    required this.enabled,
    this.firestore,
    this.auth,
    this.error,
  });

  static Future<FirebaseBootstrap> initialize() async {
    try {
      await Firebase.initializeApp();
      final auth = FirebaseAuth.instance;
      if (kDebugMode) {
        await auth.setSettings(appVerificationDisabledForTesting: true);
      }
      return FirebaseBootstrap._(
        enabled: true,
        firestore: FirebaseFirestore.instance,
        auth: auth,
      );
    } catch (error) {
      return FirebaseBootstrap._(enabled: false, error: error);
    }
  }
}
