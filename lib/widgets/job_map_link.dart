// widgets/job_map_link.dart
//
// Links an existing ShareableMap (picked via MapPickerDialog) to a schedule
// Job, mirroring JobListProvider.linkExistingMapToJob's pattern for
// JobListItem — but simpler: a schedule Job only needs to remember which map
// it's linked to (id + month key), not a share-link/area-field rewrite.
//
// Deliberately does NOT cache the linked map's Storage folder path or
// polygons on the Job — `MapPickerDialog` only knows the lightweight gallery
// summary (id/monthKey/name), not the full document, so any folder path it
// could report would already be stale/wrong. Consumers (PrintMapView) fetch
// the full `ShareableMap` doc live via `linkedMapId`/`linkedMapMonthKey`.
import 'package:flutter/material.dart';

import '../models/job.dart';
import '../providers/schedule_provider.dart';
import 'map_picker_dialog.dart';

/// Opens [MapPickerDialog] and, if the user picks a map, links it to [job].
/// Persists via the normal `updateJobWithUndo` path. No-op if cancelled.
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

  final freshJob = scheduleProvider.jobs.firstWhere(
    (j) => j.id == job.id,
    orElse: () => job,
  );
  final updatedJob = freshJob.copyWith(
    linkedMapId: result.mapId,
    linkedMapMonthKey: result.monthKey,
  );
  await scheduleProvider.updateJobWithUndo(freshJob, updatedJob, freshJob.date);
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Map "${result.mapName}" linked to job'),
      backgroundColor: Colors.green,
    ),
  );
}

/// Clears the linked map from [job].
Future<void> unlinkMapFromScheduleJob(
  ScheduleProvider scheduleProvider,
  Job job,
) async {
  final freshJob = scheduleProvider.jobs.firstWhere(
    (j) => j.id == job.id,
    orElse: () => job,
  );
  final updatedJob = freshJob.copyWith(
    linkedMapId: '',
    linkedMapMonthKey: '',
  );
  await scheduleProvider.updateJobWithUndo(freshJob, updatedJob, freshJob.date);
}
