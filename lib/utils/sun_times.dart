// utils/sun_times.dart
//
// Sunrise / sunset from NOAA's general solar position formulas — accurate to
// about a minute, which is all a forecast needs, with no API call.
import 'dart:math' as math;

import 'schedule_time.dart';

/// Sunrise and sunset on SAST civil date [civilDate] at [lat]/[lon], as SAST
/// civil times. Null when the sun does not rise or set that day (polar).
({DateTime sunrise, DateTime sunset})? sunTimes(
    DateTime civilDate, double lat, double lon) {
  // UTC on both sides so the reader's own DST can't shave an hour off a day.
  final dayOfYear = DateTime.utc(civilDate.year, civilDate.month, civilDate.day)
          .difference(DateTime.utc(civilDate.year, 1, 1))
          .inDays +
      1;
  final g = 2 * math.pi / 365 * (dayOfYear - 1);
  final eqTimeMin = 229.18 *
      (0.000075 +
          0.001868 * math.cos(g) -
          0.032077 * math.sin(g) -
          0.014615 * math.cos(2 * g) -
          0.040849 * math.sin(2 * g));
  final decl = 0.006918 -
      0.399912 * math.cos(g) +
      0.070257 * math.sin(g) -
      0.006758 * math.cos(2 * g) +
      0.000907 * math.sin(2 * g) -
      0.002697 * math.cos(3 * g) +
      0.00148 * math.sin(3 * g);
  final latRad = lat * math.pi / 180;
  // 90.833° = horizon plus refraction and the sun's radius.
  final cosHa =
      math.cos(90.833 * math.pi / 180) / (math.cos(latRad) * math.cos(decl)) -
          math.tan(latRad) * math.tan(decl);
  if (cosHa < -1 || cosHa > 1) return null;
  final haDeg = math.acos(cosHa) * 180 / math.pi;

  final midnightUtc =
      DateTime.utc(civilDate.year, civilDate.month, civilDate.day);
  DateTime at(double utcMinutes) => toScheduleCivil(
      midnightUtc.add(Duration(seconds: (utcMinutes * 60).round())));
  return (
    sunrise: at(720 - 4 * (lon + haDeg) - eqTimeMin),
    sunset: at(720 - 4 * (lon - haDeg) - eqTimeMin),
  );
}
