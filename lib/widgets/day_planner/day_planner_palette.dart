import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/dropsheet_day.dart';
import '../../models/job.dart';
import '../../providers/dropsheet_provider.dart' show kUnassignedSectionId;

/// Colour palette for driver sections inside the day planner. Index 0
/// is reserved for the synthetic "Unassigned" bucket.
const Color kUnassignedColor = Color(0xFF9E9E9E);

const List<Color> _driverPalette = <Color>[
  Color(0xFF1976D2), // blue
  Color(0xFFE65100), // orange
  Color(0xFF2E7D32), // green
  Color(0xFF6A1B9A), // purple
  Color(0xFFC62828), // red
  Color(0xFF00838F), // teal
  Color(0xFF558B2F), // lime green
  Color(0xFFAD1457), // pink
  Color(0xFF4527A0), // deep purple
  Color(0xFFEF6C00), // dark orange
];

/// Stable colour for a driver section based on its position among the
/// non-Unassigned sections in [allSections]. Returns [kUnassignedColor]
/// for the Unassigned bucket or unknown sections.
Color colorForSection(
    String sectionId, List<DropsheetDriverSection> allSections) {
  if (sectionId == kUnassignedSectionId) return kUnassignedColor;
  final ordered =
      allSections.where((s) => s.id != kUnassignedSectionId).toList();
  final idx = ordered.indexWhere((s) => s.id == sectionId);
  if (idx < 0) return kUnassignedColor;
  return _driverPalette[idx % _driverPalette.length];
}

/// Geographic centroid of [points]. Falls back to (0,0) for empty input.
LatLng centroidOf(List<LatLng> points) {
  if (points.isEmpty) return const LatLng(0, 0);
  double lat = 0, lng = 0;
  for (final p in points) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / points.length, lng / points.length);
}

/// Default drop-off location for a distributor [job]: use the explicit
/// [Job.dropOffPoint] if present, otherwise the centroid of the first
/// non-empty work-area polygon. Returns null if nothing geographic is
/// available.
LatLng? defaultDropOffFor(Job job) {
  if (job.dropOffPoint != null) return job.dropOffPoint;
  for (final wm in job.workMaps) {
    if (wm.points.isEmpty) continue;
    if (wm.isPoint) return wm.points.first;
    return centroidOf(wm.points);
  }
  return null;
}

/// Default pick-up location for [job]: uses the explicit [Job.pickUpPoint] if
/// set, otherwise falls back to [defaultDropOffFor] (same area, different stop).
LatLng? defaultPickUpFor(Job job) {
  if (job.pickUpPoint != null) return job.pickUpPoint;
  return defaultDropOffFor(job);
}

/// Holds the rendered bitmap and the correct anchor for a teardrop marker.
typedef MarkerBitmap = ({BitmapDescriptor icon, Offset anchor});

/// Generates and caches numbered teardrop-pin bitmaps for Google Maps.
/// Each pin has a coloured circle + downward tip (so the exact coordinate
/// is obvious) and an optional distributor-name badge to the right.
class NumberedMarkerCache {
  final Map<String, MarkerBitmap> _cache = {};

  Future<MarkerBitmap> get({
    required Color color,
    required int number,
    String primaryLabel = '',
    String secondaryLabel = '',
    bool isPickUp = false,
    int? iconCodePoint,
  }) async {
    final key =
        '${color.toString()}_${number}_${primaryLabel}_${secondaryLabel}_${isPickUp}_${iconCodePoint ?? ''}';
    final existing = _cache[key];
    if (existing != null) return existing;
    final result = await _renderPinBytes(
      color: color,
      number: number,
      primaryLabel: primaryLabel,
      secondaryLabel: secondaryLabel,
      isPickUp: isPickUp,
      iconCodePoint: iconCodePoint,
    );
    // ignore: deprecated_member_use
    final desc = BitmapDescriptor.fromBytes(result.bytes);
    final entry = (icon: desc, anchor: result.anchor);
    _cache[key] = entry;
    return entry;
  }

  /// Like [get] but renders a Material icon glyph in the circle instead of
  /// an order number. Used for special pins (e.g. the Office depot marker).
  Future<MarkerBitmap> getIconMarker({
    required Color color,
    required int iconCodePoint,
    String primaryLabel = '',
    String secondaryLabel = '',
  }) async {
    final key =
        '${color.toString()}_ico_${iconCodePoint}_${primaryLabel}_$secondaryLabel';
    final existing = _cache[key];
    if (existing != null) return existing;
    final result = await _renderIconPinBytes(
      color: color,
      iconCodePoint: iconCodePoint,
      primaryLabel: primaryLabel,
      secondaryLabel: secondaryLabel,
    );
    // ignore: deprecated_member_use
    final desc = BitmapDescriptor.fromBytes(result.bytes);
    final entry = (icon: desc, anchor: result.anchor);
    _cache[key] = entry;
    return entry;
  }

