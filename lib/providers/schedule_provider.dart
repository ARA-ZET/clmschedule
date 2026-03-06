import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/schedule.dart';
import '../models/work_area.dart';
import '../models/custom_polygon.dart';
import '../services/firestore_service.dart';

class ScheduleProvider extends ChangeNotifier {
  final FirestoreService _firestoreService;

  List<Distributor> _distributors = [];
  List<Job> _currentMonthJobs = [];
  List<Job> _nextMonthJobs = [];
  List<WorkArea> _workAreas = [];
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

  // Streams subscriptions
  StreamSubscription<List<Distributor>>? _distributorsSubscription;
  StreamSubscription<List<Job>>? _currentMonthJobsSubscription;
  StreamSubscription<List<Job>>? _nextMonthJobsSubscription;
  StreamSubscription<List<WorkArea>>? _workAreasSubscription;

  // Getters
  List<Distributor> get distributors => _distributors;
  List<Job> get jobs => _cachedJobs ??= [..._currentMonthJobs, ..._nextMonthJobs];
  List<WorkArea> get workAreas => _workAreas;
  Schedule get schedule => _cachedSchedule ??= Schedule(distributors: _distributors, jobs: jobs);

  /// Build (or return cached) lookup map for O(1) cell queries.
  Map<String, List<Job>> get _lookupMap {
    if (_jobLookupMap != null) return _jobLookupMap!;
    final map = <String, List<Job>>{};
    for (final job in jobs) {
      final key = '${job.distributorId}:${job.date.year}-${job.date.month.toString().padLeft(2, '0')}-${job.date.day.toString().padLeft(2, '0')}';
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

  ScheduleProvider({FirestoreService? firestoreService})
      : _firestoreService = firestoreService ?? FirestoreService();
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
      _distributors = await _firestoreService.streamDistributors().first;
      notifyListeners();
    } catch (e) {
      debugPrint('ScheduleProvider.initForTrackEditor: $e');
    }
  }

