import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../letterbox/utils/letterbox_geometry.dart';
import '../../track_editor/services/point_in_polygon.dart';

/// Boundary hygiene for hand-drawn polygons.
///
/// Areas drawn by hand on adjacent streets never land on identical
/// coordinates: two edges that were meant to be the same line end up a few
/// metres apart, leaving either a sliver of ground in NO polygon (a gap) or a
/// sliver in BOTH (an overlap). Neither is visible at the zoom the drawing was
/// done at, and both corrupt letterbox counts — a gap loses boxes off the
/// quote, an overlap bills the same boxes twice.
///
/// This is the classic GIS "snap / clean topology" pass, scoped to what the
/// map editor actually needs:
///
///  * **Vertex welding** — vertices of DIFFERENT polygons that sit within the
///    tolerance of each other are moved to their common centroid, so both
///    polygons end at exactly the same corner.
///  * **Vertex-to-edge snapping** — a vertex of one polygon that sits within
///    the tolerance of another polygon's edge is inserted INTO that edge, so
///    the neighbour's boundary passes exactly through it. This is what closes
///    a gap along a shared run of boundary, where the two sides have a
///    different number of vertices.
///
/// Both are limited by [defaultToleranceMetres]: anything further apart than
/// the tolerance is left alone and reported instead. A 40 m overlap is a
/// drawing mistake, not rounding, and silently clipping it would destroy real
/// data — so [analyze] names those pairs and the operator fixes them by hand.
///
/// All maths runs in a local metre plane (equirectangular, anchored at the
/// data's own centre). Over a metro area that is accurate to well under the
/// centimetre that matters here, and it is far cheaper than great-circle
/// distance run per vertex-edge pair.
class PolygonTopology {
  const PolygonTopology._();

  /// Default snapping distance. Twenty metres is about a suburban stand's
  /// frontage — wide enough to catch every hand-drawn miss, narrow enough
  /// that it can never pull a boundary across a street into ground that was
  /// never drawn.
  static const double defaultToleranceMetres = 20.0;

  /// Two positions closer than this are the same position. Below any drawing
  /// precision, so welding at this distance is a no-op that only removes
  /// duplicates.
  static const double _weldMetres = 0.05;

  /// A cluster of welded vertices may not span more than this multiple of the
  /// tolerance. Without the cap, a chain of vertices each within tolerance of
  /// the next could drag a corner an unbounded distance.
  static const double _maxClusterSpanFactor = 1.5;

  static const double _metresPerDegreeLat = 110574.0;

  // ── Analysis ─────────────────────────────────────────────────────────

  /// How far past the tolerance [analyze] still looks for neighbours, as a
  /// multiple of it. A seam too wide to snap is exactly the one an operator
  /// needs told about — reporting only what the fix can already handle is how
  /// a dialog ends up calling a map clean while a 40 m sliver sits in it.
  static const double _wideGapFactor = 6.0;

  /// Ceiling on that search, so a report on a city-wide map does not list
  /// every pair of areas in different suburbs as "nearly adjacent".
  static const double _maxWideGapMetres = 400.0;

