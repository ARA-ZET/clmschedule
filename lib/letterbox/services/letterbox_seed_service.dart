import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';

import '../../services/gpx_storage_service.dart';
import '../../track_editor/services/point_in_polygon.dart';
import '../utils/letterbox_clusters.dart';
import '../utils/letterbox_geometry.dart';

/// Input for the off-isolate single-suburb seed pass.
class _SeedInput {
  final List<Uint8List> payloads;
  final List<LatLng> polygon;
  final double snapDegrees;

  const _SeedInput(this.payloads, this.polygon, this.snapDegrees);
}

/// One suburb's boundary, in the shape the multi-suburb pass needs.
class SeedSuburb {
  final String id;
  final String name;
  final List<LatLng> polygon;

  const SeedSuburb({
    required this.id,
    required this.name,
    required this.polygon,
  });
}

/// Input for the off-isolate all-suburbs seed pass.
@visibleForTesting
class SeedAllInput {
  final List<Uint8List> payloads;
  final List<SeedSuburb> suburbs;
  final double snapDegrees;

  /// Edge tolerance in metres; 0 disables snapping entirely.
  final double edgeToleranceMetres;

  const SeedAllInput(
    this.payloads,
    this.suburbs,
    this.snapDegrees, [
    this.edgeToleranceMetres = LetterboxSeedService.defaultEdgeToleranceMetres,
  ]);
}

/// Candidate positions for every suburb that got any, plus the totals needed
/// to sanity-check the pass.
class LetterboxSeedAllResult {
  final Map<String, List<LatLng>> bySuburb;
  final int totalDrops;
  final int insideDrops;

  /// Drops that fell outside every suburb boundary. A large number here means
  /// either the suburb layer does not cover where you distribute, or the
  /// boundaries are wrong — worth looking at before trusting the seed.
  final int unmatchedDrops;

  final List<String> skippedFolders;

  /// Set on the device-upload path: what the GPX files actually contained.
  final GpxScanResult? scan;

  /// Where the unmatched drops actually fell, capped at
  /// [maxUnmatchedSample]. Counting them is not enough to act on: seeing them
  /// against the suburb boundaries is what shows whether the layer has a hole,
  /// a boundary is wrong, or the file simply covers somewhere else.
  final List<LatLng> unmatchedSample;

  /// Drops that fell outside every boundary but within the edge tolerance of
  /// one, and were taken as belonging to it.
  final int snappedDrops;

  /// Ceiling on [unmatchedSample]. A third of a large file can land outside the
  /// suburb layer, and holding hundreds of thousands of points to draw a
  /// diagnostic would cost more than the diagnostic is worth.
  static const int maxUnmatchedSample = 20000;

  const LetterboxSeedAllResult({
    required this.bySuburb,
    required this.totalDrops,
    required this.insideDrops,
    required this.unmatchedDrops,
    this.skippedFolders = const [],
    this.scan,
    this.unmatchedSample = const [],
    this.snappedDrops = 0,
  });
}

/// What a seed pass produced.
class LetterboxSeedResult {
  /// Deduplicated candidate positions inside the suburb.
  final List<LatLng> points;

  /// Raw drops that fell inside the suburb, before dedup. The ratio of this to
  /// [points.length] is roughly how many times the average letterbox has been
  /// delivered to, which is a useful sanity check on a suburb.
  final int rawInsideCount;

  /// Folders that produced no readable compiled waypoints file.
  final List<String> skippedFolders;

  /// Set on the device-upload path: what the GPX files actually contained.
  /// Null for cloud-folder seeds, which read already-compiled waypoints.
  final GpxScanResult? scan;

  const LetterboxSeedResult({
    required this.points,
    required this.rawInsideCount,
    this.skippedFolders = const [],
    this.scan,
  });
}

