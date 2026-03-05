import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/address.dart';

/// Service for optimizing delivery routes using various algorithms
class RouteOptimizationService {
  /// Calculate distance between two coordinates using Haversine formula (in kilometers)
  double calculateDistance(LatLng point1, LatLng point2) {
    const earthRadius = 6371.0; // Earth's radius in kilometers

    final lat1Rad = point1.latitude * pi / 180;
    final lat2Rad = point2.latitude * pi / 180;
    final dLat = (point2.latitude - point1.latitude) * pi / 180;
    final dLng = (point2.longitude - point1.longitude) * pi / 180;

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1Rad) * cos(lat2Rad) * sin(dLng / 2) * sin(dLng / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadius * c;
  }

  /// Build a distance matrix for all addresses
  List<List<double>> buildDistanceMatrix(List<Address> addresses) {
    final n = addresses.length;
    final matrix = List.generate(n, (_) => List.filled(n, 0.0));

    for (int i = 0; i < n; i++) {
      for (int j = 0; j < n; j++) {
        if (i != j) {
          final point1 =
              LatLng(addresses[i].latitude!, addresses[i].longitude!);
          final point2 =
              LatLng(addresses[j].latitude!, addresses[j].longitude!);
          matrix[i][j] = calculateDistance(point1, point2);
        }
      }
    }

    return matrix;
  }

  /// Optimize route using Nearest Neighbor algorithm
  /// Returns optimized sequence of addresses and total distance
  OptimizedRoute optimizeRouteNearestNeighbor(
    List<Address> addresses, {
    Address? startPoint,
  }) {
    if (addresses.isEmpty) {
      return OptimizedRoute(
        addresses: [],
        totalDistance: 0,
        strategy: 'Nearest Neighbor',
      );
    }

    if (addresses.length == 1) {
      return OptimizedRoute(
        addresses: addresses,
        totalDistance: 0,
        strategy: 'Nearest Neighbor',
      );
    }

    final distanceMatrix = buildDistanceMatrix(addresses);
    final visited = List.filled(addresses.length, false);
    final route = <Address>[];
    double totalDistance = 0;

    // Find starting point index
    int currentIndex = 0;
    if (startPoint != null) {
      currentIndex = addresses.indexWhere((a) => a.id == startPoint.id);
      if (currentIndex == -1) currentIndex = 0;
    }

    route.add(addresses[currentIndex]);
    visited[currentIndex] = true;

    // Visit nearest unvisited neighbor
    for (int i = 1; i < addresses.length; i++) {
      double minDistance = double.infinity;
      int nearestIndex = -1;

      for (int j = 0; j < addresses.length; j++) {
        if (!visited[j] && distanceMatrix[currentIndex][j] < minDistance) {
          minDistance = distanceMatrix[currentIndex][j];
          nearestIndex = j;
        }
      }

      if (nearestIndex != -1) {
        route.add(addresses[nearestIndex]);
        visited[nearestIndex] = true;
        totalDistance += minDistance;
        currentIndex = nearestIndex;
      }
    }

    return OptimizedRoute(
      addresses: route,
      totalDistance: totalDistance,
      strategy: 'Nearest Neighbor',
    );
  }

  /// Optimize route using 2-Opt algorithm (improved over nearest neighbor)
  /// This attempts to remove crossing paths
  OptimizedRoute optimizeRoute2Opt(
    List<Address> addresses, {
    Address? startPoint,
  }) {
    // Start with nearest neighbor solution
    var currentRoute =
        optimizeRouteNearestNeighbor(addresses, startPoint: startPoint);
    var improved = true;
    var route = List<Address>.from(currentRoute.addresses);

    final distanceMatrix = buildDistanceMatrix(addresses);
    final indexMap = <String, int>{};
    for (int i = 0; i < addresses.length; i++) {
      indexMap[addresses[i].id] = i;
    }

    // Keep improving until no more improvements found
    while (improved) {
      improved = false;

      for (int i = 1; i < route.length - 1; i++) {
        for (int j = i + 1; j < route.length; j++) {
          // Calculate current distance
          final idx1 = indexMap[route[i - 1].id]!;
          final idx2 = indexMap[route[i].id]!;
          final idx3 = indexMap[route[j].id]!;
          final idx4 = j + 1 < route.length ? indexMap[route[j + 1].id]! : idx1;

          final currentDist = distanceMatrix[idx1][idx2] +
              (j + 1 < route.length ? distanceMatrix[idx3][idx4] : 0);

          // Calculate new distance if we reverse the segment
          final newDist = distanceMatrix[idx1][idx3] +
              (j + 1 < route.length ? distanceMatrix[idx2][idx4] : 0);

          if (newDist < currentDist) {
            // Reverse the segment from i to j
            final segment = route.sublist(i, j + 1).reversed.toList();
            route.replaceRange(i, j + 1, segment);
            improved = true;
          }
        }
      }
    }

    // Recalculate total distance
    double totalDistance = 0;
    for (int i = 0; i < route.length - 1; i++) {
      final idx1 = indexMap[route[i].id]!;
      final idx2 = indexMap[route[i + 1].id]!;
      totalDistance += distanceMatrix[idx1][idx2];
    }

    return OptimizedRoute(
      addresses: route,
      totalDistance: totalDistance,
      strategy: '2-Opt Algorithm',
    );
  }

