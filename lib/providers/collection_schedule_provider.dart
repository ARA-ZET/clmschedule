import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/collection_job.dart';
import '../models/job_list_item.dart';
import '../models/work_area.dart';
import '../services/firestore_service.dart';
import 'job_list_provider.dart';

class CollectionScheduleProvider extends ChangeNotifier {
  final FirestoreService _firestoreService;
  final JobListProvider _jobListProvider;

  List<CollectionJob> _collectionJobs = [];
  List<WorkArea> _workAreas = [];
  DateTime _currentMonth = DateTime.now();
  bool _isInitialized = false;
  bool _isLoading = false;

  // Cache for time slot occupation checks to avoid expensive filtering during UI renders
  // Key: "vehicleType_yyyy-MM-dd_timeSlot", Value: List of jobs occupying that slot
  final Map<String, List<CollectionJob>> _timeSlotCache = {};

  // Stream subscriptions
  StreamSubscription<List<WorkArea>>? _workAreasSubscription;
  StreamSubscription? _jobListSubscription;

  // Getters
  List<CollectionJob> get collectionJobs => _collectionJobs;
  List<CollectionJob> get currentMonthCollectionJobs =>
      _getJobsForMonth(_currentMonth);
  List<WorkArea> get workAreas => _workAreas;
  DateTime get currentMonth => _currentMonth;
  String get currentMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(_currentMonth);
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;

  CollectionScheduleProvider({
    FirestoreService? firestoreService,
    required JobListProvider jobListProvider,
  })  : _firestoreService = firestoreService ?? FirestoreService(),
        _jobListProvider = jobListProvider;
  // Don't initialize streams in constructor - let it be lazy loaded

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

  // Load data for a specific month - now does one-time load instead of streaming
  Future<void> _loadDataForMonth(DateTime month) async {
    print(
        'CollectionScheduleProvider: Loading data for month: ${_firestoreService.getMonthlyDocumentId(month)}');

    // Filter and convert job list items to collection jobs (one-time operation)
    _buildCollectionJobs();

    // Load work areas (one-time fetch)
    await _loadWorkAreas();

    // Pre-compute time slot cache asynchronously (non-blocking)
    await _rebuildTimeSlotCache();

    notifyListeners();
  }

  // Build collection jobs from job list provider (one-time operation)
  void _buildCollectionJobs() {
    final jobListItems = _jobListProvider.allJobListItems;
    _collectionJobs = jobListItems
        .where((job) =>
            job.jobType == JobType.junkCollection ||
            job.jobType == JobType.furnitureMove ||
            job.jobType == JobType.trailerTowing)
        .map((job) => _jobListItemToCollectionJob(job))
        .toList();

    print(
        'CollectionScheduleProvider: Built ${_collectionJobs.length} collection jobs from job list');
  }

  // Pre-compute which jobs occupy which time slots - async to not block UI
  Future<void> _rebuildTimeSlotCache() async {
    _timeSlotCache.clear();

    // Process in batches to avoid blocking the UI thread
    const batchSize = 10;
    for (var i = 0; i < _collectionJobs.length; i += batchSize) {
      final end = (i + batchSize < _collectionJobs.length)
          ? i + batchSize
          : _collectionJobs.length;
      final batch = _collectionJobs.sublist(i, end);

      for (final job in batch) {
        final availableTimeSlots = CollectionJob.availableTimeSlots;
        final jobStartIndex = availableTimeSlots.indexOf(job.timeSlot);

        if (jobStartIndex == -1) continue;

        // For each time slot this job occupies
        for (int j = 0; j < job.timeSlots; j++) {
          final slotIndex = jobStartIndex + j;
          if (slotIndex >= availableTimeSlots.length) break;

          final timeSlot = availableTimeSlots[slotIndex];
          final dateStr =
              '${job.date.year}-${job.date.month.toString().padLeft(2, '0')}-${job.date.day.toString().padLeft(2, '0')}';
          final cacheKey = '${job.vehicleType.name}_${dateStr}_$timeSlot';

          _timeSlotCache.putIfAbsent(cacheKey, () => []).add(job);
        }
      }

      // Yield to the UI thread after each batch
      if (i + batchSize < _collectionJobs.length) {
        await Future.delayed(Duration.zero);
      }
    }

    print(
        'CollectionScheduleProvider: Pre-computed time slot cache with ${_timeSlotCache.length} entries');
  }