/// Builds candidate letterbox positions for one suburb from the compiled GPX
/// waypoints already sitting in Cloud Storage.
///
/// This is the client-side twin of the Cloud Function seed. It exists so a
/// single suburb can be seeded and eyeballed before committing to a full
/// 613-suburb run — the same reason `GpxStorageService.regenerateCompiledFiles`
/// mirrors the server-side GPX compiler.
///
/// The output is explicitly *candidates*, never truth. A suburb is only
/// trusted once a human has curated it and marked it verified.
class LetterboxSeedService {
  /// Cell used to group drops that share an address, in degrees.
  ///
  /// Derived from [LetterboxClusters.clusterMetres]: one cell is one doorway,
  /// whether that is a house gate or the bank of boxes at a block's entrance.
  static const double defaultSnapDegrees =
      LetterboxClusters.clusterMetres / 110574.0;

  /// How far outside a suburb a drop may fall and still be taken as belonging
  /// to it.
  ///
  /// Boundaries here run down the middle of the road, so a house on the far
  /// side is genuinely a few metres outside its own suburb, and GPS drift adds
  /// a few more. Ten metres covers both without reaching across a road into
  /// the neighbouring suburb, which is roughly 15-20 m away.
  static const double defaultEdgeToleranceMetres = 10.0;

  final GpxStorageService _storage;

  LetterboxSeedService({GpxStorageService? storage})
      : _storage = storage ?? GpxStorageService();

  /// Seed [suburbPolygon] from the compiled waypoints of [folderPaths].
  Future<LetterboxSeedResult> seedFromFolders({
    required List<String> folderPaths,
    required List<LatLng> suburbPolygon,
    double snapDegrees = defaultSnapDegrees,
    void Function(int done, int total)? onProgress,
  }) async {
    if (suburbPolygon.length < 3) {
      return const LetterboxSeedResult(points: [], rawInsideCount: 0);
    }

    final payloads = <Uint8List>[];
    final skipped = <String>[];

    for (var i = 0; i < folderPaths.length; i++) {
      final folder = folderPaths[i].trim().replaceAll(RegExp(r'/+$'), '');
      try {
        final bytes = await _storage
            .downloadFileBytes('$folder/_compiled_waypoints.json');
        if (bytes == null) {
          skipped.add(folder);
        } else {
          payloads.add(bytes);
        }
      } catch (e) {
        debugPrint('[LetterboxSeed] $folder failed: $e');
        skipped.add(folder);
      }
      onProgress?.call(i + 1, folderPaths.length);
    }

    if (payloads.isEmpty) {
      return LetterboxSeedResult(
        points: const [],
        rawInsideCount: 0,
        skippedFolders: skipped,
      );
    }

    final result = await compute(
      _seedIsolate,
      _SeedInput(payloads, suburbPolygon, snapDegrees),
    );

    return LetterboxSeedResult(
      points: result.points,
      rawInsideCount: result.rawInsideCount,
      skippedFolders: skipped,
    );
  }

  /// Seed one suburb from GPX files picked off the user's device.
  ///
  /// Same classification and dedupe as the cloud path — only the source
  /// differs. Useful for waypoints that have not been uploaded to Cloud
  /// Storage yet, or for a one-off correction pass.
  Future<LetterboxSeedResult> seedFromGpxFiles({
    required List<Uint8List> gpxFiles,
    required List<LatLng> suburbPolygon,
    bool includeTrackPoints = false,
    double snapDegrees = defaultSnapDegrees,
  }) async {
    if (suburbPolygon.length < 3 || gpxFiles.isEmpty) {
      return const LetterboxSeedResult(points: [], rawInsideCount: 0);
    }

    final scan =
        await scanGpxFiles(gpxFiles, includeTrackPoints: includeTrackPoints);
    if (scan.payloads.isEmpty) {
      return LetterboxSeedResult(
          points: const [], rawInsideCount: 0, scan: scan);
    }

    final result = await compute(
      _seedIsolate,
      _SeedInput(scan.payloads, suburbPolygon, snapDegrees),
    );
    return LetterboxSeedResult(
      points: result.points,
      rawInsideCount: result.rawInsideCount,
      scan: scan,
    );
  }

