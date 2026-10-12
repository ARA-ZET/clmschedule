// widgets/job_map_link.dart
//
// Links existing ShareableMaps (picked via MapPickerDialog) to a schedule
// Job, mirroring JobListProvider.linkExistingMapToJob's pattern for
// JobListItem — but simpler: a schedule Job only needs to remember which
// maps it's linked to (id + month key), not a share-link/area-field rewrite.
//
// A job can carry several client maps at once — two clients on one
// distributor's day, or one client's ground split across maps — so linking
// appends to `Job.linkedMaps` instead of replacing.
//
// Deliberately does NOT cache the linked map's Storage folder path on the
// Job — `MapPickerDialog` only knows the lightweight gallery summary
// (id/monthKey/name), not the full document, so any folder path it could
// report would already be stale/wrong. Consumers (PrintMapView) fetch the
// full `ShareableMap` doc live via `linkedMapId`/`linkedMapMonthKey`.
//
// Polygons are different: the day planner and track editor only ever read a
// job's own `workMaps`, so after linking the user picks which of the linked
// map's polygons to COPY onto the job. They are copies on purpose — the
// distributor's ground for the day must not move if someone later redraws
// the client map.
//
// The map's client (from the job-list item it was made for) is added to the
// job's clients at the same time, so the schedule says who the ground is for.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../models/job_linked_map.dart';
import '../providers/schedule_provider.dart';
import '../services/job_list_service.dart';
import '../shareable_maps/models/shareable_map.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import 'linked_map_polygon_picker.dart';
import 'map_picker_dialog.dart';

/// Opens [MapPickerDialog] and, if the user picks a map, adds it to [job]'s
/// linked maps and lets them choose which of its polygons to add to the
/// job's work maps. Persists via the normal `updateJobWithUndo` path (one
/// undo step for the link + polygons + client). No-op if cancelled.
Future<void> linkExistingMapToScheduleJob(
  BuildContext context,
  ScheduleProvider scheduleProvider,
  Job job,
) async {
  final result = await showDialog<MapPickerResult>(
    context: context,
    builder: (_) => const MapPickerDialog(),
  );
  if (result == null) return;
  if (!context.mounted) return;

  if (_fresh(scheduleProvider, job)
      .effectiveLinkedMaps
      .any((m) => m.mapId == result.mapId)) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${result.mapName}" is already linked')),
    );
    return;
  }

  final map = await _loadMap(context, result.monthKey, result.mapId);
  if (!context.mounted) return;
  final picked = map == null
      ? null
      : await _pickPolygonsFromMap(context, map, _fresh(scheduleProvider, job));
  final client =
      map == null ? null : await _clientForMap(map, result.monthKey, job);
  if (!context.mounted) return;

  final freshJob = _fresh(scheduleProvider, job);
  final updatedJob =
      _withClient(_withPolygons(freshJob, picked ?? const []), client)
          .withLinkedMaps([
    ...freshJob.effectiveLinkedMaps,
    JobLinkedMap(
      mapId: result.mapId,
      monthKey: result.monthKey,
      name: result.mapName,
    ),
  ]);
  await scheduleProvider.updateJobWithUndo(freshJob, updatedJob, freshJob.date);
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
          'Map "${result.mapName}" linked${_changeSummary(freshJob, updatedJob)}'),
      backgroundColor: Colors.green,
    ),
  );
}

/// The client of the job-list item [mapId] was made for, if it isn't on
/// [job] yet — for callers (the map editor's Link Map) that persist the link
/// themselves. Null when the map has no job-list item or it can't be found.
Future<String?> clientForLinkedMap(
  String monthKey,
  String mapId,
  Job job,
) async {
  try {
    final map = await ShareableMapsFirestoreService().getMap(monthKey, mapId);
    if (map == null) return null;
    final client = await _clientForMap(map, monthKey, job);
    return _withClient(job, client) == job ? null : client;
  } catch (e) {
    debugPrint('[job_map_link] client lookup failed for $monthKey/$mapId: $e');
    return null;
  }
}

/// [job] with [client] appended to its clients (and an empty instruction to
/// keep `clientInstructions` parallel), unless it already has that client.
Job withLinkedMapClient(Job job, String? client) => _withClient(job, client);

