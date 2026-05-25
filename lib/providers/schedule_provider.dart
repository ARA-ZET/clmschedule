import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/schedule.dart';
import '../models/work_area.dart';
import '../models/work_suburb.dart';
import '../models/custom_polygon.dart';
import '../services/firestore_service.dart';
import 'dropsheet_provider.dart';

final scheduleRiverpod = riverpod.ChangeNotifierProvider<ScheduleProvider>(
  (ref) => ScheduleProvider(ref: ref),
);

class ScheduleProvider extends ChangeNotifier {
  final FirestoreService _firestoreService;

  List<Distributor> _distributors = [];
  List<Job> _currentMonthJobs = [];
  List<Job> _nextMonthJobs = [];
  List<WorkArea> _workAreas = [];
  List<WorkSuburb> _workSuburbs = [];
  DateTime _currentMonth = DateTime.now();

  // Cached combined jobs list — invalidated when either month's data changes
  List<Job>? _cachedJobs;

  // Cached job lookup map: "distributorId:YYYY-MM-DD" → List<Job>
  // Provides O(1) lookups for cellBuilder instead of O(N) linear scans
  Map<String, List<Job>>? _jobLookupMap;

  // Cached Schedule object — rebuilt only when jobs change
  Schedule? _cachedSchedule;

  // Monotonic version counter — increments on every data change.
  // Used by the grid Selector for O(1) deterministic change detection.
  int _jobsVersion = 0;
  int get jobsVersion => _jobsVersion;

  /// Invalidate all derived caches. Call whenever raw job data changes.
  void _invalidateCaches() {
    _cachedJobs = null;
    _jobLookupMap = null;
    _cachedSchedule = null;
    _jobsVersion++;
  }

  // --- Optimistic local state helpers ---

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Ensures a job has a valid drop-off point when it has work areas.
  ///
  /// If [preferExisting] is true, an existing point is kept when still inside
  /// a polygon work area. Otherwise a new default point is estimated.
  ///
  /// Two-way sync with a dropoff-category point in [Job.workMaps]:
  /// - If only the workMap point is set (e.g. fresh edit from the map
  ///   editor), `dropOffPoint` is updated to match.
  /// - If `dropOffPoint` has been changed (e.g. marker drag from the day
  ///   planner) and disagrees with the workMap dropoff point, the workMap
  ///   point is updated to match the new `dropOffPoint`. Without this the
  ///   dragged marker would snap back to the stale workMap location on the
  ///   next read.
  Job _normalizeDropOffPoint(Job job, {bool preferExisting = true}) {
    if (job.workMaps.isEmpty) return job.copyWith(dropOffPoint: null);

    // Priority 1: explicit dropoff-category point in workMaps.
    for (int i = 0; i < job.workMaps.length; i++) {
      final wm = job.workMaps[i];
      if (!(wm.isPoint &&
          wm.pointCategory == PointCategory.dropoff &&
          wm.points.isNotEmpty)) {
        continue;
      }
      final wmPoint = wm.points.first;
      final dop = job.dropOffPoint;
      if (dop != null && !_sameLatLng(dop, wmPoint)) {
        // Caller-supplied dropOffPoint wins — propagate it back into the
        // workMap so all readers (map editor, day planner, dropsheet) see
        // a single authoritative position.
        final updatedMaps = List<CustomPolygon>.from(job.workMaps);
        updatedMaps[i] = wm.copyWith(points: [dop]);
        return job.copyWith(workMaps: updatedMaps);
      }
      return job.copyWith(dropOffPoint: wmPoint);
    }

    final estimated = Job.estimateDropOffPointFromWorkMaps(job.workMaps);
    if (estimated == null) return job;

    final existing = job.dropOffPoint;
    if (!preferExisting || existing == null) {
      return job.copyWith(dropOffPoint: estimated);
    }

    final keepExisting = Job.isPointInsideAnyWorkArea(existing, job.workMaps);
    return keepExisting ? job : job.copyWith(dropOffPoint: estimated);
  }

