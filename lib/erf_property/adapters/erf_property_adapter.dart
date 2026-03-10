import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../shareable_maps/adapters/map_data_adapter.dart';
import '../../shareable_maps/models/map_layer.dart';
import '../../shareable_maps/models/shareable_map.dart';
import '../models/erf_property.dart';
import '../services/erf_property_firestore_service.dart';

/// Adapter that bridges the ShareableMapEditor to ERF property data.
///
/// **Load**: Reads ERF properties from Firestore and converts each into a
/// [CustomPolygon] on a single layer called "ERF Properties".
///
/// **Save**: Read-only — ERF data is managed by the ERF provider, not edited
/// in the map editor. Save is a no-op.
class ErfPropertyAdapter extends MapDataAdapter {
  final ErfPropertyFirestoreService _firestoreService;

  /// Optional suburb filter. If set, only loads properties for that suburb.
  final String? suburbFilter;

  /// Optional pre-loaded properties to display (skips Firestore read).
  final List<ErfProperty>? preloadedProperties;

  /// Optional initial center for the map.
  final LatLng? initialCenter;

  ErfPropertyAdapter({
    ErfPropertyFirestoreService? firestoreService,
    this.suburbFilter,
    this.preloadedProperties,
    this.initialCenter,
  }) : _firestoreService = firestoreService ?? ErfPropertyFirestoreService();

  @override
  String get adapterId => 'erf_property';

  @override
  String get displayName =>
      suburbFilter != null ? 'ERF Properties — $suburbFilter' : 'ERF Properties';

  @override
  MapEditorCapabilities get capabilities =>
      const MapEditorCapabilities.viewOnly();

  @override
  Future<ShareableMap> load() async {
    // Get properties from preloaded list, suburb filter, or all
    List<ErfProperty> properties;
    if (preloadedProperties != null) {
      properties = preloadedProperties!;
    } else if (suburbFilter != null) {
      properties = await _firestoreService.getPropertiesBySuburb(suburbFilter!);
    } else {
      // Load all via a one-time stream read
      properties = await _firestoreService.streamProperties().first;
    }

    // Convert each ERF property to a CustomPolygon
    final polygons = properties
        .where((p) => p.polygon.length >= 3)
        .map((p) => _erfToPolygon(p))
        .toList();

    final now = DateTime.now();
    final layer = MapLayer(
      id: 'erf_properties_layer',
      name: 'ERF Properties',
      description: suburbFilter != null
          ? 'ERF parcels for $suburbFilter'
          : 'All loaded ERF parcels',
      order: 0,
      defaultColor: Colors.teal,
      polygons: polygons,
      createdAt: now,
      updatedAt: now,
    );

    // Calculate center from properties or use default
    LatLng center = initialCenter ?? const LatLng(-33.905, 18.510);
    if (properties.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      int count = 0;
      for (final p in properties) {
        latSum += p.centroid.latitude;
        lngSum += p.centroid.longitude;
        count++;
      }
      if (count > 0) {
        center = LatLng(latSum / count, lngSum / count);
      }
    }

    return ShareableMap(
      id: 'erf_properties_map',
      name: displayName,
      description: '${polygons.length} ERF parcels',
      layers: [layer],
      defaultCenter: center,
      defaultZoom: 16.0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    // Read-only adapter — ERF data is not edited in the map editor.
  }

  // ── Conversion helpers ──────────────────────────────────────────────

  /// Convert an [ErfProperty] to a [CustomPolygon] for use in the map editor.
  static CustomPolygon _erfToPolygon(ErfProperty erf) {
    return CustomPolygon(
      name: erf.displayLabel,
      description:
          'ERF ${erf.erfNumber}\n${erf.minRegion}\n${erf.area.toStringAsFixed(1)} m²',
      points: List<LatLng>.from(erf.polygon),
      color: Colors.teal,
      fillOpacity: 0.2,
      strokeWidth: 2,
    );
  }
}
