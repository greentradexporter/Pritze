import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _ownerAlertChannel = MethodChannel('com.trimtime.app/owner_alerts');

/// Why an owner's phone would stay silent for a booking request.
///
/// Each of these fails silently on the device: the server sends the push, the
/// app posts the alert, and the owner still hears nothing. Reporting them is
/// the only way an owner can tell a quiet evening from a broken one.
enum OwnerAlertBlocker {
  /// The system notification permission is off, so nothing is shown at all.
  notificationsDisabled,

  /// No FCM token is registered, so the server cannot reach this device.
  noPushToken,

  /// Android 14+ withheld USE_FULL_SCREEN_INTENT. The alert still arrives but
  /// only as a banner, which a locked phone never surfaces.
  fullScreenIntentDenied,

  /// Battery optimisation is on. Aggressive vendors stop the app when it is
  /// swiped away, and a stopped app receives no data-only message at all.
  batteryOptimised,
}

@immutable
class OwnerAlertReadiness {
  const OwnerAlertReadiness(this.blockers);

  final Set<OwnerAlertBlocker> blockers;

  /// True when nothing stands between a booking request and a ringing phone.
  bool get isReady => blockers.isEmpty;

  /// These stop the alert entirely rather than just making it easy to miss.
  bool get isSilent =>
      blockers.contains(OwnerAlertBlocker.notificationsDisabled) ||
      blockers.contains(OwnerAlertBlocker.noPushToken);
}

class OwnerAlertDeviceSettings {
  const OwnerAlertDeviceSettings._();

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Defaults to "not blocking" whenever the platform cannot answer. A missing
  /// channel must never invent a warning the owner cannot act on.
  static Future<bool> _ask(String method, {bool fallback = true}) async {
    if (!_supported) return fallback;
    try {
      return await _ownerAlertChannel.invokeMethod<bool>(method) ?? fallback;
    } on MissingPluginException {
      return fallback;
    } on PlatformException {
      return fallback;
    }
  }

  static Future<bool> canUseFullScreenIntent() =>
      _ask('canUseFullScreenIntent');

  static Future<bool> isIgnoringBatteryOptimizations() =>
      _ask('isIgnoringBatteryOptimizations');

  /// Opens the system screen. Returns false when the device has no such
  /// screen, so the caller can tell the owner where to look instead.
  static Future<bool> openFullScreenIntentSettings() =>
      _ask('openFullScreenIntentSettings', fallback: false);

  static Future<bool> openBatteryOptimizationSettings() =>
      _ask('openBatteryOptimizationSettings', fallback: false);

  /// [notificationsEnabled] and [hasPushToken] come from the app's own
  /// messaging state; only the two device settings are asked of the platform.
  static Future<OwnerAlertReadiness> check({
    required bool notificationsEnabled,
    required bool hasPushToken,
  }) async {
    final blockers = <OwnerAlertBlocker>{};
    if (!notificationsEnabled) {
      blockers.add(OwnerAlertBlocker.notificationsDisabled);
    }
    if (!hasPushToken) {
      blockers.add(OwnerAlertBlocker.noPushToken);
    }
    if (_supported) {
      if (!await canUseFullScreenIntent()) {
        blockers.add(OwnerAlertBlocker.fullScreenIntentDenied);
      }
      if (!await isIgnoringBatteryOptimizations()) {
        blockers.add(OwnerAlertBlocker.batteryOptimised);
      }
    }
    return OwnerAlertReadiness(blockers);
  }
}

/// Owner-facing wording. Each line names the symptom first, because an owner
/// recognises "requests do not ring" long before they recognise the setting.
String ownerAlertBlockerMessage(OwnerAlertBlocker blocker) {
  return switch (blocker) {
    OwnerAlertBlocker.notificationsDisabled =>
      'Booking requests cannot alert you. Turn on notifications for Pritze.',
    OwnerAlertBlocker.noPushToken =>
      'This device is not registered for booking alerts. Sign out and sign in '
          'again to reconnect it.',
    OwnerAlertBlocker.fullScreenIntentDenied =>
      'Requests will not show on a locked screen. Allow full screen alerts so '
          'they ring like a call.',
    OwnerAlertBlocker.batteryOptimised =>
      'Your phone may stop Pritze in the background and miss requests. Allow '
          'it to run unrestricted.',
  };
}
