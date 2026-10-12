import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../models/job.dart';
import '../providers/day_off_provider.dart';
import '../providers/schedule_provider.dart';
import '../providers/schedule_selection_provider.dart';

/// Moves the dragged jobs — a [ScheduleJobsDrag] selection or a single
/// [Job] — onto [date] and the following days, each job to the first free
/// distributor (a full day spills to the next). The grid updates at once;
/// the save runs in the background.
Future<void> dropJobsOnDate(
  BuildContext context,
  riverpod.WidgetRef ref,
  Object data,
  DateTime date,
) async {
  final schedule = ref.read(scheduleRiverpod);
  final selection = ref.read(scheduleSelectionRiverpod);
  final messenger = ScaffoldMessenger.of(context);

  final ids = switch (data) {
    ScheduleJobsDrag(:final jobIds) => jobIds,
    Job(:final id) => [id],
    _ => const <String>[],
  };
  final byId = {for (final j in schedule.jobs) j.id: j};
  final jobs = [
    for (final id in ids)
      if (byId[id] != null) byId[id]!,
  ];
  if (jobs.isEmpty) return;

  final dayOff = ref.read(dayOffRiverpod);
  try {
    final future = schedule.moveJobsFromDate(
      jobs,
      date,
      isDayOff: dayOff.isDayOff,
    );
    // The move is planned and on screen right away; end selecting without
    // waiting for the save.
    selection.setSelectMode(false);
    selection.clear();
    final plan = await future;
    final first = DateFormat('EEE d MMM').format(date);
    final last = plan.lastDate;
    final range = last == null || DateUtils.isSameDay(last, date)
        ? first
        : '$first – ${DateFormat('EEE d MMM').format(last)}';
    messenger.showSnackBar(SnackBar(
      content: Row(
        children: [
          const Icon(Icons.done_all, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                'Moved ${jobs.length} job${jobs.length == 1 ? '' : 's'} to $range'),
          ),
        ],
      ),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(milliseconds: 2000),
      behavior: SnackBarBehavior.floating,
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text('Could not move the jobs: $e'),
      backgroundColor: Colors.red,
      duration: const Duration(seconds: 4),
      behavior: SnackBarBehavior.floating,
    ));
  }
}