  /// Seed **every** suburb from GPX files picked off the user's device.
  Future<LetterboxSeedAllResult> seedAllFromGpxFiles({
    required List<Uint8List> gpxFiles,
    required List<SeedSuburb> suburbs,
    bool includeTrackPoints = false,
    double snapDegrees = defaultSnapDegrees,
  }) async {
    if (suburbs.isEmpty || gpxFiles.isEmpty) {
      return const LetterboxSeedAllResult(
        bySuburb: {},
        totalDrops: 0,
        insideDrops: 0,
        unmatchedDrops: 0,
      );
    }

    final scan =
        await scanGpxFiles(gpxFiles, includeTrackPoints: includeTrackPoints);
    if (scan.payloads.isEmpty) {
      return LetterboxSeedAllResult(
        bySuburb: const {},
        totalDrops: 0,
        insideDrops: 0,
        unmatchedDrops: 0,
        scan: scan,
      );
    }

    final result = await compute(
      seedAllFromPayloads,
      SeedAllInput(scan.payloads, suburbs, snapDegrees),
    );
    return LetterboxSeedAllResult(
      bySuburb: result.bySuburb,
      totalDrops: result.totalDrops,
      insideDrops: result.insideDrops,
      unmatchedDrops: result.unmatchedDrops,
      unmatchedSample: result.unmatchedSample,
      snappedDrops: result.snappedDrops,
      scan: scan,
    );
  }

  /// Seed **every** suburb from [folderPaths] in a single pass.
  ///
  /// Folder-major, exactly like the Cloud Function: each folder is downloaded
  /// once and its waypoints fanned out to whichever suburb contains them.
  /// Seeding suburb-by-suburb instead would re-download every folder 613
  /// times.
  Future<LetterboxSeedAllResult> seedAllFromFolders({
    required List<String> folderPaths,
    required List<SeedSuburb> suburbs,
    double snapDegrees = defaultSnapDegrees,
    void Function(int done, int total)? onProgress,
  }) async {
    if (suburbs.isEmpty || folderPaths.isEmpty) {
      return const LetterboxSeedAllResult(
        bySuburb: {},
        totalDrops: 0,
        insideDrops: 0,
        unmatchedDrops: 0,
      );
    }

    final payloads = <Uint8List>[];
    final skipped = <String>[];

    for (var i = 0; i < folderPaths.length; i++) {
      final folder = folderPaths[i].trim().replaceAll(RegExp(r'/+$'), '');
      try {
        final bytes = await _storage
            .downloadFileBytes('$folder/_compiled_waypoints.json');
        if (bytes == null) {
          skipped.add(folder);
        } else {
          payloads.add(bytes);
        }
      } catch (e) {
        debugPrint('[LetterboxSeed] $folder failed: $e');
        skipped.add(folder);
      }
      onProgress?.call(i + 1, folderPaths.length);
    }

    if (payloads.isEmpty) {
      return LetterboxSeedAllResult(
        bySuburb: const {},
        totalDrops: 0,
        insideDrops: 0,
        unmatchedDrops: 0,
        skippedFolders: skipped,
      );
    }

    final result = await compute(
      seedAllFromPayloads,
      SeedAllInput(payloads, suburbs, snapDegrees),
    );

    return LetterboxSeedAllResult(
      bySuburb: result.bySuburb,
      totalDrops: result.totalDrops,
      insideDrops: result.insideDrops,
      unmatchedDrops: result.unmatchedDrops,
      unmatchedSample: result.unmatchedSample,
      snappedDrops: result.snappedDrops,
      skippedFolders: skipped,
    );
  }
}

/// Input for the off-isolate GPX scan.
@visibleForTesting
class GpxScanInput {
  final List<Uint8List> files;
  final bool includeTrackPoints;

  const GpxScanInput(this.files, this.includeTrackPoints);
}

/// What an upload actually contained.
///
/// Carries the per-kind tallies, not just the result, because "nothing
/// happened" is otherwise indistinguishable from "your files record drops as
/// track points" or "that file would not parse" — and the user cannot fix what
/// they cannot see.
class GpxScanResult {
  final List<Uint8List> payloads;

