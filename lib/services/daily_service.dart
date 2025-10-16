import 'package:cloud_firestore/cloud_firestore.dart';

class DailyService {
  final FirebaseFirestore _firestore;

  DailyService(this._firestore);

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

  /// Generate daily document ID from date
  /// Format: "YYYY-MM-DD" (e.g., "2025-10-15")
  String getDailyDocumentId(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  /// Get monthly document ID for current month
  String getCurrentMonthlyDocumentId() {
    return getMonthlyDocumentId(DateTime.now());
  }

  /// Get daily document ID for current date
  String getCurrentDailyDocumentId() {
    return getDailyDocumentId(DateTime.now());
  }

  // SCHEDULE COLLECTION REFERENCES

  /// Get monthly collection reference for schedules
  CollectionReference getScheduleMonthlyCollection(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore.collection('schedules').doc(monthlyId).collection('days');
  }

  /// Get daily document reference for schedules
  DocumentReference getScheduleDailyDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    final dailyId = getDailyDocumentId(date);
    return _firestore
        .collection('schedules')
        .doc(monthlyId)
        .collection('days')
        .doc(dailyId);
  }

  /// Get monthly index document reference for schedules
  DocumentReference getScheduleMonthlyIndexDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore
        .collection('schedules')
        .doc(monthlyId)
        .collection('meta')
        .doc('index');
  }

  // JOB LIST COLLECTION REFERENCES

  /// Get monthly collection reference for job lists
  CollectionReference getJobListMonthlyCollection(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore.collection('jobLists').doc(monthlyId).collection('days');
  }

  /// Get daily document reference for job lists
  DocumentReference getJobListDailyDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    final dailyId = getDailyDocumentId(date);
    return _firestore
        .collection('jobLists')
        .doc(monthlyId)
        .collection('days')
        .doc(dailyId);
  }

  /// Get monthly index document reference for job lists
  DocumentReference getJobListMonthlyIndexDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore
        .collection('jobLists')
        .doc(monthlyId)
        .collection('meta')
        .doc('index');
  }

  // COLLECTION SCHEDULE COLLECTION REFERENCES

  /// Get monthly collection reference for collection schedules
  CollectionReference getCollectionScheduleMonthlyCollection(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore
        .collection('collectionSchedules')
        .doc(monthlyId)
        .collection('days');
  }

  /// Get daily document reference for collection schedules
  DocumentReference getCollectionScheduleDailyDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    final dailyId = getDailyDocumentId(date);
    return _firestore
        .collection('collectionSchedules')
        .doc(monthlyId)
        .collection('days')
        .doc(dailyId);
  }

  /// Get monthly index document reference for collection schedules
  DocumentReference getCollectionScheduleMonthlyIndexDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore
        .collection('collectionSchedules')
        .doc(monthlyId)
        .collection('meta')
        .doc('index');
  }

  // DOCUMENT EXISTENCE MANAGEMENT

  /// Ensure daily document exists for schedules (creates if not present)
  Future<void> ensureScheduleDailyDocExists(DateTime date) async {
    final doc = getScheduleDailyDoc(date);
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'date': getDailyDocumentId(date),
        'timestamp': Timestamp.fromDate(date),
        'jobs': [], // Initialize with empty jobs array
      });

      // Also ensure monthly index exists
      await _ensureScheduleMonthlyIndexExists(date);
    } else {
      // Ensure jobs field exists for existing documents
      final data = docSnapshot.data() as Map<String, dynamic>?;
      if (data != null && !data.containsKey('jobs')) {
        await doc.update({'jobs': []});
      }
    }
  }

  /// Ensure daily document exists for job lists (creates if not present)
  Future<void> ensureJobListDailyDocExists(DateTime date) async {
    final doc = getJobListDailyDoc(date);
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'date': getDailyDocumentId(date),
        'timestamp': Timestamp.fromDate(date),
        'items': [], // Initialize with empty items array
      });

      // Also ensure monthly index exists
      await _ensureJobListMonthlyIndexExists(date);
    } else {
      // Ensure items field exists for existing documents
      final data = docSnapshot.data() as Map<String, dynamic>?;
      if (data != null && !data.containsKey('items')) {
        await doc.update({'items': []});
      }
    }
  }

  /// Ensure daily document exists for collection schedules (creates if not present)
  Future<void> ensureCollectionScheduleDailyDocExists(DateTime date) async {
    final doc = getCollectionScheduleDailyDoc(date);
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'date': getDailyDocumentId(date),
        'timestamp': Timestamp.fromDate(date),
        'collectionJobs': [], // Initialize with empty collection jobs array
      });

      // Also ensure monthly index exists
      await _ensureCollectionScheduleMonthlyIndexExists(date);
    } else {
      // Ensure collectionJobs field exists for existing documents
      final data = docSnapshot.data() as Map<String, dynamic>?;
      if (data != null && !data.containsKey('collectionJobs')) {
        await doc.update({'collectionJobs': []});
      }
    }
  }

  // PRIVATE MONTHLY INDEX MANAGEMENT

  /// Ensure monthly index document exists for schedules
  Future<void> _ensureScheduleMonthlyIndexExists(DateTime date) async {
    final doc = getScheduleMonthlyIndexDoc(date);
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      final monthRange = getMonthDateRange(getMonthlyDocumentId(date));
      final daysInMonth = DateTime(date.year, date.month + 1, 0).day;

      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'month': getMonthlyDocumentId(date),
        'year': date.year,
        'monthNumber': date.month,
        'daysInMonth': daysInMonth,
        'startDate': Timestamp.fromDate(monthRange.start),
        'endDate': Timestamp.fromDate(monthRange.end),
      });
    }
  }

  /// Ensure monthly index document exists for job lists
  Future<void> _ensureJobListMonthlyIndexExists(DateTime date) async {
    final doc = getJobListMonthlyIndexDoc(date);
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      final monthRange = getMonthDateRange(getMonthlyDocumentId(date));
      final daysInMonth = DateTime(date.year, date.month + 1, 0).day;

      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'month': getMonthlyDocumentId(date),
        'year': date.year,
        'monthNumber': date.month,
        'daysInMonth': daysInMonth,
        'startDate': Timestamp.fromDate(monthRange.start),
        'endDate': Timestamp.fromDate(monthRange.end),
      });
    }
  }

  /// Ensure monthly index document exists for collection schedules
  Future<void> _ensureCollectionScheduleMonthlyIndexExists(
      DateTime date) async {
    final doc = getCollectionScheduleMonthlyIndexDoc(date);
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      final monthRange = getMonthDateRange(getMonthlyDocumentId(date));
      final daysInMonth = DateTime(date.year, date.month + 1, 0).day;

      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'month': getMonthlyDocumentId(date),
        'year': date.year,
        'monthNumber': date.month,
        'daysInMonth': daysInMonth,
        'startDate': Timestamp.fromDate(monthRange.start),
        'endDate': Timestamp.fromDate(monthRange.end),
      });
    }
  }

  // UTILITY METHODS

  /// Get all available daily documents for schedules in a specific month
  Future<List<String>> getAvailableScheduleDaysInMonth(DateTime month) async {
    final snapshot = await getScheduleMonthlyCollection(month).get();
    return snapshot.docs.map((doc) => doc.id).toList()
      ..sort(); // Sort chronologically
  }

  /// Get all available monthly documents for schedules
  Future<List<String>> getAvailableScheduleMonths() async {
    final snapshot = await _firestore.collection('schedules').get();
    return snapshot.docs
        .where((doc) => doc.id.contains(' ')) // Filter out non-monthly docs
        .map((doc) => doc.id)
        .toList()
      ..sort((a, b) =>
          _parseMonthYear(b).compareTo(_parseMonthYear(a))); // Latest first
  }

  /// Get all available daily documents for job lists in a specific month
  Future<List<String>> getAvailableJobListDaysInMonth(DateTime month) async {
    final snapshot = await getJobListMonthlyCollection(month).get();
    return snapshot.docs.map((doc) => doc.id).toList()
      ..sort(); // Sort chronologically
  }

  /// Get all available monthly documents for job lists
  Future<List<String>> getAvailableJobListMonths() async {
    final snapshot = await _firestore.collection('jobLists').get();
    return snapshot.docs
        .where((doc) => doc.id.contains(' ')) // Filter out non-monthly docs
        .map((doc) => doc.id)
        .toList()
      ..sort((a, b) =>
          _parseMonthYear(b).compareTo(_parseMonthYear(a))); // Latest first
  }

  /// Get all available daily documents for collection schedules in a specific month
  Future<List<String>> getAvailableCollectionScheduleDaysInMonth(
      DateTime month) async {
    final snapshot = await getCollectionScheduleMonthlyCollection(month).get();
    return snapshot.docs.map((doc) => doc.id).toList()
      ..sort(); // Sort chronologically
  }

  /// Get all available monthly documents for collection schedules
  Future<List<String>> getAvailableCollectionScheduleMonths() async {
    final snapshot = await _firestore.collection('collectionSchedules').get();
    return snapshot.docs
        .where((doc) => doc.id.contains(' ')) // Filter out non-monthly docs
        .map((doc) => doc.id)
        .toList()
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

  /// Parse daily document ID back to DateTime
  DateTime parseDailyDocumentId(String dailyId) {
    final parts = dailyId.split('-');
    if (parts.length != 3) return DateTime.now();

    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final month = int.tryParse(parts[1]) ?? DateTime.now().month;
    final day = int.tryParse(parts[2]) ?? DateTime.now().day;

    return DateTime(year, month, day);
  }

  /// Get date range for a monthly document
  DateTimeRange getMonthDateRange(String monthlyDocId) {
    final date = _parseMonthYear(monthlyDocId);
    final start = DateTime(date.year, date.month, 1);
    final end = DateTime(date.year, date.month + 1, 0, 23, 59, 59, 999);

    return DateTimeRange(start: start, end: end);
  }

  /// Get all dates in a month as a list
  List<DateTime> getAllDatesInMonth(DateTime month) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    return List.generate(
        daysInMonth, (index) => DateTime(month.year, month.month, index + 1));
  }

  /// Get date range between two dates (inclusive)
  List<DateTime> getDateRange(DateTime start, DateTime end) {
    final dates = <DateTime>[];
    var current = DateTime(start.year, start.month, start.day);
    final endDate = DateTime(end.year, end.month, end.day);

    while (current.isBefore(endDate) || current.isAtSameMomentAs(endDate)) {
      dates.add(current);
      current = current.add(const Duration(days: 1));
    }

    return dates;
  }
}

/// Date range class for convenience
class DateTimeRange {
  final DateTime start;
  final DateTime end;

  DateTimeRange({required this.start, required this.end});

  bool contains(DateTime date) {
    return date.isAfter(start.subtract(const Duration(days: 1))) &&
        date.isBefore(end.add(const Duration(days: 1)));
  }

  List<DateTime> get allDates {
    final dates = <DateTime>[];
    var current = DateTime(start.year, start.month, start.day);
    final endDate = DateTime(end.year, end.month, end.day);

    while (current.isBefore(endDate) || current.isAtSameMomentAs(endDate)) {
      dates.add(current);
      current = current.add(const Duration(days: 1));
    }

    return dates;
  }
}
