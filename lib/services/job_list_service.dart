import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/job_list_item.dart';
import 'monthly_service.dart';

class JobListService {
  final MonthlyService _monthlyService;

  JobListService(FirebaseFirestore firestore)
      : _monthlyService = MonthlyService(firestore);

  // Get collection reference for a specific date
  CollectionReference _getJobListItemsCollection(DateTime date) {
    return _monthlyService.getJobListItemsCollection(date);
  }

  // Get all job list items for current month
  Stream<List<JobListItem>> getJobListItems([DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    print('JobListService: Getting job list items for date: $targetDate');
    print(
        'JobListService: Monthly doc ID: ${_monthlyService.getMonthlyDocumentId(targetDate)}');

    // Ensure monthly document exists when streaming
    _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    return _getJobListItemsCollection(targetDate)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      print(
          'JobListService: Firestore snapshot received with ${snapshot.docs.length} documents');
      return snapshot.docs.map((doc) {
        print('JobListService: Processing doc ID: ${doc.id}');
        return JobListItem.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
    });
  }

  // Add a new job list item
  Future<String> addJobListItem(JobListItem jobListItem,
      [DateTime? date]) async {
    final targetDate = date ?? jobListItem.date;

    // Ensure monthly document exists
    await _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    final docRef =
        await _getJobListItemsCollection(targetDate).add(jobListItem.toMap());
    return docRef.id;
  }

  // Update a job list item
  Future<void> updateJobListItem(JobListItem jobListItem,
      [DateTime? date]) async {
    final targetDate = date ?? jobListItem.date;

    // Ensure monthly document exists before updating
    await _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    await _getJobListItemsCollection(targetDate)
        .doc(jobListItem.id)
        .update(jobListItem.toMap());
  }

  // Delete a job list item
  Future<void> deleteJobListItem(String id, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists before deleting
    await _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    await _getJobListItemsCollection(targetDate).doc(id).delete();
  }

  // Get a single job list item by ID
  Future<JobListItem?> getJobListItemById(String id, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();
    final doc = await _getJobListItemsCollection(targetDate).doc(id).get();
    if (doc.exists && doc.data() != null) {
      return JobListItem.fromMap(doc.id, doc.data()! as Map<String, dynamic>);
    }
    return null;
  }

  // Update job status only
  Future<void> updateJobStatus(String id, JobListStatus newStatus,
      [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists before updating status
    await _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    await _getJobListItemsCollection(targetDate)
        .doc(id)
        .update({'jobStatus': newStatus.name});
  }

  // Get job list items by status
  Stream<List<JobListItem>> getJobListItemsByStatus(JobListStatus status,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists when streaming
    _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    return _getJobListItemsCollection(targetDate)
        .where('jobStatus', isEqualTo: status.name)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return JobListItem.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
    });
  }

  // Get job list items by client
  Stream<List<JobListItem>> getJobListItemsByClient(String client,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists when streaming
    _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    return _getJobListItemsCollection(targetDate)
        .where('client', isEqualTo: client)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return JobListItem.fromMap(doc.id, doc.data() as Map<String, dynamic>);
      }).toList();
    });
  }

  // Search job list items by client name (case insensitive)
  Stream<List<JobListItem>> searchJobListItemsByClient(String searchTerm,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists when streaming
    _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    return _getJobListItemsCollection(targetDate)
        .orderBy('client')
        .startAt([searchTerm.toLowerCase()])
        .endAt(['${searchTerm.toLowerCase()}\uf8ff'])
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            return JobListItem.fromMap(
                doc.id, doc.data() as Map<String, dynamic>);
          }).toList();
        });
  }

  // UTILITY METHODS

  // Get available monthly documents for job lists
  Future<List<String>> getAvailableJobListMonths() {
    return _monthlyService.getAvailableJobListMonths();
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
