import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'job_area_link.dart';
import 'job_linked_map.dart';
import '../utils/schedule_time.dart';
import 'custom_polygon.dart';

const Object _dropOffPointUnchanged = Object();
const Object _pickUpPointUnchanged = Object();

// Keep enum for backwards compatibility during migration
enum JobStatus { standby, scheduled, done, urgent }

class Job {
  final String id;
  final List<String> clients;

  /// Per-client instructions (parallel list to [clients]). Backward-compatible:
  /// defaults to empty strings for jobs stored before this field was added.
  final List<String> clientInstructions;
  final List<String> workingAreas; // Names of the work areas for display
  final List<CustomPolygon>
      workMaps; // Custom polygons with name, description, points, color
  final String distributorId;
  final DateTime date;
  final String statusId; // Changed from JobStatus enum to String
  /// Driver-facing map/access instructions for the whole job.
  final String mapInstructions;
  final LatLng? dropOffPoint;
  final LatLng? pickUpPoint;

  /// Every client map linked to this job. A job can go out with more than
  /// one, so this is the list to read; [linkedMapId]/[linkedMapMonthKey]
  /// mirror the first entry for older code paths. Keep the two in step by
  /// going through [withLinkedMaps] rather than setting them separately.
  final List<JobLinkedMap> linkedMaps;

  /// Id of the first linked `ShareableMap` document (picked via
  /// `MapPickerDialog`), empty if none linked. Mirrors
  /// `JobListItem.shareableMapId`.
  final String linkedMapId;

  /// Month key (e.g. `'03-2026'`) of the linked map's Firestore path
  /// (`/shareableMaps/{monthKey}/maps/{linkedMapId}`), empty if none linked.
  /// Needed to re-fetch the full document (its layers/polygons and current
  /// cloud folder path) — deliberately not cached, so the print map always
  /// reflects the linked map's live state rather than a stale snapshot.
  final String linkedMapMonthKey;

  /// Client-map polygons allocated to this job by reference (see
  /// [JobAreaLink]). Their outlines are NOT stored here: `AreaLinkResolver`
  /// fills them into [workMaps] (and their names into [workingAreas]) when
  /// the job is read, and [toMap] leaves them out again.
  final List<JobAreaLink> areaLinks;

  /// Names [workingAreas] gained from resolving [areaLinks]. In memory only —
  /// lets [toMap] drop them, so a renamed or unlinked area never lingers.
  final Set<String> resolvedAreaNames;

  /// [JobAreaLink.key]s whose polygon could not be found on its client map
  /// (map or polygon deleted). In memory only, for warnings.
  final Set<String> missingAreaLinkKeys;

  Job({
    required this.id,
    required this.clients,
    this.clientInstructions = const [],
    required this.workingAreas,
    required this.workMaps,
    required this.distributorId,
    required this.date,
    required this.statusId,
    this.mapInstructions = '',
    this.dropOffPoint,
    this.pickUpPoint,
    this.linkedMapId = '',
    this.linkedMapMonthKey = '',
    this.linkedMaps = const [],
    this.areaLinks = const [],
    this.resolvedAreaNames = const {},
    this.missingAreaLinkKeys = const {},
  });

  /// The areas that are this job's own (drawn on it or copied onto it), i.e.
  /// [workMaps] without the ones resolved from [areaLinks].
  List<CustomPolygon> get ownWorkMaps =>
      workMaps.where((p) => !JobAreaLink.isResolved(p)).toList();

  /// [workingAreas] without the names added by resolving [areaLinks].
  List<String> get ownWorkingAreas => resolvedAreaNames.isEmpty
      ? workingAreas
      : workingAreas.where((a) => !resolvedAreaNames.contains(a)).toList();

  /// The links whose polygon is missing from its client map.
  List<JobAreaLink> get missingAreaLinks => missingAreaLinkKeys.isEmpty
      ? const []
      : areaLinks.where((l) => missingAreaLinkKeys.contains(l.key)).toList();

  /// [workMaps] with the areas resolved from [areaLinks] turned into plain
  /// copies (keeping the client map's polygon id). For places that store a
  /// snapshot of the ground on purpose, like the unfinished-areas pool —
  /// anything written with a resolved id would be stripped on save.
  List<CustomPolygon> get detachedWorkMaps => [
        for (final p in workMaps)
          if (JobAreaLink.isResolved(p))
            p.copyWith(id: p.id!.split('/').last)
          else
            p,
      ];

