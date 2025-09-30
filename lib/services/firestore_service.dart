import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/work_area.dart';
import '../models/collection_job.dart';
import 'monthly_service.dart';

class FirestoreService {
  final MonthlyService _monthlyService;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  FirestoreService()
      : _monthlyService = MonthlyService(FirebaseFirestore.instance);

  // Root collection references (not monthly)
  CollectionReference get _distributors =>
      _firestore.collection('distributors');
  CollectionReference get _workAreas => _firestore.collection('workAreas');

  // Monthly collection reference methods are now handled directly by monthly service

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

  // JOB OPERATIONS

  // Stream of all jobs for current month
  Stream<List<Job>> streamJobs([DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    return _streamJobsForDate(targetDate);
  }

  // Stream jobs for optimized range (current month + next month only)
  Stream<List<Job>> streamJobsExtendedRange([DateTime? date]) async* {
    final targetDate = date ?? DateTime.now();

    // Get the two months we need to cover (current + next, no previous)
    final currentMonth = DateTime(targetDate.year, targetDate.month);
    final nextMonth = DateTime(targetDate.year, targetDate.month + 1);

    // Listen to current month stream and combine with fetched data from next month
    await for (final currentJobs in _streamJobsForDate(currentMonth)) {
      // Fetch jobs from next month only (not streaming to avoid too many streams)
      final nextJobs = await fetchJobsForMonth(nextMonth);

      final allJobs = <Job>[...currentJobs, ...nextJobs];

      // Filter to only include jobs within the optimized range (current + next month)
      final startDate = DateTime(targetDate.year, targetDate.month, 1);
      final endDate = DateTime(targetDate.year, targetDate.month + 2, 0);

      final filteredJobs = allJobs
          .where((job) =>
              job.date.isAfter(startDate.subtract(const Duration(days: 1))) &&
              job.date.isBefore(endDate.add(const Duration(days: 1))))
          .toList();

      yield filteredJobs;
    }
  }

  // Fetch jobs for a specific month (one-time, not streaming)
  Future<List<Job>> fetchJobsForMonth(DateTime month) async {
    try {
      // Ensure monthly document exists
      await _monthlyService.ensureScheduleMonthlyDocExists(month);

      final snapshot = await _monthlyService.getScheduleMonthlyDoc(month).get();

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
      print('Error fetching jobs for month ${month.year}-${month.month}: $e');
      return <Job>[];
    }
  }

  // Stream jobs for a specific date
  Stream<List<Job>> _streamJobsForDate(DateTime date) {
    // Ensure monthly document exists when streaming
    _monthlyService.ensureScheduleMonthlyDocExists(date);

    return _monthlyService
        .getScheduleMonthlyDoc(date)
        .snapshots()
        .map((snapshot) {
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

  // Add a new job
  Future<String> addJob(Job job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure monthly document exists
    await _monthlyService.ensureScheduleMonthlyDocExists(targetDate);

    final monthlyDoc = _monthlyService.getScheduleMonthlyDoc(targetDate);

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

    // Add job to the jobs array in the monthly document
    await monthlyDoc.update({
      'jobs': FieldValue.arrayUnion([updatedJob.toMap()]),
    });

    return jobId;
  }

  // Update a job (optimized version using current jobs data)
  Future<void> updateJob(Job job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure monthly document exists before updating
    await _monthlyService.ensureScheduleMonthlyDocExists(targetDate);

    final monthlyDoc = _monthlyService.getScheduleMonthlyDoc(targetDate);

    // Get current document data
    final snapshot = await monthlyDoc.get();
    if (!snapshot.exists) return;

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray = List<Map<String, dynamic>>.from(data['jobs'] ?? []);

    // Find and update the job in the array
    final jobIndex = jobsArray.indexWhere((jobData) => jobData['id'] == job.id);
    if (jobIndex != -1) {
      jobsArray[jobIndex] = job.toMap();

      // Update the document with the modified array
      await monthlyDoc.update({'jobs': jobsArray});
    }
  }

  // Update a job using already synced data (optimized - no read operation)
  Future<void> updateJobOptimized(Job job, List<Job> currentJobs,
      [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure monthly document exists before updating
    await _monthlyService.ensureScheduleMonthlyDocExists(targetDate);

    final monthlyDoc = _monthlyService.getScheduleMonthlyDoc(targetDate);

    // Convert current jobs to map array and update the specific job
    final jobsArray = currentJobs.map((j) => j.toMap()).toList();
    final jobIndex = jobsArray.indexWhere((jobData) => jobData['id'] == job.id);

    if (jobIndex != -1) {
      jobsArray[jobIndex] = job.toMap();

      // Update the document with the modified array (no read operation needed)
      await monthlyDoc.update({'jobs': jobsArray});
    }
  }

  // Delete a job
  Future<void> deleteJob(String jobId, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists before deleting
    await _monthlyService.ensureScheduleMonthlyDocExists(targetDate);

    final monthlyDoc = _monthlyService.getScheduleMonthlyDoc(targetDate);

    // Get current document data
    final snapshot = await monthlyDoc.get();
    if (!snapshot.exists) return;

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray = List<Map<String, dynamic>>.from(data['jobs'] ?? []);

    // Remove the job from the array
    jobsArray.removeWhere((jobData) => jobData['id'] == jobId);

    // Update the document with the modified array
    await monthlyDoc.update({'jobs': jobsArray});
  }

  // Delete a job using already synced data (optimized - no read operation)
  Future<void> deleteJobOptimized(String jobId, List<Job> currentJobs,
      [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists before deleting
    await _monthlyService.ensureScheduleMonthlyDocExists(targetDate);

    final monthlyDoc = _monthlyService.getScheduleMonthlyDoc(targetDate);

    // Convert current jobs to map array and remove the specific job
    final jobsArray = currentJobs
        .where((job) => job.id != jobId)
        .map((job) => job.toMap())
        .toList();

    // Update the document with the modified array (no read operation needed)
    await monthlyDoc.update({'jobs': jobsArray});
  }

  // Stream jobs for a specific distributor
  Stream<List<Job>> streamJobsForDistributor(String distributorId,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists when streaming
    _monthlyService.ensureScheduleMonthlyDocExists(targetDate);

    return _monthlyService
        .getScheduleMonthlyDoc(targetDate)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists || snapshot.data() == null) {
        return <Job>[];
      }

      final data = snapshot.data() as Map<String, dynamic>;
      final jobsArray = data['jobs'] as List<dynamic>?;

      if (jobsArray == null || jobsArray.isEmpty) {
        return <Job>[];
      }

      return jobsArray
          .map((jobData) {
            final jobMap = jobData as Map<String, dynamic>;
            return Job.fromArrayElement(jobMap);
          })
          .where((job) => job.distributorId == distributorId)
          .toList();
    });
  }

  // Stream jobs for a specific date range (within same month)
  Stream<List<Job>> streamJobsForDateRange(DateTime start, DateTime end,
      [DateTime? monthContext]) {
    final targetDate = monthContext ?? start;

    // Ensure monthly document exists when streaming
    _monthlyService.ensureScheduleMonthlyDocExists(targetDate);

    return _monthlyService
        .getScheduleMonthlyDoc(targetDate)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists || snapshot.data() == null) {
        return <Job>[];
      }

      final data = snapshot.data() as Map<String, dynamic>;
      final jobsArray = data['jobs'] as List<dynamic>?;

      if (jobsArray == null || jobsArray.isEmpty) {
        return <Job>[];
      }

      return jobsArray
          .map((jobData) {
            final jobMap = jobData as Map<String, dynamic>;
            return Job.fromArrayElement(jobMap);
          })
          .where((job) =>
              job.date.isAfter(start.subtract(const Duration(days: 1))) &&
              job.date.isBefore(end.add(const Duration(days: 1))))
          .toList();
    });
  }

