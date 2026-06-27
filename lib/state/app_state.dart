import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';
import '../models/service_catalog.dart';

const _activeRolePreferenceKey = 'pritze.activeRole';
const _seenNotificationsPreferencePrefix = 'pritze.notifications.seen.';
const _dismissedNotificationsPreferencePrefix =
    'pritze.notifications.dismissed.';
const _pushNotificationChannel = AndroidNotificationChannel(
  'pritze_booking_updates',
  'Booking updates',
  description: 'Booking, request, and account updates from Pritze.',
  importance: Importance.high,
);

class AppState extends ChangeNotifier {
  final List<Salon> _salons = [];
  final List<Barber> _barbers = [];
  final List<Booking> _bookings = [];
  final List<JoinRequest> _joinRequests = [];
  final Set<String> _occupiedSlotKeys = {};
  final Map<String, List<TimeSlot>> _slotCache = {};
  final Map<String, Set<String>> _seenNotificationKeys = {};
  final Map<String, Set<String>> _dismissedNotificationKeys = {};
  DateTime? _slotCacheCreatedAt;

  int _bookingCounter = 100;
  int _serviceCounter = 30;
  int _barberCounter = 20;
  int _requestCounter = 10;
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

  AppState() {
    unawaited(_restoreActiveRole());
  }

  bool get usesFirebase => false;

  UserRole? get activeRole => _activeRole;

  String? get lastSyncError => _lastSyncError;

  bool get isSaving => _isSaving;

  List<Salon> get salons => List.unmodifiable(_salons);

  List<Barber> get barbers => List.unmodifiable(_barbers);

  List<Booking> get bookings => List.unmodifiable(_bookings);

  List<JoinRequest> get joinRequests => List.unmodifiable(_joinRequests);

  UserAccount? get customerAccount => _customerAccount;

  UserAccount? get ownerAccount => _ownerAccount;

  UserAccount? get barberAccount => _barberAccount;

  bool get ownerProfileCompleted => _ownerProfileCompleted;

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

  String? get activeCustomerContact => _customerAccount?.contact;

  String get ownerSalonId {
    final account = _ownerAccount;
    if (account == null) {
      return '';
    }
    return 'salon-${account.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}';
  }

  Salon? get ownerSalonOrNull => getSalon(ownerSalonId);

  Salon get ownerSalon => ownerSalonOrNull ?? _draftOwnerSalon();

