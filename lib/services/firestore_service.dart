import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/work_area.dart';
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

  // Monthly collection reference methods (for jobs only)
  CollectionReference _getJobsCollection(DateTime date) {
    return _monthlyService.getJobsCollection(date);
  }

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

  // Stream jobs for a specific date
  Stream<List<Job>> _streamJobsForDate(DateTime date) {
    return _getJobsCollection(date).snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return Job.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
    });
  }

  // Add a new job
  Future<String> addJob(Job job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure monthly document exists
    await _monthlyService.ensureScheduleMonthlyDocExists(targetDate);

    final docRef = await _getJobsCollection(targetDate).add(job.toMap());
    return docRef.id;
  }

  // Update a job
  Future<void> updateJob(Job job, [DateTime? date]) {
    final targetDate = date ?? job.date;
    return _getJobsCollection(targetDate).doc(job.id).update(job.toMap());
  }

  // Delete a job
  Future<void> deleteJob(String jobId, [DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    return _getJobsCollection(targetDate).doc(jobId).delete();
  }

  // Stream jobs for a specific distributor
  Stream<List<Job>> streamJobsForDistributor(String distributorId,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    return _getJobsCollection(targetDate)
        .where('distributorId', isEqualTo: distributorId)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return Job.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
    });
  }

  // Stream jobs for a specific date range (within same month)
  Stream<List<Job>> streamJobsForDateRange(DateTime start, DateTime end,
      [DateTime? monthContext]) {
    final targetDate = monthContext ?? start;
    return _getJobsCollection(targetDate)
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThanOrEqualTo: Timestamp.fromDate(end))
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return Job.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
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
}