  /// Find the gaps and overlaps between [rings] without changing anything.
  ///
  /// [toleranceMetres] separates the two classes of gap. One at or under the
  /// tolerance is rounding, and [snap] closes it. A wider one is a drawing
  /// mistake — it lands in [TopologyReport.wideGaps] with its measured width,
  /// for the operator to close by raising the tolerance deliberately or by
  /// drawing the missing strip. Overlaps are reported whatever their size,
  /// because an overlap always double-counts.
  ///
  /// [neighbourRadiusMetres] bounds how far apart two outlines can be and
  /// still be called neighbours at all; past it they are simply two different
  /// places on the map.
  static TopologyReport analyze(
    List<TopologyRing> rings, {
    double toleranceMetres = defaultToleranceMetres,
    double? neighbourRadiusMetres,
  }) {
    final radius = neighbourRadiusMetres ??
        math.min(toleranceMetres * _wideGapFactor, _maxWideGapMetres);
    final searchRadius = math.max(radius, toleranceMetres);

    final valid = <int>[];
    for (var i = 0; i < rings.length; i++) {
      if (rings[i].points.length >= 3) valid.add(i);
    }

    final gaps = <BoundaryGap>[];
    final wideGaps = <BoundaryGap>[];
    final overlaps = <BoundaryOverlap>[];

    for (var ii = 0; ii < valid.length; ii++) {
      for (var jj = ii + 1; jj < valid.length; jj++) {
        final i = valid[ii], j = valid[jj];
        final a = rings[i].points, b = rings[j].points;

        // Cheap bbox reject first — most pairs on a map are nowhere near
        // each other.
        if (!_boxesWithin(a, b, searchRadius)) continue;

        // Two independent overlap tests, because neither alone is enough.
        // The outline test catches slivers too thin to land a sample in, but
        // misses a band overlap whose ends are flush — no vertex of either
        // shape is then strictly inside the other and no pair of edges
        // properly crosses. The sampled area catches exactly that case, and
        // is needed anyway to say how much ground is double-covered.
        final overlapArea = _overlapAreaSqMetres(a, b);
        if (overlapArea > 0 || LetterboxGeometry.polygonsOverlap(a, b)) {
          overlaps.add(BoundaryOverlap(i, j, approxAreaSqMetres: overlapArea));
          continue;
        }

        // Disjoint pair: how far apart are the two outlines at their closest?
        final distance = _minOutlineDistance(a, b);
        if (distance <= _weldMetres) continue; // already sharing the boundary
        if (distance <= toleranceMetres) {
          gaps.add(BoundaryGap(i, j, metres: distance));
        } else if (distance <= searchRadius) {
          wideGaps.add(BoundaryGap(i, j, metres: distance));
        }
      }
    }

    gaps.sort((x, y) => y.metres.compareTo(x.metres));
    wideGaps.sort((x, y) => y.metres.compareTo(x.metres));
    overlaps
        .sort((x, y) => y.approxAreaSqMetres.compareTo(x.approxAreaSqMetres));

    return TopologyReport(
      ringCount: valid.length,
      skippedCount: rings.length - valid.length,
      toleranceMetres: toleranceMetres,
      neighbourRadiusMetres: searchRadius,
      gaps: gaps,
      wideGaps: wideGaps,
      overlaps: overlaps,
      snappableVertices: _countSnappableVertices(rings, toleranceMetres),
    );
  }

  // ── The fix ──────────────────────────────────────────────────────────

  /// Weld and snap [rings] to each other, returning the corrected geometry.
  ///
  /// The input is never mutated. The result holds one entry per input ring in
  /// the same order — rings with fewer than three points, and rings nothing
  /// snapped to, come back byte-for-byte unchanged, and [TopologyFix.changed]
  /// says which ones actually moved.
  ///
  /// [focus] narrows the pass to seams that involve those rings. Passing the
  /// polygon that was just drawn marries it to its neighbours without
  /// touching any other seam on the map — what you want right after an edit,
  /// where a full pass would quietly rework boundaries the user never went
  /// near.
  static TopologyFix snap(
    List<TopologyRing> rings, {
    double toleranceMetres = defaultToleranceMetres,
    bool weldVertices = true,
    bool snapToEdges = true,
    Set<int>? focus,
  }) {
    final work = <List<LatLng>>[];
    var removed = 0;
    for (final ring in rings) {
      if (ring.points.length < 3) {
        work.add(List<LatLng>.from(ring.points));
        continue;
      }
      final deduped = _dedupe(ring.points);
      removed += ring.points.length - deduped.length;
      work.add(deduped.length >= 3 ? deduped : List<LatLng>.from(ring.points));
    }

    final origin = _origin(work);
    if (origin == null) {
      return TopologyFix(
        rings: rings,
        changed: const {},
        verticesMoved: 0,
        verticesInserted: 0,
        verticesRemoved: 0,
      );
    }
    final plane = _Plane(origin);

    var moved = 0;
    if (weldVertices) moved = _weld(work, plane, toleranceMetres, focus);

    var inserted = 0;
    if (snapToEdges) inserted = _snapToEdges(work, toleranceMetres, focus);

    // Welding can leave two adjacent vertices on the same spot; edge snapping
    // can insert one onto a vertex that was already there.
    for (var i = 0; i < work.length; i++) {
      if (work[i].length < 3) continue;
      final cleaned = _dedupe(work[i]);
      if (cleaned.length >= 3) {
        removed += work[i].length - cleaned.length;
        work[i] = cleaned;
      }
    }

    final changed = <int>{};
    final result = <TopologyRing>[];
    for (var i = 0; i < rings.length; i++) {
      if (_sameRing(rings[i].points, work[i])) {
        result.add(rings[i]);
      } else {
        changed.add(i);
        result.add(rings[i].withPoints(work[i]));
      }
    }

    return TopologyFix(
      rings: result,
      changed: changed,
      verticesMoved: moved,
      verticesInserted: inserted,
      verticesRemoved: removed,
    );
  }

