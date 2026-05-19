import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/custom_polygon.dart';
import 'map_polyline.dart';
import 'map_point.dart';

/// Represents a layer in the map that can contain polygons, polylines, and points
class MapLayer {
  final String id;
  final String name;
  final String description;
  final bool isVisible;
  final int order; // Z-index for layering
  final Color defaultColor;
  final List<CustomPolygon> polygons;
  final List<MapPolyline> polylines;
  final List<MapPoint> points;
  final bool isExpanded; // For UI state (collapsed/expanded in sidebar)
  final DateTime createdAt;
  final DateTime updatedAt;

  const MapLayer({
    required this.id,
    required this.name,
    this.description = '',
    this.isVisible = true,
    required this.order,
    required this.defaultColor,
    this.polygons = const [],
    this.polylines = const [],
    this.points = const [],
    this.isExpanded = true,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Create a new layer with generated ID
  factory MapLayer.create({
    required String name,
    String description = '',
    bool isVisible = true,
    int order = 0,
    Color? defaultColor,
  }) {
    final now = DateTime.now();
    return MapLayer(
      id: 'layer_${now.millisecondsSinceEpoch}',
      name: name,
      description: description,
      isVisible: isVisible,
      order: order,
      defaultColor: defaultColor ?? Colors.blue,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Create from Map (for Firestore/JSON)
  factory MapLayer.fromMap(String id, Map<String, dynamic> data) {
    return MapLayer(
      id: id,
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      isVisible: data['isVisible'] as bool? ?? true,
      order: (data['order'] as num?)?.toInt() ?? 0,
      defaultColor:
          Color((data['defaultColor'] as num?)?.toInt() ?? Colors.blue.toARGB32()),
      polygons: (data['polygons'] as List<dynamic>?)
              ?.asMap()
              .entries
              .map(
                  (e) => CustomPolygon.fromMap(Map<String, dynamic>.from(e.value as Map)))
              .toList() ??
          [],
      polylines:
          (data['polylines'] as List<dynamic>?)?.asMap().entries.map((e) {
                final polylineData = Map<String, dynamic>.from(e.value as Map);
                final polylineId =
                    polylineData['id'] as String? ?? 'polyline_${e.key}';
                return MapPolyline.fromMap(polylineId, polylineData);
              }).toList() ??
              [],
      points: (data['points'] as List<dynamic>?)?.asMap().entries.map((e) {
            final pointData = Map<String, dynamic>.from(e.value as Map);
            final pointId = pointData['id'] as String? ?? 'point_${e.key}';
            return MapPoint.fromMap(pointId, pointData);
          }).toList() ??
          [],
      isExpanded: data['isExpanded'] as bool? ?? true,
      createdAt: data['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch((data['createdAt'] as num).toInt())
          : DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch((data['updatedAt'] as num).toInt())
          : DateTime.now(),
    );
  }

  /// Convert to Map (for Firestore/JSON)
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'isVisible': isVisible,
      'order': order,
      'defaultColor': defaultColor.toARGB32(),
      'polygons': polygons.map((p) => p.toMap()).toList(),
      'polylines': polylines.map((p) => p.toMap()).toList(),
      'points': points.map((p) => p.toMap()).toList(),
      'isExpanded': isExpanded,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// Create a copy with updated fields
  MapLayer copyWith({
    String? name,
    String? description,
    bool? isVisible,
    int? order,
    Color? defaultColor,
    List<CustomPolygon>? polygons,
    List<MapPolyline>? polylines,
    List<MapPoint>? points,
    bool? isExpanded,
    DateTime? updatedAt,
  }) {
    return MapLayer(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      isVisible: isVisible ?? this.isVisible,
      order: order ?? this.order,
      defaultColor: defaultColor ?? this.defaultColor,
      polygons: polygons ?? List.from(this.polygons),
      polylines: polylines ?? List.from(this.polylines),
      points: points ?? List.from(this.points),
      isExpanded: isExpanded ?? this.isExpanded,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  /// Get total count of all elements in this layer
  int get elementCount => polygons.length + polylines.length + points.length;

  /// Check if layer is empty
  bool get isEmpty => elementCount == 0;

  /// Check if layer has content
  bool get isNotEmpty => elementCount > 0;

  /// Get all polygons as Google Maps Polygon objects (skips marker-type entries)
  List<Polygon> getGoogleMapsPolygons({
    String? selectedElementId,
    String? editingElementId,
    Function(String polygonId)? onTap,
  }) {
    if (!isVisible) return [];

    final result = <Polygon>[];
    for (int index = 0; index < polygons.length; index++) {
      final polygon = polygons[index];

      // Skip marker-type CustomPolygons — they are converted to markers
      if (polygon.isMarker) continue;

      final polygonId = '${id}_polygon_$index';

      // Skip the polygon being vertex-edited (replaced by editing overlay)
      if (polygonId == editingElementId) continue;

      final isSelected = polygonId == selectedElementId;

      result.add(polygon.toGoogleMapsPolygon(
        polygonId: polygonId,
        isSelected: isSelected,
        isEditing: polygonId == editingElementId,
        onTap: onTap != null ? () => onTap(polygonId) : null,
      ));
    }
    return result;
  }

  /// Get all polylines as Google Maps Polyline objects
  List<Polyline> getGoogleMapsPolylines({
    String? selectedElementId,
    String? editingElementId,
    Function(String polylineId)? onTap,
  }) {
    if (!isVisible) return [];

    return polylines
        .where((polyline) => polyline.id != editingElementId)
        .map((polyline) {
      return polyline.toGoogleMapsPolyline(
        isSelected: polyline.id == selectedElementId,
        isEditing: polyline.id == editingElementId,
        onTap: onTap != null ? () => onTap(polyline.id) : null,
      );
    }).toList();
  }

  /// Get all points as Google Maps Marker objects
  /// Includes both MapPoint entries and marker-type CustomPolygon entries.
  /// If [pointIcons] is provided, uses custom bitmap icons per category.
  /// If [visibleBounds] is provided, only points within those bounds are
  /// returned (viewport culling for large point sets).
  ///
  /// When [markerVisible] is false the markers are still constructed and
  /// returned (with `visible: false`) so callers can keep large layers
  /// loaded on the JS side and toggle visibility natively without paying
  /// the cost of removing + re-adding thousands of markers across the
  /// platform-view bridge. Defaults to [isVisible] when not specified.
  List<Marker> getGoogleMapsMarkers({
    String? selectedElementId,
    Function(String pointId)? onTap,
    bool draggable = false,
    Function(String pointId, LatLng newPosition)? onDragEnd,
    Map<PointCategory, BitmapDescriptor>? pointIcons,
    LatLngBounds? visibleBounds,
    bool? markerVisible,
  }) {
    final visible = markerVisible ?? isVisible;

    final result = <Marker>[];

    // Regular MapPoint markers — cull by visible bounds when provided
    final visiblePoints = visibleBounds != null
        ? points.where((p) => visibleBounds.contains(p.position))
        : points;

    for (final point in visiblePoints) {
      result.add(point.toGoogleMapsMarker(
        isSelected: point.id == selectedElementId,
        onTap: onTap != null ? () => onTap(point.id) : null,
        draggable: draggable,
        onDragEnd: draggable && onDragEnd != null
            ? (pos) => onDragEnd(point.id, pos)
            : null,
        customIcon: pointIcons?[point.pointCategory],
        visible: visible,
      ));
    }

    // Marker-type CustomPolygon entries
    for (int i = 0; i < polygons.length; i++) {
      final cp = polygons[i];
      if (!cp.isMarker || cp.points.isEmpty) continue;
      final markerId = '${id}_polygon_marker_$i';
      final marker = cp.toGoogleMapsMarker(
        markerId: markerId,
        isSelected: markerId == selectedElementId,
        onTap: onTap != null ? () => onTap(markerId) : null,
        draggable: draggable,
        onDragEnd: draggable && onDragEnd != null
            ? (pos) => onDragEnd(markerId, pos)
            : null,
        customIcon: pointIcons?[cp.pointCategory],
        visible: visible,
      );
      if (marker != null) result.add(marker);
    }

    return result;
  }

  /// Get bounding box that encompasses all elements in the layer
  LatLngBounds? getBounds() {
    if (isEmpty) return null;

    double? minLat;
    double? maxLat;
    double? minLng;
    double? maxLng;

    void updateBounds(double lat, double lng) {
      if (minLat == null || lat < minLat!) minLat = lat;
      if (maxLat == null || lat > maxLat!) maxLat = lat;
      if (minLng == null || lng < minLng!) minLng = lng;
      if (maxLng == null || lng > maxLng!) maxLng = lng;
    }

    // Process polygons
    for (final polygon in polygons) {
      for (final point in polygon.points) {
        updateBounds(point.latitude, point.longitude);
      }
    }

    // Process polylines
    for (final polyline in polylines) {
      for (final point in polyline.points) {
        updateBounds(point.latitude, point.longitude);
      }
    }

    // Process points
    for (final point in points) {
      updateBounds(point.position.latitude, point.position.longitude);
    }

    if (minLat == null || maxLat == null || minLng == null || maxLng == null) {
      return null;
    }

    return LatLngBounds(
      southwest: LatLng(minLat!, minLng!),
      northeast: LatLng(maxLat!, maxLng!),
    );
  }

  /// Add a polygon to this layer
  MapLayer addPolygon(CustomPolygon polygon) {
    final newPolygons = List<CustomPolygon>.from(polygons)..add(polygon);
    return copyWith(polygons: newPolygons, updatedAt: DateTime.now());
  }

  /// Add a polyline to this layer
  MapLayer addPolyline(MapPolyline polyline) {
    final newPolylines = List<MapPolyline>.from(polylines)..add(polyline);
    return copyWith(polylines: newPolylines, updatedAt: DateTime.now());
  }

  /// Add a point to this layer
  MapLayer addPoint(MapPoint point) {
    final newPoints = List<MapPoint>.from(points)..add(point);
    return copyWith(points: newPoints, updatedAt: DateTime.now());
  }

  /// Remove a polygon by index
  MapLayer removePolygon(int index) {
    if (index < 0 || index >= polygons.length) return this;
    final newPolygons = List<CustomPolygon>.from(polygons)..removeAt(index);
    return copyWith(polygons: newPolygons, updatedAt: DateTime.now());
  }

  /// Remove a polyline by id
  MapLayer removePolyline(String polylineId) {
    final newPolylines = List<MapPolyline>.from(polylines)
      ..removeWhere((p) => p.id == polylineId);
    return copyWith(polylines: newPolylines, updatedAt: DateTime.now());
  }

  /// Remove a point by id
  MapLayer removePoint(String pointId) {
    final newPoints = List<MapPoint>.from(points)
      ..removeWhere((p) => p.id == pointId);
    return copyWith(points: newPoints, updatedAt: DateTime.now());
  }

  /// Update a polygon by index
  MapLayer updatePolygon(int index, CustomPolygon polygon) {
    if (index < 0 || index >= polygons.length) return this;
    final newPolygons = List<CustomPolygon>.from(polygons);
    newPolygons[index] = polygon;
    return copyWith(polygons: newPolygons, updatedAt: DateTime.now());
  }

  /// Update a polyline by id
  MapLayer updatePolyline(String polylineId, MapPolyline polyline) {
    final index = polylines.indexWhere((p) => p.id == polylineId);
    if (index == -1) return this;
    final newPolylines = List<MapPolyline>.from(polylines);
    newPolylines[index] = polyline;
    return copyWith(polylines: newPolylines, updatedAt: DateTime.now());
  }

  /// Update a point by id
  MapLayer updatePoint(String pointId, MapPoint point) {
    final index = points.indexWhere((p) => p.id == pointId);
    if (index == -1) return this;
    final newPoints = List<MapPoint>.from(points);
    newPoints[index] = point;
    return copyWith(points: newPoints, updatedAt: DateTime.now());
  }

  @override
  String toString() {
    return 'MapLayer(id: $id, name: $name, elements: $elementCount, visible: $isVisible)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MapLayer && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
