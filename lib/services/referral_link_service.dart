import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';

class ReferralLinkService {
  ReferralLinkService._();

  static const _host = 'trimtime-46539.web.app';
  static const _codeKey = 'pending_referral_code_v1';
  static const _roleKey = 'pending_referral_role_v1';
  static StreamSubscription<Uri>? _subscription;

  static Future<void> initialize() async {
    try {
      final links = AppLinks();
      final initial = await links.getInitialLink();
      if (initial != null) {
        await _store(initial);
      }
      _subscription ??= links.uriLinkStream.listen(
        (uri) => unawaited(_store(uri)),
        onError: (_) {},
      );
    } catch (_) {
      // Referral links must never block the app from starting.
    }
  }

  static Future<String> pendingCodeFor(UserRole? role) async {
    if (role != UserRole.customer && role != UserRole.owner) {
      return '';
    }
    final preferences = await SharedPreferences.getInstance();
    final code = preferences.getString(_codeKey)?.trim().toUpperCase() ?? '';
    final targetRole = preferences.getString(_roleKey) ?? '';
    if (!_isValidCode(code) || targetRole != role!.name) {
      return '';
    }
    return code;
  }

  static Future<void> clearPendingCode() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_codeKey);
    await preferences.remove(_roleKey);
  }

  static Future<void> _store(Uri uri) async {
    if (uri.scheme != 'https' || uri.host != _host) {
      return;
    }
    final segments = uri.pathSegments;
    if (segments.length != 2 || segments.first != 'r') {
      return;
    }
    final code = segments.last.trim().toUpperCase();
    final role = uri.queryParameters['role']?.trim().toLowerCase() ?? '';
    if (!_isValidCode(code) || (role != 'customer' && role != 'owner')) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_codeKey, code);
    await preferences.setString(_roleKey, role);
  }

  static bool _isValidCode(String code) =>
      RegExp(r'^(?=.*[A-Z])(?=.*\d)[A-Z\d]{6}$').hasMatch(code);
}