  /// LatLng comparison with a small epsilon so floating-point rounding
  /// from Firestore round-trips doesn't trigger spurious workMap rewrites.
  static bool _sameLatLng(dynamic a, dynamic b) {
    if (a == null || b == null) return a == b;
    const eps = 1e-7;
    return (a.latitude - b.latitude).abs() < eps &&
        (a.longitude - b.longitude).abs() < eps;
  }

  /// Replace a job in the local lists by id, then notify listeners instantly.
  void _optimisticUpdateJob(Job newJob) {
    for (int i = 0; i < _currentMonthJobs.length; i++) {
      if (_currentMonthJobs[i].id == newJob.id) {
        _currentMonthJobs = List.of(_currentMonthJobs)..[i] = newJob;
        _invalidateCaches();
        notifyListeners();
        return;
      }
    }
    for (int i = 0; i < _nextMonthJobs.length; i++) {
      if (_nextMonthJobs[i].id == newJob.id) {
        _nextMonthJobs = List.of(_nextMonthJobs)..[i] = newJob;
        _invalidateCaches();
        notifyListeners();
        return;
      }
    }
  }

  /// Remove a job from local lists by id, then notify listeners instantly.
  void _optimisticRemoveJob(String jobId) {
    final beforeCurrent = _currentMonthJobs.length;
    _currentMonthJobs = _currentMonthJobs.where((j) => j.id != jobId).toList();
    if (_currentMonthJobs.length == beforeCurrent) {
      _nextMonthJobs = _nextMonthJobs.where((j) => j.id != jobId).toList();
    }
    _invalidateCaches();
    notifyListeners();
  }

  // Streams subscriptions
  StreamSubscription<List<Distributor>>? _distributorsSubscription;
  StreamSubscription<List<Job>>? _currentMonthJobsSubscription;
  StreamSubscription<List<Job>>? _nextMonthJobsSubscription;
  StreamSubscription<List<WorkArea>>? _workAreasSubscription;
  StreamSubscription<List<WorkSuburb>>? _workSuburbsSubscription;

  // Getters
  List<Distributor> get distributors => _distributors;
  List<Job> get jobs =>
      _cachedJobs ??= [..._currentMonthJobs, ..._nextMonthJobs];
  List<WorkArea> get workAreas => _workAreas;
  List<WorkSuburb> get workSuburbs => _workSuburbs;
  Schedule get schedule =>
      _cachedSchedule ??= Schedule(distributors: _distributors, jobs: jobs);

  /// Distributors filtered for grid display:
  /// - Always show active distributors
  /// - Hide non-active distributors unless they have jobs in the current month
  List<Distributor> get gridDistributors {
    final currentJobs = jobs;
    final distributorIdsWithJobs = <String>{};
    for (final job in currentJobs) {
      distributorIdsWithJobs.add(job.distributorId);
    }
    return _distributors.where((d) {
      if (d.status == DistributorStatus.active) return true;
      return distributorIdsWithJobs.contains(d.id);
    }).toList();
  }

  /// Build (or return cached) lookup map for O(1) cell queries.
  Map<String, List<Job>> get _lookupMap {
    if (_jobLookupMap != null) return _jobLookupMap!;
    final map = <String, List<Job>>{};
    for (final job in jobs) {
      final key =
          '${job.distributorId}:${job.date.year}-${job.date.month.toString().padLeft(2, '0')}-${job.date.day.toString().padLeft(2, '0')}';
      (map[key] ??= []).add(job);
    }
    _jobLookupMap = map;
    return map;
  }

  DateTime get currentMonth => _currentMonth;
  String get currentMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(_currentMonth);

  // Helper method to check if the next month has any jobs
  bool get hasJobsInNextMonth => _nextMonthJobs.isNotEmpty;

