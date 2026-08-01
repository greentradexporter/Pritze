import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:nashik_salon_booking/main.dart';
import 'package:nashik_salon_booking/models/app_models.dart';
import 'package:nashik_salon_booking/models/service_catalog.dart';
import 'package:nashik_salon_booking/screens/barber/barber_dashboard_screen.dart';
import 'package:nashik_salon_booking/screens/customer/customer_home_screen.dart';
import 'package:nashik_salon_booking/screens/customer/my_bookings_screen.dart';
import 'package:nashik_salon_booking/screens/customer/salon_booking_screen.dart';
import 'package:nashik_salon_booking/screens/customer/salon_detail_screen.dart';
import 'package:nashik_salon_booking/screens/partner/partner_hub_screen.dart';
import 'package:nashik_salon_booking/screens/salon/salon_dashboard_screen.dart';
import 'package:nashik_salon_booking/screens/salon/salon_profile_setup_screen.dart';
import 'package:nashik_salon_booking/state/app_state.dart';
import 'package:nashik_salon_booking/state/app_state_scope.dart';
import 'package:nashik_salon_booking/widgets/account_actions.dart';
import 'package:nashik_salon_booking/widgets/auth_login_panel.dart';
import 'package:nashik_salon_booking/widgets/booking_status_timeline.dart';
import 'package:nashik_salon_booking/widgets/customer_booking_confirmation_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('uses the configured Pritze support number by default', () {
    expect(AppState().supportPhone, '+91 89996 08278');
  });

  test('push permission policy handles iOS and Android first launch', () {
    expect(
      shouldRequestPushPermission(
        AuthorizationStatus.notDetermined,
        isAndroid: false,
        hasRequestedOnAndroid: false,
      ),
      isTrue,
    );
    expect(
      shouldRequestPushPermission(
        AuthorizationStatus.authorized,
        isAndroid: false,
        hasRequestedOnAndroid: false,
      ),
      isFalse,
    );
    expect(
      shouldRequestPushPermission(
        AuthorizationStatus.denied,
        isAndroid: false,
        hasRequestedOnAndroid: false,
      ),
      isFalse,
    );
    expect(
      shouldRequestPushPermission(
        AuthorizationStatus.denied,
        isAndroid: true,
        hasRequestedOnAndroid: false,
      ),
      isTrue,
    );
    expect(
      shouldRequestPushPermission(
        AuthorizationStatus.denied,
        isAndroid: true,
        hasRequestedOnAndroid: true,
      ),
      isFalse,
    );
    expect(
      canRegisterForPushNotifications(AuthorizationStatus.authorized),
      isTrue,
    );
    expect(
      canRegisterForPushNotifications(AuthorizationStatus.provisional),
      isTrue,
    );
    expect(
      canRegisterForPushNotifications(AuthorizationStatus.denied),
      isFalse,
    );
  });

  testWidgets('opens to empty customer salon discovery', (tester) async {
    await tester.pumpWidget(const AppStateProvider(child: TrimtimeApp()));

    expect(find.text('Current location'), findsOneWidget);
    expect(find.text('Chembur'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.text('No open salons found'), findsOneWidget);
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

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(find.text('Search results'), findsOneWidget);
  });

  testWidgets('customer service categories scroll horizontally', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const AppStateProvider(child: TrimtimeApp()));

    final categoryList = find.byKey(const Key('service-category-list'));
    expect(categoryList, findsOneWidget);
    expect(
      tester.widget<ListView>(categoryList).scrollDirection,
      Axis.horizontal,
    );

    await tester.drag(categoryList, const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('Makeup'), findsOneWidget);
  });

  testWidgets('iOS home uses Chembur and readable horizontal services', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const AppStateProvider(child: TrimtimeApp()));

    expect(find.text('Chembur'), findsOneWidget);
    final categoryList = find.byKey(const Key('service-category-list'));
    expect(categoryList, findsOneWidget);
    expect(
      tester.widget<ListView>(categoryList).scrollDirection,
      Axis.horizontal,
    );
    expect(tester.widget<Text>(find.text('Haircut')).style?.fontSize, 14);

    await tester.drag(categoryList, const Offset(-650, 0));
    await tester.pumpAndSettle();
    expect(find.text('Makeup'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('customer home actions fit a narrow iPhone-sized screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
    );
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9888888811',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    await state.signOutActiveUser();

    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Book instantly'), findsOneWidget);
    expect(find.text('View salon'), findsOneWidget);
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

  testWidgets('iOS booking controls fit without overflow', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(428, 926));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = await _stateWithSalonService(signOut: false);
    final salonId = state.ownerSalon.id;
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Sahil',
      phone: '9888888802',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    await state.signOutActiveUser();

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: MaterialApp(
          home: SalonBookingScreen(salonId: salonId, serviceId: service.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Any available'), findsOneWidget);
    expect(find.text('Sahil'), findsWidgets);
    expect(find.text('1 barber'), findsNWidgets(2));
    expect(find.text('0 booking fee'), findsOneWidget);
    expect(find.text('Book this slot'), findsOneWidget);
    expect(find.text('Book for ₹0'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android booking action makes the zero cost explicit', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final state = await _stateWithSalonService(signOut: false);
    final salonId = state.ownerSalon.id;
    final service = state.ownerSalon.services.single;

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: MaterialApp(
          home: SalonBookingScreen(salonId: salonId, serviceId: service.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Book for ₹0'), findsOneWidget);
    expect(find.text('Book this slot'), findsNothing);
    expect(find.text('0 booking fee'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android booking action opens the polished sign-in sheet', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = await _stateWithSalonService(signOut: false);
    final salonId = state.ownerSalon.id;
    final service = state.ownerSalon.services.single;
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
    );
    await state.addOwnerBarber(
      name: 'Sahil',
      phone: '9888888803',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    await state.signOutActiveUser();
    final firstSlot = state.slotsForService(salonId, service.id).first;
    final firstSlotLabel = state.formatTime(firstSlot.start);

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: MaterialApp(
          home: SalonBookingScreen(salonId: salonId, serviceId: service.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).first, const Offset(0, -720));
    await tester.pumpAndSettle();
    final slotFinder = find.text(firstSlotLabel).first;
    await tester.tap(slotFinder);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Book for ₹0'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('android-booking-login-sheet')),
      findsOneWidget,
    );
    expect(find.text('Complete your booking'), findsOneWidget);
    expect(find.text('₹0 booking fee'), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-login-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android completed booking shows the polished confirmation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = await _stateWithSalonService(signOut: false);
    final salonId = state.ownerSalon.id;
    final service = state.ownerSalon.services.single;
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
    );
    await state.addOwnerBarber(
      name: 'Sahil',
      phone: '9888888804',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    await state.signOutActiveUser();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'confirmation@example.com',
    );
    final firstSlot = state.slotsForService(salonId, service.id).first;
    final firstSlotLabel = state.formatTime(firstSlot.start);

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: MaterialApp(
          home: SalonBookingScreen(salonId: salonId, serviceId: service.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).first, const Offset(0, -720));
    await tester.pumpAndSettle();
    final slotFinder = find.text(firstSlotLabel).first;
    await tester.tap(slotFinder);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Book for ₹0'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('android-booking-success-dialog')),
      findsOneWidget,
    );
    expect(find.text('Booking request sent'), findsOneWidget);
    expect(find.text('BOOKING DETAILS'), findsOneWidget);
    expect(find.text('Awaiting salon confirmation'), findsOneWidget);
    expect(find.text('View my bookings'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
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
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
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
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
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
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();

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

  testWidgets('active owner opens directly to the salon dashboard', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);

    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text(state.ownerSalon.name), findsOneWidget);
    expect(find.text('Book your next visit'), findsNothing);
  });

  test('registered salon ownership wins over a stored customer role', () {
    expect(
      resolveLaunchRole(
        hasRegisteredSalon: true,
        roles: const [UserRole.customer, UserRole.owner],
        localRole: UserRole.customer,
        remoteRole: UserRole.customer,
      ),
      UserRole.owner,
    );
  });

  testWidgets('waits for Firebase session restoration before choosing a home', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: _RestoringAppState.new,
        child: const TrimtimeApp(),
      ),
    );

    expect(find.text('Opening Pritze'), findsOneWidget);
    expect(find.text('Book your next visit'), findsNothing);
    expect(find.byType(SalonDashboardScreen), findsNothing);
  });

  test('owner can update service pricing', () async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;

    await state.updateOwnerService(
      serviceId: service.id,
      name: service.name,
      category: service.category,
      price: 450,
      durationMinutes: service.durationMinutes,
    );

    expect(state.ownerSalon.services.single.price, 450);
  });

  test('booking keeps the ordered service snapshot after a salon edit', () {
    const currentService = SalonService(
      id: 'service-1',
      name: 'Premium Haircut',
      category: 'Hair',
      price: 450,
      durationMinutes: 45,
    );
    final booking = Booking(
      id: 'booking-1',
      salonId: 'salon-1',
      serviceId: currentService.id,
      barberId: 'barber-1',
      customerName: 'Customer',
      customerPhone: '9876543210',
      start: DateTime(2026, 7, 27, 10),
      serviceName: 'Haircut',
      servicePrice: 200,
      status: BookingStatus.pending,
      createdAt: DateTime(2026, 7, 26, 10),
    );

    expect(booking.resolvedServiceName(currentService), 'Haircut');
    expect(booking.resolvedServicePrice(currentService), 200);
  });

  testWidgets('booking timeline communicates sent and salon decisions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BookingStatusTimeline(status: BookingStatus.pending),
        ),
      ),
    );

    expect(find.text('Booking sent'), findsOneWidget);
    expect(find.text('Salon response'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BookingStatusTimeline(status: BookingStatus.confirmed),
        ),
      ),
    );
    expect(find.text('Accepted'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BookingStatusTimeline(status: BookingStatus.rejected),
        ),
      ),
    );
    expect(find.text('Rejected'), findsOneWidget);
  });

  testWidgets('customer home shows live current booking progress', (
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
    await state.signOutActiveUser();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'timeline@example.com',
    );
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: CustomerHomeScreen()),
      ),
    );

    expect(
      find.byKey(const Key('current-booking-bottom-panel')),
      findsOneWidget,
    );
    expect(find.text('Current booking · Haircut'), findsOneWidget);
    expect(find.text('Booking sent'), findsOneWidget);
    expect(find.text('Salon response'), findsOneWidget);

    await state.updateBookingStatus(booking.id, BookingStatus.confirmed);
    await tester.pump();
    expect(find.text('Accepted'), findsOneWidget);
  });

  testWidgets('salon booking desk shows the ordered service snapshot', (
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
    await state.signOutActiveUser();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'snapshot@example.com',
    );
    await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
    await state.updateOwnerService(
      serviceId: service.id,
      name: 'Premium Haircut',
      category: service.category,
      price: 450,
      durationMinutes: service.durationMinutes,
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );
    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();

    expect(find.text('Ordered service: Haircut'), findsOneWidget);
    expect(find.text('Ordered service: Premium Haircut'), findsNothing);
  });

  test(
    'owner service settings control customer price availability and instant',
    () async {
      final state = await _stateWithSalonService(signOut: false);
      final original = state.ownerSalon.services.single;
      await state.addOwnerBarber(
        name: 'Ravi',
        phone: '9888888877',
        speciality: 'Haircut specialist',
        experienceYears: 4,
        resumeSummary: 'Haircuts.',
        serviceIds: [original.id],
      );
      final salonId = state.ownerSalon.id;

      await state.updateOwnerService(
        serviceId: original.id,
        name: original.name,
        category: original.category,
        price: 450,
        durationMinutes: original.durationMinutes,
        isAvailable: true,
        instantBookingEnabled: false,
      );

      expect(state.isSalonBookable(salonId), isTrue);
      expect(state.slotsForService(salonId, original.id), isNotEmpty);
      expect(
        state.isInstantBookingAvailable(
          salonId,
          serviceId: original.id,
          now: DateTime(2026, 7, 21, 10),
        ),
        isFalse,
      );

      await state.signOutActiveUser();
      await state.loginCustomerWithEmail(
        name: 'Customer',
        email: 'service-settings@example.com',
      );
      final booking = await state.createBooking(
        slot: state.slotsForService(salonId, original.id).first,
      );
      expect(booking.servicePrice, 450);

      await state.signOutActiveUser();
      await state.loginOwnerWithEmail(
        name: 'Owner',
        email: 'owner@example.com',
      );
      final updated = state.getService(salonId, original.id)!;
      await state.updateOwnerService(
        serviceId: updated.id,
        name: updated.name,
        category: updated.category,
        price: updated.price,
        durationMinutes: updated.durationMinutes,
        isAvailable: false,
      );

      expect(state.getService(salonId, original.id)?.isAvailable, isFalse);
      expect(state.slotsForService(salonId, original.id), isEmpty);
      expect(state.isSalonBookable(salonId), isFalse);
      expect(state.bookableSalons.any((salon) => salon.id == salonId), isFalse);
    },
  );

  testWidgets('owner service menu exposes availability and instant controls', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonProfileSetupScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final actions = find.byTooltip('Service actions');
    await tester.scrollUntilVisible(
      actions,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(actions);
    await tester.pumpAndSettle();

    expect(find.text('Hide from customers'), findsOneWidget);
    expect(find.text('Disable instant'), findsOneWidget);
    expect(find.text('Edit service'), findsOneWidget);

    await tester.tap(find.text('Hide from customers'));
    await tester.pumpAndSettle();

    expect(state.ownerSalon.services.single.isAvailable, isFalse);
    expect(find.text('Hidden'), findsOneWidget);
  });

  test(
    'instant booking preserves the selected arrival timer through acceptance',
    () async {
      final state = await _stateWithSalonService(signOut: false);
      final service = state.ownerSalon.services.single;
      await state.updateOwnerSalon(
        name: state.ownerSalon.name,
        ownerName: state.ownerSalon.ownerName,
        address: state.ownerSalon.address,
        directionsUrl: state.ownerSalon.directionsUrl,
        phone: state.ownerSalon.phone,
        openTime: '12:00 AM',
        closeTime: '11:59 PM',
      );
      await state.addOwnerBarber(
        name: 'Ravi',
        phone: '9333333333',
        speciality: 'Haircut specialist',
        experienceYears: 4,
        resumeSummary: 'Instant cuts.',
        serviceIds: [service.id],
      );
      final salonId = state.ownerSalon.id;
      await state.signOutActiveUser();
      await state.loginCustomerWithEmail(
        name: 'Customer',
        email: 'instant@example.com',
      );

      final booking = await state.createInstantBooking(
        salonId: salonId,
        serviceId: service.id,
        arrivalMinutes: 25,
      );

      expect(booking.isInstant, isTrue);
      expect(booking.status, BookingStatus.pending);
      expect(booking.barberId, isNotEmpty);
      expect(booking.bookingFee, 0);
      expect(booking.paymentRequired, isFalse);
      expect(booking.paymentStatus, 'not_required');
      expect(booking.customerArrivalMinutes, 25);
      expect(booking.salonArrivalMinutes, 30);
      expect(state.customerBookingOutcome(booking), 'Instant request sent');

      final requestedStart = booking.start;
      await state.updateBookingStatus(booking.id, BookingStatus.confirmed);
      final accepted = state.bookings.singleWhere(
        (item) => item.id == booking.id,
      );

      expect(accepted.acceptedAt, isNotNull);
      expect(accepted.start, requestedStart);
      expect(state.customerBookingOutcome(accepted), 'Accepted · arrive soon');
    },
  );

  test(
    'one active booking blocks all duplicates until customer cancellation',
    () async {
      final state = await _stateWithSalonService(signOut: false);
      final service = state.ownerSalon.services.single;
      await state.updateOwnerSalon(
        name: state.ownerSalon.name,
        ownerName: state.ownerSalon.ownerName,
        address: state.ownerSalon.address,
        directionsUrl: state.ownerSalon.directionsUrl,
        phone: state.ownerSalon.phone,
        openTime: '12:00 AM',
        closeTime: '11:59 PM',
      );
      await state.addOwnerBarber(
        name: 'Ravi',
        phone: '9333333336',
        speciality: 'Haircut specialist',
        experienceYears: 4,
        resumeSummary: 'Instant cuts.',
        serviceIds: [service.id],
      );
      final salonId = state.ownerSalon.id;
      await state.signOutActiveUser();
      await state.loginCustomerWithPhone(
        phone: '9876543200',
        verificationId: 'test-verification',
        smsCode: '123456',
      );

      final first = await state.createInstantBooking(
        salonId: salonId,
        serviceId: service.id,
        arrivalMinutes: 20,
      );

      expect(state.activeInstantBooking?.id, first.id);
      expect(state.activeCustomerBooking?.id, first.id);
      expect(
        () => state.createInstantBooking(
          salonId: salonId,
          serviceId: service.id,
          arrivalMinutes: 25,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('current booking'),
          ),
        ),
      );
      expect(
        () => state.createBooking(
          slot: TimeSlot(
            salonId: salonId,
            serviceId: service.id,
            barberId: first.barberId,
            start: DateTime.now().add(const Duration(days: 1)),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('current booking'),
          ),
        ),
      );

      await state.cancelBooking(first.id, reason: 'Cannot reach the salon');
      final cancelled = state.bookings.singleWhere(
        (booking) => booking.id == first.id,
      );
      expect(cancelled.status, BookingStatus.cancelled);
      expect(cancelled.cancellationReason, 'Cannot reach the salon');
      expect(cancelled.cancelledBy, 'customer');
      expect(state.activeInstantBooking, isNull);
      expect(state.activeCustomerBooking, isNull);

      final replacement = await state.createInstantBooking(
        salonId: salonId,
        serviceId: service.id,
        arrivalMinutes: 15,
      );
      expect(replacement.status, BookingStatus.pending);
      expect(replacement.id, isNot(first.id));
    },
  );

  test(
    'a pending instant request stays available to a different customer',
    () async {
      final state = await _stateWithSalonService(signOut: false);
      final service = state.ownerSalon.services.single;
      await state.updateOwnerSalon(
        name: state.ownerSalon.name,
        ownerName: state.ownerSalon.ownerName,
        address: state.ownerSalon.address,
        directionsUrl: state.ownerSalon.directionsUrl,
        phone: state.ownerSalon.phone,
        openTime: '12:00 AM',
        closeTime: '11:59 PM',
      );
      await state.addOwnerBarber(
        name: 'Ravi',
        phone: '9333333340',
        speciality: 'Haircut specialist',
        experienceYears: 4,
        resumeSummary: 'Instant cuts.',
        serviceIds: [service.id],
      );
      final salonId = state.ownerSalon.id;
      await state.signOutActiveUser();
      await state.loginCustomerWithPhone(
        name: 'First customer',
        phone: '9876543210',
        verificationId: 'first-verification',
        smsCode: '123456',
      );
      final first = await state.createInstantBooking(
        salonId: salonId,
        serviceId: service.id,
        arrivalMinutes: 15,
      );

      await state.signOutActiveUser();
      await state.loginCustomerWithPhone(
        name: 'Second customer',
        phone: '9876543211',
        verificationId: 'second-verification',
        smsCode: '123456',
      );

      expect(
        state.isInstantBookingAvailable(
          salonId,
          serviceId: service.id,
          arrivalMinutes: 15,
        ),
        isTrue,
      );
      final second = await state.createInstantBooking(
        salonId: salonId,
        serviceId: service.id,
        arrivalMinutes: 15,
      );
      expect(second.id, isNot(first.id));
      expect(second.status, BookingStatus.pending);
    },
  );

  testWidgets('instant countdown starts while salon response is pending', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      directionsUrl: state.ownerSalon.directionsUrl,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
    );
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9333333335',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Instant cuts.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await state.loginCustomerWithEmail(
      name: 'Customer',
      email: 'instant-timer@example.com',
    );
    final booking = await state.createInstantBooking(
      salonId: salonId,
      serviceId: service.id,
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: MyBookingsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Instant request · waiting for salon'), findsOneWidget);
    expect(find.textContaining('Reach the salon in'), findsWidgets);

    await state.updateBookingStatus(booking.id, BookingStatus.confirmed);
    await tester.pump();

    expect(find.textContaining('Starts in'), findsOneWidget);
  });

  testWidgets('salon instant arrival countdown uses whole minutes', (
    tester,
  ) async {
    final booking = Booking(
      id: 'minute-timer',
      salonId: 'salon',
      serviceId: 'service',
      barberId: 'barber',
      customerName: 'Customer',
      customerPhone: '+919876543210',
      start: DateTime.now().add(const Duration(minutes: 15)),
      status: BookingStatus.confirmed,
      createdAt: DateTime.now(),
      isInstant: true,
      arrivalMinutes: 15,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: BookingArrivalBottomPanel(
            booking: booking,
            audience: BookingTimerAudience.salon,
            onTap: () {},
          ),
        ),
      ),
    );

    final timerText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .firstWhere((text) => text.contains('Customer ETA'));
    expect(timerText, contains('min'));
    expect(RegExp(r'\d{2}:\d{2}').hasMatch(timerText), isFalse);
  });

  testWidgets('accepted booking opens a full-screen customer confirmation', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      directionsUrl: state.ownerSalon.directionsUrl,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
    );
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9333333341',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Customer bookings.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    final barber = state.barbersForSalon(salonId).single;
    await state.signOutActiveUser();
    await state.loginCustomerWithPhone(
      name: 'Mayur',
      phone: '9876543212',
      verificationId: 'confirmation-verification',
      smsCode: '123456',
    );
    final booking = await state.createBooking(
      slot: TimeSlot(
        salonId: salonId,
        serviceId: service.id,
        barberId: barber.id,
        start: DateTime.now().add(const Duration(hours: 2)),
      ),
    );
    await state.updateBookingStatus(booking.id, BookingStatus.confirmed);

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(
          home: CustomerBookingConfirmationGate(child: Scaffold()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Booking confirmed'), findsWidgets);
    expect(
      find.textContaining('accepted your Haircut booking'),
      findsOneWidget,
    );
  });

  test('instant booking toggle pauses today and resets next day', () async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      directionsUrl: state.ownerSalon.directionsUrl,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
    );
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9333333334',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: 'Instant cuts.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    expect(
      state.isInstantBookingAvailable(salonId, serviceId: service.id),
      isTrue,
    );

    await state.setOwnerInstantBookingEnabled(false);

    expect(state.isInstantBookingEnabled(salonId), isFalse);
    expect(
      state.isInstantBookingAvailable(salonId, serviceId: service.id),
      isFalse,
    );
    expect(
      state.isInstantBookingEnabled(
        salonId,
        now: DateTime.now().add(const Duration(days: 1)),
      ),
      isTrue,
    );
  });

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

  testWidgets('owner chooses opening and closing hours with time pickers', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonProfileSetupScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final opening = find.widgetWithText(TextFormField, 'Opening');
    final closing = find.widgetWithText(TextFormField, 'Closing');
    expect(opening, findsOneWidget);
    expect(closing, findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: opening, matching: find.byType(EditableText)),
          )
          .readOnly,
      isTrue,
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: closing, matching: find.byType(EditableText)),
          )
          .readOnly,
      isTrue,
    );

    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await tester.pumpAndSettle();
    await tester.ensureVisible(opening);
    await tester.pumpAndSettle();
    await tester.tap(opening);
    await tester.pumpAndSettle();
    expect(find.text('SELECT OPENING TIME'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
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
    await state.signOutActiveUser();
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

    final overdueRequest = base.copyWith(
      start: now.subtract(const Duration(minutes: 1)),
    );
    expect(
      state.salonBookingBucket(overdueRequest, now: now),
      SalonBookingBucket.requests,
    );
    expect(
      state.salonBookingOutcome(overdueRequest, now: now),
      'Waiting for owner action',
    );

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

  test('owner ringtone session is disabled outside owner login', () async {
    final state = AppState();
    const preferenceKey = 'pritze.notifications.ownerAlertsEnabled';

    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
    await Future<void>.delayed(Duration.zero);
    var preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(preferenceKey), isTrue);

    await state.selectRole(UserRole.customer);
    preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(preferenceKey), isFalse);

    await state.selectRole(UserRole.owner);
    await state.signOutActiveUser();
    preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(preferenceKey), isFalse);
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
    expect(find.text('Booking confirmed'), findsWidgets);
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
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await state.updateBookingStatus(booking.id, BookingStatus.confirmed);
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

    expect(find.text('You are booked for this time'), findsOneWidget);
    expect(unreadNotificationCount(state, UserRole.barber), 0);

    await state.updateBookingStatus(booking.id, BookingStatus.cancelled);
    await tester.pumpAndSettle();
    expect(unreadNotificationCount(state, UserRole.barber), 1);

    expect(find.text('Your booking was cancelled'), findsOneWidget);
  });

  testWidgets('partner hub hides the public barber login path', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: PartnerHubScreen()),
      ),
    );

    expect(find.text('Salon owner'), findsOneWidget);
    expect(find.text('Barber'), findsNothing);
    expect(find.text('Open barber tools'), findsNothing);
    expect(find.text('Barber login'), findsNothing);
  });

  testWidgets('barber screen points staff to owner-managed setup', (
    tester,
  ) async {
    final state = AppState();
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );

    expect(find.text('TEAM ACCESS'), findsOneWidget);
    expect(find.text('Barbers are added by the salon owner'), findsOneWidget);
    expect(find.text('Continue as Barber'), findsNothing);
    expect(find.text('Barber login'), findsNothing);
  });

  testWidgets('owner authentication offers phone, email, and Gmail', (
    tester,
  ) async {
    final state = AppState();
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phone number'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    await tester.tap(find.text('Email'));
    await tester.pumpAndSettle();

    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    expect(find.text('Continue with Gmail'), findsOneWidget);
    expect(find.text('Owner name'), findsNothing);
  });

  testWidgets('customer authentication only offers mobile OTP', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AuthLoginPanel(role: UserRole.customer)),
      ),
    );

    expect(find.byKey(const ValueKey('phone-login-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('customer-name-field')), findsOneWidget);
    expect(find.text('Phone number'), findsOneWidget);
    expect(find.text('Email'), findsNothing);
    expect(find.byKey(const ValueKey('email-login-field')), findsNothing);
    expect(find.text('Continue with Gmail'), findsNothing);

    final nameField = tester.widget<TextField>(
      find.byKey(const ValueKey('customer-name-field')),
    );
    final phoneField = tester.widget<TextField>(
      find.byKey(const ValueKey('phone-login-field')),
    );
    expect(nameField.autofillHints, contains(AutofillHints.name));
    expect(phoneField.autofillHints, contains(AutofillHints.telephoneNumber));
  });

  testWidgets('customer OTP completion invokes the login callback', (
    tester,
  ) async {
    final state = AppState();
    var loginCompleted = false;
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: MaterialApp(
          home: Scaffold(
            body: AuthLoginPanel(
              role: UserRole.customer,
              onLoggedIn: () => loginCompleted = true,
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('customer-name-field')),
      'Mayur',
    );
    await tester.enterText(
      find.byKey(const ValueKey('phone-login-field')),
      '9876543210',
    );
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('phone-otp-field')),
      '123456',
    );
    await tester.tap(find.text('Verify and sign in'));
    await tester.pump();

    expect(loginCompleted, isTrue);
    expect(state.hasActiveCustomerSession, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone OTP can be resent after the cooldown', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(
          home: Scaffold(body: AuthLoginPanel(role: UserRole.customer)),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('customer-name-field')),
      'Mayur',
    );
    await tester.enterText(
      find.byKey(const ValueKey('phone-login-field')),
      '9876543210',
    );
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.byKey(const ValueKey('phone-otp-field')), findsOneWidget);
    expect(find.text('Resend in 30s'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('resend-phone-otp-button')),
          )
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Resend code'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('resend-phone-otp-button')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const ValueKey('resend-phone-otp-button')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Resend in 30s'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('change-phone-number-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('phone-otp-field')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('phone-login-field')))
          .readOnly,
      isFalse,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('email OTP validates six digits and signs in from keyboard', (
    tester,
  ) async {
    final state = AppState();
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(
          home: Scaffold(body: AuthLoginPanel(role: UserRole.owner)),
        ),
      ),
    );

    await tester.tap(find.text('Email'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('email-login-field')),
      'customer@example.com',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    final otpField = find.byKey(const ValueKey('email-otp-field'));
    expect(otpField, findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.enterText(otpField, '12');
    tester.widget<TextField>(otpField).onSubmitted?.call('12');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Enter the 6-digit code from your email'), findsOneWidget);
    expect(state.hasActiveOwnerSession, isFalse);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.enterText(otpField, '123456');
    tester.widget<TextField>(otpField).onSubmitted?.call('123456');
    await tester.pumpAndSettle();
    expect(state.hasActiveOwnerSession, isTrue);
  });

  test('phone OTP login is available for customer and owner', () async {
    final state = AppState();
    final verificationId = await state.sendPhoneOtp(phone: '9876543210');
    expect(verificationId, contains('+919876543210'));

    final customer = await state.loginCustomerWithPhone(
      name: 'Mayur',
      phone: '9876543210',
      verificationId: verificationId,
      smsCode: '123456',
    );
    expect(customer.provider, LoginProvider.phone);
    expect(customer.name, 'Mayur');
    expect(customer.contact, '+919876543210');

    final owner = await state.loginOwnerWithPhone(
      phone: '9876543211',
      verificationId: verificationId,
      smsCode: '123456',
    );
    expect(owner.provider, LoginProvider.phone);
    expect(owner.contact, '+919876543211');
  });

  test('Gmail owner contact is not used as the salon phone number', () async {
    final state = AppState();

    await state.loginOwnerWithGmail(name: 'Mayur', email: 'mayur@gmail.com');

    expect(state.ownerSalon.phone, isEmpty);
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

class _RestoringAppState extends AppState {
  @override
  bool get isRestoringSession => true;
}
