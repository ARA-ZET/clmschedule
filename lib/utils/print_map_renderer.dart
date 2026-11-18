import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:http/http.dart' as http;

import '../env.dart';
import '../shareable_maps/services/map_thumbnail_service.dart'
    show ThumbnailMarkerData, ThumbnailPathData;
import 'map_pin_icons.dart';

/// A client-name label pinned to a map position, drawn upright.
class PrintMapLabel {
  final LatLng anchor;
  final String text;

  const PrintMapLabel({required this.anchor, required this.text});
}

/// One printed page's map picture.
class PrintMapPage {
  final Uint8List pngBytes;
  final bool isLandscape;

  /// 0 for a single page or the overview, otherwise 1..[sectionCount].
  final int section;

  /// How many zoomed-in sections the job was split into; 0 when the whole
  /// job fits one page with readable street names.
  final int sectionCount;

  const PrintMapPage({
    required this.pngBytes,
    required this.isLandscape,
    this.section = 0,
    this.sectionCount = 0,
  });

  bool get isOverview => section == 0 && sectionCount > 0;
}

/// What one map picture shows: centre, zoom, turn and size in pixels.
class _Frame {
  /// Centre in zoom-0 world units (0..256).
  final Offset center;
  final int zoom;
  final int degrees;
  final double outW;
  final double outH;
  final bool isLandscape;

  const _Frame({
    required this.center,
    required this.zoom,
    required this.degrees,
    required this.outW,
    required this.outH,
    required this.isLandscape,
  });

  double get pxPerUnit =>
      math.pow(2, zoom).toDouble() * PrintMapRenderer._scale;
  double get angle => degrees * math.pi / 180;
  Offset get outCenter => Offset(outW / 2, outH / 2);

  /// World point → picture pixel, before turning (canvas is turned).
  Offset local(Offset world) => (world - center) * pxPerUnit;

  /// World point → picture pixel, after turning.
  Offset toOut(Offset world) =>
      PrintMapRenderer._rotate(local(world), angle) + outCenter;

  /// Picture pixel → world point.
  Offset toWorld(Offset out) =>
      center +
      PrintMapRenderer._rotate(out - outCenter, -angle) / pxPerUnit;

  /// The picture's corners in world units: top-left, top-right,
  /// bottom-right, bottom-left.
  List<Offset> get worldCorners => [
        toWorld(Offset.zero),
        toWorld(Offset(outW, 0)),
        toWorld(Offset(outW, outH)),
        toWorld(Offset(0, outH)),
      ];
}

/// Builds the printed distribution map straight from Google Static Maps,
/// with no screen capture.
///
/// The aim is a map where the street names are readable on paper, because
/// distributors often work in areas they do not know. Google only names
/// the smaller streets from about zoom [_readableZoom], so:
/// - When the whole job fits one page at that zoom or closer, it prints as
///   one page, fitted to the work areas with a small margin.
/// - Otherwise it prints an overview page of the whole job, with each
///   zoomed-in section outlined and numbered, followed by one page per
///   section. Work areas that sit close together share a section; an area
///   too big for one page is split into a grid of overlapping pages, and
///   grid pages with no work on them are skipped.
///
/// Fitted pages are turned to the angle (up to 45° either way, portrait or
/// landscape) that lines the area's long axis up with the page, when that
/// makes it clearly larger; a north arrow then shows north. The base map is
/// stitched from several high-zoom Static Maps images. Work areas, tracks,
/// markers and labels are drawn on top locally, at full detail. [mapId]
/// applies the same cloud map style as the on-screen map.
class PrintMapRenderer {
  PrintMapRenderer._();

  static const _baseUrl = 'https://maps.googleapis.com/maps/api/staticmap';

  /// Static Maps returns at most 640x640, doubled by scale=2.
  static const int _tileLogical = 640;
  static const int _scale = 2;
  static const double _tilePx = _tileLogical * _scale * 1.0;

