// widgets/weather/weather_symbol.dart
//
// yr.no's own weather symbols (assets/weather/, © Yr/NRK, CC BY 4.0, via
// github.com/metno/weathericons) for MET symbol codes like
// "lightrainshowers_day", plus the colours yr uses for temperature, rain and
// the distribution rating.
import 'package:flutter/material.dart';

import '../../models/weather_forecast.dart';

/// English names from MET's legend.csv, keyed by symbol code without the
/// _day / _night suffix. (MET's codes really do spell "lightssleet…".)
const _symbolNames = {
  'clearsky': 'Clear sky',
  'fair': 'Fair',
  'partlycloudy': 'Partly cloudy',
  'cloudy': 'Cloudy',
  'fog': 'Fog',
  'lightrainshowers': 'Light rain showers',
  'rainshowers': 'Rain showers',
  'heavyrainshowers': 'Heavy rain showers',
  'lightrainshowersandthunder': 'Light rain showers and thunder',
  'rainshowersandthunder': 'Rain showers and thunder',
  'heavyrainshowersandthunder': 'Heavy rain showers and thunder',
  'lightsleetshowers': 'Light sleet showers',
  'sleetshowers': 'Sleet showers',
  'heavysleetshowers': 'Heavy sleet showers',
  'lightssleetshowersandthunder': 'Light sleet showers and thunder',
  'sleetshowersandthunder': 'Sleet showers and thunder',
  'heavysleetshowersandthunder': 'Heavy sleet showers and thunder',
  'lightsnowshowers': 'Light snow showers',
  'snowshowers': 'Snow showers',
  'heavysnowshowers': 'Heavy snow showers',
  'lightssnowshowersandthunder': 'Light snow showers and thunder',
  'snowshowersandthunder': 'Snow showers and thunder',
  'heavysnowshowersandthunder': 'Heavy snow showers and thunder',
  'lightrain': 'Light rain',
  'rain': 'Rain',
  'heavyrain': 'Heavy rain',
  'lightrainandthunder': 'Light rain and thunder',
  'rainandthunder': 'Rain and thunder',
  'heavyrainandthunder': 'Heavy rain and thunder',
  'lightsleet': 'Light sleet',
  'sleet': 'Sleet',
  'heavysleet': 'Heavy sleet',
  'lightsleetandthunder': 'Light sleet and thunder',
  'sleetandthunder': 'Sleet and thunder',
  'heavysleetandthunder': 'Heavy sleet and thunder',
  'lightsnow': 'Light snow',
  'snow': 'Snow',
  'heavysnow': 'Heavy snow',
  'lightsnowandthunder': 'Light snow and thunder',
  'snowandthunder': 'Snow and thunder',
  'heavysnowandthunder': 'Heavy snow and thunder',
};

String _baseCode(String code) =>
    code.replaceAll(RegExp(r'_(day|night|polartwilight)$'), '');

/// "Light rain showers" for "lightrainshowers_day".
String weatherSymbolLabel(String code) => _symbolNames[_baseCode(code)] ?? code;

bool isNightSymbol(String code) => code.endsWith('_night');

bool isWetSymbol(String code) =>
    RegExp(r'rain|sleet|snow').hasMatch(_baseCode(code));

/// A yr symbol image. Polar-twilight codes (never used this far north… or
/// south) fall back to the day variant; anything unknown to a cloud.
class WeatherSymbolIcon extends StatelessWidget {
  final String code;
  final double size;

  const WeatherSymbolIcon(this.code, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    final file = code.replaceAll('_polartwilight', '_day');
    return Semantics(
      label: weatherSymbolLabel(code),
      child: Image.asset(
        'assets/weather/$file.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.cloud_outlined, size: size * 0.9),
      ),
    );
  }
}

/// yr's temperature colours: red above zero, blue at or below.
Color temperatureColor(double? t, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  if (t != null && t <= 0) {
    return dark ? const Color(0xFF7CC4FF) : const Color(0xFF0062BF);
  }
  return dark ? const Color(0xFFFF7A7A) : const Color(0xFFC60000);
}

/// yr's precipitation blue.
Color precipitationColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFF5BB3FF)
    : const Color(0xFF006EDB);

/// Green / amber / red for how a day suits distribution.
Color distributionRatingColor(
    DistributionRating rating, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  switch (rating) {
    case DistributionRating.good:
      return dark ? Colors.green.shade300 : Colors.green.shade700;
    case DistributionRating.marginal:
      return dark ? Colors.amber.shade300 : Colors.orange.shade800;
    case DistributionRating.poor:
      return dark ? Colors.red.shade300 : Colors.red.shade700;
  }
}

String distributionRatingShort(DistributionRating rating) {
  switch (rating) {
    case DistributionRating.good:
      return 'Good';
    case DistributionRating.marginal:
      return 'Marginal';
    case DistributionRating.poor:
      return 'Poor';
  }
}

String distributionRatingLabel(DistributionRating rating) {
  switch (rating) {
    case DistributionRating.good:
      return 'Good for distribution';
    case DistributionRating.marginal:
      return 'Marginal — some rain or wind';
    case DistributionRating.poor:
      return 'Poor — heavy rain or strong wind';
  }
}

/// m/s → km/h, as people in SA read wind.
int kmh(double ms) => (ms * 3.6).round();

/// "SE" for 135°.
String compassPoint(int degrees) {
  const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return points[((degrees % 360) / 45).round() % 8];
}

/// An arrow pointing where the wind blows TO (MET gives where it comes
/// FROM), as yr draws it.
class WindArrow extends StatelessWidget {
  final int? fromDegrees;
  final double size;
  final Color? color;

  const WindArrow(this.fromDegrees, {super.key, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    if (fromDegrees == null) return SizedBox(width: size, height: size);
    return Tooltip(
      message: 'From the ${compassPoint(fromDegrees!)}',
      child: Transform.rotate(
        angle: (fromDegrees! + 180) * 3.141592653589793 / 180,
        child: Icon(Icons.navigation, size: size, color: color),
      ),
    );
  }
}

/// Short tooltip / summary text for a day.
String weatherDaySummary(WeatherDay d) {
  final parts = <String>[
    weatherSymbolLabel(d.symbol),
    if (d.minTemp != null && d.maxTemp != null)
      '${d.minTemp!.round()}–${d.maxTemp!.round()}°C',
    'Rain ${d.precipMm.toStringAsFixed(1)} mm'
        '${d.workPrecipMm != d.precipMm ? ' (${d.workPrecipMm.toStringAsFixed(1)} mm 06–18)' : ''}',
    if (d.workMaxWindMs != null) 'Wind up to ${kmh(d.workMaxWindMs!)} km/h',
  ];
  return parts.join(' · ');
}
