import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/job.dart';
import '../models/map_layer.dart';
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
        canDrawPoints: false,
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

    // Convert existing workMaps to polygons on a single layer
    final layer = MapLayer(
      id: 'job_maps_layer',
      name: 'Job Maps',
      description: 'Work maps for ${_job.clientsDisplay}',
      order: 0,
      defaultColor: Colors.blue,
      polygons: _job.workMaps
          .map((p) => CustomPolygon(
                name: p.name,
                description: p.description,
                points: List<LatLng>.from(p.points),
                color: p.color,
                fillOpacity: p.fillOpacity,
                strokeWidth: p.strokeWidth,
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

    // Derive working area names from polygon names
    final workingAreaNames = polygons
        .map((p) => p.name)
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();

    await _onSave(polygons, workingAreaNames);
  }
}
