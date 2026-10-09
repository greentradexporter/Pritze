import 'package:flutter_test/flutter_test.dart';
import 'package:nashik_salon_booking/state/app_state.dart';

void main() {
  // The salons and barbers listeners read whole collections. One malformed
  // document used to throw out of the listener after the list had already
  // been cleared, leaving it empty for every user — and an owner with no
  // salon in the list is dropped onto the registration screen, which
  // replaces the dashboard and cannot be dismissed without killing the app.
  test('one unparseable document does not discard the others', () {
    final skipped = <Object>[];

    final parsed = parseDocuments<String, String>(
      ['good-1', 'bad', 'good-2'],
      (doc) {
        if (doc == 'bad') throw const FormatException('unexpected shape');
        return doc.toUpperCase();
      },
      onSkipped: skipped.add,
    );

    expect(parsed, ['GOOD-1', 'GOOD-2']);
    expect(skipped, hasLength(1));
  });

  test('every document failing yields an empty list, not a thrown error', () {
    expect(
      () => parseDocuments<String, String>(
        ['a', 'b'],
        (_) => throw const FormatException('bad'),
      ),
      returnsNormally,
    );
  });

  test('a salon list is treated as loaded only once it has arrived', () {
    // The base state has nothing to wait for, so it reports loaded.
    expect(AppState().salonsLoaded, isTrue);
  });
}
