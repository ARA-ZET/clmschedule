import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:clmschedule/models/custom_polygon.dart';

/// The letterbox split is computed once — when a polygon is drawn, edited or
/// imported — and read back on every later view. If it does not survive the
/// Firestore round trip, every one of those reads silently falls back to a
/// recount, which is exactly what storing it was meant to avoid.
void main() {
  const square = [
    LatLng(-34.0, 18.0),
    LatLng(-34.0, 18.1),
    LatLng(-33.9, 18.1),
    LatLng(-33.9, 18.0),
  ];

  CustomPolygon polygon({LetterBoxSplit? split, int estimate = 0}) =>
      CustomPolygon(
        name: 'Area',
        description: '',
        points: square,
        color: Colors.blue,
        letterBoxEstimate: estimate,
        letterBoxSplit: split,
      );

  group('LetterBoxSplit', () {
    test('totals houses and apartment boxes, not blocks', () {
      const split =
          LetterBoxSplit(houses: 40, apartmentBoxes: 12, apartmentBlocks: 3);
      expect(split.total, 52);
    });

    test('isEmpty ignores block count', () {
      const noBoxes =
          LetterBoxSplit(houses: 0, apartmentBoxes: 0, apartmentBlocks: 0);
      expect(noBoxes.isEmpty, isTrue);
      expect(LetterBoxSplit.empty.isEmpty, isTrue);
      const someHouses =
          LetterBoxSplit(houses: 1, apartmentBoxes: 0, apartmentBlocks: 0);
      expect(someHouses.isEmpty, isFalse);
    });

    test('round trips through a map', () {
      const split =
          LetterBoxSplit(houses: 640, apartmentBoxes: 172, apartmentBlocks: 24);
      expect(LetterBoxSplit.fromMap(split.toMap()), split);
    });

    test('a missing field reads as zero rather than throwing', () {
      final split = LetterBoxSplit.fromMap({'houses': 7});
      expect(split.houses, 7);
      expect(split.apartmentBoxes, 0);
      expect(split.apartmentBlocks, 0);
    });
  });

  group('CustomPolygon serialization', () {
    test('a stored split survives the round trip', () {
      const split =
          LetterBoxSplit(houses: 640, apartmentBoxes: 172, apartmentBlocks: 24);
      final restored =
          CustomPolygon.fromMap(polygon(split: split, estimate: 812).toMap());
      expect(restored.letterBoxSplit, split);
      expect(restored.letterBoxEstimate, 812);
    });

    test('a polygon with no split writes no key and reads back null', () {
      final map = polygon().toMap();
      expect(map.containsKey('letterBoxSplit'), isFalse);
      expect(CustomPolygon.fromMap(map).letterBoxSplit, isNull);
    });

    test('a computed all-zero split is kept, not confused with "never counted"',
        () {
      // An area genuinely holding no letterboxes must stay distinguishable
      // from one that has never been counted — otherwise it is recounted on
      // every single view, forever.
      final restored =
          CustomPolygon.fromMap(polygon(split: LetterBoxSplit.empty).toMap());
      expect(restored.letterBoxSplit, isNotNull);
      expect(restored.letterBoxSplit, LetterBoxSplit.empty);
    });

    test('a legacy document without the field still parses', () {
      final legacy = {
        'name': 'Old Area',
        'description': '',
        'points': [
          {'latitude': -34.0, 'longitude': 18.0},
          {'latitude': -34.0, 'longitude': 18.1},
          {'latitude': -33.9, 'longitude': 18.1},
        ],
        'color': 0xFF2196F3,
        'letterBoxEstimate': 500,
      };
      final restored = CustomPolygon.fromMap(legacy);
      expect(restored.letterBoxSplit, isNull);
      expect(restored.letterBoxEstimate, 500);
    });

    test('copyWith carries the split forward when not overridden', () {
      const split =
          LetterBoxSplit(houses: 10, apartmentBoxes: 5, apartmentBlocks: 1);
      final moved = polygon(split: split).copyWith(name: 'Renamed');
      expect(moved.letterBoxSplit, split);
    });

    test('clearLetterBoxSplit drops a stored split', () {
      // A hand-typed total must not sit above a breakdown computed for a
      // different number. copyWith cannot pass null through the usual `??`,
      // so clearing needs its own flag.
      const split =
          LetterBoxSplit(houses: 10, apartmentBoxes: 5, apartmentBlocks: 1);
      final cleared = polygon(split: split, estimate: 15)
          .copyWith(letterBoxEstimate: 900, clearLetterBoxSplit: true);
      expect(cleared.letterBoxSplit, isNull);
      expect(cleared.letterBoxEstimate, 900);
      expect(cleared.toMap().containsKey('letterBoxSplit'), isFalse);
    });

    test('clearLetterBoxSplit wins over a supplied split', () {
      const split =
          LetterBoxSplit(houses: 10, apartmentBoxes: 5, apartmentBlocks: 1);
      final cleared = polygon().copyWith(
        letterBoxSplit: split,
        clearLetterBoxSplit: true,
      );
      expect(cleared.letterBoxSplit, isNull);
    });

    test('equality accounts for the split', () {
      const a =
          LetterBoxSplit(houses: 10, apartmentBoxes: 5, apartmentBlocks: 1);
      const b =
          LetterBoxSplit(houses: 11, apartmentBoxes: 5, apartmentBlocks: 1);
      expect(polygon(split: a) == polygon(split: a), isTrue);
      expect(polygon(split: a) == polygon(split: b), isFalse);
      expect(polygon(split: a) == polygon(), isFalse);
    });
  });
}
