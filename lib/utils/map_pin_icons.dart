/// Descriptive map pins. Each says what happens at the spot three ways, so
/// it reads at a glance and on a black-and-white printout:
///
/// * **shape** — a square sign for the worker's drop-off and pick-up, a
///   teardrop for a job location, a small dot for a plain point;
/// * **glyph** — a bin for a junk collection, a sofa for a furniture move,
///   a window for window cleaning;
/// * **tag** — a short word beside the pin: DROP-OFF, COLLECTION, FURNITURE MOVE · LOADING,
///   with the appointment time on a second line for booked call-outs.
///
/// One painter draws every pin, so the on-screen map ([MapPinIcons.bitmap])
/// and the printed map ([MapPinPainter.paint]) show the same thing. Printed
/// pins are drawn [mono]: solid black with a white disc and white tag text,
/// which stays crisp on a black-and-white printer.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart'
    show BitmapDescriptor, LatLng;

import '../models/company.dart';
import '../models/custom_job_type.dart';
import '../models/custom_polygon.dart';

/// Outline of a pin, by the role of the spot.
enum PinShape {
  /// Teardrop: a job location — where the work is done.
  pin,

  /// Square sign on a pointer: where the van drops off or picks up workers.
  sign,

  /// Small dot, no glyph or tag: a plain point.
  dot,
}

/// Which way a pin hangs off its spot, so two close pins can keep their
/// tags apart ([MapPinLayout]). [up] is the normal pin: head above the spot,
/// tag to the right.
enum PinPlacement {
  up,

  /// Head above the spot, tag to the left.
  upLeft,

  /// Hanging upside down: head below the spot, tag to the right.
  down,

  /// Head below the spot, tag to the left.
  downLeft;

  bool get hangsDown => this == down || this == downLeft;
  bool get tagLeft => this == upLeft || this == downLeft;
}

/// How pins stack, back to front (a marker's z-index). The drop-off is often
/// placed on or next to the job's own point — a client's house, a hand-out
/// spot — so it goes behind everything; Junk & Stuff and Happy Sun job pins
/// go in front.
abstract final class PinLayer {
  static const int dropOff = 0;
  static const int point = 1;
  static const int callOut = 2;
}

/// What a pin looks like and what the legend calls it.
@immutable
class MapPinStyle {
  final IconData glyph;
  final Color color;
  final PinShape shape;

  /// Short word printed beside the pin, e.g. "JUNK". Null for none.
  final String? tag;

  /// Legend text, e.g. "Junk Collection" or "Furniture Move – loading".
  final String label;

  /// Appointment time ("09:30") on the line under [tag]. Null for none.
  final String? time;

  /// Which way the pin hangs off its spot.
  final PinPlacement placement;

  const MapPinStyle({
    required this.glyph,
    required this.color,
    required this.label,
    this.shape = PinShape.pin,
    this.tag,
    this.time,
    this.placement = PinPlacement.up,
  });

  /// Identity of the picture (label excluded), for caching bitmaps.
  String get key => '${glyph.codePoint}|${color.toARGB32()}|${shape.name}|'
      '${tag ?? ''}|${time ?? ''}'
      '${placement == PinPlacement.up ? '' : '|${placement.name}'}';

  /// This pin without its appointment time — the legend's picture.
  MapPinStyle get withoutTime => time == null
      ? this
      : MapPinStyle(
          glyph: glyph,
          color: color,
          label: label,
          shape: shape,
          tag: tag,
          placement: placement);

  /// This pin hanging off its spot the [placement] way.
  MapPinStyle withPlacement(PinPlacement placement) =>
      placement == this.placement
          ? this
          : MapPinStyle(
              glyph: glyph,
              color: color,
              label: label,
              shape: shape,
              tag: tag,
              time: time,
              placement: placement);

  /// Where the van drops the worker off.
  static const dropOff = MapPinStyle(
    glyph: Icons.directions_walk,
    color: Color(0xFF1565C0),
    shape: PinShape.sign,
    tag: 'DROP-OFF',
    label: 'Drop-off',
  );

  /// Where the van picks the worker up.
  static const pickUp = MapPinStyle(
    glyph: Icons.directions_walk,
    color: Color(0xFF2E7D32),
    shape: PinShape.sign,
    tag: 'PICK-UP',
    label: 'Pick-up',
  );

