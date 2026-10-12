// track_editor/widgets/te_analysis_chart.dart
//
// The time chart at the top of the Analysis view: distributor speed against
// one shared time axis running from the start of the shift to the end, with
// the stationary stretches shaded behind it and an activity strip underneath.
// A second line rides the right-hand axis — either cumulative handouts or
// cumulative distance walked, never both, so the chart never grows a third
// axis (see [TESecondarySeries]).
//
// Reading the chart, with handouts as the second line: speed on the floor
// with the handout line climbing means the distributor is parked at an
// intersection working the traffic. Speed on the floor with the handout line
// flat means they are standing around. Speed up with the handout line flat
// means they are walking between spots. With distance as the second line
// instead: it climbs whenever speed is above the floor and flattens whenever
// speed is on it — the same story, read off ground covered rather than
// flyers handed out.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../providers/te_view_provider.dart';
import '../utils/te_track_analysis.dart';

/// Chart palette. Validated for colour-vision deficiency against the light
/// chart surface (`scripts/validate_palette.js`, all-pairs): blue/orange/violet
/// clear both the CVD and normal-vision separation floors.
abstract class TEChartColors {
  static const surface = Color(0xFFFCFCFB);
  static const grid = Color(0xFFE1E0D9);
  static const axis = Color(0xFFC3C2B7);
  static const muted = Color(0xFF898781);
  static const secondaryInk = Color(0xFF52514E);
  static const primaryInk = Color(0xFF0B0B0B);

  /// Series 1 — speed.
  static const speed = Color(0xFF2A78D6);

  /// Series 2 — handouts. Also the "working a stop" state.
  static const handouts = Color(0xFFEB6834);

  /// Stationary but not handing out — idle time and breaks.
  static const idle = Color(0xFF4A3AA7);

  /// No tracklog at all.
  static const gap = Color(0xFF898781);

  static Color forStop(TEStopKind kind) => switch (kind) {
        TEStopKind.handout => handouts,
        TEStopKind.idle => idle,
        TEStopKind.breakTime => idle,
      };
}

final _hm = DateFormat('HH:mm');
final _hms = DateFormat('HH:mm:ss');

/// Speed + a second series (handouts or distance) chart over the shift's
/// time axis.
class TEAnalysisChart extends StatefulWidget {
  final TETrackAnalysis analysis;

  /// True: both series share one plot with two y-axes (as requested).
  /// False: two stacked plots share the time axis — the same comparison, but
  /// neither scale can distort the other.
  final bool overlay;

  /// What the right-hand line tracks: cumulative handouts or cumulative
  /// distance walked. Never both — the chart stays at two axes.
  final TESecondarySeries secondary;

  /// The slice of the shift the time axis covers. Defaults to the whole of
  /// it; narrowing the window is what "zooming in on an hour" means here.
  final DateTime viewStart;
  final DateTime viewEnd;

  /// Called when the user drags the plot sideways, with how far to move the
  /// window in milliseconds (positive = later). Null disables panning.
  final void Function(int deltaMs)? onPan;

  const TEAnalysisChart({
    super.key,
    required this.analysis,
    required this.overlay,
    required this.secondary,
    required this.viewStart,
    required this.viewEnd,
    this.onPan,
  });

  @override
  State<TEAnalysisChart> createState() => _TEAnalysisChartState();
}

class _TEAnalysisChartState extends State<TEAnalysisChart> {
  /// Hover position in chart-local coordinates. Kept in a notifier so moving
  /// the mouse repaints only the thin crosshair layer, never the series paths.
  final ValueNotifier<Offset?> _cursor = ValueNotifier(null);

  @override
  void dispose() {
    _cursor.dispose();
    super.dispose();
  }

