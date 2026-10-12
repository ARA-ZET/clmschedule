import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/job.dart';
import '../models/job_list_item.dart';
import '../services/firestore_service.dart';
import '../services/job_list_service.dart';
import '../utils/distribution_lag.dart';
import '../utils/schedule_time.dart';
import 'job_type_provider.dart';
import 'schedule_provider.dart';
import 'zoho_sync_settings_provider.dart';

final distributionLagRiverpod =
    riverpod.ChangeNotifierProvider<DistributionLagProvider>((ref) {
  return DistributionLagProvider(
    schedule: ref.read(scheduleRiverpod),
    jobTypes: ref.read(jobTypeRiverpod),
    zohoSync: ref.read(zohoSyncSettingsRiverpod),
    jobListService: ref.read(jobListServiceRiverpod),
  );
});

/// Keeps every loaded schedule job's lag behind its Job List date (see
/// `utils/distribution_lag.dart`) for the schedule grid's cell borders.
///
/// Follows the schedule's month. Reads the Job List for the previous, current
/// and next month, and the previous month's schedule too: an item dated late
/// last month owns its days there before any overflow into this month, so
/// without them it would claim this month's days instead.
class DistributionLagProvider extends ChangeNotifier {
  final ScheduleProvider _schedule;
  final JobTypeProvider _jobTypes;
  final ZohoSyncSettingsProvider _zohoSync;
  final JobListService _jobListService;
  final FirestoreService _firestoreService = FirestoreService();

  DateTime? _month;
  final List<StreamSubscription<List<JobListItem>>> _itemSubs = [];
  StreamSubscription<List<Job>>? _prevJobsSub;
  final Map<String, List<JobListItem>> _itemsByMonth = {};
  List<Job> _prevMonthJobs = const [];

  /// Schedule job list last computed against, to skip recomputes on schedule
  /// notifications that did not change jobs (distributors, work areas…).
  List<Job>? _lastScheduleJobs;
  Map<String, JobLag> _lags = const {};

  DistributionLagProvider({
    required ScheduleProvider schedule,
    required JobTypeProvider jobTypes,
    required ZohoSyncSettingsProvider zohoSync,
    required JobListService jobListService,
  })  : _schedule = schedule,
        _jobTypes = jobTypes,
        _zohoSync = zohoSync,
        _jobListService = jobListService {
    _schedule.addListener(_onScheduleChanged);
    _jobTypes.addListener(_recompute);
    _zohoSync.addListener(_recompute);
    _onScheduleChanged();
  }

  /// Worst lag over [jobs] (one distributor's day), or null when none of them
  /// can be tied to a Job List item.
  ///
  /// A planning aid, so only today and future days are flagged. Past days
  /// still take part in the matching — they hold the days a job has already
  /// used, which decides which future day is its overflow.
  (DistributionLag, JobLag)? lagForJobs(List<Job> jobs) {
    final today = scheduleToday();
    JobLag? worst;
    for (final job in jobs) {
      if (DateTime(job.date.year, job.date.month, job.date.day)
          .isBefore(today)) {
        continue;
      }
      final lag = _lags[job.id];
      if (lag != null && (worst == null || lag.days > worst.days)) {
        worst = lag;
      }
    }
    return worst == null ? null : (lagForDays(worst.days), worst);
  }

  void _onScheduleChanged() {
    final month = DateTime(
        _schedule.currentMonth.year, _schedule.currentMonth.month);
    if (month != _month) {
      _month = month;
      _subscribe(month);
    }
    if (!identical(_schedule.jobs, _lastScheduleJobs)) _recompute();
  }

  void _subscribe(DateTime month) {
    _cancelSubscriptions();
    _itemsByMonth.clear();
    _prevMonthJobs = const [];

    for (final offset in const [-1, 0, 1]) {
      final m = DateTime(month.year, month.month + offset);
      final key = '${m.year}-${m.month}';
      _itemSubs.add(_jobListService.getJobListItems(m).listen(
        (items) {
          _itemsByMonth[key] = items;
          _recompute();
        },
        onError: (e) =>
            debugPrint('DistributionLagProvider: job list $key error: $e'),
      ));
    }

    _prevJobsSub = _firestoreService
        .streamJobsForMonth(DateTime(month.year, month.month - 1),
            resolveAreaLinks: false)
        .listen(
      (jobs) {
        _prevMonthJobs = jobs;
        _recompute();
      },
      onError: (e) =>
          debugPrint('DistributionLagProvider: previous schedule error: $e'),
    );
  }

  void _recompute() {
    final scheduleJobs = _schedule.jobs;
    _lastScheduleJobs = scheduleJobs;

    // Only work the allocator schedules counts. If no type is flagged yet,
    // fall back to every type rather than showing nothing.
    final autoTypes = _jobTypes.scheduleAutoAllocateTypeIds.toSet();
    final items = <String, JobListItem>{};
    for (final list in _itemsByMonth.values) {
      for (final item in list) {
        if (_zohoSync.isCancelledStatus(item.jobStatusId)) continue;
        if (autoTypes.isNotEmpty && !autoTypes.contains(item.jobTypeId)) {
          continue;
        }
        items[item.id] = item;
      }
    }

    final jobs = <String, Job>{
      for (final j in _prevMonthJobs) j.id: j,
      for (final j in scheduleJobs) j.id: j,
    };

    final next = computeDistributionLag(
      jobs: jobs.values,
      items: items.values,
    );
    if (mapEquals(next, _lags)) return;
    _lags = next;
    notifyListeners();
  }

  void _cancelSubscriptions() {
    for (final s in _itemSubs) {
      s.cancel();
    }
    _itemSubs.clear();
    _prevJobsSub?.cancel();
    _prevJobsSub = null;
  }

  @override
  void dispose() {
    _schedule.removeListener(_onScheduleChanged);
    _jobTypes.removeListener(_recompute);
    _zohoSync.removeListener(_recompute);
    _cancelSubscriptions();
    super.dispose();
  }
}
