// widgets/weather/weather_day_table.dart
//
// yr's long-term table: one row per day with night / morning / afternoon /
// evening symbols, max/min temperature, rain and wind — plus our
// distribution rating. A row expands into that day's hour-by-hour table
// (6-hourly beyond ~2.5 days, as MET publishes it).
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../models/weather_forecast.dart';
import '../../utils/schedule_time.dart';
import 'weather_symbol.dart';

class WeatherDayTable extends StatelessWidget {
  final List<WeatherDay> days;
  final List<WeatherStep> steps;
  final DateTime? expandedDay;
  final ValueChanged<DateTime> onToggle;

  /// Row keys by date, so the screen can scroll an opened day into view.
  final Map<DateTime, GlobalKey> rowKeys;

  const WeatherDayTable({
    super.key,
    required this.days,
    required this.steps,
    required this.expandedDay,
    required this.onToggle,
    required this.rowKeys,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 720;
      return Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            _HeaderRow(wide: wide),
            for (final d in days) ...[
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
              _DayRow(
                key: rowKeys.putIfAbsent(d.date, GlobalKey.new),
                day: d,
                wide: wide,
                expanded: d.date == expandedDay,
                onTap: () => onToggle(d.date),
                steps: steps.where((s) => _sameDay(s.time, d.date)).toList(),
              ),
            ],
          ],
        ),
      );
    });
  }

  static bool _sameDay(DateTime instant, DateTime civilDay) {
    final c = toScheduleCivil(instant);
    return c.year == civilDay.year &&
        c.month == civilDay.month &&
        c.day == civilDay.day;
  }
}

// Column widths shared by header and rows.
const _periodW = 46.0;
const _tempW = 92.0;
const _precipW = 78.0;
const _windW = 92.0;
const _ratingW = 104.0;
const _chevronW = 36.0;

class _HeaderRow extends StatelessWidget {
  final bool wide;