  // ── Live snapping (while drawing) ────────────────────────────────────

  /// How close a click has to be to existing geometry before it is snapped
  /// onto it. Roughly a house frontage: close enough that snapping is always
  /// what the user meant, far enough to catch an imprecise click.
  static const double defaultSnapRadiusMetres = 15.0;

  /// Snap one position onto the geometry already on the map, so a new corner
  /// is the SAME coordinate as its neighbour's rather than merely near it.
  ///
  /// This is where "no gaps" actually comes from. Repairing seams afterwards
  /// can only guess which vertices were meant to be one; a click that lands
  /// on an existing corner never creates the ambiguity in the first place.
  ///
  /// An existing corner wins over an edge, even a slightly further one: a
  /// corner is a decision somebody already made, and reusing it exactly keeps
  /// three polygons meeting at one point instead of three points a metre
  /// apart. Failing that, the click drops onto the nearest edge — the foot of
  /// the perpendicular, which lies exactly on the neighbour's boundary.
  ///
  /// [exclude] names a ring to ignore, so a vertex being dragged is not
  /// snapped onto its own polygon.
  static SnapResult snapPosition(
    LatLng raw,
    List<TopologyRing> rings, {
    double radiusMetres = defaultSnapRadiusMetres,
    bool Function(TopologyRing ring)? exclude,
  }) {
    LatLng? bestVertex;
    var bestVertexDistance = double.infinity;
    LatLng? bestFoot;
    var bestEdgeDistance = double.infinity;

    for (final ring in rings) {
      if (ring.points.length < 2) continue;
      if (exclude != null && exclude(ring)) continue;

      for (var i = 0; i < ring.points.length; i++) {
        final v = ring.points[i];
        final d = _metres(raw, v);
        if (d <= radiusMetres && d < bestVertexDistance) {
          bestVertexDistance = d;
          bestVertex = v;
        }

        final a = v;
        final b = ring.points[(i + 1) % ring.points.length];
        final edgeDistance = LetterboxGeometry.metresToSegment(
            raw.latitude, raw.longitude, a, b);
        if (edgeDistance <= radiusMetres && edgeDistance < bestEdgeDistance) {
          final t = _projection(raw, a, b);
          if (t > 0 && t < 1) {
            bestEdgeDistance = edgeDistance;
            bestFoot = _pointAlong(a, b, t);
          }
        }
      }
    }

    if (bestVertex != null) {
      return SnapResult(bestVertex, SnapKind.vertex, bestVertexDistance);
    }
    if (bestFoot != null) {
      return SnapResult(bestFoot, SnapKind.edge, bestEdgeDistance);
    }
    return SnapResult(raw, SnapKind.none, 0);
  }

