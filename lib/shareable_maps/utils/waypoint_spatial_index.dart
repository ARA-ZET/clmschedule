import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Lightweight model holding only what is needed for tap hit-testing and
/// the info window for a cloud waypoint rendered via Dataset tile overlay.
class WaypointMeta {
  final String id;
  final String name;
  final String description;
  final LatLng position;

  const WaypointMeta({
    required this.id,
    required this.name,
    required this.description,
    required this.position,
  });
}

/// Grid-based spatial index for fast viewport queries over large waypoint sets.
///
/// Divides lat/lng space into 0.01° × 0.01° cells (~1 km²). Each cell holds
/// the waypoints whose position falls inside it. A viewport query scans only
/// the cells that overlap the given [LatLngBounds], so it runs in
/// O(viewport_cells + results) rather than O(total_points).
///
/// Designed to handle 20 000+ points without blocking the UI thread.
class WaypointSpatialIndex {
  static const double _cellDeg = 0.01;

  final Map<String, List<WaypointMeta>> _grid = {};
  int _count = 0;

  int get count => _count;
  bool get isEmpty => _count == 0;

  /// Returns every waypoint in the index. Used when the dataset is small
  /// enough to render in full (≤ 5 000 points).
  List<WaypointMeta> all() =>
      _grid.values.expand((cell) => cell).toList(growable: false);

  void insertAll(List<WaypointMeta> points) {
    for (final pt in points) {
      final key = _cellKey(pt.position.latitude, pt.position.longitude);
      (_grid[key] ??= []).add(pt);
      _count++;
    }
  }

  /// Returns all waypoints whose position falls inside [bounds], up to [limit].
  List<WaypointMeta> query(LatLngBounds bounds, {int limit = 300}) {
    final minRow = (bounds.southwest.latitude / _cellDeg).floor();
    final maxRow = (bounds.northeast.latitude / _cellDeg).floor();
    final minCol = (bounds.southwest.longitude / _cellDeg).floor();
    final maxCol = (bounds.northeast.longitude / _cellDeg).floor();

    final result = <WaypointMeta>[];
    outer:
    for (int row = minRow; row <= maxRow; row++) {
      for (int col = minCol; col <= maxCol; col++) {
        final cell = _grid['$row:$col'];
        if (cell == null) continue;
        for (final pt in cell) {
          result.add(pt);
          if (result.length >= limit) break outer;
        }
      }
    }
    return result;
  }

  static String _cellKey(double lat, double lng) {
    final row = (lat / _cellDeg).floor();
    final col = (lng / _cellDeg).floor();
    return '$row:$col';
  }
}
