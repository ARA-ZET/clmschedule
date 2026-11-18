// widgets/weather/weather_now_card.dart
//
// The hero at the top of the Weather screen: place, current symbol and
// temperature on a sky that matches the conditions, today's distribution
// rating, and glass tiles for wind, rain, humidity, UV and sun times.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../models/weather_forecast.dart';
import '../../utils/schedule_time.dart';
import '../../utils/sun_times.dart';
import 'weather_symbol.dart';

class WeatherNowCard extends StatelessWidget {
  final String locationName;
  final VoidCallback onChangeLocation;
  final WeatherStep now;
  final WeatherDay? today;
  final double lat;
  final double lon;

  const WeatherNowCard({
    super.key,
    required this.locationName,
    required this.onChangeLocation,
    required this.now,
    required this.today,
    required this.lat,
    required this.lon,
  });

  /// Sky gradients, darkest at the top so white text always reads.
  static List<Color> _sky(String code) {
    final base = code.replaceAll(RegExp(r'_(day|night|polartwilight)$'), '');
    if (isNightSymbol(code)) {
      return const [Color(0xFF071A33), Color(0xFF1B3A63)];
    }
    if (base.contains('thunder')) {
      return const [Color(0xFF22243D), Color(0xFF4A4F72)];
    }
    if (isWetSymbol(code)) {
      return const [Color(0xFF263D52), Color(0xFF557189)];
    }
    if (base == 'cloudy' || base == 'fog') {
      return const [Color(0xFF3F5466), Color(0xFF7A8D9C)];
    }
    if (base == 'partlycloudy') {
      return const [Color(0xFF1F5F96), Color(0xFF5C93C2)];
    }
    return const [Color(0xFF0F5FB0), Color(0xFF3F93E0)];
  }

  @override
  Widget build(BuildContext context) {
    final nowCivil = scheduleNow();
    final sun = sunTimes(scheduleToday(), lat, lon);
    final time = DateFormat('HH:mm');
    final rating = today?.distributionRating;

    final headline = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onChangeLocation,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.place, color: Colors.white, size: 22),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    locationName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const Icon(Icons.expand_more, color: Colors.white70),
              ],
            ),
          ),
        ),
        Text(
          'Now · ${DateFormat('EEEE d MMMM, HH:mm').format(nowCivil)}',
          style: const TextStyle(color: Colors.white70, fontSize: 13.5),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            WeatherSymbolIcon(now.symbol, size: 104),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  now.temp == null ? '–' : '${now.temp!.round()}°',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 72,
                    height: 1.0,
                    fontWeight: FontWeight.w300,
                    letterSpacing: -2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  weatherSymbolLabel(now.symbol),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (now.feelsLike != null)
                  Text(
                    'Feels like ${now.feelsLike!.round()}°',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
              ],
            ),
          ],
        ),
        if (today != null) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Pill(
                icon: Icons.thermostat,
                text: 'Today ${today!.maxTemp?.round() ?? '–'}° / '
                    '${today!.minTemp?.round() ?? '–'}°',
              ),
              if (rating != null) _RatingPill(rating: rating),
            ],
          ),
        ],
      ],
    );

    final tiles = <Widget>[
      _GlassTile(
        icon: Icons.air,
        label: 'Wind',
        leading: WindArrow(now.windDir, size: 18, color: Colors.white),
        value: now.windMs == null ? '–' : '${kmh(now.windMs!)} km/h',
        detail: now.windDir == null
            ? null
            : 'From the ${compassPoint(now.windDir!)}',
      ),
      _GlassTile(
        icon: Icons.water_drop_outlined,
        label: 'Rain today',
        value: today == null ? '–' : '${today!.precipMm.toStringAsFixed(1)} mm',
        detail: now.precipMm > 0
            ? '${now.precipMm.toStringAsFixed(1)} mm this hour'
            : 'Dry this hour',
      ),
      _GlassTile(
        icon: Icons.opacity,
        label: 'Humidity',
        value: now.humidity == null ? '–' : '${now.humidity}%',
        detail: now.cloud == null ? null : '${now.cloud}% cloud cover',
      ),
      if (now.uv != null)
        _GlassTile(
          icon: Icons.wb_sunny_outlined,
          label: 'UV index',
          value: now.uv!.toStringAsFixed(now.uv! >= 10 ? 0 : 1),
          detail: _uvBand(now.uv!),
        ),
      if (sun != null)
        _GlassTile(
          icon: Icons.wb_twilight,
          label: 'Sunrise · Sunset',
          value: '${time.format(sun.sunrise)} · ${time.format(sun.sunset)}',
          detail: _daylight(sun.sunset.difference(sun.sunrise)),
        ),
    ];

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _sky(now.symbol),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 760;
          final grid = Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < tiles.length; i++)
                SizedBox(
                  // Two per row; an odd last tile takes the whole row.
                  width: () {
                    final rowW = wide ? c.maxWidth * 0.46 : c.maxWidth;
                    final last = i == tiles.length - 1 && tiles.length.isOdd;
                    return last ? rowW : (rowW - 10) / 2;
                  }(),
                  child: tiles[i],
                ),
            ],
          );
          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [headline, const SizedBox(height: 20), grid],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: headline),
              const SizedBox(width: 20),
              SizedBox(width: c.maxWidth * 0.46, child: grid),
            ],
          );
        },
      ),
    );
  }

  static String _uvBand(double uv) {
    if (uv < 3) return 'Low';
    if (uv < 6) return 'Moderate';
    if (uv < 8) return 'High — sunscreen for the team';
    if (uv < 11) return 'Very high — sunscreen & hats';
    return 'Extreme — cover up';
  }

  static String _daylight(Duration d) =>
      '${d.inHours} h ${d.inMinutes % 60} min of daylight';
}

class _GlassTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? detail;
  final Widget? leading;

  const _GlassTile({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: Colors.white70),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 6)],
              Flexible(
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 2),
            Text(
              detail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Pill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _RatingPill extends StatelessWidget {
  final DistributionRating rating;

  const _RatingPill({required this.rating});

  @override
  Widget build(BuildContext context) {
    // Always the light-theme shade: it sits on the dark sky, as a solid chip.
    final color = distributionRatingColor(rating, Brightness.light);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            rating == DistributionRating.good
                ? Icons.check_circle
                : Icons.warning_amber_rounded,
            size: 16,
            color: Colors.white,
          ),
          const SizedBox(width: 6),
          Text(
            distributionRatingLabel(rating),
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
