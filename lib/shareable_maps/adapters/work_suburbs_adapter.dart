import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/work_suburb.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';
import '../services/suburb_data_service.dart';
import 'map_data_adapter.dart';

/// Adapter that bridges the ShareableMapEditor to the suburb polygon dataset.
///
/// **Load**: Downloads the KML from Firebase Storage (with in-memory session
/// cache and bundled-asset fallback), parses it, then merges any user
/// overrides from `workSuburbs/overrides`.
///
/// **Save**: Persists only the user-editable fields (letterBoxEstimate,
/// description) to `workSuburbs/overrides`. Polygon coordinates are never
/// written back — they live exclusively in the KML.
class WorkSuburbsAdapter extends MapDataAdapter {
  final SuburbDataService _suburbService;

  /// Optional center to focus the map on initially.
  final LatLng? initialCenter;

  WorkSuburbsAdapter({
    SuburbDataService? suburbService,
    this.initialCenter,
  }) : _suburbService = suburbService ?? SuburbDataService();

  @override
  String get adapterId => 'work_suburbs';

  @override
  String get displayName => 'Work Suburbs';

  @override
  MapEditorCapabilities get capabilities =>
      const MapEditorCapabilities.polygonOnly();

  @override
  Future<ShareableMap> load() async {
    final suburbs = await _suburbService.loadSuburbs();

    final polygons = suburbs.map(_suburbToPolygon).toList();

    final now = DateTime.now();
    final layer = MapLayer(
      id: 'work_suburbs_layer',
      name: 'Work Suburbs',
      description: 'Cape Town suburb polygons',
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

    // Build a name→suburb lookup from the cached base KML suburbs so we can
    // resolve the canonical id (SL_OFC_SBRB_KEY) for each polygon.
    final base = _suburbService.baseSuburbs ?? [];
    final baseByName = {for (final s in base) s.name: s};

    final suburbs = allPolygons.map((polygon) {
      final match = baseByName[polygon.name];
      return WorkSuburb(
        // Use the original KML id when available; generate a stable id for new
        // user-drawn polygons so they survive a save/reload cycle.
        id: match?.id ??
            'usr_${polygon.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}',
        name: polygon.name,
        description: polygon.description,
        polygonPoints:
            polygon.points, // pass real points so delta can detect edits
        letterBoxEstimate: polygon.letterBoxEstimate,
      );
    }).toList();

    await _suburbService.saveDelta(suburbs);
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
