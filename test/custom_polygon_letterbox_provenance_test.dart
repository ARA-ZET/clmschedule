import 'package:clmschedule/models/custom_polygon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  const base = CustomPolygon(
    name: 'Sea Point',
    description: '',
    points: [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1)],
    color: Color(0xFF2196F3),
    letterBoxEstimate: 120,
    letterBoxSplit:
        LetterBoxSplit(houses: 100, apartmentBoxes: 20, apartmentBlocks: 2),
    letterboxSuburbIds: ['sea_point', 'fresnaye'],
  );

  test('suburb ids survive a Firestore round trip', () {
    final back = CustomPolygon.fromMap(base.toMap());
    expect(back.letterboxSuburbIds, ['sea_point', 'fresnaye']);
    expect(back, base);
  });

  test('a polygon counted before provenance existed reads as unknown', () {
    final map = base.toMap()..remove('letterboxSuburbIds');
    expect(CustomPolygon.fromMap(map).letterboxSuburbIds, isNull);
  });

  test('a hand-typed total drops the provenance with the split', () {
    final typed =
        base.copyWith(letterBoxEstimate: 90, clearLetterBoxSplit: true);
    expect(typed.letterBoxSplit, isNull);
    expect(typed.letterboxSuburbIds, isNull);
    expect(typed.toMap().containsKey('letterboxSuburbIds'), isFalse);
  });

  test('provenance changes break equality', () {
    expect(base.copyWith(letterboxSuburbIds: ['sea_point']) == base, isFalse);
  });

  test('a hand-set lock survives a round trip and records who set it', () {
    final locked = base.copyWith(
      letterBoxEstimate: 95,
      clearLetterBoxSplit: true,
      letterBoxLocked: true,
      letterBoxLockedBy: 'admin@clm.co.za',
    );
    final back = CustomPolygon.fromMap(locked.toMap());
    expect(back.letterBoxLocked, isTrue);
    expect(back.letterBoxLockedBy, 'admin@clm.co.za');
    expect(back.letterBoxEstimate, 95);
    expect(back, locked);
  });

  test('unlocking forgets who locked it and stores nothing', () {
    final unlocked = base
        .copyWith(letterBoxLocked: true, letterBoxLockedBy: 'a@b.c')
        .copyWith(letterBoxLocked: false);
    expect(unlocked.letterBoxLockedBy, isNull);
    expect(unlocked.toMap().containsKey('letterBoxLocked'), isFalse);
    expect(unlocked.toMap().containsKey('letterBoxLockedBy'), isFalse);
  });
}
