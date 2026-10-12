/// Planning a multi-job move on the schedule grid: the selected jobs are
/// dropped on a date and each lands on the first free distributor, the same
/// way [JobAssignmentService] allocates Job List items — lowest-index active
/// distributor without a job or a day off; when a day is full, the next day.
library;

import '../models/distributor.dart';
import '../models/job.dart';

/// Where each job of a batch move goes: the moved job (new distributor and
/// date, everything else kept) keyed by the job's id.
class BatchMovePlan {
  final Map<String, Job> moved;

  /// Jobs no slot was found for within the search window.
  final List<Job> unplaced;

  const BatchMovePlan(this.moved, this.unplaced);

  DateTime? get lastDate => moved.values.isEmpty
      ? null
      : moved.values.map((j) => j.date).reduce((a, b) => a.isAfter(b) ? a : b);
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Plans moving [jobs] to [startDate] onwards.
///
/// Jobs are placed in their current order (date, then distributor index), so
/// a block of days keeps its sequence. The slots the jobs leave count as
/// free, and each placed job takes its slot for the ones after it.
/// [occupiedOn] lists the distributor ids already holding a job on a date;
/// [isDayOff] says whether a distributor is off that date. No date after
/// [lastDate] is used (the loaded schedule's end — beyond it the occupancy
/// is unknown).
BatchMovePlan planBatchMove({
  required List<Job> jobs,
  required List<Distributor> distributors,
  required DateTime startDate,
  required DateTime lastDate,
  required Set<String> Function(DateTime date) occupiedOn,
  required bool Function(String distributorId, DateTime date) isDayOff,
}) {
  final indexOf = {for (final d in distributors) d.id: d.index};
  final candidates = distributors
      .where((d) => d.status == DistributorStatus.active)
      .toList()
    ..sort((a, b) => a.index.compareTo(b.index));

  final ordered = List.of(jobs)
    ..sort((a, b) {
      final byDate = _day(a.date).compareTo(_day(b.date));
      if (byDate != 0) return byDate;
      return (indexOf[a.distributorId] ?? 1 << 30)
          .compareTo(indexOf[b.distributorId] ?? 1 << 30);
    });

  // Slots the moving jobs leave behind are free for the batch.
  final vacated = <String>{
    for (final j in ordered) '${j.distributorId}|${_day(j.date)}',
  };
  final taken = <String>{};
  final occupiedCache = <DateTime, Set<String>>{};

  bool isFree(Distributor d, DateTime date) {
    final key = '${d.id}|$date';
    if (taken.contains(key)) return false;
    if (isDayOff(d.id, date)) return false;
    final occupied = occupiedCache.putIfAbsent(date, () => occupiedOn(date));
    return !occupied.contains(d.id) || vacated.contains(key);
  }

  final moved = <String, Job>{};
  final unplaced = <Job>[];
  var cursor = _day(startDate);
  final end = _day(lastDate);
  for (final job in ordered) {
    Distributor? slot;
    while (!cursor.isAfter(end)) {
      for (final d in candidates) {
        if (isFree(d, cursor)) {
          slot = d;
          break;
        }
      }
      if (slot != null) break;
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }
    if (slot == null) {
      unplaced.add(job);
      continue;
    }
    taken.add('${slot.id}|$cursor');
    moved[job.id] = job.copyWith(distributorId: slot.id, date: cursor);
  }
  return BatchMovePlan(moved, unplaced);
}