  /// The position a fraction [t] of the way from [a] to [b].
  static LatLng _pointAlong(LatLng a, LatLng b, double t) => LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );

  // ── Vertex welding ───────────────────────────────────────────────────

  /// Move mutually-close vertices of different rings onto a shared point.
  /// Returns how many vertices actually moved.
  static int _weld(List<List<LatLng>> rings, _Plane plane,
      double toleranceMetres, Set<int>? focus) {
    // Flatten every vertex into parallel arrays, indexed by a global id.
    final ringOf = <int>[];
    final vertexOf = <int>[];
    final xs = <double>[];
    final ys = <double>[];
    for (var r = 0; r < rings.length; r++) {
      if (rings[r].length < 3) continue;
      for (var v = 0; v < rings[r].length; v++) {
        final p = rings[r][v];
        ringOf.add(r);
        vertexOf.add(v);
        xs.add(plane.x(p));
        ys.add(plane.y(p));
      }
    }
    if (xs.isEmpty) return 0;

    // Grid hash at one cell per tolerance, so a vertex only has to look at
    // its own cell and the eight around it.
    final cell = math.max(toleranceMetres, 1.0);
    final buckets = <String, List<int>>{};
    for (var i = 0; i < xs.length; i++) {
      buckets
          .putIfAbsent('${(xs[i] / cell).floor()}:${(ys[i] / cell).floor()}',
              () => <int>[])
          .add(i);
    }

    final clusters = _ClusterSet(xs, ys, ringOf, vertexOf,
        ringLengths: rings.map((r) => r.length).toList(),
        maxSpan: toleranceMetres * _maxClusterSpanFactor);

    final toleranceSq = toleranceMetres * toleranceMetres;
    for (var i = 0; i < xs.length; i++) {
      final cx = (xs[i] / cell).floor();
      final cy = (ys[i] / cell).floor();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final neighbours = buckets['${cx + dx}:${cy + dy}'];
          if (neighbours == null) continue;
          for (final j in neighbours) {
            if (j <= i) continue;
            // Only ACROSS rings: welding a ring to itself would pinch a
            // narrow neck of that same shape shut.
            if (ringOf[i] == ringOf[j]) continue;
            if (focus != null &&
                !focus.contains(ringOf[i]) &&
                !focus.contains(ringOf[j])) {
              continue;
            }
            final ddx = xs[i] - xs[j];
            final ddy = ys[i] - ys[j];
            if (ddx * ddx + ddy * ddy > toleranceSq) continue;
            clusters.union(i, j);
          }
        }
      }
    }

    var moved = 0;
    clusters.forEachCluster((members) {
      if (members.length < 2) return;
      var sx = 0.0, sy = 0.0;
      for (final m in members) {
        sx += xs[m];
        sy += ys[m];
      }
      final target = plane.toLatLng(sx / members.length, sy / members.length);
      for (final m in members) {
        final ring = rings[ringOf[m]];
        final index = vertexOf[m];
        final before = ring[index];
        if (_metres(before, target) <= _weldMetres) continue;
        ring[index] = target;
        moved++;
      }
    });
    return moved;
  }

  // ── Vertex-to-edge snapping ──────────────────────────────────────────

  /// Insert each ring's vertices into any *other* ring's edge they sit close
  /// to, so the two boundaries share that point exactly. Returns how many
  /// vertices were inserted.
  ///
  /// Every insertion is computed against the same snapshot of the geometry
  /// and applied afterwards, so the result does not depend on the order the
  /// rings happen to be in.
  static int _snapToEdges(
      List<List<LatLng>> rings, double toleranceMetres, Set<int>? focus) {
    final boxes = rings.map(_Box.of).toList();
    // Per target ring: edge index → points to insert along that edge.
    final insertions = <int, Map<int, List<_Insertion>>>{};

    for (var target = 0; target < rings.length; target++) {
      final ring = rings[target];
      if (ring.length < 3) continue;
      final targetBox = boxes[target];
      if (targetBox == null) continue;

      for (var source = 0; source < rings.length; source++) {
        if (source == target) continue;
        if (focus != null &&
            !focus.contains(target) &&
            !focus.contains(source)) {
          continue;
        }
        final sourceBox = boxes[source];
        if (sourceBox == null) continue;
        if (!targetBox.within(sourceBox, toleranceMetres)) continue;

        for (final v in rings[source]) {
          var bestEdge = -1;
          var bestDistance = double.infinity;
          var bestT = 0.0;

          for (var e = 0; e < ring.length; e++) {
            final a = ring[e];
            final b = ring[(e + 1) % ring.length];
            final d = LetterboxGeometry.metresToSegment(
                v.latitude, v.longitude, a, b);
            if (d > toleranceMetres || d >= bestDistance) continue;
            final t = _projection(v, a, b);
            // Only along the middle of an edge: a vertex nearest to an
            // edge's endpoint is a welding case, already handled (or
            // deliberately not close enough to weld).
            if (t <= 0.001 || t >= 0.999) continue;
            bestEdge = e;
            bestDistance = d;
            bestT = t;
          }

          if (bestEdge < 0) continue;
          // Already effectively on the line — inserting would add a vertex
          // that changes nothing.
          if (bestDistance <= _weldMetres) continue;

          insertions
              .putIfAbsent(target, () => <int, List<_Insertion>>{})
              .putIfAbsent(bestEdge, () => <_Insertion>[])
              .add(_Insertion(bestT, v));
        }
      }
    }

    var inserted = 0;
    insertions.forEach((ringIndex, byEdge) {
      final ring = rings[ringIndex];
      final rebuilt = <LatLng>[];
      for (var e = 0; e < ring.length; e++) {
        rebuilt.add(ring[e]);
        final additions = byEdge[e];
        if (additions == null) continue;
        additions.sort((a, b) => a.t.compareTo(b.t));
        for (final addition in additions) {
          if (_metres(rebuilt.last, addition.position) <= _weldMetres) {
            continue;
          }
          rebuilt.add(addition.position);
          inserted++;
        }
      }
      rings[ringIndex] = rebuilt;
    });
    return inserted;
  }

  // ── Measurement helpers ──────────────────────────────────────────────

  /// How many vertices sit close enough to another ring's outline to be
  /// snapped, but are not on it yet. This is the size of the job [snap] would
  /// do, and reads to the operator as "N loose vertices".
  static int _countSnappableVertices(
      List<TopologyRing> rings, double toleranceMetres) {
    final outlines = rings.map((r) => r.points).toList();
    final boxes = outlines.map(_Box.of).toList();
    var count = 0;

    for (var i = 0; i < outlines.length; i++) {
      if (outlines[i].length < 3) continue;
      final boxI = boxes[i];
      if (boxI == null) continue;
      for (final v in outlines[i]) {
        for (var j = 0; j < outlines.length; j++) {
          if (i == j || outlines[j].length < 3) continue;
          final boxJ = boxes[j];
          if (boxJ == null || !boxI.within(boxJ, toleranceMetres)) continue;
          final d = LetterboxGeometry.metresToPolygon(
              v.latitude, v.longitude, outlines[j]);
          if (d > _weldMetres && d <= toleranceMetres) {
            count++;
            break;
          }
        }
      }
    }
    return count;
  }

  /// Closest approach between two outlines, in metres.
  ///
  /// For two shapes that do not intersect, the minimum is always reached at a
  /// vertex of one against an edge of the other, so checking both directions
  /// is exact rather than a sample.
  static double _minOutlineDistance(List<LatLng> a, List<LatLng> b) {
    var best = double.infinity;
    for (final v in a) {
      final d = LetterboxGeometry.metresToPolygon(v.latitude, v.longitude, b);
      if (d < best) best = d;
    }
    for (final v in b) {
      final d = LetterboxGeometry.metresToPolygon(v.latitude, v.longitude, a);
      if (d < best) best = d;
    }
    return best;
  }

  /// Rough area covered by both polygons, in square metres.
  ///
  /// Sampled on a grid over the overlapping part of the two bounding boxes
  /// rather than clipped exactly: this number exists to tell an operator
  /// whether an overlap is a 30 m² drawing slip or a 2 ha mistake, and a
  /// sampled figure answers that without a polygon-boolean implementation
  /// that would have to be correct for every self-touching hand-drawn shape.
  static double _overlapAreaSqMetres(List<LatLng> a, List<LatLng> b) {
    final boxA = _Box.of(a), boxB = _Box.of(b);
    if (boxA == null || boxB == null) return 0;

    final minLat = math.max(boxA.minLat, boxB.minLat);
    final maxLat = math.min(boxA.maxLat, boxB.maxLat);
    final minLng = math.max(boxA.minLng, boxB.minLng);
    final maxLng = math.min(boxA.maxLng, boxB.maxLng);
    if (maxLat <= minLat || maxLng <= minLng) return 0;

    const steps = 48; // 2 304 samples — plenty for an order of magnitude.
    final dLat = (maxLat - minLat) / steps;
    final dLng = (maxLng - minLng) / steps;
    final midLat = (minLat + maxLat) / 2;
    final cellArea = (dLat * _metresPerDegreeLat) *
        (dLng * 111320.0 * math.cos(midLat * math.pi / 180));

    var hits = 0;
    for (var i = 0; i < steps; i++) {
      final lat = minLat + (i + 0.5) * dLat;
      for (var j = 0; j < steps; j++) {
        final p = LatLng(lat, minLng + (j + 0.5) * dLng);
        if (isPointInPolygon(p, a) && isPointInPolygon(p, b)) hits++;
      }
    }
    return hits * cellArea;
  }

  // ── Small geometry helpers ───────────────────────────────────────────

  /// Drop vertices that repeat the one before them (and the closing vertex
  /// that repeats the first) — these carry no shape and break the
  /// vertex-to-edge projection.
  static List<LatLng> _dedupe(List<LatLng> points) {
    final out = <LatLng>[];
    for (final p in points) {
      if (out.isNotEmpty && _metres(out.last, p) <= _weldMetres) continue;
      out.add(p);
    }
    while (out.length > 1 && _metres(out.first, out.last) <= _weldMetres) {
      out.removeLast();
    }
    return out;
  }

  /// Where the foot of the perpendicular from [p] falls along a→b, as a
  /// fraction of the edge. Outside 0…1 the nearest point is an endpoint.
  static double _projection(LatLng p, LatLng a, LatLng b) {
    final mLng = 111320.0 * math.cos(p.latitude * math.pi / 180);
    final ax = a.longitude * mLng, ay = a.latitude * _metresPerDegreeLat;
    final bx = b.longitude * mLng, by = b.latitude * _metresPerDegreeLat;
    final px = p.longitude * mLng, py = p.latitude * _metresPerDegreeLat;
    final dx = bx - ax, dy = by - ay;
    final lengthSq = dx * dx + dy * dy;
    if (lengthSq == 0) return 0;
    return ((px - ax) * dx + (py - ay) * dy) / lengthSq;
  }

  static double _metres(LatLng a, LatLng b) {
    final mLng = 111320.0 * math.cos(a.latitude * math.pi / 180);
    final dx = (b.longitude - a.longitude) * mLng;
    final dy = (b.latitude - a.latitude) * _metresPerDegreeLat;
    return math.sqrt(dx * dx + dy * dy);
  }

  static bool _boxesWithin(
      List<LatLng> a, List<LatLng> b, double toleranceMetres) {
    final boxA = _Box.of(a), boxB = _Box.of(b);
    if (boxA == null || boxB == null) return false;
    return boxA.within(boxB, toleranceMetres);
  }

  static bool _sameRing(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].latitude != b[i].latitude || a[i].longitude != b[i].longitude) {
        return false;
      }
    }
    return true;
  }

  static LatLng? _origin(List<List<LatLng>> rings) {
    for (final ring in rings) {
      if (ring.isNotEmpty) return ring.first;
    }
    return null;
  }
}

