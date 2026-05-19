import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../utils/marker_clusterer.dart';
import '../utils/point_marker_icons.dart';
import '../../models/custom_polygon.dart' show PointCategory;

/// App-lifetime cache for every custom [BitmapDescriptor] used by the
/// shareable map editor.
///
/// Replaces the previous per-instance rasterisation that happened in
/// `_MapViewWidgetState._createMarkerIcons()` — those icons were rebuilt
/// (asset decode + Canvas → PNG round-trip) every time the editor mounted,
/// hot-reloaded or a different map was opened. Now they are built once on
/// first use and reused for the rest of the app session.
///
/// Usage:
/// ```dart
/// final cache = MapBitmapCache.instance;
/// await cache.ensureLoaded();
/// final marker = Marker(icon: cache.vertex ?? BitmapDescriptor.defaultMarker);
/// ```
///
/// All getters are synchronous and may return `null` if [ensureLoaded] has
/// not finished yet — call sites should keep a `defaultMarker*` fallback.
class MapBitmapCache {
  MapBitmapCache._();

  static final MapBitmapCache instance = MapBitmapCache._();

  // ── Cached descriptors ────────────────────────────────────────────────

  /// Small white circle with red border — used as the draggable vertex
  /// handle when editing polygon / polyline geometry.
  BitmapDescriptor? get vertex => _vertex;
  BitmapDescriptor? _vertex;

  /// Small orange circle with white border — used for the "insert vertex"
  /// midpoint handles between existing vertices.
  BitmapDescriptor? get midpoint => _midpoint;
  BitmapDescriptor? _midpoint;

  /// Larger green circle with white border — used for the first vertex of
  /// an in-progress polygon to indicate "tap here to close".
  BitmapDescriptor? get firstVertex => _firstVertex;
  BitmapDescriptor? _firstVertex;

  /// 16 px letterbox icon used for cloud waypoint markers.
  BitmapDescriptor? get waypoint => _waypoint;
  BitmapDescriptor? _waypoint;

  /// Pre-rendered cluster bubbles (letterbox + count badge) keyed by
  /// bucketed point count. Populated from
  /// [MarkerClusterer.warmUpClusterIcons].
  Map<int, BitmapDescriptor> get clusterIcons =>
      Map.unmodifiable(_clusterIcons);
  Map<int, BitmapDescriptor> _clusterIcons = const {};

  /// Per-[PointCategory] icons (coloured circle + glyph). The map is owned
  /// by [PointMarkerIcons]; this cache simply holds a reference once
  /// preloading has completed.
  Map<PointCategory, BitmapDescriptor>? get pointCategoryIcons =>
      _pointCategoryIcons;
  Map<PointCategory, BitmapDescriptor>? _pointCategoryIcons;

  /// `true` once [ensureLoaded] has finished at least once.
  bool get isLoaded => _isLoaded;
  bool _isLoaded = false;

  // ── Loading ───────────────────────────────────────────────────────────

  Future<void>? _loadFuture;

  /// Idempotent. The first caller starts the rasterisation work; subsequent
  /// callers (concurrent or later) await the same future and return
  /// immediately once it has completed.
  Future<void> ensureLoaded() {
    if (_isLoaded) return Future.value();
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    // Each section is wrapped in its own try/catch so that a failure in one
    // bitmap (e.g. a missing asset on web) doesn't prevent the others from
    // loading. Callers fall back to `BitmapDescriptor.default*` for any
    // descriptor that ends up null.

    try {
      _vertex = await _renderCircle(
        size: 16.0,
        fill: Colors.white,
        border: Colors.red,
        borderWidth: 1.5,
      );
    } catch (_) {
      _vertex = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    }

    try {
      _midpoint = await _renderMidpoint();
    } catch (_) {
      _midpoint =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    }

    try {
      _firstVertex = await _renderCircle(
        size: 20.0,
        fill: Colors.green,
        border: Colors.white,
        borderWidth: 2.0,
      );
    } catch (_) {
      _firstVertex =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
    }

    try {
      await PointMarkerIcons.preload();
      _pointCategoryIcons = PointMarkerIcons.allCached;
    } catch (_) {
      _pointCategoryIcons = null;
    }

    try {
      _waypoint = await _loadAssetBitmap('assets/letterbox.png', width: 16);
    } catch (_) {
      _waypoint = null;
    }

    try {
      await MarkerClusterer.loadBaseImage();
      _clusterIcons = await MarkerClusterer.warmUpClusterIcons();
    } catch (_) {
      _clusterIcons = const {};
    }

    _isLoaded = true;
  }

  // ── Internal raster helpers (moved out of _MapViewWidgetState) ────────

  static Future<BitmapDescriptor> _renderCircle({
    required double size,
    required Color fill,
    required Color border,
    required double borderWidth,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final radius = size / 2;
    final fillPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(radius, radius), radius - borderWidth, fillPaint);
    final borderPaint = Paint()
      ..color = border
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;
    canvas.drawCircle(
        Offset(radius, radius), radius - borderWidth, borderPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) {
      throw StateError('toByteData returned null for circle marker');
    }
    return BitmapDescriptor.bytes(png.buffer.asUint8List());
  }

  static Future<BitmapDescriptor> _renderMidpoint() async {
    const size = 12.0;
    const radius = size / 2;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final fillPaint = Paint()
      ..color = Colors.orange
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(radius, radius), radius - 1.0, fillPaint);
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(const Offset(radius, radius), radius - 1.0, borderPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) {
      throw StateError('toByteData returned null for midpoint marker');
    }
    return BitmapDescriptor.bytes(png.buffer.asUint8List());
  }

  static Future<BitmapDescriptor?> _loadAssetBitmap(
    String assetPath, {
    required int width,
  }) async {
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: width,
    );
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return null;
    return BitmapDescriptor.bytes(png.buffer.asUint8List());
  }
}
