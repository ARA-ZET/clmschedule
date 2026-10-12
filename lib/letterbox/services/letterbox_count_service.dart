import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../track_editor/services/point_in_polygon.dart';
import '../models/letterbox_suburb.dart';
import '../utils/letterbox_clusters.dart';
import '../utils/letterbox_geometry.dart';
import '../utils/letterbox_spatial_index.dart';
import 'letterbox_codec.dart';
import 'letterbox_firestore_service.dart';
import 'letterbox_storage_service.dart';

/// The result of counting letterboxes inside a polygon.
///
/// Carries provenance, not just a number. A count that includes unverified
/// suburbs must not be presented as fact — it may not be used to quote a
/// client or to accuse a distributor of underperforming — so callers get
/// [isTrusted] and [unverifiedSuburbs] alongside the total and are expected to
/// surface the difference.
class LetterboxCount {
  /// Letterboxes whose position falls inside the polygon.
  final int count;

  /// Suburb ids that contributed at least one candidate to this query.
  final List<String> suburbIds;

  /// Contributing suburbs that are not yet curated and signed off.
  final List<String> unverifiedSuburbs;

  /// Houses-versus-flats split of the letterboxes inside the polygon. Two areas
  /// with the same total are very different jobs if one is mostly blocks, so
  /// quoting wants this alongside the headline number.
  final LetterboxBreakdown breakdown;

  const LetterboxCount({
    required this.count,
    this.suburbIds = const [],
    this.unverifiedSuburbs = const [],
    this.breakdown = LetterboxBreakdown.empty,
  });

  static const empty = LetterboxCount(count: 0);

  /// True when every suburb this polygon touches has been verified.
  bool get isTrusted => unverifiedSuburbs.isEmpty;
}

/// Two polygons in a quote whose outlines genuinely overlap, by index into
/// the list that was passed to [LetterboxCountService.countUnion].
///
/// Sharing an edge or a corner — the normal result of drawing adjacent areas
/// by snapping — is NOT an overlap. This only fires when the two shapes cover
/// some of the same ground, which is the case that would silently double-bill
/// a client if counts were summed instead of unioned.
class PolygonOverlap {
  final int indexA;
  final int indexB;
  const PolygonOverlap(this.indexA, this.indexB);

  @override
  bool operator ==(Object other) =>
      other is PolygonOverlap &&
      other.indexA == indexA &&
      other.indexB == indexB;

  @override
  int get hashCode => Object.hash(indexA, indexB);

  @override
  String toString() => 'PolygonOverlap($indexA, $indexB)';
}

/// Result of counting several polygons together as one billable area.
///
/// [count] is a true union: a letterbox inside two overlapping polygons is
/// counted once, not twice. [overlaps] tells you WHY the union differs from
/// the sum of individually counting each polygon, so an unexpected overlap is
/// visible rather than silently folded into a smaller-than-expected total.
class LetterboxUnionResult {
  /// Distinct letterboxes inside the union of every polygon.
  final int count;

  final List<String> suburbIds;
  final List<String> unverifiedSuburbs;
  final LetterboxBreakdown breakdown;

  /// Letterboxes that fell outside every polygon exactly, but within the gap
  /// tolerance of one — a house-sized allowance for the small gaps that
  /// hand-drawn adjacent areas tend to leave between their edges. Reported
  /// separately so a materially large number is visible rather than an
  /// invisible correction to the bill.
  final int gapCapturedCount;

  /// Every pair of input polygons (by index) whose outlines genuinely
  /// overlap. A client map with two work areas that overlap should almost
  /// always be redrawn — this is what surfaces that before a quote goes out.
  final List<PolygonOverlap> overlaps;

  const LetterboxUnionResult({
    required this.count,
    this.suburbIds = const [],
    this.unverifiedSuburbs = const [],
    this.breakdown = LetterboxBreakdown.empty,
    this.gapCapturedCount = 0,
    this.overlaps = const [],
  });

  static const empty = LetterboxUnionResult(count: 0);

  bool get isTrusted => unverifiedSuburbs.isEmpty;

  bool get hasOverlaps => overlaps.isNotEmpty;
}

