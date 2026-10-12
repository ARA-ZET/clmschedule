import 'package:clmschedule/track_editor/services/point_in_polygon.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// The area-replacement rule, isolated from Firebase.
///
/// Mirrors `LetterboxProvider._applyAreaReplacement`: keep everything outside
/// the drawn area, and take the fresh survey for everything inside it — but
/// only where the fresh points also fall within the suburb.
List<LatLng> applyAreaReplacement({
  required List<LatLng> existing,
  required List<LatLng> area,
  required List<LatLng> fresh,
  required List<LatLng> suburb,
}) {
  final kept = existing.where((p) => !isPointInPolygon(p, area)).toList();
  final added = fresh
      .where((p) => isPointInPolygon(p, area) && isPointInPolygon(p, suburb))
      .toList();
  return [...kept, ...added];
}

List<LatLng> box(double minLat, double minLng, double size) => [
      LatLng(minLat, minLng),
      LatLng(minLat, minLng + size),
      LatLng(minLat + size, minLng + size),
      LatLng(minLat + size, minLng),
    ];

void main() {
  // Suburb spans lat [-33.94, -33.90], lng [18.40, 18.44].
  final suburb = box(-33.94, 18.40, 0.04);
  // Re-surveyed area: a block in the middle.
  final area = box(-33.925, 18.415, 0.005);

  const insideArea = LatLng(-33.9230, 18.4170);
  const insideArea2 = LatLng(-33.9225, 18.4175);
  const elsewhereInSuburb = LatLng(-33.9350, 18.4350);
  const alsoElsewhere = LatLng(-33.9050, 18.4050);

  test('letterboxes outside the area are untouched', () {
    final result = applyAreaReplacement(
      existing: [insideArea, elsewhereInSuburb, alsoElsewhere],
      area: area,
      fresh: const [],
      suburb: suburb,
    );

    expect(result, containsAll([elsewhereInSuburb, alsoElsewhere]));
    expect(result.contains(insideArea), isFalse,
        reason: 'the old survey inside the area is replaced');
    expect(result, hasLength(2));
  });

  test('the fresh survey replaces what was inside', () {
    const fresh1 = LatLng(-33.9235, 18.4165);
    const fresh2 = LatLng(-33.9240, 18.4180);

    final result = applyAreaReplacement(
      existing: [insideArea, insideArea2, elsewhereInSuburb],
      area: area,
      fresh: const [fresh1, fresh2],
      suburb: suburb,
    );

    expect(result, containsAll([elsewhereInSuburb, fresh1, fresh2]));
    expect(result.contains(insideArea), isFalse);
    expect(result.contains(insideArea2), isFalse);
    expect(result, hasLength(3));
  });

  test('an apartment block in the fresh survey keeps all its boxes', () {
    // Re-surveying must not flatten a block back to one point.
    final blockBoxes = [
      for (var i = 0; i < 6; i++) LatLng(-33.9230 + i * 0.00001, 18.4170),
    ];

    final result = applyAreaReplacement(
      existing: [insideArea],
      area: area,
      fresh: blockBoxes,
      suburb: suburb,
    );

    expect(result, hasLength(6));
  });

  test('fresh points outside the suburb are refused', () {
    // An area dragged over a neighbouring suburb must not import that
    // suburb's letterboxes into this one's payload.
    final wideArea = box(-33.930, 18.410, 0.10); // spills past the suburb
    const beyondSuburb = LatLng(-33.9200, 18.4900);
    const withinSuburb = LatLng(-33.9250, 18.4250);

    final result = applyAreaReplacement(
      existing: const [],
      area: wideArea,
      fresh: const [beyondSuburb, withinSuburb],
      suburb: suburb,
    );

    expect(result, [withinSuburb]);
  });

  test('an empty fresh survey clears the area but keeps the rest', () {
    final result = applyAreaReplacement(
      existing: [insideArea, insideArea2, elsewhereInSuburb],
      area: area,
      fresh: const [],
      suburb: suburb,
    );

    expect(result, [elsewhereInSuburb]);
  });

  test('replacing twice with the same data is stable', () {
    const fresh = LatLng(-33.9235, 18.4165);

    final once = applyAreaReplacement(
      existing: [insideArea, elsewhereInSuburb],
      area: area,
      fresh: const [fresh],
      suburb: suburb,
    );
    final twice = applyAreaReplacement(
      existing: once,
      area: area,
      fresh: const [fresh],
      suburb: suburb,
    );

    expect(twice, once);
  });

  test('an area covering nothing changes nothing', () {
    final emptyCorner = box(-33.9390, 18.4010, 0.001);
    final existing = [insideArea, elsewhereInSuburb];

    final result = applyAreaReplacement(
      existing: existing,
      area: emptyCorner,
      fresh: const [],
      suburb: suburb,
    );

    expect(result, existing);
  });

  group('replacing into an area that already holds letterboxes', () {
    test('every existing letterbox inside is removed, none survive', () {
      // The case that matters: re-seeding a block that was already curated
      // must not leave the old survey mixed in with the new one.
      final existingInside = [
        for (var i = 0; i < 25; i++)
          LatLng(-33.9230 + i * 0.00005, 18.4170 + i * 0.00005),
      ];
      final freshInside = [
        for (var i = 0; i < 9; i++)
          LatLng(-33.9235 + i * 0.00004, 18.4165 + i * 0.00004),
      ];

      final result = applyAreaReplacement(
        existing: [...existingInside, elsewhereInSuburb],
        area: area,
        fresh: freshInside,
        suburb: suburb,
      );

      for (final old in existingInside) {
        expect(result.contains(old), isFalse,
            reason: 'no part of the previous survey may remain in the area');
      }
      expect(result, containsAll(freshInside));
      expect(result, hasLength(freshInside.length + 1));
    });

    test('the replacement can be smaller than what it replaced', () {
      // 25 old letterboxes replaced by 9 must leave 9, not 25 and not 34.
      final existingInside = [
        for (var i = 0; i < 25; i++) LatLng(-33.9230 + i * 0.00005, 18.4170),
      ];
      final freshInside = [
        for (var i = 0; i < 9; i++) LatLng(-33.9240 + i * 0.00004, 18.4180),
      ];

      final result = applyAreaReplacement(
        existing: existingInside,
        area: area,
        fresh: freshInside,
        suburb: suburb,
      );

      expect(result, hasLength(9));
    });
  });

  group('a polygon spanning two suburbs', () {
    // West and east halves meeting at lng 18.42, with the drawn area straddling
    // the seam.
    final west = box(-33.94, 18.40, 0.02);
    final east = box(-33.94, 18.42, 0.02);
    final across = box(-33.930, 18.415, 0.010); // lng 18.415 .. 18.425

    const oldWest = LatLng(-33.9270, 18.4180); // inside area, west suburb
    const oldEast = LatLng(-33.9270, 18.4230); // inside area, east suburb
    const farWest = LatLng(-33.9350, 18.4050); // west suburb, outside area
    const farEast = LatLng(-33.9350, 18.4350); // east suburb, outside area

    const freshWest = LatLng(-33.9260, 18.4170);
    const freshEast = LatLng(-33.9260, 18.4240);

    test('each suburb keeps what lies outside the polygon', () {
      final w = applyAreaReplacement(
        existing: const [oldWest, farWest],
        area: across,
        fresh: const [freshWest, freshEast],
        suburb: west,
      );
      final e = applyAreaReplacement(
        existing: const [oldEast, farEast],
        area: across,
        fresh: const [freshWest, freshEast],
        suburb: east,
      );

      expect(w, containsAll([farWest, freshWest]));
      expect(w.contains(oldWest), isFalse);
      expect(e, containsAll([farEast, freshEast]));
      expect(e.contains(oldEast), isFalse);
    });

    test('a fresh point lands only in the suburb that contains it', () {
      // The whole point of clipping to the suburb as well as the polygon: a
      // shape drawn across a boundary must not move a neighbour's letterboxes
      // into whichever suburb happened to be open.
      final w = applyAreaReplacement(
        existing: const [],
        area: across,
        fresh: const [freshWest, freshEast],
        suburb: west,
      );
      final e = applyAreaReplacement(
        existing: const [],
        area: across,
        fresh: const [freshWest, freshEast],
        suburb: east,
      );

      expect(w, [freshWest]);
      expect(e, [freshEast]);
    });

    test('no letterbox is duplicated or dropped across the seam', () {
      final w = applyAreaReplacement(
        existing: const [oldWest, farWest],
        area: across,
        fresh: const [freshWest, freshEast],
        suburb: west,
      );
      final e = applyAreaReplacement(
        existing: const [oldEast, farEast],
        area: across,
        fresh: const [freshWest, freshEast],
        suburb: east,
      );

      final all = [...w, ...e];
      expect(all.toSet().length, all.length, reason: 'no duplicates');
      expect(all, containsAll([freshWest, freshEast, farWest, farEast]));
      expect(all, hasLength(4));
    });
  });
}