  // Load work areas (one-time fetch)
  Future<void> _loadWorkAreas() async {
    try {
      // Get the first emission from the stream for one-time fetch
      _workAreas = await _firestoreService.streamWorkAreas().first;
      print(
          'CollectionScheduleProvider: Loaded ${_workAreas.length} work areas');
    } catch (e) {
      print('CollectionScheduleProvider: Error loading work areas: $e');
    }
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

  // Convert JobListItem to CollectionJob
  CollectionJob _jobListItemToCollectionJob(JobListItem jobListItem) {
    // Parse vehicle/trailer from quantity
    final vehicleTrailerCombo =
        _getVehicleTrailerComboFromQuantity(jobListItem.quantity);
    final vehicleTrailer = _parseVehicleTrailerCombo(vehicleTrailerCombo ?? '');

    // Determine timeSlots from quantityDistributed (default to 1 if not set or invalid)
    final timeSlots = (jobListItem.quantityDistributed > 0)
        ? jobListItem.quantityDistributed
        : 1;

    // Extract time slot from the job's date - this handles the properly formatted DateTime
    final timeSlot =
        '${jobListItem.date.hour.toString().padLeft(2, '0')}:${jobListItem.date.minute.toString().padLeft(2, '0')}';

    // Use collectionDate if it has a meaningful time, otherwise fall back to the main date
    final effectiveDate = (jobListItem.collectionDate.year != 2000 &&
            jobListItem.collectionDate.month != 1 &&
            jobListItem.collectionDate.day != 1)
        ? jobListItem.collectionDate
        : jobListItem.date;

    return CollectionJob(
      id: jobListItem.id,
      location: jobListItem.collectionAddress.isNotEmpty
          ? jobListItem.collectionAddress
          : jobListItem.area,
      vehicleType: vehicleTrailer?.vehicleType ?? VehicleType.hyundai,
      trailerType: vehicleTrailer?.trailerType ?? TrailerType.noTrailer,
      date: effectiveDate,
      timeSlot: timeSlot,
      timeSlots: timeSlots,
      assignedStaff: [], // Can be populated later
      staffCount: jobListItem.manDays.ceil(),
      jobType: jobListItem.jobType.displayName,
      statusId: jobListItem.jobStatusId,
      clients: [jobListItem.client],
      notes: jobListItem.specialInstructions,
      jobListItemId: jobListItem.id,
    );
  }

  // Helper method to get jobs for a specific month
  List<CollectionJob> _getJobsForMonth(DateTime month) {
    return _collectionJobs
        .where((job) =>
            job.date.year == month.year && job.date.month == month.month)
        .toList();
  }

  // Helper method to check if the next month has any jobs
  bool hasJobsInNextMonth(DateTime currentMonth) {
    final nextMonth = DateTime(currentMonth.year, currentMonth.month + 1, 1);
    return _getJobsForMonth(nextMonth).isNotEmpty;
  }

  // Helper methods for vehicle/trailer parsing (copied from add_edit_job_dialog.dart)
  String? _getVehicleTrailerComboFromQuantity(int quantity) {
    final combinations = _getVehicleTrailerCombinations();
    if (quantity >= 1 && quantity <= combinations.length) {
      return combinations[quantity - 1];
    }
    return null;
  }

  List<String> _getVehicleTrailerCombinations() {
    return [
      'Hyundai - No trailer',
      'Hyundai - Big trailer',
      'Hyundai - Small trailer',
      'Mahindra - No trailer',
      'Mahindra - Big trailer',
      'Mahindra - Small trailer',
      'Nissan - No trailer',
      'Nissan - Big trailer',
      'Nissan - Small trailer',
    ];
  }

  ({VehicleType vehicleType, TrailerType trailerType})?
      _parseVehicleTrailerCombo(String combo) {
    if (combo.isEmpty) return null;

    final parts = combo.split(' - ');
    if (parts.length != 2) return null;

    final vehicleName = parts[0].trim();
    final trailerName = parts[1].trim();

    // Map vehicle names to enum values
    VehicleType vehicleType;
    switch (vehicleName.toLowerCase()) {
      case 'hyundai':
        vehicleType = VehicleType.hyundai;
        break;
      case 'mahindra':
        vehicleType = VehicleType.mahindra;
        break;
      case 'nissan':
        vehicleType = VehicleType.nissan;
        break;
      default:
        return null;
    }

    // Map trailer names to enum values
    TrailerType trailerType;
    switch (trailerName.toLowerCase()) {
      case 'no trailer':
        trailerType = TrailerType.noTrailer;
        break;
      case 'big trailer':
        trailerType = TrailerType.bigTrailer;
        break;
      case 'small trailer':
        trailerType = TrailerType.smallTrailer;
        break;
      default:
        return null;
    }

    return (vehicleType: vehicleType, trailerType: trailerType);
  }

  // Month navigation methods
  void setCurrentMonth(DateTime month) {
    if (_currentMonth != month) {
      _currentMonth = month;
      _loadDataForMonth(_currentMonth);
      notifyListeners();
    }
  }

  void goToNextMonth() {
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    setCurrentMonth(nextMonth);
  }

  void goToPreviousMonth() {
    final previousMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    setCurrentMonth(previousMonth);
  }

  void goToCurrentMonth() {
    setCurrentMonth(DateTime.now());
  }

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
    return _firestoreService.getAvailableCollectionScheduleMonths();
  }

