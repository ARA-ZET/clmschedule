import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/work_area.dart';
import '../models/collection_job.dart';
import 'daily_service.dart';

class FirestoreService {
  final DailyService _dailyService;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  FirestoreService() : _dailyService = DailyService(FirebaseFirestore.instance);

  // Root collection references (not daily)
  CollectionReference get _distributors =>
      _firestore.collection('distributors');
  CollectionReference get _workAreas => _firestore.collection('workAreas');

  // DISTRIBUTOR OPERATIONS

  // Stream of all distributors (from root collection)
  Stream<List<Distributor>> streamDistributors([DateTime? date]) {
    // Date parameter is ignored for distributors since they're in root collection
    return _distributors.orderBy('index').snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return Distributor.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
    });
  }

  // Add a new distributor (to root collection)
  Future<String> addDistributor(String name, [DateTime? date]) async {
    // Date parameter is ignored for distributors since they're in root collection

    // Get current count to determine the next index
    final snapshot = await _distributors.get();
    final nextIndex = snapshot.docs.length;

    final docRef = await _distributors.add({
      'name': name,
      'index': nextIndex,
      'phone1': null,
      'phone2': null,
      'status': DistributorStatus.active.name,
    });
    return docRef.id;
  }

  // Update a distributor (in root collection)
  Future<void> updateDistributor(Distributor distributor, [DateTime? date]) {
    // Date parameter is ignored for distributors since they're in root collection
    return _distributors.doc(distributor.id).update(distributor.toMap());
  }

  // Smart update distributor with index management
  Future<void> updateDistributorWithSmartIndexing(
    Distributor updatedDistributor,
    int oldIndex,
  ) async {
    final batch = _firestore.batch();

    // Get all distributors to manage indices
    final snapshot = await _distributors.orderBy('index').get();
    final distributors = snapshot.docs.map((doc) {
      return Distributor.fromMap(doc.id, doc.data() as Map<String, dynamic>);
    }).toList();

    final newIndex = updatedDistributor.index;

    // If index changed, we need to reindex other distributors
    if (oldIndex != newIndex) {
      // Smart indexing: only shift affected distributors
      if (oldIndex < newIndex) {
        // Moving down: shift distributors up
        for (final distributor in distributors) {
          if (distributor.id != updatedDistributor.id &&
              distributor.index > oldIndex &&
              distributor.index <= newIndex) {
            final docRef = _distributors.doc(distributor.id);
            final updatedData =
                distributor.copyWith(index: distributor.index - 1).toMap();
            batch.update(docRef, updatedData);
          }
        }
      } else {
        // Moving up: shift distributors down
        for (final distributor in distributors) {
          if (distributor.id != updatedDistributor.id &&
              distributor.index >= newIndex &&
              distributor.index < oldIndex) {
            final docRef = _distributors.doc(distributor.id);
            final updatedData =
                distributor.copyWith(index: distributor.index + 1).toMap();
            batch.update(docRef, updatedData);
          }
        }
      }
    }

    // Update the main distributor
    final docRef = _distributors.doc(updatedDistributor.id);
    batch.update(docRef, updatedDistributor.toMap());

    await batch.commit();
  }

  // Delete a distributor (from root collection)
  Future<void> deleteDistributor(String distributorId, [DateTime? date]) {
    // Date parameter is ignored for distributors since they're in root collection
    return _distributors.doc(distributorId).delete();
  }

  // JOB OPERATIONS (DAILY STRUCTURE)

  // Stream of all jobs for a specific date
  Stream<List<Job>> streamJobsForDate(DateTime date) {
    // Ensure daily document exists when streaming
    _dailyService.ensureScheduleDailyDocExists(date);

    return _dailyService.getScheduleDailyDoc(date).snapshots().map((snapshot) {
      if (!snapshot.exists || snapshot.data() == null) {
        return <Job>[];
      }

      final data = snapshot.data() as Map<String, dynamic>;
      final jobsArray = data['jobs'] as List<dynamic>?;

      if (jobsArray == null || jobsArray.isEmpty) {
        return <Job>[];
      }

      return jobsArray.map((jobData) {
        final jobMap = jobData as Map<String, dynamic>;
        return Job.fromArrayElement(jobMap);
      }).toList();
    });
  }

  // Stream jobs for a date range (will combine multiple daily documents)
  Stream<List<Job>> streamJobsForDateRange(
      DateTime startDate, DateTime endDate) {
    final dates = _dailyService.getDateRange(startDate, endDate);

    // Use StreamController to combine multiple daily streams
    late StreamController<List<Job>> controller;
    final subscriptions = <StreamSubscription>[];
    Map<String, List<Job>> dailyJobs = {};

    controller = StreamController<List<Job>>(
      onListen: () {
        // Subscribe to each daily document
        for (final date in dates) {
          final dateKey = _dailyService.getDailyDocumentId(date);
          dailyJobs[dateKey] = [];

          final subscription = streamJobsForDate(date).listen((jobs) {
            dailyJobs[dateKey] = jobs;

            // Combine all daily jobs and emit
            final allJobs = <Job>[];
            for (final jobList in dailyJobs.values) {
              allJobs.addAll(jobList);
            }

            if (!controller.isClosed) {
              controller.add(allJobs);
            }
          });

          subscriptions.add(subscription);
        }
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  // Stream of all jobs for current month (optimized for monthly view)
  Stream<List<Job>> streamJobs([DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    final monthStart = DateTime(targetDate.year, targetDate.month, 1);
    final monthEnd = DateTime(targetDate.year, targetDate.month + 1, 0);

    return streamJobsForDateRange(monthStart, monthEnd);
  }

  // Stream jobs for optimized range (current month + next month only)
  Stream<List<Job>> streamJobsExtendedRange([DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    final currentMonthStart = DateTime(targetDate.year, targetDate.month, 1);
    final nextMonthEnd = DateTime(targetDate.year, targetDate.month + 2, 0);

    return streamJobsForDateRange(currentMonthStart, nextMonthEnd);
  }

  // Fetch jobs for a specific date (one-time, not streaming)
  Future<List<Job>> fetchJobsForDate(DateTime date) async {
    try {
      // Ensure daily document exists
      await _dailyService.ensureScheduleDailyDocExists(date);

      final snapshot = await _dailyService.getScheduleDailyDoc(date).get();

      if (!snapshot.exists || snapshot.data() == null) {
        return <Job>[];
      }

      final data = snapshot.data() as Map<String, dynamic>;
      final jobsArray = data['jobs'] as List<dynamic>?;

      if (jobsArray == null || jobsArray.isEmpty) {
        return <Job>[];
      }

      return jobsArray.map((jobData) {
        final jobMap = jobData as Map<String, dynamic>;
        return Job.fromArrayElement(jobMap);
      }).toList();
    } catch (e) {
      print('Error fetching jobs for date ${date.toIso8601String()}: $e');
      return <Job>[];
    }
  }

  // Fetch jobs for a specific month (one-time, not streaming)
  Future<List<Job>> fetchJobsForMonth(DateTime month) async {
    try {
      final monthStart = DateTime(month.year, month.month, 1);
      final monthEnd = DateTime(month.year, month.month + 1, 0);

      final allJobs = <Job>[];
      final dates = _dailyService.getDateRange(monthStart, monthEnd);

      for (final date in dates) {
        final jobs = await fetchJobsForDate(date);
        allJobs.addAll(jobs);
      }

      return allJobs;
    } catch (e) {
      print('Error fetching jobs for month ${month.year}-${month.month}: $e');
      return <Job>[];
    }
  }

  // Add a new job
  Future<String> addJob(Job job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure daily document exists
    await _dailyService.ensureScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getScheduleDailyDoc(targetDate);

    // Generate a unique ID for the job if it doesn't have one
    final jobId =
        job.id.isEmpty ? _firestore.collection('dummy').doc().id : job.id;

    // Create job with proper ID
    final updatedJob = Job(
      id: jobId,
      clients: job.clients,
      workingAreas: job.workingAreas,
      workMaps: job.workMaps,
      distributorId: job.distributorId,
      date: job.date,
      statusId: job.statusId,
    );

    // Add job to the jobs array in the daily document
    await dailyDoc.update({
      'jobs': FieldValue.arrayUnion([updatedJob.toMap()]),
    });

    return jobId;
  }

  // Update a job
  Future<void> updateJob(Job job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure daily document exists before updating
    await _dailyService.ensureScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getScheduleDailyDoc(targetDate);

    // Get current document data
    final snapshot = await dailyDoc.get();
    if (!snapshot.exists) return;

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray = List<Map<String, dynamic>>.from(data['jobs'] ?? []);

    // Find and update the job in the array
    final jobIndex = jobsArray.indexWhere((jobData) => jobData['id'] == job.id);
    if (jobIndex != -1) {
      jobsArray[jobIndex] = job.toMap();

      // Update the document with the modified array
      await dailyDoc.update({'jobs': jobsArray});
    }
  }

  // Update a job using already synced data (optimized - no read operation)
  Future<void> updateJobOptimized(Job job, List<Job> currentJobs,
      [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure daily document exists before updating
    await _dailyService.ensureScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getScheduleDailyDoc(targetDate);

    // Convert current jobs to map array and update the specific job
    final jobsArray = currentJobs.map((j) => j.toMap()).toList();
    final jobIndex = jobsArray.indexWhere((jobData) => jobData['id'] == job.id);

    if (jobIndex != -1) {
      jobsArray[jobIndex] = job.toMap();

      // Update the document with the modified array (no read operation needed)
      await dailyDoc.update({'jobs': jobsArray});
    }
  }

  // Move a job between different dates (handles cross-day/cross-month moves)
  Future<void> moveJobBetweenDates(Job originalJob, Job updatedJob,
      DateTime originalDate, DateTime newDate) async {
    // If it's the same date, just do a regular update
    if (originalDate.year == newDate.year &&
        originalDate.month == newDate.month &&
        originalDate.day == newDate.day) {
      await updateJob(updatedJob, newDate);
      return;
    }

    // Different dates - need to remove from original and add to new

    // Ensure both daily documents exist
    await _dailyService.ensureScheduleDailyDocExists(originalDate);
    await _dailyService.ensureScheduleDailyDocExists(newDate);

    // Remove from original date
    await deleteJob(originalJob.id, originalDate);

    // Add to new date with updated properties
    await addJob(updatedJob, newDate);
  }

  // Delete a job
  Future<void> deleteJob(String jobId, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure daily document exists before deleting
    await _dailyService.ensureScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getScheduleDailyDoc(targetDate);

    // Get current document data
    final snapshot = await dailyDoc.get();
    if (!snapshot.exists) return;

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray = List<Map<String, dynamic>>.from(data['jobs'] ?? []);

    // Remove the job from the array
    jobsArray.removeWhere((jobData) => jobData['id'] == jobId);

    // Update the document with the modified array
    await dailyDoc.update({'jobs': jobsArray});
  }

  // Delete a job using already synced data (optimized - no read operation)
  Future<void> deleteJobOptimized(String jobId, List<Job> currentJobs,
      [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure daily document exists before deleting
    await _dailyService.ensureScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getScheduleDailyDoc(targetDate);

    // Convert current jobs to map array and remove the specific job
    final jobsArray = currentJobs
        .where((job) => job.id != jobId)
        .map((job) => job.toMap())
        .toList();

    // Update the document with the modified array (no read operation needed)
    await dailyDoc.update({'jobs': jobsArray});
  }

  // Stream jobs for a specific distributor
  Stream<List<Job>> streamJobsForDistributor(String distributorId,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    return streamJobsForDate(targetDate).map((jobs) {
      return jobs.where((job) => job.distributorId == distributorId).toList();
    });
  }

  // Stream jobs for a specific date range (within same month)
  Stream<List<Job>> streamJobsForDateRangeInMonth(DateTime start, DateTime end,
      [DateTime? monthContext]) {
    return streamJobsForDateRange(start, end);
  }

  // WORK AREA OPERATIONS

  // Stream of all work areas (from root collection)
  Stream<List<WorkArea>> streamWorkAreas([DateTime? date]) {
    // Date parameter is ignored for work areas since they're in root collection
    return _workAreas.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id; // Add the document ID to the data
        return WorkArea.fromMap(data);
      }).toList();
    });
  }

  // Update a work area (in root collection)
  Future<void> updateWorkArea(WorkArea workArea, [DateTime? date]) {
    // Date parameter is ignored for work areas since they're in root collection
    return _workAreas.doc(workArea.id).update(workArea.toFirestore());
  }

  // Add a new work area (to root collection)
  Future<String> addWorkArea(WorkArea workArea, [DateTime? date]) async {
    // Date parameter is ignored for work areas since they're in root collection
    final docRef = await _workAreas.add(workArea.toFirestore());
    return docRef.id;
  }

  // Delete a work area (from root collection)
  Future<void> deleteWorkArea(String workAreaId, [DateTime? date]) {
    // Date parameter is ignored for work areas since they're in root collection
    return _workAreas.doc(workAreaId).delete();
  }

  // UTILITY METHODS

  // Get available monthly documents for schedules (jobs only)
  Future<List<String>> getAvailableScheduleMonths() {
    return _dailyService.getAvailableScheduleMonths();
  }

  // Get current monthly document ID
  String getCurrentMonthlyDocumentId() {
    return _dailyService.getCurrentMonthlyDocumentId();
  }

  // Get current daily document ID
  String getCurrentDailyDocumentId() {
    return _dailyService.getCurrentDailyDocumentId();
  }

  // Get monthly document ID for a specific date
  String getMonthlyDocumentId(DateTime date) {
    return _dailyService.getMonthlyDocumentId(date);
  }

  // Get daily document ID for a specific date
  String getDailyDocumentId(DateTime date) {
    return _dailyService.getDailyDocumentId(date);
  }

  // COLLECTION JOB OPERATIONS (DAILY STRUCTURE)

  // Stream collection jobs for a specific date
  Stream<List<CollectionJob>> streamCollectionJobsForDate(DateTime date) {
    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(date);

    return dailyDoc.snapshots().map((snapshot) {
      if (!snapshot.exists) return <CollectionJob>[];

      final data = snapshot.data() as Map<String, dynamic>;
      final jobsArray =
          List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

      return jobsArray.map((jobData) {
        final id = jobData['id'] as String;
        return CollectionJob.fromMap(id, jobData);
      }).toList();
    });
  }

  // Stream collection jobs for a month
  Stream<List<CollectionJob>> streamCollectionJobs(DateTime month) {
    final monthStart = DateTime(month.year, month.month, 1);
    final monthEnd = DateTime(month.year, month.month + 1, 0);

    return streamCollectionJobsForDateRange(monthStart, monthEnd);
  }

  // Stream collection jobs for a date range
  Stream<List<CollectionJob>> streamCollectionJobsForDateRange(
      DateTime startDate, DateTime endDate) async* {
    final dates = _dailyService.getDateRange(startDate, endDate);
    final allJobs = <CollectionJob>[];

    for (final date in dates) {
      final jobs = await fetchCollectionJobsForDate(date);
      allJobs.addAll(jobs);
    }
    yield allJobs;

    // Note: For a fully reactive stream, you'd need to combine multiple streams
    // This is a simplified version for demonstration
  }

  // Fetch collection jobs for a specific date (one-time fetch)
  Future<List<CollectionJob>> fetchCollectionJobsForDate(DateTime date) async {
    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(date);
    final snapshot = await dailyDoc.get();

    if (!snapshot.exists) return <CollectionJob>[];

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    return jobsArray.map((jobData) {
      final id = jobData['id'] as String;
      return CollectionJob.fromMap(id, jobData);
    }).toList();
  }

  // Fetch collection jobs for a specific month (one-time fetch)
  Future<List<CollectionJob>> fetchCollectionJobsForMonth(
      DateTime month) async {
    final monthStart = DateTime(month.year, month.month, 1);
    final monthEnd = DateTime(month.year, month.month + 1, 0);

    final allJobs = <CollectionJob>[];
    final dates = _dailyService.getDateRange(monthStart, monthEnd);

    for (final date in dates) {
      final jobs = await fetchCollectionJobsForDate(date);
      allJobs.addAll(jobs);
    }

    return allJobs;
  }

  // Add a collection job
  Future<String> addCollectionJob(CollectionJob job, DateTime date) async {
    final targetDate = date;

    // Ensure daily document exists
    await _dailyService.ensureCollectionScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(targetDate);

    // Generate a unique ID for the job
    final jobId = _firestore.collection('temp').doc().id;
    final jobWithId = job.copyWith();
    final jobMap = jobWithId.toMap();
    jobMap['id'] = jobId; // Ensure ID is set in the map

    // Add to the jobs array
    await dailyDoc.update({
      'collectionJobs': FieldValue.arrayUnion([jobMap])
    });

    return jobId;
  }

  // Update a collection job
  Future<void> updateCollectionJob(CollectionJob job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure daily document exists
    await _dailyService.ensureCollectionScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(targetDate);

    // Get current document data
    final snapshot = await dailyDoc.get();
    if (!snapshot.exists) return;

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    // Find and update the job in the array
    final jobIndex = jobsArray.indexWhere((jobData) => jobData['id'] == job.id);
    if (jobIndex != -1) {
      jobsArray[jobIndex] = job.toMap();

      // Update the document with the modified array
      await dailyDoc.update({'collectionJobs': jobsArray});
    }
  }

  // Delete a collection job
  Future<void> deleteCollectionJob(String jobId, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure daily document exists
    await _dailyService.ensureCollectionScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(targetDate);

    // Get current document data
    final snapshot = await dailyDoc.get();
    if (!snapshot.exists) return;

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    // Remove the job from the array
    jobsArray.removeWhere((jobData) => jobData['id'] == jobId);

    // Update the document with the modified array
    await dailyDoc.update({'collectionJobs': jobsArray});
  }

  // Get available schedule months for collection jobs
  Future<List<String>> getAvailableCollectionScheduleMonths() async {
    return await _dailyService.getAvailableCollectionScheduleMonths();
  }
}
