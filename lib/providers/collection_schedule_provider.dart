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

  CollectionScheduleProvider({
    FirestoreService? firestoreService,
    required JobListProvider jobListProvider,
  })  : _firestoreService = firestoreService ?? FirestoreService(),
        _jobListProvider = jobListProvider {
    _initStreams();
  }

  void _initStreams() {
    _loadDataForMonth(_currentMonth);
  }

  // Load data for a specific month
  void _loadDataForMonth(DateTime month) {
    // Cancel existing subscriptions
    _jobListSubscription?.cancel();
    _workAreasSubscription?.cancel();

    print(
        'CollectionScheduleProvider: Starting streams for current month: ${_firestoreService.getMonthlyDocumentId(month)}');

    // Listen to job list changes and transform collection jobs
    _jobListProvider.addListener(_onJobListChanged);
    _onJobListChanged(); // Initial load

    // Listen to work areas stream from root collection (not monthly)
    _workAreasSubscription =
        _firestoreService.streamWorkAreas().listen((workAreas) {
      _workAreas = workAreas;
      notifyListeners();
    });
  }

  // Convert job list items to collection jobs
  void _onJobListChanged() {
    final jobListItems = _jobListProvider.jobListItems;
    _collectionJobs = jobListItems
        .where((job) =>
            job.jobType == JobType.junkCollection ||
            job.jobType == JobType.furnitureMove)
        .map((job) => _jobListItemToCollectionJob(job))
        .toList();

    print(
        'CollectionScheduleProvider: Received ${_collectionJobs.length} collection jobs from job list');
    notifyListeners();
  }

  // Convert JobListItem to CollectionJob
  CollectionJob _jobListItemToCollectionJob(JobListItem jobListItem) {
    // Parse vehicle/trailer from quantity
    final vehicleTrailerCombo =
        _getVehicleTrailerComboFromQuantity(jobListItem.quantity);
    final vehicleTrailer = _parseVehicleTrailerCombo(vehicleTrailerCombo ?? '');

    return CollectionJob(
      id: jobListItem.id,
      location: jobListItem.collectionAddress.isNotEmpty
          ? jobListItem.collectionAddress
          : jobListItem.area,
      vehicleType: vehicleTrailer?.vehicleType ?? VehicleType.hyundai,
      trailerType: vehicleTrailer?.trailerType ?? TrailerType.noTrailer,
      date: jobListItem.date,
      timeSlot: jobListItem.date.hour,
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
      VehicleType vehicleType, DateTime date, int timeSlot) {
    return collectionJobs
        .where((job) =>
            job.vehicleType == vehicleType &&
            job.date.year == date.year &&
            job.date.month == date.month &&
            job.date.day == date.day &&
            job.timeSlot == timeSlot)
        .toList();
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
      VehicleType vehicleType, DateTime date, int timeSlot) {
    return !collectionJobs.any((job) =>
        job.vehicleType == vehicleType &&
        job.date.year == date.year &&
        job.date.month == date.month &&
        job.date.day == date.day &&
        job.timeSlot == timeSlot);
  }

  // Get available time slots for a vehicle on a specific date
  List<int> getAvailableTimeSlots(VehicleType vehicleType, DateTime date) {
    const allTimeSlots = [8, 9, 10, 11, 12, 13, 14, 15, 16]; // 08:00 to 16:00
    return allTimeSlots
        .where((slot) => isTimeSlotAvailable(vehicleType, date, slot))
        .toList();
  }

  @override
  void dispose() {
    _jobListProvider.removeListener(_onJobListChanged);
    _workAreasSubscription?.cancel();
    super.dispose();
  }
}
