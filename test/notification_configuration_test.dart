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
    expect(functions, contains('OWNER_ALERT_ATTEMPTS = 4'));
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
    expect(functions, contains('apnsSound: "owner_booking_request.wav"'));
    expect(functions, contains('androidSound: OWNER_BOOKING_REQUEST_SOUND'));
    final recipientLogic = File(
      'functions/booking_notification_logic.js',
    ).readAsStringSync();
    expect(recipientLogic, contains('after.cancelledBy === "customer"'));
    expect(recipientLogic, contains('excludeActor'));

    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android.permission.POST_NOTIFICATIONS'));
    expect(
      manifest,
      contains('com.google.firebase.messaging.default_notification_channel_id'),
    );

    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(infoPlist, contains('<string>remote-notification</string>'));
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
