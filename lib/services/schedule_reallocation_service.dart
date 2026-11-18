import '../models/job.dart';
import '../models/job_list_item.dart';
import '../models/distributor.dart';
import 'package:flutter/foundation.dart';
import '../providers/day_off_provider.dart';
import '../providers/schedule_provider.dart';
import '../utils/distribution_lag.dart';

/// Choice for how to treat jobs when a job-list date changes and there are
/// schedule jobs grouped with other clients on the same distributor/date.
enum ScheduleDateChangeMoveMode {
  moveChangedOnly,
  moveGroupedJobs,
}

class ScheduleReallocationResult {
  final bool changed;
  final int removed;
  final int added;

  /// The schedule jobs taken off and put on, exactly as written — so a Job
  /// List undo can reverse the shift without asking again.
  final List<Job> removedJobs;
  final List<Job> addedJobs;

  const ScheduleReallocationResult({
    required this.changed,
    required this.removed,
    required this.added,
    this.removedJobs = const [],
    this.addedJobs = const [],
  });
}

/// Reallocates schedule jobs for a date-changed job-list item.
///
/// Important constraints handled:
/// - only auto-allocate job types should call this service;
/// - number of moved assignments follows ceil(manDays);
/// - only jobs on today/future dates are eligible;
/// - grouped distributor/date allocations can be moved together on demand;
/// - allocation uses the same availability rules as automatic allocation.
class ScheduleReallocationService {
  final ScheduleProvider scheduleProvider;
  final DayOffProvider? dayOffProvider;

  ScheduleReallocationService({
    required this.scheduleProvider,
    this.dayOffProvider,
  });

  Future<ScheduleReallocationResult> reallocateAfterDateChange({
    required JobListItem originalItem,
    required JobListItem updatedItem,
    required ScheduleDateChangeMoveMode moveMode,
  }) async {
    final sw = Stopwatch()..start();
    const debugTag = 'job-date-shift';
    final sourceDate = DateTime(
      originalItem.date.year,
      originalItem.date.month,
      originalItem.date.day,
    );
    final targetDate = DateTime(
      updatedItem.date.year,
      updatedItem.date.month,
      updatedItem.date.day,
    );

    if (_isSameDay(sourceDate, targetDate)) {
      debugPrint('[$debugTag] skip: source and target date are the same');
      return const ScheduleReallocationResult(
          changed: false, removed: 0, added: 0);
    }

    final isFutureEligible = !_isBeforeToday(sourceDate);
    if (!isFutureEligible) {
      debugPrint('[$debugTag] skip: source date is in the past');
      return const ScheduleReallocationResult(
          changed: false, removed: 0, added: 0);
    }

    final requiredSlots = updatedItem.manDays.ceil();
    if (requiredSlots <= 0) {
      debugPrint('[$debugTag] skip: required slots <= 0');
      return const ScheduleReallocationResult(
          changed: false, removed: 0, added: 0);
    }

    final matches = _findCandidateJobs(
      jobListItem: originalItem,
      sourceDate: sourceDate,
    );

    if (matches.isEmpty) {
      debugPrint('[$debugTag] skip: no matching allocated schedule jobs');
      return const ScheduleReallocationResult(
          changed: false, removed: 0, added: 0);
    }

    final selected = _selectJobsToMove(
      candidates: matches,
      requiredCount: requiredSlots,
      moveMode: moveMode,
    );

    if (selected.isEmpty) {
      debugPrint('[$debugTag] skip: no selected jobs to move');
      return const ScheduleReallocationResult(
          changed: false, removed: 0, added: 0);
    }

    final assignmentArea = updatedItem.area.trim().isNotEmpty
        ? updatedItem.area.trim()
        : 'To be assigned';

    final blueprints = _buildBlueprints(
      moveMode: moveMode,
      selectedJobs: selected,
      originalItem: originalItem,
      fallbackArea: assignmentArea,
    );

    if (blueprints.isEmpty) {
      debugPrint('[$debugTag] skip: no blueprints produced');
      return const ScheduleReallocationResult(
          changed: false, removed: 0, added: 0);
    }

    final planned = _allocateAssignments(
      startDate: targetDate,
      blueprints: blueprints,
      removingJobIds: selected.map((j) => j.id).toSet(),
    );

    if (planned.isEmpty) {
      debugPrint('[$debugTag] skip: no available target slots for allocation');
      return const ScheduleReallocationResult(
          changed: false, removed: 0, added: 0);
    }

    final toMove = planned.map((p) => p.blueprint.sourceJob).toSet().toList();
    final addJobs = <Job>[];
    for (final assignment in planned) {
      final blueprint = assignment.blueprint;
      final moved = blueprint.template.copyWith(
        distributorId: assignment.distributorId,
        date: assignment.date,
      );
      final newJob = blueprint.forceNewId
          ? _cloneJobWithId(moved, '')
          : moved;
      addJobs.add(newJob);
    }

    // In changed-only mode, preserve non-changed clients on the original
    // distributor/date by re-adding residual jobs after removing originals.
    if (moveMode == ScheduleDateChangeMoveMode.moveChangedOnly) {
      for (final job in toMove) {
        final residual = _removeClientFromJob(
          job,
          originalItem.client,
        );
        if (residual != null) {
          addJobs.add(residual);
        }
      }
    }

    final added = await scheduleProvider.reallocateJobsAtomically(
      removeJobs: toMove,
      addJobs: addJobs,
      debugTag: debugTag,
    );

    sw.stop();
    debugPrint(
      '[$debugTag] complete in ${sw.elapsedMilliseconds}ms: removed=${toMove.length}, moved=${planned.length}, requiredSlots=$requiredSlots, moveMode=$moveMode',
    );

    return ScheduleReallocationResult(
      changed: toMove.isNotEmpty || planned.isNotEmpty,
      removed: toMove.length,
      added: planned.length,
      removedJobs: toMove,
      addedJobs: added,
    );
  }