  /// Each image carries Google's logo and copyright along its bottom edge.
  /// Rows overlap by this much so the next row covers that strip, and the
  /// last row's strip falls outside the picture. Attribution is redrawn once.
  static const double _bottomStripPx = 40.0 * _scale;

  /// Columns overlap a little so a turned map shows no seams between images.
  static const double _stepX = _tilePx - 4;
  static const double _stepY = _tilePx - _bottomStripPx;

  /// The fitted area's long side is kept at or under this many pixels
  /// before margins. Picks the zoom: about 200 dpi across an A4 page, which
  /// keeps Google's street names about 3 mm tall on paper.
  static const double _targetLongSidePx = 2300;
  static const double _marginPx = 70;

  /// Map box on the A4 PDF page in points, after margins, header and a
  /// typical footer. Approximate; the PDF fits the image inside.
  static const Size _landscapeBox = Size(822, 450);
  static const Size _portraitBox = Size(575, 680);

  /// Turning the map is only worth it when the area prints this much
  /// larger than north-up. Small gains are not worth tilted street names.
  static const double _minRotationGain = 1.08;
  static const int _maxRotationDegrees = 45;

  /// The zoom from which Google names residential streets. A job that
  /// cannot fit one page at this zoom is split into sections.
  static const int _readableZoom = 16;

  /// More sections than this and the zoom steps down one level (fewer,
  /// larger sections) rather than printing a thick stack of pages.
  static const int _maxSections = 12;

  /// Grid sections overlap their neighbours by this share, so streets on
  /// a page edge also appear on the next page.
  static const double _gridOverlap = 0.08;

  static const int _maxTiles = 24;

  /// Renders the pages for one job.
  ///
  /// [areas] holds each work area's points (polygons, lines and points);
  /// they decide the framing and the sections. [extraFitPoints] (the
  /// drop-off) is framed on the overview or single page only.
  static Future<List<PrintMapPage>> renderBook({
    required List<List<LatLng>> areas,
    List<LatLng> extraFitPoints = const [],
    List<ThumbnailPathData> polygons = const [],
    List<ThumbnailPathData> polylines = const [],
    List<ThumbnailMarkerData> markers = const [],
    List<PrintMapLabel> labels = const [],
    String? mapId,
    void Function(String message)? onProgress,
  }) async {
    final areaWorld = [
      for (final a in areas)
        if (a.isNotEmpty) [for (final p in a) _world(p)],
    ];
    final all = [
      for (final a in areaWorld) ...a,
      for (final p in extraFitPoints) _world(p),
    ];
    if (all.isEmpty) {
      throw StateError('This job has no work areas to print.');
    }

    Future<Uint8List> draw(_Frame frame,
            [List<List<Offset>> outlines = const []]) =>
        _renderFrame(
          frame,
          polygons: polygons,
          polylines: polylines,
          markers: markers,
          labels: labels,
          mapId: mapId,
          outlines: outlines,
        );

    final overview = _fitFrame(_hull(all));
    var sections = <_Frame>[];
    if (areaWorld.isNotEmpty && overview.zoom < _readableZoom) {
      for (var zoom = _readableZoom; zoom >= _readableZoom - 2; zoom--) {
        sections = _planSections(areaWorld, zoom);
        if (sections.length <= _maxSections) break;
      }
    }

    if (sections.isEmpty) {
      onProgress?.call('Fetching Google map...');
      return [
        PrintMapPage(
          pngBytes: await draw(overview),
          isLandscape: overview.isLandscape,
        ),
      ];
    }

    final count = sections.length;
    onProgress?.call('Fetching overview map...');
    final pages = <PrintMapPage>[
      PrintMapPage(
        pngBytes: await draw(
          overview,
          [for (final s in sections) s.worldCorners],
        ),
        isLandscape: overview.isLandscape,
        sectionCount: count,
      ),
    ];
    for (var i = 0; i < count; i++) {
      onProgress?.call('Fetching section ${i + 1} of $count...');
      pages.add(PrintMapPage(
        pngBytes: await draw(sections[i]),
        isLandscape: sections[i].isLandscape,
        section: i + 1,
        sectionCount: count,
      ));
    }
    return pages;
  }