  /// Width of the plotting area, needed to turn a drag in pixels into a shift
  /// in time. Vertical drags are left alone so the page can still scroll.
  double _plotWidth() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return 0;
    final w = box.size.width -
        _Layout.leftAxisW -
        (widget.overlay ? _Layout.rightAxisW : 12);
    return w > 1 ? w : 0;
  }

  void _onDrag(DragUpdateDetails d) {
    final onPan = widget.onPan;
    if (onPan == null) return;
    final w = _plotWidth();
    if (w == 0) return;
    final spanMs = widget.viewEnd.difference(widget.viewStart).inMilliseconds;
    // Drag right = look at earlier time, like dragging a strip of film.
    onPan(-(d.delta.dx / w * spanMs).round());
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    final zoomed = widget.onPan != null &&
        widget.viewEnd.difference(widget.viewStart) < a.elapsed;
    return MouseRegion(
      cursor: zoomed ? SystemMouseCursors.grab : MouseCursor.defer,
      onHover: (e) => _cursor.value = e.localPosition,
      onExit: (_) => _cursor.value = null,
      child: GestureDetector(
        onHorizontalDragUpdate: widget.onPan == null ? null : _onDrag,
        child: CustomPaint(
          painter: _ChartPainter(
            analysis: a,
            overlay: widget.overlay,
            secondary: widget.secondary,
            viewStart: widget.viewStart,
            viewEnd: widget.viewEnd,
          ),
          foregroundPainter: _CursorPainter(
            analysis: a,
            overlay: widget.overlay,
            secondary: widget.secondary,
            viewStart: widget.viewStart,
            viewEnd: widget.viewEnd,
            cursor: _cursor,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// LAYOUT
// ════════════════════════════════════════════════════════════════════════════

/// Where each band of the chart lives, and how to map a time onto x. Both
/// painters derive this from the same size so the crosshair lines up exactly
/// with the series underneath it.
class _Layout {
  final Rect speedPlot;
  final Rect rightPlot; // identical to speedPlot when overlaid
  final Rect strip;
  final Rect xAxis;

  /// Left edge of the time axis. Not necessarily the start of the shift —
  /// this is the visible window.
  final DateTime viewStart;
  final int spanMs;
  final double speedMax;

  /// Axis ceiling for the right-hand line — handout count or distance in km,
  /// whichever [secondary] selects.
  final double rightMax;
  final bool overlay;
  final TESecondarySeries secondary;

  const _Layout({
    required this.speedPlot,
    required this.rightPlot,
    required this.strip,
    required this.xAxis,
    required this.viewStart,
    required this.spanMs,
    required this.speedMax,
    required this.rightMax,
    required this.overlay,
    required this.secondary,
  });

  /// Time -> x. Deliberately unclamped: when the window is zoomed in, data
  /// outside it must fall off the plot and be clipped, not pile up against
  /// the axis as a false vertical wall.
  double xOf(DateTime t) {
    final f = t.difference(viewStart).inMilliseconds / spanMs;
    return speedPlot.left + f * speedPlot.width;
  }

  DateTime timeAt(double x) {
    final f = ((x - speedPlot.left) / speedPlot.width).clamp(0.0, 1.0);
    return viewStart.add(Duration(milliseconds: (f * spanMs).round()));
  }

  double ySpeed(double kmh) =>
      speedPlot.bottom - (kmh / speedMax).clamp(0.0, 1.0) * speedPlot.height;

  double yRight(double v) =>
      rightPlot.bottom - (v / rightMax).clamp(0.0, 1.0) * rightPlot.height;

  /// Full vertical extent covered by the plots and the strip — the crosshair
  /// and the shaded stop bands run the whole way down.
  double get bandTop => speedPlot.top;
  double get bandBottom => strip.bottom;

  /// The full plotted area — everything drawn against the time axis is
  /// clipped to this so a zoomed-in window never bleeds over the axes.
  Rect get band =>
      Rect.fromLTRB(speedPlot.left, bandTop, speedPlot.right, bandBottom);

  static const double leftAxisW = 46;
  static const double rightAxisW = 46;
  static const double topPad = 12;
  static const double stripH = 20;
  static const double stripGap = 8;
  static const double xAxisH = 20;
  static const double panelGap = 22;

  factory _Layout.of(
    Size size,
    TETrackAnalysis a,
    bool overlay,
    TESecondarySeries secondary,
    DateTime viewStart,
    DateTime viewEnd,
  ) {
    final left = leftAxisW;
    final right = size.width - (overlay ? rightAxisW : 12);
    final plotsTop = topPad;
    final stripTop = size.height - xAxisH - stripH;
    final plotsBottom = stripTop - stripGap;

    final Rect speedPlot;
    final Rect rightPlot;
    if (overlay) {
      final r = Rect.fromLTRB(left, plotsTop, right, plotsBottom);
      speedPlot = r;
      rightPlot = r;
    } else {
      final h = (plotsBottom - plotsTop - panelGap) / 2;
      speedPlot = Rect.fromLTRB(left, plotsTop, right, plotsTop + h);
      rightPlot =
          Rect.fromLTRB(left, plotsTop + h + panelGap, right, plotsBottom);
    }

    final span = viewEnd.difference(viewStart).inMilliseconds;
    final rightMax = switch (secondary) {
      TESecondarySeries.handouts =>
        math.max(_niceCeil(a.handoutTimes.length.toDouble()), 1.0),
      TESecondarySeries.distance =>
        _niceCeil(math.max(a.distanceKm, 0.1)),
    };
    return _Layout(
      speedPlot: speedPlot,
      rightPlot: rightPlot,
      strip: Rect.fromLTRB(left, stripTop, right, stripTop + stripH),
      xAxis: Rect.fromLTRB(left, stripTop + stripH, right, size.height),
      viewStart: viewStart,
      spanMs: span <= 0 ? 1 : span,
      speedMax: _niceCeil(math.max(a.maxSpeedKmh, 1)),
      rightMax: rightMax,
      overlay: overlay,
      secondary: secondary,
    );
  }
}

/// The right-hand line's value at [t] — a running handout count or the
/// distance walked so far, whichever [secondary] selects. Shared by the
/// chart painter (to place the end-of-line figure) and the cursor painter
/// (to place the crosshair dot and its tooltip row), so the two can never
/// disagree about what is on screen.
double teRightValueAt(TETrackAnalysis a, TESecondarySeries secondary, DateTime t) {
  return switch (secondary) {
    TESecondarySeries.handouts => a.cumulativeAt(t).toDouble(),
    TESecondarySeries.distance => a.sampleAt(t)?.cumulativeKm ?? 0,
  };
}

/// Round up to a readable axis maximum (1, 2, 2.5, 5, 10 × a power of ten).
double _niceCeil(double v) {
  if (v <= 0) return 1;
  final mag = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  final n = v / mag;
  final step =
      n <= 1 ? 1.0 : (n <= 2 ? 2.0 : (n <= 2.5 ? 2.5 : (n <= 5 ? 5.0 : 10.0)));
  return step * mag;
}

/// Tick spacing that lands on wall-clock boundaries and gives ~5–9 ticks.
Duration _tickStep(int spanMs) {
  const candidates = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 2),
    Duration(hours: 3),
    Duration(hours: 6),
  ];
  for (final c in candidates) {
    if (spanMs / c.inMilliseconds <= 8) return c;
  }
  return candidates.last;
}

// ════════════════════════════════════════════════════════════════════════════
// BASE PAINTER — grid, stop bands, series, strip
// ════════════════════════════════════════════════════════════════════════════

class _ChartPainter extends CustomPainter {
  final TETrackAnalysis analysis;
  final bool overlay;
  final TESecondarySeries secondary;
  final DateTime viewStart;
  final DateTime viewEnd;

  _ChartPainter({
    required this.analysis,
    required this.overlay,
    required this.secondary,
    required this.viewStart,
    required this.viewEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 120 || size.height < 120) return;
    final a = analysis;
    final l = _Layout.of(size, a, overlay, secondary, viewStart, viewEnd);

    canvas.drawRect(Offset.zero & size, Paint()..color = TEChartColors.surface);

    _paintStopBands(canvas, l);
    _paintGridAndAxes(canvas, l);
    _paintSpeed(canvas, l);
    _paintRightSeries(canvas, l);
    _paintStrip(canvas, l);
    _paintPanelTitles(canvas, l);
  }

  // ── Shaded stationary stretches behind everything ───────────────────────
  void _paintStopBands(Canvas canvas, _Layout l) {
    canvas.save();
    canvas.clipRect(l.band);
    for (final s in analysis.stops) {
      final x1 = l.xOf(s.start);
      final x2 = l.xOf(s.end);
      if (x2 < l.band.left || x1 > l.band.right) continue;
      if (x2 - x1 < 0.5) continue;
      // A band can start or end outside the window; clipping above trims it.
      final rect = Rect.fromLTRB(x1, l.bandTop, x2, l.bandBottom);
      canvas.drawRect(
        rect,
        Paint()..color = TEChartColors.forStop(s.kind).withValues(alpha: 0.10),
      );
      // Breaks get a hatch on top of the same violet as idle time, so the two
      // are told apart by texture rather than by a fifth hue.
      if (s.kind == TEStopKind.breakTime) {
        _hatch(canvas, rect, TEChartColors.idle.withValues(alpha: 0.16),
            spacing: 12);
      }
    }
    for (final g in analysis.gaps) {
      final rect =
          Rect.fromLTRB(l.xOf(g.start), l.bandTop, l.xOf(g.end), l.bandBottom);
      if (rect.width < 0.5) continue;
      canvas.drawRect(
          rect, Paint()..color = TEChartColors.gap.withValues(alpha: 0.12));
      _hatch(canvas, rect, TEChartColors.gap.withValues(alpha: 0.35),
          spacing: 12);
    }
    canvas.restore();
  }

  void _hatch(Canvas canvas, Rect rect, Color color, {double spacing = 7}) {
    canvas.save();
    canvas.clipRect(rect);
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = rect.left - rect.height; x < rect.right; x += spacing) {
      canvas.drawLine(
          Offset(x, rect.bottom), Offset(x + rect.height, rect.top), p);
    }
    canvas.restore();
  }

  // ── Grid, y-axes, x-axis ────────────────────────────────────────────────
  void _paintGridAndAxes(Canvas canvas, _Layout l) {
    final grid = Paint()
      ..color = TEChartColors.grid
      ..strokeWidth = 1;
    final axis = Paint()
      ..color = TEChartColors.axis
      ..strokeWidth = 1;

    // Horizontal gridlines + left axis labels (speed).
    const rows = 4;
    for (var i = 0; i <= rows; i++) {
      final y = l.speedPlot.bottom - l.speedPlot.height * i / rows;
      canvas.drawLine(
          Offset(l.speedPlot.left, y), Offset(l.speedPlot.right, y), grid);
      final v = l.speedMax * i / rows;
      _text(canvas, _trimNum(v), Offset(l.speedPlot.left - 6, y),
          align: _Align.rightCentre, color: TEChartColors.muted, size: 10);
    }

    // Right-hand axis: right side when overlaid, its own panel when split.
    // Handouts are whole numbers; distance keeps a decimal.
    for (var i = 0; i <= rows; i++) {
      final y = l.rightPlot.bottom - l.rightPlot.height * i / rows;
      if (!l.overlay) {
        canvas.drawLine(Offset(l.rightPlot.left, y),
            Offset(l.rightPlot.right, y), grid);
      }
      final raw = l.rightMax * i / rows;
      final v = l.secondary == TESecondarySeries.handouts
          ? raw.round().toString()
          : _trimNum(raw);
      if (l.overlay) {
        _text(canvas, v, Offset(l.rightPlot.right + 6, y),
            align: _Align.leftCentre, color: TEChartColors.muted, size: 10);
      } else {
        _text(canvas, v, Offset(l.rightPlot.left - 6, y),
            align: _Align.rightCentre, color: TEChartColors.muted, size: 10);
      }
    }

    // Baselines.
    canvas.drawLine(Offset(l.speedPlot.left, l.speedPlot.bottom),
        Offset(l.speedPlot.right, l.speedPlot.bottom), axis);
    if (!l.overlay) {
      canvas.drawLine(Offset(l.rightPlot.left, l.rightPlot.bottom),
          Offset(l.rightPlot.right, l.rightPlot.bottom), axis);
    }

    // Time ticks.
    final step = _tickStep(l.spanMs);
    var t = _ceilTo(viewStart, step);
    while (!t.isAfter(viewEnd)) {
      final x = l.xOf(t);
      canvas.drawLine(
          Offset(x, l.speedPlot.top), Offset(x, l.speedPlot.bottom), grid);
      if (!l.overlay) {
        canvas.drawLine(Offset(x, l.rightPlot.top),
            Offset(x, l.rightPlot.bottom), grid);
      }
      canvas.drawLine(
          Offset(x, l.strip.bottom), Offset(x, l.strip.bottom + 3), axis);
      final label = step.inMinutes < 1 ? _hms.format(t) : _hm.format(t);
      _text(canvas, label, Offset(x, l.xAxis.top + 5),
          align: _Align.topCentre, color: TEChartColors.muted, size: 10);
      t = t.add(step);
    }
  }

  // ── Speed: 2px line over a faint fill ───────────────────────────────────
  void _paintSpeed(Canvas canvas, _Layout l) {
    final s = analysis.samples;
    if (s.length < 2) return;
    final line = Path();
    final fill = Path()..moveTo(l.xOf(s.first.time), l.speedPlot.bottom);
    // Break the path across genuine gaps rather than drawing a fake ramp
    // through ground we never saw covered. Standing time is NOT a break in
    // the line: on a motion-triggered logger the silence is the stop, and the
    // speed across it really was zero — drawing it flat on the floor is the
    // whole point.
    var penDown = false;
    for (var i = 0; i < s.length; i++) {
      final x = l.xOf(s[i].time);
      final y = l.ySpeed(s[i].speedKmh);
      final brokeHere = i > 0 && analysis.spansGap(s[i - 1].time, s[i].time);
      if (!penDown || brokeHere) {
        if (brokeHere) {
          fill.lineTo(l.xOf(s[i - 1].time), l.speedPlot.bottom);
          fill.moveTo(x, l.speedPlot.bottom);
        }
        line.moveTo(x, y);
        fill.lineTo(x, y);
        penDown = true;
      } else {
        line.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo(l.xOf(s.last.time), l.speedPlot.bottom);
    fill.close();
    canvas.save();
    canvas.clipRect(l.speedPlot);
    canvas.drawPath(
        fill, Paint()..color = TEChartColors.speed.withValues(alpha: 0.12));
    canvas.drawPath(
      line,
      Paint()
        ..color = TEChartColors.speed
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  // ── Right-hand series: cumulative handouts (step) or distance (line) ────
  void _paintRightSeries(Canvas canvas, _Layout l) {
    switch (secondary) {
      case TESecondarySeries.handouts:
        _paintHandoutsStep(canvas, l);
      case TESecondarySeries.distance:
        _paintDistanceLine(canvas, l);
    }
  }

  /// Cumulative handouts: 2px step line — flat between presses, a vertical
  /// riser on each one, since a handout is a discrete event.
  void _paintHandoutsStep(Canvas canvas, _Layout l) {
    final times = analysis.handoutTimes;
    if (times.isEmpty) return;
    final path = Path()..moveTo(l.xOf(analysis.start), l.yRight(0));
    for (var i = 0; i < times.length; i++) {
      final x = l.xOf(times[i]);
      path.lineTo(x, l.yRight(i.toDouble())); // hold the previous count…
      path.lineTo(x, l.yRight((i + 1).toDouble())); // …step up on the press
    }
    path.lineTo(l.xOf(analysis.end), l.yRight(times.length.toDouble()));

    canvas.save();
    canvas.clipRect(l.rightPlot);
    canvas.drawPath(
      path,
      Paint()
        ..color = TEChartColors.handouts
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();

    // Direct label on the running total at the right edge of the WINDOW —
    // one number, where the line leaves the plot, rather than a figure on
    // every step. Zoomed in, it reads the count reached so far.
    final visible = analysis.cumulativeAt(viewEnd);
    _endLabel(canvas, l, visible.toString(), l.yRight(visible.toDouble()));
  }

  /// Cumulative distance: a continuous line following the tracklog, exactly
  /// like the speed line — it climbs whenever the distributor is moving and
  /// flattens whenever they are not. Same gap treatment as speed: broken
  /// across a genuine gap, unbroken across a dwell, since distance really
  /// does stay flat while they stand still.
  void _paintDistanceLine(Canvas canvas, _Layout l) {
    final s = analysis.samples;
    if (s.length < 2) return;
    final path = Path();
    var penDown = false;
    for (var i = 0; i < s.length; i++) {
      final x = l.xOf(s[i].time);
      final y = l.yRight(s[i].cumulativeKm);
      final brokeHere = i > 0 && analysis.spansGap(s[i - 1].time, s[i].time);
      if (!penDown || brokeHere) {
        path.moveTo(x, y);
        penDown = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.save();
    canvas.clipRect(l.rightPlot);
    canvas.drawPath(
      path,
      Paint()
        ..color = TEChartColors.handouts
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();

    final visible = teRightValueAt(analysis, secondary, viewEnd);
    _endLabel(canvas, l, _trimNum(visible), l.yRight(visible));
  }

  void _endLabel(Canvas canvas, _Layout l, String text, double y) {
    _text(canvas, text, Offset(l.rightPlot.right - 6, y - 10),
        align: _Align.rightCentre,
        color: TEChartColors.handouts,
        size: 11,
        weight: FontWeight.bold);
  }

  // ── Activity strip ──────────────────────────────────────────────────────
  void _paintStrip(Canvas canvas, _Layout l) {
    final r = RRect.fromRectAndRadius(l.strip, const Radius.circular(4));
    canvas.save();
    canvas.clipRRect(r);
    // Base state: on the move (or, where there is no tracklog at all, unknown).
    canvas.drawRect(
        l.strip,
        Paint()
          ..color = analysis.samples.isEmpty
              ? TEChartColors.grid
              : TEChartColors.speed.withValues(alpha: 0.55));
    for (final s in analysis.stops) {
      final rect = Rect.fromLTRB(
          l.xOf(s.start), l.strip.top, l.xOf(s.end), l.strip.bottom);
      canvas.drawRect(rect, Paint()..color = TEChartColors.forStop(s.kind));
      if (s.kind == TEStopKind.breakTime) {
        _hatch(canvas, rect, Colors.white.withValues(alpha: 0.55));
      }
    }
    for (final g in analysis.gaps) {
      final rect = Rect.fromLTRB(
          l.xOf(g.start), l.strip.top, l.xOf(g.end), l.strip.bottom);
      canvas.drawRect(rect, Paint()..color = TEChartColors.grid);
      _hatch(canvas, rect, TEChartColors.gap.withValues(alpha: 0.6));
    }
    canvas.restore();
    canvas.drawRRect(
        r,
        Paint()
          ..color = TEChartColors.axis
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    _text(canvas, 'Activity', Offset(l.strip.left - 6, l.strip.center.dy),
        align: _Align.rightCentre, color: TEChartColors.muted, size: 10);
  }

  // ── Panel titles double as the series' direct labels ────────────────────
  void _paintPanelTitles(Canvas canvas, _Layout l) {
    _text(canvas, 'Speed  km/h', Offset(l.speedPlot.left + 4, l.speedPlot.top),
        align: _Align.topLeft,
        color: TEChartColors.speed,
        size: 11,
        weight: FontWeight.bold);
    final rightTitle = secondary == TESecondarySeries.handouts
        ? 'Handouts  cumulative'
        : 'Distance  km walked';
    if (!l.overlay) {
      _text(canvas, rightTitle, Offset(l.rightPlot.left + 4, l.rightPlot.top),
          align: _Align.topLeft,
          color: TEChartColors.handouts,
          size: 11,
          weight: FontWeight.bold);
    } else {
      _text(canvas, rightTitle, Offset(l.rightPlot.right - 4, l.rightPlot.top),
          align: _Align.topRight,
          color: TEChartColors.handouts,
          size: 11,
          weight: FontWeight.bold);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.analysis != analysis ||
      old.overlay != overlay ||
      old.secondary != secondary ||
      old.viewStart != viewStart ||
      old.viewEnd != viewEnd;
}

// ════════════════════════════════════════════════════════════════════════════
// CURSOR PAINTER — crosshair + tooltip, repaints on mouse move only
// ════════════════════════════════════════════════════════════════════════════

class _CursorPainter extends CustomPainter {
  final TETrackAnalysis analysis;
  final bool overlay;
  final TESecondarySeries secondary;
  final DateTime viewStart;
  final DateTime viewEnd;
  final ValueNotifier<Offset?> cursor;

  _CursorPainter({
    required this.analysis,
    required this.overlay,
    required this.secondary,
    required this.viewStart,
    required this.viewEnd,
    required this.cursor,
  }) : super(repaint: cursor);

  @override
  void paint(Canvas canvas, Size size) {
    final pos = cursor.value;
    if (pos == null || size.width < 120 || size.height < 120) return;
    final l = _Layout.of(size, analysis, overlay, secondary, viewStart, viewEnd);
    if (pos.dx < l.speedPlot.left || pos.dx > l.speedPlot.right) return;
    if (pos.dy < l.bandTop || pos.dy > l.bandBottom) return;

    final t = l.timeAt(pos.dx);
    final x = l.xOf(t);

    canvas.drawLine(
      Offset(x, l.bandTop),
      Offset(x, l.bandBottom),
      Paint()
        ..color = TEChartColors.primaryInk.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );

    final sample = analysis.sampleAt(t);
    final rightValue = teRightValueAt(analysis, secondary, t);

    // Dots on each series where the crosshair crosses it, ringed in the
    // surface colour so they stay legible over the shaded bands.
    if (sample != null) {
      _dot(canvas, Offset(x, l.ySpeed(sample.speedKmh)), TEChartColors.speed);
    }
    _dot(canvas, Offset(x, l.yRight(rightValue)), TEChartColors.handouts);

    final stop = analysis.stopAt(t);
    final gap = analysis.gapAt(t);
    final rightLabel = secondary == TESecondarySeries.handouts
        ? 'Handouts so far'
        : 'Distance so far';
    final rightText = secondary == TESecondarySeries.handouts
        ? rightValue.round().toString()
        : '${rightValue.toStringAsFixed(2)} km';
    final lines = <(String, String, Color)>[
      ('Time', _hms.format(t), TEChartColors.primaryInk),
      if (sample != null)
        (
          'Speed',
          '${sample.speedKmh.toStringAsFixed(1)} km/h',
          TEChartColors.speed
        ),
      (rightLabel, rightText, TEChartColors.handouts),
      if (gap != null)
        ('No tracklog', _dur(gap.duration), TEChartColors.gap)
      else if (stop != null)
        (
          stop.kind.label,
          stop.kind == TEStopKind.handout
              ? '${_dur(stop.duration)} · ${stop.handouts} handouts'
              : _dur(stop.duration),
          TEChartColors.forStop(stop.kind),
        )
      else if (sample != null)
        ('On the move', '', TEChartColors.speed),
    ];
    _tooltip(canvas, size, Offset(x, pos.dy), lines);
  }

  void _dot(Canvas canvas, Offset c, Color color) {
    canvas.drawCircle(c, 5, Paint()..color = TEChartColors.surface);
    canvas.drawCircle(c, 4, Paint()..color = color);
  }

  void _tooltip(
    Canvas canvas,
    Size size,
    Offset anchor,
    List<(String, String, Color)> lines,
  ) {
    const pad = 8.0;
    const rowH = 15.0;
    final painters = <(TextPainter, Color)>[];
    var w = 0.0;
    for (final (label, value, color) in lines) {
      final tp = TextPainter(
        text: TextSpan(children: [
          TextSpan(
            text: value.isEmpty ? label : '$label  ',
            style: const TextStyle(
                fontSize: 11, color: TEChartColors.secondaryInk),
          ),
          if (value.isNotEmpty)
            TextSpan(
              text: value,
              style: const TextStyle(
                fontSize: 11,
                color: TEChartColors.primaryInk,
                fontWeight: FontWeight.w600,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
        ]),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      w = math.max(w, tp.width);
      painters.add((tp, color));
    }
    final boxW = w + pad * 2 + 12;
    final boxH = lines.length * rowH + pad * 2;

    var left = anchor.dx + 14;
    if (left + boxW > size.width) left = anchor.dx - 14 - boxW;
    left = left.clamp(0.0, math.max(0.0, size.width - boxW));
    var top = anchor.dy - boxH - 12;
    if (top < 0) top = anchor.dy + 12;
    top = top.clamp(0.0, math.max(0.0, size.height - boxH));

    final box = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, boxW, boxH), const Radius.circular(6));
    canvas.drawRRect(
        box, Paint()..color = TEChartColors.surface.withValues(alpha: 0.97));
    canvas.drawRRect(
        box,
        Paint()
          ..color = TEChartColors.primaryInk.withValues(alpha: 0.12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);

    for (var i = 0; i < painters.length; i++) {
      final (tp, color) = painters[i];
      final y = top + pad + i * rowH;
      canvas.drawRect(
        Rect.fromLTWH(left + pad, y + 4, 6, 6),
        Paint()..color = color,
      );
      tp.paint(canvas, Offset(left + pad + 12, y));
    }
  }

  @override
  bool shouldRepaint(_CursorPainter old) =>
      old.analysis != analysis ||
      old.overlay != overlay ||
      old.secondary != secondary ||
      old.viewStart != viewStart ||
      old.viewEnd != viewEnd;
}

// ════════════════════════════════════════════════════════════════════════════
// Small helpers
// ════════════════════════════════════════════════════════════════════════════

enum _Align { rightCentre, leftCentre, topCentre, topLeft, topRight }

void _text(
  Canvas canvas,
  String s,
  Offset at, {
  required _Align align,
  required Color color,
  required double size,
  FontWeight weight = FontWeight.normal,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontSize: size,
        color: color,
        fontWeight: weight,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    ),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  final o = switch (align) {
    _Align.rightCentre => Offset(at.dx - tp.width, at.dy - tp.height / 2),
    _Align.leftCentre => Offset(at.dx, at.dy - tp.height / 2),
    _Align.topCentre => Offset(at.dx - tp.width / 2, at.dy),
    _Align.topLeft => at,
    _Align.topRight => Offset(at.dx - tp.width, at.dy),
  };
  tp.paint(canvas, o);
}

String _trimNum(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

DateTime _ceilTo(DateTime t, Duration step) {
  final ms = step.inMilliseconds;
  final base = DateTime(t.year, t.month, t.day);
  final since = t.difference(base).inMilliseconds;
  return base.add(Duration(milliseconds: ((since / ms).ceil()) * ms));
}

/// "1h 05m" / "12m 30s" — compact enough for a tooltip or a table cell.
String _dur(Duration d) {
  if (d.inHours > 0) {
    return '${d.inHours}h ${d.inMinutes.remainder(60).toString().padLeft(2, '0')}m';
  }
  if (d.inMinutes > 0) {
    return '${d.inMinutes}m ${d.inSeconds.remainder(60).toString().padLeft(2, '0')}s';
  }
  return '${d.inSeconds}s';
}

/// Shared duration formatter for the panels below the chart.
String teFormatDuration(Duration d) => _dur(d);

/// Shared clock formatter for the panels below the chart.
String teFormatClock(DateTime t) => _hm.format(t);

/// Shared clock formatter including seconds.
String teFormatClockSeconds(DateTime t) => _hms.format(t);
