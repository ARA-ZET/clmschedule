import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/address.dart';
import '../models/route_data.dart';

/// Thin wrapper around the server-side Day Planner / Dropsheet
/// performance offload Cloud Functions:
///
///   - getRouteSegment            (shared Distance Matrix cache)
///   - optimizeDropsheetRoute     (server-side route optimisation)
///   - syncDropsheetFromSchedule  (callable dropsheet sync)
///
/// Each function is exposed as an opt-in entry point so existing
/// client-side code keeps working unchanged. Callers who want the
/// reduced-latency / shared-cache behaviour can swap in these methods.
class DayPlannerCloudFunctions {
  DayPlannerCloudFunctions({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  /// Shared Distance Matrix lookup. Returns the same shape as
  /// [DistanceMatrixService.getRouteSegment] minus the polyline (which
  /// the server returns as an encoded string to keep payloads small;
  /// decode it on demand if needed).
  Future<RouteSegmentData?> getRouteSegment(
    Address from,
    Address to, {
    DateTime? departureTime,
  }) async {
    if (from.latitude == null ||
        from.longitude == null ||
        to.latitude == null ||
        to.longitude == null) {
      return null;
    }
    try {
      final result = await _functions
          .httpsCallable('getRouteSegment')
          .call<Map<String, dynamic>>({
        'fromLat': from.latitude,
        'fromLng': from.longitude,
        'toLat': to.latitude,
        'toLng': to.longitude,
        if (departureTime != null)
          'departureTime': departureTime.toUtc().toIso8601String(),
      });
      final data = result.data;
      final polylinePoints = <LatLng>[];
      // The server returns an encoded polyline; decode on the client
      // only when present (caller can ignore it if unneeded).
      final encoded = data['encodedPolyline'] as String?;
      if (encoded != null && encoded.isNotEmpty) {
        polylinePoints.addAll(_decodePolyline(encoded));
      }
      return RouteSegmentData(
        fromAddressId: from.id,
        toAddressId: to.id,
        distanceMeters: (data['distanceMeters'] as num).toDouble(),
        durationSeconds: (data['durationSeconds'] as num).toInt(),
        durationInTrafficSeconds:
            (data['durationInTrafficSeconds'] as num?)?.toInt() ??
                (data['durationSeconds'] as num).toInt(),
        polylinePoints: polylinePoints,
      );
    } catch (e) {
      debugPrint('getRouteSegment cloud call failed: $e');
      return null;
    }
  }

  /// Run the greedy nearest-neighbour route optimiser server-side and
  /// return the resulting order, ETAs, leg data and combined polyline.
  ///
  /// [stops] entries must include `taskId`, `role` ('single' | 'loading'
  /// | 'offload'), `lat`, `lng`, `serviceMinutes`, and a unique
  /// `stopKey`. Mirrors the client-side [DropsheetRoutePlanner] payload.
  Future<Map<String, dynamic>?> optimizeDropsheetRoute({
    required List<Map<String, dynamic>> stops,
    required Map<String, dynamic> depot,
    required DateTime baseDate,
    String? startTime,
  }) async {
    try {
      final result = await _functions
          .httpsCallable('optimizeDropsheetRoute')
          .call<Map<String, dynamic>>({
        'stops': stops,
        'depot': depot,
        'baseDate':
            '${baseDate.year.toString().padLeft(4, '0')}-${baseDate.month.toString().padLeft(2, '0')}-${baseDate.day.toString().padLeft(2, '0')}',
        if (startTime != null) 'startTime': startTime,
      });
      return result.data;
    } catch (e) {
      debugPrint('optimizeDropsheetRoute cloud call failed: $e');
      return null;
    }
  }

  /// Trigger a server-side dropsheet sync for the given date. The
  /// dropsheet doc is rewritten in Firestore; the existing client
  /// stream listener will pick up the change automatically.
  Future<bool> syncDropsheetFromSchedule(DateTime date) async {
    final dateId =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    try {
      await _functions
          .httpsCallable('syncDropsheetFromSchedule')
          .call<Map<String, dynamic>>({'dateId': dateId});
      return true;
    } catch (e) {
      debugPrint('syncDropsheetFromSchedule cloud call failed: $e');
      return false;
    }
  }

  /// Local fallback decoder for the server's encoded polyline. Mirrors
  /// the algorithm used inside [DistanceMatrixService] so polyline
  /// data round-trips losslessly.
  List<LatLng> _decodePolyline(String encoded) {
    final List<LatLng> points = [];
    int index = 0;
    final int len = encoded.length;
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
      final dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;
      shift = 0;
      result = 0;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      final dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;
      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }
}