  // COLLECTION JOB OPERATIONS

  @Deprecated(
      'Collection jobs are now derived from job list data. Modify the job list instead.')
  Future<String> addCollectionJob(CollectionJob job) async {
    // Collection jobs are now automatically derived from job list
    // This method is deprecated - modify the job list instead
    print(
        'addCollectionJob is deprecated - collection jobs are now derived from job list data');
    return job.id;
  }

  @Deprecated(
      'Collection jobs are now derived from job list data. Modify the job list instead.')
  Future<void> updateCollectionJob(CollectionJob job) async {
    // Collection jobs are now automatically derived from job list
    // This method is deprecated - modify the job list instead
    print(
        'updateCollectionJob is deprecated - collection jobs are now derived from job list data');
  }

  Future<void> deleteCollectionJob(String jobId) async {
    try {
      // Find the job to get its date for proper monthly context
      final job = collectionJobs.where((j) => j.id == jobId).firstOrNull;
      final jobDate = job?.date ?? _currentMonth;
      await _firestoreService.deleteCollectionJob(jobId, jobDate);
      print('Successfully deleted collection job $jobId');
    } catch (e) {
      print('Error deleting collection job: $e');
      rethrow;
    }
  }

  CollectionJob? getCollectionJobById(String jobId) {
    try {
      return collectionJobs.where((job) => job.id == jobId).firstOrNull;
    } catch (e) {
      print('Error finding collection job by ID $jobId: $e');
      return null;
    }
  }

  // Helper methods for filtering jobs

  List<CollectionJob> getJobsForVehicleAndDate(
      VehicleType vehicleType, DateTime date) {
    return collectionJobs
        .where((job) =>
            job.vehicleType == vehicleType &&
            job.date.year == date.year &&
            job.date.month == date.month &&
            job.date.day == date.day)
        .toList();
  }

  List<CollectionJob> getJobsForVehicleAndTimeSlot(
      VehicleType vehicleType, DateTime date, String timeSlot) {
    // Use pre-computed cache for instant lookup instead of filtering
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final cacheKey = '${vehicleType.name}_${dateStr}_$timeSlot';

    return _timeSlotCache[cacheKey] ?? [];
  }

  // Helper method to check if a job occupies a specific time slot
  bool _jobOccupiesTimeSlot(CollectionJob job, String timeSlot) {
    final availableTimeSlots = CollectionJob.availableTimeSlots;
    final jobStartIndex = availableTimeSlots.indexOf(job.timeSlot);
    final checkIndex = availableTimeSlots.indexOf(timeSlot);

    if (jobStartIndex == -1 || checkIndex == -1) {
      return job.timeSlot == timeSlot; // Fallback to exact match
    }

    // Check if the timeSlot falls within the job's duration
    final isOccupied = checkIndex >= jobStartIndex &&
        checkIndex < (jobStartIndex + job.timeSlots);

    return isOccupied;
  }

  List<CollectionJob> getJobsForDate(DateTime date) {
    return collectionJobs
        .where((job) =>
            job.date.year == date.year &&
            job.date.month == date.month &&
            job.date.day == date.day)
        .toList();
  }

  List<CollectionJob> getJobsForVehicle(VehicleType vehicleType) {
    return collectionJobs
        .where((job) => job.vehicleType == vehicleType)
        .toList();
  }

