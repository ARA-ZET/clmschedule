import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'map_layer.dart';

/// Represents a complete shareable map with all layers and settings
class ShareableMap {
  final String id;
  final String name;
  final String description;
  final List<MapLayer> layers;
  final LatLng defaultCenter;
  final double defaultZoom;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? thumbnailUrl;

  const ShareableMap({
    required this.id,
    required this.name,
    this.description = '',
    this.layers = const [],
    required this.defaultCenter,
    this.defaultZoom = 12.0,
    required this.createdAt,
    required this.updatedAt,
    this.thumbnailUrl,
  });

  /// Create a new map with generated ID
  factory ShareableMap.create({
    required String name,
    String description = '',
    LatLng? defaultCenter,
    double defaultZoom = 12.0,
  }) {
    final now = DateTime.now();
    return ShareableMap(
      id: 'map_${now.millisecondsSinceEpoch}',
      name: name,
      description: description,
      defaultCenter:
          defaultCenter ?? const LatLng(-33.925, 18.425), // Cape Town default
      defaultZoom: defaultZoom,
      createdAt: now,
      updatedAt: now,
      thumbnailUrl: null,
    );
  }

  /// Create a blank map with a default layer
  factory ShareableMap.createWithDefaultLayer({
    required String name,
    String description = '',
    LatLng? defaultCenter,
  }) {
    final now = DateTime.now();
    final defaultLayer = MapLayer.create(
      name: 'Layer 1',
      order: 0,
      defaultColor: Colors.blue,
    );

    return ShareableMap(
      id: 'map_${now.millisecondsSinceEpoch}',
      name: name,
      description: description,
      layers: [defaultLayer],
      defaultCenter: defaultCenter ?? const LatLng(-33.925, 18.425),
      defaultZoom: 12.0,
      createdAt: now,
      updatedAt: now,
      thumbnailUrl: null,
    );
  }

