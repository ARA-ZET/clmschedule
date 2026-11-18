import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../utils/schedule_time.dart';

class DailyService {
  final FirebaseFirestore _firestore;

  // Cache of known-existing document IDs to avoid redundant Firestore reads.
  // Once a doc is confirmed to exist (or created), we skip future checks.
  final Set<String> _knownScheduleDocIds = {};
  final Set<String> _knownJobListDocIds = {};
  final Set<String> _knownCollectionScheduleDocIds = {};

  // Cache for available months lists (avoids full collection reads on every picker open)
  // Static so all DailyService instances share the same cache
  static const _monthsCacheTtl = Duration(minutes: 60);
  static List<String>? _cachedScheduleMonths;
  static List<String>? _cachedJobListMonths;
  static List<String>? _cachedCollectionScheduleMonths;
  static DateTime? _scheduleMonthsCacheTime;
  static DateTime? _jobListMonthsCacheTime;
  static DateTime? _collectionScheduleMonthsCacheTime;

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
    return getMonthlyDocumentId(scheduleNow());
  }

  /// Get daily document ID for current date
  String getCurrentDailyDocumentId() {
    return getDailyDocumentId(scheduleNow());
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
  /// Uses in-memory cache to avoid redundant Firestore reads.
  /// Tries cache first to avoid unnecessary server round-trips.
  Future<void> ensureScheduleDailyDocExists(DateTime date) async {
    final dateKey = getDailyDocumentId(date);

    // Skip if we've already confirmed this doc exists this session
    if (_knownScheduleDocIds.contains(dateKey)) return;

    final doc = getScheduleDailyDoc(date);

    // Try cache first — only trust positive existence (avoids server read)
    try {
      final cached = await doc.get(const GetOptions(source: Source.cache));
      if (cached.exists) {
        _knownScheduleDocIds.add(dateKey);
        return;
      }
    } catch (_) {
      // Cache miss — fall through to server
    }

    // Cache didn't confirm existence — must verify with server
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'date': dateKey,
        'timestamp': Timestamp.fromDate(scheduleCivilToInstant(date)),
        'jobs': [], // Initialize with empty jobs array
      });

      // Also ensure monthly index exists
      await _ensureScheduleMonthlyIndexExists(date);

      // Invalidate months cache since a new month may now exist
      _cachedScheduleMonths = null;
      _scheduleMonthsCacheTime = null;
    } else {
      // Ensure jobs field exists for existing documents
      final data = (docSnapshot.data() == null ? null : Map<String, dynamic>.from(docSnapshot.data() as Map));
      if (data != null && !data.containsKey('jobs')) {
        await doc.update({'jobs': []});
      }
    }

    // Mark as known-existing so future calls skip the read
    _knownScheduleDocIds.add(dateKey);
  }

  /// Ensure daily document exists for job lists (creates if not present)
  /// Uses in-memory cache to avoid redundant Firestore reads.
  /// Tries cache first to avoid unnecessary server round-trips.
  Future<void> ensureJobListDailyDocExists(DateTime date) async {
    final dateKey = getDailyDocumentId(date);

    // Skip if we've already confirmed this doc exists this session
    if (_knownJobListDocIds.contains(dateKey)) return;

    final doc = getJobListDailyDoc(date);

    // Try cache first — only trust positive existence (avoids server read)
    try {
      final cached = await doc.get(const GetOptions(source: Source.cache));
      if (cached.exists) {
        _knownJobListDocIds.add(dateKey);
        return;
      }
    } catch (_) {
      // Cache miss — fall through to server
    }

    // Cache didn't confirm existence — must verify with server
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'date': dateKey,
        'timestamp': Timestamp.fromDate(scheduleCivilToInstant(date)),
        'items': [], // Initialize with empty items array
      });

      // Also ensure monthly index exists
      await _ensureJobListMonthlyIndexExists(date);

      // Invalidate months cache since a new month may now exist
      _cachedJobListMonths = null;
      _jobListMonthsCacheTime = null;
    } else {
      // Ensure items field exists for existing documents
      final data = (docSnapshot.data() == null ? null : Map<String, dynamic>.from(docSnapshot.data() as Map));
      if (data != null && !data.containsKey('items')) {
        await doc.update({'items': []});
      }
    }

    // Mark as known-existing so future calls skip the read
    _knownJobListDocIds.add(dateKey);
  }

  /// Ensure daily document exists for collection schedules (creates if not present)
  /// Uses in-memory cache to avoid redundant Firestore reads.
  /// Tries cache first to avoid unnecessary server round-trips.
  Future<void> ensureCollectionScheduleDailyDocExists(DateTime date) async {
    final dateKey = getDailyDocumentId(date);

    // Skip if we've already confirmed this doc exists this session
    if (_knownCollectionScheduleDocIds.contains(dateKey)) return;

    final doc = getCollectionScheduleDailyDoc(date);

    // Try cache first — only trust positive existence (avoids server read)
    try {
      final cached = await doc.get(const GetOptions(source: Source.cache));
      if (cached.exists) {
        _knownCollectionScheduleDocIds.add(dateKey);
        return;
      }
    } catch (_) {
      // Cache miss — fall through to server
    }

    // Cache didn't confirm existence — must verify with server
    final docSnapshot = await doc.get();

    if (!docSnapshot.exists) {
      await doc.set({
        'created': FieldValue.serverTimestamp(),
        'date': dateKey,
        'timestamp': Timestamp.fromDate(scheduleCivilToInstant(date)),
        'collectionJobs': [], // Initialize with empty collection jobs array
      });

      // Also ensure monthly index exists
      await _ensureCollectionScheduleMonthlyIndexExists(date);

      // Invalidate months cache since a new month may now exist
      _cachedCollectionScheduleMonths = null;
      _collectionScheduleMonthsCacheTime = null;
    } else {
      // Ensure collectionJobs field exists for existing documents
      final data = (docSnapshot.data() == null ? null : Map<String, dynamic>.from(docSnapshot.data() as Map));
      if (data != null && !data.containsKey('collectionJobs')) {
        await doc.update({'collectionJobs': []});
      }
    }

    // Mark as known-existing so future calls skip the read
    _knownCollectionScheduleDocIds.add(dateKey);
  }

  // PRIVATE MONTHLY INDEX MANAGEMENT

  /// Schedule months whose index document is known to exist this session.
  static final Set<String> _knownScheduleMonthIndexes = {};

  /// Makes sure the month index of [date]'s schedule month exists (month
  /// pickers and the next-month probe read it), once per month per session.
  ///
  /// Schedule mutations call this instead of
  /// [ensureScheduleDailyDocExists]: their transaction creates a missing day
  /// document itself, so only the month index needs doing beforehand.
  ///
  /// Never waits on the server. It used to read the index from the server
  /// when the cache could not confirm it, which cost every first schedule
  /// save of a session a round trip and, on a flaky connection, failed with
  /// "client is offline". The index holds only fields derived from the month,
  /// so a merge write of them is safe whether or not it exists; it is queued
  /// offline like any other write, and nothing waits for it.
  Future<void> ensureScheduleMonthIndexExists(DateTime date) async {
    final monthId = getMonthlyDocumentId(date);
    if (_knownScheduleMonthIndexes.contains(monthId)) return;
    _knownScheduleMonthIndexes.add(monthId);
    final doc = getScheduleMonthlyIndexDoc(date);
    try {
      final cached = await doc.get(const GetOptions(source: Source.cache));
      if (cached.exists) return;
    } catch (_) {
      // Not in the cache — write it below.
    }
    final monthRange = getMonthDateRange(monthId);
    unawaited(doc
        .set({
          'month': monthId,
          'year': date.year,
          'monthNumber': date.month,
          'daysInMonth': DateTime(date.year, date.month + 1, 0).day,
          'startDate': Timestamp.fromDate(monthRange.start),
          'endDate': Timestamp.fromDate(monthRange.end),
        }, SetOptions(merge: true))
        .catchError((Object e) {
      _knownScheduleMonthIndexes.remove(monthId);
      debugPrint('DailyService: schedule month index $monthId not saved: $e');
    }));
    _cachedScheduleMonths = null;
    _scheduleMonthsCacheTime = null;
  }

  /// Ensure monthly index document exists for schedules. Returns true when
  /// it had to be created.
  Future<bool> _ensureScheduleMonthlyIndexExists(DateTime date) async {
    final doc = getScheduleMonthlyIndexDoc(date);
    final docSnapshot = await doc.get();

    if (docSnapshot.exists) {
      _knownScheduleMonthIndexes.add(getMonthlyDocumentId(date));
      return false;
    }

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
    _knownScheduleMonthIndexes.add(getMonthlyDocumentId(date));
    return true;
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

  /// Get all available monthly documents for schedules (cached for 60 min)
  Future<List<String>> getAvailableScheduleMonths() async {
    final now = DateTime.now();
    if (_cachedScheduleMonths != null &&
        _scheduleMonthsCacheTime != null &&
        now.difference(_scheduleMonthsCacheTime!) < _monthsCacheTtl) {
      return _cachedScheduleMonths!;
    }

    // Try Firestore cache first to avoid a billed server read
    var snapshot = await _firestore
        .collection('schedules')
        .get(const GetOptions(source: Source.cache));

    // Fall back to server if cache is empty
    if (snapshot.docs.isEmpty) {
      snapshot = await _firestore.collection('schedules').get();
    }

    _cachedScheduleMonths = snapshot.docs
        .where((doc) => doc.id.contains(' ')) // Filter out non-monthly docs
        .map((doc) => doc.id)
        .toList()
      ..sort((a, b) =>
          _parseMonthYear(b).compareTo(_parseMonthYear(a))); // Latest first
    _scheduleMonthsCacheTime = now;
    return _cachedScheduleMonths!;
  }

  /// Get all available daily documents for job lists in a specific month
  Future<List<String>> getAvailableJobListDaysInMonth(DateTime month) async {
    final snapshot = await getJobListMonthlyCollection(month).get();
    return snapshot.docs.map((doc) => doc.id).toList()
      ..sort(); // Sort chronologically
  }

  /// Get all available monthly documents for job lists (cached for 60 min)
  Future<List<String>> getAvailableJobListMonths() async {
    final now = DateTime.now();
    if (_cachedJobListMonths != null &&
        _jobListMonthsCacheTime != null &&
        now.difference(_jobListMonthsCacheTime!) < _monthsCacheTtl) {
      return _cachedJobListMonths!;
    }

    // Try Firestore cache first to avoid a billed server read
    var snapshot = await _firestore
        .collection('jobLists')
        .get(const GetOptions(source: Source.cache));

    // Fall back to server if cache is empty
    if (snapshot.docs.isEmpty) {
      snapshot = await _firestore.collection('jobLists').get();
    }

    _cachedJobListMonths = snapshot.docs
        .where((doc) => doc.id.contains(' ')) // Filter out non-monthly docs
        .map((doc) => doc.id)
        .toList()
      ..sort((a, b) =>
          _parseMonthYear(b).compareTo(_parseMonthYear(a))); // Latest first
    _jobListMonthsCacheTime = now;
    return _cachedJobListMonths!;
  }

  /// Get all available daily documents for collection schedules in a specific month
  Future<List<String>> getAvailableCollectionScheduleDaysInMonth(
      DateTime month) async {
    final snapshot = await getCollectionScheduleMonthlyCollection(month).get();
    return snapshot.docs.map((doc) => doc.id).toList()
      ..sort(); // Sort chronologically
  }

  /// Get all available monthly documents for collection schedules (cached for 60 min)
  Future<List<String>> getAvailableCollectionScheduleMonths() async {
    final now = DateTime.now();
    if (_cachedCollectionScheduleMonths != null &&
        _collectionScheduleMonthsCacheTime != null &&
        now.difference(_collectionScheduleMonthsCacheTime!) < _monthsCacheTtl) {
      return _cachedCollectionScheduleMonths!;
    }

    // Try Firestore cache first to avoid a billed server read
    var snapshot = await _firestore
        .collection('collectionSchedules')
        .get(const GetOptions(source: Source.cache));

    // Fall back to server if cache is empty
    if (snapshot.docs.isEmpty) {
      snapshot = await _firestore.collection('collectionSchedules').get();
    }

    _cachedCollectionScheduleMonths = snapshot.docs
        .where((doc) => doc.id.contains(' ')) // Filter out non-monthly docs
        .map((doc) => doc.id)
        .toList()
      ..sort((a, b) =>
          _parseMonthYear(b).compareTo(_parseMonthYear(a))); // Latest first
    _collectionScheduleMonthsCacheTime = now;
    return _cachedCollectionScheduleMonths!;
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

  /// Clear all doc existence caches (e.g., on user sign-out or for testing)
  void clearDocExistenceCache() {
    _knownScheduleDocIds.clear();
    _knownJobListDocIds.clear();
    _knownCollectionScheduleDocIds.clear();
  }

  /// Invalidate the available months cache so next call re-fetches from Firestore.
  /// Call when a new monthly document is created.
  static void invalidateMonthsCache() {
    _cachedScheduleMonths = null;
    _scheduleMonthsCacheTime = null;
    _cachedJobListMonths = null;
    _jobListMonthsCacheTime = null;
    _cachedCollectionScheduleMonths = null;
    _collectionScheduleMonthsCacheTime = null;
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
