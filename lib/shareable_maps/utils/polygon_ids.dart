// shareable_maps/utils/polygon_ids.dart
//
// Stable ids for the polygons — and points — of a stored client map, so a
// schedule job can point at one (`JobAreaLink`) instead of holding a copy.
// Points (traffic-light or handout spots) are allocated like areas.
//
// The editor addresses polygons by their position in the layer, which shifts
// whenever an earlier one is deleted — useless as a reference. Every polygon
// of a Firestore-backed map therefore gets an id the first time the map is
// read or saved, and keeps it through every edit (`copyWith` carries `id`).
//
// The id is derived from the polygon's outline rather than drawn at random,
// so two people opening the same not-yet-backfilled map compute the same ids
// before either of them saves. Once saved, the id is stored and the outline
// can change freely without changing it.
//
// Only stored client maps get ids. The work-area, client-area and suburb
// libraries treat a missing id as "new polygon", so this is never applied to
// the maps their adapters build.
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../models/custom_polygon.dart';
import '../models/map_layer.dart';
import '../models/map_point.dart';

/// Prefix of every id handed out here, so a stored id can be told apart from
/// a library id (work area / suburb doc id) that arrived with an import.
const String kPolygonIdPrefix = 'pg_';

/// Two independent 32-bit polynomial hashes of [s], hex-joined. Kept below
/// 2^53 at every step so the web (JS doubles) and the VM agree exactly —
/// `String.hashCode` differs between the two and cannot be used.
String _stableHash(String s) {
  var a = 7, b = 11;
  for (final c in s.codeUnits) {
    a = (a * 31 + c) % 4294967291;
    b = (b * 131 + c) % 4294967279;
  }
  return a.toRadixString(16).padLeft(8, '0') +
      b.toRadixString(16).padLeft(8, '0');
}

/// The id a polygon without one is given: a hash of its type and outline.
String derivedPolygonId(CustomPolygon p) {
  final key = StringBuffer(p.type.name);
  for (final pt in p.points) {
    key
      ..write('|')
      ..write(pt.latitude.toStringAsFixed(6))
      ..write(',')
      ..write(pt.longitude.toStringAsFixed(6));
  }
  return '$kPolygonIdPrefix${_stableHash(key.toString())}';
}

/// Prefix of a point id derived from its position.
const String kPointIdPrefix = 'pt_';

/// The id a stored point without one is given: a hash of its position.
String derivedPointId(LatLng position) =>
    '$kPointIdPrefix${_stableHash('point|${position.latitude.toStringAsFixed(6)},'
        '${position.longitude.toStringAsFixed(6)}')}';

/// [layers] with every polygon carrying an id that is unique across the
/// whole map. Missing ids are derived from the outline; a repeated id (two
/// copies of the same outline, or a polygon duplicated with `copyWith`) is
/// kept by its first holder, in layer order, and the later ones get a
/// suffix. Returns [layers] itself when nothing needed changing.
List<MapLayer> withStablePolygonIds(List<MapLayer> layers) {
  final used = <String>{};
  var changed = false;
  final out = <MapLayer>[];

  for (final layer in layers) {
    List<CustomPolygon>? polys;
    for (var i = 0; i < layer.polygons.length; i++) {
      final p = layer.polygons[i];
      final current = p.id;
      var id =
          (current == null || current.isEmpty) ? derivedPolygonId(p) : current;
      if (!used.add(id)) {
        final base = id;
        var n = 2;
        while (!used.add('${base}_$n')) {
          n++;
        }
        id = '${base}_$n';
      }
      if (id != current) {
        polys ??= List<CustomPolygon>.from(layer.polygons);
        polys[i] = p.copyWith(id: id);
      }
    }
    // Points share the id space, so a link's id never names two things.
    List<MapPoint>? points;
    for (var i = 0; i < layer.points.length; i++) {
      final p = layer.points[i];
      final current = p.id;
      var id = current.isEmpty ? derivedPointId(p.position) : current;
      if (!used.add(id)) {
        final base = id;
        var n = 2;
        while (!used.add('${base}_$n')) {
          n++;
        }
        id = '${base}_$n';
      }
      if (id != current) {
        points ??= List<MapPoint>.from(layer.points);
        points[i] = p.copyWith(id: id, updatedAt: p.updatedAt);
      }
    }
    if (polys != null || points != null) {
      changed = true;
      out.add(layer.copyWith(
          polygons: polys, points: points, updatedAt: layer.updatedAt));
    } else {
      out.add(layer);
    }
  }
  return changed ? out : layers;
}

/// Finds the polygon with [polygonId] in [layers], or null.
CustomPolygon? findPolygonById(List<MapLayer> layers, String polygonId) {
  for (final layer in layers) {
    for (final p in layer.polygons) {
      if (p.id == polygonId) return p;
    }
  }
  return null;
}
