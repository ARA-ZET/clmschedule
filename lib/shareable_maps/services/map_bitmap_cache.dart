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
    debugPrint('[WASM-DEBUG] MapBitmapCache._load() starting');

    try {
      _vertex = await _renderCircle(
        size: 16.0,
        fill: Colors.white,
        border: Colors.red,
        borderWidth: 1.5,
      );
      debugPrint('[WASM-DEBUG] _vertex loaded from Canvas PNG');
    } catch (e) {
      debugPrint('[WASM-DEBUG] _vertex FALLBACK due to: $e');
      _vertex = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    }

    try {
      _midpoint = await _renderCircle(
        size: 14.0,
        fill: Colors.orange,
        border: Colors.white,
        borderWidth: 1.5,
      );
      debugPrint('[WASM-DEBUG] _midpoint loaded from Canvas PNG');
    } catch (e) {
      debugPrint('[WASM-DEBUG] _midpoint FALLBACK due to: $e');
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
      debugPrint('[WASM-DEBUG] _firstVertex loaded from Canvas PNG');
    } catch (e) {
      debugPrint('[WASM-DEBUG] _firstVertex FALLBACK due to: $e');
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

  /// PNG magic bytes: 0x89 'P' 'N' 'G' 0x0D 0x0A 0x1A 0x0A
  static bool _isValidPng(Uint8List b) {
    if (b.length < 8) return false;
    return b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47 &&
        b[4] == 0x0D &&
        b[5] == 0x0A &&
        b[6] == 0x1A &&
        b[7] == 0x0A;
  }

  /// Render a small filled circle with a border directly at [size]×[size].
  ///
  /// Note: in earlier Flutter/skwasm builds (pre-update), rendering tiny
  /// canvases under `flutter run --wasm` produced oversized/mis-anchored
  /// PNGs, so we previously rendered at 64×64 and clamped. With the
  /// current Flutter toolchain the small-canvas path works again, so we
  /// raster directly at the target size for sharper output. The PNG magic
  /// check and `width`/`height` clamp remain as cheap safety nets.
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
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(radius, radius), radius - borderWidth, fillPaint);
    final borderPaint = Paint()
      ..color = border
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;
    canvas.drawCircle(
        Offset(radius, radius), radius - borderWidth, borderPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    debugPrint('[WASM-DEBUG] _renderCircle: ${size}px '
        'raster=${img.width}x${img.height} '
        'png=${png?.lengthInBytes ?? 0} bytes');
    if (png == null) {
      throw StateError('toByteData returned null for circle marker');
    }
    final bytes = png.buffer.asUint8List();
    if (!_isValidPng(bytes)) {
      debugPrint('[WASM-DEBUG] _renderCircle: \u26a0\ufe0f INVALID PNG magic '
          '\u2014 falling back to defaultMarker');
      throw StateError('Invalid PNG bytes produced for circle marker');
    }
    return BitmapDescriptor.bytes(
      bytes,
      width: size,
      height: size,
    );
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