  /// `<wpt>` elements — how a letterbox drop is normally recorded.
  final int waypointCount;

  /// `<rtept>` elements — some exports put drops here.
  final int routePointCount;

  /// `<trkpt>` elements — the walked path. Excluded unless explicitly asked
  /// for, because a day's track is tens of thousands of points and folding it
  /// in would inflate every letterbox count.
  final int trackPointCount;

  /// Files that could not be parsed at all.
  final int failedFiles;

  const GpxScanResult({
    required this.payloads,
    required this.waypointCount,
    required this.routePointCount,
    required this.trackPointCount,
    required this.failedFiles,
  });

  /// Nothing usable was found, but the files clearly hold a recorded path —
  /// the signature of an export that stores drops as track points.
  bool get onlyTrackPoints =>
      waypointCount == 0 && routePointCount == 0 && trackPointCount > 0;
}

/// Convert raw GPX file bytes into the same compiled-waypoints JSON shape the
/// Cloud Function writes, so device uploads and cloud folders feed the exact
/// same classification code rather than two parallel paths that can drift.
@visibleForTesting
GpxScanResult scanGpxBytes(GpxScanInput input) {
  final out = <Uint8List>[];
  var wpts = 0, rtepts = 0, trkpts = 0, failed = 0;

  for (final bytes in input.files) {
    try {
      final gpx =
          GpxReader().fromString(utf8.decode(bytes, allowMalformed: true));
      final waypoints = <Map<String, dynamic>>[];

      void add(double? lat, double? lon, String? name, String? desc) {
        if (lat == null || lon == null) return;
        waypoints.add({
          'name': name ?? '',
          'desc': desc ?? '',
          'lat': lat,
          'lon': lon,
        });
      }

      for (final w in gpx.wpts) {
        wpts++;
        add(w.lat, w.lon, w.name, w.desc);
      }
      for (final r in gpx.rtes) {
        for (final p in r.rtepts) {
          rtepts++;
          add(p.lat, p.lon, p.name, p.desc);
        }
      }
      for (final t in gpx.trks) {
        for (final seg in t.trksegs) {
          for (final p in seg.trkpts) {
            trkpts++;
            if (input.includeTrackPoints) {
              add(p.lat, p.lon, p.name, p.desc);
            }
          }
        }
      }

      if (waypoints.isNotEmpty) {
        out.add(Uint8List.fromList(
            utf8.encode(jsonEncode({'waypoints': waypoints}))));
      }
    } catch (_) {
      // A single unreadable file must not abort the whole upload — but it is
      // counted, so the UI can say so rather than silently doing nothing.
      failed++;
    }
  }

  return GpxScanResult(
    payloads: out,
    waypointCount: wpts,
    routePointCount: rtepts,
    trackPointCount: trkpts,
    failedFiles: failed,
  );
}

/// Parse GPX bytes off the UI isolate; a day of points is a large XML parse.
Future<GpxScanResult> scanGpxFiles(
  List<Uint8List> files, {
  bool includeTrackPoints = false,
}) =>
    compute(scanGpxBytes, GpxScanInput(files, includeTrackPoints));

/// Grid over suburb bounding boxes, so classifying a waypoint tests a handful
/// of suburbs rather than all 613.
///
/// Without this, seeding the city would be 890 000 x 613 = 545 million polygon
/// tests. With it, it is roughly one test per waypoint.
class _SuburbGrid {
  static const double cell = 0.01; // ~1 km

  final List<SeedSuburb> suburbs;
  final List<_Box> boxes;
  final Map<int, List<int>> grid = {};

  _SuburbGrid(this.suburbs) : boxes = suburbs.map(_boxOf).toList() {
    for (var i = 0; i < suburbs.length; i++) {
      final b = boxes[i];
      final minRow = (b.minLat / cell).floor();
      final maxRow = (b.maxLat / cell).floor();
      final minCol = (b.minLng / cell).floor();
      final maxCol = (b.maxLng / cell).floor();
      for (var row = minRow; row <= maxRow; row++) {
        for (var col = minCol; col <= maxCol; col++) {
          (grid[row * 1000000 + col] ??= []).add(i);
        }
      }
    }
  }

