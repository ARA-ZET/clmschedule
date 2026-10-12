import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/job.dart';
import '../../models/job_area_link.dart';
import '../../models/job_linked_map.dart';
import '../../providers/unfinished_work_areas_provider.dart';
import '../../services/job_cloud_map_data_service.dart';
import '../models/map_layer.dart';
import '../models/map_point.dart';
import '../models/map_polyline.dart';
import '../models/shareable_map.dart';
import '../services/shareable_maps_firestore_service.dart';
import '../utils/linked_map_polygons.dart';
import 'map_data_adapter.dart';

/// Callback signature for saving updated polygons and working area names
/// back to the schedule job.
typedef ScheduleJobSaveCallback = Future<void> Function(
  List<CustomPolygon> polygons,
  List<String> workingAreaNames,
);

/// Callback signature for linking an existing ShareableMap to the schedule
/// job (see `MapDataAdapter.onLinkExistingMap`). Only `mapId`/`monthKey` are
/// persisted — the map's folder path/polygons are fetched live wherever
/// they're needed (e.g. `PrintMapView`), not cached here.
typedef ScheduleJobLinkMapCallback = Future<void> Function(
  String mapId,
  String monthKey,
  String mapName,
);

/// Fixed layer id for polygons injected from matching unfinished work areas.
/// Polygons in this layer sync back to [UnfinishedWorkAreasProvider] on save
/// instead of being persisted on the job itself.
const String kUnfinishedAreasLayerId = 'unfinished_work_areas_layer';

/// Fixed layer id for the recorded GPS tracks of the linked client maps —
/// the same overlay the print map offers, behind a show/hide toggle.
const String kLinkedClientMapTracksLayerId = 'linked_client_map_tracks_layer';

/// Fixed layer id for the polygons of the client maps linked to this job.
/// Shown for reference so the user can see the client's ground and copy the
/// parts this distributor is being sent to; never saved onto the job itself
/// (see [MapDataAdapter.referenceLayerId]). Copying happens through the
/// editor's "Client map" action, which moves polygons into the job layer.
const String kLinkedClientMapLayerId = 'linked_client_map_layer';

/// Fixed layer id for the client-map areas allocated to this job by link
/// (`Job.areaLinks`). Their outlines belong to the client map, so this layer
/// is never saved onto the job — edit them on the client map instead.
const String kAllocatedAreasLayerId = 'allocated_client_areas_layer';

