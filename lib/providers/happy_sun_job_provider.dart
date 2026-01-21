import 'package:flutter/material.dart';
import 'dart:async';
import '../models/happy_sun_job.dart';
import '../models/job_list_item.dart';
import '../services/happy_sun_job_service.dart';

class HappySunJobProvider extends ChangeNotifier {
  final HappySunJobService _jobService = HappySunJobService();

  List<HappySunJob> _jobs = [];
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<HappySunJob>>? _jobsSubscription;

  // Current month being viewed
  DateTime _currentMonth = DateTime.now();

  List<HappySunJob> get jobs => _jobs;
  bool get isLoading => _isLoading;
  String? get error => _error;
  DateTime get currentMonth => _currentMonth;

  HappySunJobProvider() {
    _initializeJobs();
  }

  void _initializeJobs() {
    _setLoading(true);
    _loadJobsForMonth(_currentMonth);
  }

  void _loadJobsForMonth(DateTime month) {
    _jobsSubscription?.cancel();
    _jobsSubscription =
        _jobService.getJobsForMonth(month.year, month.month).listen(
      (jobs) {
        _jobs = jobs;
        _setLoading(false);
        notifyListeners();
      },
      onError: (error) {
        _error = error.toString();
        _setLoading(false);
        notifyListeners();
      },
    );
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  /// Change the current month being viewed
  void setMonth(int year, int month) {
    _currentMonth = DateTime(year, month);
    _loadJobsForMonth(_currentMonth);
  }

  /// Create a Happy Sun job from a JobListItem
  /// Called when a window cleaning or solar panel cleaning job is added
  Future<bool> createJobFromJobListItem(
    JobListItem jobListItem,
    CategorizedTools categorizedTools,
  ) async {
    try {
      // Check if it's a Happy Sun job type
      if (jobListItem.jobType != JobType.windowCleaning &&
          jobListItem.jobType != JobType.solarPanelCleaning) {
        return false; // Not a Happy Sun job
      }

      _error = null;

      final jobType = jobListItem.jobType == JobType.windowCleaning
          ? 'windowCleaning'
          : 'solarPanelCleaning';

      final happySunJob = HappySunJob(
        id: jobListItem.id,
        jobListItemId: jobListItem.id,
        date: jobListItem.date,
        jobType: jobType,
        statusId: jobListItem.jobStatusId,
        toolsNeededCategorized: categorizedTools,
        createdAt: DateTime.now(),
      );

      await _jobService.createJob(happySunJob);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Update Happy Sun job status (synced from JobListItem)
  Future<bool> syncStatusFromJobListItem(JobListItem jobListItem) async {
    try {
      _error = null;
      await _jobService.updateJobStatus(
        jobListItem.id,
        jobListItem.date,
        jobListItem.jobStatusId,
      );
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Delete Happy Sun job (when JobListItem is deleted)
  Future<bool> deleteJob(String jobId, DateTime date) async {
    try {
      _error = null;
      await _jobService.deleteJob(jobId, date);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Update tools needed for a job (planned before checkout)
  Future<bool> updateToolsNeeded(
    String jobId,
    DateTime date,
    List<HappySunToolUsage> toolsNeeded,
  ) async {
    try {
      _error = null;
      await _jobService.updateToolsNeeded(jobId, date, toolsNeeded);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Update tools needed when manDays (number of cleaners) changes
  Future<bool> updateToolsNeededFromManDays(
    String jobId,
    DateTime date,
    int numberOfCleaners,
    CategorizedTools categorizedTools,
  ) async {
    try {
      _error = null;
      await _jobService.updateToolsNeededCategorized(
          jobId, date, categorizedTools);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Add tools to a job
  Future<bool> addTools(
    String jobId,
    DateTime date,
    List<HappySunToolUsage> tools,
  ) async {
    try {
      _error = null;
      await _jobService.addToolsToJob(jobId, date, tools);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Record start time
  Future<bool> recordStartTime(
    String jobId,
    DateTime date,
    DateTime startTime,
  ) async {
    try {
      _error = null;
      await _jobService.recordStartTime(jobId, date, startTime);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Record end time
  Future<bool> recordEndTime(
    String jobId,
    DateTime date,
    DateTime endTime,
  ) async {
    try {
      _error = null;
      await _jobService.recordEndTime(jobId, date, endTime);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Update notes
  Future<bool> updateNotes(String jobId, DateTime date, String notes) async {
    try {
      _error = null;
      await _jobService.updateNotes(jobId, date, notes);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Add team members
  Future<bool> addTeamMembers(
    String jobId,
    DateTime date,
    List<String> teamMemberIds,
  ) async {
    try {
      _error = null;
      await _jobService.addTeamMembers(jobId, date, teamMemberIds);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Get a specific Happy Sun job by ID
  HappySunJob? getJobById(String jobId) {
    try {
      return _jobs.firstWhere((job) => job.id == jobId);
    } catch (e) {
      return null;
    }
  }

  /// Get jobs by type
  List<HappySunJob> getJobsByType(String jobType) {
    return _jobs.where((job) => job.jobType == jobType).toList();
  }

  /// Get window cleaning jobs
  List<HappySunJob> get windowCleaningJobs => getJobsByType('windowCleaning');

  /// Get solar panel cleaning jobs
  List<HappySunJob> get solarPanelCleaningJobs =>
      getJobsByType('solarPanelCleaning');

  @override
  void dispose() {
    _jobsSubscription?.cancel();
    super.dispose();
  }
}
