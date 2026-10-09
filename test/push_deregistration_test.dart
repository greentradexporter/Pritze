import 'package:flutter_test/flutter_test.dart';
import 'package:nashik_salon_booking/services/push_deregistration.dart';

void main() {
  Map<String, Object?> fields(String? token) => signOutDeregistrationFields(
    token: token,
    arrayRemove: (values) => 'remove:${values.join(',')}',
    delete: 'delete',
    serverTimestamp: 'now',
  );

  group('signing out always de-registers the account', () {
    test('a token read that throws still writes the stop flags', () async {
      // The iOS case: getToken() throws until APNs issues a token. This used
      // to abort the write, leaving the phone registered and still ringing.
      String? written = 'unset';
      var wrote = false;
      final degraded = <Object>[];
      await performSignOutDeregistration(
        readToken: () async => throw StateError('apns-token-not-set'),
        write: (token) async {
          wrote = true;
          written = token;
        },
        deleteToken: () async {},
        onDegraded: degraded.add,
      );
      expect(wrote, isTrue);
      expect(written, isNull);
      expect(degraded, hasLength(1));
      expect(fields(written)['notificationsEnabled'], isFalse);
      expect(fields(written)['ownerNotificationsEnabled'], isFalse);
      expect(fields(written)['activeRole'], 'delete');
    });

    test('a failed read falls back to the last registered token', () async {
      String? written;
      await performSignOutDeregistration(
        fallbackToken: 'registered-token',
        readToken: () async => throw StateError('offline'),
        write: (token) async => written = token,
        deleteToken: () async {},
      );
      expect(written, 'registered-token');
      expect(fields(written)['fcmTokens'], 'remove:registered-token');
      expect(fields(written)['ownerAlertV4Tokens'], 'remove:registered-token');
      expect(fields(written)['ownerAlertV3Tokens'], 'remove:registered-token');
    });

    test('a fresh token wins over the remembered one', () async {
      String? written;
      await performSignOutDeregistration(
        fallbackToken: 'stale-token',
        readToken: () async => 'fresh-token',
        write: (token) async => written = token,
        deleteToken: () async {},
      );
      expect(written, 'fresh-token');
    });

    test('the local token is deleted even when the write fails', () async {
      var deleted = false;
      final writeErrors = <Object>[];
      await performSignOutDeregistration(
        readToken: () async => 'token',
        write: (_) async => throw StateError('permission-denied'),
        deleteToken: () async => deleted = true,
        onWriteError: writeErrors.add,
      );
      expect(deleted, isTrue);
      expect(writeErrors, hasLength(1));
    });

    test('nothing thrown by cleanup can keep the user signed in', () async {
      // signOutActiveUser awaits this before calling auth.signOut().
      await expectLater(
        performSignOutDeregistration(
          readToken: () async => throw StateError('read'),
          write: (_) async => throw StateError('write'),
          deleteToken: () async => throw StateError('delete'),
        ),
        completes,
      );
    });

    test('an unknown token omits the array removals, never the flags', () {
      final payload = fields(null);
      expect(payload.containsKey('fcmTokens'), isFalse);
      expect(payload.containsKey('ownerAlertV4Tokens'), isFalse);
      expect(payload.containsKey('ownerAlertV3Tokens'), isFalse);
      expect(payload['notificationsEnabled'], isFalse);
      expect(payload['lastFcmToken'], 'delete');
    });

    test('an empty token is treated as unknown', () {
      expect(fields('').containsKey('fcmTokens'), isFalse);
      expect(fields('')['notificationsEnabled'], isFalse);
    });
  });
}
