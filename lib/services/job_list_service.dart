import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/job_list_item.dart';

class JobListService {
  final FirebaseFirestore _firestore;
  static const String collectionName = 'jobListItems';

  JobListService(this._firestore);

  // Get all job list items
  Stream<List<JobListItem>> getJobListItems() {
    return _firestore
        .collection(collectionName)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return JobListItem.fromMap(doc.id, doc.data());
      }).toList();
    });
  }

  // Add a new job list item
  Future<String> addJobListItem(JobListItem jobListItem) async {
    final docRef =
        await _firestore.collection(collectionName).add(jobListItem.toMap());
    return docRef.id;
  }

  // Update a job list item
  Future<void> updateJobListItem(JobListItem jobListItem) async {
    await _firestore
        .collection(collectionName)
        .doc(jobListItem.id)
        .update(jobListItem.toMap());
  }

  // Delete a job list item
  Future<void> deleteJobListItem(String id) async {
    await _firestore.collection(collectionName).doc(id).delete();
  }

  // Get a single job list item by ID
  Future<JobListItem?> getJobListItemById(String id) async {
    final doc = await _firestore.collection(collectionName).doc(id).get();
    if (doc.exists && doc.data() != null) {
      return JobListItem.fromMap(doc.id, doc.data()!);
    }
    return null;
  }

  // Update job status only
  Future<void> updateJobStatus(String id, JobListStatus newStatus) async {
    await _firestore
        .collection(collectionName)
        .doc(id)
        .update({'jobStatus': newStatus.name});
  }

  // Get job list items by status
  Stream<List<JobListItem>> getJobListItemsByStatus(JobListStatus status) {
    return _firestore
        .collection(collectionName)
        .where('jobStatus', isEqualTo: status.name)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return JobListItem.fromMap(doc.id, doc.data());
      }).toList();
    });
  }

  // Get job list items by client
  Stream<List<JobListItem>> getJobListItemsByClient(String client) {
    return _firestore
        .collection(collectionName)
        .where('client', isEqualTo: client)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return JobListItem.fromMap(doc.id, doc.data());
      }).toList();
    });
  }

  // Search job list items by client name (case insensitive)
  Stream<List<JobListItem>> searchJobListItemsByClient(String searchTerm) {
    return _firestore
        .collection(collectionName)
        .orderBy('client')
        .startAt([searchTerm.toLowerCase()])
        .endAt(['${searchTerm.toLowerCase()}\uf8ff'])
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            return JobListItem.fromMap(doc.id, doc.data());
          }).toList();
        });
  }
}
