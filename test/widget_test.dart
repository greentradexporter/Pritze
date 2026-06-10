import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nashik_salon_booking/main.dart';
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

    expect(
      find.text('Find your next cut without calling around'),
      findsOneWidget,
    );
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
    await tester.pumpWidget(
      AppStateProvider(
        createAppState: () => state,
        child: const MaterialApp(home: BarberDashboardScreen()),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Barber name'),
      'Aman',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone number'),
      '9999999999',
    );
    await tester.tap(find.text('Send OTP'));
    await tester.pumpAndSettle();

    expect(find.text('Haircut specialist'), findsOneWidget);

    await tester.tap(find.text('Haircut specialist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fade specialist').last);
    await tester.pumpAndSettle();

    expect(find.text('Fade specialist'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Speciality'), findsNothing);
  });

  testWidgets('customer discovery only shows bookable shops', (tester) async {
    final state = AppState();
    await state.loginOwnerWithPhone(name: 'Owner A', phone: '9000000001');
    await state.updateOwnerSalon(
      name: 'Almost Ready Salon',
      ownerName: 'Owner A',
      address: 'MG Road',
      phone: '9000000001',
      openTime: '9:00 AM',
      closeTime: '8:00 PM',
    );
    await state.signOutActiveUser();
    await state.loginOwnerWithPhone(name: 'Owner B', phone: '9000000002');
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
      await state.loginOwnerWithPhone(name: 'Owner', phone: '9111111111');
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

  test(
    'barber phone login matches owner-added barber after normalization',
    () async {
      final state = await _stateWithBookableSalon(barberPhone: '9222222222');
      await state.loginBarberWithPhone(name: 'Aman', phone: '+91 92222 22222');

      expect(state.currentBarber?.name, 'Aman');
      expect(state.currentBarber?.phone, '+919222222222');
    },
  );

  testWidgets('barber join request is blocked when no shops exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      const AppStateProvider(child: MaterialApp(home: BarberDashboardScreen())),
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Barber name'),
      'Aman',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone number'),
      '9999999999',
    );
    await tester.tap(find.text('Send OTP'));
    await tester.pumpAndSettle();

    expect(find.text('No shops available yet'), findsOneWidget);
    expect(find.text('Send request'), findsNothing);
  });
}

Future<AppState> _stateWithBookableSalon({
  String barberPhone = '9999999999',
}) async {
  final state = await _stateWithSalonService(signOut: false);
  await state.addOwnerBarber(
    name: 'Aman',
    phone: barberPhone,
    speciality: 'Haircut specialist',
    experienceYears: 3,
    resumeSummary: 'Sharp cuts.',
    serviceIds: [state.ownerSalon.services.first.id],
  );
  await state.signOutActiveUser();
  return state;
}

Future<AppState> _stateWithSalonService({bool signOut = true}) async {
  final state = AppState();
  await state.loginOwnerWithPhone(name: 'Owner', phone: '9888888888');
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