  /// Index of the suburb whose boundary is nearest this position, provided it
  /// is within [metres]. Returns -1 when nothing is close enough.
  ///
  /// Suburb boundaries here run down the middle of the road, so a house on the
  /// far side legitimately sits a few metres outside its own suburb — and GPS
  /// drift adds a few more. Without this, those drops are discarded as
  /// "outside every suburb" even though a human can see exactly where they
  /// belong.
  ///
  /// Only ever called for drops that failed the exact test, so the cost lands
  /// on the minority of points rather than on all of them.
  int nearestWithin(double lat, double lng, double metres) {
    // Neighbouring cells too: a point just outside a suburb can sit in the
    // next cell along, whose candidate list would not mention that suburb.
    final row = (lat / cell).floor();
    final col = (lng / cell).floor();

    var bestIndex = -1;
    var bestDistance = double.infinity;
    final seen = <int>{};

    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final candidates = grid[(row + dr) * 1000000 + (col + dc)];
        if (candidates == null) continue;
        for (final i in candidates) {
          if (!seen.add(i)) continue;
          final b = boxes[i];
          // Bounding box widened by the tolerance, so a suburb whose edge is
          // within range is not rejected before its edges are measured.
          final padLat = metres / 110574.0;
          final padLng =
              padLat / math.cos(lat * math.pi / 180).abs().clamp(0.000001, 1.0);
          if (lat < b.minLat - padLat ||
              lat > b.maxLat + padLat ||
              lng < b.minLng - padLng ||
              lng > b.maxLng + padLng) {
            continue;
          }
          final d = LetterboxGeometry.metresToPolygon(lat, lng, suburbs[i].polygon);
          if (d < bestDistance) {
            bestDistance = d;
            bestIndex = i;
          }
        }
      }
    }

    return bestDistance <= metres ? bestIndex : -1;
  }

  /// Index of the suburb containing this position, or -1.
  int indexFor(double lat, double lng) {
    final key = (lat / cell).floor() * 1000000 + (lng / cell).floor();
    final candidates = grid[key];
    if (candidates == null) return -1;
    final position = LatLng(lat, lng);
    for (final i in candidates) {
      final b = boxes[i];
      if (lat < b.minLat ||
          lat > b.maxLat ||
          lng < b.minLng ||
          lng > b.maxLng) {
        continue;
      }
      if (isPointInPolygon(position, suburbs[i].polygon)) return i;
    }
    return -1;
  }

  static _Box _boxOf(SeedSuburb s) {
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLng = double.infinity, maxLng = -double.infinity;
    for (final p in s.polygon) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return _Box(minLat, minLng, maxLat, maxLng);
  }
}

class _Box {
  final double minLat, minLng, maxLat, maxLng;
  const _Box(this.minLat, this.minLng, this.maxLat, this.maxLng);
}