  ScheduleProvider({FirestoreService? firestoreService, riverpod.Ref? ref})
      : _firestoreService = firestoreService ?? FirestoreService(),
        _ref = ref;

  /// Optional riverpod ref so the provider can notify peer providers
  /// (currently the dropsheet) about distributor coordinate changes.
  final riverpod.Ref? _ref;

  /// Push dropOff/pickUp coordinate changes for [updatedJob] into the
  /// dropsheet provider so any task linked to this job updates its
  /// cached `lat`/`lng` immediately. Safe to call from any screen — the
  /// dropsheet ignores the call when no matching task exists.
  void _notifyDropsheetOfCoordChanges(Job? previous, Job updatedJob) {
    final ref = _ref;
    if (ref == null) return;
    final prevDrop = previous?.dropOffPoint;
    final newDrop = updatedJob.dropOffPoint;
    final dropChanged = !_sameLatLng(prevDrop, newDrop);
    final prevPick = previous?.pickUpPoint;
    final newPick = updatedJob.pickUpPoint;
    final pickChanged = !_sameLatLng(prevPick, newPick);
    if (!dropChanged && !pickChanged) return;
    final dropsheet = ref.read(dropsheetRiverpod);
    if (dropChanged) {
      unawaited(dropsheet.refreshDropOffCoords(updatedJob.id, newDrop));
    }
    if (pickChanged) {
      unawaited(dropsheet.refreshPickUpCoords(updatedJob.id, newPick));
    }
  }
  // Don't initialize streams in constructor - let it be done async

  // Initialize streams asynchronously without blocking (full app)
  Future<void> initialize() async {
    await _initStreamsAsync();
  }

  /// Lightweight init for the track editor flavor.
  /// Fetches distributors once (no ongoing streams) — jobs are read
  /// on-demand via [fetchJobsForDistributorAndDate].
  Future<void> initForTrackEditor() async {
    try {
      _distributors = await _firestoreService.fetchDistributorsOnce();
      notifyListeners();
    } catch (e) {
      debugPrint('ScheduleProvider.initForTrackEditor: $e');
    }
  }

  /// One-time read of all work areas from Firestore (cache-first).
  Future<List<WorkArea>> fetchWorkAreas() async {
    try {
      return await _firestoreService.fetchWorkAreasOnce();
    } catch (e) {
      debugPrint('ScheduleProvider.fetchWorkAreas: $e');
      return [];
    }
  }

  // Load data streams asynchronously and concurrently
  Future<void> _initStreamsAsync() async {
    // Set up global streams once (distributors + work areas)
    _setupGlobalStreams();
    // Set up month-specific job streams
    _loadJobStreamsForMonth(_currentMonth);
  }

  /// Set up distributors and workAreas streams.
  /// These are global (not month-specific) and only need to be created once.
  void _setupGlobalStreams() {
    // Listen to distributors stream from root collection (not monthly)
    _distributorsSubscription = _firestoreService.streamDistributors().listen(
      (distributors) {
        _distributors = distributors;
        _cachedSchedule = null; // Schedule depends on distributors
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: Distributors stream error: $error');
      },
    );

    // Listen to work areas stream from root collection (not monthly)
    _workAreasSubscription = _firestoreService.streamWorkAreas().listen(
      (workAreas) {
        _workAreas = workAreas;
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: WorkAreas stream error: $error');
      },
    );

    // Listen to work suburbs single-document stream
    _workSuburbsSubscription = _firestoreService.streamWorkSuburbs().listen(
      (suburbs) {
        _workSuburbs = suburbs;
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: WorkSuburbs stream error: $error');
      },
    );
  }

  // Tracks the month the next-month subscription is currently attached to.
  // Null when no next-month listener is active.
  DateTime? _nextMonthSubscribedFor;