/// One polygon taking part in a topology pass, tagged with where it lives so
/// the caller can write the corrected geometry back to the right place.
class TopologyRing {
  /// Layer holding the polygon.
  final String layerId;

  /// Position of the polygon within that layer's polygon list.
  final int polygonIndex;

  /// Display name, for the report the operator reads.
  final String name;

  final List<LatLng> points;

  const TopologyRing({
    required this.layerId,
    required this.polygonIndex,
    required this.name,
    required this.points,
  });

  TopologyRing withPoints(List<LatLng> newPoints) => TopologyRing(
        layerId: layerId,
        polygonIndex: polygonIndex,
        name: name,
        points: newPoints,
      );
}

/// What a live snap latched onto.
enum SnapKind {
  /// Nothing was near enough — the position is the raw click.
  none,

  /// Landed exactly on an existing polygon's corner, which is now shared.
  vertex,

  /// Landed on an existing polygon's edge, between two of its corners.
  edge,
}

/// One snapped position, and what it snapped to.
class SnapResult {
  final LatLng position;
  final SnapKind kind;

  /// How far the raw position moved, in metres.
  final double movedMetres;

  const SnapResult(this.position, this.kind, this.movedMetres);

  bool get snapped => kind != SnapKind.none;
}

/// Two polygons whose outlines nearly touch: ground that belongs to neither.
class BoundaryGap {
  /// Indexes into the ring list that was analysed.
  final int a;
  final int b;

