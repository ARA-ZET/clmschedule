// Web implementation calling the Google Maps JS DirectionsService via
// JS interop. This avoids the CORS restrictions that block the REST
// Directions API from the browser, so on web we still get real road
// distances, durations, traffic-aware ETAs and polylines.

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

/// Returns a [RouteSegmentData] computed by the JS Directions service,
/// or null if the call fails (no route, JS not loaded, etc.).
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

  final epochSec = departureTime == null
      ? 0
      : (departureTime.millisecondsSinceEpoch ~/ 1000);

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

    final distanceMeters =
        (result.getProperty('distanceMeters'.toJS) as JSNumber).toDartDouble;
    final durationSeconds =
        (result.getProperty('durationSeconds'.toJS) as JSNumber)
            .toDartDouble
            .round();
    final trafficSeconds =
        (result.getProperty('durationInTrafficSeconds'.toJS) as JSNumber)
            .toDartDouble
            .round();
    final pathArr = result.getProperty('path'.toJS) as JSArray<JSObject>;
    final path = <LatLng>[];
    for (final p in pathArr.toDart) {
      final lat = (p.getProperty('lat'.toJS) as JSNumber).toDartDouble;
      final lng = (p.getProperty('lng'.toJS) as JSNumber).toDartDouble;
      path.add(LatLng(lat, lng));
    }

    return RouteSegmentData(
      fromAddressId: from.id,
      toAddressId: to.id,
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      durationInTrafficSeconds: trafficSeconds,
      polylinePoints: path,
    );
  } catch (e) {
    debugPrint('Web directions failed: $e');
    return null;
  }
}