  void clear() => _cache.clear();
}

/// Renders a teardrop-shaped marker bitmap and returns both the PNG bytes
/// and the correct [Offset] anchor so the pin tip sits on the coordinate.
///
/// Layout (left → right):
///   [pad] [circle outerR=16] [gap=6] [label badge + padH=6 each side] [pad]
///
/// [primaryLabel] is shown in bold at the top of the badge.
/// [secondaryLabel] (optional) is shown smaller below it in grey.
/// If both are empty the image is just wide enough for the circle.
Future<({Uint8List bytes, Offset anchor})> _renderPinBytes({
  required Color color,
  required int number,
  String primaryLabel = '',
  String secondaryLabel = '',
  bool isPickUp = false,
  int? iconCodePoint,
}) async {
  // All dimensions are scaled to 40% of the original (reduced by 60%).
  const double s = 0.6;
  const double outerR = 26.0 * s; // white ring radius
  const double fillR = 22.0 * s; // coloured fill radius
  const double tipH = 20.0 * s; // tip length below circle-bottom
  const double pad = 6.0 * s; // outer bleed / shadow padding
  const double gap = 8.0 * s; // space between circle and label badge
  const double primaryFontSz = 20.0 * s;
  const double secondaryFontSz = 14.0 * s;
  const double innerLineGap = 3.0 * s; // gap between primary and secondary
  const double labelPadH = 9.0 * s; // badge horizontal inner padding
  const double labelPadV = 5.0 * s; // badge vertical inner padding
  const double maxBadgeTextW = 160.0 * s; // max text width
  const double numFontSz = 26.0 * s; // order number font size
  const double tipHalfW = 10.0 * s;
  const double textMeasureBuffer = 12.0 * s;

  // ── Measure labels ────────────────────────────────────────────────
  final effectivePrimary = primaryLabel.isNotEmpty
      ? primaryLabel
      : (secondaryLabel.isNotEmpty ? secondaryLabel : '');
  final effectiveSecondary = primaryLabel.isNotEmpty ? secondaryLabel : '';

  TextPainter? primaryTp;
  if (effectivePrimary.isNotEmpty) {
    primaryTp = TextPainter(
      text: TextSpan(
        text: effectivePrimary,
        style: const TextStyle(
          color: Color(0xFF202124),
          fontSize: primaryFontSz,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxBadgeTextW);
  }

  TextPainter? secondaryTp;
  if (effectiveSecondary.isNotEmpty) {
    secondaryTp = TextPainter(
      text: TextSpan(
        text: effectiveSecondary,
        style: const TextStyle(
          color: Color(0xFF5F6368),
          fontSize: secondaryFontSz,
          fontWeight: FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxBadgeTextW);
  }

  final hasLabel = primaryTp != null;

  // ── Geometry ──────────────────────────────────────────────────────
  final double textBlockH = primaryTp == null
      ? 0.0
      : (primaryTp.height +
          (secondaryTp != null ? innerLineGap + secondaryTp.height : 0.0));
  // Safety buffer: on Flutter web (CanvasKit/Skwasm) the rasteriser sometimes
  // paints glyphs slightly wider than TextPainter.layout() reports — usually
  // due to font fallback when Roboto isn't immediately available. Without
  // this buffer the right edge of the badge (and the last 1–2 characters)
  // gets cropped when the PNG is encoded. Buffer is generous enough to
  // cover the worst-case wasm font-fallback discrepancy.
  // Uniform badge width: every labelled marker is rendered at exactly
  // [maxBadgeTextW] regardless of the actual measured text width, so all
  // markers on the day planner share the same footprint. Text longer
  // than [maxBadgeTextW] is ellipsis-truncated by the TextPainter above.
  final double badgeInnerW =
      primaryTp == null ? 0.0 : maxBadgeTextW + textMeasureBuffer;
  final double badgeW = hasLabel ? (labelPadH * 2 + badgeInnerW) : 0.0;
  final double sideExt = hasLabel ? (outerR - 2) + gap + badgeW : 0.0;
  // Pin circle is LEFT-aligned in the bitmap: only `outerR + pad` of empty
  // space to the left of centre. The label badge (if any) extends to the
  // right. This keeps the OS hit-rect tight to the visible ink — any touch
  // in the transparent area to the left or beyond the badge falls through
  // to the map.
  final double cx = outerR + pad;
  final double rightHalf =
      math.max(outerR + pad, hasLabel ? sideExt + pad : outerR + pad);
  final double w = cx + rightHalf;
  final double cy = outerR + pad;
  final double tipY = cy + outerR + tipH;
  final double h = tipY;

  // Badge bounds (needed for tip position and drawing).
  final double badgeL = cx + outerR - 2;
  final double badgeR = badgeL + (hasLabel ? gap + badgeW : 0.0);

  // Tip position: horizontal centre of the combined [circle … badge] span
  // for labelled markers; directly below the circle for plain pins.
  // This places a standalone pointer between the two separate elements.
  final double tipX = hasLabel ? (cx - outerR + badgeR) / 2 : cx;
  // Tip triangle geometry.
  final double tipBaseY = cy + outerR; // base at circle bottom
  // Anchor maps the exact tip pixel to the map coordinate.
  final anchor = Offset(tipX / w, 1.0);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  // ── Drop shadow ───────────────────────────────────────────────────
  final shadowPaint = Paint()
    // ignore: deprecated_member_use
    ..color = Colors.black.withOpacity(0.28)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
  // Circle shadow
  canvas.drawCircle(Offset(cx, cy + 2), outerR - 1, shadowPaint);
  // Tip triangle shadow
  final shadowTipPath = Path()
    ..moveTo(tipX - tipHalfW, tipBaseY + 2)
    ..lineTo(tipX + tipHalfW, tipBaseY + 2)
    ..lineTo(tipX, tipY + 3)
    ..close();
  canvas.drawPath(shadowTipPath, shadowPaint);

  // ── Label badge (drawn behind the circle) ─────────────────────────
  if (primaryTp != null) {
    // badgeL / badgeR are defined in the geometry section above.
    final badgeT = cy - textBlockH / 2 - labelPadV;
    final badgeB = cy + textBlockH / 2 + labelPadV;
    final badgeRect = RRect.fromLTRBR(
        badgeL, badgeT, badgeR, badgeB, const Radius.circular(6));
    canvas.drawRRect(badgeRect, Paint()..color = Colors.white);
    canvas.drawRRect(
      badgeRect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
    final textX = badgeL + gap + labelPadH;
    final primaryY = cy - textBlockH / 2;
    primaryTp.paint(canvas, Offset(textX, primaryY));
    if (secondaryTp != null) {
      secondaryTp.paint(
        canvas,
        Offset(textX, primaryY + primaryTp.height + innerLineGap),
      );
    }
  }

  // ── Tip triangle (drawn below circle and badge, behind both) ───────────
  // Standalone pointer — the circle and badge each stand on their own;
  // the tip simply points at the exact map coordinate from between them.
  final tipPath = Path()
    ..moveTo(tipX - tipHalfW, tipBaseY)
    ..lineTo(tipX + tipHalfW, tipBaseY)
    ..lineTo(tipX, tipY)
    ..close();
  canvas.drawPath(tipPath, Paint()..color = color);

  // ── White ring (green for pick-up markers) ────────────────────
  final ringColor = isPickUp ? const Color(0xFF43A047) : Colors.white;
  canvas.drawCircle(Offset(cx, cy), outerR, Paint()..color = ringColor);

  // ── Coloured circle fill (standalone, no teardrop tail) ──────────────
  canvas.drawCircle(Offset(cx, cy), fillR, Paint()..color = color);

  // ── Order number / icon glyph ─────────────────────────────────────
  if (iconCodePoint != null) {
    final iconTp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(iconCodePoint),
        style: TextStyle(
          color: Colors.white,
          fontSize: numFontSz,
          fontFamily: 'MaterialIcons',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    iconTp.paint(canvas, Offset(cx - iconTp.width / 2, cy - iconTp.height / 2));
  } else {
    final numTp = TextPainter(
      text: TextSpan(
        text: '$number',
        style: TextStyle(
          color: Colors.white,
          fontSize: numFontSz,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    numTp.paint(canvas, Offset(cx - numTp.width / 2, cy - numTp.height / 2));
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(w.toInt(), h.toInt());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return (bytes: byteData!.buffer.asUint8List(), anchor: anchor);
}

/// Same teardrop layout as [_renderPinBytes] but draws a Material icon glyph
/// inside the circle instead of an order number.
Future<({Uint8List bytes, Offset anchor})> _renderIconPinBytes({
  required Color color,
  required int iconCodePoint,
  String primaryLabel = '',
  String secondaryLabel = '',
}) async {
  const double s = 0.6;
  const double outerR = 26.0 * s;
  const double fillR = 22.0 * s;
  const double tipH = 20.0 * s;
  const double pad = 6.0 * s;
  const double gap = 8.0 * s;
  const double primaryFontSz = 20.0 * s;
  const double secondaryFontSz = 14.0 * s;
  const double innerLineGap = 3.0 * s;
  const double labelPadH = 9.0 * s;
  const double labelPadV = 5.0 * s;
  const double maxBadgeTextW = 160.0 * s;
  const double iconFontSz = 24.0 * s;
  const double tipHalfW = 10.0 * s;
  const double textMeasureBuffer = 12.0 * s;

  TextPainter? primaryTp;
  if (primaryLabel.isNotEmpty) {
    primaryTp = TextPainter(
      text: TextSpan(
        text: primaryLabel,
        style: const TextStyle(
          color: Color(0xFF202124),
          fontSize: primaryFontSz,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxBadgeTextW);
  }

  TextPainter? secondaryTp;
  if (secondaryLabel.isNotEmpty) {
    secondaryTp = TextPainter(
      text: TextSpan(
        text: secondaryLabel,
        style: const TextStyle(
          color: Color(0xFF5F6368),
          fontSize: secondaryFontSz,
          fontWeight: FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxBadgeTextW);
  }

  final hasLabel = primaryTp != null;
  final double textBlockH = primaryTp == null
      ? 0.0
      : (primaryTp.height +
          (secondaryTp != null ? innerLineGap + secondaryTp.height : 0.0));
  final double badgeInnerW =
      primaryTp == null ? 0.0 : maxBadgeTextW + textMeasureBuffer;
  final double badgeW = hasLabel ? (labelPadH * 2 + badgeInnerW) : 0.0;
  final double sideExt = hasLabel ? (outerR - 2) + gap + badgeW : 0.0;
  final double cx = outerR + pad;
  final double rightHalf =
      math.max(outerR + pad, hasLabel ? sideExt + pad : outerR + pad);
  final double w = cx + rightHalf;
  final double cy = outerR + pad;
  final double tipY = cy + outerR + tipH;
  final double h = tipY;
  final double badgeL = cx + outerR - 2;
  final double badgeR = badgeL + (hasLabel ? gap + badgeW : 0.0);
  final double tipX = hasLabel ? (cx - outerR + badgeR) / 2 : cx;
  final double tipBaseY = cy + outerR;
  final anchor = Offset(tipX / w, 1.0);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  // Drop shadow
  final shadowPaint = Paint()
    // ignore: deprecated_member_use
    ..color = Colors.black.withOpacity(0.28)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
  canvas.drawCircle(Offset(cx, cy + 2), outerR - 1, shadowPaint);
  final shadowTipPath = Path()
    ..moveTo(tipX - tipHalfW, tipBaseY + 2)
    ..lineTo(tipX + tipHalfW, tipBaseY + 2)
    ..lineTo(tipX, tipY + 3)
    ..close();
  canvas.drawPath(shadowTipPath, shadowPaint);

  // Label badge
  if (primaryTp != null) {
    final badgeT = cy - textBlockH / 2 - labelPadV;
    final badgeB = cy + textBlockH / 2 + labelPadV;
    final badgeRect = RRect.fromLTRBR(
        badgeL, badgeT, badgeR, badgeB, const Radius.circular(6));
    canvas.drawRRect(badgeRect, Paint()..color = Colors.white);
    canvas.drawRRect(
      badgeRect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
    final textX = badgeL + gap + labelPadH;
    final primaryY = cy - textBlockH / 2;
    primaryTp.paint(canvas, Offset(textX, primaryY));
    if (secondaryTp != null) {
      secondaryTp.paint(
          canvas, Offset(textX, primaryY + primaryTp.height + innerLineGap));
    }
  }

  // Tip triangle
  final tipPath = Path()
    ..moveTo(tipX - tipHalfW, tipBaseY)
    ..lineTo(tipX + tipHalfW, tipBaseY)
    ..lineTo(tipX, tipY)
    ..close();
  canvas.drawPath(tipPath, Paint()..color = color);

  // White ring + coloured fill
  canvas.drawCircle(Offset(cx, cy), outerR, Paint()..color = Colors.white);
  canvas.drawCircle(Offset(cx, cy), fillR, Paint()..color = color);

  // Icon glyph
  final iconTp = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(iconCodePoint),
      style: TextStyle(
        fontFamily: 'MaterialIcons',
        color: Colors.white,
        fontSize: iconFontSz,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  iconTp.paint(canvas, Offset(cx - iconTp.width / 2, cy - iconTp.height / 2));

  final picture = recorder.endRecording();
  final image = await picture.toImage(w.toInt(), h.toInt());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return (bytes: byteData!.buffer.asUint8List(), anchor: anchor);
}