  // Load job streams for a specific month (and next month when it has data)
  // Only tears down and recreates the two job subscriptions.
  void _loadJobStreamsForMonth(DateTime month) {
    // Cancel ONLY job subscriptions (not global distributors/workAreas)
    _currentMonthJobsSubscription?.cancel();
    _nextMonthJobsSubscription?.cancel();
    _nextMonthSubscribedFor = null;

    // Clear stale data from previous month so the lookup map
    // doesn't contain old-month entries while new streams start.
    _currentMonthJobs = [];
    _nextMonthJobs = [];

    // Invalidate all derived caches
    _invalidateCaches();

    debugPrint(
        'ScheduleProvider: Starting job stream for current month: ${_firestoreService.getMonthlyDocumentId(month)}');

    // Listen to jobs stream for the current month — set up synchronously
    _currentMonthJobsSubscription = _firestoreService.streamJobs(month).listen(
      (jobs) {
        _currentMonthJobs = jobs;
        _invalidateCaches();
        debugPrint(
            'ScheduleProvider: Received ${jobs.length} jobs for current month ${_firestoreService.getMonthlyDocumentId(month)}');
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: Current month jobs stream error: $error');
      },
    );

    // Next month is attached lazily: only when the monthly index document
    // exists (i.e. the month has real data). This avoids an empty collection
    // listener for every session on months that haven't been populated.
    unawaited(_maybeAttachNextMonthStream(month));
  }

  /// Attach the next-month jobs stream only if that month has any data.
  /// Uses a cache-first existence probe on the monthly index doc.
  Future<void> _maybeAttachNextMonthStream(DateTime currentMonth) async {
    final nextMonth = DateTime(currentMonth.year, currentMonth.month + 1);

    // Skip if another month change already happened.
    if (_currentMonth != currentMonth) return;

    final hasData = await _firestoreService.hasScheduleDataForMonth(nextMonth);

    // Re-check after the async gap — the user may have navigated away.
    if (_currentMonth != currentMonth) return;
    if (!hasData) {
      debugPrint(
          'ScheduleProvider: Skipping next-month stream (no data) for ${_firestoreService.getMonthlyDocumentId(nextMonth)}');
      return;
    }

    _nextMonthSubscribedFor = nextMonth;
    _nextMonthJobsSubscription = _firestoreService.streamJobs(nextMonth).listen(
      (jobs) {
        _nextMonthJobs = jobs;
        _invalidateCaches();
        debugPrint(
            'ScheduleProvider: Received ${jobs.length} jobs for next month ${_firestoreService.getMonthlyDocumentId(nextMonth)}');
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: Next month jobs stream error: $error');
      },
    );
  }

  /// Public hook for callers (e.g. cross-date drag) that know they need
  /// next-month data even if the existence probe missed it.
  Future<void> ensureNextMonthLoaded() async {
    if (_nextMonthSubscribedFor != null) return;
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    _nextMonthSubscribedFor = nextMonth;
    _nextMonthJobsSubscription = _firestoreService.streamJobs(nextMonth).listen(
      (jobs) {
        _nextMonthJobs = jobs;
        _invalidateCaches();
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: Next month jobs stream error: $error');
      },
    );
  }

  // Change current month
  void setCurrentMonth(DateTime month) {
    if (_currentMonth != month) {
      _currentMonth = month;
      _invalidateCaches();
      _loadJobStreamsForMonth(_currentMonth);
      notifyListeners();
    }
  }

  // Go to next month
  void goToNextMonth() {
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    setCurrentMonth(nextMonth);
  }

  // Go to previous month
  void goToPreviousMonth() {
    final previousMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    setCurrentMonth(previousMonth);
  }

  // Go to current month
  void goToCurrentMonth() {
    setCurrentMonth(DateTime.now());
  }

  // Go to specific month by month string (e.g., "Sep 2025")
  void goToMonth(String monthString) {
    final DateTime? month = _parseMonthString(monthString);
    if (month != null) {
      setCurrentMonth(month);
    }
  }