/// Counts curated letterbox positions inside an arbitrary polygon.
///
/// This is the primitive the whole letterbox system exists to provide. Client
/// map quoting, work-area tiering, suburb numbers and distributor performance
/// review are all thin callers of [countIn] — none of them should reimplement
/// counting, or the four features will drift apart and disagree.
///
/// How a query stays fast:
///  1. Take the polygon's bounding box.
///  2. Shortlist suburbs whose stored `bounds` intersect it — from the small
///     metadata documents, touching no payload files.
///  3. Lazily fetch and decode only those suburbs' gzipped payloads, caching
///     them for the session.
///  4. Ask each suburb's grid index for the candidates in the box, then run
///     the exact ray-cast only on those.
///
/// For a hand-drawn work area that is typically one suburb, ~4 KB fetched once,
/// and a few hundred exact tests — fast enough to recount on every tick while
/// a polygon is being drawn.
///
/// **Boundary behaviour.** The ray-cast uses a half-open rule, so a letterbox
/// lying exactly on the edge shared by two adjacent polygons is counted in
/// exactly one of them — provided the two polygons share bit-identical vertex
/// coordinates, which is what happens when areas are drawn by snapping. Where
/// two polygons were drawn independently and their "shared" edge differs by a
/// floating-point hair, a point on that seam can fall in both or neither. The
/// window is around 1e-15 degrees, so it is not a practical concern for
/// hand-drawn work areas, but it is the reason tiering should be driven from
/// one set of snapped polygons rather than from two independently drawn ones.
class LetterboxCountService {
  final LetterboxFirestoreService _firestore;
  final LetterboxStorageService _storage;

  /// Suburb metadata, loaded once per session. Small enough (613 docs, no
  /// geometry) that refetching per query would be pure waste.
  List<LetterboxSuburb>? _suburbs;
  Future<List<LetterboxSuburb>>? _suburbsInFlight;

  /// Decoded per-suburb indexes, keyed by suburb id.
  final Map<String, LetterboxSpatialIndex> _indexes = {};

  /// In-flight loads, so N concurrent queries over the same suburb trigger one
  /// download rather than N.
  final Map<String, Future<LetterboxSpatialIndex?>> _inFlight = {};

  /// Suburbs known to have no payload, so a miss is not retried every tick.
  final Set<String> _missing = {};

  LetterboxCountService({
    LetterboxFirestoreService? firestore,
    LetterboxStorageService? storage,
  })  : _firestore = firestore ?? LetterboxFirestoreService(),
        _storage = storage ?? LetterboxStorageService();

  // ── The primitive ────────────────────────────────────────────────────

  /// Count curated letterboxes inside [polygon].
  ///
  /// Returns [LetterboxCount.empty] for a degenerate polygon (fewer than three
  /// vertices), which is the normal state while a user is still placing the
  /// first points.
  Future<LetterboxCount> countIn(List<LatLng> polygon) async {
    if (polygon.length < 3) return LetterboxCount.empty;

    final box = LetterboxBounds.fromPoints(polygon);
    if (box == null) return LetterboxCount.empty;

    final candidates = await _suburbsOverlapping(box);
    if (candidates.isEmpty) return LetterboxCount.empty;

    final inside = <LatLng>[];
    final touched = <String>[];
    final unverified = <String>[];

    for (final suburb in candidates) {
      final index = await _indexFor(suburb);
      if (index == null || index.isEmpty) continue;

      final inBox = index.candidatesIn(box);
      if (inBox.isEmpty) continue;

      // Exact test. isPointInPolygon caches the polygon's bounding box against
      // the vertex list instance, so the cheap reject is shared across every
      // point in this loop rather than recomputed per point.
      var hits = 0;
      for (final p in inBox) {
        if (isPointInPolygon(p, polygon)) {
          inside.add(p);
          hits++;
        }
      }
      if (hits == 0) continue;

      touched.add(suburb.suburbId);
      if (!suburb.isTrusted) unverified.add(suburb.suburbId);
    }

    return LetterboxCount(
      count: inside.length,
      suburbIds: touched,
      unverifiedSuburbs: unverified,
      // Clustered across the whole selection, not per suburb: a block sitting
      // on a suburb boundary is still one block.
      breakdown: LetterboxClusters.breakdown(inside),
    );
  }