  List<Salon> get bookableSalons =>
      _salons.where((salon) => isSalonBookable(salon.id)).toList();

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
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));
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
        salon.openTime.trim().isNotEmpty &&
        salon.closeTime.trim().isNotEmpty;
  }

  bool isSalonSetupComplete(String salonId) {
    final salon = getSalon(salonId);
    if (salon == null || !hasSalonDetails(salonId)) {
      return false;
    }
    return salon.services.isNotEmpty && barbersForSalon(salonId).isNotEmpty;
  }

  bool isSalonBookable(String salonId) {
    final salon = getSalon(salonId);
    if (salon == null || !salon.isOpen || !isSalonSetupComplete(salonId)) {
      return false;
    }
    final serviceIds = salon.services.map((service) => service.id).toSet();
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
        reference.isBefore(booking.start)
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
    return switch (booking.status) {
      BookingStatus.pending => 'Awaiting acceptance',
      BookingStatus.confirmed => 'Confirmed',
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
        reference.isBefore(booking.start)
            ? SalonBookingBucket.requests
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
    return switch (booking.status) {
      BookingStatus.pending => 'Waiting for owner action',
      BookingStatus.confirmed => 'Accepted',
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
        reference.isBefore(booking.start)
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
    return switch (booking.status) {
      BookingStatus.pending => 'Waiting for salon',
      BookingStatus.confirmed => 'Accepted by salon',
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
    if (salon == null || service == null || !isSalonBookable(salonId)) {
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

    for (var dayOffset = 0; dayOffset < 4; dayOffset++) {
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
    final result = List<TimeSlot>.unmodifiable(visibleSlots.take(18));
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
          .map((serviceId) => getService(salonId, serviceId)?.durationMinutes)
          .whereType<int>()
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
    _activeRole = role;
    _clearInactiveRoleState(role);
    await _persistActiveRole();
    notifyListeners();
  }

  Future<void> signOutActiveUser() async {
    _activeRole = null;
    _customerAccount = null;
    _ownerAccount = null;
    _barberAccount = null;
    _currentBarberId = null;
    _currentJoinRequestId = null;
    await _clearPersistedActiveRole();
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

  Future<Booking> createBooking({required TimeSlot slot}) async {
    final account = _customerAccount;
    if (_activeRole != UserRole.customer || account == null) {
      throw StateError('Customer login is required before booking.');
    }
    final service = getService(slot.salonId, slot.serviceId);
    final barber = getBarber(slot.barberId);
    if (service == null ||
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
      status: BookingStatus.pending,
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

  Future<void> sendEmailSignInLink({required String email}) async {}

  Future<void> sendEmailOtp({required String email}) {
    return sendEmailSignInLink(email: email);
  }

  Future<String> sendPhoneOtp({required String phone}) async {
    return 'mock-verification-${normalizePhone(phone)}';
  }

  Future<UserAccount> loginCustomerWithEmail({
    required String name,
    required String email,
    String? emailLink,
  }) async {
    final account = UserAccount(
      id: 'customer-${_accountCounter++}',
      name: name.trim(),
      contact: email.trim(),
      provider: LoginProvider.email,
    );
    _activateRole(UserRole.customer, account);
    return account;
  }

  Future<UserAccount> loginCustomerWithGmail({
    required String name,
    required String email,
  }) async {
    final account = UserAccount(
      id: 'customer-${_accountCounter++}',
      name: name.trim().isEmpty ? 'Google user' : name.trim(),
      contact: email.trim(),
      provider: LoginProvider.google,
    );
    _activateRole(UserRole.customer, account);
    return account;
  }

  Future<UserAccount> loginCustomerWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final account = UserAccount(
      id: 'customer-${_accountCounter++}',
      name: 'Phone user',
      contact: normalizePhone(phone),
      provider: LoginProvider.phone,
    );
    _activateRole(UserRole.customer, account);
    return account;
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
    _activateRole(UserRole.owner, account);
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
    _activateRole(UserRole.owner, account);
    return account;
  }

  Future<UserAccount> loginOwnerWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final contact = normalizePhone(phone);
    final account = UserAccount(
      id: _stableAccountId(UserRole.owner, contact),
      name: 'Phone user',
      contact: contact,
      provider: LoginProvider.phone,
    );
    _activateRole(UserRole.owner, account);
    return account;
  }

  Future<UserAccount> loginBarberWithGmail({
    required String name,
    required String email,
  }) async {
    final account = UserAccount(
      id: 'barber-account-${_accountCounter++}',
      name: name.trim().isEmpty ? 'Google user' : name.trim(),
      contact: email.trim(),
      provider: LoginProvider.google,
    );
    _activateRole(UserRole.barber, account);
    return account;
  }

  Future<UserAccount> loginBarberWithEmail({
    required String name,
    required String email,
    String? phone,
    String? emailLink,
  }) async {
    final account = UserAccount(
      id: 'barber-account-${_accountCounter++}',
      name: name.trim(),
      contact: phone == null || phone.trim().isEmpty
          ? email.trim()
          : normalizePhone(phone),
      provider: LoginProvider.email,
    );
    _activateRole(UserRole.barber, account);
    return account;
  }

  Future<UserAccount> loginBarberWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final account = UserAccount(
      id: 'barber-${_accountCounter++}',
      name: 'Phone user',
      contact: normalizePhone(phone),
      provider: LoginProvider.phone,
    );
    _activateRole(UserRole.barber, account);
    return account;
  }

  Future<void> updateBookingStatus(
    String bookingId,
    BookingStatus status,
  ) async {
    final index = _bookings.indexWhere((booking) => booking.id == bookingId);
    if (index == -1) {
      throw StateError('Booking not found.');
    }
    final previous = _bookings[index];
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
    _bookings[index] = previous.copyWith(status: status);
    final booking = _bookings[index];
    if (status == BookingStatus.cancelled || status == BookingStatus.rejected) {
      _setSlotOccupancy(
        barberId: booking.barberId,
        start: booking.start,
        durationMinutes: booking.durationMinutes,
        occupied: false,
      );
    } else {
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
    String? logoUrl,
    List<String>? photoUrls,
    required String openTime,
    required String closeTime,
  }) async {
    final openingMinutes = _parseClockMinutes(openTime);
    final closingMinutes = _parseClockMinutes(closeTime);
    if (openingMinutes == null || closingMinutes == null) {
      throw FormatException('Use a valid time such as 9:00 AM or 18:30.');
    }
    if (closingMinutes <= openingMinutes) {
      throw ArgumentError('Closing time must be after opening time.');
    }
    final salon = ownerSalon.copyWith(
      name: name.trim(),
      ownerName: ownerName.trim(),
      address: address.trim(),
      directionsUrl: directionsUrl?.trim(),
      phone: normalizePhone(phone),
      logoUrl: logoUrl?.trim(),
      photoUrls: photoUrls
          ?.map((url) => url.trim())
          .where((url) => url.isNotEmpty)
          .toList(),
      openTime: openTime.trim(),
      closeTime: closeTime.trim(),
    );
    _replaceSalon(salon);
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
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError('Service name is required.');
    }
    if (price <= 0 || durationMinutes <= 0) {
      throw ArgumentError('Price and duration must be greater than zero.');
    }
    final salon = ownerSalon;
    final service = SalonService(
      id: 'service-${_serviceCounter++}',
      name: name.trim(),
      category: category.trim().isEmpty ? 'Grooming' : category.trim(),
      price: price,
      durationMinutes: durationMinutes,
    );
    _replaceSalon(salon.copyWith(services: [...salon.services, service]));
    notifyListeners();
  }

  Future<int> addOwnerServicesFromCatalog({
    Iterable<String>? categories,
  }) async {
    final salon = ownerSalon;
    final selectedCategories = categories
        ?.map((category) => category.trim().toLowerCase())
        .where((category) => category.isNotEmpty)
        .toSet();
    final existingNames = salon.services
        .map((service) => service.name.trim().toLowerCase())
        .toSet();
    final servicesToAdd = <SalonService>[];
    for (final template in serviceCatalog) {
      if (selectedCategories != null &&
          selectedCategories.isNotEmpty &&
          !selectedCategories.contains(template.category.toLowerCase())) {
        continue;
      }
      if (existingNames.contains(template.name.trim().toLowerCase())) {
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
    _replaceSalon(
      salon.copyWith(services: [...salon.services, ...servicesToAdd]),
    );
    notifyListeners();
    return servicesToAdd.length;
  }

  Future<void> removeOwnerService(String serviceId) async {
    final salon = ownerSalon;
    final nextServices = salon.services
        .where((service) => service.id != serviceId)
        .toList();
    _replaceSalon(salon.copyWith(services: nextServices));
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
    required String phone,
    String email = '',
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    final normalizedPhone = normalizePhone(phone);
    final normalizedEmail = email.trim().toLowerCase();
    if (_barbers.any(
      (barber) =>
          barber.isActive &&
          (barber.phone == normalizedPhone ||
              (normalizedEmail.isNotEmpty && barber.email == normalizedEmail)),
    )) {
      throw StateError('A barber with this phone or email already exists.');
    }
    final assignedServiceIds = serviceIds.isEmpty
        ? ownerSalon.services.map((service) => service.id).toList()
        : serviceIds;
    final barber = Barber(
      id: _newEntityId('barber', _barberCounter++),
      salonId: ownerSalonId,
      name: name.trim(),
      phone: normalizedPhone,
      email: normalizedEmail,
      speciality: speciality.trim().isEmpty ? 'Grooming expert' : speciality,
      experienceYears: experienceYears,
      resumeSummary: resumeSummary.trim().isEmpty
          ? 'Customer-first grooming professional.'
          : resumeSummary.trim(),
      serviceIds: assignedServiceIds,
    );
    _barbers.add(barber);
    _joinRequests.add(
      JoinRequest(
        id: _newEntityId('request', _requestCounter++),
        salonId: ownerSalonId,
        barberName: barber.name,
        barberPhone: normalizedPhone,
        barberEmail: normalizedEmail,
        speciality: barber.speciality,
        experienceYears: barber.experienceYears,
        resumeSummary: barber.resumeSummary,
        serviceIds: assignedServiceIds,
        status: JoinRequestStatus.approved,
        requestedAt: DateTime.now(),
      ),
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
    final request = JoinRequest(
      id: _newEntityId('request', _requestCounter++),
      requesterUid: _barberAccount?.id,
      salonId: salonId,
      barberName: barberName.trim(),
      barberPhone: normalizePhone(barberPhone),
      barberEmail: barberEmail.trim().toLowerCase(),
      speciality: speciality.trim().isEmpty ? 'Grooming expert' : speciality,
      experienceYears: experienceYears,
      resumeSummary: resumeSummary.trim().isEmpty
          ? 'Customer-first grooming professional.'
          : resumeSummary.trim(),
      serviceIds: serviceIds,
      status: JoinRequestStatus.pending,
      requestedAt: DateTime.now(),
    );
    _currentJoinRequestId = request.id;
    _currentBarberId = null;
    _joinRequests.add(request);
    notifyListeners();
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
          return total + _bookingPrice(booking);
        });
  }

  int totalCollection(String salonId) {
    return bookingsForSalon(salonId)
        .where((booking) => booking.status == BookingStatus.completed)
        .fold(0, (total, booking) => total + _bookingPrice(booking));
  }

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

  int bookingEarning(Booking booking) => _bookingPrice(booking);

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
      final service = getService(salonId, booking.serviceId);
      final price = _bookingPrice(booking);
      if (price <= 0) {
        continue;
      }
      final serviceId = service?.id ?? booking.serviceId;
      result[serviceId] = (result[serviceId] ?? 0) + price;
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

  void _activateRole(UserRole role, UserAccount account) {
    _activeRole = role;
    _customerAccount = role == UserRole.customer ? account : null;
    _ownerAccount = role == UserRole.owner ? account : null;
    _barberAccount = role == UserRole.barber ? account : null;
    _clearInactiveRoleState(role);
    unawaited(_persistActiveRole());
    unawaited(_restoreNotificationPreferences(role));
    notifyListeners();
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
    try {
      final preferences = await SharedPreferences.getInstance();
      final viewerKey = _notificationViewerKey(role);
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
      notifyListeners();
    } catch (_) {
      // Notification history can safely remain in memory if storage is unavailable.
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
  }

  Future<void> _restoreActiveRole() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final roleName = preferences.getString(_activeRolePreferenceKey);
      final role = _roleFromName(roleName);
      if (role != null) {
        _activeRole = role;
        notifyListeners();
      }
    } catch (_) {
      // Local role persistence is a convenience; the app can still run without it.
    }
  }

  Future<void> _persistActiveRole() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final role = _activeRole;
      if (role == null) {
        await preferences.remove(_activeRolePreferenceKey);
      } else {
        await preferences.setString(_activeRolePreferenceKey, role.name);
      }
    } catch (_) {
      // Ignore local persistence failures; Firebase remains the source of truth.
    }
  }

  Future<void> _clearPersistedActiveRole() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_activeRolePreferenceKey);
    } catch (_) {
      // Ignore local persistence failures.
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

  Salon _draftOwnerSalon() {
    final owner = _ownerAccount;
    return Salon(
      id: ownerSalonId,
      name: '',
      ownerName: owner?.name ?? '',
      address: '',
      phone: owner?.contact ?? '',
      logoUrl: '',
      photoUrls: const [],
      distanceLabel: 'Nearby',
      rating: 0,
      reviewCount: 0,
      openTime: '9:00 AM',
      closeTime: '8:00 PM',
      isOpen: true,
      services: const [],
    );
  }
}