  // ---------------------------------------------------------------------------
  // Framing
  // ---------------------------------------------------------------------------

  /// Fits [world] points (zoom-0 units) to a page: best angle, highest
  /// whole zoom that keeps the long side within the target, a margin, and
  /// the loose side widened to the page's map box.
  static _Frame _fitFrame(List<Offset> world) {
    final origin = world.first;
    final rel = [for (final o in world) o - origin];
    final fit = _bestFit(rel);
    final angle = fit.degrees * math.pi / 180;

    var bounds = Rect.fromPoints(_rotate(rel.first, angle),
        _rotate(rel.first, angle));
    for (final o in rel.skip(1)) {
      final t = _rotate(o, angle);
      bounds = bounds.expandToInclude(Rect.fromPoints(t, t));
    }
    final longSpan = math.max(bounds.width, bounds.height);

    // A single point gets a street-level view.
    final zoom = longSpan < 1e-9
        ? 17
        : (math.log(_targetLongSidePx / _scale / longSpan) / math.ln2)
            .floor()
            .clamp(3, 19);
    final pxPerUnit = math.pow(2, zoom).toDouble() * _scale;

    final areaW = bounds.width * pxPerUnit;
    final areaH = bounds.height * pxPerUnit;
    final margin = math.max(math.max(areaW, areaH) * 0.05, _marginPx);
    var outW = areaW + margin * 2;
    var outH = areaH + margin * 2;
    final box = fit.isLandscape ? _landscapeBox : _portraitBox;
    final boxAspect = box.width / box.height;
    if (outW / outH < boxAspect) {
      outW = outH * boxAspect;
    } else {
      outH = outW / boxAspect;
    }

    return _Frame(
      center: origin + _rotate(bounds.center, -angle),
      zoom: zoom,
      degrees: fit.degrees,
      outW: outW.roundToDouble(),
      outH: outH.roundToDouble(),
      isLandscape: fit.isLandscape,
    );
  }

  /// Splits the work into sections that each print at [zoom] or closer.
  ///
  /// Work areas start as their own groups; the two whose combined fit still
  /// reaches [zoom] with the smallest combined footprint merge, until no
  /// pair can. A group that fits becomes one (possibly turned) section; a
  /// group too big for one page becomes a grid of north-up sections.
  static List<_Frame> _planSections(List<List<Offset>> areas, int zoom) {
    final groups = [
      for (var i = 0; i < areas.length; i++) [i],
    ];
    final hulls = [for (final a in areas) _hull(a)];

    while (groups.length > 1) {
      int? bestI, bestJ;
      List<Offset>? bestHull;
      var bestArea = double.infinity;
      for (var i = 0; i < groups.length; i++) {
        for (var j = i + 1; j < groups.length; j++) {
          final merged = _hull([...hulls[i], ...hulls[j]]);
          if (_fitFrame(merged).zoom < zoom) continue;
          final box = _boundsOf(merged);
          final area = box.width * box.height;
          if (area < bestArea) {
            bestArea = area;
            bestI = i;
            bestJ = j;
            bestHull = merged;
          }
        }
      }
      if (bestI == null || bestJ == null) break;
      groups[bestI].addAll(groups[bestJ]);
      hulls[bestI] = bestHull!;
      groups.removeAt(bestJ);
      hulls.removeAt(bestJ);
    }

    // Top of the map first, then left to right.
    final order = List.generate(groups.length, (i) => i)
      ..sort((a, b) {
        final ba = _boundsOf(hulls[a]), bb = _boundsOf(hulls[b]);
        final byTop = ba.top.compareTo(bb.top);
        return byTop != 0 ? byTop : ba.left.compareTo(bb.left);
      });

    final sections = <_Frame>[];
    for (final g in order) {
      final fitted = _fitFrame(hulls[g]);
      if (fitted.zoom >= zoom) {
        sections.add(fitted);
      } else {
        sections.addAll(_gridFrames([for (final i in groups[g]) areas[i]], zoom));
      }
    }
    return sections;
  }