  /// Count several polygons in one pass.
  ///
  /// Cheaper than looping [countIn]: the suburb shortlist and every payload
  /// are resolved once for the union of all the boxes, so tiering 40 work areas
  /// across one suburb downloads that suburb once rather than 40 times.
  Future<List<LetterboxCount>> countInEach(List<List<LatLng>> polygons) async {
    if (polygons.isEmpty) return const [];

    // Warm the cache for everything the batch will touch, before counting.
    await prefetch(polygons);

    final results = <LetterboxCount>[];
    for (final polygon in polygons) {
      results.add(await countIn(polygon));
    }
    return results;
  }

  /// Load the suburb list and every letterbox payload [polygons] will need,
  /// all downloads at once rather than one after another. Counting afterwards
  /// is then pure in-memory work.
  ///
  /// Suburbs are shortlisted per polygon, not for one box around them all —
  /// work areas spread across a city would otherwise pull in every suburb
  /// between them. A payload that fails to load is left for the count itself
  /// to report, so this never throws for one.
  Future<void> prefetch(Iterable<List<LatLng>> polygons) async {
    final all = await _allSuburbs();
    final wanted = <String, LetterboxSuburb>{};
    for (final polygon in polygons) {
      final box = LetterboxBounds.fromPoints(polygon);
      if (box == null) continue;
      for (final s in all) {
        if (!s.hasPayload) continue;
        final b = s.bounds;
        if (b == null || b.intersects(box)) wanted[s.suburbId] = s;
      }
    }
    await Future.wait(wanted.values.map(
      (s) => _indexFor(s).then<void>((_) {}, onError: (_) {}),
    ));
  }

  /// Load the suburb list now, so the first count does not wait for it.
  Future<void> warmUp() async {
    try {
      await _allSuburbs();
    } catch (e) {
      debugPrint('[LetterboxCount] warm-up failed: $e');
    }
  }

  /// Default bridge distance for [countUnion]'s gap tolerance.
  ///
  /// Work areas on a client map are drawn much more tightly against each
  /// other than a suburb's road-centre boundary is against a house, so this
  /// is deliberately smaller than [defaultGapEdgeTolerance] equivalents used
  /// elsewhere in the module — big enough to bridge the couple of metres a
  /// hand-drawn edge misses by, small enough that it can never reach across a
  /// real gap into ground that was never actually quoted.
  static const double defaultGapToleranceMetres = 3.0;

