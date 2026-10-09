import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nashik_salon_booking/models/app_models.dart';
import 'package:nashik_salon_booking/state/app_state.dart';

void main() {
  // `saveOwnerBarber` sends this map to a Cloud Function, and a callable
  // JSON-encodes its payload. A Firestore FieldValue sentinel in here threw
  // "Invalid argument: Instance of 'FieldValue'" on the device, so adding a
  // barber failed before the request was ever sent — which is why the server
  // logged nothing at all.
  test('the barber callable payload is JSON encodable', () {
    const barber = Barber(
      id: 'barber-1',
      salonId: 'salon-1',
      name: 'Test Barber',
      phone: '+919876543210',
      email: '',
      speciality: 'Grooming expert',
      experienceYears: 3,
      resumeSummary: 'Customer-first grooming professional.',
      serviceIds: ['haircut-men'],
      isActive: true,
    );

    final payload = barberToMap(barber);

    expect(() => jsonEncode(payload), returnsNormally);
    expect(payload.containsKey('updatedAt'), isFalse);
    expect(payload['experienceYears'], 3);
    expect(payload['serviceIds'], ['haircut-men']);
  });
}