  // Helper method to parse month string back to DateTime
  DateTime? _parseMonthString(String monthString) {
    final parts = monthString.split(' ');
    if (parts.length != 2) return null;

    const months = {
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12
    };

    final monthNum = months[parts[0]];
    final year = int.tryParse(parts[1]);

    if (monthNum != null && year != null) {
      return DateTime(year, monthNum);
    }
    return null;
  }

  // Get available months
  Future<List<String>> getAvailableMonths() {
    return _firestoreService.getAvailableScheduleMonths();
  }

  // DISTRIBUTOR OPERATIONS

  Future<void> addDistributor(String name) async {
    // Distributors are in root collection, no monthly context needed
    await _firestoreService.addDistributor(name);
  }

  Future<void> updateDistributor(Distributor distributor) async {
    // Distributors are in root collection, no monthly context needed
    await _firestoreService.updateDistributor(distributor);
  }

  // Smart update distributor with automatic index management
  Future<void> updateDistributorSmart(
      Distributor updatedDistributor, int oldIndex) async {
    // Validate index bounds
    final maxIndex = _distributors.length - 1;
    if (updatedDistributor.index < 0 || updatedDistributor.index > maxIndex) {
      throw ArgumentError('Index must be between 0 and $maxIndex');
    }

    // Use smart indexing service method
    await _firestoreService.updateDistributorWithSmartIndexing(
        updatedDistributor, oldIndex);
  }

  Future<void> deleteDistributor(String distributorId) async {
    // Distributors are in root collection, no monthly context needed
    await _firestoreService.deleteDistributor(distributorId);
  }

  // Smart delete that reindexes remaining distributors
  Future<void> deleteDistributorSmart(String distributorId) async {
    // Find the distributor being deleted
    final distributorToDelete =
        _distributors.firstWhere((d) => d.id == distributorId);

    // Delete the distributor
    await _firestoreService.deleteDistributor(distributorId);

    // Reindex remaining distributors with higher indices
    final distributorsToUpdate = _distributors
        .where(
            (d) => d.id != distributorId && d.index > distributorToDelete.index)
        .toList();

    for (final distributor in distributorsToUpdate) {
      final updatedDistributor =
          distributor.copyWith(index: distributor.index - 1);
      await _firestoreService.updateDistributor(updatedDistributor);
    }
  }

  // Reorder distributors by updating their index values
  Future<void> reorderDistributors(
      List<Distributor> reorderedDistributors) async {
    // Update each distributor with new index
    for (int i = 0; i < reorderedDistributors.length; i++) {
      final distributor = reorderedDistributors[i].copyWith(index: i);
      await _firestoreService.updateDistributor(distributor);
    }
  }

  // JOB OPERATIONS

  Future<void> addJob(Job job) async {
    try {
      final normalized = _normalizeDropOffPoint(job, preferExisting: false);
      await _firestoreService.addJob(normalized, normalized.date);
      debugPrint('Successfully added job for ${job.date}');
    } catch (e) {
      debugPrint('Error adding job: $e');
      rethrow;
    }
  }

  Future<void> updateJob(Job job) async {
    final normalized = _normalizeDropOffPoint(job);
    // Optimistic UI: surface the change locally before the Firestore
    // round-trip so the calling screen (work-areas map, print map, day
    // planner, etc.) reflects the new state instantly. The Firestore
    // stream listener will reconcile if the server-side write differs.
    Job? previous;
    for (final j in jobs) {
      if (j.id == normalized.id) {
        previous = j;
        break;
      }
    }
    if (previous != null) {
      _optimisticUpdateJob(normalized);
    }
    try {
      await _firestoreService.updateJob(normalized, normalized.date);
      _notifyDropsheetOfCoordChanges(previous, normalized);
      debugPrint('Successfully updated job ${job.id}');
    } catch (e) {
      debugPrint('Error updating job: $e');
      // Roll back the optimistic update so the UI returns to the last
      // known-good state instead of showing the failed write.
      if (previous != null) {
        _optimisticUpdateJob(previous);
      }
      rethrow;
    }
  }

