// services/compiled_tracks_parser.dart
//
// Shared parsers for the `_compiled_*.json` files produced by the Cloud
// Function that compiles a Cloud Storage folder's GPX files. Extracted so the
// Shareable Map editor, the schedule print-map flow and the distribution
// report all parse the same formats without duplicating the logic.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../shareable_maps/models/map_polyline.dart';
import '../utils/text_encoding.dart';

/// Parse a `_compiled_tracks.json` file produced by the Cloud Function.
/// Returns a list of [MapPolyline] with metadata (distance, times, duration).
///
/// Top-level function so it can be used with `compute()`.
List<MapPolyline> parseCompiledTracksBytes(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final tracks = json['tracks'] as List<dynamic>? ?? [];
  final now = DateTime.now();
  final results = <MapPolyline>[];
  int seq = 0;

  for (final t in tracks) {
    final rawPoints = t['points'] as List<dynamic>? ?? [];
    if (rawPoints.length < 2) continue;
    final points = rawPoints
        .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList();

    // Repaired: GPX saved before the UTF-8 fix carries mis-decoded names.
    final rawName = t['name'] as String?;
    final name = rawName != null ? repairMojibake(rawName) : 'Track ${seq + 1}';
    final desc = repairMojibake((t['desc'] as String?) ?? '');
    final distM = (t['distanceMeters'] as num?)?.toDouble();
    final startMs = (t['startTime'] as num?)?.toInt();
    final endMs = (t['endTime'] as num?)?.toInt();
    final durMs = (t['durationMs'] as num?)?.toInt();

    results.add(MapPolyline(
      id: 'compiled_trk_${now.millisecondsSinceEpoch}_${seq++}',
      name: name,
      description: desc,
      points: points,
      color: Colors.blue,
      strokeWidth: 3.0,
      createdAt: now,
      updatedAt: now,
      distanceMeters: distM,
      startTime:
          startMs != null ? DateTime.fromMillisecondsSinceEpoch(startMs) : null,
      endTime:
          endMs != null ? DateTime.fromMillisecondsSinceEpoch(endMs) : null,
      duration: durMs != null ? Duration(milliseconds: durMs) : null,
      sourceFile: t['file'] as String?,
    ));
  }
  return results;
}

/// The header of a `_compiled_tracks.json` plus the span its tracks cover.
///
/// Everything the distribution report needs to answer "when, and how many"
/// for one folder. Deliberately carries no geometry.
class CompiledTracksSummary {
  /// Total `<wpt>` count across every non-compiled GPX in the folder.
  ///
  /// Written into the *tracks* file as well as the waypoints file by both
  /// writers, which is why the report never has to download the (much larger)
  /// `_compiled_waypoints.json`.
  final int waypointCount;

  final int trackCount;
  final int fileCount;

  /// When the folder was last compiled. Used as the date of last resort.
  final DateTime? compiledAt;

  /// Earliest/latest `<trkpt><time>` across the folder's tracks. Null when no
  /// track carried timestamps — a real case for GPX exported without times.
  final DateTime? earliestStart;
  final DateTime? latestEnd;

  const CompiledTracksSummary({
    required this.waypointCount,
    required this.trackCount,
    required this.fileCount,
    this.compiledAt,
    this.earliestStart,
    this.latestEnd,
  });

  static const empty = CompiledTracksSummary(
    waypointCount: 0,
    trackCount: 0,
    fileCount: 0,
  );
}

/// Read the header and track timings out of a `_compiled_tracks.json`.
///
/// Skips the `points` arrays entirely — a folder's tracks can run to hundreds
/// of thousands of coordinates, and the report needs none of them. This is why
/// it is a separate function rather than a header on
/// [parseCompiledTracksBytes], whose callers do want the geometry.
CompiledTracksSummary parseCompiledTracksSummary(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final tracks = json['tracks'] as List<dynamic>? ?? [];

  DateTime? earliest;
  DateTime? latest;
  for (final t in tracks) {
    if (t is! Map) continue;
    final startMs = (t['startTime'] as num?)?.toInt();
    if (startMs != null) {
      final start = DateTime.fromMillisecondsSinceEpoch(startMs);
      if (earliest == null || start.isBefore(earliest)) earliest = start;
    }
    final endMs = (t['endTime'] as num?)?.toInt();
    if (endMs != null) {
      final end = DateTime.fromMillisecondsSinceEpoch(endMs);
      if (latest == null || end.isAfter(latest)) latest = end;
    }
  }

  return CompiledTracksSummary(
    // `trackCount` is trusted from the header, but the waypoint count falls
    // back to the array length so a file written before the header field
    // existed still reports a figure rather than zero.
    waypointCount: (json['waypointCount'] as num?)?.toInt() ??
        (json['waypoints'] as List<dynamic>?)?.length ??
        0,
    trackCount: (json['trackCount'] as num?)?.toInt() ?? tracks.length,
    fileCount: (json['fileCount'] as num?)?.toInt() ?? 0,
    compiledAt: DateTime.tryParse(json['compiledAt'] as String? ?? ''),
    earliestStart: earliest,
    latestEnd: latest,
  );
}

/// Read just the waypoint total out of a `_compiled_waypoints.json`.
///
/// The fallback for folders that have no `_compiled_tracks.json` at all —
/// both writers *delete* that file when a folder contains no tracks, so a
/// waypoint-only folder has nothing else to read.
///
/// Matches the key handling already used by the Cloud File Manager: prefer the
/// header count, fall back to the array length.
int parseCompiledWaypointCount(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final raw = json['waypointCount'] ?? json['count'];
  if (raw is num) return raw.toInt();
  final list = json['waypoints'];
  return list is List ? list.length : 0;
}
