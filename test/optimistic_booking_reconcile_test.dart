import 'package:flutter_test/flutter_test.dart';
import 'package:nashik_salon_booking/models/app_models.dart';
import 'package:nashik_salon_booking/state/app_state.dart';

Booking _booking(String id, BookingStatus status, DateTime createdAt) {
  return Booking(
    id: id,
    salonId: 'salon',
    serviceId: 'service',
    barberId: '',
    customerName: 'Customer',
    customerPhone: '+919876543210',
    start: createdAt.add(const Duration(minutes: 15)),
    status: status,
    createdAt: createdAt,
    isInstant: true,
    arrivalMinutes: 15,
  );
}

void main() {
  final createdAt = DateTime(2026, 10, 6, 10);

  test('optimistic status is shown while the server catches up', () {
    final optimistic = {
      'b1': OptimisticBooking(
        _booking('b1', BookingStatus.confirmed, createdAt),
        now: createdAt,
      ),
    };

    final merged = reconcileOptimisticBookings(
      serverBookings: {'b1': _booking('b1', BookingStatus.pending, createdAt)},
      optimistic: optimistic,
      now: createdAt.add(const Duration(seconds: 2)),
    );

    expect(merged['b1']!.status, BookingStatus.confirmed);
    expect(optimistic.containsKey('b1'), isTrue);
  });

  test('optimistic entry is dropped once the server agrees', () {
    final optimistic = {
      'b1': OptimisticBooking(
        _booking('b1', BookingStatus.confirmed, createdAt),
        now: createdAt,
      ),
    };

    final merged = reconcileOptimisticBookings(
      serverBookings: {
        'b1': _booking('b1', BookingStatus.confirmed, createdAt),
      },
      optimistic: optimistic,
      now: createdAt.add(const Duration(seconds: 2)),
    );

    expect(merged['b1']!.status, BookingStatus.confirmed);
    expect(optimistic, isEmpty);
  });

  // The regression: reconciling could fail (a timeout, a cold start), leaving
  // an optimistic copy the server never matched. It used to be replayed over
  // every later snapshot, so an accepted booking never became startable and
  // only restarting the app cleared it.
  test('a stale optimistic entry stops masking the server once it expires', () {
    final optimistic = {
      'b1': OptimisticBooking(
        _booking('b1', BookingStatus.confirmed, createdAt),
        now: createdAt,
      ),
    };
    final server = {'b1': _booking('b1', BookingStatus.inProgress, createdAt)};

    final before = reconcileOptimisticBookings(
      serverBookings: server,
      optimistic: optimistic,
      now: createdAt.add(const Duration(seconds: 5)),
    );
    expect(before['b1']!.status, BookingStatus.confirmed);

    final after = reconcileOptimisticBookings(
      serverBookings: server,
      optimistic: optimistic,
      now: createdAt.add(optimisticBookingLifetime),
    );

    expect(after['b1']!.status, BookingStatus.inProgress);
    expect(optimistic, isEmpty);
  });

  test('an optimistic booking the server has not seen is not injected', () {
    final optimistic = {
      'ghost': OptimisticBooking(
        _booking('ghost', BookingStatus.confirmed, createdAt),
        now: createdAt,
      ),
    };

    final merged = reconcileOptimisticBookings(
      serverBookings: const {},
      optimistic: optimistic,
      now: createdAt.add(const Duration(seconds: 2)),
    );

    expect(merged, isEmpty);
  });
}
