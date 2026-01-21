import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/window_cleaning_job.dart';
import '../models/job_list_item.dart';
import '../services/firestore_service.dart';
import 'job_list_provider.dart';

class WindowCleaningProvider extends ChangeNotifier {
  final FirestoreService _firestoreService;
  final JobListProvider _jobListProvider;

  List<WindowCleaningJob> _windowCleaningJobs = [];
  DateTime _currentMonth = DateTime.now();
  bool _isInitialized = false;
  bool _isLoading = false;

  // Cache for time slot occupation checks to avoid expensive filtering during UI renders
  // Key: "yyyy-MM-dd_timeSlot", Value: List of jobs occupying that slot
  final Map<String, List<WindowCleaningJob>> _timeSlotCache = {};

  // Getters
  List<WindowCleaningJob> get windowCleaningJobs => _windowCleaningJobs;
  List<WindowCleaningJob> get currentMonthJobs =>
      _getJobsForMonth(_currentMonth);
  DateTime get currentMonth => _currentMonth;
  String get currentMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(_currentMonth);
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;

  WindowCleaningProvider({
    FirestoreService? firestoreService,
    required JobListProvider jobListProvider,
  })  : _firestoreService = firestoreService ?? FirestoreService(),
        _jobListProvider = jobListProvider;

  // Manual initialization - call this when the tab is opened
  Future<void> initialize() async {
    if (_isInitialized) return;

    _isLoading = true;
    notifyListeners();

    try {
      await _loadDataForMonth(_currentMonth);
      _isInitialized = true;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Load data for a specific month
  Future<void> _loadDataForMonth(DateTime month) async {
    print(
        'WindowCleaningProvider: Loading data for month: ${_firestoreService.getMonthlyDocumentId(month)}');

    // Filter and convert job list items to window cleaning jobs
    _buildWindowCleaningJobs();

    // Pre-compute time slot cache asynchronously (non-blocking)
    await _rebuildTimeSlotCache();

    notifyListeners();
  }

  // Build window cleaning jobs from job list provider
  void _buildWindowCleaningJobs() {
    final jobListItems = _jobListProvider.allJobListItems;
    _windowCleaningJobs = jobListItems
        .where((job) => job.jobType == JobType.windowCleaning)
        .map((job) => _jobListItemToWindowCleaningJob(job))
        .toList();

    print(
        'WindowCleaningProvider: Built ${_windowCleaningJobs.length} window cleaning jobs from job list');
  }

  // Pre-compute which jobs occupy which time slots - async to not block UI
  Future<void> _rebuildTimeSlotCache() async {
    _timeSlotCache.clear();

    // Process in batches to avoid blocking the UI thread
    const batchSize = 10;
    for (var i = 0; i < _windowCleaningJobs.length; i += batchSize) {
      final end = (i + batchSize < _windowCleaningJobs.length)
          ? i + batchSize
          : _windowCleaningJobs.length;
      final batch = _windowCleaningJobs.sublist(i, end);

      for (final job in batch) {
        final availableTimeSlots = WindowCleaningJob.availableTimeSlots;
        final jobStartIndex = availableTimeSlots.indexOf(job.timeSlot);

        if (jobStartIndex == -1) continue;

        // For each time slot this job occupies
        for (int j = 0; j < job.timeSlots; j++) {
          final slotIndex = jobStartIndex + j;
          if (slotIndex >= availableTimeSlots.length) break;

          final timeSlot = availableTimeSlots[slotIndex];
          final dateStr =
              '${job.date.year}-${job.date.month.toString().padLeft(2, '0')}-${job.date.day.toString().padLeft(2, '0')}';
          final cacheKey = '${dateStr}_$timeSlot';

          _timeSlotCache.putIfAbsent(cacheKey, () => []).add(job);
        }
      }

      // Yield to the UI thread after each batch
      if (i + batchSize < _windowCleaningJobs.length) {
        await Future.delayed(Duration.zero);
      }
    }

    print(
        'WindowCleaningProvider: Pre-computed time slot cache with ${_timeSlotCache.length} entries');
  }

  // Refresh data manually when needed
  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();

    try {
      await _loadDataForMonth(_currentMonth);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Convert JobListItem to WindowCleaningJob
  WindowCleaningJob _jobListItemToWindowCleaningJob(JobListItem jobListItem) {
    // Determine timeSlots from quantityDistributed (default to 1 if not set or invalid)
    final timeSlots = (jobListItem.quantityDistributed > 0)
        ? jobListItem.quantityDistributed
        : 1;

    // Extract time slot from the job's date
    final timeSlot =
        '${jobListItem.date.hour.toString().padLeft(2, '0')}:${jobListItem.date.minute.toString().padLeft(2, '0')}';

    return WindowCleaningJob(
      id: jobListItem.id,
      location: jobListItem.area,
      client: jobListItem.client,
      date: jobListItem.date,
      timeSlot: timeSlot,
      timeSlots: timeSlots,
      assignedStaff: [], // Can be populated later
      staffCount: jobListItem.manDays.ceil(),
      statusId: jobListItem.jobStatusId,
      notes: jobListItem.specialInstructions,
      jobListItemId: jobListItem.id,
      amount: jobListItem.amount,
    );
  }

  // Helper method to get jobs for a specific month
  List<WindowCleaningJob> _getJobsForMonth(DateTime month) {
    return _windowCleaningJobs
        .where((job) =>
            job.date.year == month.year && job.date.month == month.month)
        .toList();
  }

  // Helper method to check if the next month has any jobs
  bool hasJobsInNextMonth(DateTime currentMonth) {
    final nextMonth = DateTime(currentMonth.year, currentMonth.month + 1, 1);
    return _getJobsForMonth(nextMonth).isNotEmpty;
  }

  // Get jobs for a specific date
  List<WindowCleaningJob> getJobsForDate(DateTime date) {
    return _windowCleaningJobs
        .where((job) =>
            job.date.year == date.year &&
            job.date.month == date.month &&
            job.date.day == date.day)
        .toList();
  }

  // Check if a time slot is occupied for a specific date
  List<WindowCleaningJob> getJobsOccupyingSlot(DateTime date, String timeSlot) {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final cacheKey = '${dateStr}_$timeSlot';
    return _timeSlotCache[cacheKey] ?? [];
  }

  // Change month
  Future<void> changeMonth(DateTime newMonth) async {
    if (_currentMonth.year == newMonth.year &&
        _currentMonth.month == newMonth.month) {
      return; // Already on this month
    }

    _currentMonth = newMonth;
    _isLoading = true;
    notifyListeners();

    try {
      await _loadDataForMonth(_currentMonth);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  WindowCleaningJob? getJobById(String jobId) {
    try {
      return _windowCleaningJobs.where((job) => job.id == jobId).firstOrNull;
    } catch (e) {
      print('Error finding window cleaning job by ID $jobId: $e');
      return null;
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}
