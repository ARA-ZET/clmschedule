import 'dart:convert';

import 'package:clmschedule/letterbox/services/letterbox_seed_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Uint8List payload(List<List<double?>> pts) {
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'waypoints': [
      for (final p in pts) {'lat': p[0], 'lon': p[1]},
    ],
  })));
}

SeedSuburb square(String id, double minLat, double minLng, double size) =>
    SeedSuburb(id: id, name: id, polygon: [
      LatLng(minLat, minLng),
      LatLng(minLat, minLng + size),
      LatLng(minLat + size, minLng + size),
      LatLng(minLat + size, minLng),
    ]);

LetterboxSeedAllResult run(
        List<Uint8List> payloads, List<SeedSuburb> suburbs) =>
    seedAllFromPayloads(SeedAllInput(
        payloads, suburbs, LetterboxSeedService.defaultSnapDegrees));

void main() {
  final suburb = square('a', -33.93, 18.42, 0.01);

  group('accounting for every waypoint in a file', () {
    test('the numbers reconcile exactly', () {
      // 10 drops: 6 inside, 3 outside every suburb, 1 with no coordinates.
      final result = run([
        payload([
          [-33.9250, 18.4250],
          [-33.9260, 18.4260],
          [-33.9270, 18.4270],
          [-33.9280, 18.4280],
          [-33.9290, 18.4290],
          [-33.9255, 18.4255],
          [-34.5000, 19.9000],
          [-34.6000, 19.8000],
          [-34.7000, 19.7000],
          [null, 18.4250],
        ])
      ], [
        suburb
      ]);

      // The malformed one never reaches the count at all.
      expect(result.totalDrops, 9);
      expect(result.insideDrops, 6);
      expect(result.unmatchedDrops, 3);
      expect(result.insideDrops + result.unmatchedDrops, result.totalDrops,
          reason: 'every usable drop is either placed or explained');

      final stored = result.bySuburb.values.fold(0, (sum, l) => sum + l.length);
      expect(stored, 6, reason: 'nothing inside a suburb is silently dropped');
    });

    test('unmatched drops are kept so they can be shown, not just counted', () {
      final result = run([
        payload([
          [-33.9250, 18.4250],
          [-34.5000, 19.9000],
          [-34.6000, 19.8000],
        ])
      ], [
        suburb
      ]);

      expect(result.unmatchedSample, hasLength(2));
      expect(result.unmatchedSample.first.latitude, closeTo(-34.5, 1e-9));
    });

    test('the kept sample is capped but the count is not', () {
      final many = [
        for (var i = 0; i < 25; i++) [-34.5 - i * 0.001, 19.9],
      ];
      final result = run([payload(many)], [suburb]);

      expect(result.unmatchedDrops, 25, reason: 'the count is the truth');
      expect(result.unmatchedSample.length, lessThanOrEqualTo(25));
      expect(result.unmatchedSample.length,
          lessThanOrEqualTo(LetterboxSeedAllResult.maxUnmatchedSample));
    });

    test('repeat visits explain a gap between inside and stored', () {
      // One address, four rounds: 4 drops inside, 1 letterbox stored. The
      // difference is real and must be attributable, not a silent loss.
      final one = payload([
        [-33.9250, 18.4250]
      ]);
      final result = run([one, one, one, one], [suburb]);

      expect(result.insideDrops, 4);
      final stored = result.bySuburb.values.fold(0, (sum, l) => sum + l.length);
      expect(stored, 1);
      expect(result.insideDrops - stored, 3,
          reason: 'reported as merged repeat visits, not as missing');
    });

    test('a file entirely outside the suburb layer stores nothing and says so',
        () {
      final result = run([
        payload([
          [-34.5000, 19.9000],
          [-34.6000, 19.8000],
        ])
      ], [
        suburb
      ]);

      expect(result.bySuburb, isEmpty);
      expect(result.unmatchedDrops, 2);
      expect(result.unmatchedSample, hasLength(2));
    });
  });
}