  /// Calculate route segments with distances
  List<RouteSegment> calculateRouteSegments(List<Address> route) {
    final segments = <RouteSegment>[];

    for (int i = 0; i < route.length - 1; i++) {
      final from = route[i];
      final to = route[i + 1];
      final distance = calculateDistance(
        LatLng(from.latitude!, from.longitude!),
        LatLng(to.latitude!, to.longitude!),
      );

      segments.add(RouteSegment(
        from: from,
        to: to,
        distance: distance,
        order: i + 1,
      ));
    }

    return segments;
  }

  /// Estimate delivery time based on distance and average speed
  Duration estimateDeliveryTime(
    double totalDistanceKm, {
    double averageSpeedKmh = 40, // Default 40 km/h in urban areas
    int stopTimeMinutes = 5, // Time per stop for delivery
    int numberOfStops = 1,
  }) {
    final drivingTimeHours = totalDistanceKm / averageSpeedKmh;
    final drivingTimeMinutes = (drivingTimeHours * 60).round();
    final totalStopTime = stopTimeMinutes * numberOfStops;

    return Duration(minutes: drivingTimeMinutes + totalStopTime);
  }

  /// Get route statistics
  RouteStatistics getRouteStatistics(OptimizedRoute route) {
    final segments = calculateRouteSegments(route.addresses);

    double longestSegment = 0;
    double shortestSegment = double.infinity;

    for (final segment in segments) {
      if (segment.distance > longestSegment) {
        longestSegment = segment.distance;
      }
      if (segment.distance < shortestSegment) {
        shortestSegment = segment.distance;
      }
    }

    final estimatedTime = estimateDeliveryTime(
      route.totalDistance,
      numberOfStops: route.addresses.length,
    );

    return RouteStatistics(
      totalDistance: route.totalDistance,
      numberOfStops: route.addresses.length,
      averageDistanceBetweenStops: route.addresses.length > 1
          ? route.totalDistance / (route.addresses.length - 1)
          : 0,
      longestSegment: longestSegment,
      shortestSegment: shortestSegment == double.infinity ? 0 : shortestSegment,
      estimatedDrivingTime: estimatedTime,
      strategy: route.strategy,
    );
  }
}

/// Result of route optimization
class OptimizedRoute {
  final List<Address> addresses;
  final double totalDistance; // in kilometers
  final String strategy;

  OptimizedRoute({
    required this.addresses,
    required this.totalDistance,
    required this.strategy,
  });
}

/// A segment of the route between two addresses
class RouteSegment {
  final Address from;
  final Address to;
  final double distance; // in kilometers
  final int order;

  RouteSegment({
    required this.from,
    required this.to,
    required this.distance,
    required this.order,
  });
}

/// Statistics about the optimized route
class RouteStatistics {
  final double totalDistance; // in kilometers
  final int numberOfStops;
  final double averageDistanceBetweenStops;
  final double longestSegment;
  final double shortestSegment;
  final Duration estimatedDrivingTime;
  final String strategy;

  RouteStatistics({
    required this.totalDistance,
    required this.numberOfStops,
    required this.averageDistanceBetweenStops,
    required this.longestSegment,
    required this.shortestSegment,
    required this.estimatedDrivingTime,
    required this.strategy,
  });

  String get formattedTotalDistance => '${totalDistance.toStringAsFixed(2)} km';
  String get formattedAverageDistance =>
      '${averageDistanceBetweenStops.toStringAsFixed(2)} km';
  String get formattedLongestSegment =>
      '${longestSegment.toStringAsFixed(2)} km';
  String get formattedShortestSegment =>
      '${shortestSegment.toStringAsFixed(2)} km';
  String get formattedEstimatedTime {
    final hours = estimatedDrivingTime.inHours;
    final minutes = estimatedDrivingTime.inMinutes % 60;
    return hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
  }
}
