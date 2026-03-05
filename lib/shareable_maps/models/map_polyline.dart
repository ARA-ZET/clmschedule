import 'dart:math' show sin, cos, sqrt, asin, pi;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Represents a polyline on the map (route, path, track, etc.)
class MapPolyline {
  final String id;
  final String name;
  final String description;
  final List<LatLng> points;
  final Color color;
  final double strokeWidth;
  final bool isDashed;
  final DateTime createdAt;
  final DateTime updatedAt;

  const MapPolyline({
    required this.id,
    required this.name,
    this.description = '',
    required this.points,
    required this.color,
    this.strokeWidth = 3.0,
    this.isDashed = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Create a new polyline with generated ID
  factory MapPolyline.create({
    required String name,
    String description = '',
    required List<LatLng> points,
    Color? color,
    double strokeWidth = 3.0,
    bool isDashed = false,
  }) {
    final now = DateTime.now();
    return MapPolyline(
      id: 'polyline_${now.millisecondsSinceEpoch}',
      name: name,
      description: description,
      points: points,
      color: color ?? Colors.blue,
      strokeWidth: strokeWidth,
      isDashed: isDashed,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Create from Map (for Firestore/JSON)
  factory MapPolyline.fromMap(String id, Map<String, dynamic> data) {
    return MapPolyline(
      id: id,
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      points: (data['points'] as List<dynamic>?)
              ?.map((point) => LatLng(
                    point['latitude'] as double,
                    point['longitude'] as double,
                  ))
              .toList() ??
          [],
      color: Color(data['color'] as int? ?? Colors.blue.toARGB32()),
      strokeWidth: (data['strokeWidth'] as num?)?.toDouble() ?? 3.0,
      isDashed: data['isDashed'] as bool? ?? false,
      createdAt: data['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['createdAt'] as int)
          : DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['updatedAt'] as int)
          : DateTime.now(),
    );
  }

  /// Convert to Map (for Firestore/JSON)
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'points': points
          .map((point) => {
                'latitude': point.latitude,
                'longitude': point.longitude,
              })
          .toList(),
      'color': color.toARGB32(),
      'strokeWidth': strokeWidth,
      'isDashed': isDashed,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// Create a copy with updated fields
  MapPolyline copyWith({
    String? name,
    String? description,
    List<LatLng>? points,
    Color? color,
    double? strokeWidth,
    bool? isDashed,
    DateTime? updatedAt,
  }) {
    return MapPolyline(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      points: points ?? List.from(this.points),
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      isDashed: isDashed ?? this.isDashed,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  /// Convert to Google Maps Polyline widget
  Polyline toGoogleMapsPolyline({
    bool isSelected = false,
    bool isEditing = false,
    VoidCallback? onTap,
  }) {
    Color lineColor = color;
    double lineWidth = strokeWidth;
    List<PatternItem> patterns =
        isDashed ? [PatternItem.dash(20), PatternItem.gap(10)] : [];

    if (isEditing) {
      lineColor = Colors.red;
      lineWidth = strokeWidth + 2;
    } else if (isSelected) {
      lineColor = Colors.red;
      lineWidth = strokeWidth + 1;
    }

    return Polyline(
      polylineId: PolylineId(id),
      points: points,
      color: lineColor,
      width: lineWidth.toInt(),
      patterns: patterns,
      consumeTapEvents: onTap != null,
      onTap: onTap,
    );
  }

  /// Calculate the total distance of the polyline in meters
  double get totalDistanceMeters {
    if (points.length < 2) return 0.0;

    double total = 0.0;
    for (int i = 0; i < points.length - 1; i++) {
      total += _distanceBetween(points[i], points[i + 1]);
    }
    return total;
  }

  /// Calculate distance between two points using Haversine formula
  double _distanceBetween(LatLng point1, LatLng point2) {
    const double earthRadius = 6371000; // meters
    final double dLat = _toRadians(point2.latitude - point1.latitude);
    final double dLng = _toRadians(point2.longitude - point1.longitude);

    final double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(point1.latitude)) *
            cos(_toRadians(point2.latitude)) *
            sin(dLng / 2) *
            sin(dLng / 2);

    final double c = 2 * asin(sqrt(a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * pi / 180.0;

  /// Get formatted distance string
  String get formattedDistance {
    final distance = totalDistanceMeters;
    if (distance < 1000) {
      return '${distance.toStringAsFixed(0)} m';
    } else {
      return '${(distance / 1000).toStringAsFixed(2)} km';
    }
  }

  /// Check if polyline is valid (has at least 2 points)
  bool get isValid => points.length >= 2;

  /// Get the bounding box for this polyline
  LatLngBounds? get bounds {
    if (points.isEmpty) return null;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  @override
  String toString() {
    return 'MapPolyline(id: $id, name: $name, points: ${points.length}, distance: $formattedDistance)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MapPolyline && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
