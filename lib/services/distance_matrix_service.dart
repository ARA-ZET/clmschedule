import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/foundation.dart';
import '../env.dart';
import '../models/address.dart';
import '../models/route_data.dart';

/// Service for getting actual road distances and routes from Google APIs
class DistanceMatrixService {
  static const String _directionsBaseUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  /// Check if we're running on web platform
  bool get isWeb => kIsWeb;

  /// Get route segment data between two addresses using Directions API
  /// This gives us distance, duration, and polyline points for the actual road route
  /// Note: On web, this will fall back to straight-line distance due to CORS restrictions
  Future<RouteSegmentData?> getRouteSegment(
    Address from,
    Address to,
  ) async {
    if (from.latitude == null ||
        from.longitude == null ||
        to.latitude == null ||
        to.longitude == null) {
      debugPrint('Cannot get route segment: addresses not geocoded');
      return null;
    }

    // Skip API call on web due to CORS restrictions
    if (isWeb) {
      debugPrint(
          'Web platform detected - using straight-line distance fallback');
      return _createFallbackSegment(from, to);
    }

    try {
      final origin = '${from.latitude},${from.longitude}';
      final destination = '${to.latitude},${to.longitude}';

      final url = '$_directionsBaseUrl?'
          'origin=$origin&'
          'destination=$destination&'
          'key=${Env.googleMapsApiKey}';

      debugPrint('Requesting directions: $origin -> $destination');

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        debugPrint('API Response status: ${data['status']}');

        if (data['status'] == 'OK' &&
            data['routes'] != null &&
            data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final leg = route['legs'][0];

          // Get distance and duration
          final distanceMeters = (leg['distance']['value'] as num).toDouble();
          final durationSeconds = leg['duration']['value'] as int;

          debugPrint('Got segment: ${distanceMeters}m, ${durationSeconds}s');

          // Decode polyline
          final polylinePoints =
              _decodePolyline(route['overview_polyline']['points']);

          return RouteSegmentData(
            fromAddressId: from.id,
            toAddressId: to.id,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            polylinePoints: polylinePoints,
          );
        } else {
          debugPrint('Directions API error: ${data['status']}');
          if (data['error_message'] != null) {
            debugPrint('Error message: ${data['error_message']}');
          }
          return null;
        }
      } else {
        debugPrint('HTTP error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e, stackTrace) {
      debugPrint('Error getting route segment: $e');
      if (!isWeb) {
        debugPrint('Stack trace: $stackTrace');
      }
      return null;
    }
  }

  /// Get route segments for entire optimized route
  /// Queries Google Directions API for each segment with rate limiting
  /// On web: Uses straight-line distance fallback due to CORS restrictions
  Future<List<RouteSegmentData>> getRouteSegments(
    List<Address> optimizedAddresses, {
    Function(int current, int total)? onProgress,
  }) async {
    final segments = <RouteSegmentData>[];

    if (isWeb) {
      debugPrint(
          'Web platform: Using straight-line distance calculations for ${optimizedAddresses.length - 1} segments');
    }

    for (int i = 0; i < optimizedAddresses.length - 1; i++) {
      final from = optimizedAddresses[i];
      final to = optimizedAddresses[i + 1];

      onProgress?.call(i + 1, optimizedAddresses.length - 1);

      final segment = await getRouteSegment(from, to);

      if (segment != null) {
        segments.add(segment);
        if (!isWeb) {
          debugPrint(
              'Added segment ${i + 1}/${optimizedAddresses.length - 1}: ${segment.distanceMeters}m');
        }
      } else {
        // If API fails, create segment with straight-line distance estimate
        if (!isWeb) {
          debugPrint('API failed for segment ${i + 1}, using fallback');
        }
        final fallback = _createFallbackSegment(from, to);
        segments.add(fallback);
      }

      // Rate limiting: 10 requests per second (only needed for mobile)
      if (!isWeb && i < optimizedAddresses.length - 2) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    debugPrint('Total segments created: ${segments.length}');
    return segments;
  }

  /// Create fallback segment using straight-line distance when API fails
  RouteSegmentData _createFallbackSegment(Address from, Address to) {
    final distance = _calculateStraightLineDistance(
      LatLng(from.latitude!, from.longitude!),
      LatLng(to.latitude!, to.longitude!),
    );

    // Estimate duration: assume 40 km/h average speed
    final durationSeconds = ((distance / 40) * 3600).round();

    return RouteSegmentData(
      fromAddressId: from.id,
      toAddressId: to.id,
      distanceMeters: distance * 1000, // convert km to meters
      durationSeconds: durationSeconds,
      polylinePoints: [
        LatLng(from.latitude!, from.longitude!),
        LatLng(to.latitude!, to.longitude!),
      ],
    );
  }

  /// Calculate straight-line distance using Haversine formula (in kilometers)
  double _calculateStraightLineDistance(LatLng point1, LatLng point2) {
    const earthRadius = 6371.0; // Earth's radius in kilometers

    final lat1Rad = point1.latitude * pi / 180;
    final lat2Rad = point2.latitude * pi / 180;
    final dLat = (point2.latitude - point1.latitude) * pi / 180;
    final dLng = (point2.longitude - point1.longitude) * pi / 180;

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1Rad) * cos(lat2Rad) * sin(dLng / 2) * sin(dLng / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    final distance = earthRadius * c;

    debugPrint('Haversine distance: ${distance.toStringAsFixed(2)} km');
    return distance;
  }

  /// Decode Google polyline encoding to list of LatLng points
  List<LatLng> _decodePolyline(String encoded) {
    final List<LatLng> points = [];
    int index = 0;
    int len = encoded.length;
    int lat = 0;
    int lng = 0;

    while (index < len) {
      int shift = 0;
      int result = 0;
      int byte;

      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);

      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;

      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);

      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return points;
  }
}
