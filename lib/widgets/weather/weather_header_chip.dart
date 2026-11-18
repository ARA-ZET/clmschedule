// widgets/weather/weather_header_chip.dart
//
// The forecast badge in a schedule date header: symbol, top temperature, and
// rain / wind when they matter, outlined green / amber / red by how the day
// suits distribution. Days outside the forecast range show nothing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/weather_forecast.dart';
import '../../providers/weather_provider.dart';
import 'weather_screen.dart';
import 'weather_symbol.dart';

class WeatherHeaderChip extends riverpod.ConsumerWidget {
  final DateTime date;
  final double iconSize;

  const WeatherHeaderChip({
    super.key,
    required this.date,
    required this.iconSize,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final day = ref.watch(scheduleWeatherRiverpod)?.dayFor(date);
    if (day == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final rating = day.distributionRating;
    final ratingColor = distributionRatingColor(rating, theme.brightness);
    final textStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: iconSize * 0.7,
      color: theme.colorScheme.onSurface,
    );
    final wind = day.workMaxWindMs;
    final location = ref.watch(depotWeatherLocationRiverpod).name;

    return Tooltip(
      message: '${distributionRatingLabel(rating)}\n'
          '${weatherDaySummary(day)}\n'
          '$location · Weather data from MET Norway (yr)',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => WeatherScreen(initialDate: date)),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ratingColor, width: 1.5),
            color: rating == DistributionRating.good
                ? null
                : ratingColor.withValues(alpha: 0.12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              WeatherSymbolIcon(day.symbol, size: iconSize),
              if (day.maxTemp != null) ...[
                const SizedBox(width: 2),
                Text('${day.maxTemp!.round()}°', style: textStyle),
              ],
              if (day.workPrecipMm >= 0.1) ...[
                const SizedBox(width: 4),
                Text('${_mm(day.workPrecipMm)}mm', style: textStyle),
              ],
              if (wind != null &&
                  wind >= DistributionWeatherThresholds.marginalWindMs) ...[
                const SizedBox(width: 4),
                Icon(Icons.air, size: iconSize * 0.85, color: ratingColor),
                Text('${kmh(wind)}', style: textStyle),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _mm(double v) =>
      v >= 10 ? v.round().toString() : v.toStringAsFixed(1);
}
