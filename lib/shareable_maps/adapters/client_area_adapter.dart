import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/client_area.dart';
import '../../models/custom_polygon.dart';
import '../../services/client_area_service.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';
import 'map_data_adapter.dart';

/// Adapter that bridges the ShareableMapEditor to the `/clientAreas/`
/// collection — the Client Maps library.
///
/// The twin of [WorkAreaCollectionAdapter], and deliberately so: Client Maps
/// is meant to behave exactly like Work Areas, so anything learned on one
/// screen transfers to the other.
///
/// **Load**: every [ClientArea] becomes a [CustomPolygon] on one layer.
///
/// **Save**: diffs the current polygons against the load-time snapshot and
/// performs the minimal set of creates / updates / deletes.
///
/// Two fields have no home on [CustomPolygon] and are carried across a save by
/// matching against that snapshot rather than by round-tripping through the
/// editor: [ClientArea.client] and [ClientArea.surveyedAt]. Editing an area's
/// outline or its estimate in the map editor therefore leaves who it is for,
/// and when it was last surveyed, exactly as they were — which is right:
/// neither is something a redraw tells you.
class ClientAreaCollectionAdapter extends MapDataAdapter {
  final ClientAreaService _service;

  /// Optional centre to focus the map on initially.
  final LatLng? initialCenter;

  /// The library as it was at load time, for diffing on save and for looking
  /// up the fields the editor cannot carry.
  List<ClientArea> _loaded = const [];

  ClientAreaCollectionAdapter({
    ClientAreaService? service,
    this.initialCenter,
  }) : _service = service ?? ClientAreaService();

  static const String layerId = 'client_areas_layer';

  @override
  String get adapterId => 'client_area_collection';

  @override
  String get displayName => 'Client Maps';

  @override
  MapEditorCapabilities get capabilities =>
      const MapEditorCapabilities.polygonOnly();

  /// The client an on-screen polygon belongs to, or null when it is new or the
  /// area names no client. Lets the table panel show the column without
  /// [CustomPolygon] having to grow a field the rest of the app has no use for.
  String? clientFor(String? polygonId) {
    if (polygonId == null || polygonId.isEmpty) return null;
    for (final area in _loaded) {
      if (area.id == polygonId) {
        return area.client.isEmpty ? null : area.client;
      }
    }
    return null;
  }

  /// When the letterbox index under this polygon was last replaced from a
  /// walked round, or null when it never was.
  DateTime? surveyedAtFor(String? polygonId) {
    if (polygonId == null || polygonId.isEmpty) return null;
    for (final area in _loaded) {
      if (area.id == polygonId) return area.surveyedAt;
    }
    return null;
  }

  @override
  Future<ShareableMap> load() async {
    _loaded = await _service.fetchAllOnce();

    final now = DateTime.now();
    final layer = MapLayer(
      id: layerId,
      name: 'Client Maps',
      description: 'Polygons from the /clientAreas/ collection',
      order: 0,
      defaultColor: ClientArea.defaultColor,
      polygons: _loaded.map((a) => a.toCustomPolygon()).toList(),
      createdAt: now,
      updatedAt: now,
    );

    return ShareableMap(
      id: 'client_areas_map',
      name: 'Client Maps',
      description: 'All client area polygons',
      layers: [layer],
      defaultCenter: initialCenter ?? _centreOf(_loaded),
      defaultZoom: 11.0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    final polygons = map.layers.expand((l) => l.polygons).toList();

    final byId = {for (final a in _loaded) a.id: a};
    final byName = {for (final a in _loaded) a.name: a};
    final matched = <String>{};

    for (final polygon in polygons) {
      // Identity first, name only as a fallback — the same rule the work-area
      // adapter uses, so a rename updates rather than replaces.
      final existing = polygon.id == null
          ? byName[polygon.name]
          : byId[polygon.id] ?? byName[polygon.name];

      if (existing != null) {
        matched.add(existing.id);
        if (!_changed(existing, polygon)) continue;
        await _service.save(existing.copyWith(
          name: polygon.name,
          description: polygon.description,
          polygonPoints: polygon.points,
          color: polygon.color,
          letterBoxEstimate: polygon.letterBoxEstimate,
          letterBoxSplit: polygon.letterBoxSplit,
          importedLetterBoxEstimate: polygon.importedLetterBoxEstimate,
        ));
      } else {
        final now = DateTime.now();
        await _service.add(ClientArea(
          id: '',
          name: polygon.name,
          description: polygon.description,
          polygonPoints: polygon.points,
          color: polygon.color,
          letterBoxEstimate: polygon.letterBoxEstimate,
          letterBoxSplit: polygon.letterBoxSplit,
          importedLetterBoxEstimate: polygon.importedLetterBoxEstimate,
          createdAt: now,
          updatedAt: now,
        ));
      }
    }

    for (final area in _loaded) {
      if (!matched.contains(area.id)) await _service.delete(area.id);
    }

    // Refresh the snapshot so a second save in the same session diffs against
    // what is actually stored.
    _loaded = await _service.fetchAllOnce();
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  static bool _changed(ClientArea area, CustomPolygon polygon) =>
      area.name != polygon.name ||
      area.description != polygon.description ||
      area.color != polygon.color ||
      area.letterBoxEstimate != polygon.letterBoxEstimate ||
      area.letterBoxSplit != polygon.letterBoxSplit ||
      area.importedLetterBoxEstimate != polygon.importedLetterBoxEstimate ||
      !_pointsEqual(area.polygonPoints, polygon.points);

  static bool _pointsEqual(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].latitude != b[i].latitude || a[i].longitude != b[i].longitude) {
        return false;
      }
    }
    return true;
  }

  /// Average of every vertex, falling back to Cape Town for an empty library.
  static LatLng _centreOf(List<ClientArea> areas) {
    double latSum = 0, lngSum = 0;
    var count = 0;
    for (final area in areas) {
      for (final p in area.polygonPoints) {
        latSum += p.latitude;
        lngSum += p.longitude;
        count++;
      }
    }
    if (count == 0) return const LatLng(-33.925, 18.425);
    return LatLng(latSum / count, lngSum / count);
  }
}