  /// Closest approach between the two outlines.
  final double metres;

  const BoundaryGap(this.a, this.b, {required this.metres});
}

/// Two polygons covering some of the same ground: letterboxes counted twice.
class BoundaryOverlap {
  final int a;
  final int b;

  /// Sampled, not exact — see [PolygonTopology._overlapAreaSqMetres].
  final double approxAreaSqMetres;

  const BoundaryOverlap(this.a, this.b, {required this.approxAreaSqMetres});
}

/// What [PolygonTopology.analyze] found.
class TopologyReport {
  /// Polygons that took part (rings with at least three vertices).
  final int ringCount;

  /// Polygons ignored because they had fewer than three vertices.
  final int skippedCount;

  final double toleranceMetres;

  /// How far apart two outlines could be and still be measured as neighbours.
  final double neighbourRadiusMetres;

  /// Gaps the current tolerance can close.
  final List<BoundaryGap> gaps;

  /// Gaps too wide for the current tolerance: real holes between two areas,
  /// left for the operator rather than snapped shut behind their back.
  final List<BoundaryGap> wideGaps;

  final List<BoundaryOverlap> overlaps;

  /// Vertices sitting within the tolerance of another polygon's outline
  /// without being on it — what a fix would move or match up.
  final int snappableVertices;