  /// Renames [originalItem]'s client on the schedule jobs that belong to it,
  /// so the schedule, its client-map allocation and track filing keep
  /// finding the item by name.
  ///
  /// Which jobs belong to it is [pairJobsWithJobListItems]'s call: the jobs
  /// holding areas from its client map, then the days nearest its date. Past
  /// days are included — their tracks may still be waiting to be filed.
  /// [clientItems] are the client's other Job List items around that date;
  /// they keep their own days, so another round keeps its name.
  /// [onRenamed] receives the jobs renamed and the names, for Undo.
  Future<int> renameClientInAllocatedJobs({
    required JobListItem originalItem,
    required JobListItem updatedItem,
    List<JobListItem> clientItems = const [],
    void Function(List<Job> jobs, String from, String to)? onRenamed,
  }) async {
    const debugTag = 'job-client-rename';
    final sw = Stopwatch()..start();

    final oldClient = originalItem.client.trim();
    final newClient = updatedItem.client.trim();
    if (oldClient.isEmpty || newClient.isEmpty) return 0;
    if (_normalize(oldClient) == _normalize(newClient)) return 0;

    final d = originalItem.date;
    final jobs = await scheduleProvider.fetchJobsForMonths([
      DateTime(d.year, d.month - 1),
      d,
      DateTime(d.year, d.month + 1),
    ]);
    final oldKey = jobListClientKey(oldClient);
    final pairing = pairJobsWithJobListItems(
      jobs: jobs.where((j) => j.clients.any((c) => _normalize(c) == oldKey)),
      items: [
        for (final i in clientItems)
          if (i.id != originalItem.id) i,
        originalItem,
      ],
    );
    final target = [
      for (final job in jobs)
        if (pairing[job.id]?[oldKey]?.id == originalItem.id) job,
    ];
    if (target.isEmpty) {
      debugPrint('[$debugTag] skip: no schedule jobs matched for rename');
      return 0;
    }

    final updated = await scheduleProvider.renameClientOnJobs(
      target,
      from: oldClient,
      to: newClient,
    );
    if (updated > 0) onRenamed?.call(target, oldClient, newClient);

    sw.stop();
    debugPrint(
      '[$debugTag] complete in ${sw.elapsedMilliseconds}ms updated=$updated',
    );
    return updated;
  }

  Job? _removeClientFromJob(Job job, String clientToRemove) {
    final normalizedTarget = _normalize(clientToRemove);
    final index = job.clients.indexWhere((c) => _normalize(c) == normalizedTarget);
    if (index == -1) return null;

    final nextClients = List<String>.from(job.clients)..removeAt(index);
    if (nextClients.isEmpty) return null;

    List<String> nextInstructions = List<String>.from(job.clientInstructions);
    if (nextInstructions.length == job.clients.length && index < nextInstructions.length) {
      nextInstructions.removeAt(index);
    }

    List<String> nextAreas = List<String>.from(job.workingAreas);
    if (nextAreas.length == job.clients.length && index < nextAreas.length) {
      nextAreas.removeAt(index);
    }

    return job.copyWith(
      clients: nextClients,
      clientInstructions: nextInstructions,
      workingAreas: nextAreas,
    );
  }