  /// The pin for map point [point]. [jobType] is the Junk & Stuff or Happy
  /// Sun job done there, when known: its glyph and word then replace the
  /// generic category ones, and [time] — its appointment — goes under the
  /// word. The worker drop-off is always the drop-off sign.
  static MapPinStyle forPoint(CustomPolygon point,
      {CustomJobType? jobType, String? time}) {
    final category = point.pointCategory;
    if (category == PointCategory.dropoff) return dropOff;

    final (String tagSuffix, String labelSuffix) = switch (category) {
      PointCategory.loading => (' · LOADING', ' – loading'),
      PointCategory.offloading => (' · OFFLOADING', ' – offloading'),
      _ => ('', ''),
    };

    if (jobType != null) {
      final kind = _JobKind.of(jobType);
      return MapPinStyle(
        glyph: kind.glyph,
        color: jobType.colorValue != null
            ? Color(jobType.colorValue!).withValues(alpha: 1)
            : kind.color,
        tag: '${kind.tag ?? _firstWord(jobType.label)}$tagSuffix',
        label: '${jobType.label.trim()}$labelSuffix',
        time: time == null || time.trim().isEmpty ? null : time.trim(),
      );
    }

    return switch (category) {
      PointCategory.pickup => pickUp,
      PointCategory.loading => const MapPinStyle(
          glyph: Icons.inventory_2_rounded,
          color: Color(0xFFEF6C00),
          tag: 'LOAD',
          label: 'Loading',
        ),
      PointCategory.offloading => const MapPinStyle(
          glyph: Icons.inventory_2_rounded,
          color: Color(0xFFC62828),
          tag: 'OFFLOAD',
          label: 'Offloading',
        ),
      PointCategory.cleaning => const MapPinStyle(
          glyph: Icons.cleaning_services_rounded,
          color: Color(0xFF00897B),
          tag: 'CLEANING',
          label: 'Cleaning',
        ),
      _ => _forNamedPoint(point),
    };
  }

  /// A plain point, recognised by its name where it can be (the traffic
  /// lights and hand-out spots on distribution jobs), in its own colour.
  /// Anything else is a dot.
  static MapPinStyle _forNamedPoint(CustomPolygon point) {
    final name = point.name.toLowerCase();
    final color = point.color.withValues(alpha: 1);
    for (final (words, glyph, tag, label) in _namedPoints) {
      if (words.any(name.contains)) {
        return MapPinStyle(glyph: glyph, color: color, tag: tag, label: label);
      }
    }
    return MapPinStyle(
      glyph: Icons.circle,
      color: color,
      shape: PinShape.dot,
      label: 'Point',
    );
  }

  /// A work spot labelled with its own name, in [color]: the glyph comes
  /// from the name where it is recognised (traffic light, hand-out, poster
  /// …), else a plain place pin. A long name wraps onto a second line of at
  /// most [lineChars], and only a name too long for two is cut short. An
  /// unnamed point shows the recognised word, or no tag at all.
  static MapPinStyle named(CustomPolygon point, Color color,
      {int lineChars = 22}) {
    final lower = point.name.toLowerCase();
    var glyph = Icons.place_rounded;
    String? word;
    var label = 'Point';
    for (final (words, g, tag, l) in _namedPoints) {
      if (words.any(lower.contains)) {
        glyph = g;
        word = tag;
        label = l;
        break;
      }
    }
    final name = point.name.trim().replaceAll(RegExp(r'\s+'), ' ');
    return MapPinStyle(
      glyph: glyph,
      color: color.withValues(alpha: 1),
      tag: name.isEmpty ? word : _twoLines(name, lineChars),
      label: name.isEmpty ? label : name,
    );
  }

  /// [name] on one line, or split at the space that best balances two lines
  /// of at most [max] characters; the second is cut short when the rest
  /// does not fit. A single long word is broken at [max].
  static String _twoLines(String name, int max) {
    if (name.length <= max) return name;
    int? cut;
    var widest = name.length;
    for (var i = 0; i < name.length && i <= max; i++) {
      if (name[i] != ' ') continue;
      final rest = name.length - i - 1;
      final w = math.max(i, rest);
      if (w < widest) {
        widest = w;
        cut = i;
      }
    }
    final first = cut == null ? name.substring(0, max) : name.substring(0, cut);
    var second = name.substring(cut == null ? max : cut + 1).trim();
    if (second.length > max) {
      second = '${second.substring(0, max - 1).trimRight()}…';
    }
    return second.isEmpty ? first : '$first\n$second';
  }

