import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:nashik_salon_booking/main.dart';
import 'package:nashik_salon_booking/models/app_models.dart';
import 'package:nashik_salon_booking/models/service_catalog.dart';
import 'package:nashik_salon_booking/screens/barber/barber_dashboard_screen.dart';
import 'package:nashik_salon_booking/screens/customer/customer_home_screen.dart';
import 'package:nashik_salon_booking/screens/customer/customer_profile_editor.dart';
import 'package:nashik_salon_booking/screens/customer/customer_profile_screen.dart';
import 'package:nashik_salon_booking/screens/customer/my_bookings_screen.dart';
import 'package:nashik_salon_booking/screens/customer/salon_booking_screen.dart';
import 'package:nashik_salon_booking/screens/customer/salon_detail_screen.dart';
import 'package:nashik_salon_booking/screens/partner/partner_hub_screen.dart';
import 'package:nashik_salon_booking/screens/salon/salon_dashboard_screen.dart';
import 'package:nashik_salon_booking/screens/salon/salon_profile_setup_screen.dart';
import 'package:nashik_salon_booking/services/android_phone_hint.dart';
import 'package:nashik_salon_booking/state/app_state.dart';
import 'package:nashik_salon_booking/state/app_state_scope.dart';
import 'package:nashik_salon_booking/widgets/account_actions.dart';
import 'package:nashik_salon_booking/widgets/auth_login_panel.dart';
import 'package:nashik_salon_booking/widgets/booking_status_timeline.dart';
import 'package:nashik_salon_booking/widgets/customer_booking_confirmation_gate.dart';
import 'package:nashik_salon_booking/widgets/app_update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('uses the configured Pritze support number by default', () {
    expect(AppState().supportPhone, '+91 89996 08278');
  });

  test('phone hints normalize Indian SIM number formats', () {
    expect(indianMobileDigitsFromHint('+91 98765 43210'), '9876543210');
    expect(indianMobileDigitsFromHint('09876543210'), '9876543210');
    expect(indianMobileDigitsFromHint('9876543210'), '9876543210');
    expect(indianMobileDigitsFromHint('+1 555 123 4567'), isNull);
  });

  test('app update prompt compares platform build numbers', () {
    expect(shouldShowAppUpdate(installedBuild: 24, latestBuild: 25), isTrue);
    expect(shouldShowAppUpdate(installedBuild: 24, latestBuild: 24), isFalse);
    expect(appUpdateRetryDelays, const [
      Duration(seconds: 4),
      Duration(seconds: 15),
    ]);
  });

  test('app update prompt compares published iOS versions', () {
    expect(isNewerAppVersion(installed: '1.0.15', available: '1.0.16'), isTrue);
    expect(isNewerAppVersion(installed: '1.0.15', available: '1.1.0'), isTrue);
    expect(
      isNewerAppVersion(installed: '1.0.15', available: '1.0.15'),
      isFalse,
    );
    expect(
      isNewerAppVersion(installed: '1.0.15', available: '1.0.14'),
      isFalse,
    );
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
    expect(find.text('No salons found'), findsOneWidget);
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

  testWidgets('customer home keeps incomplete salon listings visible', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();

    expect(state.isSalonBookable(salonId), isFalse);
    expect(
      state.discoverableSalons.any((salon) => salon.id == salonId),
      isTrue,
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: CustomerHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pritze Cuts'), findsOneWidget);
    expect(
      find.text('Listing visible · booking setup in progress'),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('salon-card-image-$salonId')), findsOneWidget);
    expect(find.text('Schedule Slot'), findsOneWidget);
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

  testWidgets(
    'customer can select multiple services and salons must offer all of them',
    (tester) async {
      final state = AppState();
      await state.loginOwnerWithEmail(
        name: 'Complete owner',
        email: 'complete@example.com',
      );
      await state.updateOwnerSalon(
        name: 'Complete Salon',
        ownerName: 'Complete owner',
        address: 'College Road, Nashik',
        phone: '9000000101',
        openTime: '9:00 AM',
        closeTime: '8:00 PM',
      );
      await state.addOwnerService(
        name: 'Classic Haircut',
        category: 'Hair',
        price: 250,
        durationMinutes: 30,
      );
      await state.addOwnerService(
        name: 'Glow Facial',
        category: 'Facial',
        price: 600,
        durationMinutes: 45,
      );
      await state.signOutActiveUser();
      await state.loginOwnerWithEmail(
        name: 'Hair owner',
        email: 'hair-only@example.com',
      );
      await state.updateOwnerSalon(
        name: 'Hair Only Salon',
        ownerName: 'Hair owner',
        address: 'Main Road, Nashik',
        phone: '9000000102',
        openTime: '9:00 AM',
        closeTime: '8:00 PM',
      );
      await state.addOwnerService(
        name: 'Basic Haircut',
        category: 'Hair',
        price: 200,
        durationMinutes: 30,
      );
      await state.signOutActiveUser();

      await tester.pumpWidget(
        AppStateProvider(
          createAppState: () => state,
          child: const MaterialApp(home: CustomerHomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final categories = find.byKey(const Key('service-category-list'));
      await tester.tap(
        find.descendant(of: categories, matching: find.text('Haircut')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: categories, matching: find.text('Facial')),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 services selected'), findsOneWidget);
      expect(find.text('Complete Salon'), findsOneWidget);
      expect(find.text('College Road, Nashik'), findsOneWidget);
      expect(find.text('Hair Only Salon'), findsNothing);
      expect(find.text('Nearby'), findsNothing);
    },
  );

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
    expect(tester.widget<Text>(find.text('Haircut')).style?.fontSize, 13);

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
    expect(find.text('Schedule Slot'), findsOneWidget);
    expect(find.textContaining('shops'), findsNothing);
  });

  testWidgets('homepage instant booking opens a standalone services page', (
    tester,
  ) async {
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
      name: 'Instant barber',
      phone: '9888888891',
      speciality: 'Hair',
      experienceYears: 2,
      resumeSummary: 'Instant bookings.',
      serviceIds: [service.id],
    );
    await state.signOutActiveUser();

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: CustomerHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final instantButton = find.text('Book instantly');
    await tester.ensureVisible(instantButton);
    await tester.pumpAndSettle();
    await tester.tap(instantButton);
    await tester.pumpAndSettle();

    expect(find.byType(InstantServiceSelectionScreen), findsOneWidget);
    expect(find.byType(SalonDetailScreen), findsNothing);
    expect(find.text('Choose instant services'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(CustomerHomeScreen), findsOneWidget);
  });

  testWidgets('salon detail offers direct barber picker without scrolling', (
    tester,
  ) async {
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
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byIcon(Icons.near_me_outlined), findsNothing);
    expect(find.textContaining('Nearby'), findsNothing);
    await tester.tap(find.text('Pick barber'));
    await tester.pumpAndSettle();

    expect(find.text('Choose your barber'), findsOneWidget);
    expect(find.text('Ravi'), findsOneWidget);

    await tester.tap(find.text('Ravi'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a service'), findsOneWidget);

    await tester.tap(find.text(service.name));
    await tester.pumpAndSettle();

    expect(find.byType(SalonBookingScreen), findsOneWidget);
    expect(find.text('Book slot'), findsOneWidget);
    expect(
      tester
          .widget<SalonBookingScreen>(find.byType(SalonBookingScreen))
          .initialBarberId,
      state.barbersForSalon(state.ownerSalon.id).single.id,
    );
    expect(
      tester
          .widget<SalonBookingScreen>(find.byType(SalonBookingScreen))
          .instantOnly,
      isFalse,
    );
    expect(find.text('Available slots'), findsOneWidget);
    expect(find.text('Choose barber'), findsNothing);
    expect(find.text('Request instant booking'), findsNothing);
  });

  testWidgets('customer barber picker shows every active salon barber', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    for (var index = 1; index <= 4; index += 1) {
      await state.addOwnerBarber(
        name: 'Barber $index',
        phone: '98888887${index.toString().padLeft(2, '0')}',
        speciality: 'Team member',
        experienceYears: index,
        resumeSummary: 'Salon team member.',
        serviceIds: index <= 2 ? [service.id] : const [],
      );
    }

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: MaterialApp(
          home: SalonDetailScreen(salonId: state.ownerSalon.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('4 available'), findsOneWidget);
    await tester.tap(find.text('Pick barber'));
    await tester.pumpAndSettle();

    final barberList = find.descendant(
      of: find.byType(FractionallySizedBox),
      matching: find.byType(Scrollable),
    );
    expect(barberList, findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Barber 4'),
      160,
      scrollable: barberList,
    );
    expect(find.text('Barber 4'), findsOneWidget);
  });

  testWidgets('only the dedicated instant action opens instant booking', (
    tester,
  ) async {
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
      name: 'Instant barber',
      phone: '9888888806',
      speciality: 'Instant services',
      experienceYears: 2,
      resumeSummary: 'Instant test.',
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
    await tester.tap(find.text('Book instantly'));
    await tester.pumpAndSettle();

    expect(find.text('Choose instant services'), findsOneWidget);
    await tester.tap(find.text(service.name));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('continue-instant-services')));
    await tester.pumpAndSettle();

    final bookingScreen = tester.widget<SalonBookingScreen>(
      find.byType(SalonBookingScreen),
    );
    expect(bookingScreen.instantOnly, isTrue);
    expect(find.text('Request instant booking'), findsOneWidget);
    expect(find.text('Choose barber'), findsNothing);
    expect(find.text('Available slots'), findsNothing);
    expect(find.textContaining('any available barber'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Book for ₹0'), findsNothing);
  });

  testWidgets('closed salons expose services but block appointment entry', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '12:01 AM',
    );
    await state.addOwnerBarber(
      name: 'Closed salon barber',
      phone: '9888888815',
      speciality: 'Hair',
      experienceYears: 3,
      resumeSummary: 'Closed salon test.',
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
    await tester.tap(find.text('Pick service'));
    await tester.pumpAndSettle();
    expect(find.text(service.name), findsOneWidget);
    await tester.tap(find.text(service.name));
    await tester.pumpAndSettle();

    expect(find.text('Salon is closed'), findsOneWidget);
    expect(find.byType(SalonBookingScreen), findsNothing);
  });

  testWidgets('salon card body opens the complete action preview', (
    tester,
  ) async {
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
      name: 'Preview barber',
      phone: '9888888816',
      speciality: 'Hair',
      experienceYears: 3,
      resumeSummary: 'Preview test.',
      serviceIds: [service.id],
    );
    await state.signOutActiveUser();

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: CustomerHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pritze Cuts'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('salon-preview-call')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('salon-preview-directions')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('salon-preview-schedule-slot')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('salon-preview-book-instantly')),
      findsOneWidget,
    );
  });

  testWidgets('salon card schedule action bypasses the preview sheet', (
    tester,
  ) async {
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
      name: 'Schedule barber',
      phone: '9888888817',
      speciality: 'Hair',
      experienceYears: 3,
      resumeSummary: 'Schedule test.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: CustomerHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final scheduleButton = find.byKey(ValueKey('salon-card-schedule-$salonId'));
    await tester.ensureVisible(scheduleButton);
    await tester.pumpAndSettle();
    await tester.tap(scheduleButton);
    await tester.pumpAndSettle();

    expect(find.text('Choose a service'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('salon-preview-book-instantly')),
      findsNothing,
    );

    await tester.tap(find.text(service.name));
    await tester.pumpAndSettle();
    expect(find.byType(SalonBookingScreen), findsOneWidget);
    expect(find.text('Choose barber'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(CustomerHomeScreen), findsOneWidget);
    expect(find.byType(SalonDetailScreen), findsNothing);
  });

  test('instant booking preserves multiple selected services', () async {
    final state = await _stateWithSalonService(signOut: false);
    final first = state.ownerSalon.services.single;
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
    );
    await state.addOwnerService(
      name: 'Beard trim',
      category: 'Beard',
      price: 120,
      durationMinutes: 15,
    );
    final second = state.ownerSalon.services.last;
    await state.addOwnerBarber(
      name: 'Multi service barber',
      phone: '9888888817',
      speciality: 'Hair and beard',
      experienceYears: 4,
      resumeSummary: 'Multi service test.',
      serviceIds: [first.id, second.id],
    );
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await _loginCustomer(state);

    final booking = await state.createInstantBooking(
      salonId: salonId,
      serviceIds: [first.id, second.id],
      arrivalMinutes: 15,
    );

    expect(booking.resolvedServiceIds, [first.id, second.id]);
    expect(booking.serviceName, 'Haircut, Beard trim');
    expect(booking.durationMinutes, 45);
    expect(booking.servicePrice, 320);
    expect(booking.barberId, isEmpty);
  });

  testWidgets('picking a service opens scheduled slots, not instant booking', (
    tester,
  ) async {
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
      name: 'Scheduled barber',
      phone: '9888888807',
      speciality: 'Scheduled services',
      experienceYears: 2,
      resumeSummary: 'Scheduled test.',
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
    await tester.tap(find.text('Pick service'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(service.name));
    await tester.pumpAndSettle();

    final bookingScreen = tester.widget<SalonBookingScreen>(
      find.byType(SalonBookingScreen),
    );
    expect(bookingScreen.instantOnly, isFalse);
    expect(find.text('Available slots'), findsOneWidget);
    expect(find.text('Request instant booking'), findsNothing);
  });

  testWidgets('salon service picker searches only the salon service list', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    await state.updateOwnerSalon(
      name: state.ownerSalon.name,
      ownerName: state.ownerSalon.ownerName,
      address: state.ownerSalon.address,
      phone: state.ownerSalon.phone,
      openTime: '12:00 AM',
      closeTime: '11:59 PM',
    );
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Search barber',
      phone: '9888888805',
      speciality: 'Service specialist',
      experienceYears: 2,
      resumeSummary: 'Search test.',
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
    await tester.tap(find.text('Pick service'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('salon-service-search-field')),
      findsOneWidget,
    );
    expect(find.text(service.name), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('salon-service-search-field')),
      'not offered here',
    );
    await tester.pumpAndSettle();
    expect(find.text(service.name), findsNothing);
    expect(find.text('No matching services'), findsOneWidget);
  });

  testWidgets('owner overview and team omit legacy chair and join requests', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Chair board'), findsNothing);

    await tester.tap(find.text('Team'));
    await tester.pumpAndSettle();

    expect(find.text('Join requests'), findsNothing);
    expect(find.text('No pending requests right now.'), findsNothing);
    expect(find.text('Team members'), findsOneWidget);
  });

  testWidgets('owner can open and save an existing barber profile', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final serviceId = state.ownerSalon.services.single.id;
    await state.addOwnerBarber(
      name: 'Original barber',
      phone: '9000000011',
      speciality: 'Haircut specialist',
      experienceYears: 2,
      resumeSummary: 'Original profile.',
      serviceIds: [serviceId],
    );
    final barber = state.barbersForSalon(state.ownerSalon.id).single;

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('edit-barber-${barber.id}')));
    await tester.pumpAndSettle();

    expect(find.text('Edit barber'), findsOneWidget);
    final nameField = find.byKey(const ValueKey('barber-name-field'));
    expect(
      tester.widget<TextFormField>(nameField).controller?.text,
      'Original barber',
    );
    await tester.enterText(nameField, 'Updated barber');
    await tester.enterText(
      find.byKey(const ValueKey('barber-experience-field')),
      '6',
    );
    await tester.tap(find.byKey(const ValueKey('save-barber-changes')));
    await tester.pumpAndSettle();

    final updated = state.getBarber(barber.id)!;
    expect(updated.name, 'Updated barber');
    expect(updated.experienceYears, 6);
    expect(updated.phone, '+919000000011');
    expect(find.text('Updated barber'), findsWidgets);
  });

  testWidgets('iOS booking matches Android controls without overflow', (
    tester,
  ) async {
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
    expect(find.text('0 booking fee'), findsNothing);
    expect(find.text('Book this slot'), findsNothing);
    expect(find.text('Book for ₹0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('scheduled booking exposes a horizontal 30-day calendar', (
    tester,
  ) async {
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
      name: 'Calendar barber',
      phone: '9888888806',
      speciality: 'Scheduled services',
      experienceYears: 3,
      resumeSummary: 'Calendar test.',
      serviceIds: [service.id],
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: MaterialApp(
          home: SalonBookingScreen(salonId: salonId, serviceId: service.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final selector = find.byKey(const ValueKey('booking-date-selector'));
    final dateList = find.descendant(
      of: selector,
      matching: find.byType(ListView),
    );
    final list = tester.widget<ListView>(dateList);
    expect(list.scrollDirection, Axis.horizontal);
    expect(
      list.childrenDelegate.estimatedChildCount,
      scheduledBookingHorizonDays * 2 - 1,
    );

    final today = DateTime.now();
    final firstSlotDate = state
        .slotsForService(salonId, service.id)
        .first
        .start;
    final target =
        firstSlotDate.day == today.day &&
            firstSlotDate.month == today.month &&
            firstSlotDate.year == today.year
        ? DateTime(today.year, today.month, today.day + 1)
        : DateTime(today.year, today.month, today.day);
    final targetKey = ValueKey(
      'booking-date-${target.year}-${target.month.toString().padLeft(2, '0')}-${target.day.toString().padLeft(2, '0')}',
    );
    await tester.tap(find.byKey(targetKey));
    await tester.pumpAndSettle();

    expect(
      find.text('Available times for ${state.formatDate(target)}'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
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

  testWidgets('iOS booking action opens the Android-matched sign-in sheet', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
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

    final slotFinder = find.text(firstSlotLabel).first;
    await tester.ensureVisible(slotFinder);
    await tester.pumpAndSettle();
    await tester.tap(slotFinder);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Book for ₹0'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('booking-login-sheet')), findsOneWidget);
    expect(find.text('Complete your booking'), findsOneWidget);
    expect(find.text('₹0 booking fee'), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-login-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS completed booking shows the Android-matched confirmation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
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
    await _loginCustomer(state);
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

    final slotFinder = find.text(firstSlotLabel).first;
    await tester.ensureVisible(slotFinder);
    await tester.pumpAndSettle();
    await tester.tap(slotFinder);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Book for ₹0'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('booking-success-dialog')),
      findsOneWidget,
    );
    expect(find.text('Booking confirmed'), findsOneWidget);
    expect(find.text('BOOKING DETAILS'), findsOneWidget);
    expect(find.text('Appointment registered'), findsOneWidget);
    expect(find.text('View my bookings'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  test('barber login methods are rejected', () async {
    final state = AppState();
    await expectLater(
      state.loginBarberWithEmail(name: 'Aman', email: 'aman@example.com'),
      throwsStateError,
    );
    await expectLater(
      state.loginBarberWithGmail(name: 'Aman', email: 'aman@gmail.com'),
      throwsStateError,
    );
    await expectLater(
      state.loginBarberWithPhone(
        phone: '9876543210',
        verificationId: 'test-verification',
        smsCode: '123456',
      ),
      throwsStateError,
    );
  });

  testWidgets('customer discovery shows ready and incomplete shops', (
    tester,
  ) async {
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
    expect(find.text('Almost Ready Salon'), findsOneWidget);
    expect(
      find.text('Listing visible · booking setup in progress'),
      findsOneWidget,
    );
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
    expect(find.text('Confirmed'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BookingStatusTimeline(
            status: BookingStatus.confirmed,
            isInstant: true,
          ),
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
    await _loginCustomer(state);
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
    expect(find.text('CURRENT BOOKING'), findsOneWidget);
    expect(find.text('Haircut'), findsWidgets);
    expect(
      find.byKey(const ValueKey('booking-panel-view-action')),
      findsOneWidget,
    );
    expect(find.text('Confirmed'), findsWidgets);
    expect(find.text('Appointment'), findsOneWidget);

    await state.updateBookingStatus(booking.id, BookingStatus.confirmed);
    await tester.pump();
    expect(find.text('Confirmed'), findsWidgets);

    await tester.tap(find.text('Profile').last);
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(
      find.byKey(const Key('current-booking-bottom-panel')),
      findsOneWidget,
    );
  });

  testWidgets('customer cancellation removes all active UI immediately', (
    tester,
  ) async {
    final state = _DelayedBookingStatusAppState();
    await _stateWithSalonService(signOut: false, appState: state);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9898989897',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await _loginCustomer(state);
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

    final cancellation = state.cancelBooking(
      booking.id,
      reason: 'Plans changed',
    );
    await tester.pump();

    expect(state.activeCustomerBooking, isNull);
    expect(state.customerBookings.single.status, BookingStatus.cancelled);
    expect(find.byKey(const Key('current-booking-bottom-panel')), findsNothing);
    expect(find.text('Current booking · Haircut'), findsNothing);

    state.completeStatusWrite();
    await cancellation;
    await tester.pump();
    expect(state.customerBookings.single.status, BookingStatus.cancelled);
    expect(find.byKey(const Key('current-booking-bottom-panel')), findsNothing);
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
    await _loginCustomer(state);
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
      await _loginCustomer(state);
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
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -180));
    await tester.pumpAndSettle();
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

  testWidgets('owner can edit a displayed service price by tapping it', (
    tester,
  ) async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonProfileSetupScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Owner profile'), findsNothing);
    final price = find.byKey(ValueKey('service-price-${service.id}'));
    await tester.scrollUntilVisible(
      price,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(price);
    await tester.pumpAndSettle();
    await tester.tap(price);
    await tester.pumpAndSettle();

    final editor = find.byKey(ValueKey('service-price-editor-${service.id}'));
    expect(editor, findsOneWidget);
    await tester.enterText(editor, '575');
    await tester.tap(find.byTooltip('Save price'));
    await tester.pumpAndSettle();

    expect(state.ownerSalon.services.single.price, 575);
    expect(find.text('₹575'), findsOneWidget);
  });

  test(
    'instant booking starts its selected arrival timer on acceptance',
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
      await _loginCustomer(state);

      final booking = await state.createInstantBooking(
        salonId: salonId,
        serviceId: service.id,
        arrivalMinutes: 25,
      );

      expect(booking.isInstant, isTrue);
      expect(booking.status, BookingStatus.pending);
      expect(booking.barberId, isEmpty);
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
      expect(accepted.barberId, isNotEmpty);
      expect(accepted.start, isNot(requestedStart));
      expect(
        accepted.start.difference(accepted.acceptedAt!),
        const Duration(minutes: 25),
      );
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
        name: 'Customer',
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

  test(
    'scheduled rescheduling keeps one confirmed booking atomically',
    () async {
      final state = await _stateWithSalonService(signOut: false);
      final service = state.ownerSalon.services.single;
      await state.addOwnerBarber(
        name: 'Ravi',
        phone: '9333333350',
        speciality: 'Haircut specialist',
        experienceYears: 4,
        resumeSummary: 'Scheduled cuts.',
        serviceIds: [service.id],
      );
      final salonId = state.ownerSalon.id;
      final barber = state.barbersForSalon(salonId).single;
      await state.signOutActiveUser();
      await _loginCustomer(state, phone: '9876543250');
      final now = DateTime.now();
      final originalStart = DateTime(now.year, now.month, now.day + 1, 10);
      final newStart = DateTime(now.year, now.month, now.day + 1, 11);
      final booking = await state.createBooking(
        slot: TimeSlot(
          salonId: salonId,
          serviceId: service.id,
          barberId: barber.id,
          start: originalStart,
        ),
      );

      final updated = await state.rescheduleBooking(
        booking.id,
        slot: TimeSlot(
          salonId: salonId,
          serviceId: service.id,
          barberId: barber.id,
          start: newStart,
        ),
      );

      expect(updated.id, booking.id);
      expect(updated.status, BookingStatus.confirmed);
      expect(updated.start, newStart);
      expect(state.bookings, hasLength(1));
      expect(state.activeCustomerBooking?.id, booking.id);
    },
  );

  testWidgets('instant reach-by time appears only after salon acceptance', (
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
    await _loginCustomer(state);
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

    expect(
      find.textContaining('Waiting for the salon to accept'),
      findsOneWidget,
    );
    expect(find.textContaining('Reach by'), findsNothing);

    await state.updateBookingStatus(booking.id, BookingStatus.confirmed);
    await tester.pump();

    expect(find.textContaining('Reach by'), findsOneWidget);
    expect(find.textContaining('about 15 min remaining'), findsOneWidget);
    expect(find.textContaining('Starts in'), findsNothing);
  });

  testWidgets(
    'salon instant reach-by time includes grace without a ticking clock',
    (tester) async {
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
          .firstWhere((text) => text.contains('Expect customer by'));
      expect(timerText, contains('15 min selected'));
      expect(timerText, contains('20 min salon window'));
      expect(timerText, contains('about 20 min remaining'));
      expect(timerText, isNot(contains('within')));

      await tester.pump(const Duration(seconds: 30));
      final unchangedText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .firstWhere((text) => text.contains('Expect customer by'));
      expect(unchangedText, timerText);
    },
  );

  testWidgets('pending owner request has no arrival time before acceptance', (
    tester,
  ) async {
    final booking = Booking(
      id: 'pending-arrival',
      salonId: 'salon',
      serviceId: 'service',
      barberId: '',
      customerName: 'Customer',
      customerPhone: '+919876543210',
      start: DateTime.now().add(const Duration(minutes: 15)),
      status: BookingStatus.pending,
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

    expect(
      find.textContaining('Accept or reject this request'),
      findsOneWidget,
    );
    expect(find.textContaining('Expect customer by'), findsNothing);
    expect(find.textContaining('remaining'), findsNothing);
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
    await state.signOutActiveUser();
    await state.loginCustomerWithPhone(
      name: 'Mayur',
      phone: '9876543212',
      verificationId: 'confirmation-verification',
      smsCode: '123456',
    );
    final booking = await state.createInstantBooking(
      salonId: salonId,
      serviceId: service.id,
      arrivalMinutes: 15,
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

  test('owner can create a barber without login details', () async {
    final state = await _stateWithSalonService(signOut: false);
    final serviceId = state.ownerSalon.services.first.id;

    await state.addOwnerBarber(
      name: 'Ravi',
      speciality: 'Haircut specialist',
      experienceYears: 4,
      resumeSummary: '',
      serviceIds: const [],
    );

    final barber = state.barbersForSalon(state.ownerSalon.id).single;
    expect(barber.name, 'Ravi');
    expect(barber.phone, isEmpty);
    expect(barber.email, isEmpty);
    expect(barber.uid, isNull);
    expect(barber.serviceIds, contains(serviceId));
    expect(state.joinRequests, isEmpty);
  });

  test(
    'owner can edit barber details without changing barber identity',
    () async {
      final state = await _stateWithSalonService(signOut: false);
      final serviceId = state.ownerSalon.services.first.id;
      await state.addOwnerBarber(
        name: 'Ravi',
        phone: '9000000022',
        speciality: 'Haircut specialist',
        experienceYears: 2,
        resumeSummary: 'Old details.',
        serviceIds: [serviceId],
      );
      final original = state.barbersForSalon(state.ownerSalon.id).single;

      await state.updateOwnerBarber(
        barberId: original.id,
        name: 'Ravi Kumar',
        phone: '9000000033',
        speciality: 'Fade specialist',
        experienceYears: 7,
        resumeSummary: 'Updated details.',
        serviceIds: [serviceId],
      );

      final updated = state.getBarber(original.id)!;
      expect(updated.id, original.id);
      expect(updated.salonId, original.salonId);
      expect(updated.name, 'Ravi Kumar');
      expect(updated.phone, '+919000000033');
      expect(updated.speciality, 'Fade specialist');
      expect(updated.experienceYears, 7);
      expect(updated.resumeSummary, 'Updated details.');
      expect(updated.serviceIds, [serviceId]);
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
    final customer = await _loginCustomer(state);
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
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastBookableDate = today.add(
      const Duration(days: scheduledBookingHorizonDays - 1),
    );
    final latestSlotDate = slots
        .map(
          (slot) => DateTime(slot.start.year, slot.start.month, slot.start.day),
        )
        .reduce((a, b) => a.isAfter(b) ? a : b);
    expect(latestSlotDate, lastBookableDate);
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
        openTime: '12:00 AM',
        closeTime: '11:59 PM',
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
      await _loginCustomer(state);
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

    await tester.tap(find.text('Profile'));
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
    await _loginCustomer(state);
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
    await _loginCustomer(state);
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );

    await state.updateBookingStatus(booking.id, BookingStatus.inProgress);
    expect(state.currentBookingForBarber(barber.id)?.id, booking.id);
    expect(state.totalCollection(salonId), 0);
    expect(
      state.bookings.singleWhere((item) => item.id == booking.id).startedAt,
      isNotNull,
    );

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
      isInstant: true,
    );

    expect(
      state.salonBookingBucket(base, now: now),
      SalonBookingBucket.requests,
    );
    expect(state.salonBookingOutcome(base, now: now), 'Instant request');

    final overdueRequest = base.copyWith(
      start: now.subtract(const Duration(minutes: 1)),
    );
    expect(
      state.salonBookingBucket(overdueRequest, now: now),
      SalonBookingBucket.requests,
    );
    expect(
      state.salonBookingOutcome(overdueRequest, now: now),
      'Instant request',
    );

    final scheduled = base.copyWith(
      status: BookingStatus.confirmed,
      isInstant: false,
    );
    expect(
      state.salonBookingBucket(scheduled, now: now),
      SalonBookingBucket.upcoming,
    );
    expect(state.salonBookingOutcome(scheduled, now: now), 'Registered');

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
    await _loginCustomer(state);
    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.byType(CustomerProfileScreen), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('customer-profile-logout')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('customer-profile-logout')));
    await tester.pumpAndSettle();

    expect(find.text('Log out?'), findsOneWidget);
    expect(state.hasActiveCustomerSession, isTrue);

    await tester.tap(find.text('Stay logged in'));
    await tester.pumpAndSettle();
    expect(state.hasActiveCustomerSession, isTrue);

    await tester.ensureVisible(
      find.byKey(const ValueKey('customer-profile-logout')),
    );
    await tester.tap(find.byKey(const ValueKey('customer-profile-logout')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();

    expect(state.hasActiveCustomerSession, isFalse);
  });

  testWidgets('customer can edit personal and style profile details', (
    tester,
  ) async {
    final state = AppState();
    await _loginCustomer(state);
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: CustomerProfileScreen()),
      ),
    );

    expect(find.text('Ratings from salons'), findsOneWidget);
    expect(find.text('Feedback you shared'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('edit-customer-profile')));
    await tester.pumpAndSettle();

    expect(find.byType(CustomerProfileEditor), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-customer-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-customer-phone')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-customer-gender')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('edit-customer-birthdate')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('edit-customer-name')),
      'Updated Customer',
    );
    await tester.enterText(
      find.byKey(const ValueKey('edit-customer-phone')),
      '9876500001',
    );
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Fade'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Fade'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('save-customer-profile')),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('save-customer-profile')));
    await tester.pumpAndSettle();

    expect(state.customerAccount?.name, 'Updated Customer');
    expect(state.customerAccount?.contact, '+919876500001');
    expect(state.customerAccount?.preferredStyles, contains('Fade'));
  });

  test('completed visits support feedback in both directions', () async {
    final state = await _stateWithSalonService(signOut: false);
    final service = state.ownerSalon.services.single;
    await state.addOwnerBarber(
      name: 'Ravi',
      phone: '9898989896',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Haircuts.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await _loginCustomer(state);
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await state.updateBookingStatus(booking.id, BookingStatus.inProgress);
    await state.updateBookingStatus(booking.id, BookingStatus.completed);
    await state.submitSalonFeedback(
      bookingId: booking.id,
      rating: 5,
      note: 'Clean and friendly.',
    );
    expect(state.customerSalonFeedback.single.rating, 5);

    await state.signOutActiveUser();
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
    await state.submitCustomerRating(
      bookingId: booking.id,
      rating: 4,
      note: 'Arrived on time.',
    );
    expect(state.customerSalonRatings.single.rating, 4);
  });

  test('owner ringtone session is disabled outside owner login', () async {
    final state = AppState();
    const preferenceKey = 'pritze.notifications.ownerAlertsEnabled';

    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
    await Future<void>.delayed(Duration.zero);
    var preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(preferenceKey), isTrue);

    await expectLater(state.selectRole(UserRole.customer), throwsStateError);
    preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(preferenceKey), isTrue);

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
    await _loginCustomer(state);
    final booking = await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );
    await tester.pumpWidget(
      AppStateProvider(createAppState: () => state, child: const TrimtimeApp()),
    );

    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(unreadNotificationCount(state, UserRole.customer), 1);
    await tester.tap(find.byTooltip('Customer notifications'));
    await tester.pumpAndSettle();

    expect(find.text('Booking confirmed'), findsOneWidget);
    expect(unreadNotificationCount(state, UserRole.customer), 0);

    await tester.tap(find.byTooltip('Delete notification'));
    await tester.pumpAndSettle();
    expect(find.text('No notifications yet'), findsOneWidget);
    expect(notificationKeys(state, UserRole.customer), isEmpty);

    await state.cancelBooking(booking.id, reason: 'Plans changed');
    await tester.pumpAndSettle();
    expect(find.text('You cancelled the booking'), findsOneWidget);
    expect(unreadNotificationCount(state, UserRole.customer), 1);
  });

  test('notification badge waits for persisted read state', () async {
    final state = _NotificationPreferencesLoadingState();
    await _stateWithSalonService(appState: state, signOut: false);
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
    await _loginCustomer(state);
    await state.createBooking(
      slot: state.slotsForService(salonId, service.id).first,
    );

    expect(notificationKeys(state, UserRole.customer), isNotEmpty);
    expect(unreadNotificationCount(state, UserRole.customer), 0);
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
    await _loginCustomer(state);
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

    expect(find.text('New scheduled booking'), findsOneWidget);
    expect(find.text('Booking request sent'), findsNothing);
    expect(unreadNotificationCount(state, UserRole.owner), 0);

    await tester.tap(find.text('New scheduled booking'));
    await tester.pumpAndSettle();
    expect(find.text('Booking desk'), findsOneWidget);
  });

  testWidgets('owner instant notification opens the Requests booking bucket', (
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
      phone: '9898989802',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Instant services.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await _loginCustomer(state, phone: '9876500002');
    await state.createInstantBooking(salonId: salonId, serviceId: service.id);
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');

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
    await tester.tap(find.text('New instant booking request'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ChoiceChip, 'Requests (1)'), findsOneWidget);
    expect(find.text('Accept booking'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });

  test('notification navigation signals are consumed exactly once', () {
    final state = AppState();
    state.queueNotificationNavigation(
      AppNotificationDestination.bookings,
      bookingId: 'booking-1',
    );

    final navigation = state.takePendingNotificationNavigation();
    expect(navigation?.destination, AppNotificationDestination.bookings);
    expect(navigation?.bookingId, 'booking-1');
    expect(state.takePendingNotificationNavigation(), isNull);
  });

  testWidgets('owner can respond to an instant request from Bookings', (
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
      phone: '9898989801',
      speciality: 'Haircut specialist',
      experienceYears: 3,
      resumeSummary: 'Instant services.',
      serviceIds: [service.id],
    );
    final salonId = state.ownerSalon.id;
    await state.signOutActiveUser();
    await _loginCustomer(state, phone: '9876500001');
    final booking = await state.createInstantBooking(
      salonId: salonId,
      serviceId: service.id,
      arrivalMinutes: 15,
    );
    await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
    state.queueNotificationNavigation(
      AppNotificationDestination.bookings,
      bookingId: booking.id,
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ChoiceChip, 'Requests (1)'), findsOneWidget);
    expect(find.text('Accept booking'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Any available barber'), findsOneWidget);

    await tester.ensureVisible(find.text('Accept booking'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept booking'));
    await tester.pump();
    final accepted = state.bookings.singleWhere(
      (item) => item.id == booking.id,
    );
    expect(accepted.status, BookingStatus.confirmed);
    expect(accepted.barberId, isNotEmpty);
    expect(find.text('Accept booking'), findsNothing);
    expect(
      find.byKey(const ValueKey('booking-arrival-bottom-panel-salon')),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(find.text('Start service'), findsOneWidget);

    await tester.ensureVisible(find.text('Start service'));
    await tester.drag(find.byType(ListView).last, const Offset(0, -220));
    await tester.pump();
    await tester.tap(find.text('Start service'));
    await tester.pump();
    expect(find.text('Starting...'), findsNothing);
    expect(find.text('Complete service'), findsOneWidget);
    expect(state.totalCollection(salonId), 0);

    await tester.tap(find.text('Complete service'));
    await tester.pump();
    final completed = state.bookings.singleWhere(
      (item) => item.id == booking.id,
    );
    expect(completed.status, BookingStatus.completed);
    expect(state.totalCollection(salonId), service.price);
  });

  test('customer email is rejected and Gmail saves a supplied phone', () async {
    final state = AppState();

    await expectLater(
      state.loginCustomerWithEmail(name: 'Asha', email: 'asha@example.com'),
      throwsStateError,
    );
    await expectLater(
      state.loginCustomerWithGmail(name: 'Asha', email: 'asha@gmail.com'),
      throwsA(isA<CustomerPhoneRequiredException>()),
    );
    final account = await state.completeCustomerGmailPhone(phone: '9876543299');
    expect(account.name, 'Asha');
    expect(account.contact, '+919876543299');
    expect(account.provider, LoginProvider.google);
  });

  test('the same phone cannot be both customer and owner', () async {
    final ownerFirst = AppState();
    await ownerFirst.loginOwnerWithPhone(
      phone: '9876543210',
      verificationId: 'owner-verification',
      smsCode: '123456',
    );
    await ownerFirst.signOutActiveUser();
    await expectLater(
      _loginCustomer(ownerFirst, name: 'Asha', phone: '9876543210'),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains('already registered as a salon owner'),
        ),
      ),
    );

    final customerFirst = AppState();
    await _loginCustomer(customerFirst, name: 'Asha', phone: '9876543211');
    await customerFirst.signOutActiveUser();
    await expectLater(
      customerFirst.loginOwnerWithPhone(
        phone: '9876543211',
        verificationId: 'owner-verification',
        smsCode: '123456',
      ),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains('already registered as a customer'),
        ),
      ),
    );
  });

  test('an email owner does not reserve an unrelated customer phone', () async {
    final state = AppState();
    await state.loginOwnerWithEmail(
      name: 'Salon Owner',
      email: 'owner@example.com',
    );
    await state.signOutActiveUser();

    final customer = await _loginCustomer(
      state,
      name: 'Asha',
      phone: '9876543212',
    );

    expect(customer.contact, '+919876543212');
    expect(state.hasActiveCustomerSession, isTrue);
  });

  test('an owner profile phone cannot later be used by a customer', () async {
    final state = AppState();
    await state.loginOwnerWithEmail(
      name: 'Salon Owner',
      email: 'owner@example.com',
    );
    await state.updateOwnerSalon(
      name: 'Owner Salon',
      ownerName: 'Salon Owner',
      address: 'Main Road',
      phone: '9876543213',
      email: 'contact@ownersalon.com',
      openTime: '9:00 AM',
      closeTime: '8:00 PM',
    );
    expect(state.ownerSalon.phone, '+919876543213');
    expect(state.ownerSalon.email, 'contact@ownersalon.com');
    await state.signOutActiveUser();

    await expectLater(
      _loginCustomer(state, name: 'Asha', phone: '9876543213'),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains('already registered as a salon owner'),
        ),
      ),
    );
    await expectLater(
      state.loginOwnerWithPhone(
        phone: '9876543213',
        verificationId: 'owner-verification',
        smsCode: '123456',
      ),
      throwsA(
        predicate(
          (error) => error.toString().contains('original login method'),
        ),
      ),
    );
  });

  test('a phone-authenticated owner profile still requires an email', () async {
    final state = AppState();
    await state.loginOwnerWithPhone(
      phone: '9876543214',
      verificationId: 'owner-verification',
      smsCode: '123456',
    );

    await expectLater(
      state.updateOwnerSalon(
        name: 'Owner Salon',
        ownerName: 'Salon Owner',
        address: 'Main Road',
        phone: '9876543214',
        openTime: '9:00 AM',
        closeTime: '8:00 PM',
      ),
      throwsFormatException,
    );
  });

  test(
    'new customer phone login requests a name after phone verification',
    () async {
      final state = AppState();
      await expectLater(
        state.loginCustomerWithPhone(
          name: ' ',
          phone: '9876543210',
          verificationId: 'test-verification',
          smsCode: '123456',
        ),
        throwsA(isA<CustomerNameRequiredException>()),
      );

      final account = await state.completeCustomerPhoneRegistration(
        name: 'Mayur',
        phone: '9876543210',
      );
      expect(account.name, 'Mayur');
      expect(state.hasActiveCustomerSession, isTrue);
    },
  );

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
    expect(find.text('Partner space'), findsNothing);
    expect(find.text('Choose your workspace'), findsNothing);
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

    expect(find.byKey(const ValueKey('exit-salon-login')), findsOneWidget);
    expect(find.text('Phone number'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    await tester.tap(find.text('Email'));
    await tester.pumpAndSettle();

    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    expect(find.text('Continue with Gmail'), findsOneWidget);
    expect(find.text('Owner name'), findsNothing);
  });

  testWidgets('new salon owner must register a shop before overview', (
    tester,
  ) async {
    final state = AppState();
    await state.loginOwnerWithEmail(
      name: 'New owner',
      email: 'new-owner@example.com',
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SalonProfileSetupScreen), findsOneWidget);
    expect(find.text('Shop registration'), findsOneWidget);
    expect(find.text('Overview'), findsNothing);
  });

  testWidgets('new salon owner can leave onboarding for customer home', (
    tester,
  ) async {
    final state = AppState();
    await state.loginOwnerWithEmail(
      name: 'Accidental owner',
      email: 'accidental-owner@example.com',
    );

    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: SalonDashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('exit-salon-onboarding')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('exit-salon-onboarding')));
    await tester.pumpAndSettle();

    expect(state.ownerAccount, isNull);
    expect(state.activeRole, isNull);
    expect(find.byType(CustomerHomeScreen), findsOneWidget);
  });

  testWidgets('customer authentication offers phone OTP and Gmail', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AuthLoginPanel(role: UserRole.customer)),
      ),
    );

    expect(find.byKey(const ValueKey('phone-login-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('customer-name-field')), findsNothing);
    expect(find.text('Phone number'), findsOneWidget);
    expect(find.text('Email'), findsNothing);
    expect(find.byKey(const ValueKey('email-login-field')), findsNothing);
    expect(find.text('Continue with Gmail'), findsOneWidget);

    final phoneField = tester.widget<TextField>(
      find.byKey(const ValueKey('phone-login-field')),
    );
    expect(phoneField.autofillHints, contains(AutofillHints.telephoneNumber));
    expect(
      phoneField.autofillHints,
      contains(AutofillHints.telephoneNumberDevice),
    );
    expect(phoneField.decoration?.prefixText, '+91 ');
    expect(
      find.byKey(const ValueKey('suggest-phone-number-button')),
      findsOneWidget,
    );
  });

  testWidgets('Android automatic OTP completion advances without typing code', (
    tester,
  ) async {
    final state = _AutoVerifiedPhoneAppState();
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(
          home: Scaffold(body: AuthLoginPanel(role: UserRole.customer)),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('phone-login-field')),
      '9876543210',
    );
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(find.byKey(const ValueKey('phone-otp-field')), findsOneWidget);

    state.completeOtpAutomatically('+919876543210');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-otp-field')), findsNothing);
    expect(find.byKey(const ValueKey('customer-name-field')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('customer Gmail asks for phone without sending an OTP', (
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

    await tester.tap(find.text('Continue with Gmail'));
    await tester.pumpAndSettle();

    expect(find.text('Save phone and continue'), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-otp-field')), findsNothing);
    expect(
      find.text('Add your mobile number. No phone OTP is required.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('phone-login-field')),
      '9876543298',
    );
    await tester.tap(find.text('Save phone and continue'));
    await tester.pumpAndSettle();

    expect(loginCompleted, isTrue);
    expect(state.hasActiveCustomerSession, isTrue);
    expect(state.customerAccount?.contact, '+919876543298');
    expect(find.byKey(const ValueKey('phone-otp-field')), findsNothing);
  });

  testWidgets('customer and owner login enforce ten Indian mobile digits', (
    tester,
  ) async {
    for (final role in [UserRole.customer, UserRole.owner]) {
      await tester.pumpWidget(
        AppStateProvider(
          createAppState: AppState.new,
          child: MaterialApp(
            home: Scaffold(body: AuthLoginPanel(role: role)),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('phone-login-field')),
        '98765432109',
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('phone-login-field')))
            .controller
            ?.text,
        '9876543210',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Indian mobile numbers contain exactly 10 digits.'),
        findsWidgets,
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('phone-login-field')),
        '987654321',
      );
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text(
          'Enter one more digit. Mobile number must contain 10 digits.',
        ),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox());
    }
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

    expect(loginCompleted, isFalse);
    expect(find.byKey(const ValueKey('phone-otp-field')), findsNothing);
    expect(find.byKey(const ValueKey('customer-name-field')), findsOneWidget);
    expect(find.text('Create customer account'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('customer-name-field')),
      'Mayur',
    );
    await tester.tap(find.text('Create customer account'));
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

  testWidgets('registered customer signs in with OTP without seeing name', (
    tester,
  ) async {
    final state = AppState();
    await state.loginCustomerWithPhone(
      name: 'Existing customer',
      phone: '9876543219',
      verificationId: 'first-verification',
      smsCode: '123456',
    );
    await state.signOutActiveUser();
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
      find.byKey(const ValueKey('phone-login-field')),
      '9876543219',
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
    expect(find.byKey(const ValueKey('customer-name-field')), findsNothing);
    expect(state.customerAccount?.name, 'Existing customer');

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
      await state.updateOwnerSalon(
        name: state.ownerSalon.name,
        ownerName: state.ownerSalon.ownerName,
        address: state.ownerSalon.address,
        directionsUrl: state.ownerSalon.directionsUrl,
        phone: state.ownerSalon.phone,
        openTime: '9:00 AM',
        closeTime: '8:00 PM',
      );
      await state.addOwnerBarber(
        name: 'Aman',
        phone: '9876543210',
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

Future<UserAccount> _loginCustomer(
  AppState state, {
  String name = 'Customer',
  String phone = '9876500000',
}) {
  return state.loginCustomerWithPhone(
    name: name,
    phone: phone,
    verificationId: 'test-verification',
    smsCode: '123456',
  );
}

Future<AppState> _stateWithSalonService({
  bool signOut = true,
  AppState? appState,
}) async {
  final state = appState ?? AppState();
  await state.loginOwnerWithEmail(name: 'Owner', email: 'owner@example.com');
  await state.updateOwnerSalon(
    name: 'Pritze Cuts',
    ownerName: 'Owner',
    address: 'Nashik Road',
    directionsUrl: 'https://maps.app.goo.gl/example',
    phone: '9888888888',
    openTime: '12:00 AM',
    closeTime: '11:59 PM',
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

class _DelayedBookingStatusAppState extends AppState {
  final Completer<void> _statusWrite = Completer<void>();

  void completeStatusWrite() {
    if (!_statusWrite.isCompleted) {
      _statusWrite.complete();
    }
  }

  @override
  Future<void> updateBookingStatus(
    String bookingId,
    BookingStatus status, {
    String? cancellationReason,
    String? cancelledBy,
  }) async {
    await _statusWrite.future;
    await super.updateBookingStatus(
      bookingId,
      status,
      cancellationReason: cancellationReason,
      cancelledBy: cancelledBy,
    );
  }
}

class _AutoVerifiedPhoneAppState extends AppState {
  final StreamController<String> _autoVerification =
      StreamController<String>.broadcast();

  @override
  Stream<String> get autoVerifiedPhoneNumbers => _autoVerification.stream;

  void completeOtpAutomatically(String phone) {
    _autoVerification.add(phone);
  }

  @override
  void dispose() {
    unawaited(_autoVerification.close());
    super.dispose();
  }
}

class _NotificationPreferencesLoadingState extends AppState {
  @override
  bool notificationPreferencesReady(UserRole role) => false;
}

class _RestoringAppState extends AppState {
  @override
  bool get isRestoringSession => true;
}
