import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';
import '../models/service_catalog.dart';
import '../services/firebase_bootstrap.dart';
import '../services/owner_booking_alert_state.dart';
import '../services/push_deregistration.dart';

const _activeRolePreferenceKey = 'pritze.activeRole';
const _activeRoleAccountIdPreferenceKey = 'pritze.activeRole.accountId';
const _seenNotificationsPreferencePrefix = 'pritze.notifications.seen.';
const _dismissedNotificationsPreferencePrefix =
    'pritze.notifications.dismissed.';
const _notificationsReadAtPreferencePrefix = 'pritze.notifications.readAt.';
const _upiHandoffOpenedPreferencePrefix = 'pritze.upiHandoff.opened.';
const _pushPermissionRequestedPreferenceKey =
    'pritze.notifications.permissionRequested';
const _ownerAlertSuppressionDuration = ownerBookingSuppressionDuration;
const _backgroundBookingActionAuthTimeout = Duration(seconds: 4);
const instantArrivalMinuteOptions = <int>[15, 20, 25];
const instantBookingResponseTimeout = ownerBookingResponseTimeout;
const scheduledBookingHorizonDays = 30;

/// How far ahead the first bookable slot sits. A customer turned away by one
/// salon is offered the next slot from here, so this is also the shortest
/// notice a salon can be given.
const scheduledBookingLeadTime = Duration(minutes: 30);
const customerCancellationReasons = <String>[
  'Plans changed',
  'Booked by mistake',
  'Taking too long to confirm',
  'Found another salon',
  'Cannot reach the salon',
  'Other',
];
const _zeroBookingFee = 0;
const _zeroBookingFeeStatus = 'not_required';
const _defaultSupportPhone = '+91 73101 91586';
const _pushNotificationChannel = AndroidNotificationChannel(
  'pritze_booking_updates',
  'Booking updates',
  description: 'Booking, request, and account updates from Pritze.',
  importance: Importance.high,
);
// Android channels are immutable once created, so changing how the alert
// sounds needs a new id. `_legacyOwnerBookingRequestChannelIds` keeps the
// retired ones cancellable, and the server addresses each generation by its
// own token field so a device never rings twice.
const _ownerBookingRequestChannel = AndroidNotificationChannel(
  'pritze_owner_booking_requests_v4',
  'Owner booking requests',
  description:
      'Continuous booking request alerts until accepted, rejected or timed out.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  sound: RawResourceAndroidNotificationSound('owner_booking_request'),
  // The alarm stream, so a salon phone left on silent still rings. The
  // notification stream obeys the ringer switch, which made the alert
  // inaudible on exactly the phones that sit face-down on a counter.
  audioAttributesUsage: AudioAttributesUsage.alarm,
);
const _ownerBookingAlarmNotificationId = 790001;
const _ownerBookingAlarmNotificationTag = 'pritze_owner_booking_request';
const _legacyOwnerBookingRequestChannelIds = <String>{
  'pritze_owner_booking_requests_v2',
  'pritze_owner_booking_requests_v3',
};
const _ownerBookingAlarmInterval = Duration(seconds: 15);
const _androidInsistentNotificationFlag = 4;
const _acceptInstantBookingNotificationAction = 'accept_instant_booking';
const _rejectInstantBookingNotificationAction = 'reject_instant_booking';
const _legacyOwnerBookingRequestDarwinCategory = 'PRITZE_BOOKING_REQUEST';
const _ownerBookingRequestDarwinCategory = 'PRITZE_BOOKING_REQUEST_V2';
const _ownerInstantBookingNotificationActions = <AndroidNotificationAction>[
  AndroidNotificationAction(
    _acceptInstantBookingNotificationAction,
    'Accept',
    showsUserInterface: true,
    cancelNotification: true,
  ),
  AndroidNotificationAction(
    _rejectInstantBookingNotificationAction,
    'Reject',
    showsUserInterface: true,
    cancelNotification: true,
  ),
];
final _ownerBookingRequestDarwinNotificationCategories =
    <DarwinNotificationCategory>[
      _darwinOwnerBookingRequestCategory(
        _legacyOwnerBookingRequestDarwinCategory,
      ),
      _darwinOwnerBookingRequestCategory(_ownerBookingRequestDarwinCategory),
    ];

DarwinNotificationCategory _darwinOwnerBookingRequestCategory(
  String identifier,
) {
  return DarwinNotificationCategory(
    identifier,
    actions: <DarwinNotificationAction>[
      DarwinNotificationAction.plain(
        _acceptInstantBookingNotificationAction,
        'Accept',
      ),
      DarwinNotificationAction.plain(
        _rejectInstantBookingNotificationAction,
        'Reject',
        options: <DarwinNotificationActionOption>{
          DarwinNotificationActionOption.destructive,
        },
      ),
    ],
  );
}

class CustomerNameRequiredException implements Exception {
  const CustomerNameRequiredException();

  @override
  String toString() =>
      'Enter your name once to finish creating this customer account.';
}

class CustomerPhoneRequiredException implements Exception {
  const CustomerPhoneRequiredException();

  @override
  String toString() =>
      'Enter your mobile number to finish creating this Gmail account.';
}

String _notificationPayload(Map<String, dynamic> data) {
  return jsonEncode({
    'destination': data['destination'] ?? 'bookings',
    'bookingId': data['bookingId'] ?? '',
    'isInstant': data['isInstant'] ?? 'false',
    'channel': data['channel'] ?? '',
    'createdAtMillis': data['createdAtMillis'] ?? 0,
    'responseDeadlineMillis': data['responseDeadlineMillis'] ?? 0,
    'event': data['event'] ?? '',
    'status': data['status'] ?? '',
    'statusOccurredAtMillis': data['statusOccurredAtMillis'] ?? 0,
    'acceptedAtMillis': data['acceptedAtMillis'] ?? 0,
    'cancelledAtMillis': data['cancelledAtMillis'] ?? 0,
    'rejectedAtMillis': data['rejectedAtMillis'] ?? 0,
    'completedAtMillis': data['completedAtMillis'] ?? 0,
    'startMillis': data['startMillis'] ?? 0,
    'arrivalMinutes': data['arrivalMinutes'] ?? 0,
    'customerPayableAmount': data['customerPayableAmount'] ?? 0,
    'cancelledBy': data['cancelledBy'] ?? '',
    'cancellationReason': data['cancellationReason'] ?? '',
  });
}

Map<String, dynamic> _decodeNotificationPayloadValue(String? payload) {
  if (payload == null || payload.trim().isEmpty) {
    return const {};
  }
  try {
    final value = jsonDecode(payload);
    return value is Map ? Map<String, dynamic>.from(value) : const {};
  } catch (_) {
    return const {};
  }
}

Future<void> _persistOwnerAlertSuppression(String bookingId) =>
    OwnerBookingAlertState().stop(bookingId);

String _ownerBookingTag(String bookingId) =>
    '$_ownerBookingAlarmNotificationTag:$bookingId';

bool _isOwnerBookingRequestChannel(Object? channelId) {
  final id = channelId?.toString() ?? '';
  return id == _ownerBookingRequestChannel.id ||
      _legacyOwnerBookingRequestChannelIds.contains(id);
}

bool _isOwnerBookingResolution(Map<String, dynamic> data) =>
    data['action'] == 'stop_owner_booking_alarm' ||
    (data['isInstant']?.toString() == 'true' &&
        <String>{
          'confirmed',
          'rejected',
          'cancelled',
          'inProgress',
          'completed',
        }.contains(data['status']?.toString()));

DateTime? _ownerAlertMessageDeadline(RemoteMessage message) {
  final explicit = ownerBookingAlertDeadline(message.data);
  if (explicit != null) return explicit;
  // Compatibility with the previous server payload. A repeated push does not
  // start a fresh two-minute window, and a delayed push uses its send time.
  final sentAt = message.sentTime;
  if (sentAt == null) return null;
  final attempt =
      int.tryParse(message.data['alertAttempt']?.toString() ?? '') ?? 1;
  return sentAt
      .add(instantBookingResponseTimeout)
      .subtract(Duration(seconds: (attempt.clamp(1, 10) - 1) * 15));
}

Future<void> _persistPendingOwnerBookingAction(
  String bookingId,
  String status,
) => OwnerBookingDecisionStore().save(bookingId, status);

Future<void> _clearPendingOwnerBookingAction(String bookingId) =>
    OwnerBookingDecisionStore().clear(bookingId);

Future<void> _clearOwnerDecisionFeedback(String bookingId) async {
  try {
    await FlutterLocalNotificationsPlugin().cancel(
      id: ownerBookingNotificationId('decision:$bookingId'),
      tag: 'pritze_owner_decision:$bookingId',
    );
  } catch (_) {
    // The acknowledged backend decision must not depend on OS cleanup.
  }
}

Future<void> _showOwnerDecisionFailure(
  String bookingId,
  Object error, {
  FlutterLocalNotificationsPlugin? initializedNotifications,
}) async {
  final terminal =
      error is FirebaseFunctionsException &&
      <String>{
        'failed-precondition',
        'not-found',
        'permission-denied',
        'invalid-argument',
      }.contains(error.code);
  if (terminal) await _clearPendingOwnerBookingAction(bookingId);
  try {
    final notifications =
        initializedNotifications ?? FlutterLocalNotificationsPlugin();
    if (initializedNotifications == null) {
      await _initializeBackgroundNotifications(notifications);
    }
    await notifications.show(
      id: ownerBookingNotificationId('decision:$bookingId'),
      title: terminal
          ? 'Booking response not completed'
          : 'Booking response waiting to sync',
      body: terminal
          ? 'Open bookings to review this request. Your response could not be completed.'
          : 'Your response is saved. We will retry while this request is active.',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _pushNotificationChannel.id,
          _pushNotificationChannel.name,
          tag: 'pritze_owner_decision:$bookingId',
          silent: true,
          playSound: false,
          enableVibration: false,
        ),
        iOS: const DarwinNotificationDetails(presentSound: false),
      ),
      payload: _notificationPayload({'bookingId': bookingId}),
    );
  } catch (_) {
    // Keep the saved decision even if the OS cannot display feedback.
  }
}

Future<void> _cancelOwnerBookingNotifications(
  FlutterLocalNotificationsPlugin notifications, {
  String? bookingId,
}) async {
  if (bookingId != null) {
    await notifications.cancel(
      id: ownerBookingNotificationId(bookingId),
      tag: _ownerBookingTag(bookingId),
    );
  }
  // Also remove the unscoped notification left by the previous app build.
  await notifications.cancel(
    id: _ownerBookingAlarmNotificationId,
    tag: _ownerBookingAlarmNotificationTag,
  );
  if (kIsWeb) {
    return;
  }
  try {
    final activeNotifications = await notifications.getActiveNotifications();
    for (final notification in activeNotifications) {
      final payload = _decodeNotificationPayloadValue(notification.payload);
      final isOwnerAlert =
          notification.tag == _ownerBookingAlarmNotificationTag ||
          (bookingId == null
              ? notification.channelId == _ownerBookingRequestChannel.id
              : notification.tag == _ownerBookingTag(bookingId)) ||
          _legacyOwnerBookingRequestChannelIds.contains(
            notification.channelId,
          ) ||
          (_isOwnerBookingRequestChannel(payload['channel']) &&
              (bookingId == null || payload['bookingId'] == bookingId));
      if (isOwnerAlert && notification.id != null) {
        await notifications.cancel(id: notification.id!, tag: notification.tag);
      }
    }
  } catch (_) {
    // The known tagged alarm was already cancelled above. Enumeration is a
    // best-effort cleanup for alerts posted by an older app build.
  }
}

/// Makes the notification action isolate safe for an App-Check-protected
/// callable. The foreground app already goes through FirebaseBootstrap; a
/// notification action runs in a separate isolate and must prepare Firebase
/// for itself before changing a booking.
Future<bool> _prepareBackgroundBookingActionFirebase() async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
  try {
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kReleaseMode
          ? const AndroidPlayIntegrityProvider()
          : const AndroidDebugProvider(),
      providerApple: kReleaseMode
          ? const AppleAppAttestWithDeviceCheckFallbackProvider()
          : const AppleDebugProvider(),
    );
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Background App Check activation skipped: $error');
    }
  }
  try {
    await FirebaseAppCheck.instance.getToken().timeout(
      const Duration(seconds: 8),
    );
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Background App Check token failed: $error');
    }
    return false;
  }

  if (FirebaseAuth.instance.currentUser != null) {
    return true;
  }
  try {
    final restoredUser = await FirebaseAuth.instance
        .authStateChanges()
        .firstWhere((user) => user != null)
        .timeout(_backgroundBookingActionAuthTimeout);
    return restoredUser != null;
  } on TimeoutException {
    return false;
  }
}

@pragma('vm:entry-point')
void notificationActionBackgroundHandler(NotificationResponse response) async {
  final actionId = response.actionId?.trim() ?? '';
  if (actionId != _acceptInstantBookingNotificationAction &&
      actionId != _rejectInstantBookingNotificationAction) {
    return;
  }
  final payload = _decodeNotificationPayloadValue(response.payload);
  final bookingId = payload['bookingId']?.toString().trim() ?? '';
  if (bookingId.isEmpty) {
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  final notifications = FlutterLocalNotificationsPlugin();
  try {
    await performOwnerBookingDecision(
      bookingId: bookingId,
      status: actionId == _acceptInstantBookingNotificationAction
          ? BookingStatus.confirmed.name
          : BookingStatus.rejected.name,
      cancel: () async {
        await _initializeBackgroundNotifications(notifications);
        await _cancelOwnerBookingNotifications(
          notifications,
          bookingId: bookingId,
        );
      },
      submit: () => _submitBackgroundOwnerBookingDecision(
        bookingId,
        actionId == _acceptInstantBookingNotificationAction
            ? BookingStatus.confirmed.name
            : BookingStatus.rejected.name,
      ),
    );
  } catch (error) {
    // The owner already made a decision. Never restart the continuous alarm
    // merely because the background request failed. Retain retryable decisions
    // and display a quiet status instead of pretending they were accepted.
    await _showOwnerDecisionFailure(bookingId, error);
    if (kDebugMode) {
      debugPrint('Instant booking notification action failed: $error');
    }
  }
}

Future<void> _submitBackgroundOwnerBookingDecision(
  String bookingId,
  String status,
) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      if (!await _prepareBackgroundBookingActionFirebase()) {
        throw StateError('Could not restore the owner session.');
      }
      await FirebaseFunctions.instanceFor(region: firebaseFunctionsRegion)
          .httpsCallable(
            'updateBookingStatus',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 8)),
          )
          .call<void>({
            'bookingId': bookingId,
            'status': status,
            'cancellationReason': '',
            'actionSource': 'notification_action',
          });
      await _clearOwnerDecisionFeedback(bookingId);
      return;
    } on FirebaseFunctionsException catch (error) {
      if (!isRetryableOwnerDecisionErrorCode(error.code) || attempt == 1) {
        rethrow;
      }
    } catch (_) {
      if (attempt == 1) rethrow;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

Future<void> _initializeBackgroundNotifications(
  FlutterLocalNotificationsPlugin notifications,
) async {
  await notifications.initialize(
    settings: InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories:
            _ownerBookingRequestDarwinNotificationCategories,
      ),
    ),
    onDidReceiveBackgroundNotificationResponse:
        notificationActionBackgroundHandler,
  );
}

Future<bool> _showUnansweredOwnerBookingAlert({
  required FlutterLocalNotificationsPlugin notifications,
  required String bookingId,
  required DateTime deadline,
  required String title,
  required String body,
  required Map<String, dynamic> data,
  bool Function()? isStillPending,
}) => OwnerBookingAlertState().showIfUnanswered(
  bookingId: bookingId,
  deadline: deadline,
  isStillPending: isStillPending,
  cancel: () =>
      _cancelOwnerBookingNotifications(notifications, bookingId: bookingId),
  show: (remainingMillis) => notifications.show(
    id: ownerBookingNotificationId(bookingId),
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _ownerBookingRequestChannel.id,
        _ownerBookingRequestChannel.name,
        channelDescription: _ownerBookingRequestChannel.description,
        importance: Importance.max,
        priority: Priority.max,
        icon: '@mipmap/ic_launcher',
        category: AndroidNotificationCategory.alarm,
        ongoing: true,
        autoCancel: false,
        enableVibration: true,
        visibility: NotificationVisibility.public,
        // Without this the alert is only a heads-up banner, which a locked or
        // pocketed phone never surfaces. A full-screen intent wakes the screen
        // and shows the request the way an incoming call does. Android 14 and
        // later ignore it unless the owner has granted the permission, which
        // `ownerAlertReadiness` reports and `openFullScreenIntentSettings`
        // sends them to.
        fullScreenIntent: true,
        tag: _ownerBookingTag(bookingId),
        timeoutAfter: remainingMillis,
        sound: const RawResourceAndroidNotificationSound(
          'owner_booking_request',
        ),
        // Pre-Oreo devices take the audio stream from the notification
        // rather than the channel.
        audioAttributesUsage: AudioAttributesUsage.alarm,
        additionalFlags: Int32List.fromList([
          _androidInsistentNotificationFlag,
        ]),
        actions: _ownerInstantBookingNotificationActions,
      ),
      iOS: const DarwinNotificationDetails(
        sound: 'owner_booking_request.wav',
        categoryIdentifier: _ownerBookingRequestDarwinCategory,
        interruptionLevel: InterruptionLevel.active,
      ),
      macOS: const DarwinNotificationDetails(
        sound: 'owner_booking_request.wav',
        categoryIdentifier: _ownerBookingRequestDarwinCategory,
      ),
    ),
    payload: _notificationPayload({
      ...data,
      'channel': _ownerBookingRequestChannel.id,
    }),
  ),
);

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (kIsWeb) return;
  final bookingId = message.data['bookingId']?.toString().trim() ?? '';
  final notifications = FlutterLocalNotificationsPlugin();
  if (_isOwnerBookingResolution(message.data)) {
    if (bookingId.isEmpty) return;
    await _persistOwnerAlertSuppression(bookingId);
    await _clearPendingOwnerBookingAction(bookingId);
    await _initializeBackgroundNotifications(notifications);
    await _cancelOwnerBookingNotifications(notifications, bookingId: bookingId);
    await _clearOwnerDecisionFeedback(bookingId);
    return;
  }
  if (defaultTargetPlatform != TargetPlatform.android ||
      !_isOwnerBookingRequestChannel(message.data['channel']) ||
      bookingId.isEmpty) {
    return;
  }
  final deadline = _ownerAlertMessageDeadline(message);
  if (deadline == null) return;
  if (!await OwnerAlertPreferences().isEnabled()) {
    return;
  }
  await _initializeBackgroundNotifications(notifications);
  await notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(_ownerBookingRequestChannel);
  if (await OwnerBookingAlertState().isStopped(bookingId)) {
    await _cancelOwnerBookingNotifications(notifications, bookingId: bookingId);
    final decisions = OwnerBookingDecisionStore();
    for (final entry in await decisions.pending()) {
      final parts = entry.split('|');
      if (parts.length != 3 || parts[0] != bookingId) continue;
      if (!DateTime.now().isBefore(deadline)) {
        await decisions.clear(bookingId);
        break;
      }
      try {
        await _submitBackgroundOwnerBookingDecision(bookingId, parts[1]);
        await decisions.clear(bookingId);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Background booking decision retry failed: $error');
        }
      }
      break;
    }
    return;
  }
  await _showUnansweredOwnerBookingAlert(
    notifications: notifications,
    bookingId: bookingId,
    deadline: deadline,
    title:
        message.data['notificationTitle']?.toString() ?? 'New booking request',
    body:
        message.data['notificationBody']?.toString() ??
        'A customer is waiting for accept or reject.',
    data: message.data,
  );
}

@visibleForTesting
bool shouldRequestPushPermission(
  AuthorizationStatus status, {
  required bool isAndroid,
  required bool hasRequestedOnAndroid,
}) {
  if (status == AuthorizationStatus.notDetermined) {
    return true;
  }
  return isAndroid &&
      status == AuthorizationStatus.denied &&
      !hasRequestedOnAndroid;
}

@visibleForTesting
bool canRegisterForPushNotifications(AuthorizationStatus status) {
  return status == AuthorizationStatus.authorized ||
      status == AuthorizationStatus.provisional;
}

@visibleForTesting
UserRole resolveLaunchRole({
  required bool hasRegisteredSalon,
  required List<UserRole> roles,
  UserRole? localRole,
  UserRole? remoteRole,
  UserRole? authoritativeRole,
}) {
  if (hasRegisteredSalon) {
    return UserRole.owner;
  }
  if (authoritativeRole == UserRole.customer ||
      authoritativeRole == UserRole.owner) {
    return authoritativeRole!;
  }
  final publicRoles = roles
      .where((role) => role != UserRole.barber)
      .toList(growable: false);
  if (localRole != null && publicRoles.contains(localRole)) {
    return localRole;
  }
  if (remoteRole != null && publicRoles.contains(remoteRole)) {
    return remoteRole;
  }
  return publicRoles.firstOrNull ?? UserRole.customer;
}

@visibleForTesting
UserRole? cachedRoleForAccount({
  required UserRole? role,
  required String? cachedAccountId,
  required String currentAccountId,
}) {
  return cachedAccountId == currentAccountId ? role : null;
}

@visibleForTesting
bool isRetryableCallableErrorCode(String code) {
  return const <String>{
    'aborted',
    'cancelled',
    'deadline-exceeded',
    'internal',
    'resource-exhausted',
    'unavailable',
    'unknown',
  }.contains(code.trim().toLowerCase());
}

@visibleForTesting
bool isRetryableDiscountOfferErrorCode(String code) {
  return const <String>{
    'deadline-exceeded',
    'internal',
    'unavailable',
    'unknown',
  }.contains(code.trim().toLowerCase());
}

@visibleForTesting
bool isRetryableOwnerDecisionErrorCode(String code) =>
    isRetryableCallableErrorCode(code);

class AppState extends ChangeNotifier {
  final List<Salon> _salons = [];
  final List<SalonService> _ownerDraftServices = [];
  final List<Barber> _barbers = [];
  final List<Booking> _bookings = [];
  final List<JoinRequest> _joinRequests = [];
  final List<SalonFeedback> _salonFeedback = [];
  final List<CustomerSalonRating> _customerSalonRatings = [];
  final Set<String> _occupiedSlotKeys = {};
  final Map<String, List<TimeSlot>> _slotCache = {};
  final Map<String, Set<String>> _seenNotificationKeys = {};
  final Map<String, Set<String>> _dismissedNotificationKeys = {};
  final Map<String, DateTime> _notificationsReadAt = {};
  final Set<String> _notificationPreferencesReadyViewers = {};
  final Map<String, UserRole> _mockPhoneRoles = {};
  final Map<String, String> _mockPhoneAccountIds = {};
  final Map<String, String> _verifiedOwnerPhones = {};
  final Map<String, String> _mockCustomerNames = {};
  final Set<String> _mockRegisteredAccountIds = {};
  final Map<String, ReferralCodes> _mockReferralCodes = {};
  final Map<String, ({String ownerUid, UserRole targetRole})>
  _mockReferralCodeRegistry = {};
  final Map<String, String> _pendingCustomerCancellations = {};
  String? _pendingMockCustomerPhone;
  UserAccount? _pendingMockGoogleCustomer;
  DateTime? _slotCacheCreatedAt;
  String _supportPhone = _defaultSupportPhone;

  int _bookingCounter = 100;
  int _serviceCounter = 30;
  int _barberCounter = 20;
  int _accountCounter = 10;
  UserAccount? _customerAccount;
  UserAccount? _ownerAccount;
  UserAccount? _barberAccount;
  bool _ownerProfileCompleted = false;
  String? _currentJoinRequestId;
  String? _currentBarberId;
  UserRole? _activeRole;
  String? _lastSyncError;
  String _ownerPaymentUpiId = '';
  String _ownerPaymentQrCodeUrl = '';
  bool _isSaving = false;
  bool _isInstantBookingSaving = false;
  bool _referralOnboardingRequired = false;
  int _discountOfferRefreshVersion = 0;
  int _referralCodeCounter = 1;
  int _mockDiscountPercent = 0;
  int _mockMaximumDiscountAmount = 0;
  String _mockDiscountSalonId = '';
  final List<_MockVisibleCheckoutDiscountCampaign>
  _mockVisibleDiscountCampaigns = [];
  final Map<String, DiscountQuote> _mockLockedDiscountQuotes = {};
  final Map<String, CompletedBookingUpiPaymentDetails>
  _completedBookingUpiPaymentDetails = {};
  ProinWalletSummary _customerProinWallet = const ProinWalletSummary();
  final Map<String, ProinWalletSummary> _salonProinWallets = {};
  final List<ProinActivityEntry> _customerProinActivity = [];
  AppNotificationNavigation? _pendingNotificationNavigation;
  String _pendingCompletionReceiptBookingId = '';
  Future<void> _rolePersistenceQueue = Future<void>.value();
  Timer? _customerInstantExpiryTimer;
  final Set<String> _locallyExpiredInstantBookingIds = <String>{};

  AppState({bool restoreActiveRole = true}) {
    if (restoreActiveRole) {
      unawaited(_restoreActiveRole());
    }
  }

  bool get usesFirebase => false;

  int get discountOfferRefreshVersion => _discountOfferRefreshVersion;

  bool get isRestoringSession => false;

  UserRole? get activeRole => _activeRole;

  String? get lastSyncError => _lastSyncError;

  bool get isSaving => _isSaving;
  bool get isInstantBookingSaving => _isInstantBookingSaving;

  String get ownerPaymentUpiId => _ownerPaymentUpiId;

  String get ownerPaymentQrCodeUrl => _ownerPaymentQrCodeUrl;

  bool get referralOnboardingRequired => _referralOnboardingRequired;

  Stream<String> get autoVerifiedPhoneNumbers => const Stream.empty();

  bool isPhoneAutoVerified(String phone) => false;

  bool isOwnerPhoneLoginEnabled(String phone) =>
      _ownerAccount != null &&
      (_verifiedOwnerPhones[_ownerAccount!.id] == normalizePhone(phone) ||
          (_ownerAccount!.provider == LoginProvider.phone &&
              normalizePhone(_ownerAccount!.contact) == normalizePhone(phone)));