  // WORK AREA OPERATIONS

  // Stream of all work areas (from root collection)
  Stream<List<WorkArea>> streamWorkAreas([DateTime? date]) {
    // Date parameter is ignored for work areas since they're in root collection
    return _workAreas.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return WorkArea.fromFirestore(doc);
      }).toList();
    });
  }

  // Get a work area by ID (from root collection)
  Future<WorkArea?> getWorkArea(String id, [DateTime? date]) async {
    // Date parameter is ignored for work areas since they're in root collection
    final doc = await _workAreas.doc(id).get();
    if (!doc.exists) return null;
    return WorkArea.fromFirestore(
      doc as DocumentSnapshot<Map<String, dynamic>>,
    );
  }

  // Update a work area (in root collection)
  Future<void> updateWorkArea(WorkArea workArea, [DateTime? date]) async {
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
    return _monthlyService.getAvailableScheduleMonths();
  }

  // Get current monthly document ID
  String getCurrentMonthlyDocumentId() {
    return _monthlyService.getCurrentMonthlyDocumentId();
  }

  // Get monthly document ID for a specific date
  String getMonthlyDocumentId(DateTime date) {
    return _monthlyService.getMonthlyDocumentId(date);
  }

  // COLLECTION JOB OPERATIONS

  // Stream collection jobs for a specific month
  Stream<List<CollectionJob>> streamCollectionJobs(DateTime month) {
    final monthlyDoc = _monthlyService.getCollectionScheduleMonthlyDoc(month);

    return monthlyDoc.snapshots().map((snapshot) {
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

  // Fetch collection jobs for a specific month (one-time fetch)
  Future<List<CollectionJob>> fetchCollectionJobsForMonth(
      DateTime month) async {
    final monthlyDoc = _monthlyService.getCollectionScheduleMonthlyDoc(month);

    final snapshot = await monthlyDoc.get();
    if (!snapshot.exists) return <CollectionJob>[];

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    return jobsArray.map((jobData) {
      final id = jobData['id'] as String;
      return CollectionJob.fromMap(id, jobData);
    }).toList();
  }

  // Add a collection job
  Future<String> addCollectionJob(CollectionJob job, DateTime date) async {
    final targetDate = date;

    // Ensure monthly document exists
    await _monthlyService.ensureCollectionScheduleMonthlyDocExists(targetDate);

    final monthlyDoc =
        _monthlyService.getCollectionScheduleMonthlyDoc(targetDate);

    // Generate a unique ID for the job
    final jobId = _firestore.collection('temp').doc().id;
    final jobWithId = job.copyWith();
    final jobMap = jobWithId.toMap();
    jobMap['id'] = jobId; // Ensure ID is set in the map

    // Add to the jobs array
    await monthlyDoc.update({
      'collectionJobs': FieldValue.arrayUnion([jobMap])
    });

    return jobId;
  }

  // Update a collection job
  Future<void> updateCollectionJob(CollectionJob job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure monthly document exists
    await _monthlyService.ensureCollectionScheduleMonthlyDocExists(targetDate);

    final monthlyDoc =
        _monthlyService.getCollectionScheduleMonthlyDoc(targetDate);

    // Get current document data
    final snapshot = await monthlyDoc.get();
    if (!snapshot.exists) return;

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    // Find and update the job in the array
    final jobIndex = jobsArray.indexWhere((jobData) => jobData['id'] == job.id);
    if (jobIndex != -1) {
      jobsArray[jobIndex] = job.toMap();

      // Update the document with the modified array
      await monthlyDoc.update({'collectionJobs': jobsArray});
    }
  }

  // Delete a collection job
  Future<void> deleteCollectionJob(String jobId, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists
    await _monthlyService.ensureCollectionScheduleMonthlyDocExists(targetDate);

    final monthlyDoc =
        _monthlyService.getCollectionScheduleMonthlyDoc(targetDate);

    // Get current document data
    final snapshot = await monthlyDoc.get();
    if (!snapshot.exists) return;

    final data = snapshot.data() as Map<String, dynamic>;
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    // Remove the job from the array
    jobsArray.removeWhere((jobData) => jobData['id'] == jobId);

    // Update the document with the modified array
    await monthlyDoc.update({'collectionJobs': jobsArray});
  }

  // Get available schedule months for collection jobs
  Future<List<String>> getAvailableCollectionScheduleMonths() async {
    return await _monthlyService.getAvailableCollectionScheduleMonths();
  }
}
