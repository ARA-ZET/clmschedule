import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../track_editor/services/point_in_polygon.dart';

/// Shared metric-geometry helpers for the letterbox module.
///
/// Distances are computed in an equirectangular projection centred on the
/// query point — accurate well beyond the tens-of-metres scale these are used
/// at (edge tolerance, gap bridging), and far cheaper than true great-circle
/// math run per edge or per point.
class LetterboxGeometry {
  const LetterboxGeometry._();

  /// Distance in metres from a position to the segment a-b.
  ///
  /// Projects into a local metre plane centred on the query point, then finds
  /// the nearest point on the segment by clamped projection.
  static double metresToSegment(double lat, double lng, LatLng a, LatLng b) {
    const metresPerDegreeLat = 110574.0;
    final metresPerDegreeLng = 111320.0 * math.cos(lat * math.pi / 180);

    final ax = (a.longitude - lng) * metresPerDegreeLng;
    final ay = (a.latitude - lat) * metresPerDegreeLat;
    final bx = (b.longitude - lng) * metresPerDegreeLng;
    final by = (b.latitude - lat) * metresPerDegreeLat;

    final dx = bx - ax;
    final dy = by - ay;
    final lengthSq = dx * dx + dy * dy;

    if (lengthSq == 0) return math.sqrt(ax * ax + ay * ay);

    var t = -(ax * dx + ay * dy) / lengthSq;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx;
    final cy = ay + t * dy;
    return math.sqrt(cx * cx + cy * cy);
  }

