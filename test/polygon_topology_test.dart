import 'package:clmschedule/shareable_maps/utils/polygon_topology.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

const base = LatLng(-33.975, 18.465); // Newlands, Cape Town.

const _mPerDegLat = 110574.0;
const _mPerDegLng = 92450.0; // ~111320 * cos(-33.975)

/// A position [north] metres up and [east] metres across from [base].
LatLng at(double east, double north) => LatLng(
      base.latitude + north / _mPerDegLat,
      base.longitude + east / _mPerDegLng,
    );

TopologyRing ring(String name, List<LatLng> points) =>
    TopologyRing(layerId: 'l1', polygonIndex: 0, name: name, points: points);

/// A square with its lower-left corner at ([east], [north]) metres from base.
List<LatLng> square(double east, double north, double size) => [
      at(east, north),
      at(east + size, north),
      at(east + size, north + size),
      at(east, north + size),
    ];

void main() {
  group('analyze', () {
    test('reports the gap between two nearly-adjacent squares', () {
      // Second square starts 8 m east of the first one's right edge.
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(108, 0, 100)),
      ];

      final report = PolygonTopology.analyze(rings, toleranceMetres: 20);

      expect(report.ringCount, 2);
      expect(report.overlaps, isEmpty);
      expect(report.gaps, hasLength(1));
      expect(report.gaps.first.metres, closeTo(8, 0.5));
    });

    test('a gap wider than the tolerance is reported, not swallowed', () {
      // 40 m apart: too wide to snap, but it is a hole in the map and the
      // operator has to be told — reporting only fixable gaps is how a
      // "clean" verdict ends up printed over a visible sliver.
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(140, 0, 100)),
      ];

      final report = PolygonTopology.analyze(rings, toleranceMetres: 20);

      expect(report.gaps, isEmpty, reason: 'not fixable at this tolerance');
      expect(report.wideGaps, hasLength(1));
      expect(report.wideGaps.first.metres, closeTo(40, 0.5));
      expect(report.isClean, isFalse);
      expect(report.toleranceToCloseAllGaps, greaterThan(40));
    });

    test('raising the tolerance moves a wide gap into snapping range', () {
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(140, 0, 100)),
      ];

      final needed = PolygonTopology.analyze(rings, toleranceMetres: 20)
          .toleranceToCloseAllGaps!;
      final report = PolygonTopology.analyze(rings, toleranceMetres: needed);

      expect(report.wideGaps, isEmpty);
      expect(report.gaps, hasLength(1));

      final fix = PolygonTopology.snap(rings, toleranceMetres: needed);
      expect(
          PolygonTopology.analyze(fix.rings, toleranceMetres: needed).isClean,
          isTrue);
    });

    test('polygons in different parts of town are not called neighbours', () {
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(5000, 0, 100)),
      ];

      final report = PolygonTopology.analyze(rings, toleranceMetres: 20);

      expect(report.gaps, isEmpty);
      expect(report.wideGaps, isEmpty);
      expect(report.isClean, isTrue);
    });

    test('touching squares are clean — a shared edge is not a gap', () {
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(100, 0, 100)),
      ];

      expect(
          PolygonTopology.analyze(rings, toleranceMetres: 20).isClean, isTrue);
    });

    test('measures the area two overlapping squares double-cover', () {
      // 10 m of the 100 m width overlaps → 10 x 100 = 1 000 m².
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(90, 0, 100)),
      ];

      final report = PolygonTopology.analyze(rings, toleranceMetres: 20);

      expect(report.overlaps, hasLength(1));
      expect(report.overlaps.first.approxAreaSqMetres, closeTo(1000, 150));
      expect(report.gaps, isEmpty);
    });
  });

  group('snap', () {
    test('welds two corners that miss each other by a few metres', () {
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(106, 0, 100)),
      ];

      final fix = PolygonTopology.snap(rings, toleranceMetres: 20);

      expect(fix.changed, hasLength(2),
          reason: 'both sides meet in the middle');
      expect(fix.verticesMoved, 4);

      final after = PolygonTopology.analyze(fix.rings, toleranceMetres: 20);
      expect(after.gaps, isEmpty);
      expect(after.overlaps, isEmpty);

      // The shared corners are now literally the same coordinate.
      final a = fix.rings[0].points, b = fix.rings[1].points;
      expect(a.any((p) => b.contains(p)), isTrue);
    });

    test('closes a gap where the two sides have different vertex counts', () {
      // A's right edge runs 0→100 in one segment; B's left edge has an extra
      // vertex halfway up, 6 m short of A. Welding alone cannot fix this —
      // the middle vertex has to be inserted into A's edge.
      final a = square(0, 0, 100);
      final b = [
        at(106, 0),
        at(206, 0),
        at(206, 100),
        at(106, 100),
        at(106, 50),
      ];
      final fix = PolygonTopology.snap([ring('A', a), ring('B', b)],
          toleranceMetres: 20);

      expect(fix.verticesInserted, greaterThan(0));
      final after = PolygonTopology.analyze(fix.rings, toleranceMetres: 20);
      expect(after.gaps, isEmpty);
      expect(after.overlaps, isEmpty);
    });

    test('removes a small overlap by pulling both edges together', () {
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(94, 0, 100)),
      ];

      expect(PolygonTopology.analyze(rings, toleranceMetres: 20).overlaps,
          hasLength(1));

      final fix = PolygonTopology.snap(rings, toleranceMetres: 20);
      final after = PolygonTopology.analyze(fix.rings, toleranceMetres: 20);

      expect(after.overlaps, isEmpty);
      expect(after.gaps, isEmpty);
    });

    test('leaves an overlap wider than the tolerance alone', () {
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(60, 0, 100)),
      ];

      final fix = PolygonTopology.snap(rings, toleranceMetres: 20);

      expect(fix.changed, isEmpty,
          reason: 'a 40 m overlap is a drawing '
              'mistake, not rounding — it must not be clipped silently');
      expect(PolygonTopology.analyze(fix.rings, toleranceMetres: 20).overlaps,
          hasLength(1));
    });

    test('polygons nowhere near each other are untouched', () {
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(5000, 5000, 100)),
      ];

      expect(PolygonTopology.snap(rings, toleranceMetres: 20).isEmpty, isTrue);
    });

    test('never pinches a narrow neck of one polygon shut', () {
      // A U-shape whose throat is 10 m wide — inside the tolerance, but the
      // two sides belong to the SAME ring, so welding must not close it.
      final u = [
        at(0, 0),
        at(50, 0),
        at(50, 100),
        at(30, 100),
        at(30, 20),
        at(20, 20),
        at(20, 100),
        at(0, 100),
      ];
      final fix = PolygonTopology.snap([ring('U', u)], toleranceMetres: 20);

      expect(fix.isEmpty, isTrue);
      expect(fix.rings.first.points, hasLength(u.length));
    });

    test('drops duplicate vertices left by double-clicks while drawing', () {
      final points = [
        at(0, 0),
        at(0, 0), // same spot, clicked twice
        at(100, 0),
        at(100, 100),
        at(0, 100),
      ];

      final fix =
          PolygonTopology.snap([ring('A', points)], toleranceMetres: 20);

      expect(fix.verticesRemoved, 1);
      expect(fix.rings.first.points, hasLength(4));
    });

    test('a corner is never dragged further than the tolerance allows', () {
      final rings = [
        ring('A', square(0, 0, 100)),
        ring('B', square(115, 0, 100)),
      ];

      final fix = PolygonTopology.snap(rings, toleranceMetres: 20);
      for (var r = 0; r < rings.length; r++) {
        final before = rings[r].points;
        final after = fix.rings[r].points;
        for (var i = 0; i < before.length && i < after.length; i++) {
          final dy = (before[i].latitude - after[i].latitude) * _mPerDegLat;
          final dx = (before[i].longitude - after[i].longitude) * _mPerDegLng;
          expect((dx * dx + dy * dy), lessThan(20 * 20 + 1));
        }
      }
    });
  });

  group('snapPosition', () {
    final existing = [ring('A', square(0, 0, 100))];

    test('a click near a corner becomes that exact corner', () {
      final result = PolygonTopology.snapPosition(at(103, 4), existing);

      expect(result.kind, SnapKind.vertex);
      // Not "close to" — the same coordinate, which is what makes the
      // boundary shared rather than merely adjacent.
      expect(result.position, existing.first.points[1]);
    });

    test('a click near an edge drops onto the edge', () {
      final result = PolygonTopology.snapPosition(at(107, 50), existing);

      expect(result.kind, SnapKind.edge);
      expect(
          PolygonTopology.snapPosition(result.position, existing).movedMetres,
          lessThan(0.5),
          reason: 'the snapped point now sits on the boundary');
    });

    test('a corner wins over an edge that happens to be nearer', () {
      // 6 m past the corner along the edge line: 6 m from the corner, ~0 m
      // from the edge. Reusing the corner keeps three areas meeting at one
      // point instead of three points a metre apart.
      final result = PolygonTopology.snapPosition(at(100, 6), existing);

      expect(result.kind, SnapKind.vertex);
    });

    test('a click in open ground is left where it was put', () {
      final raw = at(400, 400);
      final result = PolygonTopology.snapPosition(raw, existing);

      expect(result.kind, SnapKind.none);
      expect(result.snapped, isFalse);
      expect(result.position, raw);
    });

    test('the excluded polygon does not attract its own vertices', () {
      final result = PolygonTopology.snapPosition(
        at(103, 4),
        existing,
        exclude: (r) => r.name == 'A',
      );

      expect(result.kind, SnapKind.none);
    });
  });

  group('focused snap', () {
    test('stitches the new polygon in without touching other seams', () {
      // A and B already share a boundary. C is drawn against B, 5 m short.
      final a = square(0, 0, 100);
      final b = square(100, 0, 100);
      final c = square(205, 0, 100);
      final rings = [ring('A', a), ring('B', b), ring('C', c)];

      final fix = PolygonTopology.snap(rings, toleranceMetres: 15, focus: {2});

      expect(fix.changed, contains(2));
      expect(fix.changed, isNot(contains(0)),
          reason: 'A was nowhere near the edit and must not be reworked');

      final after = PolygonTopology.analyze(fix.rings, toleranceMetres: 15);
      expect(after.gaps, isEmpty);
      expect(after.wideGaps, isEmpty);
      expect(after.overlaps, isEmpty);
    });

    test('a snapped-then-drawn polygon needs no repair at all', () {
      // What snapping at draw time produces: every vertex of the new shape is
      // already one of its neighbour's coordinates.
      final a = square(0, 0, 100);
      final drawn = [a[1], at(200, 0), at(200, 100), a[2]];
      final rings = [ring('A', a), ring('B', drawn)];

      expect(
          PolygonTopology.analyze(rings, toleranceMetres: 20).isClean, isTrue);
      expect(PolygonTopology.snap(rings, toleranceMetres: 20).isEmpty, isTrue);
    });
  });
}