  String _normalize(String value) => value.trim().toLowerCase();

  bool hasGroupedAllocationConflict(JobListItem item) {
    final sourceDate = DateTime(item.date.year, item.date.month, item.date.day);
    final candidates = _findCandidateJobs(jobListItem: item, sourceDate: sourceDate);
    for (final job in candidates) {
      if (job.clients.length > 1) return true;
      final slotJobs = _groupJobsForDistributorAndDate(job);
      if (slotJobs.length > 1) return true;
    }
    return false;
  }

  bool hasEligibleAllocations(JobListItem item) {
    final sourceDate = DateTime(item.date.year, item.date.month, item.date.day);
    return _findCandidateJobs(jobListItem: item, sourceDate: sourceDate)
        .isNotEmpty;
  }

  List<Job> _findCandidateJobs({
    required JobListItem jobListItem,
    required DateTime sourceDate,
  }) {
    final allOnDate = scheduleProvider.getJobsForDate(sourceDate);
    final clientLower = jobListItem.client.trim().toLowerCase();

    return allOnDate.where((job) {
      final hasClient = job.clients.any((c) => c.trim().toLowerCase() == clientLower);
      if (!hasClient) return false;
      return !_isBeforeToday(job.date);
    }).toList();
  }

  List<Job> _selectJobsToMove({
    required List<Job> candidates,
    required int requiredCount,
    required ScheduleDateChangeMoveMode moveMode,
  }) {
    if (candidates.isEmpty || requiredCount <= 0) return const [];

    final sorted = List<Job>.from(candidates)
      ..sort((a, b) {
        final byDate = a.date.compareTo(b.date);
        if (byDate != 0) return byDate;
        return a.id.compareTo(b.id);
      });

    if (moveMode == ScheduleDateChangeMoveMode.moveChangedOnly) {
      return sorted.take(requiredCount).toList();
    }

    final selected = <Job>[];
    final seen = <String>{};

    for (final seed in sorted) {
      final group = _groupJobsForDistributorAndDate(seed);
      for (final job in group) {
        if (seen.add(job.id)) {
          selected.add(job);
        }
      }
      if (selected.length >= requiredCount) break;
    }

    return selected;
  }

  List<_AllocationBlueprint> _buildBlueprints({
    required ScheduleDateChangeMoveMode moveMode,
    required List<Job> selectedJobs,
    required JobListItem originalItem,
    required String fallbackArea,
  }) {
    if (selectedJobs.isEmpty) return const [];

    if (moveMode == ScheduleDateChangeMoveMode.moveGroupedJobs) {
      return selectedJobs
          .map((job) => _AllocationBlueprint(
                sourceJob: job,
                template: job,
                forceNewId: false,
              ))
          .toList();
    }

    final out = <_AllocationBlueprint>[];
    for (final job in selectedJobs) {
      final movedTemplate = _extractClientJobTemplate(job, originalItem.client);
      if (movedTemplate == null) continue;

      final splitRequired = movedTemplate.clients.length != job.clients.length;
      out.add(_AllocationBlueprint(
        sourceJob: job,
        template: movedTemplate,
        forceNewId: splitRequired,
      ));
    }
    return out;
  }

  /// Build the exact payload to move in changed-only mode.
  ///
  /// - Single-client source job: keep full template unchanged.
  /// - Multi-client source job: move only the changed client (plus aligned
  ///   per-client fields), preserving all job-level fields.
  Job? _extractClientJobTemplate(Job source, String targetClient) {
    final normalizedTarget = _normalize(targetClient);
    final idx = source.clients
        .indexWhere((c) => _normalize(c) == normalizedTarget);
    if (idx == -1) return null;

    // Single-client job: no split needed, preserve everything as-is.
    if (source.clients.length <= 1) return source;

    final clientSlice = <String>[source.clients[idx]];
    final instructionSlice = _slicePerClientField(
      source.clientInstructions,
      source.clients.length,
      idx,
    );
    final areaSlice = _slicePerClientField(
      source.workingAreas,
      source.clients.length,
      idx,
    );

    return source.copyWith(
      clients: clientSlice,
      clientInstructions: instructionSlice,
      workingAreas: areaSlice,
    );
  }

