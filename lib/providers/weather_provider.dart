import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/weather_forecast.dart';
import '../services/weather_service.dart';
import 'dropsheet_task_config_provider.dart';
import 'schedule_provider.dart';

final weatherServiceRiverpod =
    riverpod.Provider<WeatherService>((ref) => WeatherService());

/// A place a forecast can be shown for.
class WeatherLocation {
  final String id;
  final String name;
  final double lat;
  final double lon;

  const WeatherLocation(this.id, this.name, this.lat, this.lon);

  /// Forecasts are cached server-side per ~1 km cell, so keying the provider
  /// on 2-decimal coordinates keeps two nearby places on one fetch.
  ({double lat, double lon}) get key => (
        lat: (lat * 100).roundToDouble() / 100,
        lon: (lon * 100).roundToDouble() / 100,
      );
}

/// Central Cape Town, used until the depot address has been geocoded.
const _capeTown = WeatherLocation('cape_town', 'Cape Town', -33.925, 18.425);

/// The depot (where every distribution day starts), or Cape Town when the
/// depot has no coordinates yet. The schedule headers forecast here.
final depotWeatherLocationRiverpod = riverpod.Provider<WeatherLocation>((ref) {
  final depot = ref.watch(dropsheetTaskConfigRiverpod.select((c) => c.depot));
  if (!depot.hasCoordinates) return _capeTown;
  return WeatherLocation('depot', 'Depot', depot.lat!, depot.lng!);
});

/// Depot first, then every work suburb at the average of its outline, A–Z.
final weatherLocationsRiverpod =
    riverpod.Provider<List<WeatherLocation>>((ref) {
  final depot = ref.watch(depotWeatherLocationRiverpod);
  final suburbs = ref.watch(scheduleRiverpod.select((s) => s.workSuburbs));
  final places = <WeatherLocation>[];
  for (final s in suburbs) {
    if (s.polygonPoints.isEmpty || s.name.trim().isEmpty) continue;
    var lat = 0.0;
    var lon = 0.0;
    for (final p in s.polygonPoints) {
      lat += p.latitude;
      lon += p.longitude;
    }
    final n = s.polygonPoints.length;
    places.add(WeatherLocation(s.id, s.name.trim(), lat / n, lon / n));
  }
  places.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [depot, ...places];
});

/// Forecast for a 2-decimal coordinate. Held for [_freshFor] and then
/// refetched — the schedule grid stays open all day, and MET updates roughly
/// hourly (the server caches until MET's `Expires`, so this is cheap). With
/// no one watching any more, the refresh just lets it dispose.
final weatherForecastRiverpod = riverpod.FutureProvider.autoDispose
    .family<WeatherForecast, ({double lat, double lon})>((ref, at) async {
  ref.keepAlive();
  final refresh = Timer(_freshFor, ref.invalidateSelf);
  ref.onDispose(refresh.cancel);
  try {
    return await ref.watch(weatherServiceRiverpod).forecast(at.lat, at.lon);
  } catch (e) {
    // The schedule grid watches this for as long as it is open, so an error
    // would otherwise stick until restart — retry after [_retryDelay].
    debugPrint('[Weather] ${at.lat},${at.lon} failed: $e '
        '— retrying in ${_retryDelay.inSeconds}s');
    final retry = Timer(_retryDelay, ref.invalidateSelf);
    ref.onDispose(retry.cancel);
    rethrow;
  }
});

/// The depot forecast, for the schedule's day headers.
final scheduleWeatherRiverpod =
    riverpod.Provider.autoDispose<WeatherForecast?>((ref) {
  final at = ref.watch(depotWeatherLocationRiverpod).key;
  return ref.watch(weatherForecastRiverpod(at)).valueOrNull;
});

const Duration _freshFor = Duration(minutes: 30);
const Duration _retryDelay = Duration(seconds: 60);
