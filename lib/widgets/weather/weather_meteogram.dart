// widgets/weather/weather_meteogram.dart
//
// yr's hour-by-hour graph: symbols along the top, a temperature curve, rain
// bars, night shading from sunrise/sunset, day dividers, and wind arrows and
// hour labels underneath. Scrolls sideways; one column per hour.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../models/weather_forecast.dart';
import '../../utils/schedule_time.dart';
import '../../utils/sun_times.dart';
import 'weather_symbol.dart';

class WeatherMeteogram extends StatefulWidget {
  /// Hourly steps, in order.
  final List<WeatherStep> steps;
  final double lat;
  final double lon;

  const WeatherMeteogram({
    super.key,
    required this.steps,
    required this.lat,
    required this.lon,
  });

  static const double colWidth = 46;
  static const double dayRow = 24;
  static const double iconRow = 36;
  static const double chartHeight = 150;
  static const double windRow = 40;
  static const double hourRow = 22;
  static const double totalHeight =
      dayRow + iconRow + chartHeight + windRow + hourRow;

  @override
  State<WeatherMeteogram> createState() => _WeatherMeteogramState();
}

class _WeatherMeteogramState extends State<WeatherMeteogram> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static const colWidth = WeatherMeteogram.colWidth;
  static const dayRow = WeatherMeteogram.dayRow;
  static const iconRow = WeatherMeteogram.iconRow;
  static const chartHeight = WeatherMeteogram.chartHeight;
  static const windRow = WeatherMeteogram.windRow;
  static const totalHeight = WeatherMeteogram.totalHeight;

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    final lat = widget.lat;
    final lon = widget.lon;
    if (steps.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final width = steps.length * colWidth;
    final civil = [for (final s in steps) toScheduleCivil(s.time)];

    // Night = the middle of the hour falls outside sunrise–sunset.
    final sunCache = <DateTime, ({DateTime sunrise, DateTime sunset})?>{};
    final night = <bool>[
      for (final c in civil)
        () {
          final day = DateTime(c.year, c.month, c.day);
          final sun = sunCache.putIfAbsent(day, () => sunTimes(day, lat, lon));
          if (sun == null) return false;
          final mid = c.add(const Duration(minutes: 30));
          return mid.isBefore(sun.sunrise) || mid.isAfter(sun.sunset);
        }(),
    ];

    final hourStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final windColor = theme.colorScheme.onSurfaceVariant;

    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: width,
          height: totalHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _MeteogramPainter(
                    steps: steps,
                    civil: civil,
                    night: night,
                    brightness: theme.brightness,
                    textScaler: MediaQuery.textScalerOf(context),
                    fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                    labelColor: theme.colorScheme.onSurface,
                    gridColor: theme.colorScheme.outlineVariant,
                    nightColor: theme.brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.04)
                        : const Color(0xFF0B2545).withValues(alpha: 0.05),
                  ),
                ),
              ),
              for (var i = 0; i < steps.length; i++) ...[
                Positioned(
                  left: i * colWidth + (colWidth - 32) / 2,
                  top: dayRow + 2,
                  child: Tooltip(
                    message: weatherSymbolLabel(steps[i].symbol),
                    child: WeatherSymbolIcon(steps[i].symbol, size: 32),
                  ),
                ),
                Positioned(
                  left: i * colWidth,
                  width: colWidth,
                  top: dayRow + iconRow + chartHeight + 4,
                  child: Column(
                    children: [
                      WindArrow(steps[i].windDir, size: 14, color: windColor),
                      Text(
                        steps[i].windMs == null
                            ? ''
                            : '${kmh(steps[i].windMs!)}',
                        style: hourStyle?.copyWith(
                          color: _windTextColor(steps[i].windMs, theme),
                          fontWeight: (steps[i].windMs ?? 0) >=
                                  DistributionWeatherThresholds.marginalWindMs
                              ? FontWeight.w700
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: i * colWidth,
                  width: colWidth,
                  top: dayRow + iconRow + chartHeight + windRow + 2,
                  child: Text(
                    DateFormat('HH').format(civil[i]),
                    textAlign: TextAlign.center,
                    style: hourStyle?.copyWith(
                      fontWeight: civil[i].hour == 0 ? FontWeight.w700 : null,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static Color? _windTextColor(double? ms, ThemeData theme) {
    if (ms == null) return null;
    if (ms >= DistributionWeatherThresholds.poorWindMs) {
      return distributionRatingColor(DistributionRating.poor, theme.brightness);
    }
    if (ms >= DistributionWeatherThresholds.marginalWindMs) {
      return distributionRatingColor(
          DistributionRating.marginal, theme.brightness);
    }
    return null;
  }
}

class _MeteogramPainter extends CustomPainter {
  final List<WeatherStep> steps;
  final List<DateTime> civil;
  final List<bool> night;
  final Brightness brightness;
  final TextScaler textScaler;
  final String? fontFamily;
  final Color labelColor;
  final Color gridColor;
  final Color nightColor;

  _MeteogramPainter({
    required this.steps,
    required this.civil,
    required this.night,
    required this.brightness,
    required this.textScaler,
    required this.fontFamily,
    required this.labelColor,
    required this.gridColor,
    required this.nightColor,
  });

  static const _col = WeatherMeteogram.colWidth;
  static const _chartTop = WeatherMeteogram.dayRow + WeatherMeteogram.iconRow;
  static const _chartBottom = _chartTop + WeatherMeteogram.chartHeight;

  @override
  void paint(Canvas canvas, Size size) {
    // Night shading, merged into runs so there are no seams between hours.
    final nightPaint = Paint()..color = nightColor;
    for (var i = 0; i < steps.length;) {
      if (!night[i]) {
        i++;
        continue;
      }
      final start = i;
      while (i < steps.length && night[i]) {
        i++;
      }
      canvas.drawRect(
        Rect.fromLTRB(
            start * _col, WeatherMeteogram.dayRow, i * _col, size.height),
        nightPaint,
      );
    }

    // Faint hour gridlines through the chart.
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < steps.length; i++) {
      final x = i * _col;
      canvas.drawLine(Offset(x, _chartTop), Offset(x, _chartBottom), grid);
    }
    canvas.drawLine(Offset(0, _chartBottom), Offset(size.width, _chartBottom),
        grid..color = gridColor);

    // Day dividers and day names (the first label sits at the start).
    final divider = Paint()
      ..color = gridColor
      ..strokeWidth = 1.2;
    for (var i = 0; i < steps.length; i++) {
      if (i != 0 && civil[i].hour != 0) continue;
      // A late-evening start leaves no room before the next day's label.
      if (i == 0 && civil[0].hour > 20) continue;
      final x = i * _col;
      if (i != 0) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), divider);
      }
      _text(
        canvas,
        DateFormat('EEEE d MMM').format(civil[i]),
        Offset(x + 6, 4),
        TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w700, color: labelColor),
      );
    }

    // Rain bars, scaled so 4 mm/h fills ~60% of the chart unless it is wetter.
    final precipColor = precipitationColor(brightness);
    final maxPrecip =
        steps.map((s) => s.precipMm).fold<double>(0, math.max).clamp(4.0, 50.0);
    final barMaxH = WeatherMeteogram.chartHeight * 0.6;
    final barPaint = Paint()..color = precipColor.withValues(alpha: 0.85);
    for (var i = 0; i < steps.length; i++) {
      final mm = steps[i].precipMm;
      if (mm <= 0) continue;
      final h = math.max(2.0, mm / maxPrecip * barMaxH);
      final rect = Rect.fromLTWH(i * _col + 6, _chartBottom - h, _col - 12, h);
      canvas.drawRRect(
        RRect.fromRectAndCorners(rect,
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3)),
        barPaint,
      );
      _text(
        canvas,
        mm >= 10 ? mm.round().toString() : mm.toStringAsFixed(1),
        Offset(i * _col + _col / 2, _chartBottom - h - 14),
        TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w600, color: precipColor),
        center: true,
      );
    }

    // Temperature curve (upper ~70% of the chart, leaving room for labels).
    final temps = [for (final s in steps) s.temp];
    final known = temps.whereType<double>().toList();
    if (known.length < 2) return;
    final tMin = known.reduce(math.min) - 1;
    final tMax = known.reduce(math.max) + 1;
    final top = _chartTop + 22.0;
    final bottom = _chartTop + WeatherMeteogram.chartHeight * 0.72;
    double yFor(double t) =>
        bottom - (t - tMin) / math.max(1, tMax - tMin) * (bottom - top);
    final points = <Offset>[
      for (var i = 0; i < steps.length; i++)
        if (temps[i] != null) Offset(i * _col + _col / 2, yFor(temps[i]!)),
    ];

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      // Catmull-Rom → cubic Bézier for a smooth curve through every hour.
      final p0 = i == 0 ? points[i] : points[i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : p2;
      path.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
        p2.dx,
        p2.dy,
      );
    }

    final warm = temperatureColor(1, brightness);
    final fill = Path.from(path)
      ..lineTo(points.last.dx, _chartBottom)
      ..lineTo(points.first.dx, _chartBottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [warm.withValues(alpha: 0.16), warm.withValues(alpha: 0)],
        ).createShader(Rect.fromLTRB(0, top, 0, _chartBottom)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = warm
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Temperature labels every other hour, plus each day's high.
    final dayMaxIndex = <int, int>{};
    for (var i = 0; i < steps.length; i++) {
      if (temps[i] == null) continue;
      final key = civil[i].day;
      final best = dayMaxIndex[key];
      if (best == null || temps[i]! > temps[best]!) dayMaxIndex[key] = i;
    }
    final highs = dayMaxIndex.values.toSet();
    for (var i = 0; i < steps.length; i++) {
      final t = temps[i];
      if (t == null || (i.isOdd && !highs.contains(i))) continue;
      final p = Offset(i * _col + _col / 2, yFor(t));
      canvas.drawCircle(p, 3, Paint()..color = warm);
      _text(
        canvas,
        '${t.round()}°',
        p.translate(0, -19),
        TextStyle(
          fontSize: highs.contains(i) ? 13 : 11.5,
          fontWeight: highs.contains(i) ? FontWeight.w800 : FontWeight.w600,
          color: temperatureColor(t, brightness),
        ),
        center: true,
      );
    }
  }

  void _text(Canvas canvas, String text, Offset at, TextStyle style,
      {bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(fontFamily: fontFamily)),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    tp.paint(canvas, center ? at.translate(-tp.width / 2, 0) : at);
  }

  @override
  bool shouldRepaint(covariant _MeteogramPainter old) =>
      old.steps != steps || old.brightness != brightness;
}