  const _HeaderRow({required this.wide});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    );
    Widget cell(String text, double w) => SizedBox(
          width: w,
          child: Text(text, textAlign: TextAlign.center, style: style),
        );
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
      child: Row(
        children: [
          Expanded(child: Text('Day', style: style)),
          if (wide) ...[
            cell('Night', _periodW),
            cell('Morning', _periodW + 8),
            cell('Afternoon', _periodW + 14),
            cell('Evening', _periodW + 4),
          ] else
            cell('', _periodW),
          cell('Max / min', _tempW),
          cell('Rain', _precipW),
          if (wide) cell('Wind', _windW),
          if (wide) cell('Distribution', _ratingW),
          const SizedBox(width: _chevronW),
        ],
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  final WeatherDay day;
  final bool wide;
  final bool expanded;
  final VoidCallback onTap;
  final List<WeatherStep> steps;

  const _DayRow({
    super.key,
    required this.day,
    required this.wide,
    required this.expanded,
    required this.onTap,
    required this.steps,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final rating = day.distributionRating;
    final ratingColor = distributionRatingColor(rating, b);
    final today = scheduleToday();
    final isToday = day.date == today;
    final label = isToday
        ? 'Today'
        : day.date == today.add(const Duration(days: 1))
            ? 'Tomorrow'
            : DateFormat(wide ? 'EEEE d MMM' : 'EEE d MMM').format(day.date);
    final wind = day.workMaxWindMs;
    final precip = precipitationColor(b);

    Widget periodIcon(int i, double extra) => SizedBox(
          width: _periodW + extra,
          child: Center(
            child: day.periods[i] == null
                ? const SizedBox(height: 34)
                : Tooltip(
                    message: weatherSymbolLabel(day.periods[i]!.symbol),
                    child: WeatherSymbolIcon(day.periods[i]!.symbol, size: 34),
                  ),
          ),
        );

    final row = InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: expanded
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
              : null,
          border: Border(left: BorderSide(color: ratingColor, width: 4)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            if (wide) ...[
              periodIcon(0, 0),
              periodIcon(1, 8),
              periodIcon(2, 14),
              periodIcon(3, 4),
            ] else
              SizedBox(
                width: _periodW,
                child: Center(child: WeatherSymbolIcon(day.symbol, size: 34)),
              ),
            SizedBox(
              width: _tempW,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: '${day.maxTemp?.round() ?? '–'}°',
                    style: TextStyle(
                      color: temperatureColor(day.maxTemp, b),
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  TextSpan(
                    text: ' / ',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  TextSpan(
                    text: '${day.minTemp?.round() ?? '–'}°',
                    style: TextStyle(
                      color: temperatureColor(day.minTemp, b)
                          .withValues(alpha: 0.8),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ]),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(
              width: _precipW,
              child: Text(
                day.precipMm >= 0.05
                    ? '${day.precipMm.toStringAsFixed(1)} mm'
                    : '–',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: day.precipMm >= 0.05
                      ? precip
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (wide)
              SizedBox(
                width: _windW,
                child: Text(
                  wind == null ? '–' : '${kmh(wind)} km/h',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: rating == DistributionRating.good ||
                            (wind ?? 0) <
                                DistributionWeatherThresholds.marginalWindMs
                        ? null
                        : ratingColor,
                  ),
                ),
              ),
            if (wide)
              SizedBox(
                width: _ratingW,
                child: Center(
                  child: Tooltip(
                    message: weatherDaySummary(day),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: ratingColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        distributionRatingShort(rating),
                        style: TextStyle(
                          color: ratingColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            SizedBox(
              width: _chevronW,
              child: AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      children: [
        row,
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? _HourTable(day: day, steps: steps, wide: wide)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _HourTable extends StatelessWidget {
  final WeatherDay day;
  final List<WeatherStep> steps;
  final bool wide;

  const _HourTable({
    required this.day,
    required this.steps,
    required this.wide,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final head = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
    );
    final fmt = DateFormat('HH:mm');
    // Narrow screens drop "Feels like" and "Humidity" and tighten the rest.
    final timeW = wide ? 92.0 : 62.0;
    final rainW = wide ? 70.0 : 58.0;
    final windW = wide ? 96.0 : 80.0;

    Widget c(Widget child, double w, {bool left = false}) => SizedBox(
          width: w,
          child: Align(
            alignment: left ? Alignment.centerLeft : Alignment.center,
            child: child,
          ),
        );

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '${distributionRatingLabel(day.distributionRating)} · '
              '${weatherDaySummary(day)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: distributionRatingColor(day.distributionRating, b),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                c(Text('Time', style: head), timeW, left: true),
                Expanded(child: Text('Weather', style: head)),
                c(Text('Temp', style: head), 64),
                if (wide) c(Text('Feels like', style: head), 76),
                c(Text('Rain', style: head), rainW),
                c(Text('Wind', style: head), windW),
                if (wide) c(Text('Humidity', style: head), 76),
              ],
            ),
          ),
          if (steps.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No detail for this day.'),
            ),
          for (var i = 0; i < steps.length; i++)
            Builder(builder: (_) {
              final s = steps[i];
              final start = toScheduleCivil(s.time);
              final end = start.add(Duration(hours: s.hours));
              final time = s.hours == 1
                  ? fmt.format(start)
                  : wide
                      ? '${fmt.format(start)}–${fmt.format(end)}'
                      : '${DateFormat('HH').format(start)}–${DateFormat('HH').format(end)}';
              return Container(
                decoration: BoxDecoration(
                  color: i.isEven
                      ? theme.colorScheme.surface.withValues(alpha: 0.6)
                      : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    c(Text(time, style: theme.textTheme.bodyMedium), timeW,
                        left: true),
                    Expanded(
                      child: Row(
                        children: [
                          WeatherSymbolIcon(s.symbol, size: 30),
                          const SizedBox(width: 8),
                          if (wide)
                            Flexible(
                              child: Text(
                                weatherSymbolLabel(s.symbol),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                    c(
                      Text(
                        s.temp == null ? '–' : '${s.temp!.round()}°',
                        style: TextStyle(
                          color: temperatureColor(s.temp, b),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      64,
                    ),
                    if (wide)
                      c(
                        Text(
                          s.feelsLike == null
                              ? '–'
                              : '${s.feelsLike!.round()}°',
                          style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                        76,
                      ),
                    c(
                      Text(
                        s.precipMm > 0
                            ? '${s.precipMm.toStringAsFixed(1)} mm'
                            : '–',
                        style: TextStyle(
                          color: s.precipMm > 0
                              ? precipitationColor(b)
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: s.precipMm > 0 ? FontWeight.w700 : null,
                        ),
                      ),
                      rainW,
                    ),
                    c(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          WindArrow(s.windDir,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(s.windMs == null
                              ? '–'
                              : '${kmh(s.windMs!)} km/h'),
                        ],
                      ),
                      windW,
                    ),
                    if (wide)
                      c(
                        Text(s.humidity == null ? '–' : '${s.humidity}%',
                            style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant)),
                        76,
                      ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
