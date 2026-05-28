import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/work_suburb.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';
import '../services/suburb_data_service.dart';
import 'map_data_adapter.dart';

/// Adapter that bridges the ShareableMapEditor to the suburb polygon dataset.
///
/// **Load**: Reads the canonical `workSuburbs/main.suburbs` array.
/// **Save**: Overwrites that array so edited, added and deleted polygons are
/// all persisted in Firestore.
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
      defaultColor: WorkSuburb.defaultColor,
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
    final suburbs = allPolygons.asMap().entries.map((entry) {
      return _polygonToSuburb(entry.value, entry.key);
    }).toList();

    await _suburbService.saveSuburbs(suburbs);
  }

  // ── Conversion helpers ──────────────────────────────────────────────

  static CustomPolygon _suburbToPolygon(WorkSuburb s) {
    return CustomPolygon(
      id: s.id,
      name: s.name,
      description: s.description,
      points: List<LatLng>.from(s.polygonPoints),
      color: s.color,
      letterBoxEstimate: s.letterBoxEstimate,
    );
  }

  static WorkSuburb _polygonToSuburb(CustomPolygon polygon, int index) {
    return WorkSuburb(
      id: _polygonId(polygon, index),
      name: polygon.name,
      description: polygon.description,
      polygonPoints: List<LatLng>.from(polygon.points),
      letterBoxEstimate: polygon.letterBoxEstimate,
      color: polygon.color,
    );
  }

  static String _polygonId(CustomPolygon polygon, int index) {
    final existing = polygon.id?.trim();
    if (existing != null && existing.isNotEmpty) return existing;

    final slug = polygon.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return slug.isEmpty ? 'usr_suburb_$index' : 'usr_$slug';
  }
}
