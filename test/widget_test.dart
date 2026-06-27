import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nashik_salon_booking/main.dart';
import 'package:nashik_salon_booking/models/app_models.dart';
import 'package:nashik_salon_booking/models/service_catalog.dart';
import 'package:nashik_salon_booking/screens/barber/barber_dashboard_screen.dart';
import 'package:nashik_salon_booking/screens/customer/salon_detail_screen.dart';
import 'package:nashik_salon_booking/screens/salon/salon_dashboard_screen.dart';
import 'package:nashik_salon_booking/state/app_state.dart';
import 'package:nashik_salon_booking/state/app_state_scope.dart';
import 'package:nashik_salon_booking/widgets/account_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('opens to empty customer salon discovery', (tester) async {
    await tester.pumpWidget(const AppStateProvider(child: TrimtimeApp()));

    expect(find.text('Skip the wait. Book your cut.'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.text('No matching services'), findsOneWidget);
    expect(find.text('Discover'), findsOneWidget);
  });

  testWidgets('customer search box accepts typing', (tester) async {
    await tester.pumpWidget(const AppStateProvider(child: TrimtimeApp()));

    final searchBox = find.widgetWithText(
      TextField,
      'Search salon, service, area',
    );
    expect(searchBox, findsOneWidget);

    await tester.enterText(searchBox, 'beard');
    await tester.pump();

    expect(find.text('beard'), findsOneWidget);
    expect(find.text('Search results'), findsOneWidget);
  });

  testWidgets('salon detail offers direct barber picker without scrolling', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9888888801',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: MaterialApp(
          home: SalonDetailScreen(salonId: state.ownerSalon.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pick service'), findsOneWidget);
    expect(find.text('Pick barber'), findsOneWidget);
    await tester.tap(find.text('Pick barber'));
    await tester.pumpAndSettle();

    expect(find.text('Choose your barber'), findsOneWidget);
    expect(find.text('Ravi'), findsOneWidget);
  });

  testWidgets('barber speciality is chosen from a dropdown', (tester) async {
    final state = await _stateWithSalonService();
    await state.loginBarberWithEmail(name: 'Aman', email: 'aman@example.com');
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );

    expect(find.text('Haircut specialist'), findsOneWidget);

    final specialityDropdown = find.byType(DropdownButtonFormField<String>);
    await tester.scrollUntilVisible(
      specialityDropdown,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(specialityDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fade specialist').last);
    await tester.pumpAndSettle();

    expect(find.text('Fade specialist'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Speciality'), findsNothing);
  });

  testWidgets('customer discovery only shows bookable shops', (tester) async {
    final state = AppState();
    await state.loginOwnerWithEmail(
      name: 'Owner A',
      email: 'owner-a@example.com',
    );
    await state.updateOwnerSalon(
      name: 'Almost Ready Salon',
      ownerName: 'Owner A',
      address: 'MG Road',
      phone: '9000000001',
      openTime: '9:00 AM',
      closeTime: '8:00 PM',
    );
    await state.signOutActiveUser();
    await state.loginOwnerWithEmail(
      name: 'Owner B',
      email: 'owner-b@example.com',
    );
    await state.updateOwnerSalon(
      name: 'Ready Cuts',
      ownerName: 'Owner B',
      address: 'College Road',
      phone: '9000000002',
      openTime: '9:00 AM',
      closeTime: '8:00 PM',
    );
    await state.addOwnerService(
      name: 'Fade cut',
      category: 'Hair',
      price: 250,
      durationMinutes: 30,
    );
    await state.addOwnerBarber(
      name: 'Rafi',
      phone: '9000000003',
      speciality: 'Fade specialist',
      experienceYears: 4,
      resumeSummary: 'Clean fades.',
      serviceIds: [state.ownerSalon.services.first.id],
    );
    await state.signOutActiveUser();

    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );

    expect(find.text('Ready Cuts'), findsOneWidget);
    expect(find.text('Almost Ready Salon'), findsNothing);
  });

  test(
    'owner shop becomes bookable only after service and assigned barber',
    () async {
      final state = AppState();
      await state.loginOwnerWithEmail(
        name: 'Owner',
        email: 'owner@example.com',
      );
      await state.updateOwnerSalon(
        name: 'Setup Shop',
        ownerName: 'Owner',
        address: 'Main Road',
        phone: '9111111111',
        openTime: '9:00 AM',
        closeTime: '8:00 PM',
      );

      expect(state.isSalonBookable(state.ownerSalon.id), isFalse);

      await state.addOwnerService(
        name: 'Haircut',
        category: 'Hair',
        price: 200,
        durationMinutes: 30,
      );
      expect(state.isSalonBookable(state.ownerSalon.id), isFalse);

      await state.addOwnerBarber(
        name: 'Aman',
        phone: '9111111112',
        speciality: 'Haircut specialist',
        experienceYears: 3,
        resumeSummary: 'Sharp cuts.',
        serviceIds: [state.ownerSalon.services.first.id],
      );

      expect(state.isSalonBookable(state.ownerSalon.id), isTrue);
    },
  );

  test('barber email login links approved join request to account', () async {
    final state = await _stateWithSalonService();
    await state.loginBarberWithEmail(name: 'Aman', email: 'aman@example.com');
    await state.submitJoinRequest(
      salonId: state.salons.first.id,
      barberName: 'Aman',
      barberPhone: '9222222222',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Sharp cuts.',
      serviceIds: [state.salons.first.services.first.id],
    );
    final requestId = state.currentJoinRequest!.id;
    await state.approveJoinRequest(requestId);

    expect(state.currentBarber?.name, 'Aman');
    expect(state.currentBarber?.phone, '+919222222222');
  });

  test(
    'owner added barber can see assigned barber profile after login',
    () async {
      final state = await _stateWithSalonService(signOut: false);
      final serviceId = state.ownerSalon.services.first.id;
      await state.addOwnerBarber(
        name: 'Ravi',
        phone: '9333333333',
        email: 'ravi@example.com',
        speciality: 'Haircut specialist',
        experienceYears: 4,
        resumeSummary: 'Walk-in and appointment cuts.',
        serviceIds: [serviceId],
      );

      expect(state.pendingJoinRequests, isEmpty);
      expect(state.joinRequests.last.status, JoinRequestStatus.approved);

      await state.signOutActiveUser();
      await state.loginBarberWithEmail(name: 'Ravi', email: 'ravi@example.com');

      expect(state.currentBarber?.name, 'Ravi');
      expect(state.currentBarber?.serviceIds, contains(serviceId));
    },
  );

  testWidgets('barber join request is blocked when no shops exist', (
    tester,
  ) async {
    final state = AppState();
    await state.loginBarberWithEmail(name: 'Aman', email: 'aman@example.com');
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );

    expect(find.text('No shops available yet'), findsOneWidget);
    expect(find.text('Send request'), findsNothing);
  });

  testWidgets(
    'barber services use a dropdown and request action stays visible',
    (tester) async {
      final state = await _stateWithSalonService();
      await state.loginBarberWithEmail(name: 'Aman', email: 'aman@example.com');
      await tester.pumpWidget(
        AppStateProvider(
          createAppState: () => state,
          child: const MaterialApp(home: BarberDashboardScreen()),
        ),
      );

      expect(find.text('Send request'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Services you can handle'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Services you can handle'));
      await tester.pumpAndSettle();

      expect(find.byType(CheckboxListTile), findsWidgets);
      expect(find.text('Send request'), findsOneWidget);
    },
  );

  test('adding more than three barbers never overwrites staff', () async {
    final state = await _stateWithSalonService(signOut: false);
    final serviceId = state.ownerSalon.services.first.id;

    for (var index = 0; index < 5; index++) {
      await state.addOwnerBarber(
        name: 'Barber $index',
        phone: '90000000${index.toString().padLeft(2, '0')}',
        speciality: 'Haircut specialist',
        experienceYears: 2,
        resumeSummary: 'Salon team member.',
        serviceIds: [serviceId],
      );
    }

    final barbers = state.barbersForSalon(state.ownerSalon.id);
    expect(barbers, hasLength(5));
    expect(barbers.map((barber) => barber.id).toSet(), hasLength(5));
  });

  test('bookings remain tied to the authenticated customer uid', () async {
    final state = await _stateWithSalonService(signOut: false);
    final serviceId = state.ownerSalon.services.first.id;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9333333333',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Appointment cuts.',
      serviceIds: [serviceId],
    );
    await state.signOutActiveUser();
    final customer = await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'customer@example.com',
    );
    final slot = state.slotsForService(state.salons.first.id, serviceId).first;

    final booking = await state.createBooking(slot: slot);

    expect(booking.customerUid, customer.id);
    expect(state.customerBookings.map((item) => item.id), contains(booking.id));
  });

  test('available slots respect shop hours and service duration', () async {
    final state = AppState();
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
    await state.updateOwnerSalon(
      name: 'Short Day Salon',
      ownerName: 'Owner',
      address: 'Main Road',
      phone: '9444444444',
      openTime: '10:00 AM',
      closeTime: '12:00 PM',
    );
    await state.addOwnerService(
      name: 'Long treatment',
      category: 'Hair Texture',
      price: 1200,
      durationMinutes: 90,
    );
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9444444445',
      speciality: 'Hair styling expert',
      experienceYears: 4,
      resumeSummary: 'Long-form treatments.',
      serviceIds: [service.id],
    );
    final slots = state.slotsForService(state.ownerSalon.id, service.id);

    expect(slots, isNotEmpty);
    for (final slot in slots) {
      final startMinutes = slot.start.hour * 60 + slot.start.minute;
      final endMinutes = startMinutes + service.durationMinutes;
      expect(startMinutes, greaterThanOrEqualTo(10 * 60));
      expect(endMinutes, lessThanOrEqualTo(12 * 60));
    }
  });

  test(
    'long bookings block every overlapping slot and cancellation frees them',
    () async {
      final state = AppState();
      await state.loginOwnerWithEmail(
        name: 'Owner',
        email: 'owner@example.com',
      );
      await state.updateOwnerSalon(
        name: 'Overlap Safe Salon',
        ownerName: 'Owner',
        address: 'Main Road',
        phone: '9555555555',
        openTime: '9:00 AM',
        closeTime: '8:00 PM',
      );
      await state.addOwnerService(
        name: 'Keratin treatment',
        category: 'Hair Texture',
        price: 2500,
        durationMinutes: 90,
      );
      await state.addOwnerService(
        name: 'Haircut',
        category: 'Hair',
        price: 300,
        durationMinutes: 30,
      );
      final longService = state.ownerSalon.services.first;
      final shortService = state.ownerSalon.services.last;
      await state.addOwnerBarber(
        name: 'Aman',
        phone: '9555555556',
        speciality: 'All-round grooming expert',
        experienceYears: 5,
        resumeSummary: 'Cuts and treatments.',
        serviceIds: [longService.id, shortService.id],
      );
      await state.signOutActiveUser();
      await state.loginCustomerWithEmail(
        name: 'Customer',
        email: 'customer@example.com',
      );
      final bookedSlot = state
          .slotsForService(state.salons.single.id, longService.id)
          .first;

      final booking = await state.createBooking(slot: bookedSlot);
      final bookingEnd = bookedSlot.start.add(const Duration(minutes: 90));
      final blockedStarts = state
          .slotsForService(state.salons.single.id, shortService.id)
          .where(
            (slot) =>
                slot.barberId == bookedSlot.barberId &&
                !slot.start.isBefore(bookedSlot.start) &&
                slot.start.isBefore(bookingEnd),
          );

      expect(blockedStarts, isEmpty);

      await state.updateBookingStatus(booking.id, BookingStatus.cancelled);
      final reopenedStarts = state
          .slotsForService(state.salons.single.id, shortService.id)
          .map((slot) => slot.start);
      expect(reopenedStarts, contains(bookedSlot.start));
      await expectLater(
        state.updateBookingStatus(booking.id, BookingStatus.confirmed),
        throwsStateError,
      );
    },
  );

  test('shop registration rejects invalid operating hours', () async {
    final state = AppState();
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');

    await expectLater(
      state.updateOwnerSalon(
        name: 'Invalid Hours Salon',
        ownerName: 'Owner',
        address: 'Main Road',
        phone: '9666666666',
        openTime: '8:00 PM',
        closeTime: '9:00 AM',
      ),
      throwsArgumentError,
    );
  });

  testWidgets('discover uses bounded slot queries with the full catalog', (
    tester,
  ) async {
    final state = _CountingAppState();
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
    await state.updateOwnerSalon(
      name: 'Full Catalog Salon',
      ownerName: 'Owner',
      address: 'Main Road',
      phone: '9777777777',
      openTime: '9:00 AM',
      closeTime: '8:00 PM',
    );
    await state.addOwnerServicesFromCatalog();
    await state.addOwnerBarber(
      name: 'Aman',
      phone: '9777777778',
      speciality: 'All-round grooming expert',
      experienceYears: 5,
      resumeSummary: 'Full service specialist.',
      serviceIds: state.ownerSalon.services
          .map((service) => service.id)
          .toList(),
    );
    state.resetSlotQueryCount();

    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );
    await tester.pumpAndSettle();

    expect(state.slotQueryCount, lessThanOrEqualTo(2));

    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();

    expect(state.slotQueryCount, lessThanOrEqualTo(4));
  });

  test('catalog import only adds selected service categories', () async {
    final state = AppState();
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
    await state.updateOwnerSalon(
      name: 'Focused Salon',
      ownerName: 'Owner',
      address: 'Main Road',
      phone: '9888888877',
      openTime: '9:00 AM',
      closeTime: '8:00 PM',
    );

    final added = await state.addOwnerServicesFromCatalog(
      categories: {'Beard'},
    );

    expect(added, greaterThan(0));
    expect(
      state.ownerSalon.services.map((service) => service.category).toSet(),
      {'Beard'},
    );
  });

  test('any available shows each appointment time only once', () async {
    final state = await _stateWithSalonService(signOut: false);
    final serviceId = state.ownerSalon.services.single.id;
    for (var index = 0; index < 2; index++) {
      await state.addOwnerBarber(
        name: 'Barber $index',
        phone: '98888888${index.toString().padLeft(2, '0')}',
        speciality: 'Haircut specialist',
        experienceYears: 3,
        resumeSummary: 'Haircut specialist.',
        serviceIds: [serviceId],
      );
    }

    final slots = state.slotsForService(state.ownerSalon.id, serviceId);

    expect(slots.map((slot) => slot.start).toSet(), hasLength(slots.length));
  });

  test('completed revenue keeps the price captured at booking time', () async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9888888866',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircut specialist.',
      serviceIds: [service.id],
    );
    final barber = state.barbersForSalon(state.ownerSalon.id).single;
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'customer@example.com',
    );
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await state.updateBookingStatus(booking.id, BookingStatus.completed);
    await state.removeOwnerService(service.id);

    expect(state.serviceRevenue(salonId)[service.id], service.price);
    expect(state.totalCollection(salonId), service.price);
    expect(state.barberTotalEarnings(barber.id), service.price);
    expect(
      state.barberDailyEarnings(barber.id, now: booking.start),
      service.price,
    );
    expect(
      state.barberMonthlyEarnings(barber.id, now: booking.start),
      service.price,
    );
  });

  testWidgets('barber has a connected earnings tab', (tester) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9888888865',
      email: 'ravi@example.com',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircut specialist.',
      serviceIds: [service.id],
    );
    final barber = state.barbersForSalon(state.ownerSalon.id).single;
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'earnings-customer@example.com',
    );
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await state.updateBookingStatus(booking.id, BookingStatus.completed);
    await state.signOutActiveUser();
    await state.loginBarberWithEmail(name: 'Ravi', email: 'ravi@example.com');

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(state.currentBarber?.id, barber.id);
    expect(find.text('Appointments'), findsOneWidget);
    expect(find.text('Earnings'), findsOneWidget);
    await tester.tap(find.text('Earnings'));
    await tester.pumpAndSettle();

    expect(find.text('Total earnings'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('This month'), findsOneWidget);
    expect(find.text('₹${service.price}'), findsWidgets);
  });

  test('started cutting marks barber occupied until completion', () async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9888888867',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircut specialist.',
      serviceIds: [service.id],
    );
    final barber = state.barbersForSalon(state.ownerSalon.id).single;
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'occupied@example.com',
    );
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );

    await state.updateBookingStatus(booking.id, BookingStatus.inProgress);
    expect(state.currentBookingForBarber(barber.id)?.id, booking.id);

    await state.updateBookingStatus(booking.id, BookingStatus.completed);
    expect(state.currentBookingForBarber(barber.id), isNull);
    expect(state.serviceRevenue(salonId)[service.id], service.price);
  });

  test('barber ledger classifies timed-out and rejected bookings', () async {
    final state = AppState();
    final now = DateTime(2030, 1, 2, 12);
    final base = Booking(
      id: 'ledger-booking',
      salonId: 'salon',
      serviceId: 'service',
      barberId: 'barber',
      customerName: 'Customer',
      customerPhone: '9000000000',
      start: now.add(const Duration(hours: 1)),
      status: BookingStatus.pending,
      createdAt: now,
    );

    expect(
      state.barberBookingBucket(base, now: now),
      BarberBookingBucket.upcoming,
    );

    final notAccepted = base.copyWith(
      start: now.subtract(const Duration(minutes: 1)),
    );
    expect(
      state.barberBookingBucket(notAccepted, now: now),
      BarberBookingBucket.history,
    );
    expect(state.barberBookingOutcome(notAccepted, now: now), 'Not accepted');

    final missed = base.copyWith(
      start: now.subtract(const Duration(hours: 1)),
      status: BookingStatus.confirmed,
    );
    expect(
      state.barberBookingOutcome(missed, now: now),
      'Missed · not completed',
    );

    final rejected = base.copyWith(status: BookingStatus.rejected);
    expect(
      state.barberBookingBucket(rejected, now: now),
      BarberBookingBucket.cancelled,
    );
    expect(state.barberBookingOutcome(rejected, now: now), 'Rejected by salon');
  });

  test('owner booking desk separates requests, active, and history', () async {
    final state = AppState();
    final now = DateTime(2030, 1, 2, 12);
    final base = Booking(
      id: 'owner-booking',
      salonId: 'salon',
      serviceId: 'service',
      barberId: 'barber',
      customerName: 'Customer',
      customerPhone: '9000000000',
      start: now.add(const Duration(hours: 1)),
      status: BookingStatus.pending,
      createdAt: now,
    );

    expect(
      state.salonBookingBucket(base, now: now),
      SalonBookingBucket.requests,
    );
    expect(
      state.salonBookingOutcome(base, now: now),
      'Waiting for owner action',
    );

    final notAccepted = base.copyWith(
      start: now.subtract(const Duration(minutes: 1)),
    );
    expect(
      state.salonBookingBucket(notAccepted, now: now),
      SalonBookingBucket.history,
    );
    expect(state.salonBookingOutcome(notAccepted, now: now), 'Not accepted');

    final active = base.copyWith(
      start: now.subtract(const Duration(minutes: 10)),
      status: BookingStatus.confirmed,
    );
    expect(
      state.salonBookingBucket(active, now: now),
      SalonBookingBucket.active,
    );

    final missed = base.copyWith(
      start: now.subtract(const Duration(hours: 1)),
      status: BookingStatus.confirmed,
    );
    expect(state.salonBookingOutcome(missed, now: now), 'Missed · not started');

    final rejected = base.copyWith(status: BookingStatus.rejected);
    expect(
      state.salonBookingBucket(rejected, now: now),
      SalonBookingBucket.cancelled,
    );
  });

  test('customer bookings separate active, history, and rejected outcomes', () {
    final state = AppState();
    final now = DateTime(2030, 1, 2, 12);
    final base = Booking(
      id: 'customer-booking',
      salonId: 'salon',
      serviceId: 'service',
      barberId: 'barber',
      customerName: 'Customer',
      customerPhone: '9000000000',
      start: now.add(const Duration(hours: 1)),
      status: BookingStatus.pending,
      createdAt: now,
    );

    expect(
      state.customerBookingBucket(base, now: now),
      CustomerBookingBucket.active,
    );
    expect(state.customerBookingOutcome(base, now: now), 'Waiting for salon');

    final notAccepted = base.copyWith(
      start: now.subtract(const Duration(minutes: 1)),
    );
    expect(
      state.customerBookingBucket(notAccepted, now: now),
      CustomerBookingBucket.history,
    );
    expect(
      state.customerBookingOutcome(notAccepted, now: now),
      'Not accepted by salon',
    );

    final missed = base.copyWith(
      start: now.subtract(const Duration(hours: 1)),
      status: BookingStatus.confirmed,
    );
    expect(
      state.customerBookingBucket(missed, now: now),
      CustomerBookingBucket.history,
    );
    expect(
      state.customerBookingOutcome(missed, now: now),
      'Missed · not completed',
    );

    final rejected = base.copyWith(status: BookingStatus.rejected);
    expect(
      state.customerBookingBucket(rejected, now: now),
      CustomerBookingBucket.cancelled,
    );
    expect(
      state.customerBookingOutcome(rejected, now: now),
      'Rejected by salon',
    );
  });

  test('barber speciality filters unrelated services', () {
    const haircut = SalonService(
      id: 'hair',
      name: 'Classic haircut',
      category: 'Hair',
      price: 300,
      durationMinutes: 30,
    );
    const facial = SalonService(
      id: 'face',
      name: 'Gold facial',
      category: 'Facial',
      price: 900,
      durationMinutes: 45,
    );

    expect(
      serviceMatchesBarberSpeciality(haircut, 'Haircut specialist'),
      isTrue,
    );
    expect(
      serviceMatchesBarberSpeciality(facial, 'Haircut specialist'),
      isFalse,
    );
    expect(
      serviceMatchesBarberSpeciality(facial, 'Skin and cleanup expert'),
      isTrue,
    );
  });

  testWidgets('logout requires explicit confirmation', (tester) async {
    final state = AppState();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'customer@example.com',
    );
    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );

    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(find.text('Log out?'), findsOneWidget);
    expect(state.hasActiveCustomerSession, isTrue);

    await tester.tap(find.text('Stay logged in'));
    await tester.pumpAndSettle();
    expect(state.hasActiveCustomerSession, isTrue);

    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(state.hasActiveCustomerSession, isFalse);
  });

  testWidgets('customer notifications show booking updates', (tester) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9898989898',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'customer@example.com',
    );
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );

    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(unreadNotificationCount(state, UserRole.customer), 1);
    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();

    expect(find.text('Booking request sent'), findsOneWidget);
    expect(unreadNotificationCount(state, UserRole.customer), 0);

    await tester.tap(find.byTooltip('Delete notification'));
    await tester.pumpAndSettle();
    expect(find.text('No notifications yet'), findsOneWidget);
    expect(notificationKeys(state, UserRole.customer), isEmpty);

    await state.updateBookingStatus(booking.id, BookingStatus.confirmed);
    await tester.pumpAndSettle();
    expect(find.text('Booking confirmed'), findsOneWidget);
    expect(unreadNotificationCount(state, UserRole.customer), 1);
  });

  testWidgets('owner notifications show customer booking requests', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9898989898',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'customer@example.com',
    );
    await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');

    expect(unreadNotificationCount(state, UserRole.owner), 1);

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );

    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();

    expect(find.text('New booking request'), findsOneWidget);
    expect(find.text('Booking request sent'), findsNothing);
    expect(unreadNotificationCount(state, UserRole.owner), 0);
  });

  test('Google login derives a name when no name is entered', () async {
    final state = AppState();

    final customer = await state.loginCustomerWithGmail(name: '', email: '');

    expect(customer.name, 'Google user');
  });

  testWidgets('barber notifications show join request updates', (tester) async {
    final state = await _stateWithSalonService();
    await state.loginBarberWithEmail(name: 'Aman', email: 'aman@example.com');
    await state.submitJoinRequest(
      salonId: state.salons.single.id,
      barberName: 'Aman',
      barberPhone: '9876543210',
      barberEmail: 'aman@example.com',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircuts.',
      serviceIds: [state.salons.single.services.single.id],
    );
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );

    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();

    expect(find.text('Join request pending'), findsOneWidget);
  });

  testWidgets('barber notifications show assigned bookings', (tester) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Aman',
      phone: '9876543210',
      email: 'aman@example.com',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'customer@example.com',
    );
    await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await state.loginBarberWithEmail(name: 'Aman', email: 'aman@example.com');

    expect(unreadNotificationCount(state, UserRole.barber), 2);

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );

    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();

    expect(find.text('Booking request sent'), findsOneWidget);
    expect(unreadNotificationCount(state, UserRole.barber), 0);
  });

  testWidgets('barber Google login asks for no profile details upfront', (
    tester,
  ) async {
    final state = AppState();
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );

    expect(find.text('Phone number'), findsOneWidget);
    expect(find.text('Barber name'), findsNothing);
    expect(find.text('Phone number for shop records'), findsNothing);

    await tester.tap(find.text('Gmail'));
    await tester.pumpAndSettle();

    expect(find.text('Barber name'), findsNothing);
    expect(find.text('Phone number for shop records'), findsNothing);
    expect(find.text('Email address'), findsNothing);
    expect(find.text('Nothing else to fill in'), findsOneWidget);
    expect(find.text('Continue with Gmail'), findsOneWidget);
  });

  testWidgets('owner email login asks only for email', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phone number'), findsOneWidget);
    await tester.tap(find.text('Email'));
    await tester.pumpAndSettle();

    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Owner name'), findsNothing);
    expect(find.text('Send email OTP'), findsOneWidget);
  });

  test('phone OTP login is available for every role in app state', () async {
    final state = AppState();
    final verificationId = await state.sendPhoneOtp(phone: '9876543210');
    expect(verificationId, contains('+919876543210'));

    final customer = await state.loginCustomerWithPhone(
      phone: '9876543210',
      verificationId: verificationId,
      smsCode: '123456',
    );
    expect(customer.provider, LoginProvider.phone);

    final owner = await state.loginOwnerWithPhone(
      phone: '9876543211',
      verificationId: verificationId,
      smsCode: '123456',
    );
    expect(owner.provider, LoginProvider.phone);

    final barber = await state.loginBarberWithPhone(
      phone: '9876543212',
      verificationId: verificationId,
      smsCode: '123456',
    );
    expect(barber.provider, LoginProvider.phone);
  });

  testWidgets('barber Google account carries Gmail into join form', (
    tester,
  ) async {
    final state = await _stateWithSalonService();
    await state.loginBarberWithGmail(
      name: 'Aman Barber',
      email: 'aman@gmail.com',
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(state.barberAccount?.contact, 'aman@gmail.com');
    expect(find.text('aman@gmail.com'), findsOneWidget);
    final emailField = find.widgetWithText(TextFormField, 'Email address');
    expect(emailField, findsOneWidget);
    final editableEmail = tester.widget<EditableText>(
      find.descendant(of: emailField, matching: find.byType(EditableText)),
    );
    expect(editableEmail.readOnly, isTrue);
  });

  testWidgets('barber can withdraw a pending salon request', (tester) async {
    final state = await _stateWithSalonService();
    await state.loginBarberWithEmail(
      name: 'Aman',
      email: 'aman@example.com',
      phone: '9876543210',
    );
    await state.submitJoinRequest(
      salonId: state.salons.single.id,
      barberName: 'Aman',
      barberPhone: '9876543210',
      barberEmail: 'aman@example.com',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircuts.',
      serviceIds: [state.salons.single.services.single.id],
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );
    expect(find.text('Withdraw request'), findsOneWidget);

    await tester.tap(find.text('Withdraw request'));
    await tester.pumpAndSettle();
    expect(find.text('Withdraw request?'), findsOneWidget);

    await tester.tap(find.text('Yes, withdraw request'));
    await tester.pumpAndSettle();

    expect(state.currentJoinRequest?.status, JoinRequestStatus.withdrawn);
    expect(state.pendingJoinRequests, isEmpty);
    expect(find.text('Previous request withdrawn'), findsOneWidget);
    expect(find.text('Send request'), findsOneWidget);
  });

  test('haircut and waxing assets map to the correct supplied artwork', () {
    expect(
      serviceIconAssetForCategory('Haircut & Styling'),
      'assets/service_icons/haircut.jpeg',
    );
    expect(
      serviceIconAssetForCategory('Waxing'),
      'assets/service_icons/waxing.jpeg',
    );
  });

  test(
    'salon open badge follows operating hours, not only owner switch',
    () async {
      final state = await _stateWithSalonService(signOut: false);
      await state.addOwnerBarber(
        name: 'Aman',
        phone: '9876543210',
        email: 'aman@example.com',
        speciality: 'Hair',
        experienceYears: 3,
        resumeSummary: 'Experienced barber.',
        serviceIds: state.ownerSalon.services
            .map((service) => service.id)
            .toList(),
      );

      expect(
        state.isSalonCurrentlyOpen(
          state.ownerSalon.id,
          now: DateTime(2026, 6, 27, 10),
        ),
        isTrue,
      );
      expect(
        state.isSalonCurrentlyOpen(
          state.ownerSalon.id,
          now: DateTime(2026, 6, 27, 21),
        ),
        isFalse,
      );
      expect(state.isSalonBookable(state.ownerSalon.id), isTrue);
    },
  );
}

Future<AppState> _stateWithSalonService({bool signOut = true}) async {
  final state = AppState();
  await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
  await state.updateOwnerSalon(
    name: 'Pritze Cuts',
    ownerName: 'Owner',
    address: 'Nashik Road',
    directionsUrl: 'https://maps.app.goo.gl/example',
    phone: '9888888888',
    openTime: '9:00 AM',
    closeTime: '8:00 PM',
  );
  expect(state.ownerSalon.directionsUrl, 'https://maps.app.goo.gl/example');
  await state.addOwnerService(
    name: 'Haircut',
    category: 'Hair',
    price: 200,
    durationMinutes: 30,
  );
  if (signOut) {
    await state.signOutActiveUser();
  }
  return state;
}

class _CountingAppState extends AppState {
  int slotQueryCount = 0;

  void resetSlotQueryCount() {
    slotQueryCount = 0;
  }

  @override
  List<TimeSlot> slotsForService(
    String salonId,
    String serviceId, {
    String? barberId,
  }) {
    slotQueryCount++;
    return super.slotsForService(salonId, serviceId, barberId: barberId);
  }
}