  static const _namedPoints = <(List<String>, IconData, String, String)>[
    (['traffic', 'robot'], Icons.traffic_rounded, 'ROBOT', 'Traffic light'),
    (
      ['poster', 'banner', 'billboard'],
      Icons.campaign_rounded,
      'POSTER',
      'Poster',
    ),
    (
      ['hand out', 'handout', 'hand-out'],
      Icons.front_hand_rounded,
      'HAND-OUT',
      'Hand-out',
    ),
    (['taxi'], Icons.local_taxi_rounded, 'TAXI', 'Taxi rank'),
    (['station'], Icons.train_rounded, 'STATION', 'Station'),
    (['school', 'college'], Icons.school_rounded, 'SCHOOL', 'School'),
    (
      ['mall', 'shop', 'centre', 'center', 'market'],
      Icons.storefront_rounded,
      'SHOPS',
      'Shops',
    ),
  ];

  static String _firstWord(String label) {
    final word = label.trim().split(RegExp(r'\s+')).first.toUpperCase();
    return word.length > 10 ? word.substring(0, 10) : word;
  }

  @override
  bool operator ==(Object other) =>
      other is MapPinStyle && other.key == key && other.label == label;

  @override
  int get hashCode => Object.hash(key, label);
}

/// The glyph, default colour and tag word for a kind of job, picked from
/// the job type's id, then words in its name — so a type added in Settings
/// later ("Gutter Cleaning", "Garden Refuse") still gets a fitting picture —
/// then its company.
class _JobKind {
  final IconData glyph;
  final Color color;

  /// Null → the job type's first word.
  final String? tag;
  const _JobKind(this.glyph, this.color, [this.tag]);

  static const _junk =
      _JobKind(Icons.delete_rounded, Color(0xFF5D4037), 'COLLECTION');
  static const _furniture =
      _JobKind(Icons.weekend_rounded, Color(0xFFE65100), 'FURNITURE MOVE');
  static const _trailer =
      _JobKind(Icons.rv_hookup_rounded, Color(0xFF283593), 'TRAILER TOWING');
  static const _window =
      _JobKind(Icons.window_rounded, Color(0xFF0277BD), 'WINDOWS CLEANING');
  static const _solar =
      _JobKind(Icons.solar_power_rounded, Color(0xFFF57F17), 'SOLAR CLEANING');
  static const _gutter =
      _JobKind(Icons.roofing_rounded, Color(0xFF455A64), 'GUTTERS CLEANING');
  static const _garden =
      _JobKind(Icons.grass_rounded, Color(0xFF2E7D32), 'GARDEN');
  static const _pool = _JobKind(Icons.pool_rounded, Color(0xFF00838F), 'POOL');
  static const _wash =
      _JobKind(Icons.water_drop_rounded, Color(0xFF0097A7), 'WASH');
  static const _upholstery =
      _JobKind(Icons.chair_rounded, Color(0xFF6A1B9A), 'CARPETS');
  static const _paint =
      _JobKind(Icons.format_paint_rounded, Color(0xFFAD1457), 'PAINT');
  static const _delivery =
      _JobKind(Icons.local_shipping_rounded, Color(0xFF4E342E));
  static const _clean =
      _JobKind(Icons.cleaning_services_rounded, Color(0xFF00897B), 'CLEAN');
  static const _repair =
      _JobKind(Icons.handyman_rounded, Color(0xFF37474F), 'REPAIR');
  static const _happySun = _JobKind(Icons.wb_sunny_rounded, Color(0xFFF57F17));
  static const _other = _JobKind(Icons.work_rounded, Color(0xFF37474F));

  static const _byId = {
    'junkCollection': _junk,
    'furnitureMove': _furniture,
    'trailerTowing': _trailer,
    'windowCleaning': _window,
    'solarPanelCleaning': _solar,
  };

