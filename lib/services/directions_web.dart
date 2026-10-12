// Web implementation calling the Google Maps JS DirectionsService via
// JS interop. This avoids the CORS restrictions that block the REST
// Directions API from the browser, so on web we still get real road
// distances, durations, traffic-aware ETAs and polylines.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/address.dart';
import '../models/route_data.dart';

@JS('directionsRoute')
external JSPromise<JSObject?> _directionsRoute(
  JSNumber originLat,
  JSNumber originLng,
  JSNumber destLat,
  JSNumber destLng,
  JSNumber departureEpochSec,
);

@JS('directionsRouteOptimized')
external JSPromise<JSObject?> _directionsRouteOptimized(
  JSString stopsJson,
  JSNumber departureEpochSec,
  JSBoolean optimize,
  JSBoolean roundTrip,
);

/// One leg of a multi-stop directions response.
class DirectionsLeg {
  final double distanceMeters;
  final int durationSeconds;
  final int durationInTrafficSeconds;
  final List<LatLng> path;

  const DirectionsLeg({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.durationInTrafficSeconds,
    required this.path,
  });
}

/// Result of one multi-stop Directions request.
class DirectionsMultiResult {
  /// Order Google chose for the *intermediate* waypoints, as indices into
  /// the intermediate list that was sent (empty when not optimising).
  final List<int> waypointOrder;
  final List<DirectionsLeg> legs;
  final double totalDistanceMeters;
  final int totalDurationSeconds;
  final int totalDurationInTrafficSeconds;

  const DirectionsMultiResult({
    required this.waypointOrder,
    required this.legs,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.totalDurationInTrafficSeconds,
  });
}

List<LatLng> _readPath(JSObject holder) {
  final arr = holder.getProperty('path'.toJS) as JSArray<JSObject>?;
  if (arr == null) return const [];
  return [
    for (final p in arr.toDart)
      LatLng(
        (p.getProperty('lat'.toJS) as JSNumber).toDartDouble,
        (p.getProperty('lng'.toJS) as JSNumber).toDartDouble,
      ),
  ];
}

/// Returns a [RouteSegmentData] computed by the JS Directions service,
/// or null if the call fails (no route, JS not loaded, timed out).
Future<RouteSegmentData?> getRouteSegmentWeb(
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

  final epochSec =
      departureTime == null ? 0 : (departureTime.millisecondsSinceEpoch ~/ 1000);

  try {
    final result = await _directionsRoute(
      from.latitude!.toJS,
      from.longitude!.toJS,
      to.latitude!.toJS,
      to.longitude!.toJS,
      epochSec.toJS,
    ).toDart;

    if (result == null) {
      debugPrint('Web directions: null result for ${from.id} -> ${to.id}');
      return null;
    }

    return RouteSegmentData(
      fromAddressId: from.id,
      toAddressId: to.id,
      distanceMeters:
          (result.getProperty('distanceMeters'.toJS) as JSNumber).toDartDouble,
      durationSeconds:
          (result.getProperty('durationSeconds'.toJS) as JSNumber)
              .toDartDouble
              .round(),
      durationInTrafficSeconds:
          (result.getProperty('durationInTrafficSeconds'.toJS) as JSNumber)
              .toDartDouble
              .round(),
      polylinePoints: _readPath(result),
    );
  } catch (e) {
    debugPrint('Web directions failed: $e');
    return null;
  }
}

/// Route through [stops] in one Directions request.
///
/// The first entry is the origin and — unless [roundTrip] — the last is
/// the destination; everything between is sent as a waypoint. With
/// [optimize] set, Google reorders those intermediate waypoints using
/// real road distances, which is both better and vastly cheaper than
/// asking for every pairwise leg separately.
///
/// Returns null when the helper is unreachable or the request failed.
Future<DirectionsMultiResult?> getOptimizedRouteWeb(
  List<LatLng> stops, {
  DateTime? departureTime,
  bool optimize = true,
  bool roundTrip = false,
}) async {
  if (stops.length < 2) return null;

  final epochSec =
      departureTime == null ? 0 : (departureTime.millisecondsSinceEpoch ~/ 1000);
  final payload = jsonEncode([
    for (final s in stops) {'lat': s.latitude, 'lng': s.longitude},
  ]);

  try {
    final result = await _directionsRouteOptimized(
      payload.toJS,
      epochSec.toJS,
      optimize.toJS,
      roundTrip.toJS,
    ).toDart;

    if (result == null) {
      debugPrint('Web optimized directions: helper unavailable');
      return null;
    }
    final ok = (result.getProperty('ok'.toJS) as JSBoolean?)?.toDart ?? false;
    if (!ok) {
      final status =
          (result.getProperty('status'.toJS) as JSString?)?.toDart ?? 'UNKNOWN';
      debugPrint('Web optimized directions failed: $status');
      return null;
    }

    final orderArr =
        result.getProperty('waypointOrder'.toJS) as JSArray<JSNumber>?;
    final order = <int>[
      for (final n in (orderArr?.toDart ?? const <JSNumber>[]))
        n.toDartDouble.round(),
    ];

    final legsArr = result.getProperty('legs'.toJS) as JSArray<JSObject>?;
    final legs = <DirectionsLeg>[
      for (final l in (legsArr?.toDart ?? const <JSObject>[]))
        DirectionsLeg(
          distanceMeters:
              (l.getProperty('distanceMeters'.toJS) as JSNumber).toDartDouble,
          durationSeconds: (l.getProperty('durationSeconds'.toJS) as JSNumber)
              .toDartDouble
              .round(),
          durationInTrafficSeconds:
              (l.getProperty('durationInTrafficSeconds'.toJS) as JSNumber)
                  .toDartDouble
                  .round(),
          path: _readPath(l),
        ),
    ];

    return DirectionsMultiResult(
      waypointOrder: order,
      legs: legs,
      totalDistanceMeters:
          (result.getProperty('totalDistanceMeters'.toJS) as JSNumber)
              .toDartDouble,
      totalDurationSeconds:
          (result.getProperty('totalDurationSeconds'.toJS) as JSNumber)
              .toDartDouble
              .round(),
      totalDurationInTrafficSeconds:
          (result.getProperty('totalDurationInTrafficSeconds'.toJS) as JSNumber)
              .toDartDouble
              .round(),
    );
  } catch (e) {
    debugPrint('Web optimized directions threw: $e');
    return null;
  }
}
