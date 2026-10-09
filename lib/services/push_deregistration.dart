/// Sign-out has to take this device off the account's push lists.
///
/// The steps have very different failure costs, so they are ordered and
/// isolated rather than wrapped in one `try`. Reading the token is the
/// fragile step: on iOS `getToken()` throws until APNs has issued a token,
/// and on any platform it needs the network. Writing the account flags is the
/// step that actually stops delivery, so it must not be skipped when the
/// read fails — that is what left signed-out phones ringing for booking
/// requests.
///
/// [readToken] may throw or return null; [fallbackToken] is then used, which
/// is whatever this device last registered. [write] receives the token to
/// remove, or null when none could be determined, and must write the account
/// flags either way. [deleteToken] is local cleanup and its failure is never
/// reported: the account is already de-registered by then.
Future<void> performSignOutDeregistration({
  required Future<String?> Function() readToken,
  required Future<void> Function(String? token) write,
  required Future<void> Function() deleteToken,
  String? fallbackToken,
  void Function(Object error)? onWriteError,
  void Function(Object error)? onDegraded,
}) async {
  var token = fallbackToken;
  try {
    token = await readToken() ?? token;
  } catch (error) {
    onDegraded?.call(error);
  }
  try {
    await write(token);
  } catch (error) {
    onWriteError?.call(error);
  } finally {
    try {
      await deleteToken();
    } catch (error) {
      onDegraded?.call(error);
    }
  }
}

/// The account fields that stop push delivery for this device.
///
/// The flags are unconditional. The token removals are best effort: FCM
/// rotates tokens, so the list can still hold older entries for this same
/// device and the flags are what the server must honour.
Map<String, Object?> signOutDeregistrationFields({
  required String? token,
  required Object Function(List<String> values) arrayRemove,
  required Object delete,
  required Object serverTimestamp,
}) {
  final hasToken = token != null && token.isNotEmpty;
  return {
    if (hasToken) ...{
      'fcmTokens': arrayRemove([token]),
      'ownerAlertV4Tokens': arrayRemove([token]),
      'ownerAlertV3Tokens': arrayRemove([token]),
    },
    'lastFcmToken': delete,
    'notificationsEnabled': false,
    'ownerNotificationsEnabled': false,
    'activeRole': delete,
    'fcmUpdatedAt': serverTimestamp,
  };
}