  /// One-time read of all work areas from Firestore.
  Future<List<WorkArea>> fetchWorkAreas() async {
    try {
      return await _firestoreService.streamWorkAreas().first;
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
    _distributorsSubscription =
        _firestoreService.streamDistributors().listen(
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
    _workAreasSubscription =
        _firestoreService.streamWorkAreas().listen(
      (workAreas) {
        _workAreas = workAreas;
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: WorkAreas stream error: $error');
      },
    );
  }

  // Load job streams for a specific month (and next month)
  // Only tears down and recreates the two job subscriptions.
  void _loadJobStreamsForMonth(DateTime month) {
    // Cancel ONLY job subscriptions (not global distributors/workAreas)
    _currentMonthJobsSubscription?.cancel();
    _nextMonthJobsSubscription?.cancel();

    // Clear stale data from previous month so the lookup map
    // doesn't contain old-month entries while new streams start.
    _currentMonthJobs = [];
    _nextMonthJobs = [];

    // Invalidate all derived caches
    _invalidateCaches();

    // Calculate next month
    final nextMonth = DateTime(month.year, month.month + 1);

    debugPrint(
        'ScheduleProvider: Starting job streams for current month: ${_firestoreService.getMonthlyDocumentId(month)} and next month: ${_firestoreService.getMonthlyDocumentId(nextMonth)}');

    // Listen to jobs stream for the current month — set up synchronously
    _currentMonthJobsSubscription =
        _firestoreService.streamJobs(month).listen(
      (jobs) {
        _currentMonthJobs = jobs;
        _invalidateCaches();
        debugPrint(
            'ScheduleProvider: Received ${jobs.length} jobs for current month ${_firestoreService.getMonthlyDocumentId(month)}');
        notifyListeners();
      },
      onError: (error) {
        debugPrint(
            'ScheduleProvider: Current month jobs stream error: $error');
      },
    );

    // Listen to jobs stream for the next month
    _nextMonthJobsSubscription =
        _firestoreService.streamJobs(nextMonth).listen(
      (jobs) {
        _nextMonthJobs = jobs;
        _invalidateCaches();
        debugPrint(
            'ScheduleProvider: Received ${jobs.length} jobs for next month ${_firestoreService.getMonthlyDocumentId(nextMonth)}');
        notifyListeners();
      },
      onError: (error) {
        debugPrint(
            'ScheduleProvider: Next month jobs stream error: $error');
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
      await _firestoreService.addJob(job, job.date);
      debugPrint('Successfully added job for ${job.date}');
    } catch (e) {
      debugPrint('Error adding job: $e');
      rethrow;
    }
  }

  Future<void> updateJob(Job job) async {
    try {
      // Update Firestore directly - stream will handle local state update
      await _firestoreService.updateJob(job, job.date);
      debugPrint('Successfully updated job ${job.id}');
    } catch (e) {
      debugPrint('Error updating job: $e');
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
    final key = '$distributorId:${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
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
    await addJob(job);
  }

  Future<void> updateJobWithUndo(
      Job originalJob, Job modifiedJob, DateTime targetDate) async {
    // Bypass command pattern - update job directly
    debugPrint('=== UPDATE JOB WITH UNDO DEBUG ===');
    debugPrint('OriginalJob:');
    debugPrint('  ID: ${originalJob.id}');
    debugPrint('  Clients: ${originalJob.clients}');
    debugPrint('  WorkingAreas: ${originalJob.workingAreas}');
    debugPrint('  WorkMaps: ${originalJob.workMaps.length}');
    debugPrint('  Date: ${originalJob.date}');
    debugPrint('ModifiedJob:');
    debugPrint('  ID: ${modifiedJob.id}');
    debugPrint('  Clients: ${modifiedJob.clients}');
    debugPrint('  WorkingAreas: ${modifiedJob.workingAreas}');
    debugPrint('  WorkMaps: ${modifiedJob.workMaps.length}');
    debugPrint('  Date: ${modifiedJob.date}');
    debugPrint('==================================');

    // Check if we're moving the job to a different date
    if (originalJob.date.year != modifiedJob.date.year ||
        originalJob.date.month != modifiedJob.date.month ||
        originalJob.date.day != modifiedJob.date.day) {
      // Move between dates
      debugPrint('Moving job between dates');
      await moveJobBetweenDates(originalJob, modifiedJob);
    } else {
      // Regular update
      debugPrint('Regular update (same date)');
      await updateJob(modifiedJob);
    }
  }

  Future<void> moveJobBetweenDatesWithUndo(Job originalJob, Job movedJob,
      DateTime originalDate, DateTime newDate) async {
    // Bypass command pattern - move job directly
    await moveJobBetweenDates(originalJob, movedJob);
  }

  Future<void> deleteJobWithUndo(Job job, DateTime targetDate) async {
    // Bypass command pattern - delete job directly
    await deleteJob(job.id, targetDate);
  }

  Future<void> updateJobStatusWithUndo(String jobId, String newStatusId,
      String originalStatusId, DateTime targetDate) async {
    // Bypass command pattern - update status directly
    final job = jobs.firstWhere((j) => j.id == jobId);

    // Debug logging
    debugPrint('=== UPDATE JOB STATUS DEBUG ===');
    debugPrint('Original job:');
    debugPrint('  ID: ${job.id}');
    debugPrint('  StatusId: ${job.statusId}');
    debugPrint('  Clients: ${job.clients}');
    debugPrint('  WorkingAreas: ${job.workingAreas}');
    debugPrint('  WorkMaps count: ${job.workMaps.length}');

    final updatedJob = job.copyWith(statusId: newStatusId);

    debugPrint('Updated job after copyWith:');
    debugPrint('  ID: ${updatedJob.id}');
    debugPrint('  StatusId: ${updatedJob.statusId}');
    debugPrint('  Clients: ${updatedJob.clients}');
    debugPrint('  WorkingAreas: ${updatedJob.workingAreas}');
    debugPrint('  WorkMaps count: ${updatedJob.workMaps.length}');
    debugPrint('===============================');

    await updateJob(updatedJob);
  }

  Future<void> swapJobsWithUndo(
      Job draggedJob, Job targetJob, DateTime targetDate) async {
    // Bypass command pattern - swap jobs directly
    debugPrint('=== SWAP JOBS PROVIDER DEBUG ===');
    debugPrint('DraggedJob before swap:');
    debugPrint('  ID: ${draggedJob.id}');
    debugPrint('  Clients: ${draggedJob.clients}');
    debugPrint('  WorkMaps: ${draggedJob.workMaps.length}');
    debugPrint('  DistributorId: ${draggedJob.distributorId}');
    debugPrint('TargetJob before swap:');
    debugPrint('  ID: ${targetJob.id}');
    debugPrint('  Clients: ${targetJob.clients}');
    debugPrint('  WorkMaps: ${targetJob.workMaps.length}');
    debugPrint('  DistributorId: ${targetJob.distributorId}');

    // Swap distributor IDs
    final swappedDraggedJob =
        draggedJob.copyWith(distributorId: targetJob.distributorId);
    final swappedTargetJob =
        targetJob.copyWith(distributorId: draggedJob.distributorId);

    debugPrint('After copyWith:');
    debugPrint('SwappedDraggedJob:');
    debugPrint('  Clients: ${swappedDraggedJob.clients}');
    debugPrint('  WorkMaps: ${swappedDraggedJob.workMaps.length}');
    debugPrint('  DistributorId: ${swappedDraggedJob.distributorId}');
    debugPrint('SwappedTargetJob:');
    debugPrint('  Clients: ${swappedTargetJob.clients}');
    debugPrint('  WorkMaps: ${swappedTargetJob.workMaps.length}');
    debugPrint('  DistributorId: ${swappedTargetJob.distributorId}');
    debugPrint('===============================');

    await updateJob(swappedDraggedJob);
    await updateJob(swappedTargetJob);
  }

  Future<void> combineJobsWithUndo(Job draggedJob, Job targetJob,
      Job combinedJob, DateTime targetDate) async {
    // Bypass command pattern - combine jobs directly
    debugPrint('=== COMBINE JOBS PROVIDER DEBUG ===');
    debugPrint('DraggedJob to delete:');
    debugPrint('  ID: ${draggedJob.id}');
    debugPrint('  Clients: ${draggedJob.clients}');
    debugPrint('  WorkMaps: ${draggedJob.workMaps.length}');
    debugPrint('CombinedJob to save:');
    debugPrint('  ID: ${combinedJob.id}');
    debugPrint('  Clients: ${combinedJob.clients}');
    debugPrint('  WorkingAreas: ${combinedJob.workingAreas}');
    debugPrint('  WorkMaps: ${combinedJob.workMaps.length}');
    debugPrint('===================================');

    await deleteJob(draggedJob.id, targetDate);
    await updateJob(combinedJob);
  }

  Future<void> copyAndCombineJobsWithUndo(
      Job targetJob, Job combinedJob, DateTime targetDate) async {
    // Bypass command pattern - copy and combine jobs directly
    debugPrint('=== COPY & COMBINE PROVIDER DEBUG ===');
    debugPrint('TargetJob (will keep in place):');
    debugPrint('  ID: ${targetJob.id}');
    debugPrint('  Clients: ${targetJob.clients}');
    debugPrint('  WorkMaps: ${targetJob.workMaps.length}');
    debugPrint('CombinedJob (to save):');
    debugPrint('  ID: ${combinedJob.id}');
    debugPrint('  Clients: ${combinedJob.clients}');
    debugPrint('  WorkingAreas: ${combinedJob.workingAreas}');
    debugPrint('  WorkMaps: ${combinedJob.workMaps.length}');
    debugPrint('=====================================');

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
    super.dispose();
  }
}
