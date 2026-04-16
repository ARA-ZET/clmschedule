import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Type of map element stored in Job.workMaps.
enum MapElementType {
  polygon,
  polyline,
  point,

  /// Legacy value – treated as [point] everywhere.
  marker,
}

/// Category of a point/marker element, determines its bitmap icon.
enum PointCategory {
  generic('generic', 'Point', Icons.place, Colors.red),
  dropoff('dropoff', 'Dropoff', Icons.arrow_downward, Colors.blue),
  pickup('pickup', 'Pickup', Icons.arrow_upward, Colors.green),
  loading('loading', 'Loading', Icons.local_shipping, Colors.orange),
  offloading('offloading', 'Offloading', Icons.inventory, Color(0xFFD32F2F)),
  cleaning('cleaning', 'Cleaning Side', Icons.cleaning_services, Colors.teal);

  const PointCategory(this.id, this.label, this.icon, this.color);
  final String id;
  final String label;
  final IconData icon;
  final Color color;

  static PointCategory fromId(String? id) {
    if (id == null) return PointCategory.generic;
    return PointCategory.values.firstWhere(
      (c) => c.id == id,
      orElse: () => PointCategory.generic,
    );
  }
}

class CustomPolygon {
  final String name;
  final String description;
  final List<LatLng> points;
  final Color color;

  /// Fill opacity: 0.0 (transparent) … 1.0 (solid). Default 0.35.
  final double fillOpacity;

  /// Border stroke width in pixels. Default 2.
  final int strokeWidth;

  /// Whether the polyline is dashed. Only meaningful for [isPolyline].
  final bool isDashed;

  /// Type of map element. Default is polygon for backward compatibility.
  final MapElementType type;

  /// Category of the point (only meaningful when [isPoint] is true).
  final PointCategory pointCategory;

  /// Estimated number of letter boxes in this polygon/work area.
  final int letterBoxEstimate;

  const CustomPolygon({
    required this.name,
    required this.description,
    required this.points,
    required this.color,
    this.fillOpacity = 0.35,
    this.strokeWidth = 2,
    this.isDashed = false,
    this.type = MapElementType.polygon,
    this.pointCategory = PointCategory.generic,
    this.letterBoxEstimate = 0,
  });

  /// Whether this element is a single-point marker / point.
  bool get isMarker =>
      type == MapElementType.marker || type == MapElementType.point;

  /// Whether this element is a point (alias for isMarker).
  bool get isPoint => isMarker;

  /// Whether this element is a polygon area.
  bool get isPolygon => type == MapElementType.polygon;

  /// Whether this element is a polyline / path.
  bool get isPolyline => type == MapElementType.polyline;

  /// The marker position (first point). Only meaningful when [isPoint] is true.
  LatLng? get markerPosition => points.isNotEmpty ? points.first : null;

  // Create from Map (for Firestore)
  factory CustomPolygon.fromMap(Map<String, dynamic> data) {
    final points = (data['points'] as List<dynamic>?)
            ?.map((point) => LatLng(
                  point['latitude'] as double,
                  point['longitude'] as double,
                ))
            .toList() ??
        [];

    var type = _parseType(data['type'] as String?);
    // Legacy fix: single-point items stored without a type (or as 'polygon')
    // are actually point/marker elements — a 1-point polygon is invisible.
    if (type == MapElementType.polygon && points.length == 1) {
      type = MapElementType.point;
    }

    final result = CustomPolygon(
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      points: points,
      color: Color(data['color'] as int? ?? Colors.blue.value),
      fillOpacity: (data['fillOpacity'] as num?)?.toDouble() ?? 0.35,
      strokeWidth: (data['strokeWidth'] as num?)?.toInt() ?? 2,
      isDashed: data['isDashed'] as bool? ?? false,
      type: type,
      pointCategory: PointCategory.fromId(data['pointCategory'] as String?),
      letterBoxEstimate: (data['letterBoxEstimate'] as num?)?.toInt() ?? 0,
    );
    debugPrint('[CustomPolygon.fromMap] "${result.name}" type=$type '
        'rawType=${data['type']} points=${points.length} '
        'pointCategory=${result.pointCategory.id}');
    return result;
  }

  /// Parse the stored type string, with backward compatibility for 'marker'.
  static MapElementType _parseType(String? value) {
    switch (value) {
      case 'polyline':
        return MapElementType.polyline;
      case 'point':
      case 'marker': // legacy
        return MapElementType.point;
      case 'polygon':
      default:
        return MapElementType.polygon;
    }
  }

  // Convert to Map (for Firestore)
  Map<String, dynamic> toMap() {
    final map = {
      'name': name,
      'description': description,
      'points': points
          .map((point) => {
                'latitude': point.latitude,
                'longitude': point.longitude,
              })
          .toList(),
      'color': color.toARGB32(),
      'fillOpacity': fillOpacity,
      'strokeWidth': strokeWidth,
      if (isDashed) 'isDashed': true,
      'type': _typeToString(type),
      if (isPoint && pointCategory != PointCategory.generic)
        'pointCategory': pointCategory.id,
      if (letterBoxEstimate > 0) 'letterBoxEstimate': letterBoxEstimate,
    };
    if (isPoint) {
      debugPrint('[CustomPolygon.toMap] POINT "$name" type=${map['type']} '
          'pointCategory=${map['pointCategory']} points=${points.length}');
    }
    return map;
  }

