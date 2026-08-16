import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('customer-facing layout and booking flows are platform-neutral', () {
    for (final path in <String>[
      'lib/theme/app_theme.dart',
      'lib/screens/customer/customer_home_screen.dart',
      'lib/screens/customer/salon_booking_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('TargetPlatform.')), reason: path);
      expect(source, isNot(contains('defaultTargetPlatform')), reason: path);
      expect(source, isNot(contains('Platform.is')), reason: path);
    }
  });

  test('device conveniences have working Android and iOS implementations', () {
    final phoneHint = File(
      'lib/services/android_phone_hint.dart',
    ).readAsStringSync();
    expect(phoneHint, contains('TargetPlatform.android'));
    expect(phoneHint, contains('TargetPlatform.iOS'));

    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(appDelegate, contains('com.trimtime.app/phone_hint'));
    expect(appDelegate, contains('CNContactPickerViewController'));
    expect(
      appDelegate,
      contains('application.registerForRemoteNotifications()'),
    );

    final updatePrompt = File(
      'lib/widgets/app_update_prompt.dart',
    ).readAsStringSync();
    expect(updatePrompt, contains("doc(isIOS ? 'ios' : 'android')"));
    expect(updatePrompt, contains("'getIosAppUpdate'"));
    expect(updatePrompt, contains("'getAndroidAppUpdate'"));
    expect(updatePrompt, contains("_iosAppId = '6792811282'"));
    expect(updatePrompt, contains("Uri.https('itunes.apple.com', '/lookup'"));
    expect(updatePrompt, contains("'trackViewUrl'"));
  });

  test('iOS owner notifications expose the Android booking decisions', () {
    final appState = File('lib/state/app_state.dart').readAsStringSync();
    expect(appState, contains('DarwinNotificationCategory('));
    expect(appState, contains("'Accept'"));
    expect(appState, contains("'Reject'"));
    expect(
      appState,
      contains('categoryIdentifier: _ownerBookingRequestDarwinCategory'),
    );

    final functions = File('functions/index.js').readAsStringSync();
    expect(functions, contains('IOS_OWNER_BOOKING_REQUEST_CATEGORY'));
    expect(functions, contains('PRITZE_BOOKING_REQUEST_V2'));
  });
}
