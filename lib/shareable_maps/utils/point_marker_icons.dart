import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/custom_polygon.dart' show PointCategory;

/// Generates and caches BitmapDescriptor icons for each [PointCategory].
///
/// Icons are coloured circles with a single‑letter label drawn via Canvas.
/// Call [getIcon] to obtain a descriptor; results are cached so each
/// category is only rasterised once per app session.
class PointMarkerIcons {
  PointMarkerIcons._();

  static final Map<PointCategory, BitmapDescriptor> _cache = {};

  /// Return the cached icon for [category], creating it if needed.
  static Future<BitmapDescriptor> getIcon(PointCategory category) async {
    if (_cache.containsKey(category)) return _cache[category]!;
    final icon = await _create(category);
    _cache[category] = icon;
    return icon;
  }

  /// Pre‑warm the cache for all categories.
  static Future<void> preload() async {
    for (final cat in PointCategory.values) {
      await getIcon(cat);
    }
  }

  /// Get all cached icons at once (must call [preload] first).
  static Map<PointCategory, BitmapDescriptor> get allCached =>
      Map.unmodifiable(_cache);

  // ── Internal rendering ───────────────────────────────────────────────

  static const double _size = 48.0;

  static Future<BitmapDescriptor> _create(PointCategory cat) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const double r = _size / 2;
    final center = const Offset(r, r);

    // Shadow
    final shadowPaint = Paint()
      ..color = Colors.black26
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(center + const Offset(1, 2), r - 4, shadowPaint);

    // Filled circle
    final fill = Paint()
      ..color = cat.color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, r - 4, fill);

    // White border
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, r - 4, border);

    // Icon glyph (rendered via the MaterialIcons font)
    final iconData = cat.icon;
    final textPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(iconData.codePoint),
        style: TextStyle(
          fontSize: 22,
          fontFamily: iconData.fontFamily,
          package: iconData.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(r - textPainter.width / 2, r - textPainter.height / 2),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(_size.toInt(), _size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      return BitmapDescriptor.defaultMarkerWithHue(
          HSLColor.fromColor(cat.color).hue);
    }
    return BitmapDescriptor.bytes(bytes.buffer.asUint8List());
  }
}