  /// First match wins, so the more specific words come first ("solar panel
  /// cleaning" is solar, not cleaning).
  static const _byWord = <(List<String>, _JobKind)>[
    (['solar'], _solar),
    (['window'], _window),
    (['gutter', 'roof'], _gutter),
    (['pool'], _pool),
    (['carpet', 'upholster', 'couch', 'mattress'], _upholstery),
    (['pressure', 'wash', 'paving', 'driveway'], _wash),
    (['junk', 'rubbish', 'waste', 'rubble', 'refuse', 'dump', 'clear'], _junk),
    (['furniture', 'move', 'removal', 'relocat'], _furniture),
    (['trailer', 'tow'], _trailer),
    (['garden', 'lawn', 'grass', 'tree', 'hedge'], _garden),
    (['paint'], _paint),
    (['deliver', 'courier', 'transport'], _delivery),
    (['repair', 'handyman', 'fix', 'install'], _repair),
    (['clean'], _clean),
  ];

  static _JobKind of(CustomJobType type) {
    final byId = _byId[type.id];
    if (byId != null) return byId;
    final name = type.label.toLowerCase();
    for (final (words, kind) in _byWord) {
      if (words.any(name.contains)) return kind;
    }
    return switch (type.resolvedCompanyId) {
      Company.junkAndStuffId => _delivery,
      Company.happySunId => _happySun,
      _ => _other,
    };
  }
}

/// Draws a [MapPinStyle] pin onto any canvas, tip on the spot.
class MapPinPainter {
  MapPinPainter._();

  // Sizes at scale 1.
  static const double _headRadius = 16;
  static const double _stem = 29; // tip to head centre
  static const double _signHalf = 15;
  static const double _dotRadius = 6.5;
  static const double _tagHeight = 19;
  static const double _tagFont = 10.5;
  // Each further line of a tag that wraps (a long name).
  static const double _tagLine = 12.5;
  // The appointment time's line under the tag word.
  static const double _timeFont = 10;
  static const double _timeLine = 12;
  static const double _margin = 3;

  /// The box [style] needs around its tip at (0, 0), at [scale].
  static Rect bounds(MapPinStyle style, {double scale = 1}) {
    final m = _margin * scale;
    if (style.shape == PinShape.dot) {
      final r = (_dotRadius + 1.5) * scale + m;
      return Rect.fromCircle(center: Offset.zero, radius: r);
    }
    final half = _halfHead(style) * scale;
    final head = _head(Offset.zero, style, scale);
    var box = Rect.fromCircle(center: head, radius: half)
        // The tip, with room for the ground shadow under it.
        .expandToInclude(Rect.fromLTRB(-half, 0, half, 4 * scale));
    final tag = _tagRect(style, head, scale);
    if (tag != null) box = box.expandToInclude(tag);
    return box.inflate(m);
  }

  /// Where the head of [style] sits for a tip at [tip].
  static Offset _head(Offset tip, MapPinStyle style, double scale) =>
      tip +
      Offset(0, (style.placement.hangsDown ? _stem : -_stem) * scale);

  static double _halfHead(MapPinStyle style) =>
      style.shape == PinShape.sign ? _signHalf : _headRadius;

