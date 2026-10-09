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

  test('iOS exposes the Android UPI payment handoff', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('<data android:scheme="upi"/>'));

    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(infoPlist, contains('<string>upi</string>'));

    final receipt = File(
      'lib/screens/customer/customer_completion_receipt_screen.dart',
    ).readAsStringSync();
    expect(receipt, contains("uri.scheme != 'upi'"));
    expect(receipt, contains('LaunchMode.externalNonBrowserApplication'));
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
    // iOS delivers the owner alert through APNs, so Accept and Reject arrive
    // as RemoteMessage.actionIdentifier rather than through the local
    // notification plugin. Reading it is the difference between the buttons
    // deciding the booking and merely opening the app.
    expect(appState, contains('message.actionIdentifier'));
    // Both delivery routes must end in the same decision path.
    expect(
      RegExp(
        r'_submitNotificationBookingDecision\(',
      ).allMatches(appState).length,
      greaterThanOrEqualTo(3),
    );

    final functions = File('functions/index.js').readAsStringSync();
    expect(functions, contains('IOS_OWNER_BOOKING_REQUEST_CATEGORY'));
    expect(functions, contains('PRITZE_BOOKING_REQUEST_V2'));
  });

  test('iOS update enforcement tracks the shipped build, not a constant', () {
    final functions = File('functions/index.js').readAsStringSync();
    // The iOS prompt used frozen constants nobody updated, so the advertised
    // build could never move past 29 while the App Store sat at 1.0.20.
    expect(functions, contains('resolveIosUpdateVersion('));
    expect(functions, contains('ios_release.json'));
    expect(functions, isNot(contains('IOS_NEXT_BUILD_NUMBER')));
    expect(functions, isNot(contains('IOS_CURRENT_BUILD_NUMBER')));
    expect(
      functions,
      contains('IOS_LAST_CONFIRMED_PUBLIC_BUILD_NUMBER'),
      reason: 'the floor still belongs in source',
    );
    // Android keeps its own release file; the two must stay symmetrical.
    expect(File('functions/ios_release.json').existsSync(), isTrue);
    expect(File('functions/android_release.json').existsSync(), isTrue);
  });

  test('iOS uploads declare export compliance', () {
    // The app only uses HTTPS, which is exempt. Without this declaration every
    // upload reaches App Store Connect as "Missing Compliance" and cannot be
    // released to testers until someone answers the question by hand.
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(infoPlist, contains('<key>ITSAppUsesNonExemptEncryption</key>'));
    final declaration = infoPlist.substring(
      infoPlist.indexOf('<key>ITSAppUsesNonExemptEncryption</key>'),
    );
    expect(
      declaration.trimLeft().split('\n')[1].trim(),
      '<false/>',
      reason: 'only HTTPS is used, so no non-exempt encryption is declared',
    );
  });
}