  /// Create from Map (for Firestore/JSON)
  factory ShareableMap.fromMap(String id, Map<String, dynamic> data) {
    return ShareableMap(
      id: id,
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      layers: (data['layers'] as List<dynamic>?)?.asMap().entries.map((e) {
            final layerData = e.value as Map<String, dynamic>;
            final layerId = layerData['id'] as String? ?? 'layer_${e.key}';
            return MapLayer.fromMap(layerId, layerData);
          }).toList() ??
          [],
      defaultCenter: LatLng(
        data['defaultCenterLat'] as double? ?? -33.925,
        data['defaultCenterLng'] as double? ?? 18.425,
      ),
      defaultZoom: (data['defaultZoom'] as num?)?.toDouble() ?? 12.0,
      createdAt: data['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['createdAt'] as int)
          : DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(data['updatedAt'] as int)
          : DateTime.now(),
      thumbnailUrl: data['thumbnailUrl'] as String?,
    );
  }

  /// Convert to Map (for Firestore/JSON)
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'layers': layers.map((layer) => layer.toMap()).toList(),
      'defaultCenterLat': defaultCenter.latitude,
      'defaultCenterLng': defaultCenter.longitude,
      'defaultZoom': defaultZoom,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
      if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    };
  }

  /// Create a copy with updated fields
  ShareableMap copyWith({
    String? name,
    String? description,
    List<MapLayer>? layers,
    LatLng? defaultCenter,
    double? defaultZoom,
    DateTime? updatedAt,
    String? thumbnailUrl,
  }) {
    return ShareableMap(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      layers: layers ?? List.from(this.layers),
      defaultCenter: defaultCenter ?? this.defaultCenter,
      defaultZoom: defaultZoom ?? this.defaultZoom,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    );
  }

  /// Get total count of all elements across all layers
  int get totalElementCount {
    return layers.fold(0, (sum, layer) => sum + layer.elementCount);
  }

  /// Get count of visible elements
  int get visibleElementCount {
    return layers
        .where((layer) => layer.isVisible)
        .fold(0, (sum, layer) => sum + layer.elementCount);
  }

  /// Check if map is empty
  bool get isEmpty => layers.isEmpty || totalElementCount == 0;

  /// Check if map has content
  bool get isNotEmpty => !isEmpty;

  /// Get visible layers sorted by order
  List<MapLayer> get visibleLayersSorted {
    return layers.where((layer) => layer.isVisible).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  /// Get all layers sorted by order
  List<MapLayer> get layersSorted {
    return List<MapLayer>.from(layers)
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  /// Get bounding box that encompasses all visible elements
  LatLngBounds? getBounds() {
    final visibleLayers = layers.where((layer) => layer.isVisible).toList();
    if (visibleLayers.isEmpty) return null;

    double? minLat;
    double? maxLat;
    double? minLng;
    double? maxLng;

    for (final layer in visibleLayers) {
      final layerBounds = layer.getBounds();
      if (layerBounds == null) continue;

      final sw = layerBounds.southwest;
      final ne = layerBounds.northeast;

      if (minLat == null || sw.latitude < minLat) minLat = sw.latitude;
      if (maxLat == null || ne.latitude > maxLat) maxLat = ne.latitude;
      if (minLng == null || sw.longitude < minLng) minLng = sw.longitude;
      if (maxLng == null || ne.longitude > maxLng) maxLng = ne.longitude;
    }

    if (minLat == null || maxLat == null || minLng == null || maxLng == null) {
      return null;
    }

    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  /// Add a new layer
  ShareableMap addLayer(MapLayer layer) {
    final newLayers = List<MapLayer>.from(layers)..add(layer);
    return copyWith(layers: newLayers, updatedAt: DateTime.now());
  }

  /// Remove a layer by id
  ShareableMap removeLayer(String layerId) {
    final newLayers = List<MapLayer>.from(layers)
      ..removeWhere((layer) => layer.id == layerId);
    return copyWith(layers: newLayers, updatedAt: DateTime.now());
  }

  /// Update a layer by id
  ShareableMap updateLayer(String layerId, MapLayer updatedLayer) {
    final index = layers.indexWhere((layer) => layer.id == layerId);
    if (index == -1) return this;

    final newLayers = List<MapLayer>.from(layers);
    newLayers[index] = updatedLayer;
    return copyWith(layers: newLayers, updatedAt: DateTime.now());
  }

  /// Get a layer by id
  MapLayer? getLayer(String layerId) {
    try {
      return layers.firstWhere((layer) => layer.id == layerId);
    } catch (e) {
      return null;
    }
  }

  /// Reorder layers
  ShareableMap reorderLayers(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return this;

    final newLayers = List<MapLayer>.from(layers);
    final layer = newLayers.removeAt(oldIndex);
    newLayers.insert(newIndex, layer);

    // Update order values
    for (int i = 0; i < newLayers.length; i++) {
      newLayers[i] = newLayers[i].copyWith(order: i);
    }

    return copyWith(layers: newLayers, updatedAt: DateTime.now());
  }

  /// Toggle layer visibility
  ShareableMap toggleLayerVisibility(String layerId) {
    final layer = getLayer(layerId);
    if (layer == null) return this;

    final updatedLayer = layer.copyWith(isVisible: !layer.isVisible);
    return updateLayer(layerId, updatedLayer);
  }

  /// Toggle layer expanded state (for UI)
  ShareableMap toggleLayerExpanded(String layerId) {
    final layer = getLayer(layerId);
    if (layer == null) return this;

    final updatedLayer = layer.copyWith(isExpanded: !layer.isExpanded);
    return updateLayer(layerId, updatedLayer);
  }

  /// Get all polygons from visible layers as Google Maps Polygon objects
  List<Polygon> getAllGoogleMapsPolygons({
    String? selectedElementId,
    String? editingElementId,
    Function(String polygonId)? onTap,
  }) {
    return visibleLayersSorted
        .expand((layer) => layer.getGoogleMapsPolygons(
              selectedElementId: selectedElementId,
              editingElementId: editingElementId,
              onTap: onTap,
            ))
        .toList();
  }

  /// Get all polylines from visible layers as Google Maps Polyline objects
  List<Polyline> getAllGoogleMapsPolylines({
    String? selectedElementId,
    String? editingElementId,
    Function(String polylineId)? onTap,
  }) {
    return visibleLayersSorted
        .expand((layer) => layer.getGoogleMapsPolylines(
              selectedElementId: selectedElementId,
              editingElementId: editingElementId,
              onTap: onTap,
            ))
        .toList();
  }

  /// Get all markers from visible layers as Google Maps Marker objects
  List<Marker> getAllGoogleMapsMarkers({
    String? selectedElementId,
    Function(String pointId)? onTap,
  }) {
    return visibleLayersSorted
        .expand((layer) => layer.getGoogleMapsMarkers(
              selectedElementId: selectedElementId,
              onTap: onTap,
            ))
        .toList();
  }

  /// Get statistics about the map
  Map<String, dynamic> getStatistics() {
    int totalPolygons = 0;
    int totalPolylines = 0;
    int totalPoints = 0;
    int visibleLayers = 0;

    for (final layer in layers) {
      totalPolygons += layer.polygons.length;
      totalPolylines += layer.polylines.length;
      totalPoints += layer.points.length;
      if (layer.isVisible) visibleLayers++;
    }

    return {
      'totalLayers': layers.length,
      'visibleLayers': visibleLayers,
      'totalPolygons': totalPolygons,
      'totalPolylines': totalPolylines,
      'totalPoints': totalPoints,
      'totalElements': totalElementCount,
    };
  }

  @override
  String toString() {
    return 'ShareableMap(id: $id, name: $name, layers: ${layers.length}, elements: $totalElementCount)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ShareableMap && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
