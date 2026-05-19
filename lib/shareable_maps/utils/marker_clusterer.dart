import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/map_point.dart';

/// A lightweight grid-based marker clusterer that groups [MapPoint]s into cells
/// determined by the current zoom level. At high zoom individual markers are
/// returned; at low zoom nearby points are merged into cluster markers showing
/// the count.
///
/// Designed to handle 20 000+ waypoints without blocking the UI thread.
class MarkerClusterer {
  MarkerClusterer._();

  /// Maximum individual markers to render before clustering kicks in.
  static const int _clusterThreshold = 200;

  /// Build Google Maps [Marker]s from [points], clustering when there are more
  /// than [_clusterThreshold] visible points at the current [zoom].
  ///
  /// [visibleBounds] culls points outside the viewport (with padding).
  /// [zoom] drives the grid cell size for clustering.
  /// [clusterIcons] is a cache of pre-rendered cluster BitmapDescriptors keyed
  /// by display count. The caller should keep a single long-lived map and pass
  /// it in; this method will populate missing entries.
  /// Pre-load and cache the letterbox image for use in cluster icons.
  /// Call once at startup; the result is stored in [_baseImage].
  static Future<void> loadBaseImage() async {
    if (_baseImage != null) return;
    final data = await rootBundle.load('assets/letterbox.png');
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: 24,
    );
    final fi = await codec.getNextFrame();
    _baseImage = fi.image;
  }

  static ui.Image? _baseImage;

  /// Synchronous clustering — call directly in build().
  /// [clusterIcons] is a cache of pre-rendered letterbox+count icons keyed by
  /// bucketed count. Pass a long-lived map; missing entries are skipped (use
  /// [warmUpClusterIcons] at startup to pre-populate common buckets).
  static List<Marker> clusterSync({
    required List<MapPoint> points,
    required double zoom,
    LatLngBounds? visibleBounds,
    String? selectedElementId,
    Function(String pointId)? onTap,
    bool draggable = false,
    Function(String pointId, LatLng newPosition)? onDragEnd,
    BitmapDescriptor? customIcon,
    Map<int, BitmapDescriptor> clusterIcons = const {},
    bool markerVisible = true,
  }) {
    // 1 – Viewport cull
    final visible = visibleBounds != null
        ? points.where((p) => visibleBounds.contains(p.position)).toList()
        : points;

    if (visible.isEmpty) return [];

    // Few enough visible points → render individually.
    // From zoom ≥ 12 onwards (suburb / street level) always render every
    // visible point individually so the user sees real letterboxes rather
    // than clusters. Below zoom 12 (city / region overview) cluster to
    // keep the marker count manageable for large layers (e.g. 12k+ points).
    if (visible.length <= _clusterThreshold || zoom >= 14) {
      return _buildIndividual(
        visible,
        selectedElementId: selectedElementId,
        onTap: onTap,
        draggable: draggable,
        onDragEnd: onDragEnd,
        customIcon: customIcon,
        markerVisible: markerVisible,
      );
    }

    // Grid-based clustering for low zoom (< 12). Cell size in degrees
    // shrinks with zoom so the cluster grid tightens as the user zooms in.
    final cellSize = 180.0 / math.pow(2, zoom);

    final Map<int, _Cluster> grid = {};
    for (final pt in visible) {
      final col = (pt.position.longitude / cellSize).floor();
      final row = (pt.position.latitude / cellSize).floor();
      final key = col * 100000 + row;
      final cluster = grid.putIfAbsent(key, () => _Cluster());
      cluster.add(pt);
    }

    final result = <Marker>[];
    final fallbackIcon = BitmapDescriptor.defaultMarker;

    for (final cluster in grid.values) {
      if (cluster.count == 1) {
        final pt = cluster.points.first;
        result.add(pt.toGoogleMapsMarker(
          isSelected: pt.id == selectedElementId,
          onTap: onTap != null ? () => onTap(pt.id) : null,
          draggable: draggable,
          onDragEnd: draggable && onDragEnd != null
              ? (pos) => onDragEnd(pt.id, pos)
              : null,
          customIcon: customIcon,
          visible: markerVisible,
        ));
      } else {
        final bucket = _bucketCount(cluster.count);
        final icon = clusterIcons[bucket] ?? fallbackIcon;
        final center = cluster.center;
        result.add(Marker(
          markerId: MarkerId(
              'cluster_${center.latitude.toStringAsFixed(5)}_${center.longitude.toStringAsFixed(5)}'),
          position: center,
          icon: icon,
          visible: markerVisible,
          anchor: const Offset(0.5, 0.5),
          onTap: onTap != null ? () => onTap(cluster.points.first.id) : null,
        ));
      }
    }

    return result;
  }

  /// Pre-render cluster icons for common count buckets so [clusterSync] can
  /// use them immediately. Call once at startup after [loadBaseImage].
  static Future<Map<int, BitmapDescriptor>> warmUpClusterIcons() async {
    final cache = <int, BitmapDescriptor>{};
    // Pre-render common buckets: 2-9, 10-90 step 10, 100-900 step 100, 1k-5k
    final buckets = [
      ...List.generate(8, (i) => i + 2),
      ...List.generate(9, (i) => (i + 1) * 10),
      ...List.generate(9, (i) => (i + 1) * 100),
      1000,
      2000,
      3000,
      5000,
    ];
    for (final b in buckets) {
      cache[b] = await _renderClusterIcon(b);
    }
    return cache;
  }

  /// Build Google Maps [Marker]s from [points] (async version with rendered
  /// cluster icons). Prefer [clusterSync] for use inside build().
  static Future<List<Marker>> buildMarkers({
    required List<MapPoint> points,
    required double zoom,
    LatLngBounds? visibleBounds,
    String? selectedElementId,
    Function(String pointId)? onTap,
    bool draggable = false,
    Function(String pointId, LatLng newPosition)? onDragEnd,
    BitmapDescriptor? customIcon,
    required Map<int, BitmapDescriptor> clusterIcons,
  }) async {
    // 1 – Viewport cull
    final visible = visibleBounds != null
        ? points.where((p) => visibleBounds.contains(p.position)).toList()
        : points;

    if (visible.isEmpty) return [];

    // 2 – If few enough, return individual markers directly
    if (visible.length <= _clusterThreshold) {
      return _buildIndividual(
        visible,
        selectedElementId: selectedElementId,
        onTap: onTap,
        draggable: draggable,
        onDragEnd: onDragEnd,
        customIcon: customIcon,
      );
    }

    // 3 – Grid-based clustering
    // Cell size in degrees — shrinks as zoom increases.
    // At high zoom (≥ 8) use very fine cells so most points appear
    // individually while still limiting total marker count.
    final cellSize = zoom >= 8
        ? 0.0005 // ~55 m — individual at street level
        : 180.0 / math.pow(2, zoom);

    final Map<int, _Cluster> grid = {};
    for (final pt in visible) {
      final col = (pt.position.longitude / cellSize).floor();
      final row = (pt.position.latitude / cellSize).floor();
      final key = col * 100000 + row; // unique cell id
      final cluster = grid.putIfAbsent(key, () => _Cluster());
      cluster.add(pt);
    }

    final result = <Marker>[];

    for (final cluster in grid.values) {
      if (cluster.count == 1) {
        // Single point — render normally
        final pt = cluster.points.first;
        result.add(pt.toGoogleMapsMarker(
          isSelected: pt.id == selectedElementId,
          onTap: onTap != null ? () => onTap(pt.id) : null,
          draggable: draggable,
          onDragEnd: draggable && onDragEnd != null
              ? (pos) => onDragEnd(pt.id, pos)
              : null,
          customIcon: customIcon,
        ));
      } else {
        // Cluster marker
        final icon = await _getClusterIcon(cluster.count, clusterIcons);
        final center = cluster.center;
        result.add(Marker(
          markerId: MarkerId(
              'cluster_${center.latitude.toStringAsFixed(5)}_${center.longitude.toStringAsFixed(5)}'),
          position: center,
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          onTap: onTap != null ? () => onTap(cluster.points.first.id) : null,
        ));
      }
    }

    return result;
  }

  static List<Marker> _buildIndividual(
    List<MapPoint> points, {
    String? selectedElementId,
    Function(String pointId)? onTap,
    bool draggable = false,
    Function(String pointId, LatLng newPosition)? onDragEnd,
    BitmapDescriptor? customIcon,
    bool markerVisible = true,
  }) {
    return points.map((pt) {
      return pt.toGoogleMapsMarker(
        isSelected: pt.id == selectedElementId,
        onTap: onTap != null ? () => onTap(pt.id) : null,
        draggable: draggable,
        onDragEnd: draggable && onDragEnd != null
            ? (pos) => onDragEnd(pt.id, pos)
            : null,
        customIcon: customIcon,
        visible: markerVisible,
      );
    }).toList();
  }

  /// Get or create a cluster icon for [count]. Cached in [cache].
  static Future<BitmapDescriptor> _getClusterIcon(
      int count, Map<int, BitmapDescriptor> cache) async {
    // Bucket the count so we don't create thousands of unique bitmaps.
    final bucket = _bucketCount(count);
    if (cache.containsKey(bucket)) return cache[bucket]!;
    final icon = await _renderClusterIcon(bucket);
    cache[bucket] = icon;
    return icon;
  }

  /// Bucket counts to limit unique icon variants:
  /// 2-9 → exact, 10-99 → round to 10, 100-999 → round to 100, etc.
  static int _bucketCount(int count) {
    if (count < 10) return count;
    if (count < 100) return (count ~/ 10) * 10;
    if (count < 1000) return (count ~/ 100) * 100;
    return (count ~/ 1000) * 1000;
  }

  /// Format count for display: 1234 → "1.2k"
  static String _formatCount(int count) {
    if (count < 1000) return '$count';
    if (count < 10000) return '${(count / 1000).toStringAsFixed(1)}k';
    return '${count ~/ 1000}k';
  }

  /// Render a cluster icon: letterbox image with a count badge.
  /// Falls back to a plain circle if the base image isn't loaded.
  static Future<BitmapDescriptor> _renderClusterIcon(int count) async {
    final text = _formatCount(count);

    // Canvas size: letterbox centred with room for the badge
    const double canvasSize = 40.0;
    const double badgeRadius = 10.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // ── Draw letterbox image centred ──
    if (_baseImage != null) {
      final img = _baseImage!;
      final double dx = (canvasSize - img.width) / 2;
      final double dy = (canvasSize - img.height) / 2;
      canvas.drawImage(img, Offset(dx, dy), Paint());
    } else {
      // Fallback: small red circle if image not loaded
      canvas.drawCircle(
        const Offset(canvasSize / 2, canvasSize / 2),
        8,
        Paint()..color = Colors.red,
      );
    }

    // ── Count badge (top-right corner) ──
    final badgeCenter = Offset(
      canvasSize - badgeRadius - 1,
      badgeRadius + 1,
    );

    // Badge background
    canvas.drawCircle(
      badgeCenter,
      badgeRadius,
      Paint()..color = Colors.red,
    );
    // White border
    canvas.drawCircle(
      badgeCenter,
      badgeRadius,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Count text
    final fontSize = text.length > 2 ? 8.0 : 10.0;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(badgeCenter.dx - tp.width / 2, badgeCenter.dy - tp.height / 2),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(canvasSize.toInt(), canvasSize.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return BitmapDescriptor.defaultMarker;
    return BitmapDescriptor.bytes(bytes.buffer.asUint8List());
  }
}

/// Internal accumulator for one grid cell.
class _Cluster {
  final List<MapPoint> points = [];
  double _sumLat = 0;
  double _sumLng = 0;

  void add(MapPoint pt) {
    points.add(pt);
    _sumLat += pt.position.latitude;
    _sumLng += pt.position.longitude;
  }

  int get count => points.length;
  LatLng get center => LatLng(_sumLat / count, _sumLng / count);
}
