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

const _activeRolePreferenceKey = 'pritze.activeRole';
const _seenNotificationsPreferencePrefix = 'pritze.notifications.seen.';
const _dismissedNotificationsPreferencePrefix =
    'pritze.notifications.dismissed.';
const _pushPermissionRequestedPreferenceKey =
    'pritze.notifications.permissionRequested';
const _ownerAlertsEnabledPreferenceKey =
    'pritze.notifications.ownerAlertsEnabled';
const _suppressedOwnerAlertsPreferenceKey =
    'pritze.notifications.suppressedOwnerAlerts';
const _ownerAlertSuppressionDuration = Duration(minutes: 10);
const instantArrivalMinuteOptions = <int>[15, 20, 25];
const instantBookingResponseTimeout = Duration(seconds: 150);
const scheduledBookingHorizonDays = 30;
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
const _defaultSupportPhone = '+91 89996 08278';
const _pushNotificationChannel = AndroidNotificationChannel(
  'pritze_booking_updates',
  'Booking updates',
  description: 'Booking, request, and account updates from Pritze.',
  importance: Importance.high,
);
const _ownerBookingRequestChannel = AndroidNotificationChannel(
  'pritze_owner_booking_requests_v3',
  'Owner booking requests',
  description:
      'Continuous urgent booking request alerts for salon owners until opened.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  sound: RawResourceAndroidNotificationSound('owner_booking_request'),
);
const _ownerBookingAlarmNotificationId = 790001;
const _ownerBookingAlarmNotificationTag = 'pritze_owner_booking_request';
const _ownerBookingAlarmInterval = Duration(seconds: 25);
const _androidInsistentNotificationFlag = 4;
const _acceptInstantBookingNotificationAction = 'accept_instant_booking';
const _rejectInstantBookingNotificationAction = 'reject_instant_booking';
const _legacyOwnerBookingRequestDarwinCategory = 'PRITZE_BOOKING_REQUEST';
const _ownerBookingRequestDarwinCategory = 'PRITZE_BOOKING_REQUEST_V2';
const _ownerInstantBookingNotificationActions = <AndroidNotificationAction>[
  AndroidNotificationAction(
    _acceptInstantBookingNotificationAction,
    'Accept',
    showsUserInterface: false,
    cancelNotification: true,
  ),
  AndroidNotificationAction(
    _rejectInstantBookingNotificationAction,
    'Reject',
    showsUserInterface: false,
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

Future<Set<String>> _activeSuppressedOwnerAlerts() async {
  final preferences = await SharedPreferences.getInstance();
  final now = DateTime.now().millisecondsSinceEpoch;
  final activeEntries = <String>[];
  final activeIds = <String>{};
  for (final entry
      in preferences.getStringList(_suppressedOwnerAlertsPreferenceKey) ??
          const <String>[]) {
    final separator = entry.lastIndexOf('|');
    if (separator <= 0) {
      continue;
    }
    final bookingId = entry.substring(0, separator);
    final expiresAt = int.tryParse(entry.substring(separator + 1)) ?? 0;
    if (bookingId.isNotEmpty && expiresAt > now) {
      activeEntries.add(entry);
      activeIds.add(bookingId);
    }
  }
  await preferences.setStringList(
    _suppressedOwnerAlertsPreferenceKey,
    activeEntries,
  );
  return activeIds;
}

Future<void> _persistOwnerAlertSuppression(String bookingId) async {
  final activeIds = await _activeSuppressedOwnerAlerts();
  activeIds.add(bookingId);
  final preferences = await SharedPreferences.getInstance();
  final expiresAt = DateTime.now()
      .add(_ownerAlertSuppressionDuration)
      .millisecondsSinceEpoch;
  await preferences.setStringList(_suppressedOwnerAlertsPreferenceKey, [
    for (final id in activeIds) '$id|$expiresAt',
  ]);
}

Future<void> _clearOwnerAlertSuppression(String bookingId) async {
  final activeIds = await _activeSuppressedOwnerAlerts();
  activeIds.remove(bookingId);
  final preferences = await SharedPreferences.getInstance();
  final expiresAt = DateTime.now()
      .add(_ownerAlertSuppressionDuration)
      .millisecondsSinceEpoch;
  await preferences.setStringList(_suppressedOwnerAlertsPreferenceKey, [
    for (final id in activeIds) '$id|$expiresAt',
  ]);
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
    await notifications.cancel(
      id: _ownerBookingAlarmNotificationId,
      tag: _ownerBookingAlarmNotificationTag,
    );
    await _persistOwnerAlertSuppression(bookingId);
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    if (FirebaseAuth.instance.currentUser == null) {
      return;
    }
    await FirebaseFunctions.instance.httpsCallable('updateBookingStatus').call({
      'bookingId': bookingId,
      'status': actionId == _acceptInstantBookingNotificationAction
          ? BookingStatus.confirmed.name
          : BookingStatus.rejected.name,
      'cancellationReason': '',
    });
  } catch (error) {
    await _clearOwnerAlertSuppression(bookingId);
    if (kDebugMode) {
      debugPrint('Instant booking notification action failed: $error');
    }
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (kIsWeb) {
    return;
  }
  final notifications = FlutterLocalNotificationsPlugin();
  final initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: _ownerBookingRequestDarwinNotificationCategories,
    ),
  );
  await notifications.initialize(
    settings: initializationSettings,
    onDidReceiveBackgroundNotificationResponse:
        notificationActionBackgroundHandler,
  );
  if (message.data['action'] == 'stop_owner_booking_alarm') {
    await notifications.cancel(
      id: _ownerBookingAlarmNotificationId,
      tag: _ownerBookingAlarmNotificationTag,
    );
    return;
  }
  if (defaultTargetPlatform != TargetPlatform.android) {
    // APNs displays the remote alert and its registered category actions.
    return;
  }
  if (message.data['channel'] != _ownerBookingRequestChannel.id) {
    return;
  }
  final bookingId = message.data['bookingId']?.toString().trim() ?? '';
  if (bookingId.isNotEmpty &&
      (await _activeSuppressedOwnerAlerts()).contains(bookingId)) {
    await notifications.cancel(
      id: _ownerBookingAlarmNotificationId,
      tag: _ownerBookingAlarmNotificationTag,
    );
    return;
  }
  final preferences = await SharedPreferences.getInstance();
  if (preferences.getBool(_ownerAlertsEnabledPreferenceKey) != true) {
    return;
  }

  await notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(_ownerBookingRequestChannel);

  final title = message.data['notificationTitle']?.trim();
  final body = message.data['notificationBody']?.trim();
  await notifications.show(
    id: _ownerBookingAlarmNotificationId,
    title: title?.isNotEmpty == true ? title : 'New booking request',
    body: body?.isNotEmpty == true
        ? body
        : 'A customer is waiting for accept or reject.',
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
        tag: _ownerBookingAlarmNotificationTag,
        sound: const RawResourceAndroidNotificationSound(
          'owner_booking_request',
        ),
        additionalFlags: Int32List.fromList([
          _androidInsistentNotificationFlag,
        ]),
        actions: _ownerInstantBookingNotificationActions,
      ),
    ),
    payload: _notificationPayload(message.data),
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
  final Set<String> _notificationPreferencesReadyViewers = {};
  final Map<String, UserRole> _mockPhoneRoles = {};
  final Map<String, String> _mockPhoneAccountIds = {};
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
  bool _isSaving = false;
  bool _referralOnboardingRequired = false;
  int _referralCodeCounter = 1;
  int _mockDiscountPercent = 0;
  int _mockMaximumDiscountAmount = 0;
  String _mockDiscountSalonId = '';
  final List<_MockVisibleCheckoutDiscountCampaign>
  _mockVisibleDiscountCampaigns = [];
  final Map<String, DiscountQuote> _mockLockedDiscountQuotes = {};
  ProinWalletSummary _customerProinWallet = const ProinWalletSummary();
  final Map<String, ProinWalletSummary> _salonProinWallets = {};
  final List<ProinActivityEntry> _customerProinActivity = [];
  AppNotificationNavigation? _pendingNotificationNavigation;
  Future<void> _rolePersistenceQueue = Future<void>.value();
  Timer? _customerInstantExpiryTimer;

  AppState() {
    unawaited(_restoreActiveRole());
  }

  bool get usesFirebase => false;

  bool get isRestoringSession => false;

  UserRole? get activeRole => _activeRole;

  String? get lastSyncError => _lastSyncError;

  bool get isSaving => _isSaving;

  bool get referralOnboardingRequired => _referralOnboardingRequired;

  Stream<String> get autoVerifiedPhoneNumbers => const Stream.empty();

  bool isPhoneAutoVerified(String phone) => false;

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
        message: 'Pritze offer applied. You save ₹${quote.discountAmount}.',
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
      message:
          '${quote.campaignName} applied. You save ₹${quote.discountAmount}.',
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
      message: 'Voucher applied. You save ₹${quote.discountAmount}.',
      discountQuote: quote,
    );
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

  void markNotificationsSeen(UserRole role, Iterable<String> notificationKeys) {
    final seen = _seenNotificationKeys.putIfAbsent(
      _notificationViewerKey(role),
      () => <String>{},
    );
    final previousLength = seen.length;
    seen.addAll(notificationKeys);
    if (seen.length != previousLength) {
      unawaited(
        _persistNotificationSet(_seenNotificationsPreferencePrefix, role, seen),
      );
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
    final dismissed = _dismissedNotificationKeys.putIfAbsent(
      _notificationViewerKey(role),
      () => <String>{},
    )..add(notificationKey);
    unawaited(
      _persistNotificationSet(
        _dismissedNotificationsPreferencePrefix,
        role,
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
    return _bookings
        .where(
          (booking) =>
              booking.customerUid == account.id ||
              (booking.customerUid == null &&
                  booking.customerPhone == account.contact),
        )
        .map((booking) {
          final pendingReason = _pendingCustomerCancellations[booking.id];
          if (pendingReason == null) {
            return booking;
          }
          return booking.copyWith(
            status: BookingStatus.cancelled,
            cancellationReason: pendingReason,
            cancelledBy: 'customer',
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
      return;
    }

    final now = DateTime.now();
    final deadlines =
        customerBookings
            .where(
              (booking) =>
                  booking.isInstant && booking.status == BookingStatus.pending,
            )
            .map(
              (booking) => booking.createdAt.add(instantBookingResponseTimeout),
            )
            .where((deadline) => deadline.isAfter(now))
            .toList()
          ..sort();
    if (deadlines.isEmpty) {
      return;
    }

    _customerInstantExpiryTimer = Timer(
      deadlines.first.difference(now),
      notifyListeners,
    );
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
    if (salon.instantBookingsEnabled) {
      return true;
    }
    final pausedDate = salon.instantBookingsPausedDate?.trim();
    return pausedDate == null ||
        pausedDate.isEmpty ||
        pausedDate != _dateKey(now ?? DateTime.now());
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
      instantBookingsPausedDate: enabled ? '' : _dateKey(DateTime.now()),
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
        if (start.isBefore(now.add(const Duration(minutes: 45)))) {
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
          if (start.isBefore(now.add(const Duration(minutes: 45)))) {
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
    await _persistActiveRole(role);
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
    if (!isSalonCurrentlyOpen(slot.salonId)) {
      throw StateError('The salon is currently closed.');
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
    final accountId = _stableAccountId(UserRole.owner, contact);
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
    final barber = Barber(
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
    _barbers.add(barber);
    notifyListeners();
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
    unawaited(_persistActiveRole(role));
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
    } catch (_) {
      // Notification history can safely remain in memory if storage is unavailable.
    } finally {
      _notificationPreferencesReadyViewers.add(viewerKey);
      notifyListeners();
    }
  }

  Future<void> _persistNotificationSet(
    String prefix,
    UserRole role,
    Set<String> keys,
  ) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(
        '$prefix${_notificationViewerKey(role)}',
        keys.toList(),
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

  Future<void> _restoreActiveRole() async {
    try {
      await _rolePersistenceQueue;
      final preferences = await SharedPreferences.getInstance();
      final roleName = preferences.getString(_activeRolePreferenceKey);
      final role = _roleFromName(roleName);
      if (role != null && role != UserRole.barber) {
        _activeRole = role;
        notifyListeners();
      }
    } catch (_) {
      // Local role persistence is a convenience; the app can still run without it.
    }
  }

  Future<void> _persistActiveRole(UserRole? role) {
    final operation = _rolePersistenceQueue.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        if (role == null) {
          await preferences.remove(_activeRolePreferenceKey);
        } else {
          await preferences.setString(_activeRolePreferenceKey, role.name);
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
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_ownerAlertsEnabledPreferenceKey, enabled);
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
        discountStatus: booking.hasDiscount ? 'redeemed' : 'none',
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
    }
    if (status == BookingStatus.cancelled) {
      return booking.copyWith(
        status: status,
        cancelledAt: now,
        discountStatus: booking.hasDiscount ? 'released' : 'none',
        cancellationReason: cancellationReason,
        cancelledBy: cancelledBy,
      );
    }
    if (status == BookingStatus.rejected) {
      return booking.copyWith(
        status: status,
        rejectedAt: now,
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
  final Map<String, Booking> _optimisticBookingUpdates = <String, Booking>{};
  final Map<String, DateTime> _suppressedOwnerBookingAlerts =
      <String, DateTime>{};
  UserRole? _pendingFirebaseLoginRole;
  String? _pendingCustomerRegistrationPhone;
  String? _pendingCustomerRegistrationUid;
  UserAccount? _pendingGoogleCustomerAccount;
  String? _pendingGoogleCustomerUid;
  bool _suppressTokenRegistration = false;
  Timer? _messagingTokenRetryTimer;
  int _messagingTokenRetryAttempt = 0;
  Timer? _ownerBookingAlarmTimer;
  bool _isRestoringSession = true;
  int _accountRestoreGeneration = 0;
  DateTime? _lastCallableCredentialRefreshAt;

  FirebaseAppState({
    required this.firestore,
    required this.functions,
    required this.auth,
    required this.messaging,
    FirebaseStorage? storage,
  }) : storage = storage ?? FirebaseStorage.instance {
    WidgetsBinding.instance.addObserver(this);
    _connectFirestore();
    _configurePushNotifications();
    unawaited(restoreSignedInUser());
  }

  @override
  bool get usesFirebase => true;

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
    final response = await _callProtectedFunction(
      () => functions
          .httpsCallable('listCheckoutDiscountOffers')
          .call<Map<String, dynamic>>({
            'salonId': salonId,
            'serviceIds': ids,
            if (prefetchOnly) 'prefetchOnly': true,
          }),
    );
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
        await refreshCustomerProinWallet();
        await refreshCustomerProinActivity();
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
      campaignEndsAt: _int(data['campaignEndsAtMillis'], 0) <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _int(data['campaignEndsAtMillis'], 0),
            ),
    );
  }

  @override
  Future<ProinWalletSummary> refreshCustomerProinWallet() async {
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
      _optimisticBookingUpdates.containsKey(bookingId);

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
  }

  @override
  Future<void> restoreSignedInUser() async {
    try {
      await super.restoreSignedInUser();
      final user = auth.currentUser;
      if (user != null) {
        await _restoreAccountForUser(user);
      }
    } finally {
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
    if (uid != null) {
      await _removeMessagingToken(uid);
    }
    try {
      await auth.signOut();
      if (_googleInitialized) {
        await GoogleSignIn.instance.signOut();
      }
    } finally {
      await super.signOutActiveUser();
    }
  }

  @override
  void dispose() {
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
    if (!isSalonCurrentlyOpen(slot.salonId)) {
      throw StateError('The salon is currently closed.');
    }
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
      return _loadServerBooking(_string(result.data['bookingId'], ''));
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
      return _loadServerBooking(_string(result.data['bookingId'], ''));
    });
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
      if (_optimisticBookingUpdates.containsKey(bookingId)) {
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
      _optimisticBookingUpdates[bookingId] = optimisticBooking;
      _bookings[index] = optimisticBooking;
      if (suppressOwnerAlert) {
        _suppressOwnerBookingAlertLocally(bookingId);
        _stopOwnerBookingAlarm();
      }
      notifyListeners();
      _syncOwnerBookingAlarm();
      try {
        if (suppressOwnerAlert) {
          try {
            await _persistOwnerAlertSuppression(bookingId);
          } catch (error) {
            _setSyncError(error);
          }
        }
        await _runFirebaseSave(() async {
          await functions.httpsCallable('updateBookingStatus').call<void>({
            'bookingId': bookingId,
            'status': status.name,
            'cancellationReason': cancellationReason?.trim() ?? '',
          });
        });
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
      } catch (_) {
        _optimisticBookingUpdates.remove(bookingId);
        final currentIndex = _bookings.indexWhere(
          (item) => item.id == bookingId,
        );
        if (currentIndex == -1) {
          _bookings.add(originalBooking);
        } else if (_bookings[currentIndex].status == status) {
          _bookings[currentIndex] = originalBooking;
        }
        if (suppressOwnerAlert) {
          _suppressedOwnerBookingAlerts.remove(bookingId);
          try {
            await _clearOwnerAlertSuppression(bookingId);
          } catch (error) {
            _setSyncError(error);
          }
        }
        notifyListeners();
        _syncOwnerBookingAlarm();
        rethrow;
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
      await _claimOwnerProfilePhone(normalizedPhone);
      await super.updateOwnerSalon(
        name: name,
        ownerName: ownerName,
        address: address,
        directionsUrl: directionsUrl,
        phone: phone,
        email: email,
        logoUrl: logoUrl,
        photoUrls: photoUrls,
        openTime: openTime,
        closeTime: closeTime,
      );
      await _setSalon(ownerSalon);
    });
  }

  @override
  Future<void> setOwnerInstantBookingEnabled(bool enabled) async {
    await _runFirebaseSave(() async {
      await super.setOwnerInstantBookingEnabled(enabled);
      await _setSalon(ownerSalon);
    });
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
      await _setSalon(ownerSalon);
    });
    return ownerSalon.photoUrls.last;
  }

  @override
  Future<void> removeOwnerSalonPhoto(String photoUrl) async {
    final trimmed = photoUrl.trim();
    await _runFirebaseSave(() async {
      await super.removeOwnerSalonPhoto(trimmed);
      await _setSalon(ownerSalon);
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
    await _runFirebaseSave(() async {
      await super.addOwnerService(
        name: template.name,
        category: template.category,
        price: price,
        durationMinutes: durationMinutes,
        isAvailable: isAvailable,
        instantBookingEnabled: instantBookingEnabled,
      );
      if (shouldPersist) {
        await _setSalon(ownerSalon);
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
    await _runFirebaseSave(() async {
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
        await _setSalon(ownerSalon);
      }
    });
  }

  @override
  Future<int> addOwnerServicesFromCatalog({
    Iterable<String>? serviceNames,
  }) async {
    final shouldPersist = ownerSalonOrNull != null;
    return _runFirebaseSave(() async {
      final added = await super.addOwnerServicesFromCatalog(
        serviceNames: serviceCatalog.map((service) => service.name),
      );
      if (added > 0 && shouldPersist) {
        await _setSalon(ownerSalon);
      }
      return added;
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
    final before = _barbers.length;
    await _runFirebaseSave(() async {
      await super.addOwnerBarber(
        name: name,
        phone: phone,
        speciality: speciality,
        experienceYears: experienceYears,
        resumeSummary: resumeSummary,
        serviceIds: serviceIds,
      );
      if (_barbers.length > before) {
        await _setBarber(_barbers.last);
      }
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
    await _runFirebaseSave(() async {
      await super.updateOwnerBarber(
        barberId: barberId,
        name: name,
        phone: phone,
        speciality: speciality,
        experienceYears: experienceYears,
        resumeSummary: resumeSummary,
        serviceIds: serviceIds,
      );
      final barber = _barbers.where((item) => item.id == barberId).firstOrNull;
      if (barber != null) {
        await _setBarber(barber);
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
    await _runFirebaseSave(() async {
      await super.removeBarber(barberId);
      final barber = _barbers.where((item) => item.id == barberId).firstOrNull;
      if (barber != null) {
        await _setBarber(barber);
      }
    });
  }

  void _connectFirestore() {
    _subscriptions.add(
      firestore.collection('salons').snapshots().listen((snapshot) {
        _salons
          ..clear()
          ..addAll(snapshot.docs.map(_salonFromFirestore));
        _ownerProfileCompleted = ownerSalonOrNull != null;
        notifyListeners();
      }),
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
      firestore.collection('barbers').snapshots().listen((snapshot) {
        _barbers
          ..clear()
          ..addAll(snapshot.docs.map(_barberFromFirestore));
        notifyListeners();
      }),
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
        if (user != null) {
          unawaited(_saveMessagingToken(user.uid));
        }
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
    final destination = _notificationDestination(message.data['destination']);
    queueNotificationNavigation(
      destination,
      bookingId: message.data['bookingId']?.toString().trim() ?? '',
    );
  }

  void _handleLocalNotificationResponse(NotificationResponse response) {
    unawaited(_processLocalNotificationResponse(response));
  }

  Future<void> _processLocalNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = _decodeNotificationPayload(response.payload);
    final bookingId = payload['bookingId']?.toString().trim() ?? '';
    final destination = _notificationDestination(payload['destination']);
    final actionId = response.actionId?.trim() ?? '';
    final isBookingDecision =
        actionId == _acceptInstantBookingNotificationAction ||
        actionId == _rejectInstantBookingNotificationAction;
    if (isBookingDecision &&
        bookingId.isNotEmpty &&
        payload['isInstant']?.toString() == 'true') {
      silenceOwnerBookingAlert(bookingId);
    }
    queueNotificationNavigation(destination, bookingId: bookingId);
    if (!isBookingDecision || bookingId.isEmpty) {
      return;
    }

    _stopOwnerBookingAlarm();
    try {
      await updateBookingStatus(
        bookingId,
        actionId == _acceptInstantBookingNotificationAction
            ? BookingStatus.confirmed
            : BookingStatus.rejected,
      );
    } catch (error) {
      _setSyncError(error);
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
    if (message.data['action'] == 'stop_owner_booking_alarm') {
      _stopOwnerBookingAlarm();
      await _initializeLocalNotifications();
      await _localNotifications.cancel(
        id: _ownerBookingAlarmNotificationId,
        tag: _ownerBookingAlarmNotificationTag,
      );
      return;
    }
    final notification = message.notification;
    final title =
        notification?.title ?? message.data['notificationTitle']?.trim();
    final body = notification?.body ?? message.data['notificationBody']?.trim();
    if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) {
      return;
    }
    final isOwnerBookingRequest =
        message.data['channel'] == _ownerBookingRequestChannel.id;
    if (isOwnerBookingRequest &&
        (_activeRole != UserRole.owner || _ownerAccount == null)) {
      return;
    }
    final bookingId = message.data['bookingId']?.toString().trim() ?? '';
    if (isOwnerBookingRequest &&
        bookingId.isNotEmpty &&
        (_isOwnerBookingAlertSuppressedLocally(bookingId) ||
            (await _activeSuppressedOwnerAlerts()).contains(bookingId))) {
      _stopOwnerBookingAlarm();
      _syncOwnerBookingAlarm();
      return;
    }
    await _initializeLocalNotifications();
    await _localNotifications.show(
      id: isOwnerBookingRequest
          ? _ownerBookingAlarmNotificationId
          : DateTime.now().millisecondsSinceEpoch.remainder(1000000),
      title: title ?? 'Pritze',
      body: body ?? '',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          isOwnerBookingRequest
              ? _ownerBookingRequestChannel.id
              : _pushNotificationChannel.id,
          isOwnerBookingRequest
              ? _ownerBookingRequestChannel.name
              : _pushNotificationChannel.name,
          channelDescription: isOwnerBookingRequest
              ? _ownerBookingRequestChannel.description
              : _pushNotificationChannel.description,
          importance: isOwnerBookingRequest ? Importance.max : Importance.high,
          priority: isOwnerBookingRequest ? Priority.max : Priority.high,
          icon: '@mipmap/ic_launcher',
          category: isOwnerBookingRequest
              ? AndroidNotificationCategory.alarm
              : null,
          ongoing: isOwnerBookingRequest,
          autoCancel: !isOwnerBookingRequest,
          enableVibration: isOwnerBookingRequest,
          visibility: isOwnerBookingRequest
              ? NotificationVisibility.public
              : null,
          tag: isOwnerBookingRequest ? _ownerBookingAlarmNotificationTag : null,
          sound: isOwnerBookingRequest
              ? const RawResourceAndroidNotificationSound(
                  'owner_booking_request',
                )
              : null,
          additionalFlags: isOwnerBookingRequest
              ? Int32List.fromList([_androidInsistentNotificationFlag])
              : null,
          actions: isOwnerBookingRequest
              ? _ownerInstantBookingNotificationActions
              : null,
        ),
        iOS: DarwinNotificationDetails(
          sound: isOwnerBookingRequest ? 'owner_booking_request.wav' : null,
          categoryIdentifier: isOwnerBookingRequest
              ? _ownerBookingRequestDarwinCategory
              : null,
          interruptionLevel: isOwnerBookingRequest
              ? InterruptionLevel.active
              : null,
        ),
        macOS: DarwinNotificationDetails(
          sound: isOwnerBookingRequest ? 'owner_booking_request.wav' : null,
          categoryIdentifier: isOwnerBookingRequest
              ? _ownerBookingRequestDarwinCategory
              : null,
        ),
      ),
      payload: _notificationPayload(message.data),
    );
  }

  void _syncOwnerBookingAlarm() {
    final shouldRing =
        _activeRole == UserRole.owner &&
        _ownerAccount != null &&
        bookingsForSalon(ownerSalonId).any(
          (booking) =>
              booking.isInstant &&
              booking.status == BookingStatus.pending &&
              !_isOwnerBookingAlertSuppressedLocally(booking.id),
        );
    if (!shouldRing) {
      _stopOwnerBookingAlarm();
      return;
    }
    if (_ownerBookingAlarmTimer != null) {
      return;
    }
    unawaited(_showOwnerBookingRequestAlarm());
    _ownerBookingAlarmTimer = Timer.periodic(_ownerBookingAlarmInterval, (_) {
      final stillPending =
          _activeRole == UserRole.owner &&
          _ownerAccount != null &&
          bookingsForSalon(ownerSalonId).any(
            (booking) =>
                booking.isInstant &&
                booking.status == BookingStatus.pending &&
                !_isOwnerBookingAlertSuppressedLocally(booking.id),
          );
      if (!stillPending) {
        _stopOwnerBookingAlarm();
        return;
      }
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
    _stopOwnerBookingAlarm();
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

  void _stopOwnerBookingAlarm() {
    _ownerBookingAlarmTimer?.cancel();
    _ownerBookingAlarmTimer = null;
    unawaited(
      _localNotifications.cancel(
        id: _ownerBookingAlarmNotificationId,
        tag: _ownerBookingAlarmNotificationTag,
      ),
    );
  }

  Future<void> _showOwnerBookingRequestAlarm() async {
    final pending =
        bookingsForSalon(ownerSalonId)
            .where(
              (booking) =>
                  booking.isInstant &&
                  booking.status == BookingStatus.pending &&
                  !_isOwnerBookingAlertSuppressedLocally(booking.id),
            )
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (pending.isEmpty) {
      _stopOwnerBookingAlarm();
      return;
    }
    final booking = pending.first;
    await _initializeLocalNotifications();
    await _localNotifications.show(
      id: _ownerBookingAlarmNotificationId,
      title: booking.isInstant
          ? 'Instant booking request'
          : 'New booking request',
      body: '${booking.customerName} is waiting for accept or reject.',
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
          tag: _ownerBookingAlarmNotificationTag,
          sound: RawResourceAndroidNotificationSound('owner_booking_request'),
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
        'destination': 'bookings',
        'bookingId': booking.id,
        'isInstant': 'true',
      }),
    );
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
      final isOwnerSession = _activeRole == UserRole.owner;
      await firestore.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([messagingToken]),
        'ownerAlertV3Tokens': isOwnerSession
            ? FieldValue.arrayUnion([messagingToken])
            : FieldValue.arrayRemove([messagingToken]),
        'lastFcmToken': messagingToken,
        'notificationsEnabled': true,
        'ownerNotificationsEnabled': isOwnerSession,
        'fcmUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _messagingTokenRetryTimer?.cancel();
      _messagingTokenRetryTimer = null;
      _messagingTokenRetryAttempt = 0;
    } catch (error) {
      _scheduleMessagingTokenRetry(uid);
      _setSyncError(error);
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
    try {
      final token = await messaging.getToken();
      await firestore.collection('users').doc(uid).set({
        if (token != null && token.isNotEmpty)
          'fcmTokens': FieldValue.arrayRemove([token]),
        if (token != null && token.isNotEmpty)
          'ownerAlertV3Tokens': FieldValue.arrayRemove([token]),
        'lastFcmToken': FieldValue.delete(),
        'notificationsEnabled': false,
        'ownerNotificationsEnabled': false,
        'activeRole': FieldValue.delete(),
        'fcmUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (error) {
      _setSyncError(error);
    } finally {
      try {
        await messaging.deleteToken();
      } catch (error) {
        _setSyncError(error);
      }
    }
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
    _accountRestoreGeneration += 1;
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
    _stopOwnerBookingAlarm();
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
    if (_pendingFirebaseLoginRole == null) {
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
            for (final entry in _optimisticBookingUpdates.entries.toList()) {
              final serverBooking = merged[entry.key];
              if (serverBooking?.status == entry.value.status) {
                _optimisticBookingUpdates.remove(entry.key);
              } else if (serverBooking != null) {
                merged[entry.key] = entry.value;
              }
            }
            _bookings
              ..clear()
              ..addAll(merged.values);
            _syncOwnerBookingAlarm();
            notifyListeners();
          }),
    );
  }

  Future<void> _restoreAccountForUser(User user) async {
    final restoreGeneration = ++_accountRestoreGeneration;
    try {
      final doc = await firestore.collection('users').doc(user.uid).get();
      final ownerSalons = await firestore
          .collection('salons')
          .where('ownerUid', isEqualTo: user.uid)
          .limit(1)
          .get();
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
          await _claimOwnerProfilePhone(salonPhone);
        }
      }
      if (restoreGeneration != _accountRestoreGeneration ||
          auth.currentUser?.uid != user.uid) {
        return;
      }
      _activateRole(role, account);
      if (role == UserRole.customer) {
        unawaited(_refreshCustomerProinWalletInBackground());
      }
      await _saveMessagingToken(user.uid);
      if (restoreGeneration != _accountRestoreGeneration ||
          auth.currentUser?.uid != user.uid) {
        return;
      }
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
        await user.getIdToken(true);
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

  Future<void> _upsertUser(
    UserAccount account, {
    required UserRole role,
  }) async {
    final accountPhone = RegExp(r'^\+91\d{10}$').hasMatch(account.contact)
        ? account.contact
        : auth.currentUser?.phoneNumber;
    await firestore.collection('users').doc(account.id).set({
      'name': account.name,
      'contact': account.contact,
      'email': auth.currentUser?.email?.trim().toLowerCase(),
      'phone': accountPhone,
      'provider': account.provider.label.toLowerCase(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _saveMessagingToken(account.id);
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
    try {
      await _upsertUser(resolvedAccount, role: role);
    } catch (error) {
      _setSyncError(error);
    }
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

  Future<void> _setSalon(Salon salon) {
    final data = _salonToMap(salon);
    final uid = auth.currentUser?.uid;
    if (uid != null) {
      data['ownerUid'] = uid;
    }
    return firestore.collection('salons').doc(salon.id).set(data);
  }

  Future<void> _setBarber(Barber barber) {
    final data = _barberToMap(barber);
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

Map<String, Object?> _salonToMap(Salon salon) {
  return {
    'name': salon.name,
    'ownerName': salon.ownerName,
    'address': salon.address,
    'directionsUrl': salon.directionsUrl,
    'phone': salon.phone,
    'email': salon.email,
    'logoUrl': salon.logoUrl,
    'photoUrls': salon.photoUrls,
    'distanceLabel': salon.distanceLabel,
    'rating': salon.rating,
    'reviewCount': salon.reviewCount,
    'openTime': salon.openTime,
    'closeTime': salon.closeTime,
    'isOpen': salon.isOpen,
    'instantBookingsEnabled': salon.instantBookingsEnabled,
    'instantBookingsPausedDate': salon.instantBookingsPausedDate ?? '',
    'services': canonicalSalonServices(
      salon.services,
    ).map(_serviceToMap).toList(),
    'updatedAt': FieldValue.serverTimestamp(),
  };
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

Map<String, Object?> _barberToMap(Barber barber) {
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
    'updatedAt': FieldValue.serverTimestamp(),
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

Salon _salonFromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
  final data = doc.data() ?? {};
  final services = canonicalSalonServices(
    (data['services'] as List<dynamic>? ?? [])
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
    services: services,
  );
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
    uid: data['uid'] as String?,
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

Booking _bookingFromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
  final data = doc.data() ?? {};
  return Booking(
    id: doc.id,
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
  return null;
}

List<String> _stringList(Object? value) {
  return (value as List<dynamic>? ?? []).whereType<String>().toList(
    growable: false,
  );
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

String _dateKey(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
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