  Future<void> deleteJob(String jobId, [DateTime? targetDate]) async {
    try {
      // Find the job to get its date for proper monthly context
      final job = jobs.where((j) => j.id == jobId).firstOrNull;
      final jobDate = targetDate ?? job?.date ?? _currentMonth;
      await _firestoreService.deleteJob(jobId, jobDate);
      debugPrint('Successfully deleted job $jobId');
    } catch (e) {
      debugPrint('Error deleting job: $e');
      rethrow;
    }
  }

  Future<void> moveJobBetweenDates(Job originalJob, Job movedJob) async {
    try {
      await _firestoreService.moveJobBetweenDates(
        originalJob,
        movedJob,
        originalJob.date,
        movedJob.date,
      );
      debugPrint('Successfully moved job ${originalJob.id}');
    } catch (e) {
      debugPrint('Error moving job: $e');
      rethrow;
    }
  }

  // Helper methods

  List<Job> getJobsForDistributorAndDate(String distributorId, DateTime date) {
    final key =
        '$distributorId:${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return _lookupMap[key] ?? const [];
  }

  List<Job> getJobsForDistributor(String distributorId) {
    return schedule.getJobsForDistributor(distributorId);
  }

  List<Job> getJobsForDate(DateTime date) {
    return schedule.getJobsForDate(date);
  }

  // Get jobs for current month only
  List<Job> get currentMonthJobs => _currentMonthJobs;

  // Get jobs for next month only
  List<Job> get nextMonthJobs => _nextMonthJobs;

  // Get next month date
  DateTime get nextMonth =>
      DateTime(_currentMonth.year, _currentMonth.month + 1);

  // Get next month display string
  String get nextMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(nextMonth);

  // Undo/Redo functionality for schedule operations - DISABLED
  // Direct operations without command pattern to avoid state corruption
  Future<void> addJobWithUndo(Job job, DateTime targetDate) async {
    // Bypass command pattern - add job directly
    await addJob(_normalizeDropOffPoint(job, preferExisting: false));
  }

  Future<void> updateJobWithUndo(
      Job originalJob, Job modifiedJob, DateTime targetDate) async {
    final normalized = _normalizeDropOffPoint(modifiedJob);
    // Optimistic UI update — show change instantly before Firestore write
    _optimisticUpdateJob(normalized);
    _notifyDropsheetOfCoordChanges(originalJob, normalized);

    // Check if we're moving the job to a different date
    if (!_isSameDay(originalJob.date, normalized.date)) {
      await moveJobBetweenDates(originalJob, normalized);
    } else {
      await updateJob(normalized);
    }
  }

  Future<void> moveJobBetweenDatesWithUndo(Job originalJob, Job movedJob,
      DateTime originalDate, DateTime newDate) async {
    _optimisticUpdateJob(movedJob);
    await moveJobBetweenDates(originalJob, movedJob);
  }

  Future<void> deleteJobWithUndo(Job job, DateTime targetDate) async {
    await deleteJob(job.id, targetDate);
  }

  Future<void> updateJobStatusWithUndo(String jobId, String newStatusId,
      String originalStatusId, DateTime targetDate) async {
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedJob = job.copyWith(statusId: newStatusId);
    _optimisticUpdateJob(updatedJob);
    await updateJob(updatedJob);
  }

