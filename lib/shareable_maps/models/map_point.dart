import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Represents a point/marker on the map
class MapPoint {
  final String id;
  final String name;
  final String description;
  final LatLng position;
  final Color color;
  final String icon; // Icon identifier (e.g., 'pin', 'star', 'flag')
  final DateTime createdAt;
  final DateTime updatedAt;

  const MapPoint({
    required this.id,
    required this.name,
    this.description = '',
    required this.position,
    required this.color,
    this.icon = 'pin',
    required this.createdAt,
    required this.updatedAt,
  });

  /// Create a new point with generated ID
  factory MapPoint.create({
    required String name,
    String description = '',
    required LatLng position,
    Color? color,
    String icon = 'pin',
  }) {
    final now = DateTime.now();
    return MapPoint(
      id: 'point_${now.millisecondsSinceEpoch}',
      name: name,
      description: description,
      position: position,
      color: color ?? Colors.red,
      icon: icon,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Create from Map (for Firestore/JSON)
  factory MapPoint.fromMap(String id, Map<String, dynamic> data) {
    return MapPoint(
      id: id,
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      position: LatLng(
        data['latitude'] as double? ?? 0.0,
        data['longitude'] as double? ?? 0.0,
      ),
      color: Color(data['color'] as int? ?? Colors.red.toARGB32()),
      icon: data['icon'] as String? ?? 'pin',
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
      'latitude': position.latitude,
      'longitude': position.longitude,
      'color': color.toARGB32(),
      'icon': icon,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// Create a copy with updated fields
  MapPoint copyWith({
    String? name,
    String? description,
    LatLng? position,
    Color? color,
    String? icon,
    DateTime? updatedAt,
  }) {
    return MapPoint(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      position: position ?? this.position,
      color: color ?? this.color,
      icon: icon ?? this.icon,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  /// Convert to Google Maps Marker
  /// Note: BitmapDescriptor needs to be created asynchronously
  Marker toGoogleMapsMarker({
    bool isSelected = false,
    VoidCallback? onTap,
    BitmapDescriptor? customIcon,
  }) {
    return Marker(
      markerId: MarkerId(id),
      position: position,
      infoWindow: InfoWindow.noText,
      icon:
          customIcon ?? BitmapDescriptor.defaultMarkerWithHue(_getMarkerHue()),
      alpha: isSelected ? 1.0 : 0.9,
      onTap: onTap,
    );
  }

  /// Get Google Maps marker hue from color
  double _getMarkerHue() {
    final hslColor = HSLColor.fromColor(color);
    return hslColor.hue;
  }

  /// Get the coordinates as a formatted string
  String get coordinatesString {
    return '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}';
  }

  @override
  String toString() {
    return 'MapPoint(id: $id, name: $name, position: $coordinatesString)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MapPoint && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Available icon types for map points
enum MapPointIcon {
  pin('pin', 'Location Pin'),
  star('star', 'Star'),
  flag('flag', 'Flag'),
  heart('heart', 'Heart'),
  home('home', 'Home'),
  work('work', 'Work'),
  info('info', 'Info'),
  warning('warning', 'Warning'),
  delivery('delivery', 'Delivery'),
  pickup('pickup', 'Pickup');

  const MapPointIcon(this.id, this.label);
  final String id;
  final String label;

  static MapPointIcon fromId(String id) {
    return MapPointIcon.values.firstWhere(
      (icon) => icon.id == id,
      orElse: () => MapPointIcon.pin,
    );
  }
}
