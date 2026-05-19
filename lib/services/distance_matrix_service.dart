import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/foundation.dart';
import '../env.dart';
import '../models/address.dart';
import '../models/route_data.dart';
import 'directions_web_stub.dart'
    if (dart.library.js_interop) 'directions_web.dart' as web_directions;

/// Service for getting actual road distances and routes from Google APIs
class DistanceMatrixService {
  static const String _directionsBaseUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  /// In-memory LRU cache for route segment lookups. Key encodes the
  /// origin/destination pair plus the departure time-of-day bucket so
  /// traffic-aware results aren't reused across very different times.
  /// Using a [LinkedHashMap] (default Dart Map) gives us O(1) eviction
  /// of the oldest entry.
  static const int _cacheCapacity = 500;
  final Map<String, RouteSegmentData> _segmentCache = {};

  String _cacheKeyFor(Address from, Address to, DateTime? departure) {
    final bucket = departure == null
        ? 'none'
        : '${departure.hour}:${(departure.minute ~/ 15) * 15}';
    return '${from.id}|${to.id}|$bucket';
  }

  void _cacheStore(String key, RouteSegmentData data) {
    _segmentCache.remove(key);
    _segmentCache[key] = data;
    if (_segmentCache.length > _cacheCapacity) {
      _segmentCache.remove(_segmentCache.keys.first);
    }
  }

  /// Check if we're running on web platform
  bool get isWeb => kIsWeb;

  /// Get route segment data between two addresses using Directions API
  /// This gives us distance, duration, and polyline points for the actual road route
  /// Note: On web, this will fall back to straight-line distance due to CORS restrictions
  ///
  /// When [departureTime] is provided and lies in the future, the
  /// Directions API is queried with `departure_time` + `traffic_model`,
  /// and the response's `duration_in_traffic` is captured on the
  /// returned [RouteSegmentData.durationInTrafficSeconds]. Past or null
  /// timestamps fall back to a free-flow query.
  Future<RouteSegmentData?> getRouteSegment(
    Address from,
    Address to, {
    DateTime? departureTime,
    String trafficModel = 'best_guess',
  }) async {
    if (from.latitude == null ||
        from.longitude == null ||
        to.latitude == null ||
        to.longitude == null) {
      debugPrint('Cannot get route segment: addresses not geocoded');
      return null;
    }

    // LRU cache check — same origin/destination/time bucket reuses the
    // last result rather than spending another Directions API call.
    final cacheKey = _cacheKeyFor(from, to, departureTime);
    final cached = _segmentCache.remove(cacheKey);
    if (cached != null) {
      _segmentCache[cacheKey] = cached; // move to MRU position
      return cached;
    }

    // On web the REST Directions endpoint is blocked by CORS, so we
    // delegate to the Google Maps JS DirectionsService via JS interop.
    // That gives us real road distances, durations, traffic-aware ETAs
    // and polylines without a backend proxy.
    if (isWeb) {
      final webResult = await web_directions.getRouteSegmentWeb(
        from,
        to,
        departureTime: departureTime,
      );
      if (webResult != null) {
        _cacheStore(cacheKey, webResult);
        return webResult;
      }
      debugPrint(
          'Web DirectionsService unavailable - using Haversine fallback');
      return _createFallbackSegment(from, to);
    }

    try {
      final origin = '${from.latitude},${from.longitude}';
      final destination = '${to.latitude},${to.longitude}';

      // Google requires `departure_time` to be a future epoch to return
      // `duration_in_traffic`. Advance to the next future occurrence of the
      // same time-of-day so the API applies realistic historical traffic for
      // the scheduled hour even when that time has already passed today.
      DateTime? effectiveDeparture = departureTime;
      if (effectiveDeparture != null) {
        final now = DateTime.now();
        while (effectiveDeparture!.isBefore(now)) {
          effectiveDeparture = effectiveDeparture.add(const Duration(days: 1));
        }
      }

      final params = <String, String>{
        'origin': origin,
        'destination': destination,
        'alternatives': 'true',
        'key': Env.googleMapsApiKey,
      };
      if (effectiveDeparture != null) {
        params['departure_time'] =
            (effectiveDeparture.millisecondsSinceEpoch ~/ 1000).toString();
        params['traffic_model'] = trafficModel;
      }
      final url = Uri.parse(_directionsBaseUrl).replace(
        queryParameters: params,
      );

      debugPrint(
          'Requesting directions: $origin -> $destination dep=${effectiveDeparture?.toIso8601String() ?? '-'}');

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        debugPrint('API Response status: ${data['status']}');

        if (data['status'] == 'OK' &&
            data['routes'] != null &&
            data['routes'].isNotEmpty) {
          // Pick the route with the shortest distance across all alternatives.
          final routes = data['routes'] as List;
          Map<String, dynamic> bestRoute = routes[0] as Map<String, dynamic>;
          double bestDist =
              ((bestRoute['legs'][0]['distance']['value']) as num).toDouble();
          for (final r in routes.skip(1)) {
            final d = ((r['legs'][0]['distance']['value']) as num).toDouble();
            if (d < bestDist) {
              bestDist = d;
              bestRoute = r as Map<String, dynamic>;
            }
          }
          final route = bestRoute;
          final leg = route['legs'][0];

          // Get distance and duration
          final distanceMeters = (leg['distance']['value'] as num).toDouble();
          final durationSeconds = (leg['duration']['value'] as num).toInt();
          final trafficSeconds = (leg['duration_in_traffic'] != null)
              ? (leg['duration_in_traffic']['value'] as num).toInt()
              : durationSeconds;

          debugPrint(
              'Got segment: ${distanceMeters}m, ${durationSeconds}s (traffic: ${trafficSeconds}s)');

          // Decode polyline. For large encoded strings (long routes) we
          // run the bit-shift decode in a background isolate via
          // `compute()` to keep the main thread free of jank.
          final encoded = route['overview_polyline']['points'] as String;
          final polylinePoints = encoded.length > 1000
              ? await compute(_decodePolylineIsolate, encoded)
              : _decodePolyline(encoded);

          final segment = RouteSegmentData(
            fromAddressId: from.id,
            toAddressId: to.id,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            durationInTrafficSeconds: trafficSeconds,
            polylinePoints: polylinePoints,
          );
          _cacheStore(cacheKey, segment);
          return segment;
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

/// Top-level wrapper for [compute] — Dart isolates can only run
/// top-level / static functions. Decodes a Google encoded polyline
/// string off the main thread.
List<LatLng> _decodePolylineIsolate(String encoded) {
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
