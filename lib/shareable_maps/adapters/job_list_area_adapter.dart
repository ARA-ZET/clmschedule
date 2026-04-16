import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../../models/custom_polygon.dart';
import '../../models/job_list_item.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';
import '../services/map_link_service.dart';
import 'map_data_adapter.dart';

/// Callback signature for saving updated polygons and optional area link
/// back to the job list item.
typedef JobListAreaSaveCallback = Future<void> Function(
  List<CustomPolygon> polygons,
  String? areaLink,
);

/// Adapter that bridges the ShareableMapEditor to a [JobListItem]'s
/// `customPolygons` and `area` fields.
///
/// **Load**: Converts `JobListItem.customPolygons` into a single-layer
/// [ShareableMap]. The `area` field (currently a Google Maps link) is
/// stored as context but will eventually be replaced with a shareable
/// KML/GPX link from Cloud Storage.
///
/// **Save**: Extracts all polygons from the map and calls the provided
/// [onSave] callback with the updated polygons. In the future, this
/// adapter will also export KML to Cloud Storage and provide a
/// download URL for the `area` field.
class JobListAreaAdapter extends MapDataAdapter {
  final JobListItem _item;
  final JobListAreaSaveCallback _onSave;

  JobListAreaAdapter({
    required JobListItem item,
    required JobListAreaSaveCallback onSave,
  })  : _item = item,
        _onSave = onSave;

  @override
  String get adapterId => 'job_list_area';

  @override
  String get displayName =>
      'Area: ${_item.client.isNotEmpty ? _item.client : _item.id}';

  @override
  MapEditorCapabilities get capabilities => const MapEditorCapabilities(
        canDrawPolygons: true,
        canDrawPolylines: true,
        canDrawPoints: true,
        canImportKml: true,
        canImportGpx: true,
        canExport: true,
        canManageLayers: true,
        canEditStyle: true,
        canDelete: true,
        showSaveButton: true,
        readOnly: false,
      );

  @override
  Future<ShareableMap> load() async {
    final now = DateTime.now();

    // Convert existing custom polygons
    final polygons = _item.customPolygons
        .map((p) => CustomPolygon(
              name: p.name,
              description: p.description,
              points: List<LatLng>.from(p.points),
              color: p.color,
              fillOpacity: p.fillOpacity,
              strokeWidth: p.strokeWidth,
            ))
        .toList();

    final layer = MapLayer(
      id: 'job_list_layer',
      name: _item.area.isNotEmpty ? _item.area : 'Job Area',
      description: 'Area polygons for job: ${_item.client}',
      order: 0,
      defaultColor: Colors.blue,
      polygons: polygons,
      createdAt: now,
      updatedAt: now,
    );

    // Center on existing polygons
    LatLng center = const LatLng(-33.925, 18.425);
    if (polygons.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      int count = 0;
      for (final polygon in polygons) {
        for (final pt in polygon.points) {
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
      id: 'joblist_${_item.id}',
      name: displayName,
      description:
          _item.area.isNotEmpty ? 'Current area: ${_item.area}' : 'No area set',
      layers: [layer],
      defaultCenter: center,
      defaultZoom: 13.0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    // Collect all polygons from all layers
    final polygons = map.layers.expand((l) => l.polygons).toList();

    // Generate share link URL if the job has a linked shareable map
    String? areaLink;
    if (_item.shareableMapId.isNotEmpty) {
      try {
        final monthKey = DateFormat('MM-yyyy').format(_item.date);
        final linkService =
            MapLinkService(firestore: FirebaseFirestore.instance);
        final shareCode = await linkService.createShareLink(
          monthKey: monthKey,
          mapId: _item.shareableMapId,
          mapName: _item.client,
        );
        areaLink = MapLinkService.buildShareUrl(shareCode);
      } catch (e) {
        debugPrint('⚠️ JobListAreaAdapter: Share link generation failed: $e');
      }
    }

    await _onSave(polygons, areaLink);
  }
}
