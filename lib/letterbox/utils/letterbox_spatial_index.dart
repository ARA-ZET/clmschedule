import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/letterbox_suburb.dart';

/// Grid-based spatial index over one suburb's letterbox positions.
///
/// Generalises `WaypointSpatialIndex` (`lib/shareable_maps/utils/`) for the
/// two things the letterbox work needs that it doesn't do: counting the points
/// that fall inside an arbitrary polygon, and reporting its own bounds so a
/// query can skip a suburb without touching its cells.
///
/// Space is divided into 0.005 degree cells (~500 m). A polygon query scans
/// only the cells its bounding box overlaps, so cost is
/// `O(overlapping cells + candidates)` rather than `O(all points)`. At the
/// ~1 450 points of a typical Cape Town suburb that is microseconds, which is
/// what makes it safe to recount on every tick while a polygon is being drawn.
class LetterboxSpatialIndex {
  /// ~500 m. Smaller than the shareable-maps index's 0.01 degree because the
  /// dominant query here is a hand-drawn work area (a few streets), not a
  /// screen viewport, so finer cells reject far more candidates.
  static const double cellDegrees = 0.005;

  final Map<int, List<LatLng>> _grid = {};
  int _count = 0;
  LetterboxBounds? _bounds;

  int get count => _count;
  bool get isEmpty => _count == 0;

  /// Bounds of every indexed point, or null while empty.
  LetterboxBounds? get bounds => _bounds;

  /// All indexed points, in no particular order.
  List<LatLng> all() =>
      _grid.values.expand((cell) => cell).toList(growable: false);

  void insertAll(List<LatLng> points) {
    if (points.isEmpty) return;
    for (final p in points) {
      (_grid[_cellKey(p.latitude, p.longitude)] ??= []).add(p);
      _count++;
    }
    _bounds = _mergeBounds(_bounds, LetterboxBounds.fromPoints(points));
  }

  /// Every point whose cell overlaps [box]. These are *candidates* — the cell
  /// grid is coarser than the box, so callers still need an exact test.
  List<LatLng> candidatesIn(LetterboxBounds box) {
    final minRow = (box.minLat / cellDegrees).floor();
    final maxRow = (box.maxLat / cellDegrees).floor();
    final minCol = (box.minLng / cellDegrees).floor();
    final maxCol = (box.maxLng / cellDegrees).floor();

    final result = <LatLng>[];
    for (var row = minRow; row <= maxRow; row++) {
      for (var col = minCol; col <= maxCol; col++) {
        final cell = _grid[_packKey(row, col)];
        if (cell != null) result.addAll(cell);
      }
    }
    return result;
  }

  /// Points inside [box] exactly, capped at [limit]. Used for viewport-culled
  /// rendering, where an approximate extra point off-screen is harmless but an
  /// unbounded list is not.
  List<LatLng> query(LetterboxBounds box, {int limit = 2000}) {
    final result = <LatLng>[];
    for (final p in candidatesIn(box)) {
      if (p.latitude < box.minLat ||
          p.latitude > box.maxLat ||
          p.longitude < box.minLng ||
          p.longitude > box.maxLng) {
        continue;
      }
      result.add(p);
      if (result.length >= limit) break;
    }
    return result;
  }

  static LetterboxBounds? _mergeBounds(LetterboxBounds? a, LetterboxBounds? b) {
    if (a == null) return b;
    if (b == null) return a;
    return LetterboxBounds(
      minLat: a.minLat < b.minLat ? a.minLat : b.minLat,
      minLng: a.minLng < b.minLng ? a.minLng : b.minLng,
      maxLat: a.maxLat > b.maxLat ? a.maxLat : b.maxLat,
      maxLng: a.maxLng > b.maxLng ? a.maxLng : b.maxLng,
    );
  }

  static int _cellKey(double lat, double lng) =>
      _packKey((lat / cellDegrees).floor(), (lng / cellDegrees).floor());

  /// Pack row/col into one int key. Cheaper to hash than the `'$row:$col'`
  /// strings the shareable-maps index builds, which matters because this runs
  /// per drawing tick.
  ///
  /// Multiplication rather than bit-shifting on purpose: rows are negative in
  /// the southern hemisphere, and shifting a negative int is not consistent
  /// across Dart's compile targets. At 0.005 degree cells the whole planet
  /// spans |col| < 72 000, comfortably inside [_colStride], and the widest
  /// possible key stays well under 2^53 so it is exact on every backend.
  static const int _colStride = 1000000;

  static int _packKey(int row, int col) => row * _colStride + col;
}
