import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

const ownerBookingResponseTimeout = Duration(minutes: 2);
const ownerBookingSuppressionDuration = Duration(minutes: 10);

SharedPreferencesAsync _ownerActionPreferences() => SharedPreferencesAsync(
  options: const SharedPreferencesAsyncAndroidOptions(
    backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
    originalSharedPreferencesOptions: AndroidSharedPreferencesStoreOptions(
      fileName: 'pritze_owner_booking_actions',
    ),
  ),
);

int ownerBookingNotificationId(String bookingId) {
  // Stable across isolates and restarts. The Android plugin uses id * 16
  // for action PendingIntents, so keep all 16 action slots within 31 bits.
  var hash = 0x811c9dc5;
  for (final unit in bookingId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x07ffffff;
}

/// Whether this device should ring for owner booking requests.
///
/// The foreground app writes it at login and sign-out; the FCM isolate reads
/// it before posting an alert. Both must name the same store, so it lives
/// beside the other owner-alert keys rather than in the default preferences
/// file, where the two APIs disagree on both the backend and the key prefix.
class OwnerAlertPreferences {
  OwnerAlertPreferences({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? _ownerActionPreferences();

  final SharedPreferencesAsync _preferences;
  static const _enabledKey = 'pritze.notifications.ownerAlertsEnabled';

  Future<void> setEnabled(bool enabled) =>
      _preferences.setBool(_enabledKey, enabled);

  /// Falls back to the legacy store the previous build wrote through
  /// `SharedPreferences`, so an owner who has not signed in again since
  /// updating still rings.
  Future<bool> isEnabled() async {
    final value = await _preferences.getBool(_enabledKey);
    if (value != null) return value;
    try {
      return (await SharedPreferences.getInstance()).getBool(_enabledKey) ??
          false;
    } catch (_) {
      // No legacy value reachable. The foreground app rewrites the flag on the
      // next owner login, and the role check still guards the alert.
      return false;
    }
  }
}

/// Shared by the UI, notification-action and FCM isolates. Each booking has
/// its own key: reading an alert must never overwrite another isolate's stop.
class OwnerBookingAlertState {
  OwnerBookingAlertState({
    SharedPreferencesAsync? preferences,
    DateTime Function()? now,
  }) : _preferences = preferences ?? _ownerActionPreferences(),
       _legacyPreferences = preferences ?? SharedPreferencesAsync(),
       _now = now ?? DateTime.now;

  final SharedPreferencesAsync _preferences;
  final SharedPreferencesAsync _legacyPreferences;
  final DateTime Function() _now;
  static const _prefix = 'pritze.notifications.ownerAlertStopped.';
  static const _legacyKey = 'pritze.notifications.suppressedOwnerAlerts';

  Future<void> stop(String bookingId) => _preferences.setInt(
    '$_prefix$bookingId',
    _now().add(ownerBookingSuppressionDuration).millisecondsSinceEpoch,
  );

  Future<bool> isStopped(String bookingId) async {
    final now = _now().millisecondsSinceEpoch;
    final deadline = await _preferences.getInt('$_prefix$bookingId');
    if (deadline != null && deadline > now) return true;
    // Read-only compatibility with decisions made by the previous build.
    final legacy =
        await _legacyPreferences.getStringList(_legacyKey) ?? const [];
    return legacy.any((entry) {
      final separator = entry.lastIndexOf('|');
      return separator > 0 &&
          entry.substring(0, separator) == bookingId &&
          (int.tryParse(entry.substring(separator + 1)) ?? 0) > now;
    });
  }

  /// Check on both sides of the platform call. A decision can arrive while
  /// channel initialization or notification posting is in flight.
  Future<bool> showIfUnanswered({
    required String bookingId,
    required DateTime deadline,
    required Future<void> Function(int remainingMillis) show,
    required Future<void> Function() cancel,
    bool Function()? isStillPending,
  }) async {
    Future<bool> mayRing() async =>
        !(await isStopped(bookingId)) &&
        _now().isBefore(deadline) &&
        (isStillPending?.call() ?? true);

    if (!await mayRing()) {
      await cancel();
      return false;
    }
    final remaining = deadline.difference(_now()).inMilliseconds;
    if (remaining <= 0) {
      await cancel();
      return false;
    }
    await show(remaining);
    if (!await mayRing()) {
      await cancel();
      return false;
    }
    return true;
  }
}

class OwnerBookingDecisionStore {
  OwnerBookingDecisionStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? _ownerActionPreferences(),
      _legacyPreferences = preferences ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _preferences;
  final SharedPreferencesAsync _legacyPreferences;
  static const _prefix = 'pritze.notifications.pendingOwnerBookingAction.';
  static const _legacyKey = 'pritze.notifications.pendingOwnerBookingActions';

  Future<void> save(String bookingId, String status) => _preferences.setString(
    '$_prefix$bookingId',
    '$status|${DateTime.now().millisecondsSinceEpoch}',
  );

  Future<List<String>> pending() async {
    final entries = <String, String>{};
    for (final entry
        in await _legacyPreferences.getStringList(_legacyKey) ?? <String>[]) {
      entries[entry.split('|').first] = entry;
    }
    for (final key in await _preferences.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final value = await _preferences.getString(key);
      if (value != null) {
        final id = key.substring(_prefix.length);
        entries[id] = '$id|$value';
      }
    }
    return entries.values.toList();
  }

  Future<void> clear(String bookingId) async {
    await _preferences.remove('$_prefix$bookingId');
    final legacy = await _legacyPreferences.getStringList(_legacyKey);
    if (legacy != null &&
        legacy.any((entry) => entry.startsWith('$bookingId|'))) {
      await _legacyPreferences.setStringList(
        _legacyKey,
        legacy.where((entry) => !entry.startsWith('$bookingId|')).toList(),
      );
    }
  }
}

/// Saving the decision and silencing the phone happen before network work.
/// Only an acknowledged backend response removes the durable retry entry.
Future<void> performOwnerBookingDecision({
  required String bookingId,
  required String status,
  required Future<void> Function() cancel,
  required Future<void> Function() submit,
}) async {
  await OwnerBookingAlertState().stop(bookingId);
  final decisions = OwnerBookingDecisionStore();
  await decisions.save(bookingId, status);
  try {
    await cancel();
  } catch (_) {
    // Notification cleanup must not prevent the booking decision reaching
    // the server. Every later alert consults the saved stop above.
  }
  await submit();
  await decisions.clear(bookingId);
}

DateTime? ownerBookingAlertDeadline(Map<String, dynamic> data) {
  int millis(Object? value) => int.tryParse(value?.toString() ?? '') ?? 0;
  final explicit = millis(data['responseDeadlineMillis']);
  if (explicit > 0) return DateTime.fromMillisecondsSinceEpoch(explicit);
  final created = millis(data['createdAtMillis']);
  if (created > 0) {
    return DateTime.fromMillisecondsSinceEpoch(
      created,
    ).add(ownerBookingResponseTimeout);
  }
  return null;
}