  static String _typeToString(MapElementType t) {
    switch (t) {
      case MapElementType.polygon:
        return 'polygon';
      case MapElementType.polyline:
        return 'polyline';
      case MapElementType.point:
      case MapElementType.marker:
        return 'point';
    }
  }

  // Create a copy with some fields updated
  CustomPolygon copyWith({
    String? name,
    String? description,
    List<LatLng>? points,
    Color? color,
    double? fillOpacity,
    int? strokeWidth,
    bool? isDashed,
    MapElementType? type,
    PointCategory? pointCategory,
    int? letterBoxEstimate,
  }) {
    return CustomPolygon(
      name: name ?? this.name,
      description: description ?? this.description,
      points: points ?? this.points,
      color: color ?? this.color,
      fillOpacity: fillOpacity ?? this.fillOpacity,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      isDashed: isDashed ?? this.isDashed,
      type: type ?? this.type,
      pointCategory: pointCategory ?? this.pointCategory,
      letterBoxEstimate: letterBoxEstimate ?? this.letterBoxEstimate,
    );
  }

  // Convert to Google Maps Polygon widget (only for polygon type)
  Polygon toGoogleMapsPolygon({
    required String polygonId,
    bool isSelected = false,
    bool isEditing = false,
    VoidCallback? onTap,
  }) {
    Color strokeColor = color;
    Color fillColor = color.withValues(alpha: fillOpacity);
    int sw = strokeWidth;

    if (isEditing) {
      strokeColor = Colors.red;
      fillColor = Colors.red.withValues(alpha: 0.1);
      sw = 5;
    } else if (isSelected) {
      sw = 5;
    }

    return Polygon(
      polygonId: PolygonId(polygonId),
      points: points,
      fillColor: fillColor,
      strokeColor: strokeColor,
      strokeWidth: sw,
      onTap: onTap,
    );
  }

  /// Convert to a Google Maps Marker widget (only for marker type).
  /// Returns null if this is not a marker or has no points.
  Marker? toGoogleMapsMarker({
    required String markerId,
    bool isSelected = false,
    VoidCallback? onTap,
    bool draggable = false,
    ValueChanged<LatLng>? onDragEnd,
    BitmapDescriptor? customIcon,
  }) {
    if (!isMarker && !isPoint || points.isEmpty) return null;

    return Marker(
      markerId: MarkerId(markerId),
      position: points.first,
      icon: customIcon ??
          BitmapDescriptor.defaultMarkerWithHue(_colorToMarkerHue(
              pointCategory != PointCategory.generic
                  ? pointCategory.color
                  : color)),
      alpha: isSelected ? 1.0 : 0.85,
      infoWindow: InfoWindow(
        title: name.isNotEmpty ? name : pointCategory.label,
        snippet: description.isNotEmpty ? description : null,
      ),
      onTap: onTap,
      draggable: draggable,
      onDragEnd: onDragEnd,
    );
  }

  /// Map a Color to the nearest BitmapDescriptor marker hue.
  static double _colorToMarkerHue(Color c) {
    final r = c.r, g = c.g, b = c.b;
    // Red-ish
    if (r > 0.7 && g < 0.4 && b < 0.4) return BitmapDescriptor.hueRed;
    // Orange-ish
    if (r > 0.7 && g > 0.3 && g < 0.7 && b < 0.3) {
      return BitmapDescriptor.hueOrange;
    }
    // Yellow-ish
    if (r > 0.7 && g > 0.7 && b < 0.4) return BitmapDescriptor.hueYellow;
    // Green-ish
    if (g > 0.5 && r < 0.5 && b < 0.5) return BitmapDescriptor.hueGreen;
    // Cyan-ish
    if (g > 0.5 && b > 0.5 && r < 0.4) return BitmapDescriptor.hueCyan;
    // Azure / Blue-ish
    if (b > 0.5 && r < 0.4 && g < 0.5) return BitmapDescriptor.hueAzure;
    // Violet / Purple
    if (r > 0.4 && b > 0.5 && g < 0.4) return BitmapDescriptor.hueViolet;
    // Magenta / Rose
    if (r > 0.7 && b > 0.5 && g < 0.4) return BitmapDescriptor.hueRose;
    // Default blue
    return BitmapDescriptor.hueBlue;
  }

  @override
  String toString() {
    return 'CustomPolygon(name: $name, type: ${type.name}, description: $description, '
        'pointsCount: ${points.length}, color: $color)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomPolygon &&
        other.name == name &&
        other.description == description &&
        other.points.length == points.length &&
        other.color == color &&
        other.type == type;
  }

  @override
  int get hashCode {
    return Object.hash(name, description, points.length, color, type);
  }
}
