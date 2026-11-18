// models/weather_forecast.dart
//
// Forecast summary returned by the `weatherForecast` callable — MET Norway
// Locationforecast (the data behind yr.no), already bucketed into SAST days
// on the server. See functions/lib/weather_proxy.js.
import 'package:intl/intl.dart';

/// How a day's weather suits leaflet distribution.
enum DistributionRating { good, marginal, poor }

/// Thresholds for [WeatherDay.distributionRating], over working hours
/// (06–18 SAST). MET has no gusts outside the Nordics, so wind is the mean
/// speed — Cape Town's south-easter at 10 m/s (36 km/h) already sends
/// unbanded leaflets flying.
class DistributionWeatherThresholds {
  static const double poorRainMm = 3.0;
  static const double poorWindMs = 10.0;
  static const double marginalRainMm = 0.5;
  static const double marginalWindMs = 7.0;
}

double? _num(Object? v) => (v as num?)?.toDouble();

/// One of yr's four day parts — night, morning, afternoon, evening — as
/// MET's own 6-hour forecast block.
class WeatherPeriod {
  final String symbol;
  final double precipMm;
  final double? minTemp;
  final double? maxTemp;

  const WeatherPeriod({
    required this.symbol,
    this.precipMm = 0,
    this.minTemp,
    this.maxTemp,
  });

  static WeatherPeriod? fromMapOrNull(Object? v) {
    if (v is! Map || v['symbol'] == null) return null;
    return WeatherPeriod(
      symbol: v['symbol'] as String,
      precipMm: _num(v['precipMm']) ?? 0,
      minTemp: _num(v['minTemp']),
      maxTemp: _num(v['maxTemp']),
    );
  }
}

/// One SAST calendar day.
class WeatherDay {
  final DateTime date; // civil date, midnight
  final String symbol; // worst MET symbol code during working hours
  final double? minTemp;
  final double? maxTemp;
  final double precipMm; // whole day
  final double workPrecipMm; // 06–18
  final double? workMaxWindMs; // peak mean wind 06–18
  final double? maxWindMs; // peak mean wind, whole day

  /// Night (00–06), morning, afternoon, evening; null where not forecast.
  final List<WeatherPeriod?> periods;

  const WeatherDay({
    required this.date,
    required this.symbol,
    this.minTemp,
    this.maxTemp,
    this.precipMm = 0,
    this.workPrecipMm = 0,
    this.workMaxWindMs,
    this.maxWindMs,
    this.periods = const [null, null, null, null],
  });

  factory WeatherDay.fromMap(Map<String, dynamic> m) => WeatherDay(
        date: DateTime.parse(m['date'] as String),
        symbol: m['symbol'] as String? ?? '',
        minTemp: _num(m['minTemp']),
        maxTemp: _num(m['maxTemp']),
        precipMm: _num(m['precipMm']) ?? 0,
        workPrecipMm: _num(m['workPrecipMm']) ?? 0,
        workMaxWindMs: _num(m['workMaxWindMs']),
        maxWindMs: _num(m['maxWindMs']),
        periods: [
          for (var i = 0; i < 4; i++)
            WeatherPeriod.fromMapOrNull(
                (m['periods'] as List?)?.elementAtOrNull(i)),
        ],
      );

  DistributionRating get distributionRating {
    final wind = workMaxWindMs ?? 0;
    if (workPrecipMm >= DistributionWeatherThresholds.poorRainMm ||
        wind >= DistributionWeatherThresholds.poorWindMs) {
      return DistributionRating.poor;
    }
    if (workPrecipMm >= DistributionWeatherThresholds.marginalRainMm ||
        wind >= DistributionWeatherThresholds.marginalWindMs) {
      return DistributionRating.marginal;
    }
    return DistributionRating.good;
  }
}

/// One forecast period: hourly for the first ~2.5 days, 6-hourly after.
class WeatherStep {
  final DateTime time; // UTC instant at the start of the period
  final int hours;
  final double? temp;
  final double? feelsLike;
  final String symbol;
  final double precipMm;
  final double? windMs;
  final int? windDir; // degrees the wind blows FROM
  final int? humidity; // %
  final int? cloud; // % cover
  final double? uv; // clear-sky UV index

  const WeatherStep({
    required this.time,
    required this.hours,
    required this.symbol,
    this.temp,
    this.feelsLike,
    this.precipMm = 0,
    this.windMs,
    this.windDir,
    this.humidity,
    this.cloud,
    this.uv,
  });

  DateTime get end => time.add(Duration(hours: hours));

  factory WeatherStep.fromMap(Map<String, dynamic> m) => WeatherStep(
        time: DateTime.parse(m['time'] as String),
        hours: (m['hours'] as num?)?.toInt() ?? 1,
        temp: _num(m['temp']),
        symbol: m['symbol'] as String? ?? '',
        precipMm: _num(m['precipMm']) ?? 0,
        windMs: _num(m['windMs']),
        windDir: (m['windDir'] as num?)?.toInt(),
        feelsLike: _num(m['feelsLike']),
        humidity: (m['humidity'] as num?)?.toInt(),
        cloud: (m['cloud'] as num?)?.toInt(),
        uv: _num(m['uv']),
      );
}

class WeatherForecast {
  final double lat;
  final double lon;

  /// When MET last ran the model, and when our server fetched it.
  final DateTime? updatedAt;
  final DateTime? fetchedAt;
  final List<WeatherDay> days;
  final List<WeatherStep> steps;

  const WeatherForecast({
    required this.lat,
    required this.lon,
    required this.days,
    required this.steps,
    this.updatedAt,
    this.fetchedAt,
  });

  factory WeatherForecast.fromMap(Map<String, dynamic> m) {
    List<Map<String, dynamic>> rows(Object? v) => (v as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final updated = m['updatedAt'] as String?;
    final fetched = (m['fetchedAt'] as num?)?.toInt();
    return WeatherForecast(
      lat: _num(m['lat']) ?? 0,
      lon: _num(m['lon']) ?? 0,
      updatedAt: updated == null ? null : DateTime.tryParse(updated),
      fetchedAt: fetched == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(fetched, isUtc: true),
      days: rows(m['days']).map(WeatherDay.fromMap).toList(),
      steps: rows(m['steps']).map(WeatherStep.fromMap).toList(),
    );
  }

  static final _dayKey = DateFormat('yyyy-MM-dd');

  /// The period covering [instant] — "now" for the hero — or the first one.
  WeatherStep? stepAt(DateTime instant) {
    for (final s in steps) {
      if (!instant.isBefore(s.time) && instant.isBefore(s.end)) return s;
    }
    return steps.isEmpty ? null : steps.first;
  }

  /// The forecast for a schedule civil date, or null outside the forecast
  /// range (past days, or more than ~9 days out).
  WeatherDay? dayFor(DateTime civilDate) {
    final key = _dayKey.format(civilDate);
    for (final d in days) {
      if (_dayKey.format(d.date) == key) return d;
    }
    return null;
  }
}
