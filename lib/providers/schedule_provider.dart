import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/schedule.dart';
import '../models/work_area.dart';
import '../services/firestore_service.dart';

class ScheduleProvider extends ChangeNotifier {
  final FirestoreService _firestoreService;

  List<Distributor> _distributors = [];
  List<Job> _jobs = [];
  List<WorkArea> _workAreas = [];
  DateTime _currentMonth = DateTime.now();

  // Streams subscriptions
  StreamSubscription<List<Distributor>>? _distributorsSubscription;
  StreamSubscription<List<Job>>? _jobsSubscription;
  StreamSubscription<List<WorkArea>>? _workAreasSubscription;

  // Getters
  List<Distributor> get distributors => _distributors;
  List<Job> get jobs => _jobs;
  List<WorkArea> get workAreas => _workAreas;
  Schedule get schedule => Schedule(distributors: _distributors, jobs: _jobs);
  DateTime get currentMonth => _currentMonth;
  String get currentMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(_currentMonth);

  ScheduleProvider({FirestoreService? firestoreService})
      : _firestoreService = firestoreService ?? FirestoreService() {
    _initStreams();
  }

  void _initStreams() {
    _loadDataForMonth(_currentMonth);
  }

  // Load data for a specific month
  void _loadDataForMonth(DateTime month) {
    // Cancel existing subscriptions
    _distributorsSubscription?.cancel();
    _jobsSubscription?.cancel();
    _workAreasSubscription?.cancel();

    // Listen to distributors stream from root collection (not monthly)
    _distributorsSubscription = _firestoreService.streamDistributors().listen((
      distributors,
    ) {
      _distributors = distributors;
      notifyListeners();
    });

    // Listen to jobs stream for the specific month
    _jobsSubscription = _firestoreService.streamJobs(month).listen((jobs) {
      _jobs = jobs;
      notifyListeners();
    });

    // Listen to work areas stream from root collection (not monthly)
    _workAreasSubscription = _firestoreService.streamWorkAreas().listen((
      workAreas,
    ) {
      _workAreas = workAreas;
      notifyListeners();
    });
  }

  // Change current month
  void setCurrentMonth(DateTime month) {
    if (_currentMonth != month) {
      _currentMonth = month;
      _loadDataForMonth(_currentMonth);
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
    await _firestoreService.addJob(job, job.date);
  }

  Future<void> updateJob(Job job) async {
    // Update local state first
    final jobIndex = _jobs.indexWhere((j) => j.id == job.id);
    if (jobIndex != -1) {
      _jobs[jobIndex] = job;
      notifyListeners();
    }
    // Then update Firestore
    await _firestoreService.updateJob(job, job.date);
  }

  Future<void> deleteJob(String jobId) async {
    // Find the job to get its date for proper monthly context
    final job = _jobs.where((j) => j.id == jobId).firstOrNull;
    final jobDate = job?.date ?? _currentMonth;
    await _firestoreService.deleteJob(jobId, jobDate);
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

  @override
  void dispose() {
    _distributorsSubscription?.cancel();
    _jobsSubscription?.cancel();
    _workAreasSubscription?.cancel();
    super.dispose();
  }
}
