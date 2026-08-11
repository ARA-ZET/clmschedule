// services/compiled_tracks_parser.dart
//
// Shared parser for `_compiled_tracks.json` files produced by the Cloud
// Function that compiles a Cloud Storage folder's GPX tracks. Extracted so
// both the Shareable Map editor and the schedule print-map flow can parse the
// same file format without duplicating the logic.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../shareable_maps/models/map_polyline.dart';

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

    final name = (t['name'] as String?) ?? 'Track ${seq + 1}';
    final desc = (t['desc'] as String?) ?? '';
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
    ));
  }
  return results;
}
