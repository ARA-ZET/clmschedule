import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Represents a segment of a delivery route between two addresses
class RouteSegmentData {
  final String fromAddressId;
  final String toAddressId;
  final double distanceMeters;
  final int durationSeconds;

  /// Traffic-aware duration in seconds at the queried departure time.
  /// Falls back to [durationSeconds] when no `departure_time` was passed
  /// to the Directions API or when traffic data is unavailable.
  final int durationInTrafficSeconds;
  final List<LatLng> polylinePoints;

  RouteSegmentData({
    required this.fromAddressId,
    required this.toAddressId,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.polylinePoints,
    int? durationInTrafficSeconds,
  }) : durationInTrafficSeconds = durationInTrafficSeconds ?? durationSeconds;

  /// Get distance in kilometers
  double get distanceKm => distanceMeters / 1000;

  /// Get duration as formatted string (e.g., "5 mins", "1 hr 30 mins")
  String get durationFormatted {
    final hours = durationSeconds ~/ 3600;
    final minutes = (durationSeconds % 3600) ~/ 60;

    if (hours > 0) {
      return minutes > 0 ? '$hours hr $minutes mins' : '$hours hr';
    }
    return '$minutes mins';
  }

  /// Create from Firestore map
  factory RouteSegmentData.fromMap(Map<String, dynamic> data) {
    final polylineData = data['polylinePoints'] as List<dynamic>? ?? [];
    final polylinePoints = polylineData
        .map((point) => LatLng(
              (point['lat'] as num).toDouble(),
              (point['lng'] as num).toDouble(),
            ))
        .toList();

    return RouteSegmentData(
      fromAddressId: data['fromAddressId'] ?? '',
      toAddressId: data['toAddressId'] ?? '',
      distanceMeters: (data['distanceMeters'] as num?)?.toDouble() ?? 0.0,
      durationSeconds: (data['durationSeconds'] as num?)?.toInt() ?? 0,
      durationInTrafficSeconds:
          (data['durationInTrafficSeconds'] as num?)?.toInt(),
      polylinePoints: polylinePoints,
    );
  }

  /// Convert to Firestore map
  Map<String, dynamic> toMap() {
    return {
      'fromAddressId': fromAddressId,
      'toAddressId': toAddressId,
      'distanceMeters': distanceMeters,
      'durationSeconds': durationSeconds,
      'durationInTrafficSeconds': durationInTrafficSeconds,
      'polylinePoints': polylinePoints
          .map((point) => {
                'lat': point.latitude,
                'lng': point.longitude,
              })
          .toList(),
    };
  }
}

/// Complete route data for a suburb with all segments
class SuburbRouteData {
  final String suburb;
  final String algorithm; // 'nearest_neighbor' or '2opt'
  final DateTime optimizedAt;
  final List<RouteSegmentData> segments;
  final double totalDistanceMeters;
  final int totalDurationSeconds;

  SuburbRouteData({
    required this.suburb,
    required this.algorithm,
    required this.optimizedAt,
    required this.segments,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
  });

  /// Get total distance in kilometers
  double get totalDistanceKm => totalDistanceMeters / 1000;

  /// Get total duration as formatted string
  String get totalDurationFormatted {
    final hours = totalDurationSeconds ~/ 3600;
    final minutes = (totalDurationSeconds % 3600) ~/ 60;

    if (hours > 0) {
      return minutes > 0 ? '$hours hr $minutes mins' : '$hours hr';
    }
    return '$minutes mins';
  }

  /// Create from Firestore map
  factory SuburbRouteData.fromMap(Map<String, dynamic> data) {
    final segmentsData = data['segments'] as List<dynamic>? ?? [];
    final segments = segmentsData
        .map((seg) => RouteSegmentData.fromMap(Map<String, dynamic>.from(seg as Map)))
        .toList();

    return SuburbRouteData(
      suburb: data['suburb'] ?? '',
      algorithm: data['algorithm'] ?? 'nearest_neighbor',
      optimizedAt: data['optimizedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['optimizedAt'])
          : DateTime.now(),
      segments: segments,
      totalDistanceMeters:
          (data['totalDistanceMeters'] as num?)?.toDouble() ?? 0.0,
      totalDurationSeconds: (data['totalDurationSeconds'] as num?)?.toInt() ?? 0,
    );
  }

  /// Convert to Firestore map
  Map<String, dynamic> toMap() {
    return {
      'suburb': suburb,
      'algorithm': algorithm,
      'optimizedAt': optimizedAt.millisecondsSinceEpoch,
      'segments': segments.map((seg) => seg.toMap()).toList(),
      'totalDistanceMeters': totalDistanceMeters,
      'totalDurationSeconds': totalDurationSeconds,
    };
  }
}