  Future<void> linkOwnerPhoneLogin({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final owner = _ownerAccount;
    if (owner == null || _activeRole != UserRole.owner) {
      throw StateError('Sign in as the salon owner first.');
    }
    if (!RegExp(r'^\d{6}$').hasMatch(smsCode)) {
      throw StateError('Enter the 6-digit OTP.');
    }
    _claimMockPhoneRole(
      normalizePhone(phone),
      UserRole.owner,
      accountId: owner.id,
    );
    _verifiedOwnerPhones[owner.id] = normalizePhone(phone);
    notifyListeners();
  }

  bool notificationPreferencesReady(UserRole role) =>
      !usesFirebase ||
      _notificationPreferencesReadyViewers.contains(
        _notificationViewerKey(role),
      );

  bool isBookingStatusUpdatePending(String bookingId) => false;

  void silenceOwnerBookingAlert(String bookingId) {}

  AppNotificationNavigation? takePendingNotificationNavigation() {
    final navigation = _pendingNotificationNavigation;
    _pendingNotificationNavigation = null;
    return navigation;
  }

  String get pendingCompletionReceiptBookingId =>
      _pendingCompletionReceiptBookingId;

  void queueCompletionReceipt(String bookingId) {
    final normalizedBookingId = bookingId.trim();
    if (normalizedBookingId.isEmpty) return;
    _pendingCompletionReceiptBookingId = normalizedBookingId;
    notifyListeners();
  }

  void clearPendingCompletionReceipt(String bookingId) {
    if (_pendingCompletionReceiptBookingId != bookingId.trim()) return;
    _pendingCompletionReceiptBookingId = '';
  }

  void queueNotificationNavigation(
    AppNotificationDestination destination, {
    String bookingId = '',
  }) {
    _pendingNotificationNavigation = AppNotificationNavigation(
      destination: destination,
      bookingId: bookingId,
    );
    notifyListeners();
  }

  String get supportPhone => _supportPhone;

  List<Salon> get salons => List.unmodifiable(_salons);

  List<Salon> get discoverableSalons => List.unmodifiable(_salons);

  List<Barber> get barbers => List.unmodifiable(_barbers);

  List<Booking> get bookings => List.unmodifiable(_bookings);

  List<JoinRequest> get joinRequests => List.unmodifiable(_joinRequests);

  List<SalonFeedback> get customerSalonFeedback =>
      List.unmodifiable(_salonFeedback);

  List<CustomerSalonRating> get customerSalonRatings =>
      List.unmodifiable(_customerSalonRatings);

  UserAccount? get customerAccount => _customerAccount;

  ProinWalletSummary get customerProinWallet => _customerProinWallet;

  ProinWalletSummary salonProinWallet(String salonId) =>
      _salonProinWallets[salonId] ??
      const ProinWalletSummary(creditLimitProin: 1000, spendableProin: 1000);

  List<ProinActivityEntry> get customerProinActivity =>
      List.unmodifiable(_customerProinActivity);

  UserAccount? get ownerAccount => _ownerAccount;

  UserAccount? get barberAccount => _barberAccount;

  bool get ownerProfileCompleted => _ownerProfileCompleted;

  /// Whether the salon list has arrived at least once. Until it has, an empty
  /// list means "not loaded yet", not "this owner has no salon" — the two
  /// look identical and acting on the wrong one strands the owner on the
  /// registration screen.
  bool get salonsLoaded => true;

  List<String> _normalizedDiscountServiceIds(Iterable<String> serviceIds) {
    final ids =
        serviceIds
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort();
    return ids;
  }

  int _mockServiceTotal(String salonId, Iterable<String> serviceIds) {
    return _normalizedDiscountServiceIds(serviceIds)
        .map((id) => getService(salonId, id)?.price ?? 0)
        .fold<int>(0, (total, price) => total + price);
  }

  bool _mockVisibleCampaignMatches(
    _MockVisibleCheckoutDiscountCampaign campaign,
    String salonId,
    Iterable<String> serviceIds,
  ) {
    final ids = _normalizedDiscountServiceIds(serviceIds);
    if (!campaign.active) return false;
    if (campaign.salonId.isNotEmpty && campaign.salonId != salonId) {
      return false;
    }
    if (campaign.serviceIds.isEmpty) return ids.isNotEmpty;
    return ids.any(campaign.serviceIds.contains);
  }

  DiscountQuote _mockCampaignQuote({
    required String quotePrefix,
    required String campaignId,
    required String campaignName,
    required String salonId,
    required Iterable<String> serviceIds,
    String discountType = 'percent',
    double discountPercent = 0,
    int fixedDiscountAmount = 0,
    int maximumDiscountAmount = 0,
    Iterable<String> eligibleServiceIds = const [],
    bool voucherApplied = false,
    String voucherMaskedCode = '',
    bool lockQuote = true,
  }) {
    final ids = _normalizedDiscountServiceIds(serviceIds);
    final eligibleIds = eligibleServiceIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final originalAmount = _mockServiceTotal(salonId, ids);
    final discountBaseAmount = _mockServiceTotal(
      salonId,
      eligibleIds.isEmpty ? ids : ids.where(eligibleIds.contains),
    );
    if (campaignId.isEmpty ||
        campaignName.isEmpty ||
        originalAmount <= 0 ||
        discountBaseAmount <= 0) {
      return DiscountQuote(originalAmount: originalAmount);
    }
    var discountAmount = discountType == 'fixed'
        ? fixedDiscountAmount
        : (discountBaseAmount * discountPercent / 100).floor();
    if (maximumDiscountAmount > 0 && discountAmount > maximumDiscountAmount) {
      discountAmount = maximumDiscountAmount;
    }
    if (discountAmount > discountBaseAmount) {
      discountAmount = discountBaseAmount;
    }
    if (discountAmount < 0) {
      discountAmount = 0;
    }
    if (discountAmount <= 0) {
      return DiscountQuote(originalAmount: originalAmount);
    }
    final pritzePayout = discountAmount * 2;
    final quote = DiscountQuote(
      quoteId: '$quotePrefix-${DateTime.now().microsecondsSinceEpoch}',
      campaignId: campaignId,
      campaignName: campaignName,
      discountType: discountType,
      discountPercent: discountPercent,
      fixedDiscountAmount: fixedDiscountAmount,
      voucherApplied: voucherApplied,
      voucherMaskedCode: voucherMaskedCode,
      originalAmount: originalAmount,
      discountBaseAmount: discountBaseAmount,
      discountAmount: discountAmount,
      customerPayableAmount: originalAmount - discountAmount,
      pritzePayoutAmount: pritzePayout,
      cashbackProinAmount: 0,
      cashbackValidityDays: 0,
      salonTotalEarning: originalAmount - discountAmount + pritzePayout,
    );
    if (lockQuote && quote.quoteId.isNotEmpty) {
      _mockLockedDiscountQuotes[quote.quoteId] = quote;
    }
    return quote;
  }

  Future<DiscountQuote> getDiscountQuote({
    required String salonId,
    required Iterable<String> serviceIds,
    bool lockQuote = true,
  }) async {
    final ids = _normalizedDiscountServiceIds(serviceIds);
    final originalAmount = _mockServiceTotal(salonId, ids);
    if (lockQuote) {
      return DiscountQuote(originalAmount: originalAmount);
    }
    if (_activeRole != UserRole.customer ||
        _customerAccount == null ||
        _mockDiscountPercent <= 0 ||
        (_mockDiscountSalonId.isNotEmpty && _mockDiscountSalonId != salonId)) {
      return DiscountQuote(originalAmount: originalAmount);
    }
    return _mockCampaignQuote(
      quotePrefix: 'mock-quote',
      campaignId: 'mock-campaign',
      campaignName: 'Pritze offer',
      salonId: salonId,
      serviceIds: ids,
      discountPercent: _mockDiscountPercent.toDouble(),
      maximumDiscountAmount: _mockMaximumDiscountAmount,
      lockQuote: lockQuote,
    );
  }

  Future<CompletedBookingUpiPaymentDetails>
  getCompletedBookingUpiPaymentDetails(String bookingId) async {
    final normalizedBookingId = bookingId.trim();
    final cached = _completedBookingUpiPaymentDetails[normalizedBookingId];
    if (cached != null) return cached;
    final booking = _bookings
        .where((item) => item.id == normalizedBookingId)
        .firstOrNull;
    if (booking == null || booking.status != BookingStatus.completed) {
      throw StateError('This completed booking could not be found.');
    }
    final details = CompletedBookingUpiPaymentDetails(
      bookingId: booking.id,
      salonId: booking.salonId,
      salonName: getSalon(booking.salonId)?.name ?? 'Salon',
      amountInr: booking.customerPayableAmount,
    );
    _completedBookingUpiPaymentDetails[normalizedBookingId] = details;
    return details;
  }

  Future<bool> hasOpenedUpiPayment(String bookingId) async {
    final normalizedBookingId = bookingId.trim();
    if (normalizedBookingId.isEmpty) return false;
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(
          '$_upiHandoffOpenedPreferencePrefix$normalizedBookingId',
        ) ??
        false;
  }

  Future<void> markUpiPaymentOpened(String bookingId) async {
    final normalizedBookingId = bookingId.trim();
    if (normalizedBookingId.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      '$_upiHandoffOpenedPreferencePrefix$normalizedBookingId',
      true,
    );
  }

  Future<List<CheckoutDiscountOffer>> listCheckoutDiscountOffers({
    required String salonId,
    required Iterable<String> serviceIds,
    bool prefetchOnly = false,
  }) async {
    final ids = _normalizedDiscountServiceIds(serviceIds);
    if (_activeRole != UserRole.customer ||
        _customerAccount == null ||
        ids.isEmpty) {
      return const [];
    }
    final offers = _mockVisibleDiscountCampaigns
        .where(
          (campaign) => _mockVisibleCampaignMatches(campaign, salonId, ids),
        )
        .map((campaign) {
          final quote = _mockCampaignQuote(
            quotePrefix: 'mock-visible-offer',
            campaignId: campaign.campaignId,
            campaignName: campaign.campaignName,
            salonId: salonId,
            serviceIds: ids,
            discountType: campaign.discountType,
            discountPercent: campaign.discountPercent,
            fixedDiscountAmount: campaign.fixedDiscountAmount,
            maximumDiscountAmount: campaign.maximumDiscountAmount,
            eligibleServiceIds: campaign.serviceIds,
            voucherApplied: true,
            voucherMaskedCode: campaign.voucherMaskedCode,
            lockQuote: false,
          );
          return CheckoutDiscountOffer(
            campaignId: quote.campaignId,
            campaignName: quote.campaignName,
            discountType: quote.discountType,
            discountPercent: quote.discountPercent,
            fixedDiscountAmount: quote.fixedDiscountAmount,
            voucherMaskedCode: quote.voucherMaskedCode,
            originalAmount: quote.originalAmount,
            discountAmount: quote.discountAmount,
            customerPayableAmount: quote.customerPayableAmount,
            cashbackProinAmount: quote.cashbackProinAmount,
            cashbackValidityDays: quote.cashbackValidityDays,
            campaignEndsAt: quote.campaignEndsAt,
          );
        })
        .where((offer) => offer.hasSaving)
        .toList();
    if (_mockDiscountPercent > 0 &&
        (_mockDiscountSalonId.isEmpty || _mockDiscountSalonId == salonId)) {
      final quote = _mockCampaignQuote(
        quotePrefix: 'mock-campaign-preview',
        campaignId: 'mock-campaign',
        campaignName: 'Pritze offer',
        salonId: salonId,
        serviceIds: ids,
        discountPercent: _mockDiscountPercent.toDouble(),
        maximumDiscountAmount: _mockMaximumDiscountAmount,
        lockQuote: false,
      );
      if (quote.hasDiscount) {
        offers.add(
          CheckoutDiscountOffer(
            campaignId: quote.campaignId,
            campaignName: quote.campaignName,
            discountType: quote.discountType,
            discountPercent: quote.discountPercent,
            fixedDiscountAmount: quote.fixedDiscountAmount,
            voucherMaskedCode: '',
            originalAmount: quote.originalAmount,
            discountAmount: quote.discountAmount,
            customerPayableAmount: quote.customerPayableAmount,
            cashbackProinAmount: quote.cashbackProinAmount,
            cashbackValidityDays: quote.cashbackValidityDays,
          ),
        );
      }
    }
    offers.sort((left, right) {
      final discountCompare = right.discountAmount.compareTo(
        left.discountAmount,
      );
      if (discountCompare != 0) return discountCompare;
      return left.campaignName.compareTo(right.campaignName);
    });
    return offers;
  }

  Future<CheckoutCouponResult> applyVisibleCheckoutDiscount({
    required String salonId,
    required Iterable<String> serviceIds,
    required String campaignId,
  }) async {
    final ids = _normalizedDiscountServiceIds(serviceIds);
    if (_activeRole != UserRole.customer ||
        _customerAccount == null ||
        ids.isEmpty) {
      throw StateError('Sign in as a customer before applying a discount.');
    }
    if (campaignId == 'mock-campaign' &&
        _mockDiscountPercent > 0 &&
        (_mockDiscountSalonId.isEmpty || _mockDiscountSalonId == salonId)) {
      final quote = _mockCampaignQuote(
        quotePrefix: 'mock-selected-quote',
        campaignId: 'mock-campaign',
        campaignName: 'Pritze offer',
        salonId: salonId,
        serviceIds: ids,
        discountPercent: _mockDiscountPercent.toDouble(),
        maximumDiscountAmount: _mockMaximumDiscountAmount,
      );
      return CheckoutCouponResult(
        benefitType: 'discount',
        message: _discountAppliedMessage(quote),
        discountQuote: quote,
      );
    }
    final campaign = _mockVisibleDiscountCampaigns
        .where(
          (item) =>
              item.campaignId == campaignId &&
              _mockVisibleCampaignMatches(item, salonId, ids),
        )
        .firstOrNull;
    if (campaign == null) {
      throw StateError('This offer is no longer available for this booking.');
    }
    final quote = _mockCampaignQuote(
      quotePrefix: 'mock-visible-quote',
      campaignId: campaign.campaignId,
      campaignName: campaign.campaignName,
      salonId: salonId,
      serviceIds: ids,
      discountType: campaign.discountType,
      discountPercent: campaign.discountPercent,
      fixedDiscountAmount: campaign.fixedDiscountAmount,
      maximumDiscountAmount: campaign.maximumDiscountAmount,
      eligibleServiceIds: campaign.serviceIds,
      voucherApplied: true,
      voucherMaskedCode: campaign.voucherMaskedCode,
    );
    if (!quote.hasDiscount) {
      throw StateError('This offer is no longer available for this booking.');
    }
    return CheckoutCouponResult(
      benefitType: 'discount',
      message: _discountAppliedMessage(quote),
      discountQuote: quote,
    );
  }

  Future<ProinWalletSummary> refreshCustomerProinWallet() async {
    return _customerProinWallet;
  }

  Future<ProinWalletSummary> refreshSalonProinWallet(String salonId) async {
    return salonProinWallet(salonId);
  }

  Future<ProinCouponClaimResult> claimSalonProinCoupon({
    required String salonId,
    required String code,
  }) async {
    final normalizedSalonId = salonId.trim();
    final normalized = code.trim().toUpperCase();
    if (normalizedSalonId.isEmpty ||
        _activeRole != UserRole.owner ||
        ownerSalonOrNull?.id != normalizedSalonId) {
      throw StateError('Sign in as this salon owner to apply a coupon.');
    }
    if (!RegExp(r'^(?=.*[A-Z])[A-Z\d]{4,20}$').hasMatch(normalized)) {
      throw StateError('Enter a 4-20 character coupon code with a letter.');
    }
    final current = salonProinWallet(normalizedSalonId);
    final expiry = DateTime.now().add(const Duration(days: 30));
    final updated = ProinWalletSummary(
      availableProin: current.availableProin + 100,
      reservedProin: current.reservedProin,
      creditLimitProin: current.creditLimitProin,
      spendableProin: current.availableProin + 100 + current.creditLimitProin,
      lifetimeGrantedProin: current.lifetimeGrantedProin + 100,
      lifetimeRedeemedProin: current.lifetimeRedeemedProin,
      lifetimeExpiredProin: current.lifetimeExpiredProin,
      nextExpiryAt: current.nextExpiryAt ?? expiry,
      expiringLots: [
        ...current.expiringLots,
        ProinExpiringLot(
          amountProin: 100,
          expiresAt: expiry,
          sourceType: 'coupon',
        ),
      ]..sort((left, right) => left.expiresAt.compareTo(right.expiresAt)),
    );
    _salonProinWallets[normalizedSalonId] = updated;
    notifyListeners();
    return ProinCouponClaimResult(
      amountProin: 100,
      availableProin: updated.availableProin,
      expiresAt: expiry,
    );
  }

  Future<List<ProinActivityEntry>> refreshCustomerProinActivity() async {
    return customerProinActivity;
  }

  Future<ProinBookingQuote> getProinBookingQuote({
    required String salonId,
    required Iterable<String> serviceIds,
    required DiscountQuote discountQuote,
  }) async {
    final payableBeforeProin = discountQuote.customerPayableAmount;
    final maximum = <int>[
      _customerProinWallet.availableProin,
      (payableBeforeProin * 0.25).floor(),
      250,
    ].reduce((left, right) => left < right ? left : right);
    return ProinBookingQuote(
      availableProin: _customerProinWallet.availableProin,
      maximumRedeemableProin: maximum,
      payableBeforeProin: payableBeforeProin,
      customerPayableAmount: payableBeforeProin - maximum,
    );
  }

  Future<ProinCouponClaimResult> claimProinCoupon(String code) async {
    final normalized = code.trim().toUpperCase();
    if (!RegExp(r'^(?=.*[A-Z])[A-Z\d]{4,20}$').hasMatch(normalized)) {
      throw StateError('Enter a 4-20 character coupon code with a letter.');
    }
    final expiry = DateTime.now().add(const Duration(days: 30));
    _customerProinWallet = ProinWalletSummary(
      availableProin: _customerProinWallet.availableProin + 100,
      reservedProin: _customerProinWallet.reservedProin,
      lifetimeGrantedProin: _customerProinWallet.lifetimeGrantedProin + 100,
      lifetimeRedeemedProin: _customerProinWallet.lifetimeRedeemedProin,
      lifetimeExpiredProin: _customerProinWallet.lifetimeExpiredProin,
      nextExpiryAt: _customerProinWallet.nextExpiryAt ?? expiry,
      expiringLots: [
        ..._customerProinWallet.expiringLots,
        ProinExpiringLot(
          amountProin: 100,
          expiresAt: expiry,
          sourceType: 'coupon',
        ),
      ]..sort((left, right) => left.expiresAt.compareTo(right.expiresAt)),
    );
    _customerProinActivity.insert(
      0,
      ProinActivityEntry(
        transactionId: 'mock-coupon-${DateTime.now().microsecondsSinceEpoch}',
        type: 'grant',
        direction: 'credit',
        amountProin: 100,
        sourceType: 'coupon',
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
    return ProinCouponClaimResult(
      amountProin: 100,
      availableProin: _customerProinWallet.availableProin,
      expiresAt: expiry,
    );
  }

  Future<CheckoutCouponResult> applyCheckoutCoupon({
    required String salonId,
    required Iterable<String> serviceIds,
    required String code,
  }) async {
    final normalized = code.trim().toUpperCase();
    if (!RegExp(r'^(?=.*[A-Z])[A-Z\d]{4,20}$').hasMatch(normalized)) {
      throw StateError('Enter a 4-20 character coupon code with a letter.');
    }
    if (normalized.startsWith('PROIN')) {
      final claim = await claimProinCoupon(normalized);
      return CheckoutCouponResult(
        benefitType: 'proin',
        message: '${claim.amountProin} Proin added to your account.',
        amountProin: claim.amountProin,
        alreadyClaimed: claim.alreadyClaimed,
      );
    }
    final quote = _mockCampaignQuote(
      quotePrefix: 'mock-voucher',
      campaignId: 'mock-voucher-campaign',
      campaignName: 'Voucher offer',
      salonId: salonId,
      serviceIds: serviceIds,
      discountPercent: 10,
      voucherApplied: true,
      voucherMaskedCode: normalized,
    );
    return CheckoutCouponResult(
      benefitType: 'discount',
      message: _discountAppliedMessage(quote, label: 'Voucher'),
      discountQuote: quote,
    );
  }

  String _discountAppliedMessage(DiscountQuote quote, {String? label}) {
    final cashback = quote.cashbackProinAmount;
    final displayLabel = label ?? quote.campaignName;
    if (cashback > 0) {
      return '$displayLabel applied. You save ₹${quote.discountAmount} now and earn $cashback Proin after the service.';
    }
    return '$displayLabel applied. You save ₹${quote.discountAmount}.';
  }

  @visibleForTesting
  void configureMockDiscountCampaign({
    required int discountPercent,
    int maximumDiscountAmount = 0,
    String salonId = '',
  }) {
    _mockDiscountPercent = discountPercent.clamp(0, 100);
    _mockMaximumDiscountAmount = maximumDiscountAmount.clamp(0, 1000000);
    _mockDiscountSalonId = salonId;
  }

  @visibleForTesting
  void configureMockVisibleCheckoutDiscountOffer({
    required String campaignId,
    String campaignName = 'Pritze checkout offer',
    String salonId = '',
    Iterable<String> serviceIds = const [],
    String discountType = 'percent',
    int discountPercent = 10,
    int fixedDiscountAmount = 0,
    int maximumDiscountAmount = 0,
    String voucherMaskedCode = '••••',
    bool active = true,
  }) {
    final normalizedCampaignId = campaignId.trim();
    if (normalizedCampaignId.isEmpty) {
      throw ArgumentError.value(campaignId, 'campaignId', 'cannot be empty');
    }
    _mockVisibleDiscountCampaigns.removeWhere(
      (campaign) => campaign.campaignId == normalizedCampaignId,
    );
    _mockVisibleDiscountCampaigns.add(
      _MockVisibleCheckoutDiscountCampaign(
        campaignId: normalizedCampaignId,
        campaignName: campaignName.trim().isEmpty
            ? 'Pritze checkout offer'
            : campaignName.trim(),
        salonId: salonId.trim(),
        serviceIds: _normalizedDiscountServiceIds(serviceIds).toSet(),
        discountType: discountType == 'fixed' ? 'fixed' : 'percent',
        discountPercent: discountPercent.clamp(0, 100).toDouble(),
        fixedDiscountAmount: fixedDiscountAmount.clamp(0, 1000000),
        maximumDiscountAmount: maximumDiscountAmount.clamp(0, 1000000),
        voucherMaskedCode: voucherMaskedCode.trim().isEmpty
            ? '••••'
            : voucherMaskedCode.trim(),
        active: active,
      ),
    );
  }

  Future<ReferralCodes> ensureReferralCodes() async {
    final role = _activeRole;
    final account = role == UserRole.customer
        ? _customerAccount
        : role == UserRole.owner
        ? _ownerAccount
        : null;
    if (account == null ||
        (role != UserRole.customer && role != UserRole.owner)) {
      throw StateError('Sign in before opening referrals.');
    }
    final existing = _mockReferralCodes[account.id];
    if (existing != null) {
      return existing;
    }

    final customerCode = _newMockReferralCode();
    final salonCode = role == UserRole.owner ? _newMockReferralCode() : '';
    final codes = ReferralCodes(
      customerInviteCode: customerCode,
      salonInviteCode: salonCode,
    );
    _mockReferralCodes[account.id] = codes;
    _mockReferralCodeRegistry[customerCode] = (
      ownerUid: account.id,
      targetRole: UserRole.customer,
    );
    if (salonCode.isNotEmpty) {
      _mockReferralCodeRegistry[salonCode] = (
        ownerUid: account.id,
        targetRole: UserRole.owner,
      );
    }
    notifyListeners();
    return codes;
  }

  Future<ReferralSummary> getReferralSummary() async {
    if (_activeRole == null) {
      throw StateError('Sign in before opening referrals.');
    }
    return ReferralSummary(
      customerInviterRewardProin: 40,
      customerReferredRewardProin: 40,
      salonInviterRewardProin: _activeRole == UserRole.owner ? 500 : 0,
      salonReferredRewardProin: _activeRole == UserRole.owner ? 500 : 0,
    );
  }

  Future<void> completeReferralOnboarding({String referralCode = ''}) async {
    if (!_referralOnboardingRequired) {
      return;
    }
    final role = _activeRole;
    final account = role == UserRole.customer
        ? _customerAccount
        : role == UserRole.owner
        ? _ownerAccount
        : null;
    if (account == null || role == null) {
      throw StateError('Sign in again before continuing.');
    }
    final normalizedCode = referralCode.trim().toUpperCase();
    if (normalizedCode.isNotEmpty) {
      if (!RegExp(
        r'^(?=.*[A-Z])(?=.*\d)[A-Z\d]{6}$',
      ).hasMatch(normalizedCode)) {
        throw StateError('Enter a valid 6-character referral code.');
      }
      final referral = _mockReferralCodeRegistry[normalizedCode];
      if (referral == null) {
        throw StateError('This referral code is not valid.');
      }
      if (referral.ownerUid == account.id) {
        throw StateError('You cannot use your own referral code.');
      }
      if (referral.targetRole != role) {
        throw StateError(
          role == UserRole.customer
              ? 'This code cannot be used for a customer account.'
              : 'This code cannot be used for a salon account.',
        );
      }
    }
    _referralOnboardingRequired = false;
    notifyListeners();
  }

  String _newMockReferralCode() {
    while (true) {
      final code =
          'R${(_referralCodeCounter++).toRadixString(36).toUpperCase().padLeft(5, '0')}';
      if (!_mockReferralCodeRegistry.containsKey(code)) {
        return code;
      }
    }
  }

  bool get hasActiveCustomerSession =>
      _activeRole == UserRole.customer && _customerAccount != null;

  bool get hasActiveOwnerSession =>
      _activeRole == UserRole.owner && _ownerAccount != null;

  bool get hasActiveBarberSession =>
      _activeRole == UserRole.barber && _barberAccount != null;

  bool hasSeenNotification(UserRole role, String notificationKey) {
    return _seenNotificationKeys[_notificationViewerKey(role)]?.contains(
          notificationKey,
        ) ==
        true;
  }

  DateTime? notificationReadAt(UserRole role) {
    return _notificationsReadAt[_notificationViewerKey(role)];
  }

  void markNotificationsSeen(UserRole role, Iterable<String> notificationKeys) {
    final viewerKey = _notificationViewerKey(role);
    final seen = _seenNotificationKeys.putIfAbsent(viewerKey, () => <String>{});
    final previousLength = seen.length;
    seen.addAll(notificationKeys);
    final readAt = DateTime.now();
    final previousReadAt = _notificationsReadAt[viewerKey];
    _notificationsReadAt[viewerKey] = readAt;
    if (seen.length != previousLength || previousReadAt != readAt) {
      unawaited(
        _persistNotificationSet(
          _seenNotificationsPreferencePrefix,
          viewerKey,
          seen,
        ),
      );
      unawaited(_persistNotificationReadAt(viewerKey, readAt));
      notifyListeners();
    }
  }

  bool hasDismissedNotification(UserRole role, String notificationKey) {
    return _dismissedNotificationKeys[_notificationViewerKey(role)]?.contains(
          notificationKey,
        ) ??
        false;
  }

  void dismissNotification(UserRole role, String notificationKey) {
    final viewerKey = _notificationViewerKey(role);
    final dismissed = _dismissedNotificationKeys.putIfAbsent(
      viewerKey,
      () => <String>{},
    )..add(notificationKey);
    unawaited(
      _persistNotificationSet(
        _dismissedNotificationsPreferencePrefix,
        viewerKey,
        dismissed,
      ),
    );
    notifyListeners();
  }

  String _notificationViewerKey(UserRole role) {
    final accountId = switch (role) {
      UserRole.customer => _customerAccount?.id,
      UserRole.owner => _ownerAccount?.id,
      UserRole.barber => _barberAccount?.id,
    };
    return '${role.name}:${accountId ?? 'guest'}';
  }

  String? get activeCustomerContact {
    final contact = _customerAccount?.contact.trim();
    return contact == null || contact.isEmpty ? null : contact;
  }

  String get ownerSalonId {
    final account = _ownerAccount;
    if (account == null) {
      return '';
    }
    return 'salon-${account.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}';
  }

  Salon? get ownerSalonOrNull => getSalon(ownerSalonId);

  Salon get ownerSalon => ownerSalonOrNull ?? _draftOwnerSalon();

  List<Salon> get bookableSalons => _salons
      .where(
        (salon) =>
            isSalonBookable(salon.id) && isSalonCurrentlyOpenByClock(salon),
      )
      .toList();

  Barber? get currentBarber {
    if (_currentBarberId == null) {
      final account = _barberAccount;
      if (_activeRole != UserRole.barber || account == null) {
        return null;
      }
      return _barbers
          .where(
            (barber) =>
                barber.isActive &&
                (barber.uid == account.id ||
                    barber.phone == account.contact ||
                    barber.email.toLowerCase() ==
                        account.contact.toLowerCase()),
          )
          .firstOrNull;
    }
    return getBarber(_currentBarberId!);
  }

  JoinRequest? get currentJoinRequest {
    if (_currentJoinRequestId == null) {
      final account = _barberAccount;
      if (_activeRole != UserRole.barber || account == null) {
        return null;
      }
      final requests =
          _joinRequests
              .where(
                (request) =>
                    request.requesterUid == account.id ||
                    request.barberPhone == account.contact ||
                    request.barberEmail.toLowerCase() ==
                        account.contact.toLowerCase(),
              )
              .toList()
            ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
      return requests.firstOrNull;
    }
    return _joinRequests
        .where((request) => request.id == _currentJoinRequestId)
        .firstOrNull;
  }

  List<JoinRequest> get pendingJoinRequests {
    return _joinRequests
        .where((request) => request.status == JoinRequestStatus.pending)
        .toList();
  }

  List<Booking> get customerBookings {
    if (_activeRole != UserRole.customer || _customerAccount == null) {
      return [];
    }
    final account = _customerAccount!;
    final now = DateTime.now();
    return _bookings
        .where(
          (booking) =>
              booking.customerUid == account.id ||
              (booking.customerUid == null &&
                  booking.customerPhone == account.contact),
        )
        .map((booking) {
          final pendingReason = _pendingCustomerCancellations[booking.id];
          if (pendingReason != null) {
            return booking.copyWith(
              status: BookingStatus.cancelled,
              cancellationReason: pendingReason,
              cancelledBy: 'customer',
            );
          }
          final responseDeadline = booking.createdAt.add(
            instantBookingResponseTimeout,
          );
          final responseExpired =
              booking.isInstant &&
              booking.status == BookingStatus.pending &&
              (_locallyExpiredInstantBookingIds.contains(booking.id) ||
                  !now.isBefore(responseDeadline));
          if (!responseExpired) {
            return booking;
          }
          // Project the timeout into customer-visible state as soon as the
          // 120-second response window closes. Firestore remains authoritative
          // and will reconcile this with the server-side cancellation.
          return booking.copyWith(
            status: BookingStatus.cancelled,
            cancellationReason: 'No response from salon within 120 seconds',
            cancelledBy: 'system',
            cancelledAt: responseDeadline,
          );
        })
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));
  }

  Booking? get activeInstantBooking {
    final now = DateTime.now();
    final active =
        customerBookings
            .where(
              (booking) =>
                  booking.isInstant &&
                  isCustomerBookingActive(booking, now: now),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return active.firstOrNull;
  }

  bool get hasActiveInstantBooking => activeInstantBooking != null;

  Booking? get activeCustomerBooking {
    final now = DateTime.now();
    final active =
        customerBookings
            .where((booking) => isCustomerBookingActive(booking, now: now))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return active.firstOrNull;
  }

  bool get hasActiveCustomerBooking => activeCustomerBooking != null;

  bool isCustomerBookingActive(Booking booking, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final end = booking.start.add(Duration(minutes: booking.durationMinutes));
    return switch (booking.status) {
      BookingStatus.pending =>
        booking.isInstant
            ? reference.isBefore(
                booking.createdAt.add(instantBookingResponseTimeout),
              )
            : reference.isBefore(booking.start),
      BookingStatus.confirmed => reference.isBefore(end),
      BookingStatus.inProgress => true,
      BookingStatus.completed ||
      BookingStatus.cancelled ||
      BookingStatus.rejected => false,
    };
  }

  void _syncCustomerInstantExpiryTimer() {
    _customerInstantExpiryTimer?.cancel();
    _customerInstantExpiryTimer = null;
    if (_activeRole != UserRole.customer || _customerAccount == null) {
      _locallyExpiredInstantBookingIds.clear();
      return;
    }

    final now = DateTime.now();
    final pendingInstantBookings = _bookings
        .where(
          (booking) =>
              booking.isInstant && booking.status == BookingStatus.pending,
        )
        .toList();
    final pendingIds = pendingInstantBookings
        .map((booking) => booking.id)
        .toSet();
    _locallyExpiredInstantBookingIds.removeWhere(
      (bookingId) => !pendingIds.contains(bookingId),
    );
    final expiries =
        pendingInstantBookings
            .where(
              (booking) =>
                  !_locallyExpiredInstantBookingIds.contains(booking.id),
            )
            .map(
              (booking) => (
                booking: booking,
                deadline: booking.createdAt.add(instantBookingResponseTimeout),
              ),
            )
            .where((entry) => entry.deadline.isAfter(now))
            .toList()
          ..sort((a, b) => a.deadline.compareTo(b.deadline));
    if (expiries.isEmpty) {
      return;
    }

    final firstDeadline = expiries.first.deadline;
    _customerInstantExpiryTimer = Timer(firstDeadline.difference(now), () {
      for (final entry in expiries) {
        if (!entry.deadline.isAfter(firstDeadline)) {
          _locallyExpiredInstantBookingIds.add(entry.booking.id);
        }
      }
      notifyListeners();
    });
  }

  Salon? getSalon(String id) {
    return _salons.where((salon) => salon.id == id).firstOrNull;
  }

  Barber? getBarber(String id) {
    return _barbers.where((barber) => barber.id == id).firstOrNull;
  }

  SalonService? getService(String salonId, String serviceId) {
    final salon = getSalon(salonId);
    return salon?.services
        .where((service) => service.id == serviceId)
        .firstOrNull;
  }

  List<Barber> barbersForSalon(String salonId) {
    return _barbers
        .where((barber) => barber.salonId == salonId && barber.isActive)
        .toList();
  }

  List<Barber> barbersForService(String salonId, String serviceId) {
    final service = getService(salonId, serviceId);
    if (service == null || !service.isAvailable) {
      return [];
    }
    return barbersForSalon(
      salonId,
    ).where((barber) => barber.serviceIds.contains(serviceId)).toList();
  }

  bool hasSalonDetails(String salonId) {
    final salon = getSalon(salonId);
    if (salon == null) {
      return false;
    }
    return salon.name.trim().isNotEmpty &&
        salon.ownerName.trim().isNotEmpty &&
        salon.address.trim().isNotEmpty &&
        salon.phone.trim().isNotEmpty &&
        _isValidEmail(salon.email) &&
        salon.openTime.trim().isNotEmpty &&
        salon.closeTime.trim().isNotEmpty;
  }

  bool isSalonSetupComplete(String salonId) {
    return missingSalonSetupItems(salonId).isEmpty;
  }

  List<String> missingSalonSetupItems(String salonId) {
    final salon = getSalon(salonId);
    if (salon == null) {
      return const ['Save the salon profile'];
    }
    final missing = <String>[];
    if (salon.name.trim().isEmpty) {
      missing.add('Add the salon name');
    }
    if (salon.ownerName.trim().isEmpty) {
      missing.add('Add the owner name');
    }
    if (salon.address.trim().isEmpty) {
      missing.add('Add the salon address');
    }
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(salon.phone.trim())) {
      missing.add('Add a valid owner phone number');
    }
    if (!_isValidEmail(salon.email)) {
      missing.add('Add a valid owner email address');
    }
    final openingMinutes = _parseClockMinutes(salon.openTime);
    final closingMinutes = _parseClockMinutes(salon.closeTime);
    if (openingMinutes == null ||
        closingMinutes == null ||
        closingMinutes <= openingMinutes) {
      missing.add('Set valid opening and closing times');
    }
    if (salon.availableServices.isEmpty) {
      missing.add('Add at least one available service');
    }
    final activeBarbers = barbersForSalon(salonId);
    if (activeBarbers.isEmpty) {
      missing.add('Add at least one barber');
    } else {
      final serviceIds = salon.availableServices
          .map((service) => service.id)
          .toSet();
      if (!activeBarbers.any(
        (barber) => barber.serviceIds.any(serviceIds.contains),
      )) {
        missing.add('Assign a barber to an available service');
      }
    }
    return List.unmodifiable(missing);
  }

  bool isSalonBookable(String salonId) {
    final salon = getSalon(salonId);
    if (salon == null || !salon.isOpen) {
      return false;
    }
    final serviceIds = salon.availableServices
        .map((service) => service.id)
        .toSet();
    if (serviceIds.isEmpty) {
      return false;
    }
    return barbersForSalon(
      salonId,
    ).any((barber) => barber.serviceIds.any(serviceIds.contains));
  }

  bool isSalonCurrentlyOpen(String salonId, {DateTime? now}) {
    final salon = getSalon(salonId);
    if (salon == null) {
      return false;
    }
    return isSalonCurrentlyOpenByClock(salon, now: now);
  }

  bool isSalonCurrentlyOpenByClock(Salon salon, {DateTime? now}) {
    if (!salon.isOpen) {
      return false;
    }
    final openMinutes = _parseClockMinutes(salon.openTime);
    final closeMinutes = _parseClockMinutes(salon.closeTime);
    if (openMinutes == null ||
        closeMinutes == null ||
        closeMinutes <= openMinutes) {
      return false;
    }
    final reference = now ?? DateTime.now();
    final currentMinutes = reference.hour * 60 + reference.minute;
    return currentMinutes >= openMinutes && currentMinutes < closeMinutes;
  }

  bool isInstantBookingEnabled(String salonId, {DateTime? now}) {
    final salon = getSalon(salonId);
    if (salon == null) {
      return false;
    }
    return isInstantBookingEnabledForSalon(salon, now: now);
  }

  bool isInstantBookingEnabledForSalon(Salon salon, {DateTime? now}) {
    return salon.instantBookingsEnabled;
  }

  bool isInstantBookingAvailable(
    String salonId, {
    String? serviceId,
    DateTime? now,
    int arrivalMinutes = 15,
  }) {
    if (!instantArrivalMinuteOptions.contains(arrivalMinutes) ||
        hasActiveCustomerBooking) {
      return false;
    }
    final salon = getSalon(salonId);
    if (salon == null ||
        !isSalonBookable(salonId) ||
        !isSalonCurrentlyOpen(salonId, now: now) ||
        !isInstantBookingEnabledForSalon(salon, now: now)) {
      return false;
    }
    final requestedServices = serviceId == null
        ? salon.availableServices.map((service) => service.id)
        : [serviceId];
    return isInstantBookingAvailableForServices(
      salonId,
      requestedServices,
      now: now,
      arrivalMinutes: arrivalMinutes,
    );
  }

  bool isInstantBookingAvailableForServices(
    String salonId,
    Iterable<String> serviceIds, {
    DateTime? now,
    int arrivalMinutes = 15,
  }) {
    if (!instantArrivalMinuteOptions.contains(arrivalMinutes) ||
        hasActiveCustomerBooking) {
      return false;
    }
    final salon = getSalon(salonId);
    if (salon == null ||
        !isSalonBookable(salonId) ||
        !isSalonCurrentlyOpen(salonId, now: now) ||
        !isInstantBookingEnabledForSalon(salon, now: now)) {
      return false;
    }
    for (final serviceId in serviceIds) {
      final service = getService(salonId, serviceId);
      if (service == null ||
          !service.isAvailable ||
          !service.instantBookingEnabled) {
        continue;
      }
      final reference = now ?? DateTime.now();
      final arrival = reference.add(Duration(minutes: arrivalMinutes));
      final closeMinutes = _parseClockMinutes(salon.closeTime);
      final arrivalEndMinutes =
          arrival.hour * 60 + arrival.minute + service.durationMinutes;
      if (closeMinutes != null &&
          arrivalEndMinutes <= closeMinutes &&
          barbersForService(salonId, service.id).any(
            (barber) =>
                barber.isActive &&
                _isBarberFree(barber.id, arrival, service.durationMinutes),
          )) {
        return true;
      }
    }
    return false;
  }

  List<Barber> barbersForServices(String salonId, Iterable<String> serviceIds) {
    final requestedIds = serviceIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (requestedIds.isEmpty) {
      return const [];
    }
    return barbersForSalon(salonId)
        .where(
          (barber) =>
              barber.isActive && requestedIds.every(barber.serviceIds.contains),
        )
        .toList();
  }

  bool isInstantMultiServiceBookingAvailable(
    String salonId,
    Iterable<String> serviceIds, {
    DateTime? now,
    int arrivalMinutes = 15,
  }) {
    if (!instantArrivalMinuteOptions.contains(arrivalMinutes) ||
        hasActiveCustomerBooking) {
      return false;
    }
    final salon = getSalon(salonId);
    final requestedIds = serviceIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (salon == null ||
        requestedIds.isEmpty ||
        !isSalonBookable(salonId) ||
        !isSalonCurrentlyOpen(salonId, now: now) ||
        !isInstantBookingEnabledForSalon(salon, now: now)) {
      return false;
    }
    final services = requestedIds
        .map((id) => getService(salonId, id))
        .whereType<SalonService>()
        .toList();
    if (services.length != requestedIds.length ||
        services.any(
          (service) => !service.isAvailable || !service.instantBookingEnabled,
        )) {
      return false;
    }
    final reference = now ?? DateTime.now();
    final arrival = reference.add(Duration(minutes: arrivalMinutes));
    final totalDuration = services.fold<int>(
      0,
      (total, service) => total + service.durationMinutes,
    );
    final closeMinutes = _parseClockMinutes(salon.closeTime);
    final arrivalEndMinutes =
        arrival.hour * 60 + arrival.minute + totalDuration;
    if (closeMinutes == null || arrivalEndMinutes > closeMinutes) {
      return false;
    }
    return barbersForServices(
      salonId,
      requestedIds,
    ).any((barber) => _isBarberFree(barber.id, arrival, totalDuration));
  }

  Future<void> setOwnerInstantBookingEnabled(bool enabled) async {
    final salon = ownerSalon.copyWith(
      instantBookingsEnabled: enabled,
      instantBookingsPausedDate: '',
    );
    _replaceSalon(salon);
    notifyListeners();
  }

  List<Booking> bookingsForSalon(String salonId) {
    return _bookings.where((booking) => booking.salonId == salonId).toList()
      ..sort((a, b) => b.start.compareTo(a.start));
  }

  List<Booking> bookingsForBarber(String barberId) {
    return _bookings.where((booking) => booking.barberId == barberId).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  BarberBookingBucket barberBookingBucket(Booking booking, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final end = booking.start.add(Duration(minutes: booking.durationMinutes));
    return switch (booking.status) {
      BookingStatus.cancelled ||
      BookingStatus.rejected => BarberBookingBucket.cancelled,
      BookingStatus.inProgress => BarberBookingBucket.active,
      BookingStatus.completed => BarberBookingBucket.history,
      BookingStatus.pending =>
        booking.isInstant || reference.isBefore(booking.start)
            ? BarberBookingBucket.upcoming
            : BarberBookingBucket.history,
      BookingStatus.confirmed =>
        reference.isBefore(end)
            ? BarberBookingBucket.upcoming
            : BarberBookingBucket.history,
    };
  }

  String barberBookingOutcome(Booking booking, {DateTime? now}) {
    final bucket = barberBookingBucket(booking, now: now);
    if (bucket == BarberBookingBucket.history) {
      if (booking.status == BookingStatus.pending) {
        return 'Not accepted';
      }
      if (booking.status == BookingStatus.confirmed) {
        return 'Missed · not completed';
      }
    }
    if (booking.isInstant && booking.status == BookingStatus.pending) {
      return 'Instant request';
    }
    if (booking.isInstant && booking.status == BookingStatus.confirmed) {
      return 'Accepted · arrive soon';
    }
    return switch (booking.status) {
      BookingStatus.pending => 'Awaiting acceptance',
      BookingStatus.confirmed =>
        booking.isInstant ? 'Accepted · arrive soon' : 'Scheduled',
      BookingStatus.inProgress => 'In progress',
      BookingStatus.completed => 'Completed',
      BookingStatus.cancelled => 'Cancelled / rejected',
      BookingStatus.rejected => 'Rejected by salon',
    };
  }

  SalonBookingBucket salonBookingBucket(Booking booking, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final end = booking.start.add(Duration(minutes: booking.durationMinutes));
    return switch (booking.status) {
      BookingStatus.cancelled ||
      BookingStatus.rejected => SalonBookingBucket.cancelled,
      BookingStatus.inProgress => SalonBookingBucket.active,
      BookingStatus.completed => SalonBookingBucket.history,
      BookingStatus.pending =>
        booking.isInstant
            ? SalonBookingBucket.requests
            : reference.isBefore(booking.start)
            ? SalonBookingBucket.upcoming
            : SalonBookingBucket.history,
      BookingStatus.confirmed =>
        reference.isBefore(booking.start)
            ? SalonBookingBucket.upcoming
            : reference.isBefore(end)
            ? SalonBookingBucket.active
            : SalonBookingBucket.history,
    };
  }

  String salonBookingOutcome(Booking booking, {DateTime? now}) {
    final bucket = salonBookingBucket(booking, now: now);
    if (bucket == SalonBookingBucket.history) {
      if (booking.status == BookingStatus.pending) {
        return 'Not accepted';
      }
      if (booking.status == BookingStatus.confirmed) {
        return 'Missed · not started';
      }
    }
    if (booking.isInstant && booking.status == BookingStatus.pending) {
      return 'Instant request';
    }
    if (booking.isInstant && booking.status == BookingStatus.confirmed) {
      return 'Accepted · ${booking.customerArrivalMinutes} min arrival';
    }
    return switch (booking.status) {
      BookingStatus.pending => 'Waiting for owner action',
      BookingStatus.confirmed =>
        booking.isInstant
            ? 'Accepted · ${booking.customerArrivalMinutes} min arrival'
            : 'Registered',
      BookingStatus.inProgress => 'In progress',
      BookingStatus.completed => 'Completed · revenue added',
      BookingStatus.cancelled => 'Cancelled',
      BookingStatus.rejected => 'Rejected by salon',
    };
  }

  CustomerBookingBucket customerBookingBucket(
    Booking booking, {
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final end = booking.start.add(Duration(minutes: booking.durationMinutes));
    return switch (booking.status) {
      BookingStatus.cancelled ||
      BookingStatus.rejected => CustomerBookingBucket.cancelled,
      BookingStatus.completed => CustomerBookingBucket.history,
      BookingStatus.inProgress => CustomerBookingBucket.active,
      BookingStatus.pending =>
        booking.isInstant || reference.isBefore(booking.start)
            ? CustomerBookingBucket.active
            : CustomerBookingBucket.history,
      BookingStatus.confirmed =>
        reference.isBefore(end)
            ? CustomerBookingBucket.active
            : CustomerBookingBucket.history,
    };
  }

  String customerBookingOutcome(Booking booking, {DateTime? now}) {
    final bucket = customerBookingBucket(booking, now: now);
    if (bucket == CustomerBookingBucket.history) {
      if (booking.status == BookingStatus.pending) {
        return 'Not accepted by salon';
      }
      if (booking.status == BookingStatus.confirmed) {
        return 'Missed · not completed';
      }
    }
    if (booking.isInstant && booking.status == BookingStatus.pending) {
      return 'Instant request sent';
    }
    if (booking.isInstant && booking.status == BookingStatus.confirmed) {
      return 'Accepted · arrive soon';
    }
    return switch (booking.status) {
      BookingStatus.pending => 'Waiting for salon',
      BookingStatus.confirmed =>
        booking.isInstant ? 'Accepted · arrive soon' : 'Scheduled',
      BookingStatus.inProgress => 'Service in progress',
      BookingStatus.completed => 'Completed',
      BookingStatus.cancelled => 'Cancelled',
      BookingStatus.rejected => 'Rejected by salon',
    };
  }

  List<TimeSlot> slotsForService(
    String salonId,
    String serviceId, {
    String? barberId,
  }) {
    final salon = getSalon(salonId);
    final service = getService(salonId, serviceId);
    if (salon == null ||
        service == null ||
        !service.isAvailable ||
        !isSalonBookable(salonId)) {
      return [];
    }
    final eligibleBarbers = barbersForService(
      salonId,
      serviceId,
    ).where((barber) => barberId == null || barber.id == barberId).toList();
    final now = DateTime.now();
    _expireSlotCache(now);
    final cacheKey = '$salonId|$serviceId|${barberId ?? '*'}';
    final cached = _slotCache[cacheKey];
    if (cached != null) {
      return cached;
    }
    final openMinutes = _parseClockMinutes(salon.openTime) ?? 9 * 60;
    final closeMinutes = _parseClockMinutes(salon.closeTime) ?? 20 * 60;
    if (closeMinutes <= openMinutes) {
      return [];
    }
    final durationMinutes = service.durationMinutes > 0
        ? service.durationMinutes
        : 30;
    final slots = <TimeSlot>[];

    for (
      var dayOffset = 0;
      dayOffset < scheduledBookingHorizonDays;
      dayOffset++
    ) {
      final day = DateTime(now.year, now.month, now.day + dayOffset);
      for (
        var minuteOfDay = openMinutes;
        minuteOfDay + durationMinutes <= closeMinutes;
        minuteOfDay += 30
      ) {
        final start = DateTime(
          day.year,
          day.month,
          day.day,
          minuteOfDay ~/ 60,
          minuteOfDay % 60,
        );
        if (start.isBefore(now.add(scheduledBookingLeadTime))) {
          continue;
        }
        for (final barber in eligibleBarbers) {
          if (_isBarberFree(barber.id, start, durationMinutes)) {
            slots.add(
              TimeSlot(
                salonId: salonId,
                serviceId: serviceId,
                barberId: barber.id,
                start: start,
              ),
            );
          }
        }
      }
    }

    slots.sort((a, b) => a.start.compareTo(b.start));
    final visibleSlots = barberId == null
        ? _deduplicateAnyBarberSlots(slots)
        : slots;
    final result = List<TimeSlot>.unmodifiable(visibleSlots);
    _slotCache[cacheKey] = result;
    _slotCacheCreatedAt ??= now;
    return result;
  }

  int availableSlotCountForSalon(String salonId) {
    final salon = getSalon(salonId);
    if (salon == null || !isSalonBookable(salonId)) {
      return 0;
    }
    final openMinutes = _parseClockMinutes(salon.openTime) ?? 9 * 60;
    final closeMinutes = _parseClockMinutes(salon.closeTime) ?? 20 * 60;
    if (closeMinutes <= openMinutes) {
      return 0;
    }
    final now = DateTime.now();
    var count = 0;
    for (final barber in barbersForSalon(salonId)) {
      final durations = barber.serviceIds
          .map((serviceId) => getService(salonId, serviceId))
          .whereType<SalonService>()
          .where((service) => service.isAvailable)
          .map((service) => service.durationMinutes)
          .where((duration) => duration > 0)
          .toList();
      if (durations.isEmpty) {
        continue;
      }
      durations.sort();
      final shortestDuration = durations.first;
      for (var dayOffset = 0; dayOffset < 4; dayOffset++) {
        final day = DateTime(now.year, now.month, now.day + dayOffset);
        for (
          var minuteOfDay = openMinutes;
          minuteOfDay + shortestDuration <= closeMinutes;
          minuteOfDay += 30
        ) {
          final start = DateTime(
            day.year,
            day.month,
            day.day,
            minuteOfDay ~/ 60,
            minuteOfDay % 60,
          );
          if (start.isBefore(now.add(scheduledBookingLeadTime))) {
            continue;
          }
          if (_isBarberFree(barber.id, start, shortestDuration)) {
            count++;
          }
        }
      }
    }
    return count;
  }

  TimeSlot? earliestSlotForServices(
    String salonId,
    Iterable<String> serviceIds,
  ) {
    final requestedIds = serviceIds.toSet();
    if (requestedIds.isEmpty) {
      return null;
    }
    TimeSlot? earliest;
    for (final barber in barbersForSalon(salonId)) {
      final services =
          barber.serviceIds
              .where(requestedIds.contains)
              .map((serviceId) => getService(salonId, serviceId))
              .whereType<SalonService>()
              .where((service) => service.isAvailable)
              .toList()
            ..sort((a, b) => a.durationMinutes.compareTo(b.durationMinutes));
      if (services.isEmpty) {
        continue;
      }
      final service = services.first;
      final slots = slotsForService(salonId, service.id, barberId: barber.id);
      if (slots.isEmpty) {
        continue;
      }
      final candidate = slots.first;
      if (earliest == null || candidate.start.isBefore(earliest.start)) {
        earliest = candidate;
      }
    }
    return earliest;
  }

  Future<void> restoreSignedInUser() async {
    await _restoreActiveRole();
  }

  Future<void> refresh() async {
    _discountOfferRefreshVersion += 1;
    notifyListeners();
  }

  Future<void> selectRole(UserRole role) async {
    if (role == UserRole.barber) {
      throw StateError('Barbers do not have login accounts.');
    }
    if (_activeRole != null &&
        _activeRole != role &&
        (_customerAccount != null || _ownerAccount != null)) {
      throw StateError(_roleSwitchMessage(_activeRole!, role));
    }
    _activeRole = role;
    _clearInactiveRoleState(role);
    await _persistOwnerAlertsEnabled(role == UserRole.owner);
    final accountId = switch (role) {
      UserRole.customer => _customerAccount?.id,
      UserRole.owner => _ownerAccount?.id,
      UserRole.barber => _barberAccount?.id,
    };
    await _persistActiveRole(role, accountId: accountId);
    notifyListeners();
  }

  Future<void> signOutActiveUser() async {
    await _persistOwnerAlertsEnabled(false);
    _pendingMockCustomerPhone = null;
    _pendingMockGoogleCustomer = null;
    _activeRole = null;
    _customerAccount = null;
    _ownerAccount = null;
    _ownerDraftServices.clear();
    _barberAccount = null;
    _currentBarberId = null;
    _currentJoinRequestId = null;
    _referralOnboardingRequired = false;
    _customerProinWallet = const ProinWalletSummary();
    _salonProinWallets.clear();
    _customerProinActivity.clear();
    _ownerPaymentUpiId = '';
    _ownerPaymentQrCodeUrl = '';
    await _persistActiveRole(null);
    notifyListeners();
  }

  void clearSyncError() {
    _lastSyncError = null;
    notifyListeners();
  }

  String normalizePhone(String phone) {
    final trimmed = phone.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      return trimmed;
    }
    if (trimmed.startsWith('+')) {
      return '+$digits';
    }
    if (digits.length == 10) {
      return '+91$digits';
    }
    return '+$digits';
  }

  void _claimMockPhoneRole(
    String phone,
    UserRole requestedRole, {
    required String accountId,
  }) {
    final existingRole = _mockPhoneRoles[phone];
    if (existingRole != null && existingRole != requestedRole) {
      throw StateError(_phoneRoleConflictMessage(existingRole, requestedRole));
    }
    final existingAccountId = _mockPhoneAccountIds[phone];
    if (existingAccountId != null && existingAccountId != accountId) {
      final roleLabel = requestedRole == UserRole.owner
          ? 'salon owner'
          : 'customer';
      throw StateError(
        'Unable to log in because this phone number is already registered to '
        'another $roleLabel account. Use the original login method.',
      );
    }
    _mockPhoneRoles[phone] = requestedRole;
    _mockPhoneAccountIds[phone] = accountId;
  }

  String _roleSwitchMessage(UserRole existingRole, UserRole requestedRole) {
    if (existingRole == UserRole.owner && requestedRole == UserRole.customer) {
      return 'Salon owners cannot switch to a customer account. Sign out first.';
    }
    if (existingRole == UserRole.customer && requestedRole == UserRole.owner) {
      return 'Customers cannot switch to a salon owner account. Sign out first.';
    }
    return 'This account cannot switch roles.';
  }

  String _phoneRoleConflictMessage(
    UserRole existingRole,
    UserRole requestedRole,
  ) {
    final requestedLabel = requestedRole == UserRole.customer
        ? 'customer'
        : 'salon owner';
    final existingLabel = existingRole == UserRole.customer
        ? 'customer'
        : 'salon owner';
    return 'Unable to log in as $requestedLabel because this phone number is '
        'already registered as a $existingLabel.';
  }

  Future<Booking> createBooking({
    required TimeSlot slot,
    String quoteId = '',
    int requestedProin = 0,
  }) async {
    final account = _customerAccount;
    if (_activeRole != UserRole.customer || account == null) {
      throw StateError('Customer login is required before booking.');
    }
    if (hasActiveCustomerBooking) {
      throw StateError('You already have an active booking.');
    }
    final service = getService(slot.salonId, slot.serviceId);
    final barber = getBarber(slot.barberId);
    if (service == null ||
        !service.isAvailable ||
        barber == null ||
        !barber.isActive ||
        barber.salonId != slot.salonId ||
        !barber.serviceIds.contains(slot.serviceId) ||
        !_isWithinOperatingHours(slot, service.durationMinutes)) {
      throw StateError('This appointment is no longer available.');
    }
    if (!_isSlotAvailable(slot, service.durationMinutes)) {
      throw StateError(
        'This slot was just booked. Please choose another time.',
      );
    }
    final quoteKey = quoteId.trim();
    final discount = quoteKey.isNotEmpty
        ? _mockLockedDiscountQuotes.remove(quoteKey) ??
              (throw StateError(
                'This discount expired. Select the offer again.',
              ))
        : DiscountQuote(originalAmount: service.price);
    final booking = Booking(
      id: 'booking-${_bookingCounter++}',
      customerUid: _customerAccount?.id,
      salonId: slot.salonId,
      serviceId: slot.serviceId,
      barberId: slot.barberId,
      customerName: account.name,
      customerPhone: account.contact,
      start: slot.start,
      durationMinutes: service.durationMinutes,
      serviceName: service.name,
      servicePrice: service.price,
      serviceNameBreakdown: {service.id: service.name},
      servicePriceBreakdown: {service.id: service.price},
      bookingFee: _zeroBookingFee,
      paymentRequired: false,
      paymentStatus: _zeroBookingFeeStatus,
      discountCampaignId: discount.campaignId,
      discountCampaignName: discount.campaignName,
      discountPercent: discount.discountPercent,
      discountBaseAmount: discount.discountBaseAmount,
      discountAmount: discount.discountAmount,
      pritzePayoutAmount: discount.pritzePayoutAmount,
      salonTotalEarning: discount.salonTotalEarning,
      discountStatus: discount.hasDiscount ? 'reserved' : 'none',
      customerPayableBeforeProin: discount.customerPayableAmount,
      customerPayableAmount: (discount.customerPayableAmount - requestedProin)
          .clamp(0, 1000000000)
          .toInt(),
      proinStatus: requestedProin > 0 ? 'reserved' : 'none',
      proinRequestedAmount: requestedProin,
      proinReservedAmount: requestedProin,
      status: BookingStatus.confirmed,
      createdAt: DateTime.now(),
    );
    _bookings.add(booking);
    _setSlotOccupancy(
      barberId: slot.barberId,
      start: slot.start,
      durationMinutes: service.durationMinutes,
      occupied: true,
    );
    notifyListeners();
    return booking;
  }

  Future<Booking> createInstantBooking({
    required String salonId,
    String? serviceId,
    Iterable<String>? serviceIds,
    int arrivalMinutes = 15,
    String quoteId = '',
    int requestedProin = 0,
  }) async {
    final account = _customerAccount;
    if (_activeRole != UserRole.customer || account == null) {
      throw StateError('Customer login is required before booking.');
    }
    if (!instantArrivalMinuteOptions.contains(arrivalMinutes)) {
      throw StateError('Choose an arrival time of 15, 20, or 25 minutes.');
    }
    if (hasActiveCustomerBooking) {
      throw StateError('You already have an active booking.');
    }
    final requestedIds = <String>{
      ...?serviceIds?.map((id) => id.trim()),
      if (serviceId?.trim().isNotEmpty == true) serviceId!.trim(),
    }.where((id) => id.isNotEmpty).toList();
    if (requestedIds.isEmpty || requestedIds.length > 6) {
      throw StateError('Choose between 1 and 6 instant services.');
    }
    final salon = getSalon(salonId);
    final services = requestedIds
        .map((id) => getService(salonId, id))
        .whereType<SalonService>()
        .toList();
    if (salon == null ||
        services.length != requestedIds.length ||
        !isInstantMultiServiceBookingAvailable(
          salonId,
          requestedIds,
          arrivalMinutes: arrivalMinutes,
        )) {
      throw StateError('These services are not available together right now.');
    }
    final totalDuration = services.fold<int>(
      0,
      (total, service) => total + service.durationMinutes,
    );
    final totalPrice = services.fold<int>(
      0,
      (total, service) => total + service.price,
    );
    final now = DateTime.now();
    final arrivalDeadline = now.add(Duration(minutes: arrivalMinutes));
    final eligibleBarbers = barbersForServices(salonId, requestedIds)
      ..sort((a, b) {
        final aIsFree = _isBarberFree(a.id, arrivalDeadline, totalDuration);
        final bIsFree = _isBarberFree(b.id, arrivalDeadline, totalDuration);
        if (aIsFree != bIsFree) {
          return aIsFree ? -1 : 1;
        }
        final workloadCompare = bookingsForBarber(
          a.id,
        ).length.compareTo(bookingsForBarber(b.id).length);
        return workloadCompare != 0
            ? workloadCompare
            : a.name.compareTo(b.name);
      });
    if (eligibleBarbers.isEmpty) {
      throw StateError('No barber is available for this instant service.');
    }
    final quoteKey = quoteId.trim();
    final discount = quoteKey.isNotEmpty
        ? _mockLockedDiscountQuotes.remove(quoteKey) ??
              (throw StateError(
                'This discount expired. Select the offer again.',
              ))
        : DiscountQuote(originalAmount: totalPrice);
    final booking = Booking(
      id: 'booking-${_bookingCounter++}',
      customerUid: _customerAccount?.id,
      salonId: salonId,
      serviceId: requestedIds.first,
      serviceIds: requestedIds,
      barberId: '',
      customerName: account.name,
      customerPhone: account.contact,
      start: arrivalDeadline,
      durationMinutes: totalDuration,
      serviceName: services.map((service) => service.name).join(', '),
      servicePrice: totalPrice,
      serviceNameBreakdown: {
        for (final service in services) service.id: service.name,
      },
      servicePriceBreakdown: {
        for (final service in services) service.id: service.price,
      },
      bookingFee: _zeroBookingFee,
      paymentRequired: false,
      paymentStatus: _zeroBookingFeeStatus,
      discountCampaignId: discount.campaignId,
      discountCampaignName: discount.campaignName,
      discountPercent: discount.discountPercent,
      discountBaseAmount: discount.discountBaseAmount,
      discountAmount: discount.discountAmount,
      pritzePayoutAmount: discount.pritzePayoutAmount,
      salonTotalEarning: discount.salonTotalEarning,
      discountStatus: discount.hasDiscount ? 'reserved' : 'none',
      customerPayableBeforeProin: discount.customerPayableAmount,
      customerPayableAmount: (discount.customerPayableAmount - requestedProin)
          .clamp(0, 1000000000)
          .toInt(),
      proinStatus: requestedProin > 0 ? 'reserved' : 'none',
      proinRequestedAmount: requestedProin,
      proinReservedAmount: requestedProin,
      status: BookingStatus.pending,
      createdAt: now,
      isInstant: true,
      arrivalMinutes: arrivalMinutes,
    );
    _bookings.add(booking);
    notifyListeners();
    return booking;
  }

  Future<void> sendEmailSignInLink({required String email}) async {}

  Future<void> sendEmailOtp({required String email}) {
    return sendEmailSignInLink(email: email);
  }

  Future<String> sendPhoneOtp({required String phone}) async {
    return 'mock-verification-${normalizePhone(phone)}';
  }

  Future<String> resendPhoneOtp({required String phone}) {
    return sendPhoneOtp(phone: phone);
  }

  Future<UserAccount> loginCustomerWithEmail({
    required String name,
    required String email,
    String? emailLink,
  }) async {
    throw StateError('Customers can only log in with a phone number.');
  }

  Future<UserAccount> loginCustomerWithGmail({
    required String name,
    required String email,
  }) async {
    final contact = email.trim();
    _pendingMockGoogleCustomer = UserAccount(
      id: _stableAccountId(UserRole.customer, contact),
      name: name.trim().isEmpty ? 'Google user' : name.trim(),
      contact: contact,
      provider: LoginProvider.google,
    );
    throw const CustomerPhoneRequiredException();
  }

  Future<UserAccount> completeCustomerGmailPhone({
    required String phone,
  }) async {
    final pending = _pendingMockGoogleCustomer;
    if (pending == null) {
      throw StateError('Sign in with Gmail again before entering the phone.');
    }
    final normalizedPhone = normalizePhone(phone);
    if (!RegExp(r'^\+91\d{10}$').hasMatch(normalizedPhone)) {
      throw StateError('Enter a valid 10-digit Indian mobile number.');
    }
    _claimMockPhoneRole(
      normalizedPhone,
      UserRole.customer,
      accountId: pending.id,
    );
    final account = pending.copyWith(contact: normalizedPhone);
    _pendingMockGoogleCustomer = null;
    _mockCustomerNames[normalizedPhone] = account.name;
    _activateMockRegistration(UserRole.customer, account);
    return account;
  }

  Future<void> cancelPendingCustomerGmailLogin() async {
    _pendingMockGoogleCustomer = null;
  }

  Future<UserAccount> loginCustomerWithPhone({
    String name = '',
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final normalizedPhone = normalizePhone(phone);
    final accountId = _stableAccountId(UserRole.customer, normalizedPhone);
    final existingRole = _mockPhoneRoles[normalizedPhone];
    if (existingRole != null && existingRole != UserRole.customer) {
      _claimMockPhoneRole(
        normalizedPhone,
        UserRole.customer,
        accountId: accountId,
      );
    }
    final storedName = _mockCustomerNames[normalizedPhone]?.trim() ?? '';
    final requestedName = name.trim();
    final customerName = storedName.isNotEmpty ? storedName : requestedName;
    if (customerName.isEmpty) {
      _pendingMockCustomerPhone = normalizedPhone;
      throw const CustomerNameRequiredException();
    }
    _claimMockPhoneRole(
      normalizedPhone,
      UserRole.customer,
      accountId: accountId,
    );
    _mockCustomerNames[normalizedPhone] = customerName;
    _pendingMockCustomerPhone = null;
    final account = UserAccount(
      id: accountId,
      name: customerName,
      contact: normalizedPhone,
      provider: LoginProvider.phone,
    );
    _activateMockRegistration(UserRole.customer, account);
    return account;
  }

  Future<UserAccount> completeCustomerPhoneRegistration({
    required String name,
    required String phone,
  }) async {
    final normalizedPhone = normalizePhone(phone);
    final customerName = name.trim();
    if (customerName.isEmpty) {
      throw StateError('Enter your name to create your customer account.');
    }
    if (_pendingMockCustomerPhone != normalizedPhone) {
      throw StateError(
        'Verify this phone number again before entering a name.',
      );
    }
    return loginCustomerWithPhone(
      name: customerName,
      phone: normalizedPhone,
      verificationId: '',
      smsCode: '',
    );
  }

  Future<void> cancelPendingCustomerPhoneLogin() async {
    _pendingMockCustomerPhone = null;
  }

  Future<UserAccount> loginOwnerWithGmail({
    required String name,
    required String email,
  }) async {
    final contact = email.trim();
    final account = UserAccount(
      id: _stableAccountId(UserRole.owner, contact),
      name: name.trim().isEmpty ? 'Google user' : name.trim(),
      contact: contact,
      provider: LoginProvider.google,
    );
    _activateMockRegistration(UserRole.owner, account);
    return account;
  }

  Future<UserAccount> loginOwnerWithEmail({
    required String name,
    required String email,
    String? emailLink,
  }) async {
    final contact = email.trim();
    final account = UserAccount(
      id: _stableAccountId(UserRole.owner, contact),
      name: name.trim(),
      contact: contact,
      provider: LoginProvider.email,
    );
    _activateMockRegistration(UserRole.owner, account);
    return account;
  }

  Future<UserAccount> loginOwnerWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final contact = normalizePhone(phone);
    final linkedOwnerId = _verifiedOwnerPhones.entries
        .where((entry) => entry.value == contact)
        .firstOrNull
        ?.key;
    final accountId =
        linkedOwnerId ?? _stableAccountId(UserRole.owner, contact);
    _claimMockPhoneRole(contact, UserRole.owner, accountId: accountId);
    final account = UserAccount(
      id: accountId,
      name: 'Phone user',
      contact: contact,
      provider: LoginProvider.phone,
    );
    _activateMockRegistration(UserRole.owner, account);
    return account;
  }

  Future<UserAccount> loginBarberWithGmail({
    required String name,
    required String email,
  }) async {
    throw StateError('Barbers do not have login accounts.');
  }

  Future<UserAccount> loginBarberWithEmail({
    required String name,
    required String email,
    String? phone,
    String? emailLink,
  }) async {
    throw StateError('Barbers do not have login accounts.');
  }

  Future<UserAccount> loginBarberWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    throw StateError('Barbers do not have login accounts.');
  }

  Future<void> updateBookingExtraServices({
    required String bookingId,
    required String requestId,
    required String action,
    Map<String, int> expectedPrices = const {},
  }) async {
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index < 0) throw StateError('Booking not found.');
    final booking = _bookings[index];
    final role = activeRole?.name;
    if ((role == 'owner' && ownerSalonId != booking.salonId) ||
        (role == 'customer' && customerAccount?.id != booking.customerUid) ||
        (role != 'owner' && role != 'customer')) {
      throw StateError('This booking belongs to another account.');
    }
    if (booking.status != BookingStatus.inProgress) {
      throw StateError('Extra services can only be added during your visit.');
    }
    final pending = booking.extraServiceRequest;
    if (action == 'propose') {
      if (pending != null || expectedPrices.isEmpty) {
        throw StateError('Resolve the current request first.');
      }
      final services = expectedPrices.keys
          .map((id) => getService(booking.salonId, id))
          .toList();
      if (services.any(
        (service) =>
            service == null ||
            !service.isAvailable ||
            booking.resolvedServiceIds.contains(service.id) ||
            expectedPrices[service.id] != service.price,
      )) {
        throw StateError('Service details changed. Choose the services again.');
      }
      _bookings[index] = booking.copyWith(
        extraServiceRequest: BookingExtraServiceRequest(
          id: requestId,
          proposedByRole: role!,
          names: {for (final service in services) service!.id: service.name},
          prices: expectedPrices,
          durationMinutes: services.fold(
            0,
            (total, service) => total + service!.durationMinutes,
          ),
        ),
      );
    } else {
      if (pending == null || pending.id != requestId) {
        throw StateError('This request is no longer pending.');
      }
      if ((action == 'cancel') != (pending.proposedByRole == role)) {
        throw StateError(
          'The other person must approve or decline this request.',
        );
      }
      if (action == 'approve') {
        _bookings[index] = booking.copyWith(
          serviceIds: [...booking.resolvedServiceIds, ...pending.prices.keys],
          serviceName: [
            booking.resolvedServiceName(),
            ...pending.names.values,
          ].join(', '),
          servicePrice: booking.servicePrice + pending.amount,
          servicePriceBreakdown: {
            ...booking.servicePriceBreakdown,
            ...pending.prices,
          },
          serviceNameBreakdown: {
            ...booking.serviceNameBreakdown,
            ...pending.names,
          },
          durationMinutes: booking.durationMinutes + pending.durationMinutes,
          customerPayableAmount: booking.customerPayableAmount + pending.amount,
          customerPayableBeforeProin:
              booking.customerPayableBeforeProin + pending.amount,
          salonTotalEarning: booking.salonTotalEarning + pending.amount,
          clearExtraServiceRequest: true,
        );
      } else if (action == 'reject' || action == 'cancel') {
        _bookings[index] = booking.copyWith(clearExtraServiceRequest: true);
      } else {
        throw StateError('Invalid action.');
      }
    }
    notifyListeners();
  }

