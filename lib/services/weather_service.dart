// services/weather_service.dart
//
// Fetches forecasts through the `weatherForecast` callable, which proxies and
// caches MET Norway (yr.no's data) — MET asks that apps never call it
// directly. See functions/lib/weather_proxy.js.
import 'package:cloud_functions/cloud_functions.dart';

import '../models/weather_forecast.dart';

class WeatherService {
  final FirebaseFunctions _functions;

  WeatherService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  Future<WeatherForecast> forecast(double lat, double lon) async {
    final result = await _functions
        .httpsCallable('weatherForecast',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 40)))
        .call<dynamic>({'lat': lat, 'lon': lon});
    final data = result.data;
    if (data is! Map) {
      throw StateError('Unexpected weather response: $data');
    }
    return WeatherForecast.fromMap(Map<String, dynamic>.from(data));
  }
}
