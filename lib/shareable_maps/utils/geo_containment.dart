import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Checks whether a [point] lies inside the given [polygon] using the
/// ray-casting algorithm. Works in lat/lng space which is accurate enough
/// for the small-area selection use-case.
bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
  if (polygon.length < 3) return false;

  bool inside = false;
  int j = polygon.length - 1;

  for (int i = 0; i < polygon.length; i++) {
    final xi = polygon[i].latitude;
    final yi = polygon[i].longitude;
    final xj = polygon[j].latitude;
    final yj = polygon[j].longitude;

    final intersect = ((yi > point.longitude) != (yj > point.longitude)) &&
        (point.latitude < (xj - xi) * (point.longitude - yi) / (yj - yi) + xi);

    if (intersect) inside = !inside;
    j = i;
  }

  return inside;
}

/// Returns true if the [candidate] polygon's centroid falls inside the
/// [selection] polygon. This is a fast heuristic — a work area is considered
/// "inside" the lasso if its center point is contained.
bool isPolygonCentroidInside(List<LatLng> candidate, List<LatLng> selection) {
  if (candidate.isEmpty) return false;
  final centroid = _centroid(candidate);
  return isPointInPolygon(centroid, selection);
}

/// Returns true if *any* vertex of [candidate] falls inside [selection].
/// More inclusive than centroid-only check.
bool doesPolygonOverlap(List<LatLng> candidate, List<LatLng> selection) {
  if (candidate.isEmpty || selection.length < 3) return false;
  // Check if centroid is inside (most common case)
  if (isPolygonCentroidInside(candidate, selection)) return true;
  // Check if any vertex is inside
  for (final pt in candidate) {
    if (isPointInPolygon(pt, selection)) return true;
  }
  return false;
}

LatLng _centroid(List<LatLng> points) {
  double lat = 0, lng = 0;
  for (final p in points) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / points.length, lng / points.length);
}