  /// This job after a user edited its full [workMaps] list (the job card's
  /// work-area list): a linked area the user removed is unlinked. Only links
  /// that were resolved into [workMaps] can be removed this way — one whose
  /// map had not loaded yet was never on screen, so its absence means
  /// nothing.
  Job withEditedWorkMaps(List<CustomPolygon> edited, List<String> areas) {
    final kept = edited.map((p) => p.id).whereType<String>().toSet();
    final shown =
        workMaps.where(JobAreaLink.isResolved).map((p) => p.id!).toSet();
    return copyWith(
      workMaps: edited,
      workingAreas: areas,
      areaLinks: areaLinks
          .where((l) =>
              !shown.contains(l.resolvedId) || kept.contains(l.resolvedId))
          .toList(),
    );
  }

  /// This job with [resolved] (polygons resolved from [areaLinks], already
  /// carrying [JobAreaLink.resolvedId]s) in place of any it held before.
  /// Idempotent: resolving an already-resolved job replaces, never stacks.
  Job withResolvedAreas(
    List<CustomPolygon> resolved, {
    Set<String> missingKeys = const {},
  }) {
    final own = ownWorkingAreas;
    final ownKeys = own.map((a) => a.trim().toLowerCase()).toSet();
    final addedNames = <String>{};
    for (final p in resolved) {
      final n = p.name.trim();
      if (n.isNotEmpty && ownKeys.add(n.toLowerCase())) addedNames.add(n);
    }
    return Job(
      id: id,
      clients: clients,
      clientInstructions: clientInstructions,
      workingAreas: [...own, ...addedNames],
      workMaps: [...ownWorkMaps, ...resolved],
      distributorId: distributorId,
      date: date,
      statusId: statusId,
      mapInstructions: mapInstructions,
      dropOffPoint: dropOffPoint,
      pickUpPoint: pickUpPoint,
      linkedMapId: linkedMapId,
      linkedMapMonthKey: linkedMapMonthKey,
      linkedMaps: linkedMaps,
      areaLinks: areaLinks,
      resolvedAreaNames: addedNames,
      missingAreaLinkKeys: missingKeys,
    );
  }

  /// True when at least one client map is linked.
  bool get hasLinkedMaps => linkedMaps.isNotEmpty || linkedMapId.isNotEmpty;

  /// The linked maps, filled in from the legacy single-link fields for jobs
  /// stored before [linkedMaps] existed.
  List<JobLinkedMap> get effectiveLinkedMaps => linkedMaps.isNotEmpty
      ? linkedMaps
      : (linkedMapId.isEmpty
          ? const []
          : [JobLinkedMap(mapId: linkedMapId, monthKey: linkedMapMonthKey)]);

  /// This job with [maps] as its linked maps, keeping the legacy single-link
  /// fields pointing at the first one.
  Job withLinkedMaps(List<JobLinkedMap> maps) => copyWith(
        linkedMaps: maps,
        linkedMapId: maps.isEmpty ? '' : maps.first.mapId,
        linkedMapMonthKey: maps.isEmpty ? '' : maps.first.monthKey,
      );