  const TopologyReport({
    required this.ringCount,
    required this.skippedCount,
    required this.toleranceMetres,
    required this.neighbourRadiusMetres,
    required this.gaps,
    required this.wideGaps,
    required this.overlaps,
    required this.snappableVertices,
  });

  bool get isClean => gaps.isEmpty && wideGaps.isEmpty && overlaps.isEmpty;

  /// The widest gap the current tolerance can close, or null when there are
  /// none.
  double? get worstGapMetres => gaps.isEmpty ? null : gaps.first.metres;

  /// The widest gap of any kind, or null when there are none.
  double? get worstAnyGapMetres {
    final widest = [...gaps, ...wideGaps];
    if (widest.isEmpty) return null;
    return widest.map((g) => g.metres).reduce(math.max);
  }

  /// The tolerance that would bring every measured gap into snapping range.
  double? get toleranceToCloseAllGaps {
    final worst = worstAnyGapMetres;
    return worst == null ? null : worst.ceilToDouble() + 1;
  }

  /// Total ground double-covered, in square metres.
  double get totalOverlapSqMetres =>
      overlaps.fold(0.0, (sum, o) => sum + o.approxAreaSqMetres);
}

/// The corrected geometry from [PolygonTopology.snap].
class TopologyFix {
  /// One entry per input ring, in the same order. Unchanged rings are the
  /// original objects.
  final List<TopologyRing> rings;

  /// Indexes of the rings whose geometry actually changed.
  final Set<int> changed;

  final int verticesMoved;
  final int verticesInserted;
  final int verticesRemoved;

  const TopologyFix({
    required this.rings,
    required this.changed,
    required this.verticesMoved,
    required this.verticesInserted,
    required this.verticesRemoved,
  });

  bool get isEmpty => changed.isEmpty;
}

// ── Internals ──────────────────────────────────────────────────────────

/// Local metre plane anchored at a fixed origin, so every vertex on the map
/// shares one coordinate system (unlike [LetterboxGeometry.metresToSegment],
/// which re-centres on each query point).
class _Plane {
  final double lat0;
  final double lng0;
  final double metresPerDegreeLng;

  _Plane(LatLng origin)
      : lat0 = origin.latitude,
        lng0 = origin.longitude,
        metresPerDegreeLng =
            111320.0 * math.cos(origin.latitude * math.pi / 180);

  double x(LatLng p) => (p.longitude - lng0) * metresPerDegreeLng;
  double y(LatLng p) =>
      (p.latitude - lat0) * PolygonTopology._metresPerDegreeLat;

  LatLng toLatLng(double x, double y) => LatLng(
        lat0 + y / PolygonTopology._metresPerDegreeLat,
        lng0 + x / metresPerDegreeLng,
      );
}

/// Union-find over vertices, with two rules that keep a weld honest:
///
///  * a cluster may not grow wider than [maxSpan], so a chain of near-misses
///    cannot drag a corner an arbitrary distance; and
///  * a cluster may not contain two vertices of the same ring unless they are
///    neighbours in that ring, so welding can never fold a shape onto itself.
class _ClusterSet {
  final List<double> xs;
  final List<double> ys;
  final List<int> ringOf;
  final List<int> vertexOf;
  final List<int> ringLengths;
  final double maxSpan;

  final List<int> _parent;
  final Map<int, List<int>> _members = {};

  _ClusterSet(this.xs, this.ys, this.ringOf, this.vertexOf,
      {required this.ringLengths, required this.maxSpan})
      : _parent = List<int>.generate(xs.length, (i) => i) {
    for (var i = 0; i < xs.length; i++) {
      _members[i] = [i];
    }
  }

  int find(int i) {
    var root = i;
    while (_parent[root] != root) {
      root = _parent[root];
    }
    while (_parent[i] != root) {
      final next = _parent[i];
      _parent[i] = root;
      i = next;
    }
    return root;
  }

