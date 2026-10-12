// Stub for non-web platforms. The web implementation lives in
// directions_web.dart and is selected via conditional import.

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/address.dart';
import '../models/route_data.dart';

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

class DirectionsMultiResult {
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

Future<RouteSegmentData?> getRouteSegmentWeb(
  Address from,
  Address to, {
  DateTime? departureTime,
}) async =>
    null;

Future<DirectionsMultiResult?> getOptimizedRouteWeb(
  List<LatLng> stops, {
  DateTime? departureTime,
  bool optimize = true,
  bool roundTrip = false,
}) async =>
    null;