  /// Paints [style] with its tip at [tip]. [scale] multiplies every size.
  static void paint(
    Canvas canvas,
    Offset tip,
    MapPinStyle style, {
    double scale = 1,
    bool mono = false,
  }) {
    final base = style.color.withValues(alpha: 1);
    final body = mono ? Colors.black : base;
    final rim = Colors.white;

    if (style.shape == PinShape.dot) {
      final r = _dotRadius * scale;
      if (!mono) _shadow(canvas, Path()..addOval(_circle(tip, r)), scale);
      canvas.drawCircle(tip, r, Paint()..color = body);
      canvas.drawCircle(tip, r, _stroke(rim, 2 * scale));
      return;
    }

    final down = style.placement.hangsDown;
    final head = _head(tip, style, scale);
    // Drawn as an upright pin, then turned over about the tip when it hangs
    // down; the tag and glyph are drawn upright either way.
    final upright = tip - Offset(0, _stem * scale);
    var outline = style.shape == PinShape.sign
        ? _signOutline(tip, upright, _signHalf * scale)
        : _teardrop(tip, upright, _headRadius * scale);
    if (down) {
      outline = outline.transform(Float64List.fromList([
        1, 0, 0, 0, //
        0, -1, 0, 0,
        0, 0, 1, 0,
        0, 2 * tip.dy, 0, 1,
      ]));
    }

    // Ground shadow first, then the tag tucked behind the head.
    if (!mono) {
      canvas.drawOval(
        Rect.fromCenter(
            center: tip + Offset(0, 1 * scale),
            width: 12 * scale,
            height: 4 * scale),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.3)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.5 * scale),
      );
    }
    final tag = _tagRect(style, head, scale);
    if (tag != null) {
      final rr = RRect.fromRectAndRadius(
          tag, Radius.circular(_tagHeight * scale / 2));
      if (!mono) _shadow(canvas, Path()..addRRect(rr), scale);
      canvas.drawRRect(rr, Paint()..color = mono ? Colors.black : _deep(base));
      canvas.drawRRect(rr, _stroke(rim, 1.6 * scale));
      // The text sits in the part of the tag the head does not cover.
      final right = style.placement.tagLeft
          ? tag.right - (_halfHead(style) * 0.6 + 5) * scale
          : tag.right - _tagPadRight(scale);
      final firstLine = tag.top + _tagHeight * scale / 2;
      final lines = style.tag!.split('\n');
      // A wrapped tag reads left-aligned; one line ends at [right] as ever.
      final textLeft =
          right - lines.map((l) => _textWidth(l, scale)).reduce(math.max);
      for (var i = 0; i < lines.length; i++) {
        final y = firstLine + i * _tagLine * scale;
        final end = lines.length == 1
            ? right
            : textLeft + _textWidth(lines[i], scale);
        _text(canvas, lines[i], Offset(end, y), scale);
      }
      if (style.time != null) {
        _text(
          canvas,
          style.time!,
          Offset(right,
              firstLine + ((lines.length - 1) * _tagLine + _timeLine) * scale),
          scale,
          fontSize: _timeFont,
        );
      }
    }

    if (!mono) _shadow(canvas, outline, scale);
    canvas.drawPath(
      outline,
      Paint()
        ..shader = mono
            ? null
            : ui.Gradient.linear(
                head + Offset(0, (down ? 1 : -1) * _headRadius * scale),
                tip,
                [_light(base), _deep(base)],
              )
        ..color = body,
    );
    canvas.drawPath(outline, _stroke(rim, 2 * scale));

    // White face with the glyph in the pin's colour.
    if (style.shape == PinShape.sign) {
      final face = _signHalf * scale - 3.5 * scale;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: head, width: face * 2, height: face * 2),
          Radius.circular(5 * scale),
        ),
        Paint()..color = Colors.white,
      );
    } else {
      canvas.drawCircle(
          head, (_headRadius - 3.5) * scale, Paint()..color = Colors.white);
    }
    _glyph(canvas, style.glyph, head, 18 * scale, mono ? Colors.black : base);
  }

  // ── Shapes ────────────────────────────────────────────────────────

  /// A circle of radius [r] round [head] narrowing to [tip], as one outline
  /// so the stroke has no seam.
  static Path _teardrop(Offset tip, Offset head, double r) {
    final d = (tip - head).distance;
    final a = math.acos(r / d);
    const down = math.pi / 2;
    final start = down + a;
    return Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(head.dx + r * math.cos(start), head.dy + r * math.sin(start))
      ..arcTo(_circle(head, r), start, 2 * math.pi - 2 * a, false)
      ..close();
  }

  /// A rounded square on [head] with a pointer down to [tip], like a road
  /// sign on its post.
  static Path _signOutline(Offset tip, Offset head, double half) {
    final corner = half * 0.42;
    final box =
        Rect.fromCenter(center: head, width: half * 2, height: half * 2);
    final pointer = half * 0.45;
    return Path()
      ..moveTo(box.left + corner, box.top)
      ..lineTo(box.right - corner, box.top)
      ..arcToPoint(Offset(box.right, box.top + corner),
          radius: Radius.circular(corner))
      ..lineTo(box.right, box.bottom - corner)
      ..arcToPoint(Offset(box.right - corner, box.bottom),
          radius: Radius.circular(corner))
      ..lineTo(head.dx + pointer, box.bottom)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(head.dx - pointer, box.bottom)
      ..lineTo(box.left + corner, box.bottom)
      ..arcToPoint(Offset(box.left, box.bottom - corner),
          radius: Radius.circular(corner))
      ..lineTo(box.left, box.top + corner)
      ..arcToPoint(Offset(box.left + corner, box.top),
          radius: Radius.circular(corner))
      ..close();
  }

  /// The tag's box: starts under the head's right half, so the head sits
  /// on its left end, and runs right to fit the word — or the mirror of
  /// that for a tag on the left. A wrapped name and a time add lines below,
  /// so the box grows downwards.
  static Rect? _tagRect(MapPinStyle style, Offset head, double scale) {
    final text = style.tag;
    if (text == null || text.isEmpty || style.shape == PinShape.dot) {
      return null;
    }
    final lines = text.split('\n');
    var width = lines.map((l) => _textWidth(l, scale)).reduce(math.max);
    final time = style.time;
    if (time != null) {
      width = math.max(width, _textWidth(time, scale, fontSize: _timeFont));
    }
    final w =
        (_halfHead(style) * 0.6 + 5) * scale + width + _tagPadRight(scale);
    final inset = _halfHead(style) * scale * 0.4;
    return Rect.fromLTWH(
      style.placement.tagLeft ? head.dx - inset - w : head.dx + inset,
      head.dy - _tagHeight * scale / 2,
      w,
      (_tagHeight +
              (lines.length - 1) * _tagLine +
              (time != null ? _timeLine : 0)) *
          scale,
    );
  }

  static double _textWidth(String text, double scale,
      {double fontSize = _tagFont}) {
    final painter = _textPainter(text, scale, fontSize: fontSize);
    final width = painter.width;
    painter.dispose();
    return width;
  }

  static double _tagPadRight(double scale) => 7 * scale;

  // ── Paint helpers ─────────────────────────────────────────────────

  static Rect _circle(Offset c, double r) =>
      Rect.fromCircle(center: c, radius: r);

  static Paint _stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = width
    ..color = color;

  static void _shadow(Canvas canvas, Path path, double scale) {
    canvas.drawPath(
      path.shift(Offset(0, 1.2 * scale)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.8 * scale),
    );
  }

  static Color _light(Color c) => Color.lerp(c, Colors.white, 0.12)!;
  static Color _deep(Color c) => Color.lerp(c, Colors.black, 0.18)!;

  static TextPainter _textPainter(String text, double scale,
          {double fontSize = _tagFont}) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            // Roboto where it is available (web, Android), else the
            // platform's own sans-serif.
            fontFamily: 'Roboto',
            fontSize: fontSize * scale,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6 * scale,
            color: Colors.white,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

  /// Draws [text] ending at [rightCenter].
  static void _text(
      Canvas canvas, String text, Offset rightCenter, double scale,
      {double fontSize = _tagFont}) {
    final painter = _textPainter(text, scale, fontSize: fontSize);
    painter.paint(
      canvas,
      rightCenter - Offset(painter.width, painter.height / 2),
    );
    painter.dispose();
  }

  static void _glyph(
      Canvas canvas, IconData icon, Offset center, double size, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
        canvas, center - Offset(painter.width / 2, painter.height / 2));
    painter.dispose();
  }
}