/// The job's own layer — everything in it is saved to `Job.workMaps`.
const String kJobMapsLayerId = 'job_maps_layer';

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
  final ScheduleJobLinkMapCallback? _onLinkExistingMap;
  final String? distributorName;
  final UnfinishedWorkAreasProvider? _unfinishedProvider;

  /// Maps polygon name → source unfinished item id. Populated during [load]
  /// so we can route edits back to the right Firestore doc on [save].
  final Map<String, String> _polygonNameToUnfinishedId = {};

  /// The client maps this adapter is currently showing. Starts from the job
  /// snapshot and grows with [onLinkExistingMap], so linking inside the
  /// editor can refresh the reference layer without reloading the map.
  final List<JobLinkedMap> _links;

  ScheduleJobAdapter({
    required Job job,
    required ScheduleJobSaveCallback onSave,
    ScheduleJobLinkMapCallback? onLinkExistingMap,
    this.distributorName,
    UnfinishedWorkAreasProvider? unfinishedProvider,
  })  : _job = job,
        _links = List<JobLinkedMap>.from(job.effectiveLinkedMaps),
        _onSave = onSave,
        _onLinkExistingMap = onLinkExistingMap,
        _unfinishedProvider = unfinishedProvider;

  @override
  Future<void> onLinkExistingMap({
    required String mapId,
    required String monthKey,
    required String mapName,
    String? storageFolderPath,
  }) async {
    if (!_links.any((l) => l.mapId == mapId)) {
      _links.add(JobLinkedMap(mapId: mapId, monthKey: monthKey, name: mapName));
    }
    await _onLinkExistingMap?.call(mapId, monthKey, mapName);
  }

  /// True once at least one client map is linked, so the editor can offer
  /// its polygons and tracks.
  bool get hasLinkedMap => _links.isNotEmpty;

  @override
  String? get referenceLayerId => kLinkedClientMapLayerId;

  @override
  String? get referenceTracksLayerId => kLinkedClientMapTracksLayerId;

  @override
  bool get hasReferenceTracks => _links.isNotEmpty;

  Future<List<ShareableMap>> _loadLinkedMaps() async {
    final maps = <ShareableMap>[];
    for (final link in _links) {
      try {
        final map = await ShareableMapsFirestoreService()
            .getMap(link.monthKey, link.mapId);
        if (map != null) maps.add(map);
      } catch (e) {
        debugPrint('[ScheduleJobAdapter] linked map ${link.mapId}: $e');
      }
    }
    return maps;
  }

  @override
  Future<MapLayer?> loadReferenceLayer() async {
    if (_links.isEmpty) return null;
    final maps = await _loadLinkedMaps();
    if (maps.isEmpty) return null;

    // Polygons the job already holds are drawn from the job layer, so
    // showing them here as well would just be a second outline on top.
    final seen = _job.workMaps.map(polygonGeometryKey).toSet();
    final polygons = [
      for (final map in maps)
        for (final group in linkedMapPolygonGroups(map))
          for (final p in group.polygons)
            if (seen.add(polygonGeometryKey(p))) p,
    ];
    if (polygons.isEmpty) return null;

    final now = DateTime.now();
    return MapLayer(
      id: kLinkedClientMapLayerId,
      name: maps.length == 1
          ? 'Client map · ${maps.first.name}'
          : 'Client maps · ${maps.map((m) => m.name).join(', ')}',
      description: 'Polygons from the linked client maps — not saved on the '
          'job until you add them',
      order: 2,
      defaultColor: Colors.deepPurple,
      polygons: polygons,
      polylines: const [],
      points: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<MapLayer?> loadReferenceTracksLayer() async {
    if (_links.isEmpty) return null;
    final maps = await _loadLinkedMaps();
    final tracks = <MapPolyline>[];
    for (final map in maps) {
      final folderPath = map.cloudFolderPaths.isNotEmpty
          ? map.cloudFolderPaths.first
          : map.storageFolderPath;
      if (folderPath == null || folderPath.isEmpty) continue;
      try {
        tracks.addAll(
            await JobCloudMapDataService().fetchCompiledTracks(folderPath));
      } catch (e) {
        debugPrint('[ScheduleJobAdapter] tracks for ${map.name}: $e');
      }
    }
    if (tracks.isEmpty) return null;

    final now = DateTime.now();
    return MapLayer(
      id: kLinkedClientMapTracksLayerId,
      name: 'Recorded tracks',
      description: 'Walked tracks from the linked client maps',
      order: 3,
      defaultColor: Colors.blueGrey,
      polygons: const [],
      polylines: tracks,
      points: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

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
        canLinkExistingMap: true,
      );

  @override
  Future<ShareableMap> load() async {
    final now = DateTime.now();
    final linkedLayer = await loadReferenceLayer();

    // Split workMaps by element type. Areas resolved from client-map links
    // get a layer of their own, which is not saved back onto the job.
    final ownWorkMaps = _job.ownWorkMaps;
    final allocatedAreas = _job.workMaps.where(JobAreaLink.isResolved).toList();
    final polygonWorkMaps = ownWorkMaps.where((p) => p.isPolygon).toList();
    final polylineWorkMaps = ownWorkMaps.where((p) => p.isPolyline).toList();
    final pointWorkMaps = ownWorkMaps.where((p) => p.isPoint).toList();
    final hasDropoffPoint = pointWorkMaps.any(
        (p) => p.pointCategory == PointCategory.dropoff && p.points.isNotEmpty);
    final inferredDropOff = _job.dropOffPoint ??
        Job.estimateDropOffPointFromWorkMaps(_job.workMaps);

    // Convert existing workMaps to a single layer
    final layer = MapLayer(
      id: kJobMapsLayerId,
      name: 'Job Maps',
      description: 'Work maps for ${_job.clientsDisplay}',
      order: 0,
      defaultColor: Colors.blue,
      polygons: polygonWorkMaps
          .map((p) => p.copyWith(points: List<LatLng>.from(p.points)))
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
          .toList()
          .asMap()
          .entries
          .map((entry) {
            final p = entry.value;
            return MapPoint(
              id: 'job_${_job.id}_point_${entry.key}',
              name: p.name,
              description: p.description,
              position:
                  p.points.isNotEmpty ? p.points.first : const LatLng(0, 0),
              color: p.color,
              pointCategory: p.pointCategory,
              createdAt: now,
              updatedAt: now,
            );
          })
          .followedBy(
            !hasDropoffPoint && inferredDropOff != null
                ? [
                    MapPoint(
                      id: 'job_${_job.id}_dropoff',
                      name: 'Drop-off Point',
                      description: 'Auto-generated drop-off point',
                      position: inferredDropOff,
                      color: Colors.blue,
                      pointCategory: PointCategory.dropoff,
                      createdAt: now,
                      updatedAt: now,
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
      layers: [
        layer,
        if (allocatedAreas.isNotEmpty)
          MapLayer(
            id: kAllocatedAreasLayerId,
            name: 'Allocated from client maps',
            description: 'Linked to the client map — changes made here are '
                'not saved; edit the client map instead',
            order: 1,
            defaultColor: Colors.teal,
            polygons: allocatedAreas,
            createdAt: now,
            updatedAt: now,
          ),
        ..._buildUnfinishedLayers(now),
        ...?(linkedLayer == null ? null : [linkedLayer]),
      ],
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
      if (kDebugMode) debugPrint('[UnfinishedLayer] skipped: provider is null');
      return const [];
    }

    final match = JobCloudMapDataService.matchingGapAreas(_job, provider);
    _polygonNameToUnfinishedId
      ..clear()
      ..addAll(match.polygonNameToItemId);

    if (match.polygons.isEmpty) return const [];

    return [
      MapLayer(
        id: kUnfinishedAreasLayerId,
        name: 'Unfinished Areas',
        description: 'Matched from unfinished work areas by client name',
        order: 1,
        defaultColor: Colors.indigo.shade600,
        polygons: match.polygons,
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
    final jobLayers = map.layers
        .where((l) =>
            l.id != kUnfinishedAreasLayerId &&
            l.id != kAllocatedAreasLayerId &&
            l.id != kLinkedClientMapLayerId &&
            l.id != kLinkedClientMapTracksLayerId)
        .toList();
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
    final polygons = jobLayers
        .expand((l) => l.polygons)
        .map((p) => p.copyWith(points: List<LatLng>.from(p.points)))
        .toList();

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

    if (kDebugMode) {
      debugPrint(
          '[ScheduleJobAdapter.save] Saving ${allWorkMaps.length} workMaps: '
          '${polygons.length} polygons, ${polylineElements.length} polylines, ${pointElements.length} points');
      for (final wm in allWorkMaps) {
        debugPrint('  "${wm.name}" type=${wm.type} points=${wm.points.length} '
            'pointCategory=${wm.pointCategory.id}');
      }
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
