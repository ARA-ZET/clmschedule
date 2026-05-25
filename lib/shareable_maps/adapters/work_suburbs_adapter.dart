import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/work_suburb.dart';
import '../../services/firestore_service.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';
import 'map_data_adapter.dart';

/// Adapter that bridges the ShareableMapEditor to the single
/// `workSuburbs/main` Firestore document.
///
/// **Load**: Reads the `suburbs` array from the single document and converts
/// each entry into a [CustomPolygon] on a single layer called "Work Suburbs".
///
/// **Save**: Overwrites the entire `suburbs` array with the current polygons.
class WorkSuburbsAdapter extends MapDataAdapter {
  final FirestoreService _firestoreService;

  /// Optional center to focus the map on initially.
  final LatLng? initialCenter;

  WorkSuburbsAdapter({
    FirestoreService? firestoreService,
    this.initialCenter,
  }) : _firestoreService = firestoreService ?? FirestoreService();

  @override
  String get adapterId => 'work_suburbs';

  @override
  String get displayName => 'Work Suburbs';

  @override
  MapEditorCapabilities get capabilities =>
      const MapEditorCapabilities.polygonOnly();

  @override
  Future<ShareableMap> load() async {
    final suburbs = await _firestoreService.fetchWorkSuburbsOnce();

    final polygons = suburbs.map(_suburbToPolygon).toList();

    final now = DateTime.now();
    final layer = MapLayer(
      id: 'work_suburbs_layer',
      name: 'Work Suburbs',
      description: 'Polygons from the workSuburbs/main document',
      order: 0,
      defaultColor: Colors.blue,
      polygons: polygons,
      createdAt: now,
      updatedAt: now,
    );

    LatLng center = initialCenter ?? const LatLng(-33.925, 18.425);
    if (suburbs.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      int count = 0;
      for (final s in suburbs) {
        for (final pt in s.polygonPoints) {
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
      id: 'work_suburbs_map',
      name: 'Work Suburbs',
      description: 'All work suburb polygons',
      layers: [layer],
      defaultCenter: center,
      defaultZoom: 11.0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    final allPolygons = map.layers.expand((l) => l.polygons).toList();

    // Convert each polygon back to a WorkSuburb, preserving id by name match.
    // Polygons added in the editor that have no matching id get a new uuid-like
    // id derived from their name and timestamp.
    final existing = await _firestoreService.fetchWorkSuburbsOnce();
    final existingByName = {for (final s in existing) s.name: s};

    final updated = allPolygons.map((polygon) {
      final match = existingByName[polygon.name];
      return WorkSuburb(
        id: match?.id ?? '${polygon.name}_${DateTime.now().millisecondsSinceEpoch}',
        name: polygon.name,
        description: polygon.description,
        polygonPoints: polygon.points,
        letterBoxEstimate: polygon.letterBoxEstimate,
      );
    }).toList();

    await _firestoreService.saveWorkSuburbs(updated);
  }

  // ── Conversion helpers ──────────────────────────────────────────────

  static CustomPolygon _suburbToPolygon(WorkSuburb s) {
    return CustomPolygon(
      name: s.name,
      description: s.description,
      points: List<LatLng>.from(s.polygonPoints),
      color: Colors.blue,
      letterBoxEstimate: s.letterBoxEstimate,
    );
  }
}