  List<String> _slicePerClientField(
    List<String> field,
    int clientsLen,
    int index,
  ) {
    if (field.isEmpty) return const [];
    if (field.length == clientsLen && index < field.length) {
      return [field[index]];
    }
    if (field.length == 1) {
      return [field.first];
    }
    // Shape is ambiguous — preserve original field so no data is lost.
    return List<String>.from(field);
  }

  Job _cloneJobWithId(Job source, String id) {
    return Job(
      id: id,
      clients: List<String>.from(source.clients),
      clientInstructions: List<String>.from(source.clientInstructions),
      workingAreas: List<String>.from(source.workingAreas),
      workMaps: List.from(source.workMaps),
      distributorId: source.distributorId,
      date: source.date,
      statusId: source.statusId,
      mapInstructions: source.mapInstructions,
      dropOffPoint: source.dropOffPoint,
      pickUpPoint: source.pickUpPoint,
      linkedMapId: source.linkedMapId,
      linkedMapMonthKey: source.linkedMapMonthKey,
      linkedMaps: List.from(source.linkedMaps),
      areaLinks: List.from(source.areaLinks),
      resolvedAreaNames: source.resolvedAreaNames,
      missingAreaLinkKeys: source.missingAreaLinkKeys,
    );
  }

  List<_PlannedAssignment> _allocateAssignments({
    required DateTime startDate,
    required List<_AllocationBlueprint> blueprints,
    required Set<String> removingJobIds,
  }) {
    final localStart = DateTime(startDate.year, startDate.month, startDate.day);
    final occupiedByDate = <String, Set<String>>{};

    for (final job in scheduleProvider.jobs) {
      if (removingJobIds.contains(job.id)) continue;
      final dateKey = _dateKey(job.date);
      occupiedByDate.putIfAbsent(dateKey, () => <String>{}).add(job.distributorId);
    }

    final activeDistributors = scheduleProvider.distributors
        .where((d) => d.status == DistributorStatus.active)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final planned = <_PlannedAssignment>[];

    for (final blueprint in blueprints) {
      final slot = _findNextAvailableSlot(
        startDate: localStart,
        activeDistributors: activeDistributors,
        occupiedByDate: occupiedByDate,
      );
      if (slot == null) break;

      occupiedByDate.putIfAbsent(_dateKey(slot.date), () => <String>{}).add(slot.distributorId);
      planned.add(_PlannedAssignment(
        blueprint: blueprint,
        distributorId: slot.distributorId,
        date: slot.date,
      ));
    }

    return planned;
  }

  _Slot? _findNextAvailableSlot({
    required DateTime startDate,
    required List<Distributor> activeDistributors,
    required Map<String, Set<String>> occupiedByDate,
  }) {
    var cursor = startDate;

    for (int i = 0; i < 366; i++) {
      final key = _dateKey(cursor);
      final occupied = occupiedByDate[key] ?? const <String>{};

      for (final distributor in activeDistributors) {
        if (occupied.contains(distributor.id)) continue;
        if (dayOffProvider?.isDayOff(distributor.id, cursor) ?? false) {
          continue;
        }
        return _Slot(distributorId: distributor.id, date: cursor);
      }

      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }

    return null;
  }

  String _dateKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  List<Job> _groupJobsForDistributorAndDate(Job seed) {
    return scheduleProvider
        .getJobsForDistributorAndDate(seed.distributorId, seed.date)
        .where((j) => !_isBeforeToday(j.date))
        .toList();
  }

  bool _isBeforeToday(DateTime date) {
    final today = DateTime.now();
    final localToday = DateTime(today.year, today.month, today.day);
    final localDate = DateTime(date.year, date.month, date.day);
    return localDate.isBefore(localToday);
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

class _Slot {
  final String distributorId;
  final DateTime date;

  const _Slot({
    required this.distributorId,
    required this.date,
  });
}

class _AllocationBlueprint {
  final Job sourceJob;
  final Job template;
  final bool forceNewId;

  const _AllocationBlueprint({
    required this.sourceJob,
    required this.template,
    required this.forceNewId,
  });
}

class _PlannedAssignment {
  final _AllocationBlueprint blueprint;
  final String distributorId;
  final DateTime date;

  const _PlannedAssignment({
    required this.blueprint,
    required this.distributorId,
    required this.date,
  });
}
