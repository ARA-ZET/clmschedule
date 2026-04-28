import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/job.dart';
import '../../providers/unfinished_work_areas_provider.dart';
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

/// Fixed layer id for polygons injected from matching unfinished work areas.
/// Polygons in this layer sync back to [UnfinishedWorkAreasProvider] on save
/// instead of being persisted on the job itself.
const String kUnfinishedAreasLayerId = 'unfinished_work_areas_layer';

/// Adapter that bridges the ShareableMapEditor to a single schedule [Job]'s
/// `workMaps` field.
///
/// **Load**: Converts `Job.workMaps` (`List<CustomPolygon>`) into a single-layer
/// [ShareableMap]. Also uses `Job.workingAreas` for context. When an
/// [UnfinishedWorkAreasProvider] is provided, any unfinished items whose
/// `clients` overlap with the current job's clients are added as a second
/// read-visible layer (`kUnfinishedAreasLayerId`).
///
/// **Save**: Extracts polygons from the job layer(s) and calls the provided
/// [onSave] callback. Polygons in the unfinished-areas layer are NOT sent to
/// the job; instead their updated points are written back to the matching
/// unfinished items via [UnfinishedWorkAreasProvider.updateItemWorkMaps].
class ScheduleJobAdapter extends MapDataAdapter {
  final Job _job;
  final ScheduleJobSaveCallback _onSave;
  final String? distributorName;
  final UnfinishedWorkAreasProvider? _unfinishedProvider;

  /// Maps polygon name → source unfinished item id. Populated during [load]
  /// so we can route edits back to the right Firestore doc on [save].
  final Map<String, String> _polygonNameToUnfinishedId = {};

  ScheduleJobAdapter({
    required Job job,
    required ScheduleJobSaveCallback onSave,
    this.distributorName,
    UnfinishedWorkAreasProvider? unfinishedProvider,
  })  : _job = job,
        _onSave = onSave,
        _unfinishedProvider = unfinishedProvider;

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
    final hasDropoffPoint = pointWorkMaps.any(
        (p) => p.pointCategory == PointCategory.dropoff && p.points.isNotEmpty);
    final inferredDropOff = _job.dropOffPoint ??
        Job.estimateDropOffPointFromWorkMaps(_job.workMaps);
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
          .followedBy(
            !hasDropoffPoint && inferredDropOff != null
                ? [
                    MapPoint.create(
                      name: 'Drop-off Point',
                      description: 'Auto-generated drop-off point',
                      position: inferredDropOff,
                      color: Colors.blue,
                      pointCategory: PointCategory.dropoff,
                    ),
                  ]
                : const <MapPoint>[],
          )
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
      layers: [layer, ..._buildUnfinishedLayers(now)],
      defaultCenter: center,
      defaultZoom: 13.0,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Build a list containing at most one layer of polygons sourced from
  /// unfinished work area items whose clients overlap with this job.
  ///
  /// Also populates [_polygonNameToUnfinishedId] so [save] can route edits
  /// back to the originating Firestore document.
  List<MapLayer> _buildUnfinishedLayers(DateTime now) {
    final provider = _unfinishedProvider;
    if (provider == null) {
      debugPrint('[UnfinishedLayer] skipped: provider is null');
      return const [];
    }
    if (_job.clients.isEmpty) {
      debugPrint(
          '[UnfinishedLayer] skipped: job "${_job.id}" has no clients');
      return const [];
    }

    final jobClients = _job.clients.map((c) => c.trim().toLowerCase()).toSet();
    debugPrint(
        '[UnfinishedLayer] job "${_job.id}" clients (raw): ${_job.clients}');
    debugPrint(
        '[UnfinishedLayer] job clients (normalised): $jobClients');
    debugPrint(
        '[UnfinishedLayer] scanning ${provider.items.length} unfinished item(s)');

    final matchedPolygons = <CustomPolygon>[];
    _polygonNameToUnfinishedId.clear();

    for (final item in provider.items) {
      final itemClientsNorm =
          item.clients.map((c) => c.trim().toLowerCase()).toList();
      final overlap = itemClientsNorm
          .where((c) => jobClients.contains(c))
          .toList();
      final hasMatch = overlap.isNotEmpty;
      debugPrint(
          '[UnfinishedLayer]  item "${item.id}" clients=${item.clients} '
          '(norm=$itemClientsNorm) polygons=${item.workMaps.where((p) => p.isPolygon).length} '
          'match=$hasMatch overlap=$overlap');
      if (!hasMatch) continue;

      for (final wm in item.workMaps.where((p) => p.isPolygon)) {
        if (wm.name.isEmpty) {
          debugPrint(
              '[UnfinishedLayer]    skipping unnamed polygon in item "${item.id}"');
          continue;
        }
        debugPrint(
            '[UnfinishedLayer]    adding polygon "${wm.name}" (${wm.points.length} pts) from item "${item.id}"');
        matchedPolygons.add(CustomPolygon(
          name: wm.name,
          description: wm.description,
          points: List<LatLng>.from(wm.points),
          color: wm.color,
          fillOpacity: wm.fillOpacity,
          strokeWidth: wm.strokeWidth,
          type: wm.type,
        ));
        _polygonNameToUnfinishedId[wm.name] = item.id;
      }
    }

    debugPrint(
        '[UnfinishedLayer] total matched polygons: ${matchedPolygons.length}');
    if (matchedPolygons.isEmpty) return const [];

    return [
      MapLayer(
        id: kUnfinishedAreasLayerId,
        name: 'Unfinished Areas',
        description: 'Matched from unfinished work areas by client name',
        order: 1,
        defaultColor: Colors.indigo.shade600,
        polygons: matchedPolygons,
        polylines: const [],
        points: const [],
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }

  @override
  Future<void> save(ShareableMap map) async {
    // Separate layers: unfinished-areas layer syncs back to the unfinished
    // provider; all other layers are persisted on the job itself.
    final jobLayers =
        map.layers.where((l) => l.id != kUnfinishedAreasLayerId).toList();
    final unfinishedLayers =
        map.layers.where((l) => l.id == kUnfinishedAreasLayerId).toList();

    // --- Route unfinished polygon edits back to UnfinishedWorkAreasProvider.
    if (_unfinishedProvider != null && unfinishedLayers.isNotEmpty) {
      final polysByItemId = <String, List<CustomPolygon>>{};
      for (final layer in unfinishedLayers) {
        for (final p in layer.polygons) {
          // Match by polygon name. If the user renamed a polygon while editing
          // it becomes orphaned and is skipped (the job layer's own save still
          // runs, so no data is lost overall).
          final itemId = _polygonNameToUnfinishedId[p.name];
          if (itemId == null) continue;
          polysByItemId.putIfAbsent(itemId, () => []).add(p);
        }
      }
      for (final entry in polysByItemId.entries) {
        try {
          await _unfinishedProvider.updateItemWorkMaps(entry.key, entry.value);
        } catch (e) {
          debugPrint('[ScheduleJobAdapter.save] Failed to sync unfinished $e');
        }
      }
    }

    // --- Collect elements from job-owned layers for the Job.workMaps write.
    final polygons = jobLayers.expand((l) => l.polygons).toList();

    // Collect all polylines and convert to CustomPolygon with polyline type
    final polylineElements = jobLayers
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
    final pointElements = jobLayers
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

    // Derive working area names from polygon elements only
    final workingAreaNames = allWorkMaps
        .where((e) => e.isPolygon)
        .map((p) => p.name)
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();

    await _onSave(allWorkMaps, workingAreaNames);
  }
}
