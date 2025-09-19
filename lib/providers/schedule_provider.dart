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

  // Streams subscriptions
  StreamSubscription<List<Distributor>>? _distributorsSubscription;
  StreamSubscription<List<Job>>? _jobsSubscription;
  StreamSubscription<List<WorkArea>>? _workAreasSubscription;

  // Getters
  List<Distributor> get distributors => _distributors;
  List<Job> get jobs => _jobs;
  List<WorkArea> get workAreas => _workAreas;
  Schedule get schedule => Schedule(distributors: _distributors, jobs: _jobs);

  ScheduleProvider({FirestoreService? firestoreService})
    : _firestoreService = firestoreService ?? FirestoreService() {
    _initStreams();
  }

  void _initStreams() {
    // Listen to distributors stream
    _distributorsSubscription = _firestoreService.streamDistributors().listen((
      distributors,
    ) {
      _distributors = distributors;
      notifyListeners();
    });

    // Listen to jobs stream
    _jobsSubscription = _firestoreService.streamJobs().listen((jobs) {
      _jobs = jobs;
      notifyListeners();
    });

    // Listen to work areas stream
    _workAreasSubscription = _firestoreService.streamWorkAreas().listen((
      workAreas,
    ) {
      _workAreas = workAreas;
      notifyListeners();
    });
  }

  // DISTRIBUTOR OPERATIONS

  Future<void> addDistributor(String name) async {
    await _firestoreService.addDistributor(name);
  }

  Future<void> updateDistributor(Distributor distributor) async {
    await _firestoreService.updateDistributor(distributor);
  }

  Future<void> deleteDistributor(String distributorId) async {
    await _firestoreService.deleteDistributor(distributorId);
  }

  // JOB OPERATIONS

  Future<void> addJob(Job job) async {
    await _firestoreService.addJob(job);
  }

  Future<void> updateJob(Job job) async {
    // Update local state first
    final jobIndex = _jobs.indexWhere((j) => j.id == job.id);
    if (jobIndex != -1) {
      _jobs[jobIndex] = job;
      notifyListeners();
    }
    // Then update Firestore
    await _firestoreService.updateJob(job);
  }

  Future<void> deleteJob(String jobId) async {
    await _firestoreService.deleteJob(jobId);
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