  void union(int i, int j) {
    final rootI = find(i), rootJ = find(j);
    if (rootI == rootJ) return;

    final merged = [..._members[rootI]!, ..._members[rootJ]!];
    if (!_spanOk(merged) || !_ringsOk(merged)) return;

    _parent[rootJ] = rootI;
    _members[rootI] = merged;
    _members.remove(rootJ);
  }

  bool _spanOk(List<int> members) {
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final m in members) {
      minX = math.min(minX, xs[m]);
      maxX = math.max(maxX, xs[m]);
      minY = math.min(minY, ys[m]);
      maxY = math.max(maxY, ys[m]);
    }
    final dx = maxX - minX, dy = maxY - minY;
    return math.sqrt(dx * dx + dy * dy) <= maxSpan;
  }

  /// Reject a merge that would pull two non-adjacent vertices of one ring
  /// onto the same point — that pinches the ring into a figure-of-eight.
  bool _ringsOk(List<int> members) {
    final byRing = <int, List<int>>{};
    for (final m in members) {
      byRing.putIfAbsent(ringOf[m], () => <int>[]).add(vertexOf[m]);
    }
    for (final entry in byRing.entries) {
      final indices = entry.value;
      if (indices.length < 2) continue;
      final n = ringLengths[entry.key];
      for (var i = 0; i < indices.length; i++) {
        for (var j = i + 1; j < indices.length; j++) {
          final raw = (indices[i] - indices[j]).abs();
          if (math.min(raw, n - raw) > 1) return false;
        }
      }
    }
    return true;
  }

  void forEachCluster(void Function(List<int> members) visit) {
    for (final members in _members.values) {
      visit(members);
    }
  }
}

class _Insertion {
  /// Position along the edge, 0…1.
  final double t;
  final LatLng position;
  const _Insertion(this.t, this.position);
}

class _Box {
  final double minLat, maxLat, minLng, maxLng;
  const _Box(this.minLat, this.maxLat, this.minLng, this.maxLng);

  static _Box? of(List<LatLng> points) {
    if (points.isEmpty) return null;
    var minLat = points.first.latitude, maxLat = minLat;
    var minLng = points.first.longitude, maxLng = minLng;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    return _Box(minLat, maxLat, minLng, maxLng);
  }

  /// Whether this box comes within [metres] of [other].
  bool within(_Box other, double metres) {
    final padLat = metres / PolygonTopology._metresPerDegreeLat;
    final midLat = (minLat + maxLat) / 2;
    final padLng = metres / (111320.0 * math.cos(midLat * math.pi / 180)).abs();
    return !(maxLat + padLat < other.minLat ||
        minLat - padLat > other.maxLat ||
        maxLng + padLng < other.minLng ||
        minLng - padLng > other.maxLng);
  }
}

/// Everything one boundary-cleanup run did, for the operator to read.
///
/// Carries both reports so the dialog can show the fix as a before/after —
/// "4 gaps, 2 overlaps" → "0 gaps, 1 overlap left" — rather than only
/// claiming success. [rings] is the geometry as it stands after the run, so
/// the indexes inside [after] can be turned back into polygon names.
class BoundaryCleanupOutcome {
  final List<TopologyRing> rings;
  final TopologyReport before;
  final TopologyReport after;
  final TopologyFix fix;

  /// Polygons whose letterbox estimate was recomputed because their shape
  /// moved. Zero when the caller asked to skip the recount.
  final int recounted;

  const BoundaryCleanupOutcome({
    required this.rings,
    required this.before,
    required this.after,
    required this.fix,
    required this.recounted,
  });

  /// Names of the polygon pairs that still overlap — the ones the tolerance
  /// could not explain away and a human has to redraw.
  List<String> get remainingOverlapPairs => after.overlaps
      .map((o) => '${rings[o.a].name} ↔ ${rings[o.b].name}')
      .toList();

  /// Names of the polygon pairs still separated by a gap — including the ones
  /// too wide for the tolerance that was used, which are the gaps still
  /// visible on the map after a fix that reported success.
  List<String> get remainingGapPairs => [...after.gaps, ...after.wideGaps]
      .map((g) =>
          '${rings[g.a].name} ↔ ${rings[g.b].name} (${g.metres.toStringAsFixed(1)} m)')
      .toList();
}
