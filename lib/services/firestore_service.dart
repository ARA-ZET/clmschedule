import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/work_area.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Collection references
  CollectionReference get _distributors =>
      _firestore.collection('distributors');
  CollectionReference get _jobs => _firestore.collection('jobs');
  CollectionReference get _workAreas => _firestore.collection('workAreas');

  // DISTRIBUTOR OPERATIONS

  // Stream of all distributors
  Stream<List<Distributor>> streamDistributors() {
    return _distributors.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return Distributor.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
    });
  }

  // Add a new distributor
  Future<String> addDistributor(String name) async {
    final docRef = await _distributors.add({'name': name});
    return docRef.id;
  }

  // Update a distributor
  Future<void> updateDistributor(Distributor distributor) {
    return _distributors.doc(distributor.id).update(distributor.toMap());
  }

  // Delete a distributor
  Future<void> deleteDistributor(String distributorId) {
    return _distributors.doc(distributorId).delete();
  }

  // JOB OPERATIONS

  // Stream of all jobs
  Stream<List<Job>> streamJobs() {
    return _jobs.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return Job.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
    });
  }

  // Add a new job
  Future<String> addJob(Job job) async {
    final docRef = await _jobs.add(job.toMap());
    return docRef.id;
  }

  // Update a job
  Future<void> updateJob(Job job) {
    return _jobs.doc(job.id).update(job.toMap());
  }

  // Delete a job
  Future<void> deleteJob(String jobId) {
    return _jobs.doc(jobId).delete();
  }

  // Stream jobs for a specific distributor
  Stream<List<Job>> streamJobsForDistributor(String distributorId) {
    return _jobs
        .where('distributorId', isEqualTo: distributorId)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            return Job.fromMap(doc.id, doc.data() as Map<String, dynamic>);
          }).toList();
        });
  }

  // Stream jobs for a specific date range
  Stream<List<Job>> streamJobsForDateRange(DateTime start, DateTime end) {
    return _jobs
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

  // Stream of all work areas
  Stream<List<WorkArea>> streamWorkAreas() {
    return _workAreas.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return WorkArea.fromFirestore(doc);
      }).toList();
    });
  }

  // Get a work area by ID
  Future<WorkArea?> getWorkArea(String id) async {
    final doc = await _workAreas.doc(id).get();
    if (!doc.exists) return null;
    return WorkArea.fromFirestore(
      doc as DocumentSnapshot<Map<String, dynamic>>,
    );
  }

  // Update a work area
  Future<void> updateWorkArea(WorkArea workArea) {
    return _workAreas.doc(workArea.id).update(workArea.toFirestore());
  }
}