  // Check if a specific time slot is available for a vehicle on a date
  bool isTimeSlotAvailable(
      VehicleType vehicleType, DateTime date, String timeSlot) {
    // Use cache for instant lookup
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final cacheKey = '${vehicleType.name}_${dateStr}_$timeSlot';

    return !_timeSlotCache.containsKey(cacheKey) ||
        _timeSlotCache[cacheKey]!.isEmpty;
  }

  // Get all occupied time slots for a vehicle on a specific date
  List<String> getOccupiedTimeSlots(VehicleType vehicleType, DateTime date,
      {String? excludeJobId}) {
    const allTimeSlots = [
      "07:30",
      "08:00",
      "08:30",
      "09:00",
      "09:30",
      "10:00",
      "10:30",
      "11:00",
      "11:30",
      "12:00",
      "12:30",
      "13:00",
      "13:30",
      "14:00",
      "14:30",
      "15:00",
      "15:30",
      "16:00",
      "16:30",
      "17:00",
      "17:30",
      "18:00",
      "18:30",
      "19:00",
      "19:30",
      "20:00"
    ];

    Set<String> occupiedSlots = {};

    for (var job in collectionJobs) {
      // Skip the job being edited if excludeJobId is provided
      if (excludeJobId != null && job.id == excludeJobId) continue;

      if (job.vehicleType == vehicleType &&
          job.date.year == date.year &&
          job.date.month == date.month &&
          job.date.day == date.day) {
        // Add all time slots occupied by this job
        for (var timeSlot in allTimeSlots) {
          if (_jobOccupiesTimeSlot(job, timeSlot)) {
            occupiedSlots.add(timeSlot);
          }
        }
      }
    }

    return occupiedSlots.toList();
  }

  // Check if selecting a time slot with given duration would overlap with existing jobs
  bool wouldOverlapWithExistingJobs(VehicleType vehicleType, DateTime date,
      String startTimeSlot, int duration,
      {String? excludeJobId}) {
    const allTimeSlots = [
      "07:30",
      "08:00",
      "08:30",
      "09:00",
      "09:30",
      "10:00",
      "10:30",
      "11:00",
      "11:30",
      "12:00",
      "12:30",
      "13:00",
      "13:30",
      "14:00",
      "14:30",
      "15:00",
      "15:30",
      "16:00",
      "16:30",
      "17:00",
      "17:30",
      "18:00",
      "18:30",
      "19:00",
      "19:30",
      "20:00"
    ];

    final startIndex = allTimeSlots.indexOf(startTimeSlot);
    if (startIndex == -1) return false;

    // Check if any of the slots this job would occupy are already taken
    for (int i = 0; i < duration; i++) {
      if (startIndex + i >= allTimeSlots.length) break;

      final slotToCheck = allTimeSlots[startIndex + i];
      if (!isTimeSlotAvailable(vehicleType, date, slotToCheck)) {
        // If excludeJobId is provided, check if the conflict is with a different job
        if (excludeJobId != null) {
          final conflictingJobs = collectionJobs.where((job) =>
              job.id != excludeJobId &&
              job.vehicleType == vehicleType &&
              job.date.year == date.year &&
              job.date.month == date.month &&
              job.date.day == date.day &&
              _jobOccupiesTimeSlot(job, slotToCheck));

          if (conflictingJobs.isNotEmpty) return true;
        } else {
          return true;
        }
      }
    }

    return false;
  }

  // Get available time slots for a vehicle on a specific date
  List<String> getAvailableTimeSlots(VehicleType vehicleType, DateTime date) {
    const allTimeSlots = [
      "07:30",
      "08:00",
      "08:30",
      "09:00",
      "09:30",
      "10:00",
      "10:30",
      "11:00",
      "11:30",
      "12:00",
      "12:30",
      "13:00",
      "13:30",
      "14:00",
      "14:30",
      "15:00",
      "15:30",
      "16:00",
      "16:30",
      "17:00",
      "17:30",
      "18:00",
      "18:30",
      "19:00",
      "19:30",
      "20:00"
    ];
    return allTimeSlots
        .where((slot) => isTimeSlotAvailable(vehicleType, date, slot))
        .toList();
  }

  @override
  void dispose() {
    _workAreasSubscription?.cancel();
    _jobListSubscription?.cancel();
    super.dispose();
  }
}