/// Classify every waypoint in every payload into whichever suburb contains it.
///
/// Folder-major, mirroring the Cloud Function: each folder is read once and
/// fanned out across all suburbs, rather than re-reading every folder per
/// suburb.
@visibleForTesting
LetterboxSeedAllResult seedAllFromPayloads(SeedAllInput input) {
  final index = _SuburbGrid(input.suburbs);
  // suburb -> address cell -> folder -> points logged there on that round
  final bySuburb = <int, Map<String, Map<int, List<LatLng>>>>{};
  final unmatchedSample = <LatLng>[];
  var total = 0, inside = 0, unmatched = 0, snapped = 0;

  for (var folder = 0; folder < input.payloads.length; folder++) {
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(utf8.decode(input.payloads[folder]))
          as Map<String, dynamic>;
    } catch (_) {
      continue;
    }

    for (final w in decoded['waypoints'] as List<dynamic>? ?? const []) {
      if (w is! Map) continue;
      final lat = (w['lat'] as num?)?.toDouble();
      final lon = (w['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      total++;

      var found = index.indexFor(lat, lon);
      if (found < 0 && input.edgeToleranceMetres > 0) {
        // Just outside a boundary: a house across the road, or GPS drift.
        found = index.nearestWithin(lat, lon, input.edgeToleranceMetres);
        if (found >= 0) snapped++;
      }
      if (found < 0) {
        unmatched++;
        if (unmatchedSample.length <
            LetterboxSeedAllResult.maxUnmatchedSample) {
          unmatchedSample.add(LatLng(lat, lon));
        }
        continue;
      }
      inside++;

      final snap = input.snapDegrees;
      final key = '${(lat / snap).round()}:${(lon / snap).round()}';
      (((bySuburb[found] ??= {})[key] ??= {})[folder] ??= [])
          .add(LatLng(lat, lon));
    }
  }

  return LetterboxSeedAllResult(
    bySuburb: {
      for (final entry in bySuburb.entries)
        input.suburbs[entry.key].id: _reduceAddresses(entry.value),
    },
    totalDrops: total,
    insideDrops: inside,
    unmatchedDrops: unmatched,
    unmatchedSample: unmatchedSample,
    snappedDrops: snapped,
  );
}

/// Parse, clip and reduce off the UI isolate — this touches every waypoint in
/// every folder, so it must not run on the main thread.
LetterboxSeedResult _seedIsolate(_SeedInput input) {
  // address cell -> folder index -> the points that folder logged there
  final byAddress = <String, Map<int, List<LatLng>>>{};
  var rawInside = 0;

  for (var folder = 0; folder < input.payloads.length; folder++) {
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(utf8.decode(input.payloads[folder]))
          as Map<String, dynamic>;
    } catch (_) {
      continue;
    }

    for (final w in decoded['waypoints'] as List<dynamic>? ?? const []) {
      if (w is! Map) continue;
      final lat = (w['lat'] as num?)?.toDouble();
      final lon = (w['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;

      final position = LatLng(lat, lon);
      // Bbox-short-circuited ray cast — the polygon's box is cached against
      // the vertex list, so the cheap reject is shared across every waypoint.
      // Points just outside still count: the boundary runs down the middle of
      // the road, so a house opposite is legitimately a few metres out.
      if (!isPointInPolygon(position, input.polygon) &&
          LetterboxGeometry.metresToPolygon(lat, lon, input.polygon) >
              LetterboxSeedService.defaultEdgeToleranceMetres) {
        continue;
      }

      rawInside++;
      final snap = input.snapDegrees;
      final key = '${(lat / snap).round()}:${(lon / snap).round()}';
      ((byAddress[key] ??= {})[folder] ??= []).add(position);
    }
  }

  return LetterboxSeedResult(
    points: _reduceAddresses(byAddress),
    rawInsideCount: rawInside,
  );
}

/// Turn per-address, per-folder observations into one set of letterboxes.
///
/// **The rule is max-per-folder, not one-per-address.** A folder is a single
/// distribution round, so the points it logged at one address are the boxes
/// delivered to on that visit:
///
///  * a house is one waypoint per round, six rounds -> one box;
///  * a block with eight boxes is eight waypoints per round, six rounds ->
///    eight boxes, not forty-eight and not one.
///
/// Taking the maximum discounts repeat visits without flattening a block of
/// flats, which counting distinct positions would do and which collapsing to
/// one would do even more brutally. The round that saw the most boxes is
/// assumed the most complete, and its actual positions are kept.
List<LatLng> _reduceAddresses(Map<String, Map<int, List<LatLng>>> byAddress) {
  final out = <LatLng>[];
  for (final perFolder in byAddress.values) {
    List<LatLng>? best;
    for (final observed in perFolder.values) {
      if (best == null || observed.length > best.length) best = observed;
    }
    if (best != null) out.addAll(best);
  }
  return out;
}
