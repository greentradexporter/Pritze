import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native notification resources and payload names stay aligned', () {
    final iosSound = File('ios/Runner/owner_booking_request.wav');
    final androidSound = File(
      'android/app/src/main/res/raw/owner_booking_request.wav',
    );
    expect(iosSound.existsSync(), isTrue);
    expect(androidSound.existsSync(), isTrue);
    _expectValidWaveFile(iosSound);
    _expectValidWaveFile(androidSound);

    final androidKeepRule = File(
      'android/app/src/main/res/raw/keep.xml',
    ).readAsStringSync();
    expect(androidKeepRule, contains('@raw/owner_booking_request'));

    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(project, contains('owner_booking_request.wav in Resources'));

    final appState = File('lib/state/app_state.dart').readAsStringSync();
    expect(
      appState,
      contains("Future<void> firebaseMessagingBackgroundHandler"),
    );
    expect(appState, contains("'ownerAlertV4Tokens'"));
    // The retired generation must still be cleared, or the server rings the
    // device twice: once per channel it is registered for.
    expect(appState, contains("'ownerAlertV3Tokens'"));
    // The owner-alert flag has exactly one owner. The app and the FCM isolate
    // reach it through that accessor so they cannot name different stores.
    expect(appState, contains('OwnerAlertPreferences().isEnabled()'));
    expect(appState, contains('OwnerAlertPreferences().setEnabled(enabled)'));
    expect(appState, isNot(contains('ownerAlertsEnabled')));
    final alertState = File(
      'lib/services/owner_booking_alert_state.dart',
    ).readAsStringSync();
    expect(alertState, contains('class OwnerAlertPreferences'));
    expect(
      RegExp(r"'pritze\.notifications\.ownerAlertsEnabled'")
          .allMatches(alertState)
          .length,
      1,
    );
    // The alarm stream, so a phone on silent still rings.
    expect(
      RegExp(r'audioAttributesUsage: AudioAttributesUsage\.alarm')
          .allMatches(appState)
          .length,
      greaterThanOrEqualTo(2),
    );
    expect(appState, contains("'pritze_owner_booking_requests_v4'"));
    expect(appState, contains('_legacyOwnerBookingRequestChannelIds'));
    expect(appState, contains("'ownerNotificationsEnabled': isOwnerSession"));
    // An owner whose stored role still says customer must still be treated as
    // an owner session, and the field the server routes on must be promoted.
    expect(
      appState,
      contains('authoritativeRole == UserRole.owner || '
          '_activeRole == UserRole.owner'),
    );
    expect(appState, contains("if (isOwnerSession) 'activeRole'"));
    final rules = File('firestore.rules').readAsStringSync();
    // The profile allowlist rejects the whole write when a field is missing,
    // which is how sign-out silently failed to de-register a device.
    for (final field in <String>[
      'fcmTokens',
      'ownerAlertV4Tokens',
      'ownerAlertV3Tokens',
      'lastFcmToken',
      'notificationsEnabled',
      'ownerNotificationsEnabled',
      'activeRole',
    ]) {
      expect(rules, contains("'$field'"), reason: '$field must be writable');
    }
    // Sign-out de-registration: the token read must not gate the write that
    // actually stops delivery.
    expect(appState, contains('performSignOutDeregistration('));
    expect(appState, contains('signOutDeregistrationFields('));
    expect(appState, contains('deleteToken: messaging.deleteToken'));
    final deregistration = File(
      'lib/services/push_deregistration.dart',
    ).readAsStringSync();
    expect(deregistration, contains("'notificationsEnabled': false"));
    expect(deregistration, contains("'ownerNotificationsEnabled': false"));
    expect(
      appState,
      contains("await _sendBookingPush(bookingId, event: 'statusUpdated')"),
    );
    expect(appState, contains('additionalFlags:'));
    expect(appState, contains("'accept_instant_booking'"));
    expect(appState, contains("'reject_instant_booking'"));
    expect(appState, contains('showsUserInterface: true'));
    expect(
      RegExp(r'cancelNotification: true').allMatches(appState).length,
      greaterThanOrEqualTo(2),
    );
    expect(
      appState,
      contains('actions: _ownerInstantBookingNotificationActions'),
    );
    expect(appState, contains("'PRITZE_BOOKING_REQUEST_V2'"));
    expect(appState, contains("'PRITZE_BOOKING_REQUEST'"));
    expect(appState, contains('DarwinNotificationCategory('));
    expect(appState, contains('DarwinNotificationAction.plain('));
    expect(
      appState,
      contains('categoryIdentifier: _ownerBookingRequestDarwinCategory'),
    );
    expect(appState, contains('autoCancel: false'));
    expect(appState, contains('FirebaseMessaging.onMessageOpenedApp.listen'));
    expect(appState, contains('messaging.getInitialMessage()'));
    expect(appState, contains('_applyRemoteCustomerBookingHint(message.data)'));
    // The cross-isolate preferences all live in the alert service now; the
    // app itself no longer reaches for a store of its own.
    expect(alertState, contains('SharedPreferencesAsync('));
    expect(appState, contains('_persistPendingOwnerBookingAction'));
    expect(appState, contains('_cancelOwnerBookingNotifications'));
    expect(appState, contains('_loadServerBooking(bookingId)'));
    expect(appState, contains('onDidReceiveNotificationResponse:'));
    expect(appState, contains('onDidReceiveBackgroundNotificationResponse:'));
    expect(appState, contains('notificationActionBackgroundHandler'));
    expect(appState, contains("httpsCallable('updateBookingStatus')"));
    expect(appState, contains('_prepareBackgroundBookingActionFirebase'));
    expect(appState, contains('FirebaseAppCheck.instance.getToken()'));
    expect(appState, contains('Never restart the continuous alarm'));
    expect(appState, contains('_backgroundBookingActionAuthTimeout'));
    expect(appState, contains('authStateChanges()'));
    final accountActions = File(
      'lib/widgets/account_actions.dart',
    ).readAsStringSync();
    expect(
      accountActions,
      contains('_unreadNotificationBadgeLifetime'),
      reason: 'The app should not surface stale booking history as unread.',
    );
    expect(accountActions, contains('_isCurrentUnreadBookingNotification'));
    expect(appState, contains('getNotificationAppLaunchDetails()'));
    expect(
      appState,
      contains('booking.isInstant && booking.status == BookingStatus.pending'),
    );
    expect(appState, contains("sound: 'owner_booking_request.wav'"));
    expect(
      RegExp(r'requestSoundPermission: false').allMatches(appState).length,
      greaterThanOrEqualTo(2),
    );

    final functions = File('functions/index.js').readAsStringSync();
    expect(functions, contains('"pritze_owner_booking_requests_v4"'));
    expect(functions, contains('"pritze_owner_booking_requests_v3"'));
    expect(functions, contains('"pritze_owner_booking_requests_v2"'));
    expect(functions, contains('"ownerAlertV4Tokens"'));
    expect(functions, contains('"ownerAlertV3Tokens"'));
    // Each generation is addressed on its own token list and excluded from the
    // older ones, so one device receives one alert.
    expect(functions, contains('tokenField: OWNER_ALERT_TOKEN_FIELD'));
    expect(
      functions,
      contains('excludeTokenField: OWNER_ALERT_TOKEN_FIELD'),
    );
    expect(functions, contains('excludeTokenFields: ['));
    // A signed-out device must be refused server side too: FCM token
    // rotation means its older tokens can still be in the list.
    expect(functions, contains('data.notificationsEnabled === false'));
    expect(functions, contains('requireActiveOwnerSession: true'));
    expect(functions, contains('requiredActiveRolesByUser'));
    expect(functions, contains('customerPayableAmount: money('));
    expect(functions, contains('completedAtMillis: adminMillis('));
    expect(
      functions,
      contains('Completion is the customer\'s payment trigger.'),
    );
    expect(functions, contains('!requiredRoles.includes(data.activeRole)'));
    expect(functions, contains('data.ownerNotificationsEnabled !== true'));
    expect(functions, contains('onDocumentCreated'));
    expect(functions, contains('createdBooking?.isInstant !== true'));
    expect(functions, contains('OWNER_ALERT_ATTEMPTS = 10'));
    expect(functions, contains('OWNER_ALERT_REPEAT_DELAY_MS = 15_000'));
    expect(functions, contains('INSTANT_RESPONSE_TIMEOUT_MS'));
    expect(functions, contains('expirePendingInstantBooking'));
    expect(functions, contains('Oops, looks like the salon is busy'));
    expect(functions, contains('androidDataOnly: true'));
    expect(
      functions,
      contains('"apns-priority": message.controlOnly ? "5" : "10"'),
    );
    expect(
      functions,
      contains(
        '"apns-push-type": message.controlOnly ? "background" : "alert"',
      ),
    );
    expect(functions, contains('onDocumentUpdated'));
    expect(functions, contains('stop_owner_booking_alarm'));
    expect(functions, contains('owner booking alert continued'));
    expect(functions, contains('apnsSound: "owner_booking_request.wav"'));
    expect(functions, contains('"PRITZE_BOOKING_REQUEST_V2"'));
    expect(functions, contains('IOS_OWNER_BOOKING_REQUEST_CATEGORY'));
    expect(
      functions,
      contains('apnsCategory: IOS_OWNER_BOOKING_REQUEST_CATEGORY'),
    );
    expect(functions, contains('function logPushDeliveryFailures('));
    expect(functions, contains('console.error("push delivery failed"'));
    expect(functions, contains('androidSound: OWNER_BOOKING_REQUEST_SOUND'));
    expect(functions, contains('exports.sendBookingArrivalReminders'));
    expect(functions, contains('schedule: "every 1 minutes"'));
    expect(functions, contains('"customerArrivalReminderSentAt"'));
    expect(functions, contains('"ownerArrivalReminderSentAt"'));
    final recipientLogic = File(
      'functions/booking_notification_logic.js',
    ).readAsStringSync();
    expect(recipientLogic, contains('after.customerUid'));
    expect(recipientLogic, contains('after.ownerUid'));

    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android.permission.POST_NOTIFICATIONS'));
    expect(manifest, contains('android.permission.USE_FULL_SCREEN_INTENT'));
    // Without these the full-screen intent wakes the phone to the keyguard
    // and the request stays hidden behind it.
    expect(manifest, contains('android:showWhenLocked="true"'));
    expect(manifest, contains('android:turnScreenOn="true"'));
    expect(
      manifest,
      contains('com.google.firebase.messaging.default_notification_channel_id'),
    );
    expect(
      manifest,
      contains(
        'com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver',
      ),
    );

    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(infoPlist, contains('<string>fetch</string>'));
    expect(infoPlist, contains('<string>remote-notification</string>'));
    expect(infoPlist, contains('app-1-3474382418-ios-73bf27d33b1eddec8c498b'));
    expect(infoPlist, contains('<key>NSContactsUsageDescription</key>'));
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(appDelegate, contains('import flutter_local_notifications'));
    expect(
      appDelegate,
      contains('FlutterLocalNotificationsPlugin.setPluginRegistrantCallback'),
    );
    expect(appDelegate, contains('CNContactPickerViewController'));
    expect(
      appDelegate,
      contains('application.registerForRemoteNotifications()'),
    );
    final entitlements = File(
      'ios/Runner/Runner.entitlements',
    ).readAsStringSync();
    expect(entitlements, contains('<key>aps-environment</key>'));
    // No salon owner is on iOS yet, so the owner alert is deliberately an
    // ordinary notification there: iOS cannot loop a sound, and the
    // time-sensitive entitlement would add an App ID capability the archive
    // has to be signed against. The per-message level stays plumbed through
    // so raising it later is a one-line change.
    expect(
      entitlements,
      isNot(contains('usernotifications.time-sensitive')),
      reason: 'adding this needs the App ID capability enabled first',
    );
    expect(appState, contains('interruptionLevel: InterruptionLevel.active'));
    expect(functions, contains('message.apnsInterruptionLevel || "active"'));
    expect(functions, isNot(contains('apnsInterruptionLevel: "')));
  });
}

void _expectValidWaveFile(File file) {
  final bytes = file.readAsBytesSync();
  expect(bytes.length, greaterThan(44));
  expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
  expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
  final header = ByteData.sublistView(Uint8List.fromList(bytes));
  final channelCount = header.getUint16(22, Endian.little);
  final sampleRate = header.getUint32(24, Endian.little);
  final bitsPerSample = header.getUint16(34, Endian.little);
  final bytesPerSecond = sampleRate * channelCount * (bitsPerSample ~/ 8);
  final durationSeconds = (bytes.length - 44) / bytesPerSecond;
  expect(durationSeconds, greaterThanOrEqualTo(28));
  expect(durationSeconds, lessThan(30));
  expect(bytes.length, lessThan(6 * 1024 * 1024));
}
