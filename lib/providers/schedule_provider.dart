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

  // Streams subscriptions
  StreamSubscription<List<Distributor>>? _distributorsSubscription;
  StreamSubscription<List<Job>>? _currentMonthJobsSubscription;
  StreamSubscription<List<Job>>? _nextMonthJobsSubscription;
  StreamSubscription<List<WorkArea>>? _workAreasSubscription;

  // Getters
  List<Distributor> get distributors => _distributors;
  List<Job> get jobs => [..._currentMonthJobs, ..._nextMonthJobs];
  List<WorkArea> get workAreas => _workAreas;
  Schedule get schedule => Schedule(distributors: _distributors, jobs: jobs);
  DateTime get currentMonth => _currentMonth;
  String get currentMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(_currentMonth);

  // Helper method to check if the next month has any jobs
  bool get hasJobsInNextMonth => _nextMonthJobs.isNotEmpty;

  ScheduleProvider({FirestoreService? firestoreService})
      : _firestoreService = firestoreService ?? FirestoreService();
  // Don't initialize streams in constructor - let it be done async

  // Initialize streams asynchronously without blocking
  Future<void> initialize() async {
    await _initStreamsAsync();
  }

  // Load data streams asynchronously and concurrently
  Future<void> _initStreamsAsync() async {
    await _loadDataForMonthAsync(_currentMonth);
  }

  // Load data for a specific month (and next month) - async version
  Future<void> _loadDataForMonthAsync(DateTime month) async {
    // Cancel existing subscriptions
    _distributorsSubscription?.cancel();
    _currentMonthJobsSubscription?.cancel();
    _nextMonthJobsSubscription?.cancel();
    _workAreasSubscription?.cancel();

    // Calculate next month
    final nextMonth = DateTime(month.year, month.month + 1);

    print(
        'ScheduleProvider: Starting streams for current month: ${_firestoreService.getMonthlyDocumentId(month)} and next month: ${_firestoreService.getMonthlyDocumentId(nextMonth)}');

    // Start all streams concurrently without blocking
    await Future.microtask(() {
      // Listen to distributors stream from root collection (not monthly)
      _distributorsSubscription =
          _firestoreService.streamDistributors().listen((
        distributors,
      ) {
        _distributors = distributors;
        notifyListeners();
      });

      // Listen to jobs stream for the current month
      _currentMonthJobsSubscription =
          _firestoreService.streamJobs(month).listen((jobs) {
        _currentMonthJobs = jobs;
        print(
            'ScheduleProvider: Received ${jobs.length} jobs for current month ${_firestoreService.getMonthlyDocumentId(month)}');
        notifyListeners();
      });

      // Listen to jobs stream for the next month
      _nextMonthJobsSubscription =
          _firestoreService.streamJobs(nextMonth).listen((jobs) {
        _nextMonthJobs = jobs;
        print(
            'ScheduleProvider: Received ${jobs.length} jobs for next month ${_firestoreService.getMonthlyDocumentId(nextMonth)}');
        notifyListeners();
      });

      // Listen to work areas stream from root collection (not monthly)
      _workAreasSubscription = _firestoreService.streamWorkAreas().listen((
        workAreas,
      ) {
        _workAreas = workAreas;
        notifyListeners();
      });
    });
  }

  // Change current month
  void setCurrentMonth(DateTime month) {
    if (_currentMonth != month) {
      _currentMonth = month;
      _loadDataForMonthAsync(_currentMonth);
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
      print('Successfully added job for ${job.date}');
    } catch (e) {
      print('Error adding job: $e');
      rethrow;
    }
  }

  Future<void> updateJob(Job job) async {
    try {
      // Update Firestore directly - stream will handle local state update
      await _firestoreService.updateJob(job, job.date);
      print('Successfully updated job ${job.id}');
    } catch (e) {
      print('Error updating job: $e');
      rethrow;
    }
  }

  Future<void> deleteJob(String jobId, [DateTime? targetDate]) async {
    try {
      // Find the job to get its date for proper monthly context
      final job = jobs.where((j) => j.id == jobId).firstOrNull;
      final jobDate = targetDate ?? job?.date ?? _currentMonth;
      await _firestoreService.deleteJob(jobId, jobDate);
      print('Successfully deleted job $jobId');
    } catch (e) {
      print('Error deleting job: $e');
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
      print('Successfully moved job ${originalJob.id}');
    } catch (e) {
      print('Error moving job: $e');
      rethrow;
    }
  }

  // Helper methods

  List<Job> getJobsForDistributorAndDate(String distributorId, DateTime date) {
    return schedule.getJobsForDistributorAndDate(distributorId, date);
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
    print('=== UPDATE JOB WITH UNDO DEBUG ===');
    print('OriginalJob:');
    print('  ID: ${originalJob.id}');
    print('  Clients: ${originalJob.clients}');
    print('  WorkingAreas: ${originalJob.workingAreas}');
    print('  WorkMaps: ${originalJob.workMaps.length}');
    print('  Date: ${originalJob.date}');
    print('ModifiedJob:');
    print('  ID: ${modifiedJob.id}');
    print('  Clients: ${modifiedJob.clients}');
    print('  WorkingAreas: ${modifiedJob.workingAreas}');
    print('  WorkMaps: ${modifiedJob.workMaps.length}');
    print('  Date: ${modifiedJob.date}');
    print('==================================');

    // Check if we're moving the job to a different date
    if (originalJob.date.year != modifiedJob.date.year ||
        originalJob.date.month != modifiedJob.date.month ||
        originalJob.date.day != modifiedJob.date.day) {
      // Move between dates
      print('Moving job between dates');
      await moveJobBetweenDates(originalJob, modifiedJob);
    } else {
      // Regular update
      print('Regular update (same date)');
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
    print('=== UPDATE JOB STATUS DEBUG ===');
    print('Original job:');
    print('  ID: ${job.id}');
    print('  StatusId: ${job.statusId}');
    print('  Clients: ${job.clients}');
    print('  WorkingAreas: ${job.workingAreas}');
    print('  WorkMaps count: ${job.workMaps.length}');

    final updatedJob = job.copyWith(statusId: newStatusId);

    print('Updated job after copyWith:');
    print('  ID: ${updatedJob.id}');
    print('  StatusId: ${updatedJob.statusId}');
    print('  Clients: ${updatedJob.clients}');
    print('  WorkingAreas: ${updatedJob.workingAreas}');
    print('  WorkMaps count: ${updatedJob.workMaps.length}');
    print('===============================');

    await updateJob(updatedJob);
  }

  Future<void> swapJobsWithUndo(
      Job draggedJob, Job targetJob, DateTime targetDate) async {
    // Bypass command pattern - swap jobs directly
    print('=== SWAP JOBS PROVIDER DEBUG ===');
    print('DraggedJob before swap:');
    print('  ID: ${draggedJob.id}');
    print('  Clients: ${draggedJob.clients}');
    print('  WorkMaps: ${draggedJob.workMaps.length}');
    print('  DistributorId: ${draggedJob.distributorId}');
    print('TargetJob before swap:');
    print('  ID: ${targetJob.id}');
    print('  Clients: ${targetJob.clients}');
    print('  WorkMaps: ${targetJob.workMaps.length}');
    print('  DistributorId: ${targetJob.distributorId}');

    // Swap distributor IDs
    final swappedDraggedJob =
        draggedJob.copyWith(distributorId: targetJob.distributorId);
    final swappedTargetJob =
        targetJob.copyWith(distributorId: draggedJob.distributorId);

    print('After copyWith:');
    print('SwappedDraggedJob:');
    print('  Clients: ${swappedDraggedJob.clients}');
    print('  WorkMaps: ${swappedDraggedJob.workMaps.length}');
    print('  DistributorId: ${swappedDraggedJob.distributorId}');
    print('SwappedTargetJob:');
    print('  Clients: ${swappedTargetJob.clients}');
    print('  WorkMaps: ${swappedTargetJob.workMaps.length}');
    print('  DistributorId: ${swappedTargetJob.distributorId}');
    print('===============================');

    await updateJob(swappedDraggedJob);
    await updateJob(swappedTargetJob);
  }

  Future<void> combineJobsWithUndo(Job draggedJob, Job targetJob,
      Job combinedJob, DateTime targetDate) async {
    // Bypass command pattern - combine jobs directly
    print('=== COMBINE JOBS PROVIDER DEBUG ===');
    print('DraggedJob to delete:');
    print('  ID: ${draggedJob.id}');
    print('  Clients: ${draggedJob.clients}');
    print('  WorkMaps: ${draggedJob.workMaps.length}');
    print('CombinedJob to save:');
    print('  ID: ${combinedJob.id}');
    print('  Clients: ${combinedJob.clients}');
    print('  WorkingAreas: ${combinedJob.workingAreas}');
    print('  WorkMaps: ${combinedJob.workMaps.length}');
    print('===================================');

    await deleteJob(draggedJob.id, targetDate);
    await updateJob(combinedJob);
  }

  Future<void> copyAndCombineJobsWithUndo(
      Job targetJob, Job combinedJob, DateTime targetDate) async {
    // Bypass command pattern - copy and combine jobs directly
    print('=== COPY & COMBINE PROVIDER DEBUG ===');
    print('TargetJob (will keep in place):');
    print('  ID: ${targetJob.id}');
    print('  Clients: ${targetJob.clients}');
    print('  WorkMaps: ${targetJob.workMaps.length}');
    print('CombinedJob (to save):');
    print('  ID: ${combinedJob.id}');
    print('  Clients: ${combinedJob.clients}');
    print('  WorkingAreas: ${combinedJob.workingAreas}');
    print('  WorkMaps: ${combinedJob.workMaps.length}');
    print('=====================================');

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
