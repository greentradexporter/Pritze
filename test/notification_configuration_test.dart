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
    expect(appState, contains("'ownerAlertV3Tokens'"));
    expect(appState, contains('_ownerAlertsEnabledPreferenceKey'));
    expect(appState, contains("'ownerNotificationsEnabled': isOwnerSession"));
    expect(appState, contains('await messaging.deleteToken()'));
    expect(
      appState,
      contains("await _sendBookingPush(bookingId, event: 'statusUpdated')"),
    );
    expect(appState, contains('additionalFlags:'));
    expect(appState, contains("'accept_instant_booking'"));
    expect(appState, contains("'reject_instant_booking'"));
    expect(appState, contains('showsUserInterface: false'));
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
    expect(appState, contains('onDidReceiveNotificationResponse:'));
    expect(appState, contains('onDidReceiveBackgroundNotificationResponse:'));
    expect(appState, contains('notificationActionBackgroundHandler'));
    expect(appState, contains("httpsCallable('updateBookingStatus')"));
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
    expect(functions, contains('"pritze_owner_booking_requests_v3"'));
    expect(functions, contains('"pritze_owner_booking_requests_v2"'));
    expect(functions, contains('tokenField: "ownerAlertV3Tokens"'));
    expect(functions, contains('excludeTokenField: "ownerAlertV3Tokens"'));
    expect(functions, contains('requireActiveOwnerSession: true'));
    expect(functions, contains('requiredActiveRolesByUser'));
    expect(functions, contains('!requiredRoles.includes(data.activeRole)'));
    expect(functions, contains('data.ownerNotificationsEnabled !== true'));
    expect(functions, contains('onDocumentCreated'));
    expect(functions, contains('createdBooking?.isInstant !== true'));
    expect(functions, contains('OWNER_ALERT_ATTEMPTS = 6'));
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