/// Keeps pins' tags from covering each other. Close pins are turned to hang
/// another way ([PinPlacement]): the tag to the left, or the pin upside
/// down below its spot.
class MapPinLayout {
  MapPinLayout._();

  /// Boxes by picture, at scale 1 around a tip at (0, 0): measuring a tag
  /// lays out its text, and a layout asks for every placement of every pin.
  static final Map<String, Rect> _bounds = {};

  static Rect _boundsOf(MapPinStyle style) =>
      _bounds[style.key] ??= MapPinPainter.bounds(style);

  /// The placement for each pin of [pins] (id, spot, upright style) on a
  /// map at [zoom]. Pins are placed one by one, north first; each takes the
  /// first placement whose box clears the pins placed before it and every
  /// spot, else the one that overlaps least. Dots have no tag and stay put.
  static Map<String, PinPlacement> arrange(
      List<(String id, LatLng position, MapPinStyle style)> pins,
      double zoom) {
    // Web Mercator, in the map's logical pixels.
    final world = 256 * math.pow(2, zoom).toDouble();
    Offset project(LatLng p) {
      final s = math.sin(p.latitude.clamp(-85.0, 85.0) * math.pi / 180);
      return Offset(
        (p.longitude + 180) / 360 * world,
        (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * world,
      );
    }

    final order = [...pins]..sort((a, b) {
        final byLat = b.$2.latitude.compareTo(a.$2.latitude);
        return byLat != 0 ? byLat : a.$1.compareTo(b.$1);
      });
    final spots = {for (final p in order) p.$1: project(p.$2)};
    final placed = <Rect>[];
    final out = <String, PinPlacement>{};

    double overlap(Rect box, String self) {
      var total = 0.0;
      for (final r in placed) {
        final i = box.intersect(r);
        if (i.width > 0 && i.height > 0) total += i.width * i.height;
      }
      // Covering another pin's spot hides where it is: count it heavily.
      for (final e in spots.entries) {
        if (e.key != self && box.deflate(2).contains(e.value)) total += 400;
      }
      return total;
    }

    for (final (id, _, style) in order) {
      final at = spots[id]!;
      if (style.shape == PinShape.dot) {
        out[id] = PinPlacement.up;
        placed.add(_boundsOf(style).shift(at));
        continue;
      }
      PinPlacement? best;
      Rect? bestBox;
      var bestCost = double.infinity;
      for (final placement in PinPlacement.values) {
        final box = _boundsOf(style.withPlacement(placement)).shift(at);
        final cost = overlap(box, id);
        if (cost < bestCost) {
          best = placement;
          bestBox = box;
          bestCost = cost;
          if (cost == 0) break;
        }
      }
      out[id] = best!;
      placed.add(bestBox!);
    }
    return out;
  }
}

/// A rasterised pin: the PNG, its size in logical pixels, and where the tip
/// sits as a fraction of that size (the marker anchor).
class MapPinImage {
  final Uint8List png;
  final Size size;
  final Offset anchor;
  const MapPinImage(this.png, this.size, this.anchor);
}

/// Pins as images: [bitmap] for Google Maps markers, [png] for the PDF
/// legend. Each is rasterised once per session.
class MapPinIcons {
  MapPinIcons._();