  /// A north-up grid of overlapping pages at [zoom] covering [areas],
  /// keeping only pages that touch a work area. Portrait or landscape,
  /// whichever needs fewer pages.
  static List<_Frame> _gridFrames(List<List<Offset>> areas, int zoom) {
    final pxPerUnit = math.pow(2, zoom).toDouble() * _scale;
    final px = [
      for (final a in areas) [for (final o in a) o * pxPerUnit],
    ];
    final bounds = _boundsOf([for (final a in px) ...a]);
    final longSide = _targetLongSidePx + _marginPx * 2;

    List<_Frame> gridFor(bool landscape) {
      final box = landscape ? _landscapeBox : _portraitBox;
      final aspect = box.width / box.height;
      final cellW = landscape ? longSide : longSide * aspect;
      final cellH = landscape ? longSide / aspect : longSide;
      final stepW = cellW * (1 - _gridOverlap);
      final stepH = cellH * (1 - _gridOverlap);
      final needW = bounds.width + _marginPx * 2;
      final needH = bounds.height + _marginPx * 2;
      final cols = needW <= cellW ? 1 : 1 + ((needW - cellW) / stepW).ceil();
      final rows = needH <= cellH ? 1 : 1 + ((needH - cellH) / stepH).ceil();
      final left = bounds.center.dx - (cellW + (cols - 1) * stepW) / 2;
      final top = bounds.center.dy - (cellH + (rows - 1) * stepH) / 2;

      return [
        for (var r = 0; r < rows; r++)
          for (var c = 0; c < cols; c++)
            if (_touchesAny(
              Rect.fromLTWH(left + c * stepW, top + r * stepH, cellW, cellH),
              px,
            ))
              _Frame(
                center: Rect.fromLTWH(
                        left + c * stepW, top + r * stepH, cellW, cellH)
                        .center /
                    pxPerUnit,
                zoom: zoom,
                degrees: 0,
                outW: cellW.roundToDouble(),
                outH: cellH.roundToDouble(),
                isLandscape: landscape,
              ),
      ];
    }

    final landscape = gridFor(true);
    final portrait = gridFor(false);
    return portrait.length < landscape.length ? portrait : landscape;
  }

  /// Whether [rect] touches any area: a point inside it, an edge crossing
  /// it, or (for a polygon) the rect sitting inside the polygon.
  static bool _touchesAny(Rect rect, List<List<Offset>> areas) {
    for (final a in areas) {
      if (a.isEmpty) continue;
      if (a.any(rect.contains)) return true;
      for (var i = 0; i + 1 < a.length; i++) {
        if (_segmentTouchesRect(a[i], a[i + 1], rect)) return true;
      }
      if (a.length >= 3) {
        if (_segmentTouchesRect(a.last, a.first, rect)) return true;
        if (_pointInPolygon(rect.center, a)) return true;
      }
    }
    return false;
  }

  /// Liang–Barsky: does the segment a→b pass through [r]?
  static bool _segmentTouchesRect(Offset a, Offset b, Rect r) {
    var t0 = 0.0, t1 = 1.0;
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    for (final (p, q) in [
      (-dx, a.dx - r.left),
      (dx, r.right - a.dx),
      (-dy, a.dy - r.top),
      (dy, r.bottom - a.dy),
    ]) {
      if (p == 0) {
        if (q < 0) return false;
      } else {
        final t = q / p;
        if (p < 0) {
          if (t > t1) return false;
          if (t > t0) t0 = t;
        } else {
          if (t < t0) return false;
          if (t < t1) t1 = t;
        }
      }
    }
    return true;
  }