  /// Shortest distance in metres from a position to a polygon's outline.
  ///
  /// Measured against the edges, not the vertices: a boundary running straight
  /// for a long stretch has vertices far apart, so vertex distance would
  /// wrongly reject a point sitting right on the middle of an edge.
  static double metresToPolygon(double lat, double lng, List<LatLng> polygon) {
    var best = double.infinity;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      final d = metresToSegment(lat, lng, a, b);
      if (d < best) best = d;
    }
    return best;
  }

  /// Whether segment p1-p2 crosses or touches segment p3-p4.
  ///
  /// Standard orientation-based test, with the collinear/touching cases
  /// handled explicitly so two polygons that share an edge (drawn by
  /// snapping) are correctly reported as touching rather than missed by
  /// floating-point luck.
  static bool segmentsIntersect(LatLng p1, LatLng p2, LatLng p3, LatLng p4) {
    double cross(LatLng o, LatLng a, LatLng b) =>
        (a.longitude - o.longitude) * (b.latitude - o.latitude) -
        (a.latitude - o.latitude) * (b.longitude - o.longitude);

    final d1 = cross(p3, p4, p1);
    final d2 = cross(p3, p4, p2);
    final d3 = cross(p1, p2, p3);
    final d4 = cross(p1, p2, p4);

    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
      return true;
    }

    bool onSegment(LatLng p, LatLng q, LatLng r) =>
        math.min(p.latitude, r.latitude) <= q.latitude &&
        q.latitude <= math.max(p.latitude, r.latitude) &&
        math.min(p.longitude, r.longitude) <= q.longitude &&
        q.longitude <= math.max(p.longitude, r.longitude);

    if (d1 == 0 && onSegment(p3, p1, p4)) return true;
    if (d2 == 0 && onSegment(p3, p2, p4)) return true;
    if (d3 == 0 && onSegment(p1, p3, p2)) return true;
    if (d4 == 0 && onSegment(p1, p4, p2)) return true;
    return false;
  }

  /// Whether two polygon outlines genuinely overlap — not merely adjacent.
  ///
  /// True when either polygon has a vertex STRICTLY inside the other (catches
  /// full or partial containment) or any pair of edges properly crosses
  /// (catches the case where neither polygon's vertices sit inside the other,
  /// e.g. two quadrilaterals overlapping like a plus sign).
  ///
  /// Two polygons that only share an edge or a corner — the normal result of
  /// drawing adjacent areas by snapping — are deliberately NOT reported as
  /// overlapping: sharing a boundary is not covering the same ground twice.
  /// That is why this uses a boundary-aware "strictly inside" test rather than
  /// the ordinary ray-cast: a vertex sitting exactly on the other polygon's
  /// edge is ambiguous under a plain ray-cast (it can read as inside depending
  /// on which way that edge happens to run), and snapped, shared vertices are
  /// exactly the case this must not misfire on.
  static bool polygonsOverlap(List<LatLng> a, List<LatLng> b) {
    if (a.length < 3 || b.length < 3) return false;

    double minLat(List<LatLng> p) => p.map((e) => e.latitude).reduce(math.min);
    double maxLat(List<LatLng> p) => p.map((e) => e.latitude).reduce(math.max);
    double minLng(List<LatLng> p) => p.map((e) => e.longitude).reduce(math.min);
    double maxLng(List<LatLng> p) => p.map((e) => e.longitude).reduce(math.max);

    // Cheap reject before any point-in-polygon or segment work.
    if (maxLat(a) < minLat(b) ||
        minLat(a) > maxLat(b) ||
        maxLng(a) < minLng(b) ||
        minLng(a) > maxLng(b)) {
      return false;
    }

    for (final v in a) {
      if (_strictlyInside(v, b)) return true;
    }
    for (final v in b) {
      if (_strictlyInside(v, a)) return true;
    }

    for (var i = 0; i < a.length; i++) {
      final a1 = a[i];
      final a2 = a[(i + 1) % a.length];
      for (var j = 0; j < b.length; j++) {
        final b1 = b[j];
        final b2 = b[(j + 1) % b.length];
        // Proper crossing only — two edges that merely touch at a shared
        // endpoint (again, the snapped-vertex case) must not register.
        if (_properlyCrosses(a1, a2, b1, b2)) return true;
      }
    }
    return false;
  }

  /// True inside, false both outside AND exactly on the boundary. Ordinary
  /// [isPointInPolygon] cannot make that distinction — its half-open ray-cast
  /// rule assigns every boundary point to exactly one side, which is correct
  /// for "which polygon owns this letterbox" but wrong for "do these two
  /// shapes cover the same ground", where a shared boundary must read as
  /// neither.
  static bool _strictlyInside(LatLng p, List<LatLng> polygon) {
    for (var i = 0; i < polygon.length; i++) {
      if (_onSegment(p, polygon[i], polygon[(i + 1) % polygon.length])) {
        return false;
      }
    }
    return isPointInPolygon(p, polygon);
  }

  /// Whether [p] lies on the closed segment a-b, within a tolerance tight
  /// enough to catch snapped/shared vertices and floating-point jitter but
  /// far below any real-world gap between two distinct letterboxes.
  static bool _onSegment(LatLng p, LatLng a, LatLng b) {
    const eps = 1e-9;
    final cross = (b.longitude - a.longitude) * (p.latitude - a.latitude) -
        (b.latitude - a.latitude) * (p.longitude - a.longitude);
    if (cross.abs() > eps) return false;
    return p.latitude >= math.min(a.latitude, b.latitude) - eps &&
        p.latitude <= math.max(a.latitude, b.latitude) + eps &&
        p.longitude >= math.min(a.longitude, b.longitude) - eps &&
        p.longitude <= math.max(a.longitude, b.longitude) + eps;
  }

  /// True only for a transversal crossing — the two segments pass through
  /// each other. Segments that merely touch at a shared endpoint (the case
  /// [segmentsIntersect] deliberately also reports as true, for callers that
  /// need "do they touch at all") do not count here, because two adjacent
  /// polygons sharing a vertex must not be flagged as overlapping.
  static bool _properlyCrosses(LatLng p1, LatLng p2, LatLng p3, LatLng p4) {
    double cross(LatLng o, LatLng a, LatLng b) =>
        (a.longitude - o.longitude) * (b.latitude - o.latitude) -
        (a.latitude - o.latitude) * (b.longitude - o.longitude);

    final d1 = cross(p3, p4, p1);
    final d2 = cross(p3, p4, p2);
    final d3 = cross(p1, p2, p3);
    final d4 = cross(p1, p2, p4);

    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }
}