  static const double _pixelRatio = 3;
  static final Map<String, (BitmapDescriptor, Offset)> _bitmaps = {};
  static final Map<String, MapPinImage> _images = {};

  /// The cached marker bitmap and anchor for [style], once [bitmap] has
  /// made it.
  static (BitmapDescriptor, Offset)? cached(MapPinStyle style) =>
      _bitmaps[style.key];

  static Future<(BitmapDescriptor, Offset)> bitmap(MapPinStyle style) async {
    final hit = _bitmaps[style.key];
    if (hit != null) return hit;
    final image = await render(style);
    return _bitmaps[style.key] = (
      BitmapDescriptor.bytes(
        image.png,
        width: image.size.width,
        height: image.size.height,
      ),
      image.anchor,
    );
  }

  static Future<Uint8List> png(MapPinStyle style, {bool mono = false}) async =>
      (await render(style, mono: mono)).png;

  static Future<MapPinImage> render(MapPinStyle style,
      {bool mono = false}) async {
    final cacheKey = '${style.key}|$mono';
    final hit = _images[cacheKey];
    if (hit != null) return hit;

    final box = MapPinPainter.bounds(style);
    final w = (box.width * _pixelRatio).ceilToDouble();
    final h = (box.height * _pixelRatio).ceilToDouble();
    final tip = -box.topLeft * _pixelRatio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
    MapPinPainter.paint(canvas, tip, style, scale: _pixelRatio, mono: mono);
    final image = await recorder.endRecording().toImage(w.round(), h.round());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('Map pin could not be drawn.');
    return _images[cacheKey] = MapPinImage(
      data.buffer.asUint8List(),
      Size(w / _pixelRatio, h / _pixelRatio),
      Offset(tip.dx / w, tip.dy / h),
    );
  }
}
