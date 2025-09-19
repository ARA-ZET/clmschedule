import 'package:cloud_firestore/cloud_firestore.dart';

class MonthlyService {
  final FirebaseFirestore _firestore;

  MonthlyService(this._firestore);

  /// Generate monthly document ID from date
  /// Format: "MMM YYYY" (e.g., "Sep 2025", "Oct 2025")
  String getMonthlyDocumentId(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];

    final monthName = months[date.month - 1];
    final year = date.year;

    return '$monthName $year';
  }

  /// Get monthly document ID for current month
  String getCurrentMonthlyDocumentId() {
    return getMonthlyDocumentId(DateTime.now());
  }

  /// Get monthly document reference for schedules
  DocumentReference getScheduleMonthlyDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore.collection('schedules').doc(monthlyId);
  }

  /// Get monthly document reference for job lists
  DocumentReference getJobListMonthlyDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore.collection('jobLists').doc(monthlyId);
  }

  /// Get jobs subcollection reference for a specific month
  CollectionReference getJobsCollection(DateTime date) {
    return getScheduleMonthlyDoc(date).collection('jobs');
  }

  /// Get distributors subcollection reference for a specific month
  CollectionReference getDistributorsCollection(DateTime date) {
    return getScheduleMonthlyDoc(date).collection('distributors');
  }

  /// Get work areas subcollection reference for a specific month
  CollectionReference getWorkAreasCollection(DateTime date) {
    return getScheduleMonthlyDoc(date).collection('workAreas');
  }

  /// Get job list items subcollection reference for a specific month
  CollectionReference getJobListItemsCollection(DateTime date) {
    return getJobListMonthlyDoc(date).collection('items');
  }

  /// Ensure monthly document exists (creates if not present)
  Future<void> ensureScheduleMonthlyDocExists(DateTime date) async {
    final doc = getScheduleMonthlyDoc(date);
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'month': getMonthlyDocumentId(date),
      });
    }
  }

  /// Ensure job list monthly document exists (creates if not present)
  Future<void> ensureJobListMonthlyDocExists(DateTime date) async {
    final doc = getJobListMonthlyDoc(date);
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'month': getMonthlyDocumentId(date),
      });
    }
  }

  /// Get all available monthly documents for schedules
  Future<List<String>> getAvailableScheduleMonths() async {
    final snapshot = await _firestore.collection('schedules').get();
    return snapshot.docs.map((doc) => doc.id).toList()
      ..sort((a, b) =>
          _parseMonthYear(b).compareTo(_parseMonthYear(a))); // Latest first
  }

  /// Get all available monthly documents for job lists
  Future<List<String>> getAvailableJobListMonths() async {
    final snapshot = await _firestore.collection('jobLists').get();
    return snapshot.docs.map((doc) => doc.id).toList()
      ..sort((a, b) =>
          _parseMonthYear(b).compareTo(_parseMonthYear(a))); // Latest first
  }

  /// Parse month year string back to DateTime for sorting
  DateTime _parseMonthYear(String monthYear) {
    final parts = monthYear.split(' ');
    if (parts.length != 2) return DateTime.now();

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

    final monthNum = months[parts[0]] ?? 1;
    final year = int.tryParse(parts[1]) ?? DateTime.now().year;

    return DateTime(year, monthNum);
  }

  /// Get date range for a monthly document
  DateTimeRange getMonthDateRange(String monthlyDocId) {
    final date = _parseMonthYear(monthlyDocId);
    final start = DateTime(date.year, date.month, 1);
    final end = DateTime(date.year, date.month + 1, 0, 23, 59, 59, 999);

    return DateTimeRange(start: start, end: end);
  }
}

/// Date range class for convenience
class DateTimeRange {
  final DateTime start;
  final DateTime end;

  DateTimeRange({required this.start, required this.end});
}
