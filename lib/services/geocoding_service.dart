import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../env.dart';

/// Service for geocoding addresses using Google Geocoding API
class GeocodingService {
  static const String _baseUrl =
      'https://maps.googleapis.com/maps/api/geocode/json';

  /// Geocode an address string to latitude/longitude
  /// Returns a map with 'lat' and 'lng' keys, or null if geocoding fails
  Future<Map<String, double>?> geocodeAddress(String address) async {
    try {
      final encodedAddress = Uri.encodeComponent(address);
      final url =
          '$_baseUrl?address=$encodedAddress&key=${Env.googleMapsApiKey}';

      debugPrint('🌍 Geocoding: $address');

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['status'] == 'OK' &&
            data['results'] != null &&
            data['results'].isNotEmpty) {
          final location = data['results'][0]['geometry']['location'];
          final lat = location['lat'] as double;
          final lng = location['lng'] as double;

          debugPrint('✅ Geocoded: $lat, $lng');
          return {'lat': lat, 'lng': lng};
        } else {
          debugPrint('⚠️ Geocoding failed: ${data['status']}');
          return null;
        }
      } else {
        debugPrint('❌ HTTP error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Geocoding error: $e');
      return null;
    }
  }

  /// Batch geocode multiple addresses with delay to respect API limits
  /// Google Geocoding API has a limit of ~50 requests per second
  Future<List<Map<String, dynamic>>> batchGeocode(
    List<String> addresses, {
    Duration delay = const Duration(milliseconds: 200),
    Function(int current, int total)? onProgress,
  }) async {
    final results = <Map<String, dynamic>>[];

    for (int i = 0; i < addresses.length; i++) {
      final address = addresses[i];
      final result = await geocodeAddress(address);

      results.add({
        'address': address,
        'index': i,
        'result': result,
        'success': result != null,
      });

      // Report progress
      onProgress?.call(i + 1, addresses.length);

      // Delay between requests to respect rate limits
      if (i < addresses.length - 1) {
        await Future.delayed(delay);
      }
    }

    return results;
  }
}
