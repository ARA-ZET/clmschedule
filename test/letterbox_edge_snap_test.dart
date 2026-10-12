import 'dart:convert';

import 'package:clmschedule/letterbox/services/letterbox_seed_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Uint8List payload(List<List<double>> pts) =>
    Uint8List.fromList(utf8.encode(jsonEncode({
      'waypoints': [
        for (final p in pts) {'lat': p[0], 'lon': p[1]},
      ],
    })));

SeedSuburb square(String id, double minLat, double minLng, double size) =>
    SeedSuburb(id: id, name: id, polygon: [
      LatLng(minLat, minLng),
      LatLng(minLat, minLng + size),
      LatLng(minLat + size, minLng + size),
      LatLng(minLat + size, minLng),
    ]);

LetterboxSeedAllResult run(
  List<Uint8List> payloads,
  List<SeedSuburb> suburbs, {
  double tolerance = LetterboxSeedService.defaultEdgeToleranceMetres,
}) =>
    seedAllFromPayloads(SeedAllInput(
        payloads, suburbs, LetterboxSeedService.defaultSnapDegrees, tolerance));

/// Degrees of latitude for a distance in metres.
double latFor(double metres) => metres / 110574.0;

void main() {
  // Suburb spanning lat [-33.93, -33.92], lng [18.42, 18.43].
  final suburb = square('a', -33.93, 18.42, 0.01);

  group('drops just outside a boundary', () {
    test('a house across the road is placed in the nearest suburb', () {
      // 4 m north of the northern edge — the far side of a road whose centre
      // line is the boundary.
      final result = run([
        payload([
          [-33.92 + latFor(4), 18.425]
        ])
      ], [
        suburb
      ]);

      expect(result.bySuburb['a'], hasLength(1));
      expect(result.snappedDrops, 1);
      expect(result.unmatchedDrops, 0);
    });

    test('a drop well outside is still rejected', () {
      // 60 m out: too far to be a road's width, so it is a genuine miss.
      final result = run([
        payload([
          [-33.92 + latFor(60), 18.425]
        ])
      ], [
        suburb
      ]);

      expect(result.bySuburb, isEmpty);
      expect(result.snappedDrops, 0);
      expect(result.unmatchedDrops, 1);
    });

    test('the tolerance boundary behaves as stated', () {
      final justIn = run([
        payload([
          [-33.92 + latFor(9), 18.425]
        ])
      ], [
        suburb
      ]);
      final justOut = run([
        payload([
          [-33.92 + latFor(11), 18.425]
        ])
      ], [
        suburb
      ]);

      expect(justIn.snappedDrops, 1);
      expect(justOut.unmatchedDrops, 1);
    });

    test('a point inside is unaffected and never counted as snapped', () {
      final result = run([
        payload([
          [-33.925, 18.425]
        ])
      ], [
        suburb
      ]);

      expect(result.bySuburb['a'], hasLength(1));
      expect(result.snappedDrops, 0);
    });

    test('it picks the NEAREST suburb, not merely one in range', () {
      // Two suburbs with a 12 m gap between them; a drop 3 m from the south
      // one must go there, not to the north one 9 m away.
      final south = square('south', -33.9300, 18.42, 0.0100);
      final north = SeedSuburb(id: 'north', name: 'north', polygon: [
        LatLng(-33.9200 + latFor(12), 18.42),
        LatLng(-33.9200 + latFor(12), 18.43),
        LatLng(-33.9100, 18.43),
        LatLng(-33.9100, 18.42),
      ]);

      final result = run([
        payload([
          [-33.9200 + latFor(3), 18.425]
        ])
      ], [
        south,
        north
      ]);

      expect(result.bySuburb.containsKey('south'), isTrue);
      expect(result.bySuburb.containsKey('north'), isFalse);
    });

    test('measures to the edge, not to vertices', () {
      // The northern edge runs 1.1 km with vertices only at its ends. A drop
      // 5 m from the middle of that edge is ~550 m from the nearest vertex, so
      // a vertex-based test would wrongly reject it.
      final result = run([
        payload([
          [-33.92 + latFor(5), 18.425]
        ])
      ], [
        suburb
      ]);

      expect(result.snappedDrops, 1);
    });

    test('tolerance of zero disables snapping', () {
      final result = run([
        payload([
          [-33.92 + latFor(4), 18.425]
        ])
      ], [
        suburb
      ], tolerance: 0);

      expect(result.unmatchedDrops, 1);
      expect(result.snappedDrops, 0);
    });
  });
}
