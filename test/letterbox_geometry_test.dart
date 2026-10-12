import 'package:clmschedule/letterbox/utils/letterbox_geometry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

List<LatLng> square(double minLat, double minLng, double size) => [
      LatLng(minLat, minLng),
      LatLng(minLat, minLng + size),
      LatLng(minLat + size, minLng + size),
      LatLng(minLat + size, minLng),
    ];

void main() {
  group('metresToSegment / metresToPolygon', () {
    test('zero for a point on an edge', () {
      final poly = square(-33.93, 18.42, 0.01);
      // Midpoint of the southern edge.
      expect(
        LetterboxGeometry.metresToPolygon(-33.93, 18.425, poly),
        closeTo(0, 0.5),
      );
    });

    test('measures to the nearest edge, not the nearest vertex', () {
      // A long straight edge with vertices ~1.1 km apart; a point off the
      // middle of that edge must not be measured against the far vertices.
      final poly = square(-33.93, 18.42, 0.01);
      final d = LetterboxGeometry.metresToPolygon(-33.9250, 18.4300, poly);
      expect(d, lessThan(20));
    });
  });

  group('segmentsIntersect', () {
    test('crossing segments intersect', () {
      expect(
        LetterboxGeometry.segmentsIntersect(
          const LatLng(0, 0),
          const LatLng(2, 2),
          const LatLng(0, 2),
          const LatLng(2, 0),
        ),
        isTrue,
      );
    });

    test('parallel non-touching segments do not intersect', () {
      expect(
        LetterboxGeometry.segmentsIntersect(
          const LatLng(0, 0),
          const LatLng(1, 0),
          const LatLng(0, 1),
          const LatLng(1, 1),
        ),
        isFalse,
      );
    });

    test('segments sharing an endpoint are reported as touching', () {
      expect(
        LetterboxGeometry.segmentsIntersect(
          const LatLng(0, 0),
          const LatLng(1, 1),
          const LatLng(1, 1),
          const LatLng(2, 0),
        ),
        isTrue,
      );
    });
  });

  group('polygonsOverlap', () {
    test('disjoint squares do not overlap', () {
      final a = square(-33.93, 18.42, 0.01);
      final b = square(-33.93, 18.50, 0.01);
      expect(LetterboxGeometry.polygonsOverlap(a, b), isFalse);
    });

    test('squares sharing only an edge do NOT overlap', () {
      // Adjacent work areas drawn by snapping — must not be flagged.
      final a = square(-33.93, 18.42, 0.01);
      final b = square(-33.93, 18.43, 0.01);
      expect(LetterboxGeometry.polygonsOverlap(a, b), isFalse);
    });

    test('squares sharing only a corner do NOT overlap', () {
      final a = square(-33.93, 18.42, 0.01);
      final b = square(-33.92, 18.43, 0.01);
      expect(LetterboxGeometry.polygonsOverlap(a, b), isFalse);
    });

    test('overlapping squares (vertex inside the other) DO overlap', () {
      final a = square(-33.93, 18.42, 0.01);
      final b = square(-33.925, 18.425, 0.01); // shifted half a cell in
      expect(LetterboxGeometry.polygonsOverlap(a, b), isTrue);
    });

    test('crossing shapes with no vertex inside the other still overlap', () {
      // A tall thin rectangle crossing a wide thin rectangle, like a plus
      // sign — every vertex of each sits outside the other, so only the
      // edge-crossing test catches this.
      final vertical = [
        const LatLng(-33.930, 18.424),
        const LatLng(-33.930, 18.426),
        const LatLng(-33.920, 18.426),
        const LatLng(-33.920, 18.424),
      ];
      final horizontal = [
        const LatLng(-33.926, 18.420),
        const LatLng(-33.926, 18.430),
        const LatLng(-33.924, 18.430),
        const LatLng(-33.924, 18.420),
      ];
      for (final v in vertical) {
        expect(_inside(v, horizontal), isFalse);
      }
      for (final v in horizontal) {
        expect(_inside(v, vertical), isFalse);
      }
      expect(LetterboxGeometry.polygonsOverlap(vertical, horizontal), isTrue);
    });

    test('one polygon fully containing another overlaps', () {
      final outer = square(-33.94, 18.40, 0.05);
      final inner = square(-33.92, 18.42, 0.01);
      expect(LetterboxGeometry.polygonsOverlap(outer, inner), isTrue);
    });

    test('is symmetric', () {
      final a = square(-33.93, 18.42, 0.01);
      final b = square(-33.925, 18.425, 0.01);
      expect(LetterboxGeometry.polygonsOverlap(a, b),
          LetterboxGeometry.polygonsOverlap(b, a));
    });

    test('degenerate input never overlaps', () {
      expect(
          LetterboxGeometry.polygonsOverlap(
              const [], square(-33.9, 18.4, 0.01)),
          isFalse);
    });
  });
}

/// Simple ray-cast, independent of the production implementation, purely to
/// set up the plus-sign fixture above.
bool _inside(LatLng p, List<LatLng> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
        p.longitude <
            (b.longitude - a.longitude) *
                    (p.latitude - a.latitude) /
                    (b.latitude - a.latitude) +
                a.longitude) {
      inside = !inside;
    }
  }
  return inside;
}