/// Lets the user pick more polygons from [link] (or the job's first linked
/// map) and adds them to its work maps.
Future<void> addLinkedMapPolygonsToScheduleJob(
  BuildContext context,
  ScheduleProvider scheduleProvider,
  Job job, {
  JobLinkedMap? link,
}) async {
  final target = link ??
      (job.effectiveLinkedMaps.isEmpty ? null : job.effectiveLinkedMaps.first);
  if (target == null) return;
  final map = await _loadMap(context, target.monthKey, target.mapId);
  if (map == null || !context.mounted) return;
  final picked =
      await _pickPolygonsFromMap(context, map, _fresh(scheduleProvider, job));
  if (picked == null || picked.isEmpty || !context.mounted) return;
  final client = await _clientForMap(map, target.monthKey, job);
  if (!context.mounted) return;

  final freshJob = _fresh(scheduleProvider, job);
  final updatedJob = _withClient(_withPolygons(freshJob, picked), client);
  if (updatedJob == freshJob) return;
  await scheduleProvider.updateJobWithUndo(freshJob, updatedJob, freshJob.date);
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Job updated${_changeSummary(freshJob, updatedJob)}'),
      backgroundColor: Colors.green,
    ),
  );
}

/// " — 2 polygons added, client Acme added", or "" if nothing changed.
String _changeSummary(Job before, Job after) {
  final parts = <String>[];
  final added = after.workMaps.length - before.workMaps.length;
  if (added > 0) parts.add('$added polygon${added == 1 ? '' : 's'} added');
  if (after.clients.length > before.clients.length) {
    parts.add('client ${after.clients.last} added');
  }
  return parts.isEmpty ? '' : ' — ${parts.join(', ')}';
}

/// Shows the job's linked client maps: add polygons from any of them, unlink
/// one, or link another. Replaces the old single-link "Map Linked" prompt.
Future<void> showLinkedMapsDialog(
  BuildContext context,
  ScheduleProvider scheduleProvider,
  Job job,
) async {
  if (!_fresh(scheduleProvider, job).hasLinkedMaps) {
    await linkExistingMapToScheduleJob(context, scheduleProvider, job);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _LinkedMapsDialog(
      scheduleProvider: scheduleProvider,
      job: job,
    ),
  );
}

class _LinkedMapsDialog extends StatefulWidget {
  final ScheduleProvider scheduleProvider;
  final Job job;

  const _LinkedMapsDialog({required this.scheduleProvider, required this.job});

  @override
  State<_LinkedMapsDialog> createState() => _LinkedMapsDialogState();
}

class _LinkedMapsDialogState extends State<_LinkedMapsDialog> {
  Job get _job => _fresh(widget.scheduleProvider, widget.job);

