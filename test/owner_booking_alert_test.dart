import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nashik_salon_booking/services/owner_booking_alert_state.dart';
import 'package:nashik_salon_booking/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];
  Future<void> Function()? onShow;

  RemoteMessage request(
    String id, {
    DateTime? deadline,
    String channel = 'pritze_owner_booking_requests_v4',
  }) => RemoteMessage(
    data: {
      'channel': channel,
      'bookingId': id,
      'isInstant': 'true',
      'status': 'pending',
      'responseDeadlineMillis':
          (deadline ?? DateTime.now().add(const Duration(minutes: 2)))
              .millisecondsSinceEpoch
              .toString(),
      'notificationTitle': 'Instant booking request',
      'notificationBody': 'Customer is waiting',
    },
  );

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SharedPreferences.setMockInitialValues({});
    await OwnerAlertPreferences().setEnabled(true);
    calls.clear();
    onShow = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'show') await onShow?.call();
          if (call.method == 'getActiveNotifications') return <dynamic>[];
          if (call.method == 'initialize') return true;
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final status in ['confirmed', 'rejected', 'cancelled']) {
    test('$status stop blocks delayed request pushes', () async {
      await firebaseMessagingBackgroundHandler(
        RemoteMessage(
          data: {
            'action': 'stop_owner_booking_alarm',
            'bookingId': 'a',
            'status': status,
          },
        ),
      );
      calls.clear();
      await firebaseMessagingBackgroundHandler(request('a'));
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    });
  }

  test('regular confirmation push also stops the alarm', () async {
    await firebaseMessagingBackgroundHandler(
      const RemoteMessage(
        data: {'bookingId': 'a', 'isInstant': 'true', 'status': 'confirmed'},
      ),
    );
    await firebaseMessagingBackgroundHandler(request('a'));
    expect(calls.where((call) => call.method == 'show'), isEmpty);
  });

  test(
    'unanswered request keeps continuous sound and expires at its deadline',
    () async {
      await firebaseMessagingBackgroundHandler(
        request('a', deadline: DateTime.now().add(const Duration(seconds: 23))),
      );
      final show = calls.singleWhere((call) => call.method == 'show');
      final android = (show.arguments as Map)['platformSpecifics'] as Map;
      expect(android['additionalFlags'], contains(4));
      expect(android['ongoing'], isTrue);
      expect(android['autoCancel'], isFalse);
      expect(android['sound'], 'owner_booking_request');
      expect(android['timeoutAfter'], inInclusiveRange(1, 23000));
      final actions = android['actions'] as List;
      expect(actions.map((action) => action['id']), [
        'accept_instant_booking',
        'reject_instant_booking',
      ]);
      expect(
        actions.every((action) => action['showsUserInterface'] == true),
        isTrue,
      );
    },
  );

  test('expired request cannot restart even without a stop push', () async {
    await firebaseMessagingBackgroundHandler(
      request(
        'a',
        deadline: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    );
    expect(calls.where((call) => call.method == 'show'), isEmpty);
  });

  test(
    'stop during platform posting cancels the in-flight notification',
    () async {
      onShow = () => OwnerBookingAlertState().stop('a');
      await firebaseMessagingBackgroundHandler(request('a'));
      final shown = calls.indexWhere((call) => call.method == 'show');
      expect(shown, greaterThanOrEqualTo(0));
      expect(
        calls.skip(shown + 1).any((call) => call.method == 'cancel'),
        isTrue,
      );
      calls.clear();
      await firebaseMessagingBackgroundHandler(request('a'));
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    },
  );

  test(
    'stopping A leaves B notification and button identities independent',
    () async {
      await firebaseMessagingBackgroundHandler(request('a'));
      await firebaseMessagingBackgroundHandler(request('b'));
      final ids = calls
          .where((call) => call.method == 'show')
          .map((call) => (call.arguments as Map)['id'])
          .toSet();
      expect(ids, hasLength(2));
      calls.clear();
      await firebaseMessagingBackgroundHandler(
        const RemoteMessage(
          data: {
            'action': 'stop_owner_booking_alarm',
            'bookingId': 'a',
            'status': 'confirmed',
          },
        ),
      );
      expect(
        calls
            .where((call) => call.method == 'cancel')
            .any(
              (call) =>
                  (call.arguments as Map)['id'] ==
                  ownerBookingNotificationId('b'),
            ),
        isFalse,
      );
      await firebaseMessagingBackgroundHandler(request('b'));
      expect(calls.where((call) => call.method == 'show'), hasLength(1));
    },
  );

  for (final status in ['confirmed', 'rejected']) {
    test(
      'cold launch recovers native $status and keeps delayed alerts silent',
      () async {
        final now = DateTime.now();
        // These values are written by MainActivity before Flutter starts.
        // This fake exposes them only through the named native preferences file.
        SharedPreferencesAsyncPlatform.instance = _NativeActionPreferences({
          'pritze.notifications.ownerAlertStopped.a': now
              .add(const Duration(minutes: 10))
              .millisecondsSinceEpoch,
          'pritze.notifications.pendingOwnerBookingAction.a':
              '$status|${now.millisecondsSinceEpoch}',
        });
        expect(await OwnerBookingAlertState().isStopped('a'), isTrue);
        expect(
          (await OwnerBookingDecisionStore().pending()).single,
          startsWith('a|$status|'),
        );
        var shows = 0;
        await OwnerBookingAlertState().showIfUnanswered(
          bookingId: 'a',
          deadline: now.add(const Duration(minutes: 2)),
          show: (_) async {
            shows++;
          },
          cancel: () async {},
        );
        expect(shows, 0);
        var submitted = false;
        await performOwnerBookingDecision(
          bookingId: 'a',
          status: status,
          cancel: () async {},
          submit: () async {
            submitted = true;
          },
        );
        expect(submitted, isTrue);
        expect(await OwnerBookingDecisionStore().pending(), isEmpty);
      },
    );

    test(
      'panel $status submits decision and stops the app timer from reposting',
      () async {
        var submissions = 0;
        await performOwnerBookingDecision(
          bookingId: 'a',
          status: status,
          cancel: () async {
            expect(await OwnerBookingAlertState().isStopped('a'), isTrue);
          },
          submit: () async {
            final queued = await OwnerBookingDecisionStore().pending();
            expect(queued.single, startsWith('a|$status|'));
            submissions++;
          },
        );
        expect(submissions, 1);
        expect(await OwnerBookingDecisionStore().pending(), isEmpty);
        // A separate instance represents the foreground isolate with a stale
        // pending Firestore snapshot, using the same gate as the app timer.
        var shows = 0;
        await OwnerBookingAlertState().showIfUnanswered(
          bookingId: 'a',
          deadline: DateTime.now().add(const Duration(minutes: 2)),
          isStillPending: () => true,
          show: (_) async {
            shows++;
          },
          cancel: () async {},
        );
        expect(shows, 0);
      },
    );
  }

  test(
    'failed network submission keeps the decision queued and the phone silent',
    () async {
      await expectLater(
        performOwnerBookingDecision(
          bookingId: 'a',
          status: 'confirmed',
          cancel: () async {},
          submit: () async => throw StateError('offline'),
        ),
        throwsStateError,
      );
      expect(await OwnerBookingAlertState().isStopped('a'), isTrue);
      expect(
        (await OwnerBookingDecisionStore().pending()).single,
        startsWith('a|confirmed|'),
      );
    },
  );

  test(
    'notification cleanup failure does not prevent backend acceptance',
    () async {
      var submitted = false;
      await performOwnerBookingDecision(
        bookingId: 'a',
        status: 'confirmed',
        cancel: () async => throw StateError('platform unavailable'),
        submit: () async {
          submitted = true;
        },
      );
      expect(submitted, isTrue);
      expect(await OwnerBookingDecisionStore().pending(), isEmpty);
    },
  );

  test(
    'concurrent decisions cannot overwrite each others saved state',
    () async {
      await Future.wait([
        OwnerBookingAlertState().stop('a'),
        OwnerBookingAlertState().stop('b'),
        OwnerBookingDecisionStore().save('a', 'confirmed'),
        OwnerBookingDecisionStore().save('b', 'rejected'),
      ]);
      expect(await OwnerBookingAlertState().isStopped('a'), isTrue);
      expect(await OwnerBookingAlertState().isStopped('b'), isTrue);
      await OwnerBookingDecisionStore().clear('a');
      expect(
        (await OwnerBookingDecisionStore().pending()).single,
        startsWith('b|rejected|'),
      );
    },
  );

  test(
    'booking resolved while awaiting initialization is never posted',
    () async {
      var shows = 0;
      await OwnerBookingAlertState().showIfUnanswered(
        bookingId: 'a',
        deadline: DateTime.now().add(const Duration(minutes: 2)),
        isStillPending: () => false,
        show: (_) async {
          shows++;
        },
        cancel: () async {},
      );
      expect(shows, 0);
    },
  );

  test(
    'legacy suppression remains readable without rewriting shared state',
    () async {
      final prefs = SharedPreferencesAsync();
      final entries = [
        'a|${DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch}',
      ];
      await prefs.setStringList(
        'pritze.notifications.suppressedOwnerAlerts',
        entries,
      );
      expect(await OwnerBookingAlertState().isStopped('a'), isTrue);
      expect(
        await prefs.getStringList('pritze.notifications.suppressedOwnerAlerts'),
        entries,
      );
    },
  );

  group('owner alert enablement reaches the FCM isolate', () {
    test('the flag the app writes is the flag the handler reads', () async {
      // Only the named native file answers here. A writer and a reader that
      // disagree on the store leave this silent, which is how a background
      // booking request stopped ringing at all.
      SharedPreferencesAsyncPlatform.instance = _NativeActionPreferences({});
      await OwnerAlertPreferences().setEnabled(true);
      expect(await OwnerAlertPreferences().isEnabled(), isTrue);

      await firebaseMessagingBackgroundHandler(request('a'));
      expect(calls.where((call) => call.method == 'show'), hasLength(1));
    });

    test('a request is ignored until an owner session enables it', () async {
      SharedPreferencesAsyncPlatform.instance = _NativeActionPreferences({});
      SharedPreferences.setMockInitialValues({});
      expect(await OwnerAlertPreferences().isEnabled(), isFalse);

      await firebaseMessagingBackgroundHandler(request('a'));
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    });

    test('sign-out silences the handler', () async {
      await OwnerAlertPreferences().setEnabled(false);
      await firebaseMessagingBackgroundHandler(request('a'));
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    });

    test('a push addressed to a retired channel still rings', () async {
      // An owner who updates but does not reopen the app stays on the previous
      // token list, so the server keeps addressing them by the previous
      // channel id. The alert is still posted on the current channel.
      await firebaseMessagingBackgroundHandler(
        request('a', channel: 'pritze_owner_booking_requests_v3'),
      );
      final show = calls.singleWhere((call) => call.method == 'show');
      final android = (show.arguments as Map)['platformSpecifics'] as Map;
      expect(android['channelId'], 'pritze_owner_booking_requests_v4');
      expect(android['additionalFlags'], contains(4));
    });

    test('an unrelated channel is left to the normal push path', () async {
      await firebaseMessagingBackgroundHandler(
        request('a', channel: 'pritze_booking_updates'),
      );
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    });

    test('a flag left by the previous build still rings', () async {
      // The previous build wrote this through the legacy preferences API.
      // An owner who has not signed in again since updating must still ring.
      SharedPreferencesAsyncPlatform.instance = _NativeActionPreferences({});
      SharedPreferences.setMockInitialValues({
        'pritze.notifications.ownerAlertsEnabled': true,
      });
      expect(await OwnerAlertPreferences().isEnabled(), isTrue);

      await firebaseMessagingBackgroundHandler(request('a'));
      expect(calls.where((call) => call.method == 'show'), hasLength(1));
    });
  });
}

final class _NativeActionPreferences extends InMemorySharedPreferencesAsync {
  _NativeActionPreferences(super.data) : super.withData();

  bool _isNativeFile(SharedPreferencesOptions options) =>
      options is SharedPreferencesAsyncAndroidOptions &&
      options.backend ==
          SharedPreferencesAndroidBackendLibrary.SharedPreferences &&
      options.originalSharedPreferencesOptions?.fileName ==
          'pritze_owner_booking_actions';

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) async =>
      _isNativeFile(options) ? super.getBool(key, options) : null;

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) async =>
      _isNativeFile(options) ? super.getInt(key, options) : null;

  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async => _isNativeFile(options) ? super.getString(key, options) : null;

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async => _isNativeFile(options) ? super.getKeys(parameters, options) : {};
}