  Future<void> updateBookingStatus(
    String bookingId,
    BookingStatus status, {
    String? cancellationReason,
    String? cancelledBy,
  }) async {
    _applyBookingStatus(
      bookingId,
      status,
      cancellationReason: cancellationReason,
      cancelledBy: cancelledBy,
    );
  }

  Future<void> updateCustomerArrivalStatus(
    String bookingId,
    CustomerArrivalStatus status,
  ) async {
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index < 0) throw StateError('Booking not found.');
    _bookings[index] = _bookings[index].copyWith(
      arrivalStatus: status,
      arrivalStatusUpdatedAt: DateTime.now(),
      arrivalSharingActive: status == CustomerArrivalStatus.arrived
          ? false
          : _bookings[index].arrivalSharingActive,
    );
    notifyListeners();
  }

  Future<DateTime> startCustomerArrivalSharing(
    String bookingId, {
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double speedMetersPerSecond,
    required DateTime capturedAt,
  }) async {
    final expiresAt = DateTime.now().add(const Duration(hours: 1));
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index < 0) throw StateError('Booking not found.');
    _bookings[index] = _bookings[index].copyWith(
      arrivalStatus: CustomerArrivalStatus.onTheWay,
      arrivalStatusUpdatedAt: DateTime.now(),
      arrivalSharingActive: true,
      arrivalSharingExpiresAt: expiresAt,
    );
    notifyListeners();
    return expiresAt;
  }

  Future<void> updateCustomerArrivalLocation(
    String bookingId, {
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double speedMetersPerSecond,
    required DateTime capturedAt,
  }) async {}

  Future<void> stopCustomerArrivalSharing(String bookingId) async {
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index < 0) throw StateError('Booking not found.');
    _bookings[index] = _bookings[index].copyWith(arrivalSharingActive: false);
    notifyListeners();
  }

  Future<void> cancelBooking(String bookingId, {required String reason}) async {
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty) {
      throw StateError('Choose a cancellation reason.');
    }
    if (_pendingCustomerCancellations.containsKey(bookingId)) {
      throw StateError('This booking is already being cancelled.');
    }
    _pendingCustomerCancellations[bookingId] = normalizedReason;
    notifyListeners();
    try {
      await updateBookingStatus(
        bookingId,
        BookingStatus.cancelled,
        cancellationReason: normalizedReason,
        cancelledBy: 'customer',
      );
    } finally {
      _pendingCustomerCancellations.remove(bookingId);
      notifyListeners();
    }
  }

  Future<void> updateCustomerProfile({
    required String name,
    required String phone,
    required String gender,
    required String birthDate,
    required List<String> preferredStyles,
    String? photoUrl,
    List<String>? stylePhotoUrls,
  }) async {
    final account = _customerAccount;
    if (_activeRole != UserRole.customer || account == null) {
      throw StateError('Log in as a customer before editing your profile.');
    }
    final normalizedName = name.trim();
    final normalizedPhone = normalizePhone(phone);
    if (normalizedName.isEmpty) {
      throw StateError('Enter your name.');
    }
    if (!RegExp(r'^\+91\d{10}$').hasMatch(normalizedPhone)) {
      throw StateError('Enter a valid 10-digit Indian mobile number.');
    }
    final styles = preferredStyles
        .map((style) => style.trim())
        .where((style) => style.isNotEmpty)
        .take(12)
        .toSet()
        .toList(growable: false);
    _customerAccount = account.copyWith(
      name: normalizedName,
      contact: normalizedPhone,
      photoUrl: photoUrl?.trim(),
      gender: gender.trim(),
      birthDate: birthDate.trim(),
      preferredStyles: styles,
      stylePhotoUrls: stylePhotoUrls,
    );
    notifyListeners();
  }

  Future<String> uploadCustomerProfilePhoto({
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError('Choose a photo before uploading.');
    }
    final account = _customerAccount;
    if (account == null) {
      throw StateError('Log in as a customer before uploading a photo.');
    }
    final url =
        'memory://customer-profile/${DateTime.now().microsecondsSinceEpoch}';
    _customerAccount = account.copyWith(photoUrl: url);
    notifyListeners();
    return url;
  }

  Future<String> uploadCustomerStylePhoto({
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError('Choose a style photo before uploading.');
    }
    final account = _customerAccount;
    if (account == null) {
      throw StateError('Log in as a customer before uploading style photos.');
    }
    if (account.stylePhotoUrls.length >= 8) {
      throw StateError('You can save up to 8 preferred-style photos.');
    }
    final url =
        'memory://customer-style/${DateTime.now().microsecondsSinceEpoch}';
    _customerAccount = account.copyWith(
      stylePhotoUrls: [...account.stylePhotoUrls, url],
    );
    notifyListeners();
    return url;
  }

  Future<void> removeCustomerStylePhoto(String photoUrl) async {
    final account = _customerAccount;
    if (account == null) {
      throw StateError('Log in as a customer before editing style photos.');
    }
    _customerAccount = account.copyWith(
      stylePhotoUrls: account.stylePhotoUrls
          .where((url) => url != photoUrl.trim())
          .toList(growable: false),
    );
    notifyListeners();
  }

  Future<void> submitSalonFeedback({
    required String bookingId,
    required int rating,
    required String note,
  }) async {
    final account = _customerAccount;
    final booking = _bookings.where((item) => item.id == bookingId).firstOrNull;
    if (_activeRole != UserRole.customer ||
        account == null ||
        booking == null ||
        booking.customerUid != account.id ||
        booking.status != BookingStatus.completed) {
      throw StateError('Feedback is available after a completed appointment.');
    }
    if (rating < 1 || rating > 5) {
      throw StateError('Choose a rating from 1 to 5.');
    }
    final salon = getSalon(booking.salonId);
    _salonFeedback.removeWhere((item) => item.bookingId == bookingId);
    _salonFeedback.add(
      SalonFeedback(
        bookingId: bookingId,
        customerUid: account.id,
        salonId: booking.salonId,
        salonName: salon?.name ?? 'Salon',
        rating: rating,
        note: note.trim(),
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  Future<void> submitCustomerRating({
    required String bookingId,
    required int rating,
    required String note,
  }) async {
    final booking = _bookings.where((item) => item.id == bookingId).firstOrNull;
    if (_activeRole != UserRole.owner ||
        _ownerAccount == null ||
        booking == null ||
        booking.status != BookingStatus.completed ||
        booking.salonId != ownerSalonId) {
      throw StateError(
        'Customer ratings are available after completed visits.',
      );
    }
    if (rating < 1 || rating > 5) {
      throw StateError('Choose a rating from 1 to 5.');
    }
    final salon = getSalon(booking.salonId);
    _customerSalonRatings.removeWhere((item) => item.bookingId == bookingId);
    _customerSalonRatings.add(
      CustomerSalonRating(
        bookingId: bookingId,
        customerUid: booking.customerUid ?? '',
        salonId: booking.salonId,
        salonName: salon?.name ?? 'Salon',
        rating: rating,
        note: note.trim(),
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  Future<Booking> rescheduleBooking(
    String bookingId, {
    required TimeSlot slot,
  }) async {
    final account = _customerAccount;
    if (_activeRole != UserRole.customer || account == null) {
      throw StateError('Customer login is required before rescheduling.');
    }
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index == -1) {
      throw StateError('Booking not found.');
    }
    final booking = _bookings[index];
    final now = DateTime.now();
    if (booking.customerUid != account.id ||
        booking.isInstant ||
        booking.status != BookingStatus.confirmed ||
        !now.isBefore(booking.start.subtract(const Duration(hours: 2)))) {
      throw StateError('Rescheduling closes two hours before the appointment.');
    }
    if (slot.salonId != booking.salonId ||
        slot.serviceId != booking.serviceId) {
      throw StateError('Choose a new slot for this same appointment.');
    }
    final service = getService(slot.salonId, slot.serviceId);
    final barber = getBarber(slot.barberId);
    if (service == null ||
        !service.isAvailable ||
        barber == null ||
        !barber.isActive ||
        barber.salonId != slot.salonId ||
        !barber.serviceIds.contains(slot.serviceId) ||
        !_isWithinOperatingHours(slot, booking.durationMinutes) ||
        !_isSlotAvailable(slot, booking.durationMinutes)) {
      throw StateError('This appointment is no longer available.');
    }
    _setSlotOccupancy(
      barberId: booking.barberId,
      start: booking.start,
      durationMinutes: booking.durationMinutes,
      occupied: false,
    );
    final updated = booking.copyWith(
      barberId: slot.barberId,
      start: slot.start,
    );
    _bookings[index] = updated;
    _setSlotOccupancy(
      barberId: updated.barberId,
      start: updated.start,
      durationMinutes: updated.durationMinutes,
      occupied: true,
    );
    notifyListeners();
    return updated;
  }

  void _applyBookingStatus(
    String bookingId,
    BookingStatus status, {
    DateTime? now,
    String? cancellationReason,
    String? cancelledBy,
  }) {
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index == -1) {
      throw StateError('Booking not found.');
    }
    var previous = _bookings[index];
    if (previous.status == status) {
      return;
    }
    if (previous.status == BookingStatus.cancelled ||
        previous.status == BookingStatus.rejected ||
        previous.status == BookingStatus.completed) {
      throw StateError(
        'A ${previous.status.label.toLowerCase()} booking cannot be changed.',
      );
    }
    if (previous.isInstant &&
        previous.status == BookingStatus.pending &&
        status == BookingStatus.confirmed) {
      final acceptedStart = (now ?? DateTime.now()).add(
        Duration(minutes: previous.customerArrivalMinutes),
      );
      final eligible =
          barbersForServices(previous.salonId, previous.resolvedServiceIds)
              .where(
                (barber) => _isBarberFree(
                  barber.id,
                  acceptedStart,
                  previous.durationMinutes,
                ),
              )
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      if (eligible.isEmpty) {
        throw StateError(
          'No barber is free for this instant booking. Reject the request.',
        );
      }
      previous = previous.copyWith(barberId: eligible.first.id);
    }
    final booking = _bookingWithStatus(
      previous,
      status,
      now: now ?? DateTime.now(),
      cancellationReason: cancellationReason,
      cancelledBy: cancelledBy,
    );
    _bookings[index] = booking;
    if (status == BookingStatus.cancelled ||
        status == BookingStatus.rejected ||
        status == BookingStatus.completed) {
      _setSlotOccupancy(
        barberId: previous.barberId,
        start: previous.start,
        durationMinutes: previous.durationMinutes,
        occupied: false,
      );
    } else {
      if (booking.start != previous.start ||
          booking.barberId != previous.barberId) {
        _setSlotOccupancy(
          barberId: previous.barberId,
          start: previous.start,
          durationMinutes: previous.durationMinutes,
          occupied: false,
        );
      }
      _setSlotOccupancy(
        barberId: booking.barberId,
        start: booking.start,
        durationMinutes: booking.durationMinutes,
        occupied: true,
      );
    }
    notifyListeners();
  }

  Future<void> updateOwnerSalon({
    required String name,
    required String ownerName,
    required String address,
    String? directionsUrl,
    required String phone,
    String email = '',
    String? logoUrl,
    List<String>? photoUrls,
    required String openTime,
    required String closeTime,
  }) async {
    final ownerAccount = _ownerAccount;
    if (_activeRole != UserRole.owner || ownerAccount == null) {
      throw StateError('Log in as a salon owner before saving a salon.');
    }
    final normalizedPhone = normalizePhone(phone);
    final accountEmail = ownerAccount.contact.trim();
    final normalizedEmail = email.trim().isNotEmpty
        ? email.trim().toLowerCase()
        : (accountEmail.contains('@') ? accountEmail.toLowerCase() : '');
    if (normalizedPhone.isEmpty ||
        !RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(normalizedPhone)) {
      throw FormatException('Enter a valid salon phone number.');
    }
    if (!_isValidEmail(normalizedEmail)) {
      throw FormatException('Enter a valid salon email address.');
    }
    if (name.trim().isEmpty ||
        ownerName.trim().isEmpty ||
        address.trim().isEmpty) {
      throw ArgumentError('Salon name, owner name, and address are required.');
    }
    final openingMinutes = _parseClockMinutes(openTime);
    final closingMinutes = _parseClockMinutes(closeTime);
    if (openingMinutes == null || closingMinutes == null) {
      throw FormatException('Use a valid time such as 9:00 AM or 18:30.');
    }
    if (closingMinutes <= openingMinutes) {
      throw ArgumentError('Closing time must be after opening time.');
    }
    _claimMockPhoneRole(
      normalizedPhone,
      UserRole.owner,
      accountId: ownerAccount.id,
    );
    final wasDraft = ownerSalonOrNull == null;
    final salon = ownerSalon.copyWith(
      name: name.trim(),
      ownerName: ownerName.trim(),
      address: address.trim(),
      directionsUrl: directionsUrl?.trim(),
      phone: normalizedPhone,
      email: normalizedEmail,
      logoUrl: logoUrl?.trim(),
      photoUrls: photoUrls
          ?.map((url) => url.trim())
          .where((url) => url.isNotEmpty)
          .toList(),
      openTime: formatSalonClockTime(openTime),
      closeTime: formatSalonClockTime(closeTime),
    );
    _replaceSalon(salon);
    if (wasDraft) {
      _ownerDraftServices.clear();
    }
    _ownerProfileCompleted = true;
    notifyListeners();
  }

  Future<void> refreshOwnerPaymentDetails() async {
    if (!hasActiveOwnerSession) {
      _ownerPaymentUpiId = '';
      _ownerPaymentQrCodeUrl = '';
      notifyListeners();
    }
  }

  Future<void> saveOwnerPaymentUpiId(String upiId) async {
    if (!hasActiveOwnerSession || ownerSalonOrNull == null) {
      throw StateError('Save the salon profile before adding payment details.');
    }
    _ownerPaymentUpiId = _normalizeUpiId(upiId);
    notifyListeners();
  }

  Future<String> uploadOwnerPaymentQrCode({
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) {
    throw UnsupportedError('Payment QR upload needs Firebase Storage.');
  }

  Future<void> removeOwnerPaymentQrCode() async {
    _ownerPaymentQrCodeUrl = '';
    notifyListeners();
  }

  Future<String> uploadOwnerSalonPhoto({
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) {
    throw UnsupportedError('Photo upload needs Firebase Storage.');
  }

  Future<void> removeOwnerSalonPhoto(String photoUrl) async {
    final trimmed = photoUrl.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final nextPhotos = ownerSalon.photoUrls
        .where((url) => url.trim() != trimmed)
        .toList();
    _replaceSalon(ownerSalon.copyWith(photoUrls: nextPhotos));
    notifyListeners();
  }

  Future<void> addOwnerService({
    required String name,
    required String category,
    required int price,
    required int durationMinutes,
    bool isAvailable = true,
    bool instantBookingEnabled = true,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError('Service name is required.');
    }
    if (price <= 0 || durationMinutes <= 0) {
      throw ArgumentError('Price and duration must be greater than zero.');
    }
    final service = SalonService(
      id: 'service-${_serviceCounter++}',
      name: name.trim(),
      category: category.trim().isEmpty ? 'Grooming' : category.trim(),
      price: price,
      durationMinutes: durationMinutes,
      isAvailable: isAvailable,
      instantBookingEnabled: instantBookingEnabled,
      isCustom: true,
    );
    _replaceOwnerServices([...ownerSalon.services, service]);
    notifyListeners();
  }

  Future<void> updateOwnerService({
    required String serviceId,
    required String name,
    required String category,
    required int price,
    required int durationMinutes,
    bool? isAvailable,
    bool? instantBookingEnabled,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError('Service name is required.');
    }
    if (price <= 0 || durationMinutes <= 0) {
      throw ArgumentError('Price and duration must be greater than zero.');
    }
    final salon = ownerSalon;
    final index = salon.services.indexWhere(
      (service) => service.id == serviceId,
    );
    if (index == -1) {
      throw StateError('Service not found.');
    }
    final services = [...salon.services];
    services[index] = services[index].copyWith(
      name: name.trim(),
      category: category.trim().isEmpty ? 'Grooming' : category.trim(),
      price: price,
      durationMinutes: durationMinutes,
      isAvailable: isAvailable,
      instantBookingEnabled: instantBookingEnabled,
    );
    _replaceOwnerServices(services);
    notifyListeners();
  }

  Future<int> addOwnerServicesFromCatalog({
    Iterable<String>? serviceNames,
  }) async {
    final salon = ownerSalon;
    final existingNames = salon.services
        .map((service) => normalizeServiceName(service.name))
        .toSet();
    final servicesToAdd = <SalonService>[];
    for (final template in serviceCatalog) {
      final normalizedName = normalizeServiceName(template.name);
      if (existingNames.contains(normalizedName)) {
        continue;
      }
      servicesToAdd.add(
        SalonService(
          id: 'service-${_serviceCounter++}',
          name: template.name,
          category: template.category,
          price: template.price,
          durationMinutes: template.durationMinutes,
        ),
      );
    }
    if (servicesToAdd.isEmpty) {
      return 0;
    }
    _replaceOwnerServices([...salon.services, ...servicesToAdd]);
    notifyListeners();
    return servicesToAdd.length;
  }

  Future<void> removeOwnerService(String serviceId) async {
    final salon = ownerSalon;
    final nextServices = salon.services
        .where((service) => service.id != serviceId)
        .toList();
    _replaceOwnerServices(nextServices);
    for (var i = 0; i < _barbers.length; i++) {
      _barbers[i] = _barbers[i].copyWith(
        serviceIds: _barbers[i].serviceIds
            .where((id) => id != serviceId)
            .toList(),
      );
    }
    notifyListeners();
  }

  Future<void> addOwnerBarber({
    required String name,
    String phone = '',
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    final barber = _newOwnerBarber(
      name: name,
      phone: phone,
      speciality: speciality,
      experienceYears: experienceYears,
      resumeSummary: resumeSummary,
      serviceIds: serviceIds,
    );
    _barbers.add(barber);
    notifyListeners();
  }

  Barber _newOwnerBarber({
    required String name,
    required String phone,
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) {
    final normalizedPhone = normalizePhone(phone);
    if (_barbers.any(
      (barber) =>
          barber.isActive &&
          normalizedPhone.isNotEmpty &&
          barber.phone == normalizedPhone,
    )) {
      throw StateError('A barber with this phone number already exists.');
    }
    final assignedServiceIds = serviceIds.isEmpty
        ? ownerSalon.services.map((service) => service.id).toList()
        : serviceIds;
    return Barber(
      id: _newEntityId('barber', _barberCounter++),
      salonId: ownerSalonId,
      name: name.trim(),
      phone: normalizedPhone,
      email: '',
      speciality: speciality.trim().isEmpty ? 'Grooming expert' : speciality,
      experienceYears: experienceYears,
      resumeSummary: resumeSummary.trim().isEmpty
          ? 'Customer-first grooming professional.'
          : resumeSummary.trim(),
      serviceIds: assignedServiceIds,
    );
  }

  Future<void> updateOwnerBarber({
    required String barberId,
    required String name,
    String phone = '',
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    final index = _barbers.indexWhere(
      (barber) =>
          barber.id == barberId &&
          barber.salonId == ownerSalonId &&
          barber.isActive,
    );
    if (index == -1) {
      throw StateError('This barber is not part of your active salon team.');
    }
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw StateError('Barber name is required.');
    }
    final normalizedPhone = normalizePhone(phone);
    if (_barbers.any(
      (barber) =>
          barber.id != barberId &&
          barber.isActive &&
          normalizedPhone.isNotEmpty &&
          barber.phone == normalizedPhone,
    )) {
      throw StateError('A barber with this phone number already exists.');
    }
    final availableServiceIds = ownerSalon.services
        .map((service) => service.id)
        .toSet();
    final assignedServiceIds = serviceIds.isEmpty
        ? availableServiceIds.toList()
        : serviceIds
              .where(availableServiceIds.contains)
              .toSet()
              .toList(growable: false);
    final existing = _barbers[index];
    _barbers[index] = existing.copyWith(
      name: trimmedName,
      phone: normalizedPhone,
      speciality: speciality.trim().isEmpty
          ? 'Grooming expert'
          : speciality.trim(),
      experienceYears: experienceYears < 0 ? 0 : experienceYears,
      resumeSummary: resumeSummary.trim().isEmpty
          ? 'Customer-first grooming professional.'
          : resumeSummary.trim(),
      serviceIds: assignedServiceIds,
    );
    notifyListeners();
  }

  Future<void> submitJoinRequest({
    required String salonId,
    required String barberName,
    required String barberPhone,
    String barberEmail = '',
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    throw StateError('Barbers do not have login accounts or join requests.');
  }

  Future<void> approveJoinRequest(String requestId) async {
    final index = _joinRequests.indexWhere(
      (request) => request.id == requestId,
    );
    if (index == -1) {
      return;
    }
    final request = _joinRequests[index];
    final barber = Barber(
      id: _newEntityId('barber', _barberCounter++),
      uid: request.requesterUid,
      salonId: request.salonId,
      name: request.barberName,
      phone: request.barberPhone,
      email: request.barberEmail,
      speciality: request.speciality,
      experienceYears: request.experienceYears,
      resumeSummary: request.resumeSummary,
      serviceIds: request.serviceIds,
    );
    _joinRequests[index] = request.copyWith(status: JoinRequestStatus.approved);
    _barbers.add(barber);
    if (_currentJoinRequestId == requestId) {
      _currentBarberId = barber.id;
    }
    notifyListeners();
  }

  Future<void> removeBarber(String barberId) async {
    final index = _barbers.indexWhere((barber) => barber.id == barberId);
    if (index == -1) {
      return;
    }
    _barbers[index] = _barbers[index].copyWith(isActive: false);
    if (_currentBarberId == barberId) {
      _currentBarberId = null;
    }
    notifyListeners();
  }

  Future<void> rejectJoinRequest(String requestId) async {
    final index = _joinRequests.indexWhere(
      (request) => request.id == requestId,
    );
    if (index == -1) {
      return;
    }
    _joinRequests[index] = _joinRequests[index].copyWith(
      status: JoinRequestStatus.rejected,
    );
    if (_currentJoinRequestId == requestId) {
      _currentBarberId = null;
    }
    notifyListeners();
  }

  Future<void> withdrawJoinRequest(String requestId) async {
    final index = _joinRequests.indexWhere(
      (request) => request.id == requestId,
    );
    if (index == -1) {
      throw StateError('Join request not found.');
    }
    final request = _joinRequests[index];
    if (request.status != JoinRequestStatus.pending) {
      throw StateError('Only a pending request can be withdrawn.');
    }
    _joinRequests[index] = request.copyWith(
      status: JoinRequestStatus.withdrawn,
    );
    if (_currentJoinRequestId == requestId) {
      _currentBarberId = null;
    }
    notifyListeners();
  }

  int dailyCollection(String salonId) {
    return bookingsForSalon(salonId)
        .where(
          (booking) =>
              _isToday(booking.start) &&
              booking.status == BookingStatus.completed,
        )
        .fold(0, (total, booking) {
          return total + booking.salonTotalEarning;
        });
  }

  int totalCollection(String salonId) {
    return bookingsForSalon(salonId)
        .where((booking) => booking.status == BookingStatus.completed)
        .fold(0, (total, booking) => total + booking.salonTotalEarning);
  }

  int totalOriginalServiceValue(String salonId) => bookingsForSalon(salonId)
      .where((booking) => booking.status == BookingStatus.completed)
      .fold(0, (total, booking) => total + _bookingPrice(booking));

  int totalCustomerCounterCollection(String salonId) =>
      bookingsForSalon(salonId)
          .where((booking) => booking.status == BookingStatus.completed)
          .fold(0, (total, booking) => total + booking.customerPayableAmount);

  int totalPritzeEarnings(String salonId) => bookingsForSalon(salonId)
      .where((booking) => booking.status == BookingStatus.completed)
      .fold(0, (total, booking) => total + booking.totalPritzeContribution);

  int totalDiscountPritzeEarnings(String salonId) => bookingsForSalon(salonId)
      .where((booking) => booking.status == BookingStatus.completed)
      .fold(0, (total, booking) => total + booking.pritzePayoutAmount);

  int totalProinReimbursements(String salonId) => bookingsForSalon(salonId)
      .where((booking) => booking.status == BookingStatus.completed)
      .fold(0, (total, booking) => total + booking.proinRedeemedAmount);

  int barberTotalEarnings(String barberId) {
    return bookingsForBarber(barberId)
        .where((booking) => booking.status == BookingStatus.completed)
        .fold(0, (total, booking) => total + _bookingPrice(booking));
  }

  int barberDailyEarnings(String barberId, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    return bookingsForBarber(barberId)
        .where(
          (booking) =>
              booking.status == BookingStatus.completed &&
              booking.start.year == reference.year &&
              booking.start.month == reference.month &&
              booking.start.day == reference.day,
        )
        .fold(0, (total, booking) => total + _bookingPrice(booking));
  }

  int barberMonthlyEarnings(String barberId, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    return bookingsForBarber(barberId)
        .where(
          (booking) =>
              booking.status == BookingStatus.completed &&
              booking.start.year == reference.year &&
              booking.start.month == reference.month,
        )
        .fold(0, (total, booking) => total + _bookingPrice(booking));
  }

  int bookingEarning(Booking booking) => booking.salonTotalEarning;

  int todayBookingCount(String salonId) {
    return bookingsForSalon(salonId).where((booking) {
      return _isToday(booking.start) &&
          booking.status != BookingStatus.cancelled &&
          booking.status != BookingStatus.rejected;
    }).length;
  }

  int countByStatus(String salonId, BookingStatus status) {
    return bookingsForSalon(
      salonId,
    ).where((booking) => booking.status == status).length;
  }

  int todayCountByStatus(String salonId, BookingStatus status) {
    return bookingsForSalon(salonId).where((booking) {
      return _isToday(booking.start) && booking.status == status;
    }).length;
  }

  Map<String, int> barberWorkCount(String salonId) {
    final result = <String, int>{};
    for (final barber in barbersForSalon(salonId)) {
      result[barber.id] = bookingsForBarber(barber.id)
          .where(
            (booking) =>
                _isToday(booking.start) &&
                booking.status != BookingStatus.cancelled &&
                booking.status != BookingStatus.rejected,
          )
          .length;
    }
    return result;
  }

  Booking? currentBookingForBarber(String barberId) {
    final now = DateTime.now();
    final started =
        bookingsForBarber(barberId)
            .where((booking) => booking.status == BookingStatus.inProgress)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (started.isNotEmpty) {
      return started.first;
    }

    final candidates = bookingsForBarber(barberId).where((booking) {
      final end = booking.start.add(Duration(minutes: booking.durationMinutes));
      return booking.status == BookingStatus.confirmed &&
          now.isAfter(booking.start) &&
          now.isBefore(end);
    }).toList();
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) => a.start.compareTo(b.start));
    return candidates.first;
  }

  Booking? nextBookingForBarber(String barberId) {
    final now = DateTime.now();
    final nextStatuses = {BookingStatus.pending, BookingStatus.confirmed};
    final candidates = bookingsForBarber(barberId).where((booking) {
      return nextStatuses.contains(booking.status) &&
          booking.start.isAfter(now);
    }).toList();
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) => a.start.compareTo(b.start));
    return candidates.first;
  }

  Map<String, int> serviceRevenue(String salonId) {
    final result = <String, int>{};
    for (final booking in bookingsForSalon(salonId)) {
      if (booking.status != BookingStatus.completed) {
        continue;
      }
      final totalEarning = booking.salonTotalEarning;
      if (totalEarning <= 0) {
        continue;
      }
      final breakdown = booking.servicePriceBreakdown.isNotEmpty
          ? booking.servicePriceBreakdown
          : <String, int>{booking.serviceId: booking.servicePrice};
      final originalTotal = breakdown.values.fold<int>(
        0,
        (total, price) => total + price,
      );
      if (originalTotal <= 0) {
        continue;
      }
      var assigned = 0;
      final entries = breakdown.entries.toList(growable: false);
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        final earning = index == entries.length - 1
            ? totalEarning - assigned
            : (totalEarning * entry.value / originalTotal).floor();
        assigned += earning;
        result[entry.key] = (result[entry.key] ?? 0) + earning;
      }
    }
    return result;
  }

  String formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final difference = target.difference(today).inDays;
    if (difference == 0) {
      return 'Today';
    }
    if (difference == 1) {
      return 'Tomorrow';
    }
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${date.day} ${months[date.month - 1]}';
  }

  String formatTime(DateTime date) {
    final hour = date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour:$minute $period';
  }

  String countdownTo(DateTime target, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final difference = target.difference(reference);
    if (difference.isNegative) {
      return 'Time passed';
    }
    final totalMinutes =
        difference.inMinutes + (difference.inSeconds % 60 == 0 ? 0 : 1);
    if (totalMinutes < 1) {
      return 'Under 1 min';
    }
    if (totalMinutes < 60) {
      return '$totalMinutes min left';
    }
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (minutes == 0) {
      return '$hours hr left';
    }
    return '$hours hr $minutes min left';
  }

  void _activateRole(UserRole role, UserAccount account) {
    _activeRole = role;
    _customerAccount = role == UserRole.customer ? account : null;
    _ownerAccount = role == UserRole.owner ? account : null;
    _barberAccount = role == UserRole.barber ? account : null;
    _clearInactiveRoleState(role);
    unawaited(_persistOwnerAlertsEnabled(role == UserRole.owner));
    // A role is only safe to restore when it belongs to the same Firebase
    // account. Keeping the uid beside it prevents a customer from inheriting
    // an owner's locally cached dashboard (and vice versa).
    unawaited(_persistActiveRole(role, accountId: account.id));
    unawaited(_restoreNotificationPreferences(role));
    notifyListeners();
  }

  void _activateMockRegistration(UserRole role, UserAccount account) {
    _referralOnboardingRequired = _mockRegisteredAccountIds.add(account.id);
    _activateRole(role, account);
  }

  String _stableAccountId(UserRole role, String contact) {
    final safeContact = contact
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (safeContact.isEmpty) {
      return '${role.name}-${_accountCounter++}';
    }
    return '${role.name}-$safeContact';
  }

  Future<void> _restoreNotificationPreferences(UserRole role) async {
    final viewerKey = _notificationViewerKey(role);
    _notificationPreferencesReadyViewers.remove(viewerKey);
    try {
      final preferences = await SharedPreferences.getInstance();
      _seenNotificationKeys[viewerKey] =
          preferences
              .getStringList('$_seenNotificationsPreferencePrefix$viewerKey')
              ?.toSet() ??
          <String>{};
      _dismissedNotificationKeys[viewerKey] =
          preferences
              .getStringList(
                '$_dismissedNotificationsPreferencePrefix$viewerKey',
              )
              ?.toSet() ??
          <String>{};
      final storedReadAt = preferences.getInt(
        '$_notificationsReadAtPreferencePrefix$viewerKey',
      );
      if (storedReadAt == null) {
        // Existing booking history must not become unread merely because the
        // app was installed, updated, or its Firestore stream reconnected.
        final baseline = DateTime.now();
        _notificationsReadAt[viewerKey] = baseline;
        await preferences.setInt(
          '$_notificationsReadAtPreferencePrefix$viewerKey',
          baseline.millisecondsSinceEpoch,
        );
      } else {
        _notificationsReadAt[viewerKey] = DateTime.fromMillisecondsSinceEpoch(
          storedReadAt,
        );
      }
    } catch (_) {
      // Notification history can safely remain in memory if storage is unavailable.
    } finally {
      _notificationPreferencesReadyViewers.add(viewerKey);
      notifyListeners();
    }
  }

  Future<void> _persistNotificationSet(
    String prefix,
    String viewerKey,
    Set<String> keys,
  ) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList('$prefix$viewerKey', keys.toList());
    } catch (_) {
      // Keep the in-memory behavior if local persistence is unavailable.
    }
  }

  Future<void> _persistNotificationReadAt(
    String viewerKey,
    DateTime readAt,
  ) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(
        '$_notificationsReadAtPreferencePrefix$viewerKey',
        readAt.millisecondsSinceEpoch,
      );
    } catch (_) {
      // Keep the in-memory behavior if local persistence is unavailable.
    }
  }

  void _clearInactiveRoleState(UserRole role) {
    if (role != UserRole.barber) {
      _currentBarberId = null;
      _currentJoinRequestId = null;
    }
    if (role != UserRole.owner) {
      _ownerDraftServices.clear();
    }
  }

  Future<void> _restoreActiveRole({String? accountId}) async {
    try {
      await _rolePersistenceQueue;
      final preferences = await SharedPreferences.getInstance();
      final roleName = preferences.getString(_activeRolePreferenceKey);
      final role = _roleFromName(roleName);
      if (accountId != null) {
        _activeRole = cachedRoleForAccount(
          role: role,
          cachedAccountId: preferences.getString(
            _activeRoleAccountIdPreferenceKey,
          ),
          currentAccountId: accountId,
        );
        if (_activeRole != null) {
          notifyListeners();
        }
        return;
      }
      if (role != null && role != UserRole.barber) {
        _activeRole = role;
        notifyListeners();
      }
    } catch (_) {
      // Local role persistence is a convenience; the app can still run without it.
    }
  }

  Future<void> _persistActiveRole(UserRole? role, {String? accountId}) {
    final operation = _rolePersistenceQueue.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        if (role == null) {
          await preferences.remove(_activeRolePreferenceKey);
          await preferences.remove(_activeRoleAccountIdPreferenceKey);
        } else {
          await preferences.setString(_activeRolePreferenceKey, role.name);
          if (accountId == null || accountId.trim().isEmpty) {
            await preferences.remove(_activeRoleAccountIdPreferenceKey);
          } else {
            await preferences.setString(
              _activeRoleAccountIdPreferenceKey,
              accountId,
            );
          }
        }
      } catch (_) {
        // Ignore local persistence failures; Firebase remains the source of truth.
      }
    });
    _rolePersistenceQueue = operation;
    return operation;
  }

  Future<void> _persistOwnerAlertsEnabled(bool enabled) async {
    try {
      // Must be the store the FCM isolate reads. Writing it through the
      // default preferences file leaves the background alert permanently off.
      await OwnerAlertPreferences().setEnabled(enabled);
    } catch (_) {
      // Firebase and the foreground role check remain the primary safeguards.
    }
  }

  UserRole? _roleFromName(String? value) {
    return UserRole.values.where((role) => role.name == value).firstOrNull;
  }

  void _setSaving(bool value) {
    if (_isSaving == value) {
      return;
    }
    _isSaving = value;
    notifyListeners();
  }

  void _setInstantBookingSaving(bool value) {
    if (_isInstantBookingSaving == value) {
      return;
    }
    _isInstantBookingSaving = value;
    notifyListeners();
  }

  void _expireSlotCache(DateTime now) {
    final createdAt = _slotCacheCreatedAt;
    if (createdAt != null && now.difference(createdAt).inSeconds >= 30) {
      _slotCache.clear();
      _slotCacheCreatedAt = null;
    }
  }

  @override
  void notifyListeners() {
    _slotCache.clear();
    _slotCacheCreatedAt = null;
    _syncCustomerInstantExpiryTimer();
    super.notifyListeners();
  }

  void _setSyncError(Object error) {
    _lastSyncError =
        'Could not save to Firebase. Check your internet connection and try again.';
    if (kDebugMode) {
      _lastSyncError = 'Could not save to Firebase: $error';
    }
    notifyListeners();
  }

  String _newEntityId(String prefix, int counter) {
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$counter';
  }

  bool _isBarberFree(String barberId, DateTime start, int durationMinutes) {
    final candidateEnd = start.add(Duration(minutes: durationMinutes));
    if (_slotSegmentStarts(start, durationMinutes).any(
      (segment) => _occupiedSlotKeys.contains(_slotKey(barberId, segment)),
    )) {
      return false;
    }
    return !_bookings.any((booking) {
      if (booking.barberId != barberId ||
          booking.status == BookingStatus.cancelled ||
          booking.status == BookingStatus.rejected) {
        return false;
      }
      final bookingEnd = booking.start.add(
        Duration(minutes: booking.durationMinutes),
      );
      return booking.start.isBefore(candidateEnd) && start.isBefore(bookingEnd);
    });
  }

  bool _isSlotAvailable(TimeSlot slot, int durationMinutes) {
    return _isBarberFree(slot.barberId, slot.start, durationMinutes);
  }

  bool _isWithinOperatingHours(TimeSlot slot, int durationMinutes) {
    final salon = getSalon(slot.salonId);
    if (salon == null) {
      return false;
    }
    final openMinutes = _parseClockMinutes(salon.openTime);
    final closeMinutes = _parseClockMinutes(salon.closeTime);
    if (openMinutes == null || closeMinutes == null) {
      return false;
    }
    final startMinutes = slot.start.hour * 60 + slot.start.minute;
    return startMinutes >= openMinutes &&
        startMinutes + durationMinutes <= closeMinutes;
  }

  void _setSlotOccupancy({
    required String barberId,
    required DateTime start,
    required int durationMinutes,
    required bool occupied,
  }) {
    for (final segment in _slotSegmentStarts(start, durationMinutes)) {
      final key = _slotKey(barberId, segment);
      if (occupied) {
        _occupiedSlotKeys.add(key);
      } else {
        _occupiedSlotKeys.remove(key);
      }
    }
  }

  List<TimeSlot> _deduplicateAnyBarberSlots(List<TimeSlot> slots) {
    final grouped = <DateTime, List<TimeSlot>>{};
    for (final slot in slots) {
      grouped.putIfAbsent(slot.start, () => []).add(slot);
    }
    return [
      for (final entry in grouped.entries)
        entry.value[(entry.key.millisecondsSinceEpoch ~/
                const Duration(minutes: 30).inMilliseconds) %
            entry.value.length],
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  Booking _bookingWithStatus(
    Booking booking,
    BookingStatus status, {
    required DateTime now,
    String? cancellationReason,
    String? cancelledBy,
  }) {
    if (booking.status == BookingStatus.pending &&
        status == BookingStatus.confirmed) {
      final acceptedAt = now;
      return booking.copyWith(
        status: status,
        acceptedAt: acceptedAt,
        start: booking.isInstant
            ? acceptedAt.add(Duration(minutes: booking.customerArrivalMinutes))
            : booking.start,
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
    }
    if (status == BookingStatus.inProgress) {
      return booking.copyWith(
        status: status,
        startedAt: now,
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
    }
    if (status == BookingStatus.completed) {
      return booking.copyWith(
        status: status,
        completedAt: now,
        clearExtraServiceRequest: true,
        discountStatus: booking.hasDiscount ? 'redeemed' : 'none',
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
    }
    if (status == BookingStatus.cancelled) {
      return booking.copyWith(
        status: status,
        cancelledAt: now,
        clearExtraServiceRequest: true,
        discountStatus: booking.hasDiscount ? 'released' : 'none',
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
    }
    if (status == BookingStatus.rejected) {
      return booking.copyWith(
        status: status,
        rejectedAt: now,
        clearExtraServiceRequest: true,
        discountStatus: booking.hasDiscount ? 'released' : 'none',
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
    }
    return booking.copyWith(
      status: status,
      cancellationReason: cancellationReason,
      cancelledBy: cancelledBy,
    );
  }

  int _bookingPrice(Booking booking) {
    if (booking.servicePrice > 0) {
      return booking.servicePrice;
    }
    return getService(booking.salonId, booking.serviceId)?.price ?? 0;
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  void _replaceSalon(Salon salon) {
    final index = _salons.indexWhere((item) => item.id == salon.id);
    if (index != -1) {
      _salons[index] = salon;
    } else {
      _salons.add(salon);
    }
  }

  void _replaceOwnerServices(List<SalonService> services) {
    final persistedSalon = ownerSalonOrNull;
    if (persistedSalon == null) {
      _ownerDraftServices
        ..clear()
        ..addAll(services);
      return;
    }
    _replaceSalon(persistedSalon.copyWith(services: services));
  }

  Salon _draftOwnerSalon() {
    final owner = _ownerAccount;
    return Salon(
      id: ownerSalonId,
      name: '',
      ownerName: owner?.name ?? '',
      address: '',
      phone: owner?.provider == LoginProvider.phone ? owner!.contact : '',
      email: owner?.contact.contains('@') == true ? owner!.contact : '',
      logoUrl: '',
      photoUrls: const [],
      distanceLabel: 'Nearby',
      rating: 0,
      reviewCount: 0,
      openTime: '9:00 AM',
      closeTime: '8:00 PM',
      isOpen: true,
      instantBookingsEnabled: true,
      instantBookingsPausedDate: '',
      approvalStatus: 'pending',
      services: List.unmodifiable(_ownerDraftServices),
    );
  }

  @override
  void dispose() {
    _customerInstantExpiryTimer?.cancel();
    super.dispose();
  }
}

class _MockVisibleCheckoutDiscountCampaign {
  final String campaignId;
  final String campaignName;
  final String salonId;
  final Set<String> serviceIds;
  final String discountType;
  final double discountPercent;
  final int fixedDiscountAmount;
  final int maximumDiscountAmount;
  final String voucherMaskedCode;
  final bool active;

  const _MockVisibleCheckoutDiscountCampaign({
    required this.campaignId,
    required this.campaignName,
    required this.salonId,
    required this.serviceIds,
    required this.discountType,
    required this.discountPercent,
    required this.fixedDiscountAmount,
    required this.maximumDiscountAmount,
    required this.voucherMaskedCode,
    required this.active,
  });
}

/// An optimistic booking only covers the round trip to the server. Once the
/// window passes the server is authoritative even when the two disagree.
/// Holding a stale copy indefinitely hid every later change to that booking —
/// an accepted request never became startable — and the only way to clear it
/// was to kill the app, because this map lives in memory.
const optimisticBookingLifetime = Duration(seconds: 30);

class OptimisticBooking {
  OptimisticBooking(this.booking, {DateTime? now})
    : expiresAt = (now ?? DateTime.now()).add(optimisticBookingLifetime);

  final Booking booking;
  final DateTime expiresAt;

  bool hasExpired(DateTime now) => !now.isBefore(expiresAt);
}

/// Server bookings win unless an optimistic copy is still inside its window.
/// Entries the server has caught up with, and entries that have outlived the
/// window, are dropped from [optimistic] so a booking can never be pinned to
/// a stale status for the rest of the session.
Map<String, Booking> reconcileOptimisticBookings({
  required Map<String, Booking> serverBookings,
  required Map<String, OptimisticBooking> optimistic,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final merged = Map<String, Booking>.from(serverBookings);
  for (final entry in optimistic.entries.toList()) {
    final serverBooking = merged[entry.key];
    if (entry.value.hasExpired(at) ||
        serverBooking?.status == entry.value.booking.status) {
      optimistic.remove(entry.key);
    } else if (serverBooking != null) {
      merged[entry.key] = entry.value.booking;
    }
  }
  return merged;
}

class FirebaseAppState extends AppState with WidgetsBindingObserver {
  final FirebaseFirestore firestore;
  final FirebaseFunctions functions;
  final FirebaseAuth auth;
  final FirebaseMessaging messaging;
  final FirebaseStorage storage;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _googleInitialized = false;
  bool _localNotificationsReady = false;
  bool _pushPermissionSetupStarted = false;
  Future<void>? _localNotificationsInitialization;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final List<StreamSubscription<Object?>> _privateSubscriptions = [];
  final Map<String, Map<String, Booking>> _bookingSnapshots = {};
  final Map<String, int> _phoneResendTokens = <String, int>{};
  final Map<String, int> _phoneOtpGenerations = <String, int>{};
  final Map<String, int> _autoVerifiedPhoneGenerations = <String, int>{};
  final Map<String, PhoneAuthCredential> _autoVerifiedPhoneCredentials =
      <String, PhoneAuthCredential>{};
  final Map<String, String> _currentPhoneVerificationIds = <String, String>{};
  final StreamController<String> _autoVerifiedPhoneController =
      StreamController<String>.broadcast();
  final Map<String, OptimisticBooking> _optimisticBookingUpdates =
      <String, OptimisticBooking>{};
  final Set<String> _bookingStatusRequests = {};
  Future<ProinWalletSummary>? _customerWalletRefresh;
  String? _customerWalletRefreshUid;
  final Map<String, DateTime> _suppressedOwnerBookingAlerts =
      <String, DateTime>{};
  UserRole? _pendingFirebaseLoginRole;
  String? _pendingCustomerRegistrationPhone;
  String? _pendingCustomerRegistrationUid;
  UserAccount? _pendingGoogleCustomerAccount;
  String? _pendingGoogleCustomerUid;
  bool _suppressTokenRegistration = false;
  String? _registeredMessagingToken;
  Timer? _messagingTokenRetryTimer;
  int _messagingTokenRetryAttempt = 0;
  Timer? _ownerBookingAlarmTimer;
  int _ownerBookingAlarmGeneration = 0;
  bool _ownerBookingAlarmRefreshRunning = false;
  Timer? _ownerBookingDecisionRetryTimer;
  bool _retryingOwnerBookingDecisions = false;
  final Set<String> _notificationDecisionsInFlight = {};
  bool _isRestoringSession = true;
  bool _disposed = false;
  int _accountRestoreGeneration = 0;
  String? _startupRestoreUid;
  DateTime? _lastCallableCredentialRefreshAt;

  FirebaseAppState({
    required this.firestore,
    required this.functions,
    required this.auth,
    required this.messaging,
    FirebaseStorage? storage,
  }) : storage = storage ?? FirebaseStorage.instance,
       super(restoreActiveRole: false) {
    WidgetsBinding.instance.addObserver(this);
    // Capture an Accept/Reject launch before loading account or booking data.
    unawaited(
      _initializeLocalNotifications().catchError((Object error) {
        _setSyncError(error);
      }),
    );
    unawaited(restoreSignedInUser());
    // Attaching every Firestore and notification listener can synchronously
    // hydrate large local caches. Do it after Flutter has painted the launch
    // frame so neither Android nor iOS waits on that work to become visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _connectFirestore();
      _configurePushNotifications();
    });
  }

  bool _salonsLoaded = false;

  @override
  bool get salonsLoaded => _salonsLoaded;

  @override
  bool get usesFirebase => true;

  @override
  List<Salon> get discoverableSalons => List.unmodifiable(
    super.discoverableSalons.where((salon) => salon.isApproved),
  );

  @override
  List<Salon> get bookableSalons => super.bookableSalons
      .where((salon) => salon.isApproved)
      .toList(growable: false);

  @override
  bool get hasActiveCustomerSession =>
      super.hasActiveCustomerSession &&
      auth.currentUser?.uid == customerAccount?.id;

  @override
  bool get hasActiveOwnerSession =>
      super.hasActiveOwnerSession && auth.currentUser?.uid == ownerAccount?.id;

  @override
  bool get hasActiveBarberSession =>
      super.hasActiveBarberSession &&
      auth.currentUser?.uid == barberAccount?.id;

  @override
  Future<ReferralCodes> ensureReferralCodes() {
    return _runFirebaseSave(() async {
      final response = await functions
          .httpsCallable('getReferralCodes')
          .call<Map<String, dynamic>>();
      final customerCode =
          response.data['customerInviteCode']
              ?.toString()
              .trim()
              .toUpperCase() ??
          '';
      final salonCode =
          response.data['salonInviteCode']?.toString().trim().toUpperCase() ??
          '';
      if (!RegExp(r'^(?=.*[A-Z])(?=.*\d)[A-Z\d]{6}$').hasMatch(customerCode)) {
        throw StateError('The server did not return a valid referral code.');
      }
      return ReferralCodes(
        customerInviteCode: customerCode,
        salonInviteCode: salonCode,
      );
    });
  }

  @override
  Future<ReferralSummary> getReferralSummary() {
    return _runFirebaseSave(() async {
      final response = await functions
          .httpsCallable('getReferralSummary')
          .call<Map<String, dynamic>>();
      final data = response.data;
      return ReferralSummary(
        pendingCustomerCount: _int(data['pendingCustomerCount'], 0),
        qualifiedCustomerCount: _int(data['qualifiedCustomerCount'], 0),
        pendingSalonCount: _int(data['pendingSalonCount'], 0),
        qualifiedSalonCount: _int(data['qualifiedSalonCount'], 0),
        customerInviterRewardProin: _int(data['customerInviterRewardProin'], 0),
        customerReferredRewardProin: _int(
          data['customerReferredRewardProin'],
          0,
        ),
        salonInviterRewardProin: _int(data['salonInviterRewardProin'], 0),
        salonReferredRewardProin: _int(data['salonReferredRewardProin'], 0),
        earnedCustomerReferralProin: _int(
          data['earnedCustomerReferralProin'],
          0,
        ),
        earnedSalonReferralProin: _int(data['earnedSalonReferralProin'], 0),
        earnedReferralProin: _int(data['earnedReferralProin'], 0),
      );
    });
  }

  @override
  Future<void> completeReferralOnboarding({String referralCode = ''}) {
    return _runFirebaseSave(() async {
      await functions
          .httpsCallable('completeReferralOnboarding')
          .call<Map<String, dynamic>>({
            'referralCode': referralCode.trim().toUpperCase(),
          });
      _referralOnboardingRequired = false;
      notifyListeners();
    });
  }

  @override
  Future<CompletedBookingUpiPaymentDetails>
  getCompletedBookingUpiPaymentDetails(String bookingId) async {
    final normalizedBookingId = bookingId.trim();
    final cached = _completedBookingUpiPaymentDetails[normalizedBookingId];
    if (cached != null) return cached;
    if (!hasActiveCustomerSession) {
      throw StateError('Sign in as the customer who made this booking.');
    }
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('getCompletedBookingUpiPaymentDetails')
          .call<Map<String, dynamic>>({'bookingId': normalizedBookingId}),
    );
    final data = response.data;
    final details = CompletedBookingUpiPaymentDetails(
      bookingId: _string(data['bookingId'], normalizedBookingId),
      salonId: _string(data['salonId'], ''),
      salonName: _string(data['salonName'], 'Salon'),
      amountInr: _int(data['amountInr'], 0),
      currency: _string(data['currency'], 'INR'),
      upiId: _string(data['upiId'], ''),
      upiUri: _string(data['upiUri'], ''),
      qrCodeUrl: _string(data['qrCodeUrl'], ''),
      transactionReference: _string(data['transactionReference'], ''),
      paymentAvailable: data['paymentAvailable'] == true,
    );
    if (details.bookingId != normalizedBookingId ||
        details.amountInr < 0 ||
        (details.paymentAvailable &&
            (details.upiId.isEmpty || details.upiUri.isEmpty))) {
      throw StateError('The salon payment details could not be verified.');
    }
    _completedBookingUpiPaymentDetails[normalizedBookingId] = details;
    return details;
  }

  @override
  Future<DiscountQuote> getDiscountQuote({
    required String salonId,
    required Iterable<String> serviceIds,
    bool lockQuote = true,
  }) async {
    final ids = serviceIds.toSet().toList(growable: false);
    if (auth.currentUser == null ||
        _activeRole != UserRole.customer ||
        ids.isEmpty) {
      return super.getDiscountQuote(
        salonId: salonId,
        serviceIds: ids,
        lockQuote: lockQuote,
      );
    }
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('getDiscountQuote')
          .call<Map<String, dynamic>>({
            'salonId': salonId,
            'serviceIds': ids,
            if (!lockQuote) 'previewOnly': true,
          }),
    );
    final data = response.data;
    return _discountQuoteFromData(data);
  }

  @override
  Future<List<CheckoutDiscountOffer>> listCheckoutDiscountOffers({
    required String salonId,
    required Iterable<String> serviceIds,
    bool prefetchOnly = false,
  }) async {
    final ids = serviceIds.toSet().toList(growable: false);
    if (auth.currentUser == null ||
        _activeRole != UserRole.customer ||
        ids.isEmpty) {
      return super.listCheckoutDiscountOffers(
        salonId: salonId,
        serviceIds: ids,
        prefetchOnly: prefetchOnly,
      );
    }
    Future<HttpsCallableResult<Map<String, dynamic>>> loadOffers() =>
        _callProtectedFunction(
          () => functions
              .httpsCallable('listCheckoutDiscountOffers')
              .call<Map<String, dynamic>>({
                'salonId': salonId,
                'serviceIds': ids,
                if (prefetchOnly) 'prefetchOnly': true,
              }),
        );
    late final HttpsCallableResult<Map<String, dynamic>> response;
    try {
      response = await loadOffers();
    } on FirebaseFunctionsException catch (error) {
      if (!isRetryableDiscountOfferErrorCode(error.code)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      response = await loadOffers();
    }
    final offers = response.data['offers'];
    if (offers is! List) return const [];
    return offers
        .whereType<Map>()
        .map((value) => _checkoutDiscountOfferFromData(value))
        .where((offer) => offer.hasSaving)
        .toList(growable: false);
  }

  @override
  Future<CheckoutCouponResult> applyVisibleCheckoutDiscount({
    required String salonId,
    required Iterable<String> serviceIds,
    required String campaignId,
  }) {
    return _runFirebaseSave(() async {
      final ids = serviceIds.toSet().toList(growable: false);
      final response = await _callProtectedFunction(
        () => functions
            .httpsCallable('applyVisibleCheckoutDiscount')
            .call<Map<String, dynamic>>({
              'salonId': salonId,
              'serviceIds': ids,
              'campaignId': campaignId.trim(),
            }),
      );
      final data = response.data;
      final quoteData = data['quote'];
      DiscountQuote? quote;
      if (quoteData is Map) {
        quote = _discountQuoteFromData(Map<String, dynamic>.from(quoteData));
      }
      return CheckoutCouponResult(
        benefitType: _string(data['benefitType'], ''),
        message: _string(data['message'], 'Offer applied.'),
        discountQuote: quote,
      );
    });
  }

  @override
  Future<CheckoutCouponResult> applyCheckoutCoupon({
    required String salonId,
    required Iterable<String> serviceIds,
    required String code,
  }) {
    return _runFirebaseSave(() async {
      if (!hasActiveCustomerSession) {
        throw StateError('Sign in as a customer to apply coupons.');
      }
      final ids = serviceIds.toSet().toList(growable: false);
      final response = await _callProtectedFunction(
        () => functions
            .httpsCallable('applyCheckoutCoupon')
            .call<Map<String, dynamic>>({
              'salonId': salonId,
              'serviceIds': ids,
              'couponCode': code.trim().toUpperCase(),
            }),
      );
      final data = response.data;
      final quoteData = data['quote'];
      DiscountQuote? quote;
      if (quoteData is Map) {
        final value = Map<String, dynamic>.from(quoteData);
        quote = _discountQuoteFromData(value);
      }
      if (_string(data['benefitType'], '') == 'proin') {
        final availableProin = _int(
          data['availableProin'],
          _customerProinWallet.availableProin + _int(data['amountProin'], 0),
        );
        _customerProinWallet = ProinWalletSummary(
          availableProin: availableProin,
          reservedProin: _customerProinWallet.reservedProin,
          creditLimitProin: _customerProinWallet.creditLimitProin,
          spendableProin:
              availableProin + _customerProinWallet.creditLimitProin,
          lifetimeGrantedProin:
              _customerProinWallet.lifetimeGrantedProin +
              (data['alreadyClaimed'] == true
                  ? 0
                  : _int(data['amountProin'], 0)),
          lifetimeRedeemedProin: _customerProinWallet.lifetimeRedeemedProin,
          lifetimeExpiredProin: _customerProinWallet.lifetimeExpiredProin,
          nextExpiryAt: _customerProinWallet.nextExpiryAt,
          expiringLots: _customerProinWallet.expiringLots,
        );
        notifyListeners();
        unawaited(
          Future.wait([
            refreshCustomerProinWallet(),
            refreshCustomerProinActivity(),
          ]).catchError((Object error) {
            _setSyncError(error);
            return <Object>[];
          }),
        );
      }
      return CheckoutCouponResult(
        benefitType: _string(data['benefitType'], ''),
        message: _string(data['message'], 'Coupon applied.'),
        amountProin: _int(data['amountProin'], 0),
        alreadyClaimed: data['alreadyClaimed'] == true,
        discountQuote: quote,
      );
    });
  }

  DiscountQuote _discountQuoteFromData(Map<String, dynamic> data) {
    return DiscountQuote(
      quoteId: _string(data['quoteId'], ''),
      campaignId: _string(data['campaignId'], ''),
      campaignName: _string(data['campaignName'], ''),
      discountType: _string(data['discountType'], 'percent'),
      discountPercent: _double(data['discountPercent'], 0),
      fixedDiscountAmount: _int(data['fixedDiscountAmount'], 0),
      voucherApplied: data['voucherOnly'] == true,
      voucherMaskedCode: _string(data['voucherMaskedCode'], ''),
      originalAmount: _int(data['originalAmount'], 0),
      discountBaseAmount: _int(data['discountBaseAmount'], 0),
      discountAmount: _int(data['discountAmount'], 0),
      customerPayableAmount: _int(data['customerPayableAmount'], 0),
      pritzePayoutAmount: _int(data['pritzePayoutAmount'], 0),
      salonTotalEarning: _int(data['salonTotalEarning'], 0),
      cashbackProinAmount: _int(data['cashbackProinAmount'], 0),
      cashbackValidityDays: _int(data['cashbackValidityDays'], 0),
      expiresAt: _int(data['expiresAtMillis'], 0) <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _int(data['expiresAtMillis'], 0),
            ),
      campaignEndsAt: _int(data['campaignEndsAtMillis'], 0) <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _int(data['campaignEndsAtMillis'], 0),
            ),
    );
  }

  CheckoutDiscountOffer _checkoutDiscountOfferFromData(Map data) {
    return CheckoutDiscountOffer(
      campaignId: _string(data['campaignId'], ''),
      campaignName: _string(data['campaignName'], 'Pritze offer'),
      discountType: _string(data['discountType'], 'percent'),
      discountPercent: _double(data['discountPercent'], 0),
      fixedDiscountAmount: _int(data['fixedDiscountAmount'], 0),
      voucherMaskedCode: _string(data['voucherMaskedCode'], ''),
      originalAmount: _int(data['originalAmount'], 0),
      discountAmount: _int(data['discountAmount'], 0),
      customerPayableAmount: _int(data['customerPayableAmount'], 0),
      cashbackProinAmount: _int(data['cashbackProinAmount'], 0),
      cashbackValidityDays: _int(data['cashbackValidityDays'], 0),
      campaignEndsAt: _int(data['campaignEndsAtMillis'], 0) <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _int(data['campaignEndsAtMillis'], 0),
            ),
    );
  }

  @override
  Future<ProinWalletSummary> refreshCustomerProinWallet() {
    final uid = auth.currentUser?.uid;
    if (_customerWalletRefresh != null && _customerWalletRefreshUid == uid) {
      return _customerWalletRefresh!;
    }
    _customerWalletRefreshUid = uid;
    late final Future<ProinWalletSummary> pending;
    pending = _loadCustomerProinWallet(uid).whenComplete(() {
      if (identical(_customerWalletRefresh, pending)) {
        _customerWalletRefresh = null;
      }
    });
    _customerWalletRefresh = pending;
    return pending;
  }

  Future<ProinWalletSummary> _loadCustomerProinWallet(String? uid) async {
    if (!hasActiveCustomerSession) {
      _customerProinWallet = const ProinWalletSummary();
      notifyListeners();
      return _customerProinWallet;
    }
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('getCustomerProinWallet')
          .call<Map<String, dynamic>>(),
    );
    final data = response.data;
    if (auth.currentUser?.uid != uid || !hasActiveCustomerSession) {
      return const ProinWalletSummary();
    }
    _customerProinWallet = ProinWalletSummary(
      availableProin: _int(data['availableProin'], 0),
      reservedProin: _int(data['reservedProin'], 0),
      creditLimitProin: _int(data['creditLimitProin'], 0),
      spendableProin: _int(
        data['spendableProin'],
        _int(data['availableProin'], 0),
      ),
      lifetimeGrantedProin: _int(data['lifetimeGrantedProin'], 0),
      lifetimeRedeemedProin: _int(data['lifetimeRedeemedProin'], 0),
      lifetimeExpiredProin: _int(data['lifetimeExpiredProin'], 0),
      nextExpiryAt: _int(data['nextExpiryAtMillis'], 0) <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _int(data['nextExpiryAtMillis'], 0),
            ),
      expiringLots: _proinExpiringLots(data['expiringLots']),
    );
    notifyListeners();
    return _customerProinWallet;
  }

  @override
  Future<ProinWalletSummary> refreshSalonProinWallet(String salonId) async {
    final normalizedSalonId = salonId.trim();
    if (!hasActiveOwnerSession || normalizedSalonId.isEmpty) {
      _salonProinWallets.remove(normalizedSalonId);
      notifyListeners();
      return const ProinWalletSummary();
    }
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('getSalonProinWallet')
          .call<Map<String, dynamic>>({'salonId': normalizedSalonId}),
    );
    final data = response.data;
    final availableProin = _int(data['availableProin'], 0);
    final creditLimitProin = _int(data['creditLimitProin'], 1000);
    final computedSpendableProin = availableProin + creditLimitProin;
    final wallet = ProinWalletSummary(
      availableProin: availableProin,
      reservedProin: _int(data['reservedProin'], 0),
      creditLimitProin: creditLimitProin,
      spendableProin: _int(
        data['spendableProin'],
        computedSpendableProin < 0 ? 0 : computedSpendableProin,
      ),
      lifetimeGrantedProin: _int(data['lifetimeGrantedProin'], 0),
      lifetimeRedeemedProin: _int(data['lifetimeRedeemedProin'], 0),
      lifetimeExpiredProin: _int(data['lifetimeExpiredProin'], 0),
      nextExpiryAt: _int(data['nextExpiryAtMillis'], 0) <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _int(data['nextExpiryAtMillis'], 0),
            ),
      expiringLots: _proinExpiringLots(data['expiringLots']),
    );
    _salonProinWallets[normalizedSalonId] = wallet;
    notifyListeners();
    return wallet;
  }

  @override
  Future<List<ProinActivityEntry>> refreshCustomerProinActivity() async {
    if (!hasActiveCustomerSession) {
      _customerProinActivity.clear();
      notifyListeners();
      return customerProinActivity;
    }
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('getCustomerProinActivity')
          .call<Map<String, dynamic>>({'limit': 50}),
    );
    final rawEntries = response.data['entries'];
    final entries = rawEntries is List ? rawEntries : const [];
    _customerProinActivity
      ..clear()
      ..addAll(
        entries.whereType<Map>().map((raw) {
          final data = Map<String, dynamic>.from(raw);
          final createdAtMillis = _int(data['createdAtMillis'], 0);
          return ProinActivityEntry(
            transactionId: _string(data['transactionId'], ''),
            type: _string(data['type'], ''),
            direction: _string(data['direction'], ''),
            amountProin: _int(data['amountProin'], 0),
            restoredProin: _int(data['restoredProin'], 0),
            expiredProin: _int(data['expiredProin'], 0),
            sourceType: _string(data['sourceType'], ''),
            bookingId: _string(data['bookingId'], ''),
            createdAt: createdAtMillis <= 0
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(createdAtMillis),
          );
        }),
      );
    notifyListeners();
    return customerProinActivity;
  }

  @override
  Future<ProinBookingQuote> getProinBookingQuote({
    required String salonId,
    required Iterable<String> serviceIds,
    required DiscountQuote discountQuote,
  }) async {
    final ids = serviceIds.toSet().toList(growable: false);
    if (ids.isEmpty) {
      return super.getProinBookingQuote(
        salonId: salonId,
        serviceIds: ids,
        discountQuote: discountQuote,
      );
    }
    if (!hasActiveCustomerSession) {
      throw StateError('Sign in as a customer to use Proin.');
    }
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('getProinBookingQuote')
          .call<Map<String, dynamic>>({
            'salonId': salonId,
            'serviceIds': ids,
            if (discountQuote.quoteId.isNotEmpty)
              'quoteId': discountQuote.quoteId,
          }),
    );
    final data = response.data;
    return ProinBookingQuote(
      availableProin: _int(data['availableProin'], 0),
      maximumRedeemableProin: _int(data['allocatedProin'], 0),
      payableBeforeProin: _int(
        data['payableBeforeProin'],
        discountQuote.customerPayableAmount,
      ),
      customerPayableAmount: _int(
        data['customerPayableAmount'],
        discountQuote.customerPayableAmount,
      ),
    );
  }

  @override
  Future<ProinCouponClaimResult> claimProinCoupon(String code) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      throw StateError('Enter a coupon code.');
    }
    if (!hasActiveCustomerSession) {
      throw StateError('Sign in as a customer to claim Proin coupons.');
    }
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('claimProinCoupon')
          .call<Map<String, dynamic>>({'couponCode': normalized}),
    );
    final data = response.data;
    await refreshCustomerProinWallet();
    await refreshCustomerProinActivity();
    return ProinCouponClaimResult(
      amountProin: _int(data['amountProin'], 0),
      availableProin: _int(
        data['availableProin'],
        _customerProinWallet.availableProin,
      ),
      expiresAt: _int(data['expiresAtMillis'], 0) <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _int(data['expiresAtMillis'], 0),
            ),
      alreadyClaimed: data['alreadyClaimed'] == true,
    );
  }

  @override
  Future<ProinCouponClaimResult> claimSalonProinCoupon({
    required String salonId,
    required String code,
  }) async {
    final normalizedSalonId = salonId.trim();
    final normalized = code.trim().toUpperCase();
    if (normalizedSalonId.isEmpty) {
      throw StateError('Choose a salon before applying a coupon.');
    }
    if (normalized.isEmpty) {
      throw StateError('Enter a salon coupon code.');
    }
    if (!hasActiveOwnerSession) {
      throw StateError('Sign in as the salon owner to claim salon coupons.');
    }
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('claimSalonProinCoupon')
          .call<Map<String, dynamic>>({
            'salonId': normalizedSalonId,
            'couponCode': normalized,
          }),
    );
    final data = response.data;
    await refreshSalonProinWallet(normalizedSalonId);
    return ProinCouponClaimResult(
      amountProin: _int(data['amountProin'], 0),
      availableProin: _int(
        data['availableProin'],
        salonProinWallet(normalizedSalonId).availableProin,
      ),
      expiresAt: _int(data['expiresAtMillis'], 0) <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _int(data['expiresAtMillis'], 0),
            ),
      alreadyClaimed: data['alreadyClaimed'] == true,
    );
  }

  @override
  bool get isRestoringSession => _isRestoringSession;

  @override
  Stream<String> get autoVerifiedPhoneNumbers =>
      _autoVerifiedPhoneController.stream;

  @override
  bool isPhoneAutoVerified(String phone) {
    final normalizedPhone = normalizePhone(phone);
    final generation = _phoneOtpGenerations[normalizedPhone];
    return generation != null &&
        _autoVerifiedPhoneGenerations[normalizedPhone] == generation &&
        _autoVerifiedPhoneCredentials.containsKey(normalizedPhone);
  }

  @override
  bool isBookingStatusUpdatePending(String bookingId) =>
      _bookingStatusRequests.contains(bookingId) ||
      _optimisticBookingUpdates[bookingId]?.hasExpired(DateTime.now()) ==
          false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    final uid = auth.currentUser?.uid;
    if (uid == null) {
      return;
    }
    _messagingTokenRetryAttempt = 0;
    unawaited(_saveMessagingToken(uid));
    if (_activeRole == UserRole.owner) {
      unawaited(_retryPendingOwnerBookingActions());
    }
  }

  @override
  Future<void> restoreSignedInUser() async {
    var user = auth.currentUser;
    // On a cold process start the native Auth SDK can finish restoring its
    // persisted user just after Firebase Core becomes available. Waiting for
    // the stream's initial event avoids briefly treating that user as logged
    // out and routing them to the wrong home.
    user ??= await auth.authStateChanges().first.timeout(
      const Duration(seconds: 3),
      onTimeout: () => auth.currentUser,
    );
    _startupRestoreUid = user?.uid;
    try {
      if (user == null) {
        _activeRole = null;
        return;
      }

      await _restoreActiveRole(accountId: user.uid);
      if (_activeRole != null) {
        // The cached role belongs to this exact Firebase uid, so it is safe to
        // render immediately while Firestore reconciles the profile.
        final localRole = _activeRole == UserRole.barber
            ? UserRole.customer
            : _activeRole!;
        _activateRole(localRole, _accountFromFirebaseUser(user, const {}));
      } else {
        // Existing installs have an unscoped legacy role. Do not guess from
        // it: wait for this user's authoritative profile once, otherwise an
        // owner who previously used the phone can leak into a customer login.
        await _restoreAccountForUser(user);
      }
    } finally {
      _startupRestoreUid = null;
      _isRestoringSession = false;
      notifyListeners();
    }
  }

  @override
  Future<void> refresh() async {
    try {
      final salonsSnapshot = await firestore
          .collection('salons')
          .get(const GetOptions(source: Source.server));
      final barbersSnapshot = await firestore
          .collection('barbers')
          .get(const GetOptions(source: Source.server));
      final locksSnapshot = await firestore
          .collection('slotLocks')
          .where('active', isEqualTo: true)
          .get(const GetOptions(source: Source.server));
      _salons
        ..clear()
        ..addAll(salonsSnapshot.docs.map(_salonFromFirestore));
      _barbers
        ..clear()
        ..addAll(barbersSnapshot.docs.map(_barberFromFirestore));
      _occupiedSlotKeys
        ..clear()
        ..addAll(locksSnapshot.docs.map(_slotKeyFromLock));

      final user = auth.currentUser;
      if (user != null) {
        await _saveMessagingToken(user.uid);
        for (final query in <(String, String)>[
          ('customer', 'customerUid'),
          ('owner', 'ownerUid'),
        ]) {
          final snapshot = await firestore
              .collection('bookings')
              .where(query.$2, isEqualTo: user.uid)
              .get(const GetOptions(source: Source.server));
          _bookingSnapshots[query.$1] = {
            for (final doc in snapshot.docs) doc.id: _bookingFromFirestore(doc),
          };
        }
        final mergedBookings = <String, Booking>{};
        for (final items in _bookingSnapshots.values) {
          mergedBookings.addAll(items);
        }
        _bookings
          ..clear()
          ..addAll(mergedBookings.values);
        _syncOwnerBookingAlarm();

        _joinRequests.clear();
      }
      _discountOfferRefreshVersion += 1;
      notifyListeners();
    } catch (error) {
      _setSyncError(error);
      rethrow;
    }
  }

  @override
  Future<void> selectRole(UserRole role) async {
    await super.selectRole(role);
    final user = auth.currentUser;
    if (user != null) {
      await _saveMessagingToken(user.uid);
      _syncOwnerBookingAlarm();
    }
  }

  @override
  Future<void> signOutActiveUser() async {
    _accountRestoreGeneration += 1;
    _suppressTokenRegistration = true;
    _pendingCustomerRegistrationPhone = null;
    _pendingCustomerRegistrationUid = null;
    _pendingGoogleCustomerAccount = null;
    _pendingGoogleCustomerUid = null;
    _stopOwnerBookingAlarm();
    final uid = auth.currentUser?.uid;
    final tokenCleanup = uid == null ? null : _removeMessagingToken(uid);

    // Clear the visible session and its uid-scoped role before any network
    // cleanup. A slow FCM/Firestore request must never leave the user staring
    // at an account they already asked to leave.
    await super.signOutActiveUser();
    try {
      if (tokenCleanup != null) {
        try {
          // The de-registration write needs the session that is about to end,
          // so it has to finish first. Long enough for a slow connection to
          // land it, short enough that nobody force-quits mid-way and comes
          // back still signed in.
          await tokenCleanup.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          if (kDebugMode) {
            debugPrint('Sign-out notification cleanup timed out.');
          }
        } catch (error) {
          // Notification cleanup must never be what keeps someone signed in.
          if (kDebugMode) {
            debugPrint('Sign-out notification cleanup failed: $error');
          }
        }
      }
      await auth.signOut();
      if (_googleInitialized) {
        try {
          await GoogleSignIn.instance.signOut().timeout(
            const Duration(seconds: 2),
          );
        } catch (error) {
          if (kDebugMode) {
            debugPrint('Google account cleanup after sign-out failed: $error');
          }
        }
      }
    } catch (error) {
      _setSyncError(error);
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ownerBookingDecisionRetryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _messagingTokenRetryTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _privateSubscriptions) {
      unawaited(subscription.cancel());
    }
    _stopOwnerBookingAlarm();
    unawaited(_autoVerifiedPhoneController.close());
    super.dispose();
  }

  @override
  Future<Booking> createBooking({
    required TimeSlot slot,
    String quoteId = '',
    int requestedProin = 0,
  }) async {
    if (auth.currentUser != null) {
      return _createBookingWithFunction(
        slot,
        quoteId: quoteId,
        requestedProin: requestedProin,
      );
    }
    return _runFirebaseSave(() async {
      final account = _customerAccount;
      if (_activeRole != UserRole.customer || account == null) {
        throw StateError('Customer login is required before booking.');
      }
      final customerUid = auth.currentUser?.uid;
      if (customerUid == null || customerUid != account.id) {
        throw StateError('Please sign in again before booking this slot.');
      }
      if (hasActiveCustomerBooking) {
        throw StateError('You already have an active booking.');
      }
      final service = getService(slot.salonId, slot.serviceId);
      final selectedBarber = getBarber(slot.barberId);
      if (service == null ||
          !service.isAvailable ||
          selectedBarber == null ||
          !selectedBarber.isActive ||
          selectedBarber.salonId != slot.salonId ||
          !selectedBarber.serviceIds.contains(slot.serviceId) ||
          !_isWithinOperatingHours(slot, service.durationMinutes)) {
        throw StateError('This appointment is no longer available.');
      }
      final bookingDoc = firestore.collection('bookings').doc();
      final activeCustomerDoc = firestore
          .collection('activeCustomerBookings')
          .doc(customerUid);
      final legacyActiveInstantDoc = firestore
          .collection('activeInstantBookings')
          .doc(customerUid);
      final lockStarts = _slotSegmentStarts(
        slot.start,
        service.durationMinutes,
      );
      final lockDocs = [
        for (final start in lockStarts)
          firestore
              .collection('slotLocks')
              .doc(_slotLockId(slot.barberId, start)),
      ];
      final salon = await firestore
          .collection('salons')
          .doc(slot.salonId)
          .get();
      final barber = await firestore
          .collection('barbers')
          .doc(slot.barberId)
          .get();
      if (!salon.exists || !barber.exists) {
        throw StateError('This appointment is no longer available.');
      }
      final ownerUid = (salon.data()?['ownerUid'] as String?)?.trim();
      if (ownerUid == null || ownerUid.isEmpty) {
        throw StateError(
          'This salon cannot receive bookings right now. Please try another salon.',
        );
      }
      final booking = Booking(
        id: bookingDoc.id,
        customerUid: customerUid,
        salonId: slot.salonId,
        serviceId: slot.serviceId,
        barberId: slot.barberId,
        customerName: account.name,
        customerPhone: account.contact,
        start: slot.start,
        durationMinutes: service.durationMinutes,
        serviceName: service.name,
        servicePrice: service.price,
        serviceNameBreakdown: {service.id: service.name},
        servicePriceBreakdown: {service.id: service.price},
        bookingFee: _zeroBookingFee,
        paymentRequired: false,
        paymentStatus: _zeroBookingFeeStatus,
        status: BookingStatus.pending,
        createdAt: DateTime.now(),
      );
      await firestore.runTransaction((transaction) async {
        final activeCustomerSnapshot = await transaction.get(activeCustomerDoc);
        final legacyActiveInstantSnapshot = await transaction.get(
          legacyActiveInstantDoc,
        );
        final lockSnapshots = <DocumentSnapshot<Map<String, dynamic>>>[];
        for (final lockDoc in lockDocs) {
          lockSnapshots.add(await transaction.get(lockDoc));
        }
        if (activeCustomerSnapshot.data()?['active'] == true ||
            legacyActiveInstantSnapshot.data()?['active'] == true) {
          throw StateError('You already have an active booking.');
        }
        if (lockSnapshots.any(
          (snapshot) => snapshot.exists && snapshot.data()?['active'] != false,
        )) {
          throw StateError(
            'This slot was just booked. Please choose another time.',
          );
        }
        transaction.set(
          bookingDoc,
          _bookingToFirestore(
            booking,
            customerUid: customerUid,
            ownerUid: ownerUid,
            barberUid: barber.data()?['uid'] as String?,
          ),
        );
        transaction.set(activeCustomerDoc, {
          'active': true,
          'bookingId': booking.id,
          'salonId': booking.salonId,
          'customerUid': customerUid,
          'isInstant': false,
          'createdAt': Timestamp.fromDate(booking.createdAt),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        for (var index = 0; index < lockDocs.length; index++) {
          transaction.set(lockDocs[index], {
            'bookingId': booking.id,
            'salonId': booking.salonId,
            'serviceId': booking.serviceId,
            'barberId': booking.barberId,
            'start': Timestamp.fromDate(lockStarts[index]),
            'bookingStart': Timestamp.fromDate(booking.start),
            'active': true,
            'createdAt': Timestamp.fromDate(booking.createdAt),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
      if (!_bookings.any((item) => item.id == booking.id)) {
        _bookings.add(booking);
      }
      _setSlotOccupancy(
        barberId: slot.barberId,
        start: slot.start,
        durationMinutes: service.durationMinutes,
        occupied: true,
      );
      notifyListeners();
      return booking;
    });
  }

  @override
  Future<Booking> createInstantBooking({
    required String salonId,
    String? serviceId,
    Iterable<String>? serviceIds,
    int arrivalMinutes = 15,
    String quoteId = '',
    int requestedProin = 0,
  }) async {
    if (auth.currentUser != null) {
      return _createInstantBookingWithFunction(
        salonId: salonId,
        serviceId: serviceId,
        serviceIds: serviceIds,
        arrivalMinutes: arrivalMinutes,
        quoteId: quoteId,
        requestedProin: requestedProin,
      );
    }
    return _runFirebaseSave(() async {
      final account = _customerAccount;
      if (_activeRole != UserRole.customer || account == null) {
        throw StateError('Customer login is required before booking.');
      }
      final customerUid = auth.currentUser?.uid;
      if (customerUid == null || customerUid != account.id) {
        throw StateError('Please sign in again before booking this slot.');
      }
      if (!instantArrivalMinuteOptions.contains(arrivalMinutes)) {
        throw StateError('Choose an arrival time of 15, 20, or 25 minutes.');
      }
      if (hasActiveCustomerBooking) {
        throw StateError('You already have an active booking.');
      }
      final requestedIds = <String>{
        ...?serviceIds?.map((id) => id.trim()),
        if (serviceId?.trim().isNotEmpty == true) serviceId!.trim(),
      }.where((id) => id.isNotEmpty).toList();
      if (requestedIds.isEmpty || requestedIds.length > 6) {
        throw StateError('Choose between 1 and 6 instant services.');
      }
      final salonModel = getSalon(salonId);
      final services = requestedIds
          .map((id) => getService(salonId, id))
          .whereType<SalonService>()
          .toList();
      if (salonModel == null ||
          services.length != requestedIds.length ||
          !isInstantMultiServiceBookingAvailable(
            salonId,
            requestedIds,
            arrivalMinutes: arrivalMinutes,
          )) {
        throw StateError(
          'These services are not available together right now.',
        );
      }
      final totalDuration = services.fold<int>(
        0,
        (total, service) => total + service.durationMinutes,
      );
      final totalPrice = services.fold<int>(
        0,
        (total, service) => total + service.price,
      );
      final now = DateTime.now();
      final arrivalDeadline = now.add(Duration(minutes: arrivalMinutes));
      final eligibleBarbers = barbersForServices(salonId, requestedIds)
        ..sort((a, b) {
          final aIsFree = _isBarberFree(a.id, arrivalDeadline, totalDuration);
          final bIsFree = _isBarberFree(b.id, arrivalDeadline, totalDuration);
          if (aIsFree != bIsFree) {
            return aIsFree ? -1 : 1;
          }
          final workloadCompare = bookingsForBarber(
            a.id,
          ).length.compareTo(bookingsForBarber(b.id).length);
          return workloadCompare != 0
              ? workloadCompare
              : a.name.compareTo(b.name);
        });
      if (eligibleBarbers.isEmpty) {
        throw StateError('No barber is available for this instant service.');
      }
      final selectedBarber = eligibleBarbers.first;
      final bookingDoc = firestore.collection('bookings').doc();
      final activeCustomerDoc = firestore
          .collection('activeCustomerBookings')
          .doc(customerUid);
      final activeInstantDoc = firestore
          .collection('activeInstantBookings')
          .doc(customerUid);
      final salon = await firestore.collection('salons').doc(salonId).get();
      final barber = await firestore
          .collection('barbers')
          .doc(selectedBarber.id)
          .get();
      if (!salon.exists || !barber.exists) {
        throw StateError('This service is not available for instant booking.');
      }
      final ownerUid = (salon.data()?['ownerUid'] as String?)?.trim();
      if (ownerUid == null || ownerUid.isEmpty) {
        throw StateError(
          'This salon cannot receive bookings right now. Please try another salon.',
        );
      }
      final booking = Booking(
        id: bookingDoc.id,
        customerUid: customerUid,
        salonId: salonId,
        serviceId: requestedIds.first,
        serviceIds: requestedIds,
        barberId: selectedBarber.id,
        customerName: account.name,
        customerPhone: account.contact,
        start: arrivalDeadline,
        durationMinutes: totalDuration,
        serviceName: services.map((service) => service.name).join(', '),
        servicePrice: totalPrice,
        servicePriceBreakdown: {
          for (final service in services) service.id: service.price,
        },
        bookingFee: _zeroBookingFee,
        paymentRequired: false,
        paymentStatus: _zeroBookingFeeStatus,
        status: BookingStatus.pending,
        createdAt: now,
        isInstant: true,
        arrivalMinutes: arrivalMinutes,
      );
      await firestore.runTransaction((transaction) async {
        final activeCustomerSnapshot = await transaction.get(activeCustomerDoc);
        final activeInstantSnapshot = await transaction.get(activeInstantDoc);
        if (activeCustomerSnapshot.data()?['active'] == true ||
            activeInstantSnapshot.data()?['active'] == true) {
          throw StateError('You already have an active booking.');
        }
        transaction.set(
          bookingDoc,
          _bookingToFirestore(
            booking,
            customerUid: customerUid,
            ownerUid: ownerUid,
            barberUid: barber.data()?['uid'] as String?,
          ),
        );
        transaction.set(activeCustomerDoc, {
          'active': true,
          'bookingId': booking.id,
          'salonId': booking.salonId,
          'customerUid': customerUid,
          'isInstant': true,
          'createdAt': Timestamp.fromDate(booking.createdAt),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        transaction.set(activeInstantDoc, {
          'active': true,
          'bookingId': booking.id,
          'salonId': booking.salonId,
          'customerUid': customerUid,
          'createdAt': Timestamp.fromDate(booking.createdAt),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
      if (!_bookings.any((item) => item.id == booking.id)) {
        _bookings.add(booking);
      }
      notifyListeners();
      return booking;
    });
  }

  Future<Booking> _createBookingWithFunction(
    TimeSlot slot, {
    String quoteId = '',
    int requestedProin = 0,
  }) {
    return _runFirebaseSave(() async {
      final result = await functions
          .httpsCallable('createBooking')
          .call<Map<String, dynamic>>({
            'salonId': slot.salonId,
            'serviceId': slot.serviceId,
            'barberId': slot.barberId,
            'startMillis': slot.start.millisecondsSinceEpoch,
            'isInstant': false,
            if (quoteId.isNotEmpty) 'quoteId': quoteId,
            if (requestedProin > 0) 'requestedProin': requestedProin,
          });
      return _bookingFromCreateResponse(result.data);
    });
  }

  Future<Booking> _createInstantBookingWithFunction({
    required String salonId,
    String? serviceId,
    Iterable<String>? serviceIds,
    required int arrivalMinutes,
    String quoteId = '',
    int requestedProin = 0,
  }) {
    final requestedIds = <String>{
      ...?serviceIds?.map((id) => id.trim()),
      if (serviceId?.trim().isNotEmpty == true) serviceId!.trim(),
    }.where((id) => id.isNotEmpty).toList();
    return _runFirebaseSave(() async {
      final result = await functions
          .httpsCallable('createBooking')
          .call<Map<String, dynamic>>({
            'salonId': salonId,
            'serviceId': requestedIds.firstOrNull ?? '',
            'serviceIds': requestedIds,
            'arrivalMinutes': arrivalMinutes,
            'isInstant': true,
            if (quoteId.isNotEmpty) 'quoteId': quoteId,
            if (requestedProin > 0) 'requestedProin': requestedProin,
          });
      return _bookingFromCreateResponse(result.data);
    });
  }

  Future<Booking> _bookingFromCreateResponse(
    Map<String, dynamic> response,
  ) async {
    final bookingId = _string(response['bookingId'], '');
    if (bookingId.isEmpty) {
      throw StateError('The server did not return a booking.');
    }
    final rawBooking = response['booking'];
    if (rawBooking is! Map) {
      // Compatibility with an older deployed function during a rolling
      // release. New servers return the record inline and skip this read.
      return _loadServerBooking(bookingId);
    }
    final booking = _bookingFromData(
      bookingId,
      Map<String, dynamic>.from(rawBooking),
    );
    final index = _bookings.indexWhere((item) => item.id == booking.id);
    if (index == -1) {
      _bookings.add(booking);
    } else {
      _bookings[index] = booking;
    }
    if (_activeRole == UserRole.customer && booking.hasProin) {
      unawaited(_refreshCustomerProinWalletInBackground());
    }
    notifyListeners();
    return booking;
  }

  Future<Booking> _loadServerBooking(String bookingId) async {
    if (bookingId.isEmpty) {
      throw StateError('The server did not return a booking.');
    }
    final snapshot = await firestore
        .collection('bookings')
        .doc(bookingId)
        .get(const GetOptions(source: Source.server));
    if (!snapshot.exists) {
      throw StateError('Booking not found after saving.');
    }
    final booking = _bookingFromFirestore(snapshot);
    final index = _bookings.indexWhere((item) => item.id == booking.id);
    if (index == -1) {
      _bookings.add(booking);
    } else {
      _bookings[index] = booking;
    }
    if (_activeRole == UserRole.customer && booking.hasProin) {
      unawaited(_refreshCustomerProinWalletInBackground());
    }
    notifyListeners();
    return booking;
  }

  @override
  Future<void> sendEmailSignInLink({required String email}) {
    return sendEmailOtp(email: email);
  }

  @override
  Future<void> sendEmailOtp({required String email}) async {
    await functions.httpsCallable('sendEmailOtp').call<void>({
      'email': email.trim(),
    });
  }

  @override
  Future<String> sendPhoneOtp({required String phone}) {
    return _requestPhoneOtp(phone: phone);
  }

  @override
  bool isOwnerPhoneLoginEnabled(String phone) =>
      hasActiveOwnerSession &&
      auth.currentUser?.phoneNumber == normalizePhone(phone);

  @override
  Future<void> linkOwnerPhoneLogin({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final user = auth.currentUser;
    final normalizedPhone = normalizePhone(phone);
    if (user == null || !hasActiveOwnerSession) {
      throw StateError('Sign in as the salon owner first.');
    }
    if (ownerSalonOrNull?.phone != normalizedPhone) {
      throw StateError('Save this phone number in your salon profile first.');
    }
    PhoneAuthCredential credential;
    if (verificationId.isEmpty) {
      final saved = _autoVerifiedPhoneCredentials[normalizedPhone];
      if (saved == null ||
          _autoVerifiedPhoneGenerations[normalizedPhone] !=
              _phoneOtpGenerations[normalizedPhone]) {
        throw StateError('Request a new phone OTP.');
      }
      credential = saved;
    } else {
      if (_currentPhoneVerificationIds[normalizedPhone] != verificationId ||
          !RegExp(r'^\d{6}$').hasMatch(smsCode.trim())) {
        throw StateError('Enter the latest 6-digit OTP sent to your phone.');
      }
      credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      );
    }
    try {
      if (user.phoneNumber == null) {
        await user.linkWithCredential(credential);
      } else {
        await user.updatePhoneNumber(credential);
      }
    } on FirebaseAuthException catch (error) {
      if (error.code != 'credential-already-in-use') rethrow;
      // Keep the email owner signed in. Prove the phone on a secondary auth
      // session; the server only links an unused identity, never another owner.
      final secondary = await Firebase.initializeApp(
        name: 'owner-phone-link-${DateTime.now().microsecondsSinceEpoch}',
        options: Firebase.app().options,
      );
      final phoneAuth = FirebaseAuth.instanceFor(app: secondary);
      try {
        final result = await phoneAuth.signInWithCredential(credential);
        final token = await result.user?.getIdToken(true);
        if (token == null) throw StateError('Phone verification failed.');
        await _callProtectedFunction(
          () => functions.httpsCallable('linkOwnerPhoneLogin').call<void>({
            'phoneIdToken': token,
          }),
        );
      } finally {
        await phoneAuth.signOut();
        await secondary.delete();
      }
    }
    await user.reload();
    await auth.currentUser?.getIdToken(true);
    _invalidatePhoneOtp(normalizedPhone);
    notifyListeners();
  }

  @override
  Future<String> resendPhoneOtp({required String phone}) {
    final normalizedPhone = normalizePhone(phone);
    return _requestPhoneOtp(
      phone: phone,
      forceResendingToken: _phoneResendTokens[normalizedPhone],
    );
  }

  Future<String> _requestPhoneOtp({
    required String phone,
    int? forceResendingToken,
  }) async {
    final completer = Completer<String>();
    final normalizedPhone = normalizePhone(phone);
    final requestGeneration = (_phoneOtpGenerations[normalizedPhone] ?? 0) + 1;
    _phoneOtpGenerations[normalizedPhone] = requestGeneration;
    _autoVerifiedPhoneGenerations.remove(normalizedPhone);
    _autoVerifiedPhoneCredentials.remove(normalizedPhone);
    _currentPhoneVerificationIds.remove(normalizedPhone);
    auth.verifyPhoneNumber(
      phoneNumber: normalizedPhone,
      timeout: const Duration(seconds: 30),
      forceResendingToken: forceResendingToken,
      verificationCompleted: (credential) async {
        if (_phoneOtpGenerations[normalizedPhone] != requestGeneration) {
          return;
        }
        _autoVerifiedPhoneGenerations[normalizedPhone] = requestGeneration;
        _autoVerifiedPhoneCredentials[normalizedPhone] = credential;
        if (!completer.isCompleted) {
          completer.complete('');
        } else {
          _autoVerifiedPhoneController.add(normalizedPhone);
        }
      },
      verificationFailed: (error) {
        if (_phoneOtpGenerations[normalizedPhone] != requestGeneration) {
          return;
        }
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      codeSent: (verificationId, forceResendingToken) {
        if (_phoneOtpGenerations[normalizedPhone] != requestGeneration) {
          return;
        }
        if (forceResendingToken != null) {
          _phoneResendTokens[normalizedPhone] = forceResendingToken;
        }
        _currentPhoneVerificationIds[normalizedPhone] = verificationId;
        if (!completer.isCompleted) {
          completer.complete(verificationId);
        }
      },
      codeAutoRetrievalTimeout: (verificationId) {
        if (_phoneOtpGenerations[normalizedPhone] != requestGeneration) {
          return;
        }
        _currentPhoneVerificationIds[normalizedPhone] = verificationId;
        if (!completer.isCompleted) {
          completer.complete(verificationId);
        }
      },
    );
    return completer.future;
  }

  @override
  Future<UserAccount> loginCustomerWithEmail({
    required String name,
    required String email,
    String? emailLink,
  }) async {
    throw StateError('Customers can only log in with a phone number.');
  }

  @override
  Future<UserAccount> loginCustomerWithGmail({
    required String name,
    required String email,
  }) async {
    return _withPendingLoginRole(UserRole.customer, () async {
      final previousUid = auth.currentUser?.uid;
      final account = await _signInWithGoogle(
        fallbackName: name,
        fallbackEmail: email,
      );
      final user = auth.currentUser;
      if (user == null) {
        throw StateError('Google sign-in did not return an account.');
      }
      var customerPhone = normalizePhone(user.phoneNumber ?? '');
      if (customerPhone.isEmpty) {
        final snapshot = await firestore
            .collection('users')
            .doc(user.uid)
            .get();
        final data = snapshot.data() ?? const <String, dynamic>{};
        for (final candidate in [data['phone'], data['contact']]) {
          final value = candidate?.toString().trim() ?? '';
          if (value.contains('@')) {
            continue;
          }
          final normalized = normalizePhone(value);
          if (RegExp(r'^\+91\d{10}$').hasMatch(normalized)) {
            customerPhone = normalized;
            break;
          }
        }
      }
      if (customerPhone.isEmpty) {
        _pendingGoogleCustomerAccount = account;
        _pendingGoogleCustomerUid = user.uid;
        throw const CustomerPhoneRequiredException();
      }
      return _completeRoleClaim(
        account.copyWith(contact: customerPhone),
        role: UserRole.customer,
        previousUid: previousUid,
        usedGoogle: true,
        claimedPhone: customerPhone,
      );
    });
  }

  @override
  Future<UserAccount> completeCustomerGmailPhone({
    required String phone,
  }) async {
    return _withPendingLoginRole(UserRole.customer, () async {
      final pendingAccount = _pendingGoogleCustomerAccount;
      final user = auth.currentUser;
      if (pendingAccount == null ||
          user == null ||
          _pendingGoogleCustomerUid != user.uid) {
        throw StateError('Sign in with Gmail again before entering the phone.');
      }
      final normalizedPhone = normalizePhone(phone);
      if (!RegExp(r'^\+91\d{10}$').hasMatch(normalizedPhone)) {
        throw StateError('Enter a valid 10-digit Indian mobile number.');
      }
      final resolved = await _completeRoleClaim(
        pendingAccount.copyWith(contact: normalizedPhone),
        role: UserRole.customer,
        previousUid: null,
        usedGoogle: true,
        claimedPhone: normalizedPhone,
      );
      _pendingGoogleCustomerAccount = null;
      _pendingGoogleCustomerUid = null;
      return resolved;
    });
  }

  @override
  Future<void> cancelPendingCustomerGmailLogin() async {
    if (_pendingGoogleCustomerAccount == null) {
      return;
    }
    _pendingGoogleCustomerAccount = null;
    _pendingGoogleCustomerUid = null;
    _accountRestoreGeneration += 1;
    _suppressTokenRegistration = true;
    await auth.signOut();
    if (_googleInitialized) {
      await GoogleSignIn.instance.signOut();
    }
  }

  @override
  Future<UserAccount> loginCustomerWithPhone({
    String name = '',
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    return _withPendingLoginRole(UserRole.customer, () async {
      final normalizedPhone = normalizePhone(phone);
      final previousUid = auth.currentUser?.uid;
      final account = await _signInWithPhoneOtp(
        phone: normalizedPhone,
        verificationId: verificationId,
        smsCode: smsCode,
        fallbackName: name,
      );
      try {
        final resolvedAccount = await _completeRoleClaim(
          account,
          role: UserRole.customer,
          previousUid: previousUid,
        );
        _pendingCustomerRegistrationPhone = null;
        _pendingCustomerRegistrationUid = null;
        return resolvedAccount;
      } on CustomerNameRequiredException {
        _pendingCustomerRegistrationPhone = normalizedPhone;
        _pendingCustomerRegistrationUid = account.id;
        rethrow;
      }
    });
  }

  @override
  Future<UserAccount> completeCustomerPhoneRegistration({
    required String name,
    required String phone,
  }) async {
    return _withPendingLoginRole(UserRole.customer, () async {
      final customerName = name.trim();
      if (customerName.isEmpty) {
        throw StateError('Enter your name to create your customer account.');
      }
      final normalizedPhone = normalizePhone(phone);
      final user = auth.currentUser;
      if (user == null ||
          _pendingCustomerRegistrationPhone != normalizedPhone ||
          _pendingCustomerRegistrationUid != user.uid ||
          normalizePhone(user.phoneNumber ?? '') != normalizedPhone) {
        throw StateError(
          'Phone verification expired. Verify the phone number again.',
        );
      }
      await user.updateDisplayName(customerName);
      final account = UserAccount(
        id: user.uid,
        name: customerName,
        contact: normalizedPhone,
        provider: LoginProvider.phone,
      );
      try {
        final resolvedAccount = await _completeRoleClaim(
          account,
          role: UserRole.customer,
          previousUid: null,
        );
        _pendingCustomerRegistrationPhone = null;
        _pendingCustomerRegistrationUid = null;
        return resolvedAccount;
      } catch (_) {
        if (auth.currentUser == null) {
          _pendingCustomerRegistrationPhone = null;
          _pendingCustomerRegistrationUid = null;
        }
        rethrow;
      }
    });
  }

  @override
  Future<void> cancelPendingCustomerPhoneLogin() async {
    if (_pendingCustomerRegistrationPhone == null) {
      return;
    }
    _pendingCustomerRegistrationPhone = null;
    _pendingCustomerRegistrationUid = null;
    _accountRestoreGeneration += 1;
    _suppressTokenRegistration = true;
    await auth.signOut();
  }

  @override
  Future<UserAccount> loginOwnerWithGmail({
    required String name,
    required String email,
  }) async {
    return _withPendingLoginRole(UserRole.owner, () async {
      final previousUid = auth.currentUser?.uid;
      final account = await _signInWithGoogle(
        fallbackName: name,
        fallbackEmail: email,
      );
      return _completeRoleClaim(
        account,
        role: UserRole.owner,
        previousUid: previousUid,
        usedGoogle: true,
      );
    });
  }

  @override
  Future<UserAccount> loginOwnerWithEmail({
    required String name,
    required String email,
    String? emailLink,
  }) async {
    return _withPendingLoginRole(UserRole.owner, () async {
      final previousUid = auth.currentUser?.uid;
      final account = await _signInWithEmailOtp(
        fallbackName: name,
        email: email,
        emailOtp: emailLink,
      );
      return _completeRoleClaim(
        account,
        role: UserRole.owner,
        previousUid: previousUid,
      );
    });
  }

  @override
  Future<UserAccount> loginOwnerWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    return _withPendingLoginRole(UserRole.owner, () async {
      final previousUid = auth.currentUser?.uid;
      final account = await _signInWithPhoneOtp(
        phone: phone,
        verificationId: verificationId,
        smsCode: smsCode,
      );
      return _completeRoleClaim(
        account,
        role: UserRole.owner,
        previousUid: previousUid,
      );
    });
  }

  @override
  Future<UserAccount> loginBarberWithGmail({
    required String name,
    required String email,
  }) async {
    throw StateError('Barbers do not have login accounts.');
  }

  @override
  Future<UserAccount> loginBarberWithEmail({
    required String name,
    required String email,
    String? phone,
    String? emailLink,
  }) async {
    throw StateError('Barbers do not have login accounts.');
  }

  @override
  Future<UserAccount> loginBarberWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    throw StateError('Barbers do not have login accounts.');
  }

  @override
  Future<void> updateCustomerArrivalStatus(
    String bookingId,
    CustomerArrivalStatus status,
  ) async {
    if (auth.currentUser == null) {
      return super.updateCustomerArrivalStatus(bookingId, status);
    }
    await _runFirebaseSave(() async {
      await functions.httpsCallable('updateCustomerArrivalStatus').call<void>({
        'bookingId': bookingId,
        'arrivalStatus': status.name,
      });
      await _loadServerBooking(bookingId);
    });
  }

  @override
  Future<DateTime> startCustomerArrivalSharing(
    String bookingId, {
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double speedMetersPerSecond,
    required DateTime capturedAt,
  }) async {
    if (auth.currentUser == null) {
      return super.startCustomerArrivalSharing(
        bookingId,
        latitude: latitude,
        longitude: longitude,
        accuracyMeters: accuracyMeters,
        speedMetersPerSecond: speedMetersPerSecond,
        capturedAt: capturedAt,
      );
    }
    late DateTime expiresAt;
    await _runFirebaseSave(() async {
      final response = await functions
          .httpsCallable('startCustomerArrivalSharing')
          .call<Map<String, dynamic>>({
            'bookingId': bookingId,
            'latitude': latitude,
            'longitude': longitude,
            'accuracyMeters': accuracyMeters,
            'speedMetersPerSecond': speedMetersPerSecond,
            'capturedAtMillis': capturedAt.millisecondsSinceEpoch,
          });
      expiresAt = DateTime.fromMillisecondsSinceEpoch(
        _int(response.data['expiresAtMillis'], 0),
      );
      await _loadServerBooking(bookingId);
    });
    return expiresAt;
  }

  @override
  Future<void> updateCustomerArrivalLocation(
    String bookingId, {
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double speedMetersPerSecond,
    required DateTime capturedAt,
  }) async {
    if (auth.currentUser == null) return;
    await functions.httpsCallable('updateCustomerArrivalLocation').call<void>({
      'bookingId': bookingId,
      'latitude': latitude,
      'longitude': longitude,
      'accuracyMeters': accuracyMeters,
      'speedMetersPerSecond': speedMetersPerSecond,
      'capturedAtMillis': capturedAt.millisecondsSinceEpoch,
    });
  }

  @override
  Future<void> stopCustomerArrivalSharing(String bookingId) async {
    if (auth.currentUser == null) {
      return super.stopCustomerArrivalSharing(bookingId);
    }
    await _runFirebaseSave(() async {
      await functions.httpsCallable('stopCustomerArrivalSharing').call<void>({
        'bookingId': bookingId,
      });
      await _loadServerBooking(bookingId);
    });
  }

  @override
  Future<void> updateBookingExtraServices({
    required String bookingId,
    required String requestId,
    required String action,
    Map<String, int> expectedPrices = const {},
  }) async {
    await _callProtectedFunction(
      () => functions.httpsCallable('updateBookingExtraServices').call({
        'bookingId': bookingId,
        'requestId': requestId,
        'action': action,
        'serviceIds': expectedPrices.keys.toList(),
        'expectedPrices': expectedPrices,
      }),
    );
    // Firestore streams also publish the result to the other participant.
    // A refresh failure must not report an already committed charge as failed.
    try {
      await _loadServerBooking(bookingId).timeout(const Duration(seconds: 8));
    } catch (error) {
      _setSyncError(error);
    }
  }

  @override
  Future<void> updateBookingStatus(
    String bookingId,
    BookingStatus status, {
    String? cancellationReason,
    String? cancelledBy,
  }) async {
    if (auth.currentUser != null) {
      final index = _bookings.indexWhere((item) => item.id == bookingId);
      if (index == -1) {
        throw StateError('Booking not found.');
      }
      if (isBookingStatusUpdatePending(bookingId)) {
        return;
      }
      final originalBooking = _bookings[index];
      if (originalBooking.status == status) {
        return;
      }
      if (originalBooking.status == BookingStatus.cancelled ||
          originalBooking.status == BookingStatus.rejected ||
          originalBooking.status == BookingStatus.completed) {
        throw StateError(
          'A ${originalBooking.status.label.toLowerCase()} booking cannot be changed.',
        );
      }
      var optimisticSource = originalBooking;
      if (originalBooking.isInstant &&
          originalBooking.status == BookingStatus.pending &&
          status == BookingStatus.confirmed) {
        final acceptedStart = DateTime.now().add(
          Duration(minutes: originalBooking.customerArrivalMinutes),
        );
        final eligibleBarbers =
            barbersForServices(
                  originalBooking.salonId,
                  originalBooking.resolvedServiceIds,
                )
                .where(
                  (barber) => _isBarberFree(
                    barber.id,
                    acceptedStart,
                    originalBooking.durationMinutes,
                  ),
                )
                .toList()
              ..sort((a, b) => a.id.compareTo(b.id));
        if (eligibleBarbers.isNotEmpty) {
          optimisticSource = originalBooking.copyWith(
            barberId: eligibleBarbers.first.id,
          );
        }
      }
      final optimisticBooking = _bookingWithStatus(
        optimisticSource,
        status,
        now: DateTime.now(),
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
      final suppressOwnerAlert =
          originalBooking.isInstant &&
          originalBooking.status == BookingStatus.pending &&
          status != BookingStatus.pending;
      final queueOwnerDecision =
          suppressOwnerAlert &&
          (status == BookingStatus.confirmed ||
              status == BookingStatus.rejected);
      _bookingStatusRequests.add(bookingId);
      _optimisticBookingUpdates[bookingId] =
          OptimisticBooking(optimisticBooking);
      _bookings[index] = optimisticBooking;
      if (suppressOwnerAlert) {
        _suppressOwnerBookingAlertLocally(bookingId);
        _stopOwnerBookingAlarm(bookingId: bookingId);
      }
      notifyListeners();
      _syncOwnerBookingAlarm();
      var ownerDecisionPersisted = false;
      try {
        if (suppressOwnerAlert) {
          try {
            await _persistOwnerAlertSuppression(bookingId);
          } catch (error) {
            _setSyncError(error);
          }
        }
        if (queueOwnerDecision) {
          try {
            await _persistPendingOwnerBookingAction(bookingId, status.name);
            ownerDecisionPersisted = true;
          } catch (error) {
            _setSyncError(error);
          }
        }
        await _runFirebaseSave(() async {
          await _callProtectedFunction(
            () => functions.httpsCallable('updateBookingStatus').call<void>({
              'bookingId': bookingId,
              'status': status.name,
              'cancellationReason': cancellationReason?.trim() ?? '',
            }),
          );
        });
        if (ownerDecisionPersisted) {
          await _clearPendingOwnerBookingAction(bookingId);
        }
        var serverBookingReloaded = false;
        try {
          await _loadServerBooking(bookingId);
          serverBookingReloaded = true;
        } catch (error) {
          // The backend decision already succeeded. Keep the optimistic state
          // and let the Firestore listener reconcile it when connectivity
          // recovers instead of incorrectly bringing the request back.
          _setSyncError(error);
        }
        if (serverBookingReloaded) {
          _optimisticBookingUpdates.remove(bookingId);
        }
        notifyListeners();
        _syncOwnerBookingAlarm();
      } catch (error) {
        // The callable may have committed before its response was lost.
        // Reconcile with the server before rolling back Start/Complete.
        try {
          final saved = await _loadServerBooking(
            bookingId,
          ).timeout(const Duration(seconds: 8));
          if (saved.status == status) {
            _optimisticBookingUpdates.remove(bookingId);
            if (ownerDecisionPersisted) {
              await _clearPendingOwnerBookingAction(bookingId);
            }
            _syncOwnerBookingAlarm();
            return;
          }
        } catch (_) {
          // Preserve the original failure and the durable decision below.
        }
        final keepQueuedOwnerDecision =
            queueOwnerDecision &&
            ownerDecisionPersisted &&
            (error is! FirebaseFunctionsException ||
                isRetryableOwnerDecisionErrorCode(error.code));
        if (keepQueuedOwnerDecision) {
          // The owner has already acted on this phone. Keep the optimistic
          // decision and booking-specific alert suppression while the cloud
          // request is retried on the next foreground resume. Repeated pushes
          // for this booking are therefore received but remain silent.
          _setSyncError(error);
          notifyListeners();
          unawaited(_retryPendingOwnerBookingActions());
          return;
        }
        if (ownerDecisionPersisted) {
          try {
            await _clearPendingOwnerBookingAction(bookingId);
          } catch (cleanupError) {
            _setSyncError(cleanupError);
          }
        }
        _optimisticBookingUpdates.remove(bookingId);
        final currentIndex = _bookings.indexWhere(
          (item) => item.id == bookingId,
        );
        if (currentIndex == -1) {
          _bookings.add(originalBooking);
        } else if (_bookings[currentIndex].status == status) {
          _bookings[currentIndex] = originalBooking;
        }
        notifyListeners();
        _syncOwnerBookingAlarm();
        rethrow;
      } finally {
        _bookingStatusRequests.remove(bookingId);
        notifyListeners();
      }
      return;
    }
    await _runFirebaseSave(() async {
      final booking = _bookings
          .where((item) => item.id == bookingId)
          .firstOrNull;
      if (booking == null) {
        throw StateError('Booking not found.');
      }
      if (booking.status == status) {
        return;
      }
      if (booking.status == BookingStatus.cancelled ||
          booking.status == BookingStatus.rejected ||
          booking.status == BookingStatus.completed) {
        throw StateError(
          'A ${booking.status.label.toLowerCase()} booking cannot be changed.',
        );
      }

      final now = DateTime.now();
      final updatedBooking = _bookingWithStatus(
        booking,
        status,
        now: now,
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
      final bookingDoc = firestore.collection('bookings').doc(bookingId);
      final activeCustomerDoc = booking.customerUid == null
          ? null
          : firestore
                .collection('activeCustomerBookings')
                .doc(booking.customerUid);
      final activeInstantDoc = booking.customerUid == null
          ? null
          : firestore
                .collection('activeInstantBookings')
                .doc(booking.customerUid);
      final isTerminalStatus =
          status == BookingStatus.cancelled ||
          status == BookingStatus.rejected ||
          status == BookingStatus.completed;
      final shouldCloseCustomerBooking = isTerminalStatus;
      final shouldCloseInstantBooking = booking.isInstant && isTerminalStatus;
      final shouldClaimInstantLocks =
          booking.isInstant &&
          booking.status == BookingStatus.pending &&
          status == BookingStatus.confirmed;
      final shouldReleaseLocks =
          status == BookingStatus.cancelled ||
          status == BookingStatus.rejected ||
          status == BookingStatus.completed ||
          updatedBooking.start != booking.start;
      final shouldCreateLocks =
          status != BookingStatus.cancelled &&
          status != BookingStatus.rejected &&
          status != BookingStatus.completed;
      if (shouldReleaseLocks || shouldClaimInstantLocks) {
        final previousLockStarts = _slotSegmentStarts(
          booking.start,
          booking.durationMinutes,
        );
        final previousLockDocs = [
          for (final start in previousLockStarts)
            firestore
                .collection('slotLocks')
                .doc(_slotLockId(booking.barberId, start)),
        ];
        final nextLockStarts = shouldCreateLocks
            ? _slotSegmentStarts(
                updatedBooking.start,
                updatedBooking.durationMinutes,
              )
            : <DateTime>[];
        final nextLockDocs = [
          for (final start in nextLockStarts)
            firestore
                .collection('slotLocks')
                .doc(_slotLockId(updatedBooking.barberId, start)),
        ];
        await firestore.runTransaction((transaction) async {
          final previousLockSnapshots =
              <DocumentSnapshot<Map<String, dynamic>>>[];
          for (final lockDoc in previousLockDocs) {
            previousLockSnapshots.add(await transaction.get(lockDoc));
          }
          final nextLockSnapshots = <DocumentSnapshot<Map<String, dynamic>>>[];
          for (final lockDoc in nextLockDocs) {
            nextLockSnapshots.add(await transaction.get(lockDoc));
          }
          final activeInstantSnapshot =
              shouldCloseInstantBooking && activeInstantDoc != null
              ? await transaction.get(activeInstantDoc)
              : null;
          final activeCustomerSnapshot =
              shouldCloseCustomerBooking && activeCustomerDoc != null
              ? await transaction.get(activeCustomerDoc)
              : null;
          if (nextLockSnapshots.any((snapshot) {
            final data = snapshot.data();
            return snapshot.exists &&
                data?['active'] != false &&
                data?['bookingId'] != booking.id;
          })) {
            throw StateError(
              'This slot was just booked. Please choose another time.',
            );
          }
          transaction.set(
            bookingDoc,
            _bookingStatusUpdateToFirestore(updatedBooking),
            SetOptions(merge: true),
          );
          if (activeInstantSnapshot?.data()?['bookingId'] == booking.id) {
            transaction.set(activeInstantDoc!, {
              'active': false,
              'resolvedStatus': status.name,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
          if (activeCustomerSnapshot?.data()?['bookingId'] == booking.id) {
            transaction.set(activeCustomerDoc!, {
              'active': false,
              'resolvedStatus': status.name,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
          for (var index = 0; index < previousLockDocs.length; index++) {
            if (previousLockSnapshots[index].data()?['bookingId'] ==
                booking.id) {
              transaction.set(previousLockDocs[index], {
                'active': false,
                'updatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            }
          }
          for (var index = 0; index < nextLockDocs.length; index++) {
            transaction.set(nextLockDocs[index], {
              'bookingId': updatedBooking.id,
              'salonId': updatedBooking.salonId,
              'serviceId': updatedBooking.serviceId,
              'barberId': updatedBooking.barberId,
              'start': Timestamp.fromDate(nextLockStarts[index]),
              'bookingStart': Timestamp.fromDate(updatedBooking.start),
              'active': true,
              'createdAt': Timestamp.fromDate(updatedBooking.createdAt),
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
        });
      } else if (shouldCloseCustomerBooking && activeCustomerDoc != null) {
        await firestore.runTransaction((transaction) async {
          final activeCustomerSnapshot = await transaction.get(
            activeCustomerDoc,
          );
          final activeInstantSnapshot =
              shouldCloseInstantBooking && activeInstantDoc != null
              ? await transaction.get(activeInstantDoc)
              : null;
          transaction.set(
            bookingDoc,
            _bookingStatusUpdateToFirestore(updatedBooking),
            SetOptions(merge: true),
          );
          if (activeCustomerSnapshot.data()?['bookingId'] == booking.id) {
            transaction.set(activeCustomerDoc, {
              'active': false,
              'resolvedStatus': status.name,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
          if (activeInstantSnapshot?.data()?['bookingId'] == booking.id) {
            transaction.set(activeInstantDoc!, {
              'active': false,
              'resolvedStatus': status.name,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
        });
      } else {
        await bookingDoc.set(
          _bookingStatusUpdateToFirestore(updatedBooking),
          SetOptions(merge: true),
        );
      }
      _applyBookingStatus(
        bookingId,
        status,
        now: now,
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
      _syncOwnerBookingAlarm();
      await _sendBookingPush(bookingId, event: 'statusUpdated');
    });
  }

  @override
  Future<void> updateCustomerProfile({
    required String name,
    required String phone,
    required String gender,
    required String birthDate,
    required List<String> preferredStyles,
    String? photoUrl,
    List<String>? stylePhotoUrls,
  }) async {
    await _runFirebaseSave(() async {
      await functions.httpsCallable('updateCustomerProfile').call<void>({
        'name': name.trim(),
        'phone': normalizePhone(phone),
        'gender': gender.trim(),
        'birthDate': birthDate.trim(),
        'preferredStyles': preferredStyles,
        'photoUrl': photoUrl?.trim() ?? _customerAccount?.photoUrl ?? '',
        'stylePhotoUrls':
            stylePhotoUrls ?? _customerAccount?.stylePhotoUrls ?? const [],
      });
      await auth.currentUser?.reload();
      await auth.currentUser?.getIdToken(true);
      await super.updateCustomerProfile(
        name: name,
        phone: phone,
        gender: gender,
        birthDate: birthDate,
        preferredStyles: preferredStyles,
        photoUrl: photoUrl,
        stylePhotoUrls: stylePhotoUrls,
      );
    });
  }

  @override
  Future<String> uploadCustomerProfilePhoto({
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    final uid = auth.currentUser?.uid;
    final account = _customerAccount;
    if (uid == null || account == null || _activeRole != UserRole.customer) {
      throw StateError('Log in as a customer before uploading a photo.');
    }
    final safeName = _safeUploadName(fileName);
    final ref = storage.ref(
      'customers/$uid/profile/${DateTime.now().millisecondsSinceEpoch}-$safeName',
    );
    return _runFirebaseSave(() async {
      await ref.putData(
        bytes,
        SettableMetadata(
          contentType: contentType ?? _guessImageContentType(fileName),
          customMetadata: {'customerUid': uid, 'kind': 'profile'},
        ),
      );
      final url = await ref.getDownloadURL();
      await updateCustomerProfile(
        name: account.name,
        phone: account.contact,
        gender: account.gender,
        birthDate: account.birthDate,
        preferredStyles: account.preferredStyles,
        photoUrl: url,
        stylePhotoUrls: account.stylePhotoUrls,
      );
      return url;
    });
  }

  @override
  Future<String> uploadCustomerStylePhoto({
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    final uid = auth.currentUser?.uid;
    final account = _customerAccount;
    if (uid == null || account == null || _activeRole != UserRole.customer) {
      throw StateError('Log in as a customer before uploading style photos.');
    }
    if (account.stylePhotoUrls.length >= 8) {
      throw StateError('You can save up to 8 preferred-style photos.');
    }
    final safeName = _safeUploadName(fileName);
    final ref = storage.ref(
      'customers/$uid/styles/${DateTime.now().millisecondsSinceEpoch}-$safeName',
    );
    return _runFirebaseSave(() async {
      await ref.putData(
        bytes,
        SettableMetadata(
          contentType: contentType ?? _guessImageContentType(fileName),
          customMetadata: {'customerUid': uid, 'kind': 'preferred-style'},
        ),
      );
      final url = await ref.getDownloadURL();
      final urls = [...account.stylePhotoUrls, url];
      await updateCustomerProfile(
        name: account.name,
        phone: account.contact,
        gender: account.gender,
        birthDate: account.birthDate,
        preferredStyles: account.preferredStyles,
        photoUrl: account.photoUrl,
        stylePhotoUrls: urls,
      );
      return url;
    });
  }

  @override
  Future<void> removeCustomerStylePhoto(String photoUrl) async {
    final account = _customerAccount;
    if (account == null) {
      throw StateError('Log in as a customer before editing style photos.');
    }
    final urls = account.stylePhotoUrls
        .where((url) => url != photoUrl.trim())
        .toList(growable: false);
    await updateCustomerProfile(
      name: account.name,
      phone: account.contact,
      gender: account.gender,
      birthDate: account.birthDate,
      preferredStyles: account.preferredStyles,
      photoUrl: account.photoUrl,
      stylePhotoUrls: urls,
    );
    try {
      await storage.refFromURL(photoUrl).delete();
    } catch (_) {
      // The profile update is authoritative even if an old file is gone.
    }
  }

  @override
  Future<void> submitSalonFeedback({
    required String bookingId,
    required int rating,
    required String note,
  }) async {
    await _runFirebaseSave(() async {
      await functions.httpsCallable('submitSalonFeedback').call<void>({
        'bookingId': bookingId,
        'rating': rating,
        'note': note.trim(),
      });
      await super.submitSalonFeedback(
        bookingId: bookingId,
        rating: rating,
        note: note,
      );
    });
  }

  @override
  Future<void> submitCustomerRating({
    required String bookingId,
    required int rating,
    required String note,
  }) async {
    await _runFirebaseSave(() async {
      await functions.httpsCallable('submitCustomerRating').call<void>({
        'bookingId': bookingId,
        'rating': rating,
        'note': note.trim(),
      });
      await super.submitCustomerRating(
        bookingId: bookingId,
        rating: rating,
        note: note,
      );
    });
  }

  @override
  Future<Booking> rescheduleBooking(
    String bookingId, {
    required TimeSlot slot,
  }) {
    if (auth.currentUser == null) {
      return super.rescheduleBooking(bookingId, slot: slot);
    }
    return _runFirebaseSave(() async {
      final result = await functions
          .httpsCallable('rescheduleBooking')
          .call<Map<String, dynamic>>({
            'bookingId': bookingId,
            'barberId': slot.barberId,
            'startMillis': slot.start.millisecondsSinceEpoch,
          });
      return _loadServerBooking(_string(result.data['bookingId'], bookingId));
    });
  }

  @override
  Future<void> updateOwnerSalon({
    required String name,
    required String ownerName,
    required String address,
    String? directionsUrl,
    required String phone,
    String email = '',
    String? logoUrl,
    List<String>? photoUrls,
    required String openTime,
    required String closeTime,
  }) async {
    await _runFirebaseSave(() async {
      final normalizedPhone = normalizePhone(phone);
      final accountEmail = ownerAccount?.contact.trim() ?? '';
      final normalizedEmail = email.trim().isNotEmpty
          ? email.trim().toLowerCase()
          : (accountEmail.contains('@') ? accountEmail.toLowerCase() : '');
      if (normalizedPhone.isEmpty ||
          !RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(normalizedPhone)) {
        throw FormatException('Enter a valid salon phone number.');
      }
      if (!_isValidEmail(normalizedEmail)) {
        throw FormatException('Enter a valid salon email address.');
      }
      if (name.trim().isEmpty ||
          ownerName.trim().isEmpty ||
          address.trim().isEmpty) {
        throw ArgumentError(
          'Salon name, owner name, and address are required.',
        );
      }
      final openingMinutes = _parseClockMinutes(openTime);
      final closingMinutes = _parseClockMinutes(closeTime);
      if (openingMinutes == null || closingMinutes == null) {
        throw FormatException('Use a valid time such as 9:00 AM or 18:30.');
      }
      if (closingMinutes <= openingMinutes) {
        throw ArgumentError('Closing time must be after opening time.');
      }
      final currentSalon = ownerSalon;
      await _callOwnerMutation('saveOwnerSalonProfile', {
        'salonId': ownerSalonId,
        'name': name.trim(),
        'ownerName': ownerName.trim(),
        'address': address.trim(),
        'directionsUrl': directionsUrl?.trim() ?? '',
        'phone': normalizedPhone,
        'email': normalizedEmail,
        'logoUrl': logoUrl?.trim() ?? currentSalon.logoUrl,
        'photoUrls': photoUrls ?? currentSalon.photoUrls,
        'openTime': formatSalonClockTime(openTime),
        'closeTime': formatSalonClockTime(closeTime),
        'services': currentSalon.services.map(_serviceToMap).toList(),
      });
      await super.updateOwnerSalon(
        name: name,
        ownerName: ownerName,
        address: address,
        directionsUrl: directionsUrl,
        phone: phone,
        email: normalizedEmail,
        logoUrl: logoUrl,
        photoUrls: photoUrls,
        openTime: openTime,
        closeTime: closeTime,
      );
    });
  }

  @override
  Future<void> refreshOwnerPaymentDetails() async {
    if (!hasActiveOwnerSession || ownerSalonId.isEmpty) {
      await super.refreshOwnerPaymentDetails();
      return;
    }
    final snapshot = await firestore
        .collection('salonPaymentProfiles')
        .doc(ownerSalonId)
        .get();
    final data = snapshot.data() ?? const <String, dynamic>{};
    _ownerPaymentUpiId = _string(data['upiId'], '');
    _ownerPaymentQrCodeUrl = _string(data['qrCodeUrl'], '');
    notifyListeners();
  }

  @override
  Future<void> saveOwnerPaymentUpiId(String upiId) async {
    await _runFirebaseSave(() async {
      await super.saveOwnerPaymentUpiId(upiId);
      final uid = auth.currentUser?.uid;
      if (uid == null) {
        throw StateError(
          'Log in as a salon owner before saving payment details.',
        );
      }
      await firestore.collection('salonPaymentProfiles').doc(ownerSalonId).set({
        'salonId': ownerSalonId,
        'ownerUid': uid,
        'upiId': _ownerPaymentUpiId,
        'qrCodeUrl': _ownerPaymentQrCodeUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  @override
  Future<String> uploadOwnerPaymentQrCode({
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError('Choose a QR-code image before uploading.');
    }
    if (!hasActiveOwnerSession || ownerSalonOrNull == null) {
      throw StateError('Save the salon profile before uploading a QR code.');
    }
    final salonId = ownerSalonId;
    final previousUrl = _ownerPaymentQrCodeUrl;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ref = storage.ref(
      'salons/$salonId/payments/$timestamp-${_safeUploadName(fileName)}',
    );
    final metadata = SettableMetadata(
      contentType: contentType ?? _guessImageContentType(fileName),
      customMetadata: {
        'salonId': salonId,
        if (auth.currentUser?.uid != null) 'ownerUid': auth.currentUser!.uid,
        'purpose': 'upi-qr-code',
      },
    );
    await _runFirebaseSave(() async {
      await ref.putData(bytes, metadata);
      final url = await ref.getDownloadURL();
      _ownerPaymentQrCodeUrl = url;
      final uid = auth.currentUser?.uid;
      if (uid == null) {
        throw StateError('Log in as a salon owner before uploading a QR code.');
      }
      await firestore.collection('salonPaymentProfiles').doc(salonId).set({
        'salonId': salonId,
        'ownerUid': uid,
        'upiId': _ownerPaymentUpiId,
        'qrCodeUrl': url,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (previousUrl.isNotEmpty && previousUrl != url) {
        try {
          await storage.refFromURL(previousUrl).delete();
        } on FirebaseException catch (error) {
          if (error.code != 'object-not-found') rethrow;
        }
      }
      notifyListeners();
    });
    return _ownerPaymentQrCodeUrl;
  }

  @override
  Future<void> removeOwnerPaymentQrCode() async {
    final previousUrl = _ownerPaymentQrCodeUrl;
    await _runFirebaseSave(() async {
      await super.removeOwnerPaymentQrCode();
      final uid = auth.currentUser?.uid;
      if (uid == null || ownerSalonId.isEmpty) {
        throw StateError(
          'Log in as a salon owner before changing payment details.',
        );
      }
      await firestore.collection('salonPaymentProfiles').doc(ownerSalonId).set({
        'salonId': ownerSalonId,
        'ownerUid': uid,
        'qrCodeUrl': '',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (previousUrl.isNotEmpty) {
        try {
          await storage.refFromURL(previousUrl).delete();
        } on FirebaseException catch (error) {
          if (error.code != 'object-not-found') rethrow;
        }
      }
    });
  }

  @override
  Future<void> setOwnerInstantBookingEnabled(bool enabled) async {
    if (_isInstantBookingSaving) {
      return;
    }
    final previous = ownerSalon;
    _lastSyncError = null;
    _setInstantBookingSaving(true);
    try {
      await super.setOwnerInstantBookingEnabled(enabled);
      await _callOwnerMutation('setOwnerInstantBookingEnabled', {
        'salonId': ownerSalonId,
        'enabled': enabled,
      });
    } catch (error) {
      _replaceSalon(previous);
      _setSyncError(error);
      rethrow;
    } finally {
      _setInstantBookingSaving(false);
    }
  }

  @override
  Future<String> uploadOwnerSalonPhoto({
    required Uint8List bytes,
    required String fileName,
    String? contentType,
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError('Choose a photo before uploading.');
    }
    final salonId = ownerSalonId;
    if (salonId.isEmpty) {
      throw StateError('Log in as a salon owner before uploading photos.');
    }
    final safeName = fileName
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ref = storage.ref(
      'salons/$salonId/photos/$timestamp-${safeName.isEmpty ? 'photo.jpg' : safeName}',
    );
    final metadata = SettableMetadata(
      contentType: contentType ?? _guessImageContentType(fileName),
      customMetadata: {
        'salonId': salonId,
        if (auth.currentUser?.uid != null) 'ownerUid': auth.currentUser!.uid,
      },
    );
    await _runFirebaseSave(() async {
      await ref.putData(bytes, metadata);
      final url = await ref.getDownloadURL();
      final photos = [...ownerSalon.photoUrls, url];
      await super.updateOwnerSalon(
        name: ownerSalon.name,
        ownerName: ownerSalon.ownerName,
        address: ownerSalon.address,
        directionsUrl: ownerSalon.directionsUrl,
        phone: ownerSalon.phone,
        email: ownerSalon.email,
        logoUrl: ownerSalon.logoUrl,
        photoUrls: photos,
        openTime: ownerSalon.openTime,
        closeTime: ownerSalon.closeTime,
      );
      await _saveOwnerSalonProfileToCloud(ownerSalon);
    });
    return ownerSalon.photoUrls.last;
  }

  @override
  Future<void> removeOwnerSalonPhoto(String photoUrl) async {
    final trimmed = photoUrl.trim();
    await _runFirebaseSave(() async {
      await super.removeOwnerSalonPhoto(trimmed);
      await _saveOwnerSalonProfileToCloud(ownerSalon);
      try {
        await storage.refFromURL(trimmed).delete();
      } on FirebaseException catch (error) {
        if (error.code != 'object-not-found') {
          rethrow;
        }
      }
    });
  }

  @override
  Future<void> addOwnerService({
    required String name,
    required String category,
    required int price,
    required int durationMinutes,
    bool isAvailable = true,
    bool instantBookingEnabled = true,
  }) async {
    if (!isApprovedServiceName(name)) {
      throw ArgumentError(
        'Choose a service from the standard Pritze service menu.',
      );
    }
    final template = serviceTemplateForName(name)!;
    final shouldPersist = ownerSalonOrNull != null;
    final previous = ownerSalon;
    await _runFirebaseSave(() async {
      try {
        await super.addOwnerService(
          name: template.name,
          category: template.category,
          price: price,
          durationMinutes: durationMinutes,
          isAvailable: isAvailable,
          instantBookingEnabled: instantBookingEnabled,
        );
        if (shouldPersist) {
          await _saveOwnerSalonServices();
        }
      } catch (_) {
        _replaceSalon(previous);
        notifyListeners();
        rethrow;
      }
    });
  }

  @override
  Future<void> updateOwnerService({
    required String serviceId,
    required String name,
    required String category,
    required int price,
    required int durationMinutes,
    bool? isAvailable,
    bool? instantBookingEnabled,
  }) async {
    final currentService = ownerSalon.services
        .where((service) => service.id == serviceId)
        .firstOrNull;
    final template = currentService == null
        ? null
        : serviceTemplateForName(currentService.name);
    if (template == null) {
      throw StateError('This service is not in the standard service menu.');
    }
    final shouldPersist = ownerSalonOrNull != null;
    final previous = ownerSalon;
    await _runFirebaseSave(() async {
      try {
        await super.updateOwnerService(
          serviceId: serviceId,
          name: template.name,
          category: template.category,
          price: price,
          durationMinutes: durationMinutes,
          isAvailable: isAvailable,
          instantBookingEnabled: instantBookingEnabled,
        );
        if (shouldPersist) {
          await _saveOwnerSalonServices();
        }
      } catch (_) {
        _replaceSalon(previous);
        notifyListeners();
        rethrow;
      }
    });
  }

  @override
  Future<int> addOwnerServicesFromCatalog({
    Iterable<String>? serviceNames,
  }) async {
    final shouldPersist = ownerSalonOrNull != null;
    final previous = ownerSalon;
    return _runFirebaseSave(() async {
      try {
        final added = await super.addOwnerServicesFromCatalog(
          serviceNames: serviceCatalog.map((service) => service.name),
        );
        if (added > 0 && shouldPersist) {
          await _saveOwnerSalonServices();
        }
        return added;
      } catch (_) {
        _replaceSalon(previous);
        notifyListeners();
        rethrow;
      }
    });
  }

  @override
  Future<void> removeOwnerService(String serviceId) async {
    throw StateError(
      'Standard services cannot be removed. Mark the service unavailable instead.',
    );
  }

  @override
  Future<void> addOwnerBarber({
    required String name,
    String phone = '',
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    final barber = _newOwnerBarber(
      name: name,
      phone: phone,
      speciality: speciality,
      experienceYears: experienceYears,
      resumeSummary: resumeSummary,
      serviceIds: serviceIds,
    );
    await _runFirebaseSave(() async {
      // Capture the new record independently of the live Firestore list.
      // A snapshot arriving during an await must not skip or redirect this save.
      await _saveOwnerBarber(barber);
      final index = _barbers.indexWhere((item) => item.id == barber.id);
      if (index == -1) {
        _barbers.add(barber);
      } else {
        _barbers[index] = barber;
      }
      notifyListeners();
    });
  }

  @override
  Future<void> updateOwnerBarber({
    required String barberId,
    required String name,
    String phone = '',
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    final previous = List<Barber>.of(_barbers);
    await _runFirebaseSave(() async {
      try {
        await super.updateOwnerBarber(
          barberId: barberId,
          name: name,
          phone: phone,
          speciality: speciality,
          experienceYears: experienceYears,
          resumeSummary: resumeSummary,
          serviceIds: serviceIds,
        );
        final barber = _barbers
            .where((item) => item.id == barberId)
            .firstOrNull;
        if (barber != null) {
          await _saveOwnerBarber(barber);
        }
      } catch (_) {
        _barbers
          ..clear()
          ..addAll(previous);
        notifyListeners();
        rethrow;
      }
    });
  }

  @override
  Future<void> submitJoinRequest({
    required String salonId,
    required String barberName,
    required String barberPhone,
    String barberEmail = '',
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    final before = _joinRequests.length;
    await _runFirebaseSave(() async {
      await super.submitJoinRequest(
        salonId: salonId,
        barberName: barberName,
        barberPhone: barberPhone,
        barberEmail: barberEmail,
        speciality: speciality,
        experienceYears: experienceYears,
        resumeSummary: resumeSummary,
        serviceIds: serviceIds,
      );
      if (_joinRequests.length > before) {
        await _setJoinRequest(_joinRequests.last);
        unawaited(
          _sendJoinRequestPush(_joinRequests.last.id, event: 'created'),
        );
      }
    });
  }

  @override
  Future<void> approveJoinRequest(String requestId) async {
    await _runFirebaseSave(() async {
      await super.approveJoinRequest(requestId);
      final request = _joinRequests
          .where((item) => item.id == requestId)
          .firstOrNull;
      if (request != null) {
        await firestore.collection('joinRequests').doc(requestId).set({
          'status': _joinRequestStatusName(JoinRequestStatus.approved),
          'reviewedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      final barber = _barbers.lastOrNull;
      if (barber != null && barber.name == request?.barberName) {
        await _setBarber(barber);
      }
      unawaited(_sendJoinRequestPush(requestId, event: 'approved'));
    });
  }

  @override
  Future<void> rejectJoinRequest(String requestId) async {
    await _runFirebaseSave(() async {
      await super.rejectJoinRequest(requestId);
      await firestore.collection('joinRequests').doc(requestId).set({
        'status': _joinRequestStatusName(JoinRequestStatus.rejected),
        'reviewedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      unawaited(_sendJoinRequestPush(requestId, event: 'rejected'));
    });
  }

  @override
  Future<void> withdrawJoinRequest(String requestId) async {
    await _runFirebaseSave(() async {
      await super.withdrawJoinRequest(requestId);
      await firestore.collection('joinRequests').doc(requestId).set({
        'status': _joinRequestStatusName(JoinRequestStatus.withdrawn),
        'withdrawnAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      unawaited(_sendJoinRequestPush(requestId, event: 'withdrawn'));
    });
  }

  @override
  Future<void> removeBarber(String barberId) async {
    final previous = List<Barber>.of(_barbers);
    await _runFirebaseSave(() async {
      try {
        await super.removeBarber(barberId);
        final barber = _barbers
            .where((item) => item.id == barberId)
            .firstOrNull;
        if (barber != null) {
          await _saveOwnerBarber(barber);
        }
      } catch (_) {
        _barbers
          ..clear()
          ..addAll(previous);
        notifyListeners();
        rethrow;
      }
    });
  }

  void _connectFirestore() {
    _subscriptions.add(
      firestore.collection('salons').snapshots().listen(
        (snapshot) {
          // Parse before clearing, and keep one bad document from taking the
          // rest with it. This list reads the whole collection, so a single
          // malformed salon used to empty it for everyone — and an owner with
          // no salon in the list is sent to the registration screen, which
          // replaces the dashboard and cannot be dismissed.
          final parsed = parseDocuments(
            snapshot.docs,
            _salonFromFirestore,
            onSkipped: _setSyncError,
          );
          _salons
            ..clear()
            ..addAll(parsed);
          _ownerProfileCompleted = ownerSalonOrNull != null;
          _salonsLoaded = true;
          notifyListeners();
        },
        onError: (Object error) {
          // Leave the last good list in place rather than stranding the owner.
          _setSyncError(error);
        },
      ),
    );
    _subscriptions.add(
      firestore.collection('appConfig').doc('public').snapshots().listen((
        snapshot,
      ) {
        final phone = (snapshot.data()?['supportPhone'] as String?)?.trim();
        if (phone != null && phone.isNotEmpty && phone != _supportPhone) {
          _supportPhone = phone;
          notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      firestore.collection('barbers').snapshots().listen(
        (snapshot) {
          final parsed = parseDocuments(
            snapshot.docs,
            _barberFromFirestore,
            onSkipped: _setSyncError,
          );
          _barbers
            ..clear()
            ..addAll(parsed);
          notifyListeners();
        },
        onError: (Object error) {
          _setSyncError(error);
        },
      ),
    );
    _subscriptions.add(
      firestore
          .collection('slotLocks')
          .where('active', isEqualTo: true)
          .snapshots()
          .listen((snapshot) {
            _occupiedSlotKeys
              ..clear()
              ..addAll(snapshot.docs.map(_slotKeyFromLock));
            notifyListeners();
          }),
    );
    _subscriptions.add(
      auth.authStateChanges().listen((user) {
        _connectPrivateFirestore(user);
      }),
    );
  }

  void _configurePushNotifications() {
    _subscriptions.add(
      messaging.onTokenRefresh.listen((token) {
        final uid = auth.currentUser?.uid;
        if (uid != null) {
          unawaited(_saveMessagingToken(uid, token: token));
        }
      }),
    );
    _subscriptions.add(
      FirebaseMessaging.onMessage.listen((message) {
        unawaited(_showForegroundPushNotification(message));
      }),
    );
    _subscriptions.add(
      FirebaseMessaging.onMessageOpenedApp.listen(
        _handleRemoteNotificationOpened,
      ),
    );
    unawaited(
      messaging.getInitialMessage().then((message) {
        if (message != null) {
          _handleRemoteNotificationOpened(message);
        }
      }),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_requestPushPermissionAndRegister());
    });
  }

  Future<void> _requestPushPermissionAndRegister() async {
    if (_pushPermissionSetupStarted) {
      return;
    }
    _pushPermissionSetupStarted = true;
    try {
      await _initializeLocalNotifications();
      var settings = await messaging.getNotificationSettings();
      final preferences = await SharedPreferences.getInstance();
      final hasRequestedOnAndroid =
          preferences.getBool(_pushPermissionRequestedPreferenceKey) ?? false;
      final isAndroid =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
      if (shouldRequestPushPermission(
        settings.authorizationStatus,
        isAndroid: isAndroid,
        hasRequestedOnAndroid: hasRequestedOnAndroid,
      )) {
        settings = await messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
        if (isAndroid) {
          await preferences.setBool(
            _pushPermissionRequestedPreferenceKey,
            true,
          );
        }
      }
      await messaging.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );
      if (canRegisterForPushNotifications(settings.authorizationStatus)) {
        final uid = auth.currentUser?.uid;
        if (uid != null) {
          await _saveMessagingToken(uid);
        }
      }
    } catch (error) {
      _setSyncError(error);
    }
  }

  Future<void> _initializeLocalNotifications() {
    if (_localNotificationsReady) {
      return Future.value();
    }
    return _localNotificationsInitialization ??=
        _performLocalNotificationsInitialization();
  }

  Future<void> _performLocalNotificationsInitialization() async {
    final initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories:
            _ownerBookingRequestDarwinNotificationCategories,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories:
            _ownerBookingRequestDarwinNotificationCategories,
      ),
    );
    try {
      await _localNotifications.initialize(
        settings: initializationSettings,
        onDidReceiveNotificationResponse: _handleLocalNotificationResponse,
        onDidReceiveBackgroundNotificationResponse:
            notificationActionBackgroundHandler,
      );
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_pushNotificationChannel);
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_ownerBookingRequestChannel);
      _localNotificationsReady = true;
      final launchDetails = await _localNotifications
          .getNotificationAppLaunchDetails();
      final launchResponse = launchDetails?.notificationResponse;
      if (launchDetails?.didNotificationLaunchApp == true &&
          launchResponse != null) {
        unawaited(_processLocalNotificationResponse(launchResponse));
      }
    } finally {
      _localNotificationsInitialization = null;
    }
  }

  void _handleRemoteNotificationOpened(RemoteMessage message) {
    final bookingId = message.data['bookingId']?.toString().trim() ?? '';
    _applyRemoteCustomerBookingHint(message.data);
    if (message.data['status']?.toString() == BookingStatus.completed.name) {
      queueCompletionReceipt(bookingId);
    }
    final destination = _notificationDestination(message.data['destination']);
    queueNotificationNavigation(destination, bookingId: bookingId);
  }

  void _handleLocalNotificationResponse(NotificationResponse response) {
    unawaited(_processLocalNotificationResponse(response));
  }

  Future<void> _processLocalNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = _decodeNotificationPayload(response.payload);
    final bookingId = payload['bookingId']?.toString().trim() ?? '';
    _applyRemoteCustomerBookingHint(payload);
    if (payload['status']?.toString() == BookingStatus.completed.name) {
      queueCompletionReceipt(bookingId);
    }
    final destination = _notificationDestination(payload['destination']);
    final actionId = response.actionId?.trim() ?? '';
    final isBookingDecision =
        actionId == _acceptInstantBookingNotificationAction ||
        actionId == _rejectInstantBookingNotificationAction;
    queueNotificationNavigation(destination, bookingId: bookingId);
    if (!isBookingDecision || bookingId.isEmpty) {
      return;
    }
    if (!_notificationDecisionsInFlight.add(bookingId)) return;
    _suppressOwnerBookingAlertLocally(bookingId);
    _stopOwnerBookingAlarm(bookingId: bookingId);
    final nextStatus = actionId == _acceptInstantBookingNotificationAction
        ? BookingStatus.confirmed.name
        : BookingStatus.rejected.name;
    try {
      await performOwnerBookingDecision(
        bookingId: bookingId,
        status: nextStatus,
        cancel: () => _cancelOwnerBookingNotifications(
          _localNotifications,
          bookingId: bookingId,
        ),
        submit: () async {
          // The launch payload identifies the request. Do not require its
          // Firestore snapshot to have reached the freshly opened app yet.
          final user =
              auth.currentUser ??
              await auth
                  .authStateChanges()
                  .firstWhere((user) => user != null)
                  .timeout(const Duration(seconds: 10));
          if (user == null) {
            throw StateError('Sign in to respond to this booking.');
          }
          await _callProtectedFunction(
            () => functions.httpsCallable('updateBookingStatus').call<void>({
              'bookingId': bookingId,
              'status': nextStatus,
              'cancellationReason': '',
              'actionSource': 'notification_action_foreground',
            }),
          );
        },
      );
      await _clearOwnerDecisionFeedback(bookingId);
      try {
        await _loadServerBooking(bookingId);
      } catch (error) {
        // The decision is already saved; the booking stream can reconcile.
        _setSyncError(error);
      }
    } catch (error) {
      _setSyncError(error);
      await _showOwnerDecisionFailure(
        bookingId,
        error,
        initializedNotifications: _localNotifications,
      );
    } finally {
      _notificationDecisionsInFlight.remove(bookingId);
      unawaited(_retryPendingOwnerBookingActions());
      _syncOwnerBookingAlarm();
    }
  }

  Map<String, dynamic> _decodeNotificationPayload(String? payload) {
    return _decodeNotificationPayloadValue(payload);
  }

  AppNotificationDestination _notificationDestination(Object? value) {
    return switch (value?.toString().trim() ?? '') {
      'team' => AppNotificationDestination.team,
      'overview' => AppNotificationDestination.overview,
      _ => AppNotificationDestination.bookings,
    };
  }

  Future<void> _showForegroundPushNotification(RemoteMessage message) async {
    final bookingId = message.data['bookingId']?.toString().trim() ?? '';
    if (_isOwnerBookingResolution(message.data) && bookingId.isNotEmpty) {
      _suppressOwnerBookingAlertLocally(bookingId);
      await _persistOwnerAlertSuppression(bookingId);
      await _clearPendingOwnerBookingAction(bookingId);
      await _initializeLocalNotifications();
      await _cancelOwnerBookingNotifications(
        _localNotifications,
        bookingId: bookingId,
      );
      await _clearOwnerDecisionFeedback(bookingId);
      _syncOwnerBookingAlarm();
      if (message.data['action'] == 'stop_owner_booking_alarm') return;
    }
    final status = message.data['status']?.toString() ?? '';
    final isForegroundCustomerPopupUpdate =
        _activeRole == UserRole.customer &&
        _customerAccount != null &&
        message.data['event']?.toString() != 'created' &&
        <String>{
          BookingStatus.confirmed.name,
          BookingStatus.rejected.name,
          BookingStatus.cancelled.name,
          BookingStatus.completed.name,
        }.contains(status);
    if (isForegroundCustomerPopupUpdate) {
      _applyRemoteCustomerBookingHint(message.data);
      final bookingId = message.data['bookingId']?.toString().trim() ?? '';
      if (status == BookingStatus.completed.name) {
        queueCompletionReceipt(bookingId);
      }
      if (bookingId.isNotEmpty) {
        unawaited(
          (() async {
            try {
              await _loadServerBooking(bookingId);
            } catch (error) {
              // The pushed completion is already authoritative. Keep the fast
              // local receipt and let the booking stream reconcile if this
              // single-document refresh is temporarily unavailable.
              _setSyncError(error);
            }
          })(),
        );
      }
      return;
    }
    final notification = message.notification;
    final title =
        notification?.title ?? message.data['notificationTitle']?.trim();
    final body = notification?.body ?? message.data['notificationBody']?.trim();
    if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) {
      return;
    }
    final isOwnerBookingRequest = _isOwnerBookingRequestChannel(
      message.data['channel'],
    );
    if (isOwnerBookingRequest &&
        (_activeRole != UserRole.owner || _ownerAccount == null)) {
      return;
    }
    await _initializeLocalNotifications();
    if (isOwnerBookingRequest) {
      final deadline = _ownerAlertMessageDeadline(message);
      if (bookingId.isEmpty || deadline == null) return;
      await _showUnansweredOwnerBookingAlert(
        notifications: _localNotifications,
        bookingId: bookingId,
        deadline: deadline,
        title: title ?? 'Instant booking request',
        body: body ?? 'A customer is waiting for accept or reject.',
        data: message.data,
        isStillPending: () {
          final booking = _bookings
              .where((item) => item.id == bookingId)
              .firstOrNull;
          return _activeRole == UserRole.owner &&
              !_isOwnerBookingAlertSuppressedLocally(bookingId) &&
              (booking == null || _ownerBookingCanRing(booking));
        },
      );
      return;
    }
    await _localNotifications.show(
      id: DateTime.now().millisecondsSinceEpoch.remainder(1000000),
      title: title ?? 'Pritze',
      body: body ?? '',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _pushNotificationChannel.id,
          _pushNotificationChannel.name,
          channelDescription: _pushNotificationChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(),
        macOS: const DarwinNotificationDetails(),
      ),
      payload: _notificationPayload(message.data),
    );
  }

  void _applyRemoteCustomerBookingHint(Map<String, dynamic> data) {
    if (_activeRole != UserRole.customer || _customerAccount == null) return;
    final bookingId = data['bookingId']?.toString().trim() ?? '';
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index == -1) return;
    final current = _bookings[index];
    if (current.customerUid != null &&
        current.customerUid != _customerAccount!.id) {
      return;
    }
    final status = data['status']?.toString() ?? '';
    if (status == BookingStatus.completed.name) {
      _applyRemoteCompletionHint(data);
      return;
    }
    final occurredAtMillis = _int(
      data['statusOccurredAtMillis'],
      switch (status) {
        'confirmed' => _int(
          data['acceptedAtMillis'],
          current.acceptedAt?.millisecondsSinceEpoch ?? 0,
        ),
        'rejected' => _int(
          data['rejectedAtMillis'],
          current.rejectedAt?.millisecondsSinceEpoch ?? 0,
        ),
        'cancelled' => _int(
          data['cancelledAtMillis'],
          current.cancelledAt?.millisecondsSinceEpoch ?? 0,
        ),
        _ => 0,
      },
    );
    final occurredAt = occurredAtMillis > 0
        ? DateTime.fromMillisecondsSinceEpoch(occurredAtMillis)
        : DateTime.now();
    if (status == BookingStatus.confirmed.name && current.isInstant) {
      final startMillis = _int(data['startMillis'], 0);
      _bookings[index] = current.copyWith(
        status: BookingStatus.confirmed,
        acceptedAt: occurredAt,
        start: startMillis > 0
            ? DateTime.fromMillisecondsSinceEpoch(startMillis)
            : occurredAt.add(
                Duration(minutes: _int(data['arrivalMinutes'], 15)),
              ),
      );
      notifyListeners();
      return;
    }
    if (status == BookingStatus.rejected.name) {
      _bookings[index] = current.copyWith(
        status: BookingStatus.rejected,
        rejectedAt: occurredAt,
        cancelledBy: data['cancelledBy']?.toString() ?? 'owner',
        cancellationReason:
            data['cancellationReason']?.toString() ?? 'Rejected by salon',
      );
      notifyListeners();
      return;
    }
    if (status == BookingStatus.cancelled.name) {
      _bookings[index] = current.copyWith(
        status: BookingStatus.cancelled,
        cancelledAt: occurredAt,
        cancelledBy: data['cancelledBy']?.toString() ?? '',
        cancellationReason: data['cancellationReason']?.toString() ?? '',
      );
      notifyListeners();
    }
  }

  void _applyRemoteCompletionHint(Map<String, dynamic> data) {
    if (_activeRole != UserRole.customer || _customerAccount == null) return;
    final bookingId = data['bookingId']?.toString().trim() ?? '';
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index == -1) return;
    final current = _bookings[index];
    if (current.customerUid != null &&
        current.customerUid != _customerAccount!.id) {
      return;
    }
    if (current.status == BookingStatus.cancelled ||
        current.status == BookingStatus.rejected) {
      return;
    }
    final completedAtMillis = _int(
      data['completedAtMillis'],
      _int(data['statusOccurredAtMillis'], 0),
    );
    final completedAt = completedAtMillis > 0
        ? DateTime.fromMillisecondsSinceEpoch(completedAtMillis)
        : DateTime.now();
    final payableAmount = _int(
      data['customerPayableAmount'],
      current.customerPayableAmount,
    );
    _bookings[index] = current.copyWith(
      status: BookingStatus.completed,
      completedAt: completedAt,
      customerPayableAmount: payableAmount,
      discountStatus: current.hasDiscount ? 'redeemed' : 'none',
      proinStatus: current.hasProin ? 'redeemed' : 'none',
      proinRedeemedAmount: current.proinAppliedAmount,
      arrivalSharingActive: false,
    );
    notifyListeners();
  }

  bool _ownerBookingCanRing(Booking booking) =>
      booking.isInstant &&
      booking.status == BookingStatus.pending &&
      DateTime.now().isBefore(
        booking.createdAt.add(instantBookingResponseTimeout),
      ) &&
      !_isOwnerBookingAlertSuppressedLocally(booking.id);

  void _syncOwnerBookingAlarm() {
    if (_activeRole != UserRole.owner || _ownerAccount == null) {
      _stopOwnerBookingAlarm(cancelNotifications: !isRestoringSession);
      return;
    }
    if (!bookingsForSalon(ownerSalonId).any(_ownerBookingCanRing)) {
      // The cache may not contain a newly pushed request yet. Its own
      // deadline or an authoritative resolution cancels its notification.
      _stopOwnerBookingAlarm(cancelNotifications: false);
      return;
    }
    if (_ownerBookingAlarmTimer != null) return;
    unawaited(_showOwnerBookingRequestAlarm());
    _ownerBookingAlarmTimer = Timer.periodic(_ownerBookingAlarmInterval, (_) {
      unawaited(_showOwnerBookingRequestAlarm());
    });
  }

  void _suppressOwnerBookingAlertLocally(String bookingId) {
    _suppressedOwnerBookingAlerts[bookingId] = DateTime.now().add(
      _ownerAlertSuppressionDuration,
    );
  }

  @override
  void silenceOwnerBookingAlert(String bookingId) {
    final normalizedId = bookingId.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    _suppressOwnerBookingAlertLocally(normalizedId);
    _stopOwnerBookingAlarm(bookingId: normalizedId);
    unawaited(
      _persistOwnerAlertSuppression(normalizedId).catchError((Object error) {
        _setSyncError(error);
      }),
    );
  }

  bool _isOwnerBookingAlertSuppressedLocally(String bookingId) {
    final expiresAt = _suppressedOwnerBookingAlerts[bookingId];
    if (expiresAt == null) {
      return false;
    }
    if (expiresAt.isAfter(DateTime.now())) {
      return true;
    }
    _suppressedOwnerBookingAlerts.remove(bookingId);
    return false;
  }

  void _stopOwnerBookingAlarm({
    String? bookingId,
    bool cancelNotifications = true,
  }) {
    _ownerBookingAlarmGeneration++;
    _ownerBookingAlarmTimer?.cancel();
    _ownerBookingAlarmTimer = null;
    if (!cancelNotifications) return;
    unawaited(
      _cancelOwnerBookingNotifications(
        _localNotifications,
        bookingId: bookingId,
      ),
    );
  }

  Future<void> _showOwnerBookingRequestAlarm() async {
    if (_ownerBookingAlarmRefreshRunning) return;
    _ownerBookingAlarmRefreshRunning = true;
    final generation = _ownerBookingAlarmGeneration;
    try {
      if (_activeRole != UserRole.owner || _ownerAccount == null) {
        _stopOwnerBookingAlarm();
        return;
      }
      final pending =
          bookingsForSalon(ownerSalonId).where(_ownerBookingCanRing).toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final booking in pending) {
        // A notification-panel decision is made in another isolate. Always
        // consult the durable stop, even while our Firestore cache is pending.
        if (await OwnerBookingAlertState().isStopped(booking.id)) {
          _suppressOwnerBookingAlertLocally(booking.id);
          await _cancelOwnerBookingNotifications(
            _localNotifications,
            bookingId: booking.id,
          );
          continue;
        }
        await _initializeLocalNotifications();
        final shown = await _showUnansweredOwnerBookingAlert(
          notifications: _localNotifications,
          bookingId: booking.id,
          deadline: booking.createdAt.add(instantBookingResponseTimeout),
          title: 'Instant booking request',
          body: '${booking.customerName} is waiting for accept or reject.',
          data: {
            'destination': 'bookings',
            'bookingId': booking.id,
            'isInstant': 'true',
            'createdAtMillis': booking.createdAt.millisecondsSinceEpoch,
            'responseDeadlineMillis': booking.createdAt
                .add(instantBookingResponseTimeout)
                .millisecondsSinceEpoch,
          },
          isStillPending: () =>
              generation == _ownerBookingAlarmGeneration &&
              _activeRole == UserRole.owner &&
              _bookings.any(
                (current) =>
                    current.id == booking.id && _ownerBookingCanRing(current),
              ),
        );
        if (generation != _ownerBookingAlarmGeneration) return;
        if (shown) return;
      }
      if (generation == _ownerBookingAlarmGeneration) {
        _stopOwnerBookingAlarm(cancelNotifications: false);
      }
    } catch (error) {
      _setSyncError(error);
    } finally {
      _ownerBookingAlarmRefreshRunning = false;
    }
  }

  Future<void> _saveMessagingToken(String uid, {String? token}) async {
    try {
      if (_suppressTokenRegistration || auth.currentUser?.uid != uid) {
        return;
      }
      final settings = await messaging.getNotificationSettings();
      if (!canRegisterForPushNotifications(settings.authorizationStatus)) {
        return;
      }
      final messagingToken = token ?? await _getMessagingTokenWhenReady();
      if (messagingToken == null || messagingToken.isEmpty) {
        _scheduleMessagingTokenRetry(uid);
        return;
      }
      if (_suppressTokenRegistration || auth.currentUser?.uid != uid) {
        return;
      }
      // Auth can emit before the locally cached role has been restored. Use
      // the authoritative account role so that startup never removes a real
      // owner's device from the urgent-booking token list.
      final accountSnapshot = await firestore
          .collection('users')
          .doc(uid)
          .get();
      final accountData = accountSnapshot.data() ?? const <String, dynamic>{};
      final authoritativeRole =
          _roleFromName(accountData['role'] as String?) ??
          _roleFromName(accountData['activeRole'] as String?) ??
          _activeRole;
      // A salon owner who signed up as a customer first still has
      // `role: customer` on their profile, and `resolveLaunchRole` makes them
      // an owner locally from the salon they registered. Trusting the stored
      // role alone dropped those owners from the alert list and wrote
      // `ownerNotificationsEnabled: false`, so their booking requests never
      // rang and nothing in the app showed why.
      final isOwnerSession =
          authoritativeRole == UserRole.owner || _activeRole == UserRole.owner;
      if (_suppressTokenRegistration || auth.currentUser?.uid != uid) {
        return;
      }
      await firestore.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([messagingToken]),
        'ownerAlertV4Tokens': isOwnerSession
            ? FieldValue.arrayUnion([messagingToken])
            : FieldValue.arrayRemove([messagingToken]),
        // This build rings on the v4 channel only. Leaving the previous
        // generation's list keeps the server from sending two alerts for the
        // same request.
        'ownerAlertV3Tokens': FieldValue.arrayRemove([messagingToken]),
        'lastFcmToken': messagingToken,
        'notificationsEnabled': true,
        'ownerNotificationsEnabled': isOwnerSession,
        // The server routes owner alerts on this field and only claimLoginRole
        // ever wrote it, so an owner whose profile still said `customer` was
        // refused for good. Promote it here; sign-out clears it again.
        if (isOwnerSession) 'activeRole': UserRole.owner.name,
        'fcmUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _registeredMessagingToken = messagingToken;
      _messagingTokenRetryTimer?.cancel();
      _messagingTokenRetryTimer = null;
      _messagingTokenRetryAttempt = 0;
    } catch (error) {
      _scheduleMessagingTokenRetry(uid);
      _setSyncError(error);
    }
  }

  Future<void> _retryPendingOwnerBookingActions() async {
    if (_disposed ||
        _retryingOwnerBookingDecisions ||
        _activeRole != UserRole.owner ||
        auth.currentUser == null) {
      return;
    }
    _retryingOwnerBookingDecisions = true;
    _ownerBookingDecisionRetryTimer?.cancel();
    try {
      final entries = await OwnerBookingDecisionStore().pending();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in entries) {
        final parts = entry.split('|');
        if (parts.length != 3) continue;
        final bookingId = parts[0].trim();
        if (_notificationDecisionsInFlight.contains(bookingId)) continue;
        final status = parts[1].trim();
        final createdAt = int.tryParse(parts[2]) ?? 0;
        if (bookingId.isEmpty ||
            !<String>{
              BookingStatus.confirmed.name,
              BookingStatus.rejected.name,
            }.contains(status) ||
            now - createdAt > _ownerAlertSuppressionDuration.inMilliseconds) {
          if (bookingId.isNotEmpty) {
            await _clearPendingOwnerBookingAction(bookingId);
          }
          continue;
        }
        try {
          await _callProtectedFunction(
            () => functions.httpsCallable('updateBookingStatus').call<void>({
              'bookingId': bookingId,
              'status': status,
              'cancellationReason': '',
              'actionSource': 'notification_action_retry',
            }),
          );
          await _clearPendingOwnerBookingAction(bookingId);
          await _clearOwnerDecisionFeedback(bookingId);
          await _loadServerBooking(bookingId);
        } on FirebaseFunctionsException catch (error) {
          if (<String>{
            'failed-precondition',
            'not-found',
            'permission-denied',
            'invalid-argument',
          }.contains(error.code)) {
            await _showOwnerDecisionFailure(
              bookingId,
              error,
              initializedNotifications: _localNotifications,
            );
          }
        } catch (_) {
          // Keep transient failures queued for the next automatic retry.
        }
      }
    } catch (error) {
      _setSyncError(error);
    } finally {
      _retryingOwnerBookingDecisions = false;
      if (!_disposed &&
          _activeRole == UserRole.owner &&
          (await OwnerBookingDecisionStore().pending()).isNotEmpty) {
        _ownerBookingDecisionRetryTimer = Timer(const Duration(seconds: 5), () {
          unawaited(_retryPendingOwnerBookingActions());
        });
      }
    }
  }

  void _scheduleMessagingTokenRetry(String uid) {
    if (_suppressTokenRegistration ||
        auth.currentUser?.uid != uid ||
        _messagingTokenRetryTimer?.isActive == true) {
      return;
    }
    const delays = <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(minutes: 1),
    ];
    final delay =
        delays[_messagingTokenRetryAttempt.clamp(0, delays.length - 1)];
    _messagingTokenRetryAttempt += 1;
    _messagingTokenRetryTimer = Timer(delay, () {
      _messagingTokenRetryTimer = null;
      if (!_suppressTokenRegistration && auth.currentUser?.uid == uid) {
        unawaited(_saveMessagingToken(uid));
      }
    });
  }

  Future<String?> _getMessagingTokenWhenReady() async {
    final isApplePlatform =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (isApplePlatform) {
      for (var attempt = 0; attempt < 6; attempt += 1) {
        final apnsToken = await messaging.getAPNSToken();
        if (apnsToken != null && apnsToken.isNotEmpty) {
          break;
        }
        if (attempt == 5) {
          return null;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return messaging.getToken();
  }

  Future<void> _removeMessagingToken(String uid) async {
    _messagingTokenRetryTimer?.cancel();
    _messagingTokenRetryTimer = null;
    _messagingTokenRetryAttempt = 0;
    await performSignOutDeregistration(
      fallbackToken: _registeredMessagingToken,
      readToken: messaging.getToken,
      write: (token) => firestore.collection('users').doc(uid).set(
        signOutDeregistrationFields(
          token: token,
          arrayRemove: FieldValue.arrayRemove,
          delete: FieldValue.delete(),
          serverTimestamp: FieldValue.serverTimestamp(),
        ),
        SetOptions(merge: true),
      ),
      deleteToken: messaging.deleteToken,
      onWriteError: _setSyncError,
      onDegraded: (error) {
        // Expected on an iPhone with no APNs token yet. The account flags
        // written above are the stop that matters.
        if (kDebugMode) {
          debugPrint('Sign-out push cleanup degraded: $error');
        }
      },
    );
    _registeredMessagingToken = null;
  }

  Future<void> _sendBookingPush(
    String bookingId, {
    required String event,
  }) async {
    try {
      await functions.httpsCallable('sendBookingPush').call<void>({
        'bookingId': bookingId,
        'event': event,
      });
    } catch (error) {
      _setSyncError(error);
    }
  }

  Future<void> _sendJoinRequestPush(
    String requestId, {
    required String event,
  }) async {
    try {
      await functions.httpsCallable('sendJoinRequestPush').call<void>({
        'requestId': requestId,
        'event': event,
      });
    } catch (error) {
      _setSyncError(error);
    }
  }

  void _connectPrivateFirestore(User? user) {
    final startupIsRestoringThisUser =
        _isRestoringSession &&
        (_startupRestoreUid == null ||
            user == null ||
            user.uid == _startupRestoreUid);
    if (!startupIsRestoringThisUser) {
      _accountRestoreGeneration += 1;
    }
    for (final subscription in _privateSubscriptions) {
      unawaited(subscription.cancel());
    }
    _privateSubscriptions.clear();
    _bookingSnapshots.clear();
    _bookings.clear();
    _joinRequests.clear();
    _salonFeedback.clear();
    _customerSalonRatings.clear();
    _customerProinWallet = const ProinWalletSummary();
    _salonProinWallets.clear();
    _customerProinActivity.clear();
    _stopOwnerBookingAlarm(
      cancelNotifications: user == null && !startupIsRestoringThisUser,
    );
    notifyListeners();

    if (user == null) {
      _suppressTokenRegistration = true;
      _activeRole = null;
      _customerAccount = null;
      _ownerAccount = null;
      _ownerDraftServices.clear();
      _barberAccount = null;
      _currentBarberId = null;
      _currentJoinRequestId = null;
      unawaited(_persistActiveRole(null));
      notifyListeners();
      return;
    }

    _suppressTokenRegistration = false;
    if (_pendingFirebaseLoginRole == null && !startupIsRestoringThisUser) {
      unawaited(_restoreAccountForUser(user));
    }
    _listenToBookings('customer', 'customerUid', user.uid);
    _listenToBookings('owner', 'ownerUid', user.uid);
    _privateSubscriptions.add(
      firestore.collection('users').doc(user.uid).snapshots().listen((doc) {
        final data = doc.data();
        if (data == null) {
          return;
        }
        final account = _accountFromFirebaseUser(user, data);
        final role = _roleFromName(data['role'] as String?);
        _referralOnboardingRequired =
            data['referralOnboardingCompleted'] == false;
        if (role == UserRole.customer && _activeRole == UserRole.customer) {
          _customerAccount = account;
        } else if (role == UserRole.owner && _activeRole == UserRole.owner) {
          _ownerAccount = account;
          unawaited(_saveMessagingToken(user.uid));
          _syncOwnerBookingAlarm();
        }
        notifyListeners();
      }),
    );
    _privateSubscriptions.add(
      firestore
          .collection('salonFeedback')
          .where('customerUid', isEqualTo: user.uid)
          .snapshots()
          .listen((snapshot) {
            _salonFeedback
              ..clear()
              ..addAll(snapshot.docs.map(_salonFeedbackFromFirestore))
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            notifyListeners();
          }),
    );
    _privateSubscriptions.add(
      firestore
          .collection('customerRatings')
          .where('customerUid', isEqualTo: user.uid)
          .snapshots()
          .listen((snapshot) {
            _customerSalonRatings
              ..clear()
              ..addAll(snapshot.docs.map(_customerRatingFromFirestore))
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            notifyListeners();
          }),
    );
  }

  void _listenToBookings(String key, String field, String uid) {
    _privateSubscriptions.add(
      firestore
          .collection('bookings')
          .where(field, isEqualTo: uid)
          .snapshots()
          .listen((snapshot) {
            _bookingSnapshots[key] = {
              for (final doc in snapshot.docs)
                doc.id: _bookingFromFirestore(doc),
            };
            final merged = <String, Booking>{};
            for (final items in _bookingSnapshots.values) {
              merged.addAll(items);
            }
            if (key == 'owner') {
              for (final booking in _bookingSnapshots[key]!.values) {
                if (booking.isInstant &&
                    booking.status != BookingStatus.pending &&
                    DateTime.now().isBefore(
                      booking.createdAt.add(_ownerAlertSuppressionDuration),
                    ) &&
                    !_isOwnerBookingAlertSuppressedLocally(booking.id)) {
                  silenceOwnerBookingAlert(booking.id);
                }
              }
            }
            final reconciled = reconcileOptimisticBookings(
              serverBookings: merged,
              optimistic: _optimisticBookingUpdates,
            );
            _bookings
              ..clear()
              ..addAll(reconciled.values);
            _syncOwnerBookingAlarm();
            notifyListeners();
          }),
    );
  }

  Future<void> _restoreAccountForUser(User user) async {
    final restoreGeneration = ++_accountRestoreGeneration;
    try {
      final accountFuture = firestore.collection('users').doc(user.uid).get();
      final ownerSalonsFuture = firestore
          .collection('salons')
          .where('ownerUid', isEqualTo: user.uid)
          .limit(1)
          .get();
      final (doc, ownerSalons) = await (accountFuture, ownerSalonsFuture).wait;
      final data = doc.data() ?? {};
      _referralOnboardingRequired =
          data['referralOnboardingCompleted'] == false;
      final roles = _rolesFromData(data['roles']);
      final storedRole = _roleFromName(data['activeRole'] as String?);
      final authoritativeRole = _roleFromName(data['role'] as String?);
      final role = resolveLaunchRole(
        hasRegisteredSalon: ownerSalons.docs.isNotEmpty,
        roles: roles,
        localRole: _activeRole,
        remoteRole: storedRole,
        authoritativeRole: authoritativeRole,
      );
      final account = _accountFromFirebaseUser(user, data);
      if (restoreGeneration != _accountRestoreGeneration ||
          auth.currentUser?.uid != user.uid) {
        return;
      }
      if (authoritativeRole == null) {
        await _claimLoginRole(account, role: role);
      }
      if (role == UserRole.owner && ownerSalons.docs.isNotEmpty) {
        final salonPhone = normalizePhone(
          (ownerSalons.docs.first.data()['phone'] as String?) ?? '',
        );
        if (RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(salonPhone)) {
          unawaited(
            _claimOwnerProfilePhone(salonPhone).catchError((Object error) {
              _setSyncError(error);
            }),
          );
        }
      }
      if (restoreGeneration != _accountRestoreGeneration ||
          auth.currentUser?.uid != user.uid) {
        return;
      }
      _activateRole(role, account);
      if (role == UserRole.customer) {
        unawaited(_refreshCustomerProinWalletInBackground());
      } else if (role == UserRole.owner) {
        unawaited(_retryPendingOwnerBookingActions());
      }
      // APNs can take several seconds to issue a token on a cold iPhone boot.
      // Token registration is not required to display the signed-in home.
      unawaited(_saveMessagingToken(user.uid));
      _syncOwnerBookingAlarm();
    } on CustomerNameRequiredException {
      if (restoreGeneration == _accountRestoreGeneration &&
          auth.currentUser?.uid == user.uid) {
        await auth.signOut();
      }
    } catch (error) {
      if (restoreGeneration == _accountRestoreGeneration &&
          auth.currentUser?.uid == user.uid) {
        _setSyncError(error);
      }
    }
  }

  UserAccount _accountFromFirebaseUser(User user, Map<String, dynamic> data) {
    final contact = (data['contact'] as String?)?.trim().isNotEmpty == true
        ? (data['contact'] as String).trim()
        : (user.phoneNumber?.trim().isNotEmpty == true
              ? normalizePhone(user.phoneNumber!)
              : (user.email ?? ''));
    final provider = _providerFromData(data['provider'], user);
    return UserAccount(
      id: user.uid,
      name: (data['name'] as String?)?.trim().isNotEmpty == true
          ? (data['name'] as String).trim()
          : (user.displayName?.trim().isNotEmpty == true
                ? user.displayName!.trim()
                : 'Pritze user'),
      contact: provider == LoginProvider.phone
          ? normalizePhone(contact)
          : contact,
      provider: provider,
      photoUrl: (data['photoUrl'] as String?)?.trim() ?? '',
      gender: (data['gender'] as String?)?.trim() ?? '',
      birthDate: (data['birthDate'] as String?)?.trim() ?? '',
      preferredStyles: _stringList(data['preferredStyles']),
      stylePhotoUrls: _stringList(data['stylePhotoUrls']),
      salonRating: _double(data['salonRating'], 0),
      salonRatingCount: _int(data['salonRatingCount'], 0),
    );
  }

  List<UserRole> _rolesFromData(Object? value) {
    return (value as List<dynamic>? ?? [])
        .whereType<String>()
        .map(_roleFromName)
        .whereType<UserRole>()
        .toList(growable: false);
  }

  LoginProvider _providerFromData(Object? value, User user) {
    final provider = (value as String?)?.toLowerCase();
    if (provider == 'email') {
      return LoginProvider.email;
    }
    if (provider == 'phone' || user.phoneNumber != null) {
      return LoginProvider.phone;
    }
    return LoginProvider.google;
  }

  Future<T> _runFirebaseSave<T>(Future<T> Function() operation) async {
    _lastSyncError = null;
    _setSaving(true);
    try {
      return await operation();
    } catch (error) {
      _setSyncError(error);
      rethrow;
    } finally {
      _setSaving(false);
    }
  }

  Future<Map<String, dynamic>> _callOwnerMutation(
    String functionName,
    Map<String, Object?> data,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        final result = await _callProtectedFunction(
          () => functions
              .httpsCallable(functionName)
              .call<Map<String, dynamic>>(data),
        ).timeout(const Duration(seconds: 15));
        return result.data;
      } catch (error) {
        lastError = error;
        final retryable =
            error is TimeoutException ||
            (error is FirebaseFunctionsException &&
                isRetryableCallableErrorCode(error.code));
        if (!retryable || attempt > 0) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    throw lastError ?? StateError('The salon update could not be completed.');
  }

  Future<void> _refreshCallableCredentials({bool force = false}) async {
    final now = DateTime.now();
    final last = _lastCallableCredentialRefreshAt;
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(minutes: 2)) {
      return;
    }
    _lastCallableCredentialRefreshAt = now;

    final user = auth.currentUser;
    if (user != null) {
      try {
        // Use Firebase's cached valid token on the normal path. A forced
        // network refresh is reserved for an actual unauthenticated retry.
        await user.getIdToken(force);
      } catch (error) {
        _lastCallableCredentialRefreshAt = null;
        if (kDebugMode) {
          debugPrint('Firebase Auth token refresh failed: $error');
        }
        rethrow;
      }
    }

    try {
      await FirebaseAppCheck.instance.getToken(force);
    } catch (error) {
      _lastCallableCredentialRefreshAt = null;
      if (kDebugMode) {
        debugPrint('Firebase App Check token refresh failed: $error');
      }
    }
  }

  Future<T> _callProtectedFunction<T>(Future<T> Function() operation) async {
    await _refreshCallableCredentials();
    try {
      return await operation();
    } catch (error) {
      if (_isCallableUnauthenticated(error)) {
        await _refreshCallableCredentials(force: true);
        return operation();
      }
      rethrow;
    }
  }

  bool _isCallableUnauthenticated(Object error) {
    return error is FirebaseFunctionsException &&
        error.code.toLowerCase() == 'unauthenticated';
  }

  Future<T> _withPendingLoginRole<T>(
    UserRole role,
    Future<T> Function() operation,
  ) async {
    _pendingFirebaseLoginRole = role;
    try {
      return await operation();
    } finally {
      if (_pendingFirebaseLoginRole == role) {
        _pendingFirebaseLoginRole = null;
      }
    }
  }

  Future<UserAccount> _signInWithGoogle({
    required String fallbackName,
    required String fallbackEmail,
  }) async {
    if (!_googleInitialized) {
      await GoogleSignIn.instance.initialize(
        serverClientId:
            '3474382418-g4avkshhj6tg4erhgul1r3m810j78rku.apps.googleusercontent.com',
      );
      _googleInitialized = true;
    }
    final GoogleSignInAccount googleAccount;
    try {
      googleAccount = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (error) {
      final message = error.description?.toLowerCase() ?? '';
      if (message.contains('no credential')) {
        throw StateError(
          'No Google account is available on this device. Add a Google account in device Settings, then try again.',
        );
      }
      rethrow;
    }
    final googleAuth = googleAccount.authentication;
    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );
    final result = await auth.signInWithCredential(credential);
    final user = result.user;
    return UserAccount(
      id: user?.uid ?? googleAccount.id,
      name: user?.displayName?.trim().isNotEmpty == true
          ? user!.displayName!.trim()
          : (googleAccount.displayName?.trim().isNotEmpty == true
                ? googleAccount.displayName!.trim()
                : (fallbackName.trim().isNotEmpty
                      ? fallbackName.trim()
                      : googleAccount.email.split('@').first)),
      contact: user?.email ?? googleAccount.email,
      provider: LoginProvider.google,
    );
  }

  Future<UserAccount> _signInWithEmailOtp({
    required String fallbackName,
    required String email,
    String? emailOtp,
  }) async {
    final trimmedEmail = email.trim();
    final trimmedOtp = emailOtp?.trim() ?? '';
    if (trimmedOtp.isEmpty) {
      throw StateError('Enter the 6-digit email OTP.');
    }
    final response = await functions.httpsCallable('verifyEmailOtp').call({
      'email': trimmedEmail,
      'code': trimmedOtp,
    });
    final data = Map<String, dynamic>.from(response.data as Map);
    final customToken = data['customToken'] as String?;
    if (customToken == null || customToken.isEmpty) {
      throw StateError('Email verification failed.');
    }
    final result = await auth.signInWithCustomToken(customToken);
    final user = result.user;
    return UserAccount(
      id: user?.uid ?? trimmedEmail,
      name: user?.displayName?.trim().isNotEmpty == true
          ? user!.displayName!.trim()
          : (fallbackName.trim().isNotEmpty
                ? fallbackName.trim()
                : trimmedEmail.split('@').first),
      contact: user?.email ?? trimmedEmail,
      provider: LoginProvider.email,
    );
  }

  Future<UserAccount> _signInWithPhoneOtp({
    required String phone,
    required String verificationId,
    required String smsCode,
    String fallbackName = '',
  }) async {
    final normalizedPhone = normalizePhone(phone);
    User? user;
    if (verificationId.isEmpty) {
      final currentGeneration = _phoneOtpGenerations[normalizedPhone];
      final credential = _autoVerifiedPhoneCredentials[normalizedPhone];
      if (currentGeneration == null ||
          _autoVerifiedPhoneGenerations[normalizedPhone] != currentGeneration ||
          credential == null) {
        throw StateError(
          'Phone verification expired. Request a new OTP and try again.',
        );
      }
      final result = await auth.signInWithCredential(credential);
      user = result.user;
    } else {
      final trimmedCode = smsCode.trim();
      if (!RegExp(r'^\d{6}$').hasMatch(trimmedCode)) {
        throw StateError('Enter the 6-digit OTP sent to your phone.');
      }
      if (_currentPhoneVerificationIds[normalizedPhone] !=
          verificationId.trim()) {
        throw StateError(
          'That OTP was replaced by a newer code. Enter the latest OTP.',
        );
      }
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId.trim(),
        smsCode: trimmedCode,
      );
      final result = await auth.signInWithCredential(credential);
      user = result.user;
    }
    _invalidatePhoneOtp(normalizedPhone);
    final requestedName = fallbackName.trim();
    if (requestedName.isNotEmpty && user != null) {
      unawaited(
        user.updateDisplayName(requestedName).catchError((Object error) {
          if (kDebugMode) {
            debugPrint('Could not update Firebase display name: $error');
          }
        }),
      );
    }
    return UserAccount(
      id: user?.uid ?? normalizedPhone,
      name: requestedName.isNotEmpty
          ? requestedName
          : user?.displayName?.trim().isNotEmpty == true
          ? user!.displayName!.trim()
          : 'Phone user',
      contact: user?.phoneNumber ?? normalizedPhone,
      provider: LoginProvider.phone,
    );
  }

  Future<UserAccount> _completeRoleClaim(
    UserAccount account, {
    required UserRole role,
    required String? previousUid,
    bool usedGoogle = false,
    String? claimedPhone,
  }) async {
    late final UserAccount resolvedAccount;
    try {
      final storedName = await _claimLoginRole(
        account,
        role: role,
        claimedPhone: claimedPhone,
      );
      resolvedAccount = storedName.isNotEmpty && storedName != account.name
          ? account.copyWith(name: storedName)
          : account;
    } catch (error) {
      if (error is CustomerNameRequiredException) {
        rethrow;
      }
      final signedInUid = auth.currentUser?.uid;
      if (previousUid == null || signedInUid != previousUid) {
        await auth.signOut();
        if (usedGoogle && _googleInitialized) {
          await GoogleSignIn.instance.signOut();
        }
      }
      _accountRestoreGeneration += 1;
      rethrow;
    }

    _accountRestoreGeneration += 1;
    _activateRole(role, resolvedAccount);
    if (role == UserRole.customer) {
      unawaited(_refreshCustomerProinWalletInBackground());
    }
    // claimLoginRole already writes the authoritative profile. Push token
    // registration is independent and should not add several extra network
    // round trips to the login button.
    unawaited(_saveMessagingToken(resolvedAccount.id));
    return resolvedAccount;
  }

  Future<void> _refreshCustomerProinWalletInBackground() async {
    try {
      await refreshCustomerProinWallet();
    } catch (error) {
      _setSyncError(error);
    }
  }

  Future<String> _claimLoginRole(
    UserAccount account, {
    required UserRole role,
    String? claimedPhone,
  }) async {
    final submittedName =
        role == UserRole.customer &&
            account.provider == LoginProvider.phone &&
            (account.name == 'Phone user' || account.name == 'Pritze user')
        ? ''
        : account.name;
    final response = await functions
        .httpsCallable('claimLoginRole')
        .call<Map<String, dynamic>>({
          'role': role.name,
          'name': submittedName,
          'provider': account.provider.label.toLowerCase(),
          'phone': ?claimedPhone,
        });
    if (response.data['requiresName'] == true) {
      throw const CustomerNameRequiredException();
    }
    _referralOnboardingRequired =
        response.data['requiresReferralOnboarding'] == true;
    return response.data['name']?.toString().trim() ?? '';
  }

  Future<void> _claimOwnerProfilePhone(String phone) async {
    await functions
        .httpsCallable('claimOwnerProfilePhone')
        .call<Map<String, dynamic>>({'phone': phone});
  }

  void _invalidatePhoneOtp(String normalizedPhone) {
    _phoneOtpGenerations[normalizedPhone] =
        (_phoneOtpGenerations[normalizedPhone] ?? 0) + 1;
    _autoVerifiedPhoneGenerations.remove(normalizedPhone);
    _autoVerifiedPhoneCredentials.remove(normalizedPhone);
    _currentPhoneVerificationIds.remove(normalizedPhone);
    _phoneResendTokens.remove(normalizedPhone);
  }

  Future<void> _saveOwnerSalonServices() async {
    final salon = ownerSalon;
    await _callOwnerMutation('saveOwnerSalonServices', {
      'salonId': salon.id,
      'services': salon.services.map(_serviceToMap).toList(),
    });
  }

  Future<void> _saveOwnerSalonProfileToCloud(Salon salon) async {
    await _callOwnerMutation('saveOwnerSalonProfile', {
      'salonId': salon.id,
      'name': salon.name,
      'ownerName': salon.ownerName,
      'address': salon.address,
      'directionsUrl': salon.directionsUrl,
      'phone': salon.phone,
      'email': salon.email,
      'logoUrl': salon.logoUrl,
      'photoUrls': salon.photoUrls,
      'openTime': salon.openTime,
      'closeTime': salon.closeTime,
      'services': salon.services.map(_serviceToMap).toList(),
    });
  }

  Future<void> _saveOwnerBarber(Barber barber) async {
    await _callOwnerMutation('saveOwnerBarber', {
      'barberId': barber.id,
      ...barberToMap(barber),
    });
  }

  Future<void> _setBarber(Barber barber) {
    // Only this direct write may carry a sentinel. `saveOwnerBarber` sends
    // the same map through a callable, which JSON-encodes its payload and
    // rejects a FieldValue with "Invalid argument: Instance of 'FieldValue'"
    // before the request ever leaves the device. The server stamps its own
    // updatedAt, so the callable does not need one.
    final data = barberToMap(barber);
    data['updatedAt'] = FieldValue.serverTimestamp();
    final uid = auth.currentUser?.uid;
    if (uid != null) {
      data['ownerUid'] = uid;
    }
    return firestore.collection('barbers').doc(barber.id).set(data);
  }

  Future<void> _setJoinRequest(JoinRequest request) async {
    final salon = await firestore
        .collection('salons')
        .doc(request.salonId)
        .get();
    await firestore
        .collection('joinRequests')
        .doc(request.id)
        .set(
          _joinRequestToFirestore(
            request,
            requesterUid: request.requesterUid ?? auth.currentUser?.uid,
            ownerUid: salon.data()?['ownerUid'] as String?,
          ),
        );
  }
}

Map<String, Object?> _serviceToMap(SalonService service) {
  return {
    'id': service.id,
    'name': service.name,
    'category': service.category,
    'price': service.price,
    'durationMinutes': service.durationMinutes,
    'isAvailable': service.isAvailable,
    'instantBookingEnabled': service.instantBookingEnabled,
    'isCustom': service.isCustom,
  };
}

/// Must stay JSON-encodable: this is sent as a callable payload, not only
/// written to Firestore.
@visibleForTesting
Map<String, Object?> barberToMap(Barber barber) {
  return {
    'uid': barber.uid,
    'salonId': barber.salonId,
    'name': barber.name,
    'phone': barber.phone,
    'email': barber.email,
    'speciality': barber.speciality,
    'experienceYears': barber.experienceYears,
    'resumeSummary': barber.resumeSummary,
    'serviceIds': barber.serviceIds,
    'isActive': barber.isActive,
  };
}

Map<String, Object?> _bookingToFirestore(
  Booking booking, {
  String? customerUid,
  String? ownerUid,
  String? barberUid,
}) {
  return {
    'salonId': booking.salonId,
    'serviceId': booking.serviceId,
    'serviceIds': booking.resolvedServiceIds,
    'barberId': booking.barberId,
    'customerUid': customerUid,
    'ownerUid': ownerUid,
    'barberUid': barberUid,
    'customerName': booking.customerName,
    'customerPhone': booking.customerPhone,
    'start': Timestamp.fromDate(booking.start),
    'durationMinutes': booking.durationMinutes,
    'serviceName': booking.serviceName,
    'servicePrice': booking.servicePrice,
    'servicePriceBreakdown': booking.servicePriceBreakdown,
    'serviceNameBreakdown': booking.serviceNameBreakdown,
    'extraServiceRequest': booking.extraServiceRequest?.toMap(),
    'bookingFee': booking.bookingFee,
    'paymentRequired': booking.paymentRequired,
    'paymentStatus': booking.paymentStatus,
    'discountCampaignId': booking.discountCampaignId,
    'discountCampaignName': booking.discountCampaignName,
    'discountPercent': booking.discountPercent,
    'discountBaseAmount': booking.discountBaseAmount,
    'discountAmount': booking.discountAmount,
    'customerPayableAmount': booking.customerPayableAmount,
    'pritzePayoutAmount': booking.pritzePayoutAmount,
    'salonTotalEarning': booking.salonTotalEarning,
    'cashbackProinAmount': booking.cashbackProinAmount,
    'cashbackValidityDays': booking.cashbackValidityDays,
    'discountCashbackStatus': booking.discountCashbackStatus,
    'discountStatus': booking.discountStatus,
    'customerPayableBeforeProin': booking.customerPayableBeforeProin,
    'proinStatus': booking.proinStatus,
    'proinRequestedAmount': booking.proinRequestedAmount,
    'proinReservedAmount': booking.proinReservedAmount,
    'proinRedeemedAmount': booking.proinRedeemedAmount,
    'proinReleasedAmount': booking.proinReleasedAmount,
    'proinExpiredOnReleaseAmount': booking.proinExpiredOnReleaseAmount,
    'proinReimbursementStatus': booking.proinReimbursementStatus,
    'status': _bookingStatusName(booking.status),
    'createdAt': Timestamp.fromDate(booking.createdAt),
    'isInstant': booking.isInstant,
    'acceptedAt': booking.acceptedAt == null
        ? null
        : Timestamp.fromDate(booking.acceptedAt!),
    'startedAt': booking.startedAt == null
        ? null
        : Timestamp.fromDate(booking.startedAt!),
    'completedAt': booking.completedAt == null
        ? null
        : Timestamp.fromDate(booking.completedAt!),
    'cancelledAt': booking.cancelledAt == null
        ? null
        : Timestamp.fromDate(booking.cancelledAt!),
    'rejectedAt': booking.rejectedAt == null
        ? null
        : Timestamp.fromDate(booking.rejectedAt!),
    'customerArrivalReminderSentAt':
        booking.customerArrivalReminderSentAt == null
        ? null
        : Timestamp.fromDate(booking.customerArrivalReminderSentAt!),
    'ownerArrivalReminderSentAt': booking.ownerArrivalReminderSentAt == null
        ? null
        : Timestamp.fromDate(booking.ownerArrivalReminderSentAt!),
    'arrivalMinutes': booking.customerArrivalMinutes,
    'salonArrivalMinutes': booking.salonArrivalMinutes,
    'cancellationReason': booking.cancellationReason,
    'cancelledBy': booking.cancelledBy,
    'updatedAt': FieldValue.serverTimestamp(),
  };
}

Map<String, Object?> _bookingStatusUpdateToFirestore(Booking booking) {
  return {
    'status': _bookingStatusName(booking.status),
    'start': Timestamp.fromDate(booking.start),
    'acceptedAt': booking.acceptedAt == null
        ? null
        : Timestamp.fromDate(booking.acceptedAt!),
    'startedAt': booking.startedAt == null
        ? null
        : Timestamp.fromDate(booking.startedAt!),
    'completedAt': booking.completedAt == null
        ? null
        : Timestamp.fromDate(booking.completedAt!),
    'cancelledAt': booking.cancelledAt == null
        ? null
        : Timestamp.fromDate(booking.cancelledAt!),
    'rejectedAt': booking.rejectedAt == null
        ? null
        : Timestamp.fromDate(booking.rejectedAt!),
    'cancellationReason': booking.cancellationReason,
    'cancelledBy': booking.cancelledBy,
    'discountStatus': booking.discountStatus,
    'proinStatus': booking.proinStatus,
    'proinReservedAmount': booking.proinReservedAmount,
    'proinRedeemedAmount': booking.proinRedeemedAmount,
    'proinReleasedAmount': booking.proinReleasedAmount,
    'proinExpiredOnReleaseAmount': booking.proinExpiredOnReleaseAmount,
    'proinReimbursementStatus': booking.proinReimbursementStatus,
    'updatedAt': FieldValue.serverTimestamp(),
  };
}

Map<String, Object?> _joinRequestToFirestore(
  JoinRequest request, {
  String? requesterUid,
  String? ownerUid,
}) {
  return {
    'salonId': request.salonId,
    'requesterUid': request.requesterUid ?? requesterUid,
    'ownerUid': ownerUid,
    'barberName': request.barberName,
    'barberPhone': request.barberPhone,
    'barberEmail': request.barberEmail,
    'speciality': request.speciality,
    'experienceYears': request.experienceYears,
    'resumeSummary': request.resumeSummary,
    'serviceIds': request.serviceIds,
    'status': _joinRequestStatusName(request.status),
    'requestedAt': Timestamp.fromDate(request.requestedAt),
  };
}

/// Parses what it can and drops what it cannot. A collection-wide listener
/// must never be left empty because one document has an unexpected shape.
@visibleForTesting
List<T> parseDocuments<T, D>(
  Iterable<D> docs,
  T Function(D) parse, {
  void Function(Object error)? onSkipped,
}) {
  final parsed = <T>[];
  for (final doc in docs) {
    try {
      parsed.add(parse(doc));
    } catch (error) {
      onSkipped?.call(error);
    }
  }
  return parsed;
}

Salon _salonFromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
  final data = doc.data() ?? {};
  final rawServices = data['services'];
  final services = canonicalSalonServices(
    (rawServices is List ? rawServices : const [])
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => _serviceFromMap(Map<String, dynamic>.from(item)))
        .toList(),
  );
  return Salon(
    id: doc.id,
    name: _string(data['name'], ''),
    ownerName: _string(data['ownerName'], ''),
    address: _string(data['address'], ''),
    directionsUrl: _string(data['directionsUrl'], ''),
    phone: _string(data['phone'], ''),
    email: _string(data['email'], ''),
    logoUrl: _string(data['logoUrl'], ''),
    photoUrls: _stringList(data['photoUrls']),
    distanceLabel: _string(data['distanceLabel'], 'Nearby'),
    rating: _double(data['rating'], 4.5),
    reviewCount: _int(data['reviewCount'], 0),
    openTime: _string(data['openTime'], ''),
    closeTime: _string(data['closeTime'], ''),
    isOpen: data['isOpen'] == true,
    instantBookingsEnabled: data['instantBookingsEnabled'] != false,
    instantBookingsPausedDate: _string(data['instantBookingsPausedDate'], ''),
    approvalStatus: _salonApprovalStatus(data['approvalStatus']),
    services: services,
  );
}

String _salonApprovalStatus(Object? value) {
  switch (value?.toString().trim()) {
    case 'pending':
      return 'pending';
    case 'rejected':
      return 'rejected';
    case 'approved':
    default:
      // Salons registered before the approval system remain live.
      return 'approved';
  }
}

SalonService _serviceFromMap(Map<String, dynamic> data) {
  final name = _string(data['name'], 'Service');
  return SalonService(
    id: _string(data['id'], 'service-${DateTime.now().microsecondsSinceEpoch}'),
    name: name,
    category: _string(data['category'], 'Grooming'),
    price: _int(data['price'], 0),
    durationMinutes: _int(data['durationMinutes'], 30),
    isAvailable: data['isAvailable'] != false,
    instantBookingEnabled: data['instantBookingEnabled'] != false,
    isCustom: inferServiceIsCustom(name, data['isCustom']),
  );
}

Barber _barberFromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
  final data = doc.data() ?? {};
  return Barber(
    id: doc.id,
    uid: data['uid'] is String ? data['uid'] as String : null,
    salonId: _string(data['salonId'], ''),
    name: _string(data['name'], 'Barber'),
    phone: _string(data['phone'], ''),
    email: _string(data['email'], ''),
    speciality: _string(data['speciality'], 'Grooming expert'),
    experienceYears: _int(data['experienceYears'], 1),
    resumeSummary: _string(
      data['resumeSummary'],
      'Customer-first grooming professional.',
    ),
    serviceIds: _stringList(data['serviceIds']),
    isActive: data['isActive'] != false,
  );
}

Booking _bookingFromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) =>
    _bookingFromData(doc.id, doc.data() ?? const <String, dynamic>{});

Booking _bookingFromData(String id, Map<String, dynamic> data) {
  return Booking(
    id: id,
    customerUid: data['customerUid'] as String?,
    salonId: _string(data['salonId'], ''),
    serviceId: _string(data['serviceId'], ''),
    serviceIds: _stringList(data['serviceIds']),
    barberId: _string(data['barberId'], ''),
    customerName: _string(data['customerName'], 'Customer'),
    customerPhone: _string(data['customerPhone'], ''),
    start: _date(data['start']),
    durationMinutes: _int(data['durationMinutes'], 30),
    serviceName: _string(data['serviceName'], ''),
    servicePrice: _int(data['servicePrice'], 0),
    servicePriceBreakdown: _intMap(data['servicePriceBreakdown']),
    serviceNameBreakdown: data['serviceNameBreakdown'] is Map
        ? Map<String, String>.from(data['serviceNameBreakdown'] as Map)
        : const {},
    extraServiceRequest: data['extraServiceRequest'] is Map
        ? BookingExtraServiceRequest.fromMap(data['extraServiceRequest'] as Map)
        : null,
    bookingFee: _int(data['bookingFee'], _zeroBookingFee),
    paymentRequired: data['paymentRequired'] == true,
    paymentStatus: _string(data['paymentStatus'], _zeroBookingFeeStatus),
    discountCampaignId: _string(data['discountCampaignId'], ''),
    discountCampaignName: _string(data['discountCampaignName'], ''),
    discountPercent: _double(data['discountPercent'], 0),
    discountBaseAmount: _int(data['discountBaseAmount'], 0),
    discountAmount: _int(data['discountAmount'], 0),
    customerPayableAmount: _int(
      data['customerPayableAmount'],
      _int(data['servicePrice'], 0),
    ),
    pritzePayoutAmount: _int(data['pritzePayoutAmount'], 0),
    salonTotalEarning: _int(
      data['salonTotalEarning'],
      _int(data['servicePrice'], 0),
    ),
    cashbackProinAmount: _int(data['cashbackProinAmount'], 0),
    cashbackValidityDays: _int(data['cashbackValidityDays'], 0),
    discountCashbackStatus: _string(data['discountCashbackStatus'], 'none'),
    discountStatus: _string(data['discountStatus'], 'none'),
    customerPayableBeforeProin: _int(
      data['customerPayableBeforeProin'],
      _int(data['customerPayableAmount'], _int(data['servicePrice'], 0)),
    ),
    proinStatus: _string(data['proinStatus'], 'none'),
    proinRequestedAmount: _int(data['proinRequestedAmount'], 0),
    proinReservedAmount: _int(data['proinReservedAmount'], 0),
    proinRedeemedAmount: _int(data['proinRedeemedAmount'], 0),
    proinReleasedAmount: _int(data['proinReleasedAmount'], 0),
    proinExpiredOnReleaseAmount: _int(data['proinExpiredOnReleaseAmount'], 0),
    proinReimbursementStatus: _string(data['proinReimbursementStatus'], 'none'),
    status: _bookingStatusFromName(_string(data['status'], 'pending')),
    createdAt: _date(data['createdAt']),
    isInstant: data['isInstant'] == true,
    acceptedAt: _nullableDate(data['acceptedAt']),
    startedAt: _nullableDate(data['startedAt']),
    completedAt: _nullableDate(data['completedAt']),
    cancelledAt: _nullableDate(data['cancelledAt']),
    rejectedAt: _nullableDate(data['rejectedAt']),
    customerArrivalReminderSentAt: _nullableDate(
      data['customerArrivalReminderSentAt'],
    ),
    ownerArrivalReminderSentAt: _nullableDate(
      data['ownerArrivalReminderSentAt'],
    ),
    arrivalMinutes: _int(
      data['arrivalMinutes'],
      data['isInstant'] == true ? 15 : 0,
    ),
    cancellationReason: _string(data['cancellationReason'], ''),
    cancelledBy: _string(data['cancelledBy'], ''),
    arrivalStatus: _customerArrivalStatusFromName(
      _string(data['arrivalStatus'], 'notStarted'),
    ),
    arrivalStatusUpdatedAt: _nullableDate(data['arrivalStatusUpdatedAt']),
    arrivalSharingActive: data['arrivalSharingActive'] == true,
    arrivalSharingExpiresAt: _nullableDate(data['arrivalSharingExpiresAt']),
  );
}

SalonFeedback _salonFeedbackFromFirestore(
  DocumentSnapshot<Map<String, dynamic>> doc,
) {
  final data = doc.data() ?? const <String, dynamic>{};
  return SalonFeedback(
    bookingId: _string(data['bookingId'], doc.id),
    customerUid: _string(data['customerUid'], ''),
    salonId: _string(data['salonId'], ''),
    salonName: _string(data['salonName'], 'Salon'),
    rating: _int(data['rating'], 0),
    note: _string(data['note'], ''),
    createdAt:
        _nullableDate(data['updatedAt'] ?? data['createdAt']) ?? DateTime.now(),
  );
}

CustomerSalonRating _customerRatingFromFirestore(
  DocumentSnapshot<Map<String, dynamic>> doc,
) {
  final data = doc.data() ?? const <String, dynamic>{};
  return CustomerSalonRating(
    bookingId: _string(data['bookingId'], doc.id),
    customerUid: _string(data['customerUid'], ''),
    salonId: _string(data['salonId'], ''),
    salonName: _string(data['salonName'], 'Salon'),
    rating: _int(data['rating'], 0),
    note: _string(data['note'], ''),
    createdAt:
        _nullableDate(data['updatedAt'] ?? data['createdAt']) ?? DateTime.now(),
  );
}

String _slotKeyFromLock(DocumentSnapshot<Map<String, dynamic>> doc) {
  final data = doc.data() ?? {};
  return _slotKey(_string(data['barberId'], ''), _date(data['start']));
}

String _bookingStatusName(BookingStatus status) {
  return status.name;
}

String _slotKey(String barberId, DateTime start) {
  return '$barberId-${start.toIso8601String()}';
}

String _slotLockId(String barberId, DateTime start) {
  return '${barberId}_${start.millisecondsSinceEpoch}';
}

List<DateTime> _slotSegmentStarts(DateTime start, int durationMinutes) {
  final safeDuration = durationMinutes > 0 ? durationMinutes : 30;
  return [
    for (var offset = 0; offset < safeDuration; offset += 5)
      start.add(Duration(minutes: offset)),
  ];
}

BookingStatus _bookingStatusFromName(String value) {
  return BookingStatus.values.firstWhere(
    (status) => status.name == value,
    orElse: () => BookingStatus.pending,
  );
}

CustomerArrivalStatus _customerArrivalStatusFromName(String value) {
  return CustomerArrivalStatus.values.firstWhere(
    (status) => status.name == value,
    orElse: () => CustomerArrivalStatus.notStarted,
  );
}

String _joinRequestStatusName(JoinRequestStatus status) {
  return status.name;
}

String _string(Object? value, String fallback) {
  return value is String && value.trim().isNotEmpty ? value : fallback;
}

int _int(Object? value, int fallback) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return fallback;
}

double _double(Object? value, double fallback) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return fallback;
}

DateTime _date(Object? value) {
  if (value is Timestamp) {
    return value.toDate();
  }
  if (value is DateTime) {
    return value;
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return DateTime.now();
}

DateTime? _nullableDate(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is Timestamp) {
    return value.toDate();
  }
  if (value is DateTime) {
    return value;
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return null;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<String>().toList(growable: false);
}

List<ProinExpiringLot> _proinExpiringLots(Object? value) {
  if (value is! List) return const [];
  final lots = <ProinExpiringLot>[];
  for (final raw in value.whereType<Map>()) {
    final data = Map<String, dynamic>.from(raw);
    final expiresAtMillis = _int(data['expiresAtMillis'], 0);
    final amountProin = _int(data['amountProin'], 0);
    if (expiresAtMillis <= 0 || amountProin <= 0) continue;
    lots.add(
      ProinExpiringLot(
        lotId: _string(data['lotId'], ''),
        amountProin: amountProin,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMillis),
        sourceType: _string(data['sourceType'], ''),
      ),
    );
  }
  lots.sort((left, right) => left.expiresAt.compareTo(right.expiresAt));
  return List.unmodifiable(lots);
}

Map<String, int> _intMap(Object? value) {
  if (value is! Map) {
    return const {};
  }
  return Map.unmodifiable({
    for (final entry in value.entries)
      if (entry.key.toString().trim().isNotEmpty)
        entry.key.toString(): _int(entry.value, 0),
  });
}

String _guessImageContentType(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  return 'image/jpeg';
}

String _safeUploadName(String fileName) {
  final safe = fileName
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-')
      .replaceAll(RegExp(r'-+'), '-');
  return safe.isEmpty ? 'photo.jpg' : safe;
}

String _normalizeUpiId(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) {
    return '';
  }
  if (normalized.length > 100 ||
      !RegExp(
        r'^[a-z0-9._-]{2,64}@[a-z][a-z0-9.-]{1,32}$',
      ).hasMatch(normalized)) {
    throw FormatException('Enter a valid UPI ID, for example salon@bank.');
  }
  return normalized;
}

int? _parseClockMinutes(String value) {
  final normalized = value.trim().toUpperCase().replaceAll('.', '');
  final match = RegExp(
    r'^(\d{1,2})(?::(\d{2}))?\s*([AP]M)?$',
  ).firstMatch(normalized);
  if (match == null) {
    return null;
  }
  var hour = int.tryParse(match.group(1) ?? '');
  final minute = int.tryParse(match.group(2) ?? '0');
  final period = match.group(3);
  if (hour == null || minute == null || minute > 59) {
    return null;
  }
  if (period != null) {
    if (hour < 1 || hour > 12) {
      return null;
    }
    if (period == 'AM') {
      hour = hour == 12 ? 0 : hour;
    } else if (hour != 12) {
      hour += 12;
    }
  } else if (hour > 23) {
    return null;
  }
  return hour * 60 + minute;
}

String formatSalonClockTime(String value) {
  final minutes = _parseClockMinutes(value);
  if (minutes == null) return value.trim();
  final hour24 = minutes ~/ 60;
  final minute = (minutes % 60).toString().padLeft(2, '0');
  final period = hour24 >= 12 ? 'PM' : 'AM';
  final hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24);
  return '$hour12:$minute $period';
}

String formatSalonHoursRange(Salon salon) {
  if (salon.openTime.trim().isEmpty || salon.closeTime.trim().isEmpty) {
    return 'Hours pending';
  }
  return '${formatSalonClockTime(salon.openTime)} – '
      '${formatSalonClockTime(salon.closeTime)}';
}

bool _isValidEmail(String value) {
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim());
}
