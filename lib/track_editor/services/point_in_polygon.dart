// track_editor/services/point_in_polygon.dart
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';
import '../models/styled_polygon.dart';
import '../models/te_gpx_file_entry.dart';

/// Cached bounding box for a polygon's vertex list. Keyed by the
/// `List<LatLng>` instance so it stays valid as long as the polygon
/// hasn't been rebuilt (`copyWith(points: ...)` creates a new list).
class _Bbox {
  final double minLat, maxLat, minLon, maxLon;
  const _Bbox(this.minLat, this.maxLat, this.minLon, this.maxLon);
  bool contains(LatLng p) =>
      p.latitude >= minLat &&
      p.latitude <= maxLat &&
      p.longitude >= minLon &&
      p.longitude <= maxLon;
}

final Expando<_Bbox> _bboxCache = Expando<_Bbox>('te_polygon_bbox');

_Bbox _bboxFor(List<LatLng> points) {
  final cached = _bboxCache[points];
  if (cached != null) return cached;
  double minLat = double.infinity, maxLat = -double.infinity;
  double minLon = double.infinity, maxLon = -double.infinity;
  for (final p in points) {
    if (p.latitude < minLat) minLat = p.latitude;
    if (p.latitude > maxLat) maxLat = p.latitude;
    if (p.longitude < minLon) minLon = p.longitude;
    if (p.longitude > maxLon) maxLon = p.longitude;
  }
  final bb = _Bbox(minLat, maxLat, minLon, maxLon);
  _bboxCache[points] = bb;
  return bb;
}

/// Check if point is inside polygon using ray-casting algorithm.
bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
  final n = polygon.length;
  if (n < 3) return false;
  // Bbox short-circuit: cheap reject for points far from the polygon.
  if (!_bboxFor(polygon).contains(point)) return false;
  int intersectCount = 0;
  for (int j = 0; j < n; j++) {
    final p1 = polygon[j];
    final p2 = polygon[(j + 1) % n];
    if ((p1.latitude > point.latitude) != (p2.latitude > point.latitude)) {
      final lon = (p2.longitude - p1.longitude) *
              (point.latitude - p1.latitude) /
              (p2.latitude - p1.latitude) +
          p1.longitude;
      if (point.longitude < lon) intersectCount++;
    }
  }
  return (intersectCount % 2 == 1);
}

/// Returns true if [wpt] is inside ANY of [polygons].
bool wptInAnyPolygon(Wpt wpt, List<TEStyledPolygon> polygons) {
  if (wpt.lat == null || wpt.lon == null || polygons.isEmpty) return false;
  final ll = LatLng(wpt.lat!, wpt.lon!);
  return polygons.any((poly) => isPointInPolygon(ll, poly.points));
}

/// Returns only waypoints that fall inside at least one polygon.
List<Wpt> filterWaypointsByPolygons(
    List<Wpt> waypoints, List<TEStyledPolygon> polygons) {
  if (polygons.isEmpty) return [];
  return waypoints.where((w) => wptInAnyPolygon(w, polygons)).toList();
}

/// Returns a copy of [tracks] with each segment filtered to only track points
/// inside at least one of [polygons]. Empty segments and tracks are dropped.
List<Trk> trimTracksToPolygons(
    List<Trk> tracks, List<TEStyledPolygon> polygons) {
  if (polygons.isEmpty) return [];
  final result = <Trk>[];
  for (final trk in tracks) {
    final newSegs = <Trkseg>[];
    for (final seg in trk.trksegs) {
      final pts =
          seg.trkpts.where((pt) => wptInAnyPolygon(pt, polygons)).toList();
      if (pts.isNotEmpty) newSegs.add(Trkseg()..trkpts = pts);
    }
    if (newSegs.isNotEmpty) {
      result.add(Trk()
        ..name = trk.name
        ..desc = trk.desc
        ..trksegs = newSegs);
    }
  }
  return result;
}

/// Groups waypoints into target polygons.
List<TETargetPolygon> groupWaypointsByPolygon(
  List<TEStyledPolygon> polygons,
  List<Wpt> waypoints,
) {
  final results = <TETargetPolygon>[];
  for (final polygon in polygons) {
    final contained = waypoints.where((wpt) {
      if (wpt.lat == null || wpt.lon == null) return false;
      return isPointInPolygon(LatLng(wpt.lat!, wpt.lon!), polygon.points);
    }).toList();
    results.add(TETargetPolygon(name: polygon.name, waypoints: contained));
  }
  return results;
}

/// Top-level function for [compute] – groups waypoints by polygon off the
/// main isolate to avoid jank on large datasets.
List<TETargetPolygon> _groupWaypointsByPolygonIsolate(
    _GroupWaypointsMessage msg) {
  return groupWaypointsByPolygon(msg.polygons, msg.waypoints);
}

/// Runs [groupWaypointsByPolygon] on a background isolate via [compute].
Future<List<TETargetPolygon>> groupWaypointsByPolygonAsync(
  List<TEStyledPolygon> polygons,
  List<Wpt> waypoints,
) {
  return compute(
    _groupWaypointsByPolygonIsolate,
    _GroupWaypointsMessage(polygons: polygons, waypoints: waypoints),
  );
}

class _GroupWaypointsMessage {
  final List<TEStyledPolygon> polygons;
  final List<Wpt> waypoints;
  const _GroupWaypointsMessage(
      {required this.polygons, required this.waypoints});
}

/// Top-level function for [compute] – parses a GPX file off the main isolate.
TEGpxFileEntry _parseGpxIsolate(_ParseGpxMessage msg) {
  return TEGpxFileEntry.parse(msg.filename, msg.bytes);
}

/// Runs GPX file parsing on a background isolate via [compute].
Future<TEGpxFileEntry> parseGpxFileAsync(String filename, Uint8List bytes) {
  return compute(
    _parseGpxIsolate,
    _ParseGpxMessage(filename: filename, bytes: bytes),
  );
}

class _ParseGpxMessage {
  final String filename;
  final Uint8List bytes;
  const _ParseGpxMessage({required this.filename, required this.bytes});
}
