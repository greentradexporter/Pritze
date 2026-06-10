import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';

const _activeRolePreferenceKey = 'pritze.activeRole';

class AppState extends ChangeNotifier {
  final List<Salon> _salons = [];
  final List<Barber> _barbers = [];
  final List<Booking> _bookings = [];
  final List<JoinRequest> _joinRequests = [];

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

  bool get usesRealPhoneOtp => false;

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

  String? get activeCustomerPhone => _customerAccount?.contact;

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
                (barber.uid == account.id || barber.phone == account.contact),
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
                    request.barberPhone == account.contact,
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
    return _bookings
        .where((booking) => booking.customerPhone == _customerAccount!.contact)
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

  List<Booking> bookingsForSalon(String salonId) {
    return _bookings.where((booking) => booking.salonId == salonId).toList()
      ..sort((a, b) => b.start.compareTo(a.start));
  }

  List<Booking> bookingsForBarber(String barberId) {
    return _bookings.where((booking) => booking.barberId == barberId).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  List<TimeSlot> slotsForService(
    String salonId,
    String serviceId, {
    String? barberId,
  }) {
    if (!isSalonBookable(salonId)) {
      return [];
    }
    final eligibleBarbers = barbersForService(
      salonId,
      serviceId,
    ).where((barber) => barberId == null || barber.id == barberId).toList();
    final now = DateTime.now();
    final hours = <int>[9, 10, 11, 12, 14, 15, 16, 17, 18];
    final slots = <TimeSlot>[];

    for (var dayOffset = 0; dayOffset < 4; dayOffset++) {
      final day = DateTime(now.year, now.month, now.day + dayOffset);
      for (final hour in hours) {
        final start = DateTime(day.year, day.month, day.day, hour);
        if (start.isBefore(now.add(const Duration(minutes: 45)))) {
          continue;
        }
        for (final barber in eligibleBarbers) {
          if (_isBarberFree(barber.id, start)) {
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
    return slots.take(18).toList();
  }

  Future<void> restoreSignedInUser() async {
    await _restoreActiveRole();
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
    final booking = Booking(
      id: 'booking-${_bookingCounter++}',
      salonId: slot.salonId,
      serviceId: slot.serviceId,
      barberId: slot.barberId,
      customerName: account.name,
      customerPhone: account.contact,
      start: slot.start,
      status: BookingStatus.pending,
      createdAt: DateTime.now(),
    );
    _bookings.add(booking);
    notifyListeners();
    return booking;
  }

  Future<String?> startCustomerPhoneVerification({
    required String phone,
  }) async {
    return null;
  }

  Future<UserAccount> loginCustomerWithPhone({
    required String name,
    required String phone,
    String? verificationId,
    String? smsCode,
  }) async {
    final account = UserAccount(
      id: 'customer-${_accountCounter++}',
      name: name.trim(),
      contact: normalizePhone(phone),
      provider: LoginProvider.phone,
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
      name: name.trim(),
      contact: email.trim(),
      provider: LoginProvider.gmail,
    );
    _activateRole(UserRole.customer, account);
    return account;
  }

  Future<UserAccount> loginOwnerWithPhone({
    required String name,
    required String phone,
    String? verificationId,
    String? smsCode,
  }) async {
    final account = UserAccount(
      id: 'owner-${_accountCounter++}',
      name: name.trim(),
      contact: normalizePhone(phone),
      provider: LoginProvider.phone,
    );
    _activateRole(UserRole.owner, account);
    return account;
  }

  Future<UserAccount> loginOwnerWithGmail({
    required String name,
    required String email,
  }) async {
    final account = UserAccount(
      id: 'owner-${_accountCounter++}',
      name: name.trim(),
      contact: email.trim(),
      provider: LoginProvider.gmail,
    );
    _activateRole(UserRole.owner, account);
    return account;
  }

  Future<UserAccount> loginBarberWithPhone({
    required String name,
    required String phone,
    String? verificationId,
    String? smsCode,
  }) async {
    final account = UserAccount(
      id: 'barber-account-${_accountCounter++}',
      name: name.trim(),
      contact: normalizePhone(phone),
      provider: LoginProvider.phone,
    );
    _activateRole(UserRole.barber, account);
    return account;
  }

  Future<UserAccount> loginBarberWithGmail({
    required String name,
    required String email,
  }) async {
    final account = UserAccount(
      id: 'barber-account-${_accountCounter++}',
      name: name.trim(),
      contact: email.trim(),
      provider: LoginProvider.gmail,
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
      return;
    }
    _bookings[index] = _bookings[index].copyWith(status: status);
    notifyListeners();
  }

  Future<void> updateOwnerSalon({
    required String name,
    required String ownerName,
    required String address,
    required String phone,
    required String openTime,
    required String closeTime,
  }) async {
    final salon = ownerSalon.copyWith(
      name: name.trim(),
      ownerName: ownerName.trim(),
      address: address.trim(),
      phone: normalizePhone(phone),
      openTime: openTime.trim(),
      closeTime: closeTime.trim(),
    );
    _replaceSalon(salon);
    _ownerProfileCompleted = true;
    notifyListeners();
  }

  Future<void> addOwnerService({
    required String name,
    required String category,
    required int price,
    required int durationMinutes,
  }) async {
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
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    _barbers.add(
      Barber(
        id: 'barber-${_barberCounter++}',
        salonId: ownerSalonId,
        name: name.trim(),
        phone: normalizePhone(phone),
        speciality: speciality.trim().isEmpty ? 'Grooming expert' : speciality,
        experienceYears: experienceYears,
        resumeSummary: resumeSummary.trim().isEmpty
            ? 'Customer-first grooming professional.'
            : resumeSummary.trim(),
        serviceIds: serviceIds.isEmpty
            ? ownerSalon.services.map((service) => service.id).toList()
            : serviceIds,
      ),
    );
    notifyListeners();
  }

  Future<void> submitJoinRequest({
    required String salonId,
    required String barberName,
    required String barberPhone,
    required String speciality,
    required int experienceYears,
    required String resumeSummary,
    required List<String> serviceIds,
  }) async {
    final request = JoinRequest(
      id: 'request-${_requestCounter++}',
      requesterUid: _barberAccount?.id,
      salonId: salonId,
      barberName: barberName.trim(),
      barberPhone: normalizePhone(barberPhone),
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
      id: 'barber-${_barberCounter++}',
      uid: request.requesterUid,
      salonId: request.salonId,
      name: request.barberName,
      phone: request.barberPhone,
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

  int dailyCollection(String salonId) {
    return bookingsForSalon(salonId)
        .where(
          (booking) =>
              _isToday(booking.start) &&
              booking.status == BookingStatus.completed,
        )
        .fold(0, (total, booking) {
          return total +
              (getService(booking.salonId, booking.serviceId)?.price ?? 0);
        });
  }

  int todayBookingCount(String salonId) {
    return bookingsForSalon(
      salonId,
    ).where((booking) => _isToday(booking.start)).length;
  }

  int countByStatus(String salonId, BookingStatus status) {
    return bookingsForSalon(
      salonId,
    ).where((booking) => booking.status == status).length;
  }

  Map<String, int> barberWorkCount(String salonId) {
    final result = <String, int>{};
    for (final barber in barbersForSalon(salonId)) {
      result[barber.id] = bookingsForBarber(barber.id)
          .where(
            (booking) =>
                _isToday(booking.start) &&
                booking.status != BookingStatus.cancelled,
          )
          .length;
    }
    return result;
  }

  Booking? currentBookingForBarber(String barberId) {
    final now = DateTime.now();
    final activeStatuses = {BookingStatus.confirmed, BookingStatus.inProgress};
    final candidates = bookingsForBarber(barberId).where((booking) {
      final service = getService(booking.salonId, booking.serviceId);
      final duration = service?.durationMinutes ?? 30;
      final end = booking.start.add(Duration(minutes: duration));
      return activeStatuses.contains(booking.status) &&
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
    final nextStatuses = {
      BookingStatus.pending,
      BookingStatus.confirmed,
      BookingStatus.inProgress,
    };
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
      if (!_isToday(booking.start) ||
          booking.status != BookingStatus.completed) {
        continue;
      }
      final service = getService(salonId, booking.serviceId);
      if (service == null) {
        continue;
      }
      result[service.id] = (result[service.id] ?? 0) + service.price;
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
    notifyListeners();
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

  void _setSyncError(Object error) {
    _lastSyncError =
        'Could not save to Firebase. Check your internet connection and try again.';
    if (kDebugMode) {
      _lastSyncError = 'Could not save to Firebase: $error';
    }
    notifyListeners();
  }

  bool _isBarberFree(String barberId, DateTime start) {
    return !_bookings.any((booking) {
      if (booking.barberId != barberId ||
          booking.status == BookingStatus.cancelled) {
        return false;
      }
      return booking.start.year == start.year &&
          booking.start.month == start.month &&
          booking.start.day == start.day &&
          booking.start.hour == start.hour;
    });
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
  final FirebaseAuth auth;
  PhoneAuthCredential? _pendingPhoneCredential;
  bool _googleInitialized = false;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final List<StreamSubscription<Object?>> _privateSubscriptions = [];
  final Map<String, Map<String, Booking>> _bookingSnapshots = {};
  final Map<String, Map<String, JoinRequest>> _joinRequestSnapshots = {};

  FirebaseAppState({required this.firestore, required this.auth}) {
    _connectFirestore();
    unawaited(restoreSignedInUser());
  }

  @override
  bool get usesFirebase => true;

  @override
  bool get usesRealPhoneOtp => true;

  @override
  Future<void> restoreSignedInUser() async {
    await super.restoreSignedInUser();
    final user = auth.currentUser;
    if (user != null) {
      await _restoreAccountForUser(user);
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
      final booking = await super.createBooking(slot: slot);
      await _setBooking(booking);
      return booking;
    });
  }

  @override
  Future<String?> startCustomerPhoneVerification({
    required String phone,
  }) async {
    final completer = Completer<String?>();
    await auth.verifyPhoneNumber(
      phoneNumber: normalizePhone(phone),
      verificationCompleted: (credential) {
        _pendingPhoneCredential = credential;
        if (!completer.isCompleted) {
          completer.complete(null);
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
  Future<UserAccount> loginCustomerWithPhone({
    required String name,
    required String phone,
    String? verificationId,
    String? smsCode,
  }) async {
    final credential =
        _pendingPhoneCredential ??
        (verificationId == null || smsCode == null || smsCode.trim().isEmpty
            ? null
            : PhoneAuthProvider.credential(
                verificationId: verificationId,
                smsCode: smsCode.trim(),
              ));
    if (credential == null) {
      throw StateError('OTP verification is required for phone login.');
    }
    final result = await auth.signInWithCredential(credential);
    final account = UserAccount(
      id: result.user?.uid ?? normalizePhone(phone),
      name: name.trim(),
      contact: normalizePhone(phone),
      provider: LoginProvider.phone,
    );
    _activateRole(UserRole.customer, account);
    _pendingPhoneCredential = null;
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
  Future<UserAccount> loginOwnerWithPhone({
    required String name,
    required String phone,
    String? verificationId,
    String? smsCode,
  }) async {
    final credential =
        _pendingPhoneCredential ??
        (verificationId == null || smsCode == null || smsCode.trim().isEmpty
            ? null
            : PhoneAuthProvider.credential(
                verificationId: verificationId,
                smsCode: smsCode.trim(),
              ));
    if (credential == null) {
      throw StateError('OTP verification is required for phone login.');
    }
    final result = await auth.signInWithCredential(credential);
    final account = UserAccount(
      id: result.user?.uid ?? normalizePhone(phone),
      name: name.trim(),
      contact: normalizePhone(phone),
      provider: LoginProvider.phone,
    );
    _activateRole(UserRole.owner, account);
    _pendingPhoneCredential = null;
    await _upsertUser(account, role: UserRole.owner);
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
  Future<UserAccount> loginBarberWithPhone({
    required String name,
    required String phone,
    String? verificationId,
    String? smsCode,
  }) async {
    final credential =
        _pendingPhoneCredential ??
        (verificationId == null || smsCode == null || smsCode.trim().isEmpty
            ? null
            : PhoneAuthProvider.credential(
                verificationId: verificationId,
                smsCode: smsCode.trim(),
              ));
    if (credential == null) {
      throw StateError('OTP verification is required for phone login.');
    }
    final result = await auth.signInWithCredential(credential);
    final account = UserAccount(
      id: result.user?.uid ?? normalizePhone(phone),
      name: name.trim(),
      contact: normalizePhone(phone),
      provider: LoginProvider.phone,
    );
    _activateRole(UserRole.barber, account);
    _pendingPhoneCredential = null;
    await _upsertUser(account, role: UserRole.barber);
    await _linkCurrentBarberAccount(account);
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
  Future<void> updateBookingStatus(
    String bookingId,
    BookingStatus status,
  ) async {
    await _runFirebaseSave(() async {
      await super.updateBookingStatus(bookingId, status);
      await firestore.collection('bookings').doc(bookingId).set({
        'status': _bookingStatusName(status),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  @override
  Future<void> updateOwnerSalon({
    required String name,
    required String ownerName,
    required String address,
    required String phone,
    required String openTime,
    required String closeTime,
  }) async {
    await _runFirebaseSave(() async {
      await super.updateOwnerSalon(
        name: name,
        ownerName: ownerName,
        address: address,
        phone: phone,
        openTime: openTime,
        closeTime: closeTime,
      );
      await _setSalon(ownerSalon);
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
  Future<void> submitJoinRequest({
    required String salonId,
    required String barberName,
    required String barberPhone,
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
        speciality: speciality,
        experienceYears: experienceYears,
        resumeSummary: resumeSummary,
        serviceIds: serviceIds,
      );
      if (_joinRequests.length > before) {
        await _setJoinRequest(_joinRequests.last);
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
      auth.authStateChanges().listen((user) {
        _connectPrivateFirestore(user);
      }),
    );
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
    if (provider == 'phone' || user.phoneNumber != null) {
      return LoginProvider.phone;
    }
    return LoginProvider.gmail;
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
    final index = _barbers.indexWhere(
      (barber) =>
          barber.isActive &&
          (barber.uid == account.id || barber.phone == account.contact),
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
                : fallbackName.trim()),
      contact: user?.email ?? googleAccount.email,
      provider: LoginProvider.gmail,
    );
  }

  Future<void> _upsertUser(UserAccount account, {required UserRole role}) {
    return firestore.collection('users').doc(account.id).set({
      'name': account.name,
      'contact': account.contact,
      'provider': account.provider.label.toLowerCase(),
      'roles': FieldValue.arrayUnion([role.name]),
      'activeRole': role.name,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
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

  Future<void> _setBooking(Booking booking) async {
    final salon = await firestore
        .collection('salons')
        .doc(booking.salonId)
        .get();
    final barber = await firestore
        .collection('barbers')
        .doc(booking.barberId)
        .get();
    await firestore
        .collection('bookings')
        .doc(booking.id)
        .set(
          _bookingToFirestore(
            booking,
            customerUid: auth.currentUser?.uid,
            ownerUid: salon.data()?['ownerUid'] as String?,
            barberUid: barber.data()?['uid'] as String?,
          ),
        );
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
    'phone': salon.phone,
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
    phone: _string(data['phone'], ''),
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
    salonId: _string(data['salonId'], ''),
    serviceId: _string(data['serviceId'], ''),
    barberId: _string(data['barberId'], ''),
    customerName: _string(data['customerName'], 'Customer'),
    customerPhone: _string(data['customerPhone'], ''),
    start: _date(data['start']),
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

String _bookingStatusName(BookingStatus status) {
  return status.name;
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