  Future<void> swapJobsWithUndo(
      Job draggedJob, Job targetJob, DateTime targetDate) async {
    // Each job takes the other's position (distributorId + date)
    final newDraggedJob = draggedJob.copyWith(
      distributorId: targetJob.distributorId,
      date: targetJob.date,
    );
    final newTargetJob = targetJob.copyWith(
      distributorId: draggedJob.distributorId,
      date: draggedJob.date,
    );

    // Optimistic UI update — show change instantly
    _optimisticUpdateJob(newDraggedJob);
    _optimisticUpdateJob(newTargetJob);

    // Persist atomically to Firestore
    if (_isSameDay(draggedJob.date, targetJob.date)) {
      await _firestoreService.swapJobsOnSameDate(
          newDraggedJob, newTargetJob, draggedJob.date);
    } else {
      await _firestoreService.swapJobsBetweenDates(
        draggedJob,
        newDraggedJob,
        targetJob,
        newTargetJob,
        draggedJob.date,
        targetJob.date,
      );
    }
  }

  Future<void> combineJobsWithUndo(Job draggedJob, Job targetJob,
      Job combinedJob, DateTime targetDate) async {
    // Optimistic UI update — show change instantly
    _optimisticRemoveJob(draggedJob.id);
    _optimisticUpdateJob(combinedJob);

    // Persist atomically to Firestore
    if (_isSameDay(draggedJob.date, targetJob.date)) {
      await _firestoreService.combineJobsOnSameDate(
          draggedJob.id, combinedJob, draggedJob.date);
    } else {
      await _firestoreService.combineJobsBetweenDates(
          draggedJob.id, combinedJob, draggedJob.date, targetJob.date);
    }
  }

  Future<void> copyAndCombineJobsWithUndo(
      Job targetJob, Job combinedJob, DateTime targetDate) async {
    // Optimistic UI update — show change instantly
    _optimisticUpdateJob(combinedJob);

    await updateJob(combinedJob);
  }

  // Undo/Redo functionality for map operations - DISABLED
  Future<void> addPolygonWithUndo(
      String jobId, CustomPolygon polygon, DateTime targetDate) async {
    // Bypass command pattern - add polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedJob = job.copyWith(
      workMaps: [...job.workMaps, polygon],
    );
    await updateJob(updatedJob);
  }

  Future<void> editPolygonWithUndo(String jobId, CustomPolygon originalPolygon,
      CustomPolygon modifiedPolygon, DateTime targetDate) async {
    // Bypass command pattern - edit polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedMaps = job.workMaps
        .map((p) => p.name == originalPolygon.name ? modifiedPolygon : p)
        .toList();
    final updatedJob = job.copyWith(workMaps: updatedMaps);
    await updateJob(updatedJob);
  }

  Future<void> deletePolygonWithUndo(
      String jobId, CustomPolygon polygon, DateTime targetDate) async {
    // Bypass command pattern - delete polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedMaps =
        job.workMaps.where((p) => p.name != polygon.name).toList();
    final updatedJob = job.copyWith(workMaps: updatedMaps);
    await updateJob(updatedJob);
  }

  // Undo/Redo no longer available - stubs for compatibility
  bool get canUndo => false;
  bool get canRedo => false;
  String? get nextUndoDescription => null;
  String? get nextRedoDescription => null;

  /// Fetch jobs directly from Firestore for a specific date and distributor.
  /// Uses a one-time read so it works regardless of debug/release stream scope.
  Future<List<Job>> fetchJobsForDistributorAndDate(
    String distributorId,
    DateTime date,
  ) async {
    // Normalize to midnight local to ensure we target the right daily doc.
    final localDate = DateTime(date.year, date.month, date.day);
    final jobs = await _firestoreService.fetchJobsForDate(localDate);
    return jobs.where((j) => j.distributorId == distributorId).toList();
  }

  Future<bool> undo() async {
    return false;
  }

  Future<bool> redo() async {
    return false;
  }

  @override
  void dispose() {
    _distributorsSubscription?.cancel();
    _currentMonthJobsSubscription?.cancel();
    _nextMonthJobsSubscription?.cancel();
    _workAreasSubscription?.cancel();
    _workSuburbsSubscription?.cancel();
    super.dispose();
  }
}
