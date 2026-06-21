import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nashik_salon_booking/main.dart';
import 'package:nashik_salon_booking/models/app_models.dart';
import 'package:nashik_salon_booking/models/service_catalog.dart';
import 'package:nashik_salon_booking/screens/barber/barber_dashboard_screen.dart';
import 'package:nashik_salon_booking/state/app_state.dart';
import 'package:nashik_salon_booking/state/app_state_scope.dart';
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
    await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );

    expect(find.byType(RefreshIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();

    expect(find.text('Booking request sent'), findsOneWidget);
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
}

Future<AppState> _stateWithSalonService({bool signOut = true}) async {
  final state = AppState();
  await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
  await state.updateOwnerSalon(
    name: 'Pritze Cuts',
    ownerName: 'Owner',
    address: 'Nashik Road',
    phone: '9888888888',
    openTime: '9:00 AM',
    closeTime: '8:00 PM',
  );
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
