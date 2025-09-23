import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class CustomPolygon {
  final String name;
  final String description;
  final List<LatLng> points;
  final Color color;

  const CustomPolygon({
    required this.name,
    required this.description,
    required this.points,
    required this.color,
  });

  // Create from Map (for Firestore)
  factory CustomPolygon.fromMap(Map<String, dynamic> data) {
    return CustomPolygon(
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      points: (data['points'] as List<dynamic>?)
              ?.map((point) => LatLng(
                    point['latitude'] as double,
                    point['longitude'] as double,
                  ))
              .toList() ??
          [],
      color: Color(data['color'] as int? ?? Colors.blue.value),
    );
  }

  // Convert to Map (for Firestore)
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
      'color': color.value,
    };
  }

  // Create a copy with some fields updated
  CustomPolygon copyWith({
    String? name,
    String? description,
    List<LatLng>? points,
    Color? color,
  }) {
    return CustomPolygon(
      name: name ?? this.name,
      description: description ?? this.description,
      points: points ?? this.points,
      color: color ?? this.color,
    );
  }

  // Convert to Google Maps Polygon widget
  Polygon toGoogleMapsPolygon({
    required String polygonId,
    bool isSelected = false,
    bool isEditing = false,
    VoidCallback? onTap,
  }) {
    Color strokeColor = color;
    Color fillColor = color.withOpacity(0.2);
    int strokeWidth = 2;

    if (isEditing) {
      strokeColor = Colors.red;
      fillColor = Colors.red.withOpacity(0.1);
      strokeWidth = 5;
    } else if (isSelected) {
      strokeColor = Colors.red;
      fillColor = Colors.red.withOpacity(0.1);
      strokeWidth = 4;
    }

    return Polygon(
      polygonId: PolygonId(polygonId),
      points: points,
      fillColor: fillColor,
      strokeColor: strokeColor,
      strokeWidth: strokeWidth,
      onTap: onTap,
    );
  }

  @override
  String toString() {
    return 'CustomPolygon(name: $name, description: $description, '
        'pointsCount: ${points.length}, color: $color)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomPolygon &&
        other.name == name &&
        other.description == description &&
        other.points.length == points.length &&
        other.color == color;
  }

  @override
  int get hashCode {
    return Object.hash(name, description, points.length, color);
  }
}
