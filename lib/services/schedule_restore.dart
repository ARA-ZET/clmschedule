// services/schedule_restore.dart
//
// The pure core of a Schedule undo / redo, run inside the schedule
// transaction (FirestoreService.restoreScheduleJobs): swap exactly the jobs a
// step left ([expected]) for the ones it found ([replacement]), or refuse.
import '../models/job.dart';
import '../undo/undo_history.dart' show UndoConflict;
import 'schedule_mutation_types.dart';

class ScheduleRestoreResult {
  /// The retry of a write that did commit: [replacement] is already there,
  /// so nothing was changed.
  final bool alreadyApplied;

  /// Jobs taken off the schedule with nothing put back (their raw day-doc
  /// maps and dates), for the Recycle Bin.
  final Map<String, (Map<String, dynamic>, DateTime)> removed;

  const ScheduleRestoreResult({
    this.alreadyApplied = false,
    this.removed = const {},
  });
}

/// Whether two copies of a job hold the same content. The day-doc date stamp
/// is left out: the integrity pass rewrites it to the day's date.
bool sameJobContent(Job a, Job b) {
  final ma = a.toMap()..remove('date');
  final mb = b.toMap()..remove('date');
  return deepEquals(ma, mb);
}

/// Applies the swap to [ctx]. Throws [UndoConflict], changing nothing, when an
/// expected job is missing or no longer as recorded, or a job to put back is
/// already on one of the affected days.
ScheduleRestoreResult applyScheduleRestore(
  ScheduleTxContext ctx, {
  required List<Job> expected,
  required List<Job> replacement,
}) {
  final expectedById = {for (final j in expected) j.id: j};
  final replacementById = {for (final j in replacement) j.id: j};

  // Where each job id currently sits among the affected days.
  (String, int)? find(String id) {
    for (final e in ctx.jobsByDateKey.entries) {
      final i = e.value.indexWhere((j) => j['id'] == id);
      if (i >= 0) return (e.key, i);
    }
    return null;
  }

  bool matches(Job job) {
    final at = find(job.id);
    if (at == null || at.$1 != ctx.dateKeyFor(job.date)) return false;
    final raw = ctx.jobsByDateKey[at.$1]![at.$2];
    return sameJobContent(Job.fromMap(job.id, raw), job);
  }

  final alreadyApplied = replacement.every(matches) &&
      expectedById.keys
          .where((id) => !replacementById.containsKey(id))
          .every((id) => find(id) == null);
  if (alreadyApplied) return const ScheduleRestoreResult(alreadyApplied: true);

  for (final job in expected) {
    if (!matches(job)) throw const UndoConflict('the job was changed since');
  }
  for (final id in replacementById.keys) {
    if (!expectedById.containsKey(id) && find(id) != null) {
      throw const UndoConflict('the job is already back');
    }
  }

  final removed = <String, (Map<String, dynamic>, DateTime)>{};
  for (final job in expected) {
    final at = find(job.id)!;
    final list = ctx.jobsByDateKey[at.$1]!;
    final r = replacementById[job.id];
    if (r != null && ctx.dateKeyFor(r.date) == at.$1) {
      // Same id, same day: replace in place so the order holds.
      list[at.$2] = r.toMap();
    } else {
      if (r == null) removed[job.id] = (list[at.$2], job.date);
      list.removeAt(at.$2);
    }
  }
  for (final r in replacement) {
    if (find(r.id) == null) {
      ctx.jobsByDateKey[ctx.dateKeyFor(r.date)]!.add(r.toMap());
    }
  }
  return ScheduleRestoreResult(removed: removed);
}