  /// Count the union of several polygons as one billable area.
  ///
  /// This is the primitive for a client map with more than one work area.
  /// Two things it does that looping [countIn] and summing the results does
  /// NOT:
  ///
  ///  * **Overlaps are not double-counted.** Each letterbox is tested against
  ///    every polygon and contributes to the total at most once, however many
  ///    of the polygons contain it. [PolygonOverlap] entries in the result
  ///    name which input polygons actually share ground, which a simple sum
  ///    would hide inside an inflated number.
  ///  * **Small gaps between adjacent areas do not lose letterboxes.** Work
  ///    areas are hand-drawn, and two edges meant to be the same line rarely
  ///    land on identical coordinates. A letterbox sitting in that sliver is
  ///    genuinely being distributed to — it must not silently vanish from the
  ///    bill because of how the polygon was drawn. A point that misses every
  ///    polygon outright but sits within [gapToleranceMetres] of one is still
  ///    counted, and [LetterboxUnionResult.gapCapturedCount] says how many.
  ///
  /// Both corrections are reported, never silent: a result with overlaps or a
  /// non-trivial [LetterboxUnionResult.gapCapturedCount] should be shown to
  /// whoever is about to send the quote.
  ///
  /// This also absorbs the floating-point edge case documented on [countIn]:
  /// two polygons whose "shared" vertex was computed by arithmetic rather
  /// than typed as the same literal can differ by roughly a femtometre, which
  /// is enough to flip the exact ray-cast either way. If it flips toward
  /// "inside both", the OR-based match here still counts the point once, not
  /// twice. If it flips toward "inside neither", the true distance involved
  /// is far below any real gap tolerance, so [gapToleranceMetres] recovers it
  /// the same way it recovers a genuine hand-drawn gap. Either way the union
  /// is correct; only [countIn] on a single such polygon is exposed to it.
  Future<LetterboxUnionResult> countUnion(
    List<List<LatLng>> polygons, {
    double gapToleranceMetres = defaultGapToleranceMetres,
  }) async {
    final valid = polygons.where((p) => p.length >= 3).toList();
    if (valid.isEmpty) return LetterboxUnionResult.empty;

    final boxes = <LetterboxBounds>[];
    LetterboxBounds? unionBox;
    for (final polygon in valid) {
      final box = LetterboxBounds.fromPoints(polygon);
      if (box == null) continue;
      boxes.add(box);
      unionBox = unionBox == null ? box : _union(unionBox, box);
    }
    if (unionBox == null) return LetterboxUnionResult.empty;
    if (gapToleranceMetres > 0) {
      unionBox = _pad(unionBox, gapToleranceMetres);
    }

    // Overlap detection is independent of the point data — pure geometry
    // between the input shapes — so it runs regardless of whether any
    // suburb payload is even available yet.
    final overlaps = <PolygonOverlap>[];
    for (var i = 0; i < valid.length; i++) {
      for (var j = i + 1; j < valid.length; j++) {
        if (LetterboxGeometry.polygonsOverlap(valid[i], valid[j])) {
          overlaps.add(PolygonOverlap(i, j));
        }
      }
    }

    // Each polygon's own box, padded, so the per-point gap search below can
    // reject most polygons before running the (more expensive) exact edge
    // distance — the same short-circuit isPointInPolygon already does for the
    // exact test.
    final paddedBoxes = gapToleranceMetres > 0
        ? boxes.map((b) => _pad(b, gapToleranceMetres)).toList()
        : boxes;

    // A point only counts if it is inside a polygon or within the gap
    // tolerance of one, so only suburbs touching a padded polygon box can
    // contribute — not everything in the gaps of the box around them all.
    // Their payloads are then fetched together.
    final candidates = (await _suburbsOverlapping(unionBox))
        .where((s) =>
            s.bounds == null || paddedBoxes.any((b) => s.bounds!.intersects(b)))
        .toList();
    await Future.wait(candidates.map(
      (s) => _indexFor(s).then<void>((_) {}, onError: (_) {}),
    ));
    final inside = <LatLng>[];
    final touched = <String>{};
    final unverified = <String>{};
    var gapCaptured = 0;

    for (final suburb in candidates) {
      final index = await _indexFor(suburb);
      if (index == null || index.isEmpty) continue;

      final inBox = index.candidatesIn(unionBox);
      if (inBox.isEmpty) continue;

      var hits = 0;
      for (final p in inBox) {
        var matched = false;
        for (final polygon in valid) {
          if (isPointInPolygon(p, polygon)) {
            matched = true;
            break;
          }
        }

        var viaGap = false;
        if (!matched && gapToleranceMetres > 0) {
          for (var i = 0; i < valid.length; i++) {
            final pb = paddedBoxes[i];
            if (p.latitude < pb.minLat ||
                p.latitude > pb.maxLat ||
                p.longitude < pb.minLng ||
                p.longitude > pb.maxLng) {
              continue; // cheap reject before the per-edge distance below
            }
            if (LetterboxGeometry.metresToPolygon(
                    p.latitude, p.longitude, valid[i]) <=
                gapToleranceMetres) {
              matched = true;
              viaGap = true;
              break;
            }
          }
        }

        if (matched) {
          inside.add(p);
          hits++;
          if (viaGap) gapCaptured++;
        }
      }
      if (hits == 0) continue;

      touched.add(suburb.suburbId);
      if (!suburb.isTrusted) unverified.add(suburb.suburbId);
    }

    return LetterboxUnionResult(
      count: inside.length,
      suburbIds: touched.toList(),
      unverifiedSuburbs: unverified.toList(),
      breakdown: LetterboxClusters.breakdown(inside),
      gapCapturedCount: gapCaptured,
      overlaps: overlaps,
    );
  }