  // Create from Firestore
  factory Job.fromMap(String id, Map<String, dynamic> data) {
    // Handle migration from old enum-based status to new string-based statusId
    String statusId;
    if (data['statusId'] != null) {
      statusId = data['statusId'] as String;
    } else if (data['status'] != null) {
      // Migration: convert old enum status to statusId
      statusId = data['status'] as String;
    } else {
      statusId = 'scheduled'; // Default fallback
    }

    LatLng? dropOffPoint;
    final dropMap = data['dropOffPoint'];
    if (dropMap is Map) {
      final lat = (dropMap['latitude'] as num?)?.toDouble();
      final lng = (dropMap['longitude'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        dropOffPoint = LatLng(lat, lng);
      }
    } else {
      // Backward compatibility if old flat fields are present
      final lat = (data['dropOffLat'] as num?)?.toDouble();
      final lng = (data['dropOffLng'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        dropOffPoint = LatLng(lat, lng);
      }
    }

    LatLng? pickUpPoint;
    final puMap = data['pickUpPoint'];
    if (puMap is Map) {
      final lat = (puMap['latitude'] as num?)?.toDouble();
      final lng = (puMap['longitude'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        pickUpPoint = LatLng(lat, lng);
      }
    }

    return Job(
      id: id,
      clients: (data['clients'] as List<dynamic>?)?.cast<String>() ??
          (data['client'] != null
              ? [data['client'] as String]
              : ['']), // Backwards compatibility
      clientInstructions:
          (data['clientInstructions'] as List<dynamic>?)?.cast<String>() ?? [],
      workingAreas: (data['workingAreas'] as List<dynamic>?)?.cast<String>() ??
          (data['workingArea'] != null
              ? [data['workingArea'] as String]
              : ['']), // Backwards compatibility
      workMaps: (data['workMaps'] as List<dynamic>?)
              ?.map((mapData) => CustomPolygon.fromMap(
                  Map<String, dynamic>.from(mapData as Map)))
              .toList() ??
          [],
      distributorId: data['distributorId'] as String? ?? '',
      date: data['date'] != null
          ? toScheduleCivil((data['date'] as Timestamp).toDate())
          : scheduleToday(),
      statusId: statusId,
      mapInstructions: data['mapInstructions'] as String? ?? '',
      dropOffPoint: dropOffPoint,
      pickUpPoint: pickUpPoint,
      linkedMapId: data['linkedMapId'] as String? ?? '',
      linkedMapMonthKey: data['linkedMapMonthKey'] as String? ?? '',
      linkedMaps: (data['linkedMaps'] as List<dynamic>?)
              ?.map((e) =>
                  JobLinkedMap.fromMap(Map<String, dynamic>.from(e as Map)))
              .where((m) => m.mapId.isNotEmpty)
              .toList() ??
          const [],
      areaLinks: (data['areaLinks'] as List<dynamic>?)
              ?.map((e) =>
                  JobAreaLink.fromMap(Map<String, dynamic>.from(e as Map)))
              .where((l) => l.mapId.isNotEmpty && l.polygonId.isNotEmpty)
              .toList() ??
          const [],
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    // Areas resolved from [areaLinks] live on their client map — never
    // write a copy of them back onto the job.
    final ownAreas = ownWorkingAreas;
    final map = {
      'id': id, // Include ID for array storage
      'clients': clients,
      'clientInstructions': clientInstructions,
      'mapInstructions': mapInstructions,
      'workingAreas': ownAreas,
      'workMaps': ownWorkMaps.map((workMap) => workMap.toMap()).toList(),
      if (areaLinks.isNotEmpty)
        'areaLinks': areaLinks.map((l) => l.toMap()).toList(),
      'linkedMapId': linkedMapId,
      'linkedMapMonthKey': linkedMapMonthKey,
      'linkedMaps': linkedMaps.map((m) => m.toMap()).toList(),
      'distributorId': distributorId,
      'date': Timestamp.fromDate(scheduleCivilToInstant(date)),
      'statusId': statusId,
      // Keep backwards compatibility
      'status': statusId, // Also store as status for backwards compatibility
      'client': clients.isNotEmpty ? clients.first : '',
      'workingArea': ownAreas.isNotEmpty ? ownAreas.first : '',
      if (dropOffPoint != null)
        'dropOffPoint': {
          'latitude': dropOffPoint!.latitude,
          'longitude': dropOffPoint!.longitude,
        },
      if (pickUpPoint != null)
        'pickUpPoint': {
          'latitude': pickUpPoint!.latitude,
          'longitude': pickUpPoint!.longitude,
        },
    };

    return map;
  }

  // Factory method for creating from array element
  factory Job.fromArrayElement(Map<String, dynamic> data) {
    final id = data['id'] as String;
    return Job.fromMap(id, data);
  }

  // Create a copy of job with some fields updated
  // Deep copies lists to prevent mutation issues
  Job copyWith({
    List<String>? clients,
    List<String>? clientInstructions,
    List<String>? workingAreas,
    List<CustomPolygon>? workMaps,
    String? distributorId,
    DateTime? date,
    String? statusId,
    String? mapInstructions,
    Object? dropOffPoint = _dropOffPointUnchanged,
    Object? pickUpPoint = _pickUpPointUnchanged,
    String? linkedMapId,
    String? linkedMapMonthKey,
    List<JobLinkedMap>? linkedMaps,
    List<JobAreaLink>? areaLinks,
    Set<String>? resolvedAreaNames,
    Set<String>? missingAreaLinkKeys,
  }) {
    List<CustomPolygon> cloneWorkMaps(List<CustomPolygon> maps) {
      return maps
          .map((wm) => wm.copyWith(points: List<LatLng>.from(wm.points)))
          .toList();
    }

    return Job(
      id: id,
      clients: clients != null
          ? List<String>.from(clients)
          : List<String>.from(this.clients),
      clientInstructions: clientInstructions != null
          ? List<String>.from(clientInstructions)
          : List<String>.from(this.clientInstructions),
      workingAreas: workingAreas != null
          ? List<String>.from(workingAreas)
          : List<String>.from(this.workingAreas),
      workMaps: cloneWorkMaps(workMaps ?? this.workMaps),
      distributorId: distributorId ?? this.distributorId,
      date: date ?? this.date,
      statusId: statusId ?? this.statusId,
      mapInstructions: mapInstructions ?? this.mapInstructions,
      dropOffPoint: identical(dropOffPoint, _dropOffPointUnchanged)
          ? this.dropOffPoint
          : dropOffPoint as LatLng?,
      pickUpPoint: identical(pickUpPoint, _pickUpPointUnchanged)
          ? this.pickUpPoint
          : pickUpPoint as LatLng?,
      linkedMapId: linkedMapId ?? this.linkedMapId,
      linkedMapMonthKey: linkedMapMonthKey ?? this.linkedMapMonthKey,
      linkedMaps: linkedMaps != null
          ? List<JobLinkedMap>.from(linkedMaps)
          : List<JobLinkedMap>.from(this.linkedMaps),
      areaLinks: areaLinks != null
          ? List<JobAreaLink>.from(areaLinks)
          : List<JobAreaLink>.from(this.areaLinks),
      resolvedAreaNames: resolvedAreaNames ?? this.resolvedAreaNames,
      missingAreaLinkKeys: missingAreaLinkKeys ?? this.missingAreaLinkKeys,
    );
  }

  /// Estimates a default drop-off point from job work maps.
  ///
  /// Priority:
  /// 1) Existing dropoff point element in work maps
  /// 2) Centroid (simple average) of first polygon-type work map
  /// 3) First point of first non-empty work map
  static LatLng? estimateDropOffPointFromWorkMaps(List<CustomPolygon> maps) {
    for (final map in maps) {
      if (map.isPoint &&
          map.pointCategory == PointCategory.dropoff &&
          map.points.isNotEmpty) {
        return map.points.first;
      }
    }

    for (final map in maps) {
      if (map.isPolygon && map.points.isNotEmpty) {
        return _centroid(map.points);
      }
    }

    for (final map in maps) {
      if (map.points.isNotEmpty) return map.points.first;
    }

    return null;
  }

  /// Centroid of the polygon work area whose name matches [name]
  /// (case-insensitive, trimmed). Falls back to the job-wide estimate when no
  /// polygon matches. Used when adding a per-work-area drop-off task so its pin
  /// lands inside the chosen area's polygon.
  static LatLng? centroidForWorkArea(List<CustomPolygon> maps, String name) {
    final target = name.trim().toLowerCase();
    if (target.isNotEmpty) {
      for (final map in maps) {
        if (map.isPolygon &&
            map.points.isNotEmpty &&
            map.name.trim().toLowerCase() == target) {
          return _centroid(map.points);
        }
      }
    }
    return estimateDropOffPointFromWorkMaps(maps);
  }

  /// Returns true when [point] is inside at least one polygon work map.
  static bool isPointInsideAnyWorkArea(
      LatLng point, List<CustomPolygon> workMaps) {
    final polygons = workMaps.where((w) => w.isPolygon && w.points.length >= 3);
    for (final polygon in polygons) {
      if (_isPointInPolygon(point, polygon.points)) return true;
    }
    return false;
  }

  static LatLng _centroid(List<LatLng> points) {
    double lat = 0;
    double lng = 0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  static bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    bool inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;

      final intersects = ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude <
              (xj - xi) * (point.latitude - yi) / ((yj - yi) + 1e-12) + xi);
      if (intersects) inside = !inside;
    }
    return inside;
  }

  // Note: Status color is now handled by JobStatusProvider

  @override
  String toString() {
    return 'Job(id: $id, clients: $clients, workingAreas: $workingAreas, '
        'workMapsCount: ${workMaps.length}, '
        'distributorId: $distributorId, date: $date, statusId: $statusId, '
        'dropOffPoint: $dropOffPoint)';
  }

  // Helper methods for backwards compatibility and ease of use
  String get primaryClient => clients.isNotEmpty ? clients.first : '';
  String get primaryWorkingArea =>
      workingAreas.isNotEmpty ? workingAreas.first : '';

  // Helper method to get display text for clients
  String get clientsDisplay => clients.join(', ');

  // Helper method to get display text for working areas
  String get workingAreasDisplay => workingAreas.join(', ');
}
