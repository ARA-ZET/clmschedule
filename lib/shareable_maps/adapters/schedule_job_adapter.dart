import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/job.dart';
import '../models/map_layer.dart';
import '../models/map_point.dart';
import '../models/map_polyline.dart';
import '../models/shareable_map.dart';
import 'map_data_adapter.dart';

/// Callback signature for saving updated polygons and working area names
/// back to the schedule job.
typedef ScheduleJobSaveCallback = Future<void> Function(
  List<CustomPolygon> polygons,
  List<String> workingAreaNames,
);

/// Adapter that bridges the ShareableMapEditor to a single schedule [Job]'s
/// `workMaps` field.
///
/// **Load**: Converts `Job.workMaps` (`List<CustomPolygon>`) into a single-layer
/// [ShareableMap]. Also uses `Job.workingAreas` for context.
///
/// **Save**: Extracts all polygons from the map, derives area names from
/// polygon names, and calls the provided [onSave] callback.
class ScheduleJobAdapter extends MapDataAdapter {
  final Job _job;
  final ScheduleJobSaveCallback _onSave;
  final String? distributorName;

  ScheduleJobAdapter({
    required Job job,
    required ScheduleJobSaveCallback onSave,
    this.distributorName,
  })  : _job = job,
        _onSave = onSave;

  @override
  String get adapterId => 'schedule_job';

  @override
  String get displayName {
    final parts = <String>[];
    if (distributorName != null && distributorName!.isNotEmpty) {
      parts.add(distributorName!);
    }
    // Format date as "15 Mar"
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    parts.add('${_job.date.day} ${months[_job.date.month - 1]}');
    if (_job.clientsDisplay.isNotEmpty) {
      parts.add(_job.clientsDisplay);
    }
    return parts.isNotEmpty ? parts.join(' · ') : _job.id;
  }

  @override
  MapEditorCapabilities get capabilities => const MapEditorCapabilities(
        canDrawPolygons: true,
        canDrawPolylines: true,
        canDrawPoints: true,
        canImportKml: true,
        canImportGpx: false,
        canExport: true,
        canManageLayers: false, // Single layer for schedule jobs
        canEditStyle: true,
        canDelete: true,
        showSaveButton: true,
        readOnly: false,
      );

  @override
  Future<ShareableMap> load() async {
    final now = DateTime.now();

    // Debug: log all workMaps being loaded
    debugPrint(
        '[ScheduleJobAdapter.load] Job ${_job.id} has ${_job.workMaps.length} workMaps:');
    for (final wm in _job.workMaps) {
      debugPrint('  "${wm.name}" type=${wm.type} isPolygon=${wm.isPolygon} '
          'isPolyline=${wm.isPolyline} isPoint=${wm.isPoint} isMarker=${wm.isMarker} '
          'points=${wm.points.length} pointCategory=${wm.pointCategory.id}');
    }

    // Split workMaps by element type
    final polygonWorkMaps = _job.workMaps.where((p) => p.isPolygon).toList();
    final polylineWorkMaps = _job.workMaps.where((p) => p.isPolyline).toList();
    final pointWorkMaps = _job.workMaps.where((p) => p.isPoint).toList();
    debugPrint(
        '[ScheduleJobAdapter.load] Split: ${polygonWorkMaps.length} polygons, '
        '${polylineWorkMaps.length} polylines, ${pointWorkMaps.length} points');

    // Convert existing workMaps to a single layer
    final layer = MapLayer(
      id: 'job_maps_layer',
      name: 'Job Maps',
      description: 'Work maps for ${_job.clientsDisplay}',
      order: 0,
      defaultColor: Colors.blue,
      polygons: polygonWorkMaps
          .map((p) => CustomPolygon(
                name: p.name,
                description: p.description,
                points: List<LatLng>.from(p.points),
                color: p.color,
                fillOpacity: p.fillOpacity,
                strokeWidth: p.strokeWidth,
                type: p.type,
              ))
          .toList(),
      polylines: polylineWorkMaps
          .map((p) => MapPolyline.create(
                name: p.name,
                description: p.description,
                points: List<LatLng>.from(p.points),
                color: p.color,
                strokeWidth: p.strokeWidth.toDouble(),
                isDashed: p.isDashed,
              ))
          .toList(),
      points: pointWorkMaps
          .map((p) => MapPoint.create(
                name: p.name,
                description: p.description,
                position:
                    p.points.isNotEmpty ? p.points.first : const LatLng(0, 0),
                color: p.color,
                pointCategory: p.pointCategory,
              ))
          .toList(),
      createdAt: now,
      updatedAt: now,
    );

    // Center on existing polygons or fall back to Cape Town
    LatLng center = const LatLng(-33.925, 18.425);
    if (_job.workMaps.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      int count = 0;
      for (final polygon in _job.workMaps) {
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
      id: 'job_${_job.id}',
      name: displayName,
      description: 'Work areas: ${_job.workingAreasDisplay}',
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

    // Collect all polylines and convert to CustomPolygon with polyline type
    final polylineElements = map.layers
        .expand((l) => l.polylines)
        .map((p) => CustomPolygon(
              name: p.name,
              description: p.description,
              points: List<LatLng>.from(p.points),
              color: p.color,
              strokeWidth: p.strokeWidth.toInt(),
              isDashed: p.isDashed,
              type: MapElementType.polyline,
            ))
        .toList();

    // Collect all points/markers and convert to CustomPolygon with point type
    final pointElements = map.layers
        .expand((l) => l.points)
        .map((p) => CustomPolygon(
              name: p.name,
              description: p.description,
              points: [p.position],
              color: p.color,
              type: MapElementType.point,
              pointCategory: p.pointCategory,
            ))
        .toList();

    // Combine all element types for storage in Job.workMaps
    final allWorkMaps = [...polygons, ...polylineElements, ...pointElements];

    // Debug: log what we're saving
    debugPrint(
        '[ScheduleJobAdapter.save] Saving ${allWorkMaps.length} workMaps: '
        '${polygons.length} polygons, ${polylineElements.length} polylines, ${pointElements.length} points');
    for (final wm in allWorkMaps) {
      debugPrint('  "${wm.name}" type=${wm.type} points=${wm.points.length} '
          'pointCategory=${wm.pointCategory.id}');
    }

    // Derive working area names from all element names
    final workingAreaNames = allWorkMaps
        .map((p) => p.name)
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();

    await _onSave(allWorkMaps, workingAreaNames);
  }
}