  /// Every curated point inside [box], for rendering. Capped per suburb so a
  /// zoomed-out viewport cannot produce an unbounded marker list.
  Future<List<LatLng>> pointsIn(LetterboxBounds box, {int limit = 2000}) async {
    final out = <LatLng>[];
    for (final suburb in await _suburbsOverlapping(box)) {
      final index = await _indexFor(suburb);
      if (index == null) continue;
      out.addAll(index.query(box, limit: limit - out.length));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Every suburb's metadata (name, curation status), keyed by suburb id.
  /// Served from the same once-per-session list [countIn] uses, so checking a
  /// stored count's provenance costs no extra reads.
  Future<Map<String, LetterboxSuburb>> suburbsById() async {
    final all = await _allSuburbs();
    return {for (final s in all) s.suburbId: s};
  }

  // ── Cache management ─────────────────────────────────────────────────

  /// Drop a suburb's cached payload so the next query refetches it. Call after
  /// curation saves that suburb, or its edits stay invisible for the session.
  void invalidate(String suburbId) {
    _indexes.remove(suburbId);
    _inFlight.remove(suburbId);
    _missing.remove(suburbId);
    _suburbs = null;
    _suburbsInFlight = null;
  }

  void invalidateAll() {
    _indexes.clear();
    _inFlight.clear();
    _missing.clear();
    _suburbs = null;
    _suburbsInFlight = null;
  }

  // ── Internals ────────────────────────────────────────────────────────

  Future<List<LetterboxSuburb>> _allSuburbs() {
    final cached = _suburbs;
    if (cached != null) return Future.value(cached);
    return _suburbsInFlight ??= _firestore.getAll().then((list) {
      _suburbs = list;
      _suburbsInFlight = null;
      return list;
    }).catchError((Object e) {
      _suburbsInFlight = null;
      throw e;
    });
  }

  /// Suburbs whose stored bounds intersect [box]. Bounds live on the metadata
  /// document precisely so this shortlist costs no payload downloads.
  Future<List<LetterboxSuburb>> _suburbsOverlapping(LetterboxBounds box) async {
    final all = await _allSuburbs();
    return all.where((s) {
      if (!s.hasPayload) return false;
      final b = s.bounds;
      // No bounds recorded — we cannot rule it out, so include it rather than
      // silently undercount.
      if (b == null) return true;
      return b.intersects(box);
    }).toList();
  }

  Future<LetterboxSpatialIndex?> _indexFor(LetterboxSuburb suburb) {
    final id = suburb.suburbId;
    final cached = _indexes[id];
    if (cached != null) return Future.value(cached);
    if (_missing.contains(id)) return Future.value(null);

    return _inFlight[id] ??= _loadIndex(id).whenComplete(() {
      _inFlight.remove(id);
    });
  }

  Future<LetterboxSpatialIndex?> _loadIndex(String suburbId) async {
    try {
      final bytes = await _storage.load(suburbId);
      if (bytes == null) {
        _missing.add(suburbId);
        return null;
      }
      final points = await LetterboxCodec.decodeAsync(bytes);
      final index = LetterboxSpatialIndex()..insertAll(points);
      _indexes[suburbId] = index;
      return index;
    } catch (e) {
      // Logged, not swallowed into a zero. A failed load must not read as
      // "this suburb has no letterboxes" — that would understate a quote.
      debugPrint('[LetterboxCount] failed to load $suburbId: $e');
      rethrow;
    }
  }

  /// Widen [box] by [metres] on every side. Used to make sure a padded
  /// bounding-box test cannot reject a point before the exact edge-distance
  /// check gets to see it.
  static LetterboxBounds _pad(LetterboxBounds box, double metres) {
    final padLat = metres / 110574.0;
    final midLatRadians =
        (box.minLat + box.maxLat) / 2 * 3.141592653589793 / 180;
    final cosLat = math.cos(midLatRadians).abs().clamp(0.000001, 1.0);
    final padLng = padLat / cosLat;
    return LetterboxBounds(
      minLat: box.minLat - padLat,
      minLng: box.minLng - padLng,
      maxLat: box.maxLat + padLat,
      maxLng: box.maxLng + padLng,
    );
  }

  static LetterboxBounds _union(LetterboxBounds a, LetterboxBounds b) {
    return LetterboxBounds(
      minLat: a.minLat < b.minLat ? a.minLat : b.minLat,
      minLng: a.minLng < b.minLng ? a.minLng : b.minLng,
      maxLat: a.maxLat > b.maxLat ? a.maxLat : b.maxLat,
      maxLng: a.maxLng > b.maxLng ? a.maxLng : b.maxLng,
    );
  }
}