class FirebaseAppState extends AppState {
  final FirebaseFirestore firestore;
  final FirebaseFunctions functions;
  final FirebaseAuth auth;
  final FirebaseMessaging messaging;
  final FirebaseStorage storage;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _googleInitialized = false;
  bool _localNotificationsReady = false;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final List<StreamSubscription<Object?>> _privateSubscriptions = [];
  final Map<String, Map<String, Booking>> _bookingSnapshots = {};
  final Map<String, Map<String, JoinRequest>> _joinRequestSnapshots = {};

  FirebaseAppState({
    required this.firestore,
    required this.functions,
    required this.auth,
    required this.messaging,
    FirebaseStorage? storage,
  }) : storage = storage ?? FirebaseStorage.instance {
    _connectFirestore();
    _configurePushNotifications();
    unawaited(restoreSignedInUser());
  }

  @override
  bool get usesFirebase => true;

  @override
  Future<void> restoreSignedInUser() async {
    await super.restoreSignedInUser();
    final user = auth.currentUser;
    if (user != null) {
      await _restoreAccountForUser(user);
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
          ('barber', 'barberUid'),
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

        for (final query in <(String, String)>[
          ('requester', 'requesterUid'),
          ('owner', 'ownerUid'),
        ]) {
          final snapshot = await firestore
              .collection('joinRequests')
              .where(query.$2, isEqualTo: user.uid)
              .get(const GetOptions(source: Source.server));
          _joinRequestSnapshots[query.$1] = {
            for (final doc in snapshot.docs)
              doc.id: _joinRequestFromFirestore(doc),
          };
        }
        final mergedRequests = <String, JoinRequest>{};
        for (final items in _joinRequestSnapshots.values) {
          mergedRequests.addAll(items);
        }
        _joinRequests
          ..clear()
          ..addAll(mergedRequests.values);
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
      await firestore.collection('users').doc(user.uid).set({
        'activeRole': role.name,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _saveMessagingToken(user.uid);
      await _restoreAccountForUser(user);
    }
  }

  @override
  Future<void> signOutActiveUser() async {
    await auth.signOut();
    await super.signOutActiveUser();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _privateSubscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Future<Booking> createBooking({required TimeSlot slot}) async {
    return _runFirebaseSave(() async {
      final account = _customerAccount;
      if (_activeRole != UserRole.customer || account == null) {
        throw StateError('Customer login is required before booking.');
      }
      final customerUid = auth.currentUser?.uid;
      if (customerUid == null || customerUid != account.id) {
        throw StateError('Please sign in again before booking this slot.');
      }
      final service = getService(slot.salonId, slot.serviceId);
      final selectedBarber = getBarber(slot.barberId);
      if (service == null ||
          selectedBarber == null ||
          !selectedBarber.isActive ||
          selectedBarber.salonId != slot.salonId ||
          !selectedBarber.serviceIds.contains(slot.serviceId) ||
          !_isWithinOperatingHours(slot, service.durationMinutes)) {
        throw StateError('This appointment is no longer available.');
      }
      final bookingDoc = firestore.collection('bookings').doc();
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
        status: BookingStatus.pending,
        createdAt: DateTime.now(),
      );
      await firestore.runTransaction((transaction) async {
        final lockSnapshots = <DocumentSnapshot<Map<String, dynamic>>>[];
        for (final lockDoc in lockDocs) {
          lockSnapshots.add(await transaction.get(lockDoc));
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
            ownerUid: salon.data()?['ownerUid'] as String?,
            barberUid: barber.data()?['uid'] as String?,
          ),
        );
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
      unawaited(_sendBookingPush(booking.id, event: 'created'));
      notifyListeners();
      return booking;
    });
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
    final completer = Completer<String>();
    auth.verifyPhoneNumber(
      phoneNumber: normalizePhone(phone),
      timeout: const Duration(seconds: 60),
      verificationCompleted: (credential) async {
        try {
          await auth.signInWithCredential(credential);
          if (!completer.isCompleted) {
            completer.complete('');
          }
        } catch (error) {
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        }
      },
      verificationFailed: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      codeSent: (verificationId, forceResendingToken) {
        if (!completer.isCompleted) {
          completer.complete(verificationId);
        }
      },
      codeAutoRetrievalTimeout: (verificationId) {
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
    final account = await _signInWithEmailOtp(
      fallbackName: name,
      email: email,
      emailOtp: emailLink,
    );
    _activateRole(UserRole.customer, account);
    await _upsertUser(account, role: UserRole.customer);
    return account;
  }

  @override
  Future<UserAccount> loginCustomerWithGmail({
    required String name,
    required String email,
  }) async {
    final account = await _signInWithGoogle(
      fallbackName: name,
      fallbackEmail: email,
    );
    _activateRole(UserRole.customer, account);
    await _upsertUser(account, role: UserRole.customer);
    return account;
  }

  @override
  Future<UserAccount> loginCustomerWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final account = await _signInWithPhoneOtp(
      phone: phone,
      verificationId: verificationId,
      smsCode: smsCode,
    );
    _activateRole(UserRole.customer, account);
    await _upsertUser(account, role: UserRole.customer);
    return account;
  }

  @override
  Future<UserAccount> loginOwnerWithGmail({
    required String name,
    required String email,
  }) async {
    final account = await _signInWithGoogle(
      fallbackName: name,
      fallbackEmail: email,
    );
    _activateRole(UserRole.owner, account);
    await _upsertUser(account, role: UserRole.owner);
    return account;
  }

  @override
  Future<UserAccount> loginOwnerWithEmail({
    required String name,
    required String email,
    String? emailLink,
  }) async {
    final account = await _signInWithEmailOtp(
      fallbackName: name,
      email: email,
      emailOtp: emailLink,
    );
    _activateRole(UserRole.owner, account);
    await _upsertUser(account, role: UserRole.owner);
    return account;
  }

  @override
  Future<UserAccount> loginOwnerWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final account = await _signInWithPhoneOtp(
      phone: phone,
      verificationId: verificationId,
      smsCode: smsCode,
    );
    _activateRole(UserRole.owner, account);
    await _upsertUser(account, role: UserRole.owner);
    return account;
  }

  @override
  Future<UserAccount> loginBarberWithGmail({
    required String name,
    required String email,
  }) async {
    final account = await _signInWithGoogle(
      fallbackName: name,
      fallbackEmail: email,
    );
    _activateRole(UserRole.barber, account);
    await _upsertUser(account, role: UserRole.barber);
    await _linkCurrentBarberAccount(account);
    return account;
  }

  @override
  Future<UserAccount> loginBarberWithEmail({
    required String name,
    required String email,
    String? phone,
    String? emailLink,
  }) async {
    var account = await _signInWithEmailOtp(
      fallbackName: name,
      email: email,
      emailOtp: emailLink,
    );
    if (phone != null && phone.trim().isNotEmpty) {
      account = account.copyWith(contact: normalizePhone(phone));
    }
    _activateRole(UserRole.barber, account);
    await _upsertUser(account, role: UserRole.barber);
    await _linkCurrentBarberAccount(account);
    return account;
  }

  @override
  Future<UserAccount> loginBarberWithPhone({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final account = await _signInWithPhoneOtp(
      phone: phone,
      verificationId: verificationId,
      smsCode: smsCode,
    );
    _activateRole(UserRole.barber, account);
    await _upsertUser(account, role: UserRole.barber);
    await _linkCurrentBarberAccount(account);
    return account;
  }

  @override
  Future<void> updateBookingStatus(
    String bookingId,
    BookingStatus status,
  ) async {
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

      final bookingDoc = firestore.collection('bookings').doc(bookingId);
      if (status == BookingStatus.cancelled ||
          status == BookingStatus.rejected) {
        final lockDocs = [
          for (final start in _slotSegmentStarts(
            booking.start,
            booking.durationMinutes,
          ))
            firestore
                .collection('slotLocks')
                .doc(_slotLockId(booking.barberId, start)),
        ];
        await firestore.runTransaction((transaction) async {
          final lockSnapshots = <DocumentSnapshot<Map<String, dynamic>>>[];
          for (final lockDoc in lockDocs) {
            lockSnapshots.add(await transaction.get(lockDoc));
          }
          transaction.set(bookingDoc, {
            'status': _bookingStatusName(status),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          for (var index = 0; index < lockDocs.length; index++) {
            if (lockSnapshots[index].data()?['bookingId'] == booking.id) {
              transaction.set(lockDocs[index], {
                'active': false,
                'updatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            }
          }
        });
      } else {
        await bookingDoc.set({
          'status': _bookingStatusName(status),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      await super.updateBookingStatus(bookingId, status);
      unawaited(_sendBookingPush(bookingId, event: 'statusUpdated'));
    });
  }

  @override
  Future<void> updateOwnerSalon({
    required String name,
    required String ownerName,
    required String address,
    String? directionsUrl,
    required String phone,
    String? logoUrl,
    List<String>? photoUrls,
    required String openTime,
    required String closeTime,
  }) async {
    await _runFirebaseSave(() async {
      await super.updateOwnerSalon(
        name: name,
        ownerName: ownerName,
        address: address,
        directionsUrl: directionsUrl,
        phone: phone,
        logoUrl: logoUrl,
        photoUrls: photoUrls,
        openTime: openTime,
        closeTime: closeTime,
      );
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
  }) async {
    await _runFirebaseSave(() async {
      await super.addOwnerService(
        name: name,
        category: category,
        price: price,
        durationMinutes: durationMinutes,
      );
      await _setSalon(ownerSalon);
    });
  }

  @override
  Future<int> addOwnerServicesFromCatalog({
    Iterable<String>? categories,
  }) async {
    return _runFirebaseSave(() async {
      final added = await super.addOwnerServicesFromCatalog(
        categories: categories,
      );
      if (added > 0) {
        await _setSalon(ownerSalon);
      }
      return added;
    });
  }

  @override
  Future<void> removeOwnerService(String serviceId) async {
    await _runFirebaseSave(() async {
      await super.removeOwnerService(serviceId);
      await _setSalon(ownerSalon);
      for (final barber in _barbers) {
        await _setBarber(barber);
      }
    });
  }

  @override
  Future<void> addOwnerBarber({
    required String name,
    required String phone,
    String email = '',
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
        email: email,
        speciality: speciality,
        experienceYears: experienceYears,
        resumeSummary: resumeSummary,
        serviceIds: serviceIds,
      );
      if (_barbers.length > before) {
        await _setBarber(_barbers.last);
      }
      final request = _joinRequests.lastOrNull;
      if (request != null &&
          request.status == JoinRequestStatus.approved &&
          request.barberPhone == normalizePhone(phone)) {
        await _setJoinRequest(request);
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
    unawaited(_initializeLocalNotifications());
    unawaited(
      messaging.requestPermission(alert: true, badge: true, sound: true),
    );
    unawaited(
      messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      ),
    );
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
  }

  Future<void> _initializeLocalNotifications() async {
    if (_localNotificationsReady) {
      return;
    }
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
    );
    await _localNotifications.initialize(settings: initializationSettings);
    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_pushNotificationChannel);
    _localNotificationsReady = true;
  }

  Future<void> _showForegroundPushNotification(RemoteMessage message) async {
    final notification = message.notification;
    final title = notification?.title;
    final body = notification?.body;
    if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) {
      return;
    }
    await _initializeLocalNotifications();
    await _localNotifications.show(
      id: DateTime.now().millisecondsSinceEpoch.remainder(1000000),
      title: title ?? 'Pritze',
      body: body ?? '',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'pritze_booking_updates',
          'Booking updates',
          channelDescription:
              'Booking, request, and account updates from Pritze.',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> _saveMessagingToken(String uid, {String? token}) async {
    try {
      final messagingToken = token ?? await messaging.getToken();
      if (messagingToken == null || messagingToken.isEmpty) {
        return;
      }
      await firestore.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([messagingToken]),
        'lastFcmToken': messagingToken,
        'notificationsEnabled': true,
        'fcmUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (error) {
      _setSyncError(error);
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
    for (final subscription in _privateSubscriptions) {
      unawaited(subscription.cancel());
    }
    _privateSubscriptions.clear();
    _bookingSnapshots.clear();
    _joinRequestSnapshots.clear();
    _bookings.clear();
    _joinRequests.clear();
    notifyListeners();

    if (user == null) {
      _activeRole = null;
      _customerAccount = null;
      _ownerAccount = null;
      _barberAccount = null;
      _currentBarberId = null;
      _currentJoinRequestId = null;
      unawaited(_clearPersistedActiveRole());
      notifyListeners();
      return;
    }

    unawaited(_restoreAccountForUser(user));
    _listenToBookings('customer', 'customerUid', user.uid);
    _listenToBookings('owner', 'ownerUid', user.uid);
    _listenToBookings('barber', 'barberUid', user.uid);
    _listenToJoinRequests('requester', 'requesterUid', user.uid);
    _listenToJoinRequests('owner', 'ownerUid', user.uid);
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
            _bookings
              ..clear()
              ..addAll(merged.values);
            notifyListeners();
          }),
    );
  }

  void _listenToJoinRequests(String key, String field, String uid) {
    _privateSubscriptions.add(
      firestore
          .collection('joinRequests')
          .where(field, isEqualTo: uid)
          .snapshots()
          .listen((snapshot) {
            _joinRequestSnapshots[key] = {
              for (final doc in snapshot.docs)
                doc.id: _joinRequestFromFirestore(doc),
            };
            final merged = <String, JoinRequest>{};
            for (final items in _joinRequestSnapshots.values) {
              merged.addAll(items);
            }
            _joinRequests
              ..clear()
              ..addAll(merged.values);
            notifyListeners();
          }),
    );
  }

  Future<void> _restoreAccountForUser(User user) async {
    try {
      final doc = await firestore.collection('users').doc(user.uid).get();
      final data = doc.data() ?? {};
      final roles = _rolesFromData(data['roles']);
      final storedRole = _roleFromName(data['activeRole'] as String?);
      final role = (_activeRole != null && roles.contains(_activeRole))
          ? _activeRole!
          : (storedRole != null && roles.contains(storedRole))
          ? storedRole
          : (roles.isNotEmpty ? roles.first : UserRole.customer);
      final account = _accountFromFirebaseUser(user, data);
      _activateRole(role, account);
      if (role == UserRole.barber) {
        await _linkCurrentBarberAccount(account);
      }
    } catch (error) {
      _setSyncError(error);
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

  Future<void> _linkCurrentBarberAccount(UserAccount account) async {
    final signedInEmail = auth.currentUser?.email?.trim().toLowerCase();
    final index = _barbers.indexWhere(
      (barber) =>
          barber.isActive &&
          (barber.uid == account.id ||
              barber.phone == account.contact ||
              (signedInEmail != null && barber.email == signedInEmail)),
    );
    if (index == -1) {
      return;
    }
    final barber = _barbers[index];
    _currentBarberId = barber.id;
    if (barber.uid == account.id) {
      notifyListeners();
      return;
    }
    final linkedBarber = barber.copyWith(uid: account.id);
    _barbers[index] = linkedBarber;
    notifyListeners();
    await firestore.collection('barbers').doc(linkedBarber.id).set({
      'uid': account.id,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
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
          'No Google account is available on this device. Add a Google account in Android Settings, then try again.',
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
      throw StateError('Enter the OTP sent to your email.');
    }
    final response = await functions.httpsCallable('verifyEmailOtp').call({
      'email': trimmedEmail,
      'code': trimmedOtp,
    });
    final data = Map<String, dynamic>.from(response.data as Map);
    final customToken = data['customToken'] as String?;
    if (customToken == null || customToken.isEmpty) {
      throw StateError('Email OTP verification failed.');
    }
    final result = await auth.signInWithCustomToken(customToken);
    final user = result.user;
    return UserAccount(
      id: user?.uid ?? trimmedEmail,
      name: user?.displayName?.trim().isNotEmpty == true
          ? user!.displayName!.trim()
          : fallbackName.trim(),
      contact: user?.email ?? trimmedEmail,
      provider: LoginProvider.email,
    );
  }

  Future<UserAccount> _signInWithPhoneOtp({
    required String phone,
    required String verificationId,
    required String smsCode,
  }) async {
    final normalizedPhone = normalizePhone(phone);
    final existingUser = auth.currentUser;
    User? user;
    if (verificationId.isEmpty && existingUser?.phoneNumber != null) {
      user = existingUser;
    } else {
      final trimmedCode = smsCode.trim();
      if (verificationId.trim().isEmpty || trimmedCode.isEmpty) {
        throw StateError('Enter the OTP sent to your phone.');
      }
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId.trim(),
        smsCode: trimmedCode,
      );
      final result = await auth.signInWithCredential(credential);
      user = result.user;
    }
    return UserAccount(
      id: user?.uid ?? normalizedPhone,
      name: user?.displayName?.trim().isNotEmpty == true
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
    await firestore.collection('users').doc(account.id).set({
      'name': account.name,
      'contact': account.contact,
      'email': auth.currentUser?.email?.trim().toLowerCase(),
      'phone': auth.currentUser?.phoneNumber,
      'provider': account.provider.label.toLowerCase(),
      'roles': FieldValue.arrayUnion([role.name]),
      'activeRole': role.name,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _saveMessagingToken(account.id);
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
    'logoUrl': salon.logoUrl,
    'photoUrls': salon.photoUrls,
    'distanceLabel': salon.distanceLabel,
    'rating': salon.rating,
    'reviewCount': salon.reviewCount,
    'openTime': salon.openTime,
    'closeTime': salon.closeTime,
    'isOpen': salon.isOpen,
    'services': salon.services.map(_serviceToMap).toList(),
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
    'status': _bookingStatusName(booking.status),
    'createdAt': Timestamp.fromDate(booking.createdAt),
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
  final services = (data['services'] as List<dynamic>? ?? [])
      .whereType<Map<dynamic, dynamic>>()
      .map((item) => _serviceFromMap(Map<String, dynamic>.from(item)))
      .toList();
  return Salon(
    id: doc.id,
    name: _string(data['name'], 'Salon'),
    ownerName: _string(data['ownerName'], 'Owner'),
    address: _string(data['address'], 'Address pending verification'),
    directionsUrl: _string(data['directionsUrl'], ''),
    phone: _string(data['phone'], ''),
    logoUrl: _string(data['logoUrl'], ''),
    photoUrls: _stringList(data['photoUrls']),
    distanceLabel: _string(data['distanceLabel'], 'Nearby'),
    rating: _double(data['rating'], 4.5),
    reviewCount: _int(data['reviewCount'], 0),
    openTime: _string(data['openTime'], '9:00 AM'),
    closeTime: _string(data['closeTime'], '8:00 PM'),
    isOpen: data['isOpen'] == true,
    services: services,
  );
}

SalonService _serviceFromMap(Map<String, dynamic> data) {
  return SalonService(
    id: _string(data['id'], 'service-${DateTime.now().microsecondsSinceEpoch}'),
    name: _string(data['name'], 'Service'),
    category: _string(data['category'], 'Grooming'),
    price: _int(data['price'], 0),
    durationMinutes: _int(data['durationMinutes'], 30),
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
    barberId: _string(data['barberId'], ''),
    customerName: _string(data['customerName'], 'Customer'),
    customerPhone: _string(data['customerPhone'], ''),
    start: _date(data['start']),
    durationMinutes: _int(data['durationMinutes'], 30),
    serviceName: _string(data['serviceName'], ''),
    servicePrice: _int(data['servicePrice'], 0),
    status: _bookingStatusFromName(_string(data['status'], 'pending')),
    createdAt: _date(data['createdAt']),
  );
}

JoinRequest _joinRequestFromFirestore(
  DocumentSnapshot<Map<String, dynamic>> doc,
) {
  final data = doc.data() ?? {};
  return JoinRequest(
    id: doc.id,
    requesterUid: data['requesterUid'] as String?,
    salonId: _string(data['salonId'], ''),
    barberName: _string(data['barberName'], 'Barber'),
    barberPhone: _string(data['barberPhone'], ''),
    barberEmail: _string(data['barberEmail'], ''),
    speciality: _string(data['speciality'], 'Grooming expert'),
    experienceYears: _int(data['experienceYears'], 1),
    resumeSummary: _string(
      data['resumeSummary'],
      'Customer-first grooming professional.',
    ),
    serviceIds: _stringList(data['serviceIds']),
    status: _joinRequestStatusFromName(_string(data['status'], 'pending')),
    requestedAt: _date(data['requestedAt']),
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

String _joinRequestStatusName(JoinRequestStatus status) {
  return status.name;
}

JoinRequestStatus _joinRequestStatusFromName(String value) {
  return JoinRequestStatus.values.firstWhere(
    (status) => status.name == value,
    orElse: () => JoinRequestStatus.pending,
  );
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

List<String> _stringList(Object? value) {
  return (value as List<dynamic>? ?? []).whereType<String>().toList(
    growable: false,
  );
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
