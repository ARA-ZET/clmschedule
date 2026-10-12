import 'package:clmschedule/letterbox/utils/letterbox_clusters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

const base = LatLng(-33.925, 18.425);

/// A position [metres] north of [from].
LatLng north(LatLng from, double metres) =>
    LatLng(from.latitude + metres / 110574.0, from.longitude);

void main() {
  group('metresBetween', () {
    test('measures a known northward offset', () {
      expect(LetterboxClusters.metresBetween(base, north(base, 10)),
          closeTo(10, 0.05));
    });

    test('accounts for longitude converging at this latitude', () {
      // 0.0001 degrees of longitude is ~9.2 m at -33.9, not 11.1 m. Getting
      // this wrong would make the cluster radius lopsided east to west.
      final east = LatLng(base.latitude, base.longitude + 0.0001);
      expect(LetterboxClusters.metresBetween(base, east), closeTo(9.2, 0.3));
    });
  });

  group('breakdown', () {
    test('isolated points are freestanding houses', () {
      final result = LetterboxClusters.breakdown([
        base,
        north(base, 30),
        north(base, 60),
      ]);

      expect(result.total, 3);
      expect(result.houses, 3);
      expect(result.apartmentBoxes, 0);
      expect(result.apartmentBlocks, 0);
    });

    test('boxes logged at one entrance are an apartment block', () {
      // Eight boxes recorded at a block's door, within a couple of metres —
      // how a distributor standing at an entrance actually logs them.
      final result = LetterboxClusters.breakdown([
        for (var i = 0; i < 8; i++) north(base, i * 0.3),
      ]);

      expect(result.total, 8);
      expect(result.houses, 0);
      expect(result.apartmentBoxes, 8);
      expect(result.apartmentBlocks, 1);
      expect(result.boxesPerBlock, 8);
    });

    test('a bank wider than the radius splits at the edges', () {
      // Bounding cluster extent has a cost. Twelve boxes spread over 11 m break
      // into a main cluster plus a tail, and a tail under the block threshold
      // is counted as freestanding. The TOTAL is always right; the split is an
      // estimate, and this is where it errs.
      final result = LetterboxClusters.breakdown([
        for (var i = 0; i < 12; i++) north(base, i * 1.0),
      ]);

      expect(result.total, 12, reason: 'nothing is ever lost');
      expect(result.houses + result.apartmentBoxes, 12);
      expect(result.apartmentBoxes, greaterThanOrEqualTo(6),
          reason: 'the bulk of a real bank is still recognised as a block');
    });

    test('separates houses from blocks in a mixed street', () {
      final blockAt = north(base, 100);
      final result = LetterboxClusters.breakdown([
        base,
        north(base, 30),
        north(base, 60),
        for (var i = 0; i < 6; i++) north(blockAt, i * 0.4),
      ]);

      expect(result.total, 9);
      expect(result.houses, 3);
      expect(result.apartmentBoxes, 6);
      expect(result.apartmentBlocks, 1);
    });

    test('two separate blocks are counted separately', () {
      final a = base;
      final b = north(base, 200);
      final result = LetterboxClusters.breakdown([
        for (var i = 0; i < 5; i++) north(a, i * 0.4),
        for (var i = 0; i < 6; i++) north(b, i * 0.4),
      ]);

      expect(result.apartmentBlocks, 2);
      expect(result.apartmentBoxes, 11);
      expect(result.houses, 0);
    });

    test('a street of houses does NOT chain into one block', () {
      // The bug this replaced: with single-linkage every house was within the
      // radius of the next, so twenty houses 6 m apart became one 114 m
      // "apartment block" of twenty boxes, and the suburb reported no houses
      // at all.
      final result = LetterboxClusters.breakdown([
        for (var i = 0; i < 20; i++) north(base, i * 6.0),
      ]);

      expect(result.houses, 20);
      expect(result.apartmentBlocks, 0);
      expect(result.apartmentBoxes, 0);
    });

    test('cluster extent is bounded, so nothing spans a street', () {
      // Leader clustering caps a cluster at twice the radius, so a long run of
      // tightly-spaced boxes breaks into several clusters rather than one
      // chain. 40 boxes 1 m apart span 39 m — far beyond any single entrance.
      final groups = LetterboxClusters.group([
        for (var i = 0; i < 40; i++) north(base, i * 1.0),
      ]);

      expect(groups.blocks.length, greaterThan(1),
          reason: 'a 39 m run must never be reported as a single block');
      for (final block in groups.blocks) {
        expect(block.count, lessThan(40),
            reason: 'no cluster may swallow the whole run');
      }
    });

    test('houses on normal plots do not merge into a block', () {
      // ~20 m frontages: distinct addresses, and they must stay that way.
      final result = LetterboxClusters.breakdown([
        for (var i = 0; i < 6; i++) north(base, i * 20.0),
      ]);

      expect(result.houses, 6);
      expect(result.apartmentBlocks, 0);
    });

    test('a real bank of boxes at one door still groups', () {
      // 12 boxes logged within 4 m of a single entrance.
      final result = LetterboxClusters.breakdown([
        for (var i = 0; i < 12; i++) north(base, i * 0.35),
      ]);

      expect(result.apartmentBlocks, 1);
      expect(result.apartmentBoxes, 12);
      expect(result.houses, 0);
    });

    test('empty and single-point sets', () {
      expect(LetterboxClusters.breakdown(const []).total, 0);
      final one = LetterboxClusters.breakdown([base]);
      expect(one.houses, 1);
      expect(one.apartmentBlocks, 0);
    });

    test('totals always reconcile', () {
      final blockAt = north(base, 80);
      final points = [
        base,
        north(base, 25),
        blockAt,
        north(blockAt, 2),
        north(blockAt, 4),
      ];
      final result = LetterboxClusters.breakdown(points);

      expect(result.houses + result.apartmentBoxes, result.total,
          reason: 'every letterbox is either freestanding or in a block');
    });

    test('stays fast on a dense suburb', () {
      final points = [
        for (var i = 0; i < 4000; i++)
          LatLng(base.latitude + (i % 80) * 0.0002,
              base.longitude + (i ~/ 80) * 0.0002),
      ];

      final sw = Stopwatch()..start();
      final result = LetterboxClusters.breakdown(points);
      sw.stop();

      expect(result.total, 4000);
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });
  });

  group('group() — what the map draws', () {
    test('a block reports its centre, not its first box', () {
      // The pin must sit at the entrance, not on whichever box happened to be
      // logged first, or it drifts off the door on a wide bank.
      // 0.8 m spacing: comfortably inside the radius, so the whole bank is one
      // cluster without sitting on the floating-point boundary at exactly 5 m.
      final boxes = [
        for (var i = 0; i < 6; i++) north(base, i * 0.8),
      ];
      final groups = LetterboxClusters.group(boxes);

      expect(groups.blocks, hasLength(1));
      expect(groups.blocks.first.count, 6);
      expect(groups.blocks.first.centre.latitude,
          closeTo(north(base, 2.0).latitude, 1e-9),
          reason: 'centroid of the six boxes, not the first one');
    });

    test('houses come back individually, blocks as one entry each', () {
      final blockAt = north(base, 200);
      final groups = LetterboxClusters.group([
        base,
        north(base, 30),
        north(base, 60),
        for (var i = 0; i < 5; i++) north(blockAt, i * 0.4),
      ]);

      expect(groups.houses, hasLength(3));
      expect(groups.blocks, hasLength(1));
      expect(groups.blocks.first.count, 5);
    });

    test('breakdown and group always agree', () {
      // breakdown is derived from group, so a divergence would mean the number
      // in the toolbar disagreed with the pins on the map.
      final points = [
        for (var i = 0; i < 12; i++) north(base, i * 20.0),
        for (var i = 0; i < 5; i++) north(base, 400 + i * 0.5),
      ];

      final groups = LetterboxClusters.group(points);
      final b = LetterboxClusters.breakdown(points);

      expect(b.houses, groups.houses.length);
      expect(b.apartmentBlocks, groups.blocks.length);
      expect(b.apartmentBoxes, groups.apartmentBoxes);
      expect(b.houses + b.apartmentBoxes, points.length);
    });

    test('an empty set produces nothing to draw', () {
      final groups = LetterboxClusters.group(const []);
      expect(groups.houses, isEmpty);
      expect(groups.blocks, isEmpty);
      expect(groups.breakdown.total, 0);
    });
  });

  group('minimum block size', () {
    test('a pair sharing a spot is two houses, not a block', () {
      // Semi-detached, a duplex, or a granny flat behind a house. Counting
      // every such pair as an apartment block inflated the figure badly.
      final result = LetterboxClusters.breakdown([base, north(base, 1)]);

      expect(result.houses, 2);
      expect(result.apartmentBlocks, 0);
      expect(result.apartmentBoxes, 0);
    });

    test('the threshold bites exactly at minBlockBoxes', () {
      List<LatLng> boxes(int n) =>
          [for (var i = 0; i < n; i++) north(base, i * 0.4)];

      final below = LetterboxClusters.breakdown(
          boxes(LetterboxClusters.minBlockBoxes - 1));
      final at =
          LetterboxClusters.breakdown(boxes(LetterboxClusters.minBlockBoxes));

      expect(below.apartmentBlocks, 0);
      expect(below.houses, LetterboxClusters.minBlockBoxes - 1);
      expect(at.apartmentBlocks, 1);
      expect(at.apartmentBoxes, LetterboxClusters.minBlockBoxes);
    });

    test('the total is untouched by where the threshold sits', () {
      final points = [
        base,
        north(base, 1),
        north(base, 2),
        for (var i = 0; i < 7; i++) north(base, 200 + i * 0.4),
      ];

      for (final min in [2, 3, 5, 8]) {
        final b = LetterboxClusters.breakdown(points, minBlock: min);
        expect(b.houses + b.apartmentBoxes, points.length,
            reason: 'the threshold changes the split, never the total');
      }
    });
  });
}
