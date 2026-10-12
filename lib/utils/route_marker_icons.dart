import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Numbered pins for an optimised route.
///
/// A route is only readable on a map if you can see the drive order at a
/// glance, which coloured dots alone cannot convey. These render the stop
/// number into the pin, cached per (number, colour) so a 200-stop route
/// rasterises each glyph once.
class RouteMarkerIcons {
  RouteMarkerIcons._();

  /// Logical size of a pin on screen, in points.
  static const double _size = 38.0;

  /// The canvas is drawn at this multiple of [_size] and handed to the map
  /// with a matching `imagePixelRatio`, so the number stays crisp on a
  /// retina display without the map rescaling the bitmap itself.
  static const double _pixelRatio = 3.0;

  static final Map<String, BitmapDescriptor> _cache = {};

  /// How many pins fell back to an unnumbered stock marker because the
  /// renderer could not encode a PNG. Non-zero means the map is showing
  /// plain pins and the numbering looks broken to the user.
  static int _encodeFailures = 0;
  static int get encodeFailures => _encodeFailures;

  /// Colour for stop [index] of [total] — green at the start, warming
  /// through amber to red at the final drop.
  static Color colorForPosition(int index, int total) {
    if (total <= 1) return const Color(0xFF2E7D32);
    final t = index / (total - 1);
    return Color.lerp(
      const Color(0xFF2E7D32), // green
      const Color(0xFFC62828), // red
      t,
    )!;
  }

  /// A numbered pin. [label] is normally the stop number, but any short
  /// string works ("S" for a depot).
  static Future<BitmapDescriptor> numbered(
    String label, {
    required Color color,
    bool highlighted = false,
  }) async {
    final key = '$label|${color.toARGB32()}|$highlighted';
    final cached = _cache[key];
    if (cached != null) return cached;

    final icon = await _render(label, color, highlighted);
    _cache[key] = icon;
    return icon;
  }

  /// A plain dot for un-routed addresses, sized to read at suburb zoom.
  static Future<BitmapDescriptor> dot({
    required Color color,
    bool highlighted = false,
  }) =>
      numbered('', color: color, highlighted: highlighted);

  /// Build numbered pins for a whole set at once.
  ///
  /// [specs] maps an arbitrary key — a map point id, an address id — to the
  /// label and colour its pin should carry. Rasterisation is cached per
  /// (label, colour), so a run that repeats a colour only pays for it once,
  /// and re-calling this after an unrelated rebuild is nearly free.
  static Future<Map<String, BitmapDescriptor>> batch(
    Map<String, ({String label, Color color})> specs,
  ) async {
    final icons = <String, BitmapDescriptor>{};
    for (final entry in specs.entries) {
      icons[entry.key] = await numbered(
        entry.value.label,
        color: entry.value.color,
      );
    }
    return icons;
  }

  static void clearCache() => _cache.clear();

  // ── Testing hooks ──────────────────────────────────────────────────────

  /// Renders one pin and reports whether it produced a real numbered
  /// bitmap rather than falling back to a stock marker.
  @visibleForTesting
  static Future<bool> renderProducesBitmap(String label, Color color) async {
    final before = _encodeFailures;
    await _render(label, color, false);
    return _encodeFailures == before;
  }

  /// The raw pixels of a rendered pin, for tests that need to prove the
  /// glyph is actually painted rather than trusting a non-empty PNG.
  @visibleForTesting
  static Future<ui.Image> renderImage(String label, Color color) async {
    final recorder = ui.PictureRecorder();
    _paintPin(Canvas(recorder), label, color, false);
    return recorder.endRecording().toImage(
          (_size * _pixelRatio).round(),
          (_size * _pixelRatio).round(),
        );
  }

  /// Logical size of a pin, in points.
  @visibleForTesting
  static double get pinSize => _size;

  // ── Rendering ──────────────────────────────────────────────────────────

  static Future<BitmapDescriptor> _render(
    String label,
    Color color,
    bool highlighted,
  ) async {
    final recorder = ui.PictureRecorder();
    _paintPin(Canvas(recorder), label, color, highlighted);

    final image = await recorder.endRecording().toImage(
          (_size * _pixelRatio).round(),
          (_size * _pixelRatio).round(),
        );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    // The skwasm renderer has been seen returning empty or malformed PNG
    // bytes; fall back to a stock pin rather than showing nothing.
    final bytes = data?.buffer.asUint8List();
    final validPng = bytes != null &&
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    if (!validPng) {
      // A stock pin carries no number, so a silent fallback here looks
      // exactly like "the numbering feature is broken". Say so.
      debugPrint('RouteMarkerIcons: PNG encode failed for "$label" — '
          'falling back to an unnumbered pin '
          '(${bytes == null ? 'null bytes' : '${bytes.length} bytes'})');
      _encodeFailures++;
      return BitmapDescriptor.defaultMarkerWithHue(
          HSLColor.fromColor(color).hue);
    }

    // `imagePixelRatio` rather than `width`/`height`: the sized form sends
    // the map into a rescaling path, and a marker that silently fails to
    // draw there is indistinguishable from one that was never added.
    return BitmapDescriptor.bytes(bytes, imagePixelRatio: _pixelRatio);
  }

  /// Draw one pin onto [canvas], in logical points.
  static void _paintPin(
    Canvas canvas,
    String label,
    Color color,
    bool highlighted,
  ) {
    canvas.scale(_pixelRatio);

    const double w = _size;
    const double h = _size;
    const double r = 13;
    const center = Offset(w / 2, r + 3);

    // Drop shadow so pins stay legible over satellite imagery.
    canvas.drawCircle(
      center + const Offset(0, 1.5),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );

    // Pointer tail down to the exact coordinate.
    final tail = Path()
      ..moveTo(center.dx - 4.5, center.dy + r - 3)
      ..lineTo(center.dx, h - 2)
      ..lineTo(center.dx + 4.5, center.dy + r - 3)
      ..close();
    canvas.drawPath(tail, Paint()..color = color);

    canvas.drawCircle(center, r, Paint()..color = color);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = highlighted ? Colors.white : Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = highlighted ? 2.5 : 1.8,
    );

    if (highlighted) {
      canvas.drawCircle(
        center,
        r + 2.5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
    }

    if (label.isEmpty) return;

    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: label.length >= 3 ? 10 : 13,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
  }
}