  static bool _pointInPolygon(Offset p, List<Offset> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i], b = poly[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// Convex hull (monotone chain). Fitting only needs the outline, and it
  /// keeps the angle search fast for areas with hundreds of points.
  static List<Offset> _hull(List<Offset> points) {
    final pts = points.toSet().toList()
      ..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
    if (pts.length < 3) return pts;
    double cross(Offset o, Offset a, Offset b) =>
        (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
    final lower = <Offset>[];
    for (final p in pts) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    final upper = <Offset>[];
    for (final p in pts.reversed) {
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    lower.removeLast();
    upper.removeLast();
    return [...lower, ...upper];
  }

  static Rect _boundsOf(List<Offset> points) {
    var r = Rect.fromPoints(points.first, points.first);
    for (final p in points.skip(1)) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r;
  }

  // ---------------------------------------------------------------------------
  // Drawing
  // ---------------------------------------------------------------------------

  static Future<Uint8List> _renderFrame(
    _Frame frame, {
    required List<ThumbnailPathData> polygons,
    required List<ThumbnailPathData> polylines,
    required List<ThumbnailMarkerData> markers,
    required List<PrintMapLabel> labels,
    required String? mapId,
    List<List<Offset>> outlines = const [],
  }) async {
    final outW = frame.outW, outH = frame.outH;
    final angle = frame.angle;
    final pxPerUnit = frame.pxPerUnit;

    // Base map images covering the turned picture, in picture pixels
    // around the frame centre, before turning.
    final corners = [
      for (final c in [
        Offset.zero,
        Offset(outW, 0),
        Offset(0, outH),
        Offset(outW, outH),
      ])
        _rotate(c - frame.outCenter, -angle),
    ];
    final cover = _boundsOf(corners);
    final cols = (cover.width / _stepX).ceil();
    final rows = (cover.height / _stepY).ceil();
    if (cols * rows > _maxTiles) {
      throw StateError('The print area is too large to fetch.');
    }
    final centerPx = frame.center * pxPerUnit;
    final tiles = await Future.wait([
      for (var r = 0; r < rows; r++)
        for (var c = 0; c < cols; c++)
          _fetchTile(
            centerWorldPx: centerPx +
                cover.topLeft +
                Offset(c * _stepX + _tilePx / 2, r * _stepY + _tilePx / 2),
            pxPerUnit: pxPerUnit,
            zoom: frame.zoom,
            mapId: mapId,
          ),
    ]);

    // Base map and work areas turned together, then upright markers,
    // labels, section outlines, north arrow and attribution.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, outW, outH));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, outW, outH),
      Paint()..color = const Color(0xFFFFFFFF),
    );

    canvas.save();
    canvas.translate(frame.outCenter.dx, frame.outCenter.dy);
    canvas.rotate(angle);
    // Rows top to bottom, so each row hides the logo strip of the one above.
    final tilePaint = Paint()..filterQuality = FilterQuality.high;
    var i = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        canvas.drawImage(
          tiles[i++],
          cover.topLeft + Offset(c * _stepX, r * _stepY),
          tilePaint,
        );
      }
    }
    for (final tile in tiles) {
      tile.dispose();
    }

    Offset local(LatLng p) => frame.local(_world(p));
    for (final path in polygons) {
      _drawPath(canvas, path, local, closed: true);
    }
    for (final path in polylines) {
      _drawPath(canvas, path, local, closed: false);
    }
    canvas.restore();

    Offset place(LatLng p) => frame.toOut(_world(p));
    for (final marker in markers) {
      _drawMarker(canvas, place(marker.position), marker);
    }
    for (final label in labels) {
      if (label.text.trim().isEmpty) continue;
      _drawLabel(canvas, place(label.anchor), label.text.trim());
    }
    for (var n = 0; n < outlines.length; n++) {
      _drawSectionOutline(
        canvas,
        [for (final w in outlines[n]) frame.toOut(w)],
        n + 1,
        Size(outW, outH),
      );
    }
    if (frame.degrees != 0) {
      _drawNorthArrow(canvas, Size(outW, outH), angle);
    }
    _drawAttribution(canvas, Size(outW, outH));

    final picture = recorder.endRecording();
    final image = await picture.toImage(outW.round(), outH.round());
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      throw StateError('Could not encode the print map image.');
    }
    return data.buffer.asUint8List();
  }

  /// A dashed outline of one section on the overview, with its number.
  /// Dashed, so it reads apart from the solid work-area borders on a
  /// black-and-white printout.
  ///
  /// The number sits in the middle of the part of the section that is on
  /// the picture (grid pages can run past the overview's edge). A section
  /// too small for that gets its number just outside its top-left corner,
  /// so the number does not hide the work area.
  static void _drawSectionOutline(
    Canvas canvas,
    List<Offset> quad,
    int number,
    Size size,
  ) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0 * _scale
      ..strokeCap = StrokeCap.butt
      ..color = const Color(0xFF000000);
    const dash = 9.0 * _scale, gap = 6.0 * _scale;
    for (var k = 0; k < 4; k++) {
      final a = quad[k], b = quad[(k + 1) % 4];
      final length = (b - a).distance;
      if (length <= 0) continue;
      final dir = (b - a) / length;
      for (var d = 0.0; d < length; d += dash + gap) {
        canvas.drawLine(
          a + dir * d,
          a + dir * math.min(d + dash, length),
          paint,
        );
      }
    }

    const radius = 17.0 * _scale;
    final picture = Offset.zero & size;
    final visible = _boundsOf(quad).intersect(picture);
    final Offset at;
    if (visible.width >= radius * 6 && visible.height >= radius * 6) {
      at = visible.center;
    } else {
      final topLeft = quad.reduce(
          (a, b) => (a.dx + a.dy) <= (b.dx + b.dy) ? a : b);
      at = Offset(
        (topLeft.dx - radius * 1.4).clamp(radius, size.width - radius),
        (topLeft.dy - radius * 1.4).clamp(radius, size.height - radius),
      );
    }
    canvas.drawCircle(at, radius, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 * _scale
        ..color = const Color(0xFF000000),
    );
    final painter = TextPainter(
      text: TextSpan(
        text: '$number',
        style: const TextStyle(
          color: Color(0xFF000000),
          fontSize: 17.0 * _scale,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
    painter.dispose();
  }

  /// Finds the angle (whole degrees, -45° to 45°) that lines the area's
  /// long axis up with the page: the turn whose bounding box is smallest,
  /// so the box hugs the area. The page orientation then follows the box's
  /// shape. Keeps north-up unless the turn prints the area at least
  /// [_minRotationGain] larger.
  ///
  /// Maximising scale alone would lay a thin strip along the page's
  /// diagonal, which fills the page with streets far from the work.
  static ({int degrees, bool isLandscape}) _bestFit(List<Offset> world) {
    ({double area, double scale, bool isLandscape}) fitAt(int degrees) {
      final a = degrees * math.pi / 180;
      final c = math.cos(a), s = math.sin(a);
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final o in world) {
        final x = o.dx * c - o.dy * s;
        final y = o.dx * s + o.dy * c;
        minX = math.min(minX, x);
        maxX = math.max(maxX, x);
        minY = math.min(minY, y);
        maxY = math.max(maxY, y);
      }
      // A floor keeps a straight line from looking infinitely scalable.
      final w = math.max(maxX - minX, 1e-9);
      final h = math.max(maxY - minY, 1e-9);
      final landscape =
          math.min(_landscapeBox.width / w, _landscapeBox.height / h);
      final portrait =
          math.min(_portraitBox.width / w, _portraitBox.height / h);
      return landscape >= portrait
          ? (area: w * h, scale: landscape, isLandscape: true)
          : (area: w * h, scale: portrait, isLandscape: false);
    }

    final upright = fitAt(0);
    if (world.length < 2) {
      return (degrees: 0, isLandscape: upright.isLandscape);
    }
    var bestDegrees = 0;
    var best = upright;
    for (var d = -_maxRotationDegrees; d <= _maxRotationDegrees; d++) {
      if (d == 0) continue;
      final f = fitAt(d);
      // Near ties (e.g. +45° and -45° hug a diagonal strip equally, one
      // upright and one sideways) go to the larger print, then the
      // smaller turn.
      final tie = f.area < best.area * 1.001 && f.area > best.area * 0.999;
      if (f.area <= best.area * 0.999 ||
          (tie && f.scale > best.scale * 1.001) ||
          (tie &&
              f.scale > best.scale * 0.999 &&
              d.abs() < bestDegrees.abs())) {
        bestDegrees = d;
        best = f;
      }
    }
    if (bestDegrees != 0 && best.scale < upright.scale * _minRotationGain) {
      return (degrees: 0, isLandscape: upright.isLandscape);
    }
    return (degrees: bestDegrees, isLandscape: best.isLandscape);
  }

  /// Turns [o] by [angle] radians, clockwise on screen.
  static Offset _rotate(Offset o, double angle) {
    final c = math.cos(angle), s = math.sin(angle);
    return Offset(o.dx * c - o.dy * s, o.dx * s + o.dy * c);
  }

  static Offset _world(LatLng p) =>
      Offset(_worldX(p.longitude), _worldY(p.latitude));

  /// A north arrow in the top-right corner, pointing where north is on the
  /// turned map.
  static void _drawNorthArrow(Canvas canvas, Size size, double angle) {
    const radius = 26.0 * _scale;
    const pad = 12.0 * _scale;
    final center = Offset(size.width - pad - radius, pad + radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xE6FFFFFF),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * _scale
        ..color = const Color(0xFF000000),
    );

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    const tip = radius * 0.62;
    const half = radius * 0.28;
    final arrow = Path()
      ..moveTo(0, -tip)
      ..lineTo(half, tip * 0.55)
      ..lineTo(0, tip * 0.25)
      ..lineTo(-half, tip * 0.55)
      ..close();
    canvas.drawPath(arrow, Paint()..color = const Color(0xFF000000));
    canvas.restore();

    final painter = TextPainter(
      text: const TextSpan(
        text: 'N',
        style: TextStyle(
          color: Color(0xFF000000),
          fontSize: 13.0 * _scale,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // The N sits just past the arrow tip, outside the circle.
    final dir = Offset(math.sin(angle), -math.cos(angle));
    final at = center + dir * (radius + painter.height * 0.65);
    final clamped = Offset(
      at.dx.clamp(painter.width / 2, size.width - painter.width / 2),
      at.dy.clamp(painter.height / 2, size.height - painter.height / 2),
    );
    painter.paint(
      canvas,
      clamped - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  static Future<ui.Image> _fetchTile({
    required Offset centerWorldPx,
    required double pxPerUnit,
    required int zoom,
    String? mapId,
  }) async {
    final lng = centerWorldPx.dx / pxPerUnit / 256 * 360 - 180;
    final lat = _latFromWorldY(centerWorldPx.dy / pxPerUnit);
    final params = <String>[
      'center=${lat.toStringAsFixed(7)},${lng.toStringAsFixed(7)}',
      'zoom=$zoom',
      'size=${_tileLogical}x$_tileLogical',
      'scale=$_scale',
      'maptype=roadmap',
      'format=png',
      // The screen map's cloud style, so paper matches screen. Without one,
      // plain roadmap minus clutter a distributor does not need.
      if (mapId != null && mapId.isNotEmpty)
        'map_id=$mapId'
      else ...[
        'style=feature:poi.business|visibility:off',
        'style=feature:poi|element:labels.icon|visibility:off',
        'style=feature:transit|visibility:off',
      ],
      'key=${Env.googleMapsApiKey}',
    ];
    final response =
        await http.get(Uri.parse('$_baseUrl?${params.join('&')}'));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw StateError(_staticMapError(response));
    }
    final codec = await ui.instantiateImageCodec(response.bodyBytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static void _drawPath(
    Canvas canvas,
    ThumbnailPathData path,
    Offset Function(LatLng) project, {
    required bool closed,
  }) {
    if (path.points.length < (closed ? 3 : 2)) return;
    final start = project(path.points.first);
    final p = Path()..moveTo(start.dx, start.dy);
    for (final point in path.points.skip(1)) {
      final o = project(point);
      p.lineTo(o.dx, o.dy);
    }
    if (closed) p.close();

    final color = path.color.withValues(alpha: 1);
    if (closed && path.fillOpacity > 0) {
      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: path.fillOpacity.clamp(0.0, 1.0)),
      );
    }
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(path.strokeWidth, 1) * _scale.toDouble()
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..color = color,
    );
  }

  static void _drawMarker(
    Canvas canvas,
    Offset at,
    ThumbnailMarkerData marker,
  ) {
    // Black-and-white pin, tip on the spot: the glyph says what is there.
    if (marker.pin != null) {
      MapPinPainter.paint(canvas, at, marker.pin!,
          scale: 1.15 * _scale, mono: true);
      return;
    }
    const radius = 11.0 * _scale;
    canvas.drawCircle(
      at,
      radius + 2.5 * _scale,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    canvas.drawCircle(
      at,
      radius,
      Paint()..color = marker.color.withValues(alpha: 1),
    );
    final label = marker.label?.trim() ?? '';
    if (label.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: label.substring(0, 1).toUpperCase(),
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 13.0 * _scale,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      at - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  /// Matches the on-screen label: bold black text with a white outline.
  static void _drawLabel(Canvas canvas, Offset at, String text) {
    const style = TextStyle(
      fontSize: 13.0 * _scale,
      fontWeight: FontWeight.w700,
      height: 1.1,
    );
    TextPainter painterFor(TextStyle s) => TextPainter(
          text: TextSpan(text: text, style: s),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          maxLines: 2,
        )..layout(maxWidth: 180.0 * _scale);

    final outline = painterFor(style.copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0 * _scale
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFFFFFFF),
    ));
    final fill = painterFor(style.copyWith(color: const Color(0xFF000000)));
    final topLeft = at - Offset(fill.width / 2, fill.height / 2);
    outline.paint(canvas, topLeft);
    fill.paint(canvas, topLeft);
    outline.dispose();
    fill.dispose();
  }

  /// The stitched images' own attribution is covered, so credit Google once.
  static void _drawAttribution(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'Map data ©${DateTime.now().year} Google',
        style: const TextStyle(
          color: Color(0xFF444444),
          fontSize: 10.0 * _scale,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const pad = 4.0 * _scale;
    final rect = Rect.fromLTWH(
      size.width - painter.width - pad * 2,
      size.height - painter.height - pad,
      painter.width + pad * 2,
      painter.height + pad,
    );
    canvas.drawRect(rect, Paint()..color = const Color(0xCCFFFFFF));
    painter.paint(canvas, Offset(rect.left + pad, rect.top + pad / 2));
    painter.dispose();
  }

  static String _staticMapError(http.Response response) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (body.isEmpty) {
      return 'Google map request failed (${response.statusCode}).';
    }
    final compact = body.replaceAll(RegExp(r'\s+'), ' ');
    final details =
        compact.length > 220 ? '${compact.substring(0, 220)}...' : compact;
    return 'Google map request failed (${response.statusCode}): $details';
  }

  static double _worldX(double lng) => (lng + 180) / 360 * 256;

  static double _worldY(double lat) {
    final s = math.sin(lat.clamp(-85.05112878, 85.05112878) * math.pi / 180);
    return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * 256;
  }

  static double _latFromWorldY(double y) {
    final n = math.pi - 2 * math.pi * y / 256;
    return 180 / math.pi * math.atan((math.exp(n) - math.exp(-n)) / 2);
  }
}
