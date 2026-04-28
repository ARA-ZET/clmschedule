import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/work_area.dart';
import '../../services/firestore_service.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';
import 'map_data_adapter.dart';

/// Adapter that bridges the ShareableMapEditor to the `/workAreas/` Firestore
/// collection.
///
/// **Load**: Reads all [WorkArea] documents and converts each into a
/// [CustomPolygon] on a single layer called "Work Areas".
///
/// **Save**: Compares the current polygons against the originally loaded
/// state and performs the minimal set of creates / updates / deletes
/// on Firestore.
class WorkAreaCollectionAdapter extends MapDataAdapter {
  final FirestoreService _firestoreService;

  /// Optional center to focus the map on initially.
  final LatLng? initialCenter;

  /// Snapshot of the work areas as they were at load time.
  /// Used for diffing on save.
  List<WorkArea> _loadedWorkAreas = [];

  WorkAreaCollectionAdapter({
    FirestoreService? firestoreService,
    this.initialCenter,
  }) : _firestoreService = firestoreService ?? FirestoreService();

  @override
  String get adapterId => 'work_area_collection';

  @override
  String get displayName => 'Work Areas';

  @override
  MapEditorCapabilities get capabilities =>
      const MapEditorCapabilities.polygonOnly();

  @override
  Future<ShareableMap> load() async {
    // Read all work areas from Firestore (cache-first one-shot fetch).
    _loadedWorkAreas = await _firestoreService.fetchWorkAreasOnce();

    // Convert each WorkArea to a CustomPolygon
    final polygons =
        _loadedWorkAreas.map((wa) => _workAreaToPolygon(wa)).toList();

    // Build a single-layer ShareableMap
    final now = DateTime.now();
    final layer = MapLayer(
      id: 'work_areas_layer',
      name: 'Work Areas',
      description: 'Polygons from the /workAreas/ collection',
      order: 0,
      defaultColor: Colors.red,
      polygons: polygons,
      createdAt: now,
      updatedAt: now,
    );

    // Determine default center from existing polygons or fallback
    LatLng center = initialCenter ?? const LatLng(-33.925, 18.425);
    if (_loadedWorkAreas.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      int count = 0;
      for (final wa in _loadedWorkAreas) {
        for (final pt in wa.polygonPoints) {
          latSum += pt.latitude;
          lngSum += pt.longitude;
          count++;
        }
      }
      if (count > 0) {
        center = LatLng(latSum / count, lngSum / count);
      }
    }

    return ShareableMap(
      id: 'work_areas_map',
      name: 'Work Areas',
      description: 'All work area polygons',
      layers: [layer],
      defaultCenter: center,
      defaultZoom: 11.0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    // Extract all polygons from the map (there should be exactly one layer)
    final allPolygons = map.layers.expand((l) => l.polygons).toList();

    // Build a lookup of original work areas by name for matching
    final originalByName = <String, WorkArea>{};
    for (final wa in _loadedWorkAreas) {
      originalByName[wa.name] = wa;
    }

    // Track which original work areas are still present
    final matchedOriginalIds = <String>{};

    for (final polygon in allPolygons) {
      final existing = originalByName[polygon.name];

      if (existing != null) {
        // UPDATE — polygon still has matching original work area
        matchedOriginalIds.add(existing.id);

        // Check if points actually changed
        final pointsChanged =
            !_pointsEqual(existing.polygonPoints, polygon.points);
        final descChanged = existing.description != polygon.description;
        final nameChanged = existing.name != polygon.name;
        final estimateChanged =
            existing.letterBoxEstimate != polygon.letterBoxEstimate;

        if (pointsChanged || descChanged || nameChanged || estimateChanged) {
          final updated = existing.copyWith(
            name: polygon.name,
            description: polygon.description,
            polygonPoints: polygon.points,
            letterBoxEstimate: polygon.letterBoxEstimate,
          );
          await _firestoreService.updateWorkArea(updated);
        }
      } else {
        // CREATE — new polygon not matching any original work area
        final newWorkArea = WorkArea(
          id: '', // Firestore will assign
          name: polygon.name,
          description: polygon.description,
          polygonPoints: polygon.points,
          letterBoxEstimate: polygon.letterBoxEstimate,
          kmlFileName: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        await _firestoreService.addWorkArea(newWorkArea);
      }
    }

    // DELETE — original work areas not present in current polygons
    for (final wa in _loadedWorkAreas) {
      if (!matchedOriginalIds.contains(wa.id)) {
        await _firestoreService.deleteWorkArea(wa.id);
      }
    }

    // Refresh the loaded state so subsequent saves diff correctly
    _loadedWorkAreas = await _firestoreService.fetchWorkAreasOnce();
  }

  // ── Conversion helpers ──────────────────────────────────────────────

  /// Convert a [WorkArea] to a [CustomPolygon] for use in the map editor.
  static CustomPolygon _workAreaToPolygon(WorkArea wa) {
    return CustomPolygon(
      name: wa.name,
      description: wa.description,
      points: List<LatLng>.from(wa.polygonPoints),
      color: Colors.red,
      letterBoxEstimate: wa.letterBoxEstimate,
    );
  }

  /// Check if two point lists are equal.
  static bool _pointsEqual(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].latitude != b[i].latitude || a[i].longitude != b[i].longitude) {
        return false;
      }
    }
    return true;
  }
}
