import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/work_area.dart';
import '../models/work_suburb.dart';
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

  /// Single document that holds all work suburb polygons as an array.
  DocumentReference get _workSuburbsDoc =>
      _firestore.collection('workSuburbs').doc('main');

  /// Lightweight existence check: does the month have any schedule data?
  ///
  /// Probes the monthly index document (created by the first write that
  /// touches the month). Tries Firestore cache first to avoid a billed read,
  /// then falls back to server. Returns true on ambiguous errors so the
  /// caller can fall back to its default behaviour (safe-by-default).
  Future<bool> hasScheduleDataForMonth(DateTime month) async {
    final indexDoc = _dailyService.getScheduleMonthlyIndexDoc(month);
    try {
      final cached = await indexDoc.get(
        const GetOptions(source: Source.cache),
      );
      if (cached.exists) return true;
    } catch (_) {
      // Cache miss or unavailable — fall through to server.
    }
    try {
      final server = await indexDoc.get(
        const GetOptions(source: Source.server),
      );
      return server.exists;
    } catch (_) {
      // On any server error, assume data may exist to preserve existing UX.
      return true;
    }
  }

  // DISTRIBUTOR OPERATIONS

  // Stream of all distributors (from root collection)
  Stream<List<Distributor>> streamDistributors([DateTime? date]) {
    // Date parameter is ignored for distributors since they're in root collection
    return _distributors.orderBy('index').snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return Distributor.fromMap(doc.id, Map<String, dynamic>.from(doc.data() as Map));
      }).toList();
    });
  }

  /// One-shot fetch of distributors (cache-first). Use when a consumer
  /// only needs a snapshot rather than a live subscription.
  Future<List<Distributor>> fetchDistributorsOnce() async {
    QuerySnapshot snapshot;
    try {
      snapshot = await _distributors
          .orderBy('index')
          .get(const GetOptions(source: Source.cache));
      if (snapshot.docs.isEmpty) {
        snapshot = await _distributors.orderBy('index').get();
      }
    } catch (_) {
      snapshot = await _distributors.orderBy('index').get();
    }
    return snapshot.docs.map((doc) {
      return Distributor.fromMap(doc.id, Map<String, dynamic>.from(doc.data() as Map));
    }).toList();
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
      return Distributor.fromMap(doc.id, Map<String, dynamic>.from(doc.data() as Map));
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

      final data = Map<String, dynamic>.from(snapshot.data() as Map);
      final jobsArray = data['jobs'] as List<dynamic>?;

      if (jobsArray == null || jobsArray.isEmpty) {
        return <Job>[];
      }

      return jobsArray.map((jobData) {
        final jobMap = Map<String, dynamic>.from(jobData as Map);
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

  // Stream all jobs for an entire month using a SINGLE collection listener.
  // This replaces 28-31 individual document listeners with 1 query listener.
  // Fires whenever ANY day document in the month changes.
  Stream<List<Job>> streamJobsForMonth(DateTime month) {
    final monthlyId = _dailyService.getMonthlyDocumentId(month);

    return _firestore
        .collection('schedules')
        .doc(monthlyId)
        .collection('days')
        .snapshots()
        .map((querySnapshot) {
      final allJobs = <Job>[];
      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        final jobsArray = data['jobs'] as List<dynamic>?;
        if (jobsArray != null) {
          for (final jobData in jobsArray) {
            allJobs.add(Job.fromArrayElement(Map<String, dynamic>.from(jobData as Map)));
          }
        }
      }
      return allJobs;
    });
  }

  // Stream of all jobs for current month (optimized for monthly view)
  // In debug mode: loads only this week's jobs for faster development
  // In release mode: uses single collection listener (1 instead of 28-31)
  Stream<List<Job>> streamJobs([DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    // Single collection listener per month (optimized — 1 listener instead of 28-31)
    return streamJobsForMonth(targetDate);
  }

  // Stream jobs for optimized range (current month + next month only)
  // Uses 2 collection listeners instead of 56-62 individual ones.
  Stream<List<Job>> streamJobsExtendedRange([DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    final currentMonth = DateTime(targetDate.year, targetDate.month);
    final nextMonth = DateTime(targetDate.year, targetDate.month + 1);

    // Combine two monthly collection streams
    late StreamController<List<Job>> controller;
    List<Job> currentMonthJobs = [];
    List<Job> nextMonthJobs = [];
    final subscriptions = <StreamSubscription>[];

    controller = StreamController<List<Job>>(
      onListen: () {
        subscriptions.add(streamJobsForMonth(currentMonth).listen((jobs) {
          currentMonthJobs = jobs;
          if (!controller.isClosed) {
            controller.add([...currentMonthJobs, ...nextMonthJobs]);
          }
        }));
        subscriptions.add(streamJobsForMonth(nextMonth).listen((jobs) {
          nextMonthJobs = jobs;
          if (!controller.isClosed) {
            controller.add([...currentMonthJobs, ...nextMonthJobs]);
          }
        }));
      },
      onCancel: () {
        for (final sub in subscriptions) {
          sub.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
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

      final data = Map<String, dynamic>.from(snapshot.data() as Map);
      final jobsArray = data['jobs'] as List<dynamic>?;

      if (jobsArray == null || jobsArray.isEmpty) {
        return <Job>[];
      }

      return jobsArray.map((jobData) {
        final jobMap = Map<String, dynamic>.from(jobData as Map);
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
      dropOffPoint: job.dropOffPoint,
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

    final data = Map<String, dynamic>.from(snapshot.data() as Map);
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
  // Uses WriteBatch for atomic operation - job is never lost even on failure.
  Future<void> moveJobBetweenDates(Job originalJob, Job updatedJob,
      DateTime originalDate, DateTime newDate) async {
    // If it's the same date, just do a regular update
    if (originalDate.year == newDate.year &&
        originalDate.month == newDate.month &&
        originalDate.day == newDate.day) {
      await updateJob(updatedJob, newDate);
      return;
    }

    // Different dates - need to remove from original and add to new ATOMICALLY

    // Ensure both daily documents exist
    await _dailyService.ensureScheduleDailyDocExists(originalDate);
    await _dailyService.ensureScheduleDailyDocExists(newDate);

    final sourceDoc = _dailyService.getScheduleDailyDoc(originalDate);
    final destDoc = _dailyService.getScheduleDailyDoc(newDate);

    // Read both documents
    final sourceSnapshot = await sourceDoc.get();
    final destSnapshot = await destDoc.get();

    // Build updated source array (remove the job)
    final sourceData = Map<String, dynamic>.from((sourceSnapshot.data() as Map?) ?? <String, dynamic>{});
    final sourceJobs =
        List<Map<String, dynamic>>.from(sourceData['jobs'] ?? []);
    sourceJobs.removeWhere((j) => j['id'] == originalJob.id);

    // Build updated destination array (add the job)
    final destData = Map<String, dynamic>.from((destSnapshot.data() as Map?) ?? <String, dynamic>{});
    final destJobs = List<Map<String, dynamic>>.from(destData['jobs'] ?? []);
    destJobs.add(updatedJob.toMap());

    // Atomic batch write - both succeed or both fail
    final batch = _firestore.batch();
    batch.update(sourceDoc, {'jobs': sourceJobs});
    batch.update(destDoc, {'jobs': destJobs});
    await batch.commit();
  }

  /// Swap two jobs on the same date in a single atomic write.
  /// Each job gets the other's distributorId.
  Future<void> swapJobsOnSameDate(
      Job newJobA, Job newJobB, DateTime date) async {
    await _dailyService.ensureScheduleDailyDocExists(date);

    final doc = _dailyService.getScheduleDailyDoc(date);
    final snapshot = await doc.get();
    if (!snapshot.exists) return;

    final data = Map<String, dynamic>.from((snapshot.data() as Map?) ?? <String, dynamic>{});
    final jobsArray = List<Map<String, dynamic>>.from(data['jobs'] ?? []);

    for (int i = 0; i < jobsArray.length; i++) {
      if (jobsArray[i]['id'] == newJobA.id) {
        jobsArray[i] = newJobA.toMap();
      } else if (jobsArray[i]['id'] == newJobB.id) {
        jobsArray[i] = newJobB.toMap();
      }
    }

    await doc.update({'jobs': jobsArray});
  }

  /// Swap two jobs across different dates using an atomic batch write.
  /// Job A moves from dateA to dateB, Job B moves from dateB to dateA.
  Future<void> swapJobsBetweenDates(Job originalJobA, Job newJobA,
      Job originalJobB, Job newJobB, DateTime dateA, DateTime dateB) async {
    await _dailyService.ensureScheduleDailyDocExists(dateA);
    await _dailyService.ensureScheduleDailyDocExists(dateB);

    final docA = _dailyService.getScheduleDailyDoc(dateA);
    final docB = _dailyService.getScheduleDailyDoc(dateB);

    final snapshotA = await docA.get();
    final snapshotB = await docB.get();

    final dataA = Map<String, dynamic>.from((snapshotA.data() as Map?) ?? <String, dynamic>{});
    final jobsA = List<Map<String, dynamic>>.from(dataA['jobs'] ?? []);

    final dataB = Map<String, dynamic>.from((snapshotB.data() as Map?) ?? <String, dynamic>{});
    final jobsB = List<Map<String, dynamic>>.from(dataB['jobs'] ?? []);

    // Remove Job A from dateA, add modified Job B to dateA
    jobsA.removeWhere((j) => j['id'] == originalJobA.id);
    jobsA.add(newJobB.toMap());

    // Remove Job B from dateB, add modified Job A to dateB
    jobsB.removeWhere((j) => j['id'] == originalJobB.id);
    jobsB.add(newJobA.toMap());

    final batch = _firestore.batch();
    batch.update(docA, {'jobs': jobsA});
    batch.update(docB, {'jobs': jobsB});
    await batch.commit();
  }

  /// Combine two jobs on the same date in a single atomic write:
  /// removes the source job and updates the target with combined data.
  Future<void> combineJobsOnSameDate(
      String removeJobId, Job combinedJob, DateTime date) async {
    await _dailyService.ensureScheduleDailyDocExists(date);

    final doc = _dailyService.getScheduleDailyDoc(date);
    final snapshot = await doc.get();
    if (!snapshot.exists) return;

    final data = Map<String, dynamic>.from((snapshot.data() as Map?) ?? <String, dynamic>{});
    final jobsArray = List<Map<String, dynamic>>.from(data['jobs'] ?? []);

    // Remove the dragged job
    jobsArray.removeWhere((j) => j['id'] == removeJobId);

    // Update the combined (target) job
    final idx = jobsArray.indexWhere((j) => j['id'] == combinedJob.id);
    if (idx != -1) {
      jobsArray[idx] = combinedJob.toMap();
    }

    await doc.update({'jobs': jobsArray});
  }

  /// Combine two jobs across different dates using an atomic batch write:
  /// removes the source job from sourceDate, updates the target job at targetDate.
  Future<void> combineJobsBetweenDates(String removeJobId, Job combinedJob,
      DateTime sourceDate, DateTime targetDate) async {
    await _dailyService.ensureScheduleDailyDocExists(sourceDate);
    await _dailyService.ensureScheduleDailyDocExists(targetDate);

    final sourceDoc = _dailyService.getScheduleDailyDoc(sourceDate);
    final targetDoc = _dailyService.getScheduleDailyDoc(targetDate);

    final sourceSnapshot = await sourceDoc.get();
    final targetSnapshot = await targetDoc.get();

    // Remove from source
    final sourceData = Map<String, dynamic>.from((sourceSnapshot.data() as Map?) ?? <String, dynamic>{});
    final sourceJobs =
        List<Map<String, dynamic>>.from(sourceData['jobs'] ?? []);
    sourceJobs.removeWhere((j) => j['id'] == removeJobId);

    // Update in target
    final targetData = Map<String, dynamic>.from((targetSnapshot.data() as Map?) ?? <String, dynamic>{});
    final targetJobs =
        List<Map<String, dynamic>>.from(targetData['jobs'] ?? []);
    final idx = targetJobs.indexWhere((j) => j['id'] == combinedJob.id);
    if (idx != -1) {
      targetJobs[idx] = combinedJob.toMap();
    }

    final batch = _firestore.batch();
    batch.update(sourceDoc, {'jobs': sourceJobs});
    batch.update(targetDoc, {'jobs': targetJobs});
    await batch.commit();
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

    final data = Map<String, dynamic>.from(snapshot.data() as Map);
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
        final data = Map<String, dynamic>.from(doc.data() as Map);
        data['id'] = doc.id; // Add the document ID to the data
        return WorkArea.fromMap(data);
      }).toList();
    });
  }

  /// One-shot fetch of work areas. Tries Firestore cache first to avoid a
  /// billed read, falls back to server on cache miss. Use when a consumer
  /// needs a snapshot of work areas without subscribing to live updates.
  Future<List<WorkArea>> fetchWorkAreasOnce() async {
    QuerySnapshot snapshot;
    try {
      snapshot = await _workAreas.get(const GetOptions(source: Source.cache));
      if (snapshot.docs.isEmpty) {
        snapshot = await _workAreas.get();
      }
    } catch (_) {
      snapshot = await _workAreas.get();
    }
    return snapshot.docs.map((doc) {
      final data = Map<String, dynamic>.from(doc.data() as Map);
      data['id'] = doc.id;
      return WorkArea.fromMap(data);
    }).toList();
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

  // ── Work Suburbs (single-document pattern) ──────────────────────────

  /// Real-time stream of all suburb polygons from the single
  /// `workSuburbs/main` document.
  Stream<List<WorkSuburb>> streamWorkSuburbs() {
    return _workSuburbsDoc.snapshots().map((snap) {
      if (!snap.exists) return <WorkSuburb>[];
      final data = snap.data() as Map<String, dynamic>;
      final List<dynamic> raw = data['suburbs'] ?? [];
      return raw
          .map((e) => WorkSuburb.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    });
  }

  /// Cache-first one-shot fetch of work suburbs.
  Future<List<WorkSuburb>> fetchWorkSuburbsOnce() async {
    DocumentSnapshot snap;
    try {
      snap = await _workSuburbsDoc.get(const GetOptions(source: Source.cache));
      if (!snap.exists) snap = await _workSuburbsDoc.get();
    } catch (_) {
      snap = await _workSuburbsDoc.get();
    }
    if (!snap.exists) return [];
    final data = snap.data() as Map<String, dynamic>;
    final List<dynamic> raw = data['suburbs'] ?? [];
    return raw
        .map((e) => WorkSuburb.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Overwrites the entire suburbs array in the single document.
  ///
  /// Deprecated: prefer [saveSuburbOverrides] when using [SuburbDataService].
  Future<void> saveWorkSuburbs(List<WorkSuburb> suburbs) {
    return _workSuburbsDoc.set({
      'suburbs': suburbs.map((s) => s.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ── Work Suburbs — Cloud Storage meta / overrides ─────────────────────────

  DocumentReference get _suburbMetaDoc =>
      _firestore.collection('workSuburbs').doc('meta');

  DocumentReference get _suburbOverridesDoc =>
      _firestore.collection('workSuburbs').doc('overrides');

  /// Fetch the KML version metadata stored at `workSuburbs/meta`.
  ///
  /// Returns a map with at least `version` (String) and `storagePath` (String).
  Future<Map<String, dynamic>?> fetchSuburbMeta() async {
    try {
      final snap = await _suburbMetaDoc.get();
      if (!snap.exists) return null;
      return snap.data() as Map<String, dynamic>;
    } catch (e) {
      debugPrint('FirestoreService.fetchSuburbMeta: $e');
      return null;
    }
  }

  /// Fetch user-editable overrides for individual suburbs (letterBoxEstimate,
  /// description).  Returns a map keyed by suburb id.
  Future<Map<String, Map<String, dynamic>>> fetchSuburbOverrides() async {
    try {
      DocumentSnapshot snap;
      try {
        snap = await _suburbOverridesDoc
            .get(const GetOptions(source: Source.cache));
        if (!snap.exists) snap = await _suburbOverridesDoc.get();
      } catch (_) {
        snap = await _suburbOverridesDoc.get();
      }
      if (!snap.exists) return {};
      final data = snap.data() as Map<String, dynamic>;
      final rawList = data['overrides'] as List<dynamic>? ?? [];
      return {
        for (final o in rawList.cast<Map<String, dynamic>>())
          o['id'] as String: o,
      };
    } catch (e) {
      debugPrint('FirestoreService.fetchSuburbOverrides: $e');
      return {};
    }
  }

  /// Persist user-editable suburb fields.  Only [letterBoxEstimate] and
  /// [description] are saved — coordinates stay in the KML.
  Future<void> saveSuburbOverrides(List<WorkSuburb> suburbs) {
    final overrides = suburbs
        .where((s) => s.letterBoxEstimate != 0 || s.description.isNotEmpty)
        .map((s) => {
              'id': s.id,
              'letterBoxEstimate': s.letterBoxEstimate,
              'description': s.description,
            })
        .toList();

    return _suburbOverridesDoc.set({
      'overrides': overrides,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Write (or update) the KML version metadata at `workSuburbs/meta`.
  ///
  /// Typically called from the seeder script after uploading a new KML.
  Future<void> setSuburbMeta({
    required String version,
    required String storagePath,
  }) {
    return _suburbMetaDoc.set({
      'version': version,
      'storagePath': storagePath,
      'updatedAt': FieldValue.serverTimestamp(),
    });
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

      final data = Map<String, dynamic>.from(snapshot.data() as Map);
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

    final data = Map<String, dynamic>.from(snapshot.data() as Map);
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

    final data = Map<String, dynamic>.from(snapshot.data() as Map);
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

    final data = Map<String, dynamic>.from(snapshot.data() as Map);
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