  @override
  Widget build(BuildContext context) {
    final links = _job.effectiveLinkedMaps;
    return AlertDialog(
      title: Text(links.length == 1 ? 'Linked map' : 'Linked maps'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final link in links)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.map_outlined),
                title: Text(link.name.isNotEmpty ? link.name : link.mapId),
                subtitle:
                    link.monthKey.isNotEmpty ? Text(link.monthKey) : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.add_location_alt_outlined),
                      tooltip: 'Add polygons from this map',
                      onPressed: () => _addPolygons(link),
                    ),
                    IconButton(
                      icon: const Icon(Icons.link_off),
                      tooltip: 'Unlink this map',
                      onPressed: () => _unlink(link),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _linkAnother,
          child: const Text('Link another map'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _addPolygons(JobLinkedMap link) async {
    await addLinkedMapPolygonsToScheduleJob(
      context,
      widget.scheduleProvider,
      _job,
      link: link,
    );
    if (mounted) setState(() {});
  }

  Future<void> _unlink(JobLinkedMap link) async {
    await unlinkMapFromScheduleJob(
      widget.scheduleProvider,
      _job,
      mapId: link.mapId,
    );
    if (!mounted) return;
    // Nothing left to manage — the dialog would be an empty box.
    if (!_job.hasLinkedMaps) {
      Navigator.of(context).pop();
    } else {
      setState(() {});
    }
  }

  Future<void> _linkAnother() async {
    await linkExistingMapToScheduleJob(
      context,
      widget.scheduleProvider,
      _job,
    );
    if (mounted) setState(() {});
  }
}

/// Unlinks [mapId] from [job], or every linked map when [mapId] is null.
/// Polygons already copied onto the job stay — they are the distributor's
/// ground now, not a view of the map.
Future<void> unlinkMapFromScheduleJob(
  ScheduleProvider scheduleProvider,
  Job job, {
  String? mapId,
}) async {
  final freshJob = _fresh(scheduleProvider, job);
  final remaining = mapId == null
      ? const <JobLinkedMap>[]
      : freshJob.effectiveLinkedMaps
          .where((m) => m.mapId != mapId)
          .toList();
  await scheduleProvider.updateJobWithUndo(
    freshJob,
    freshJob.withLinkedMaps(remaining),
    freshJob.date,
  );
}

Job _fresh(ScheduleProvider scheduleProvider, Job job) =>
    scheduleProvider.jobs.firstWhere(
      (j) => j.id == job.id,
      orElse: () => job,
    );

Job _withClient(Job job, String? client) {
  final name = client?.trim() ?? '';
  if (name.isEmpty) return job;
  final key = name.toLowerCase();
  if (job.clients.any((c) => c.trim().toLowerCase() == key)) return job;
  final instructions = List<String>.from(job.clientInstructions);
  while (instructions.length < job.clients.length) {
    instructions.add('');
  }
  return job.copyWith(
    clients: [...job.clients, name],
    clientInstructions: [...instructions.take(job.clients.length), ''],
  );
}

/// Looks up the client on the job-list item [map] was made for. Job-list
/// items live in per-month collections and the map's month is only its
/// creation month, so try that month and the months around the schedule job.
Future<String?> _clientForMap(ShareableMap map, String monthKey, Job job) async {
  final itemId = map.jobListItemId;
  if (itemId == null || itemId.isEmpty) return null;

  final months = <DateTime>[];
  void addMonth(DateTime d) {
    final m = DateTime(d.year, d.month);
    if (!months.contains(m)) months.add(m);
  }

  final parts = monthKey.split('-');
  if (parts.length == 2) {
    final mm = int.tryParse(parts[0]);
    final yyyy = int.tryParse(parts[1]);
    if (mm != null && yyyy != null) addMonth(DateTime(yyyy, mm));
  }
  addMonth(job.date);
  addMonth(DateTime(job.date.year, job.date.month - 1));
  addMonth(DateTime(job.date.year, job.date.month + 1));

  final service = JobListService(FirebaseFirestore.instance);
  for (final month in months) {
    try {
      final item = await service.getJobListItemById(itemId, month);
      if (item != null) return item.client;
    } catch (e) {
      debugPrint('[job_map_link] job-list lookup $itemId in $month: $e');
    }
  }
  return null;
}

/// [job] with [polygons] appended to its work maps (skipping any whose
/// outline it already has) and their names appended to `workingAreas`.
Job _withPolygons(Job job, List<CustomPolygon> polygons) {
  final seen = job.workMaps.map(polygonGeometryKey).toSet();
  final toAdd = polygons
      .where((p) => seen.add(polygonGeometryKey(p)))
      .map(allocatedPolygonStyle)
      .toList();
  if (toAdd.isEmpty) return job;

  final areaKeys = job.workingAreas.map((a) => a.trim().toLowerCase()).toSet();
  final newAreas = toAdd
      .map((p) => p.name.trim())
      .where((n) => n.isNotEmpty && areaKeys.add(n.toLowerCase()))
      .toList();
  return job.copyWith(
    workMaps: [...job.workMaps, ...toAdd],
    workingAreas: [...job.workingAreas, ...newAreas],
  );
}


Future<ShareableMap?> _loadMap(
  BuildContext context,
  String monthKey,
  String mapId,
) async {
  ShareableMap? map;
  try {
    map = await ShareableMapsFirestoreService().getMap(monthKey, mapId);
  } catch (e) {
    debugPrint('[job_map_link] failed to load map $monthKey/$mapId: $e');
  }
  if (map == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not load the linked map')),
    );
  }
  return map;
}

/// Shows the polygon picker for [map]. Returns the picked polygons (named,
/// ready to append), or null if cancelled / the map has no polygons.
Future<List<CustomPolygon>?> _pickPolygonsFromMap(
  BuildContext context,
  ShareableMap map,
  Job job,
) async {
  final groups = linkedMapPolygonGroups(map);
  if (groups.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${map.name}" has no polygons to add')),
    );
    return null;
  }
  return showLinkedMapPolygonPicker(
    context,
    mapName: map.name,
    groups: groups,
    alreadyAdded: job.workMaps.map(polygonGeometryKey).toSet(),
  );
}
