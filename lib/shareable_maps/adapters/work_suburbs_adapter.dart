import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/work_suburb.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';
import '../services/suburb_data_service.dart';
import 'map_data_adapter.dart';

/// Adapter that bridges the ShareableMapEditor to the suburb polygon dataset
/// stored in Firestore at `workSuburbs/main`.
///
/// **Load**: Reads the `suburbs` array from the Firestore document and converts
/// each [WorkSuburb] — including its stored color — into a [CustomPolygon].
///
/// **Save**: Converts each edited [CustomPolygon] back into a [WorkSuburb]
/// (preserving id, color, letterBoxEstimate, description, and coordinates) and
/// writes the full list back to `workSuburbs/main`.
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

    // Compute a center from polygon points when no override is given.
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

    final suburbs = allPolygons.map((polygon) {
      // Recover the stable suburb id from the polygon's optional id field.
      // Fall back to a slug derived from the name for user-drawn polygons.
      final suburbId = (polygon.id != null && polygon.id!.isNotEmpty)
          ? polygon.id!
          : 'usr_${polygon.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}';

      return WorkSuburb(
        id: suburbId,
        name: polygon.name,
        description: polygon.description,
        polygonPoints: polygon.points,
        letterBoxEstimate: polygon.letterBoxEstimate,
        color: polygon.color,
      );
    }).toList();

    await _suburbService.saveSuburbs(suburbs);
  }

  // ── Conversion helpers ──────────────────────────────────────────────────

  /// Converts a [WorkSuburb] to a [CustomPolygon], preserving the stored color
  /// and the stable suburb id for round-trip identity on save.
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
}
