// track_editor/services/point_in_polygon.dart
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';
import '../models/styled_polygon.dart';

/// Check if point is inside polygon using ray-casting algorithm.
bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
  int intersectCount = 0;
  for (int j = 0; j < polygon.length - 1; j++) {
    final p1 = polygon[j];
    final p2 = polygon[j + 1];
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
