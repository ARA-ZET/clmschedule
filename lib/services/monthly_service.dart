import 'package:cloud_firestore/cloud_firestore.dart';

class MonthlyService {
  final FirebaseFirestore _firestore;

  // Cache for available months lists (avoids full collection reads on every picker open)
  // Static so all MonthlyService instances share the same cache
  static const _monthsCacheTtl = Duration(minutes: 60);
  static List<String>? _cachedScheduleMonths;
  static List<String>? _cachedJobListMonths;
  static List<String>? _cachedCollectionScheduleMonths;
  static DateTime? _scheduleMonthsCacheTime;
  static DateTime? _jobListMonthsCacheTime;
  static DateTime? _collectionScheduleMonthsCacheTime;

  // In-memory caches for ensureMonthlyDocExists (avoids redundant .get() reads)
  final Set<String> _knownScheduleMonthIds = {};
  final Set<String> _knownJobListMonthIds = {};
  final Set<String> _knownCollectionScheduleMonthIds = {};

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

  /// Get monthly document reference for collection schedules
  DocumentReference getCollectionScheduleMonthlyDoc(DateTime date) {
    final monthlyId = getMonthlyDocumentId(date);
    return _firestore.collection('collectionSchedules').doc(monthlyId);
  }

  /// Get jobs subcollection reference for a specific month
  /// @deprecated Jobs are now stored as array field in monthly documents
  @Deprecated('Jobs are now stored as array field in monthly documents')
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
  /// Uses in-memory cache to avoid redundant Firestore reads.
  /// Tries cache first to avoid unnecessary server round-trips.
  Future<void> ensureScheduleMonthlyDocExists(DateTime date) async {
    final monthKey = getMonthlyDocumentId(date);
    if (_knownScheduleMonthIds.contains(monthKey)) return;

    final doc = getScheduleMonthlyDoc(date);

    // Try cache first — only trust positive existence (avoids server read)
    try {
      final cached = await doc.get(const GetOptions(source: Source.cache));
      if (cached.exists) {
        _knownScheduleMonthIds.add(monthKey);
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
        'month': monthKey,
        'jobs': [], // Initialize with empty jobs array
      });

      // Invalidate months cache since a new month was created
      _cachedScheduleMonths = null;
      _scheduleMonthsCacheTime = null;
    } else {
      // Ensure jobs field exists for existing documents
      final data = docSnapshot.data() as Map<String, dynamic>?;
      if (data != null && !data.containsKey('jobs')) {
        await doc.update({'jobs': []});
      }
    }

    _knownScheduleMonthIds.add(monthKey);
  }

  /// Ensure job list monthly document exists (creates if not present)
  /// Uses in-memory cache to avoid redundant Firestore reads.
  /// Tries cache first to avoid unnecessary server round-trips.
  Future<void> ensureJobListMonthlyDocExists(DateTime date) async {
    final monthKey = getMonthlyDocumentId(date);
    if (_knownJobListMonthIds.contains(monthKey)) return;

    final doc = getJobListMonthlyDoc(date);

    // Try cache first — only trust positive existence (avoids server read)
    try {
      final cached = await doc.get(const GetOptions(source: Source.cache));
      if (cached.exists) {
        _knownJobListMonthIds.add(monthKey);
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
        'month': monthKey,
      });

      // Invalidate months cache since a new month was created
      _cachedJobListMonths = null;
      _jobListMonthsCacheTime = null;
    }

    _knownJobListMonthIds.add(monthKey);
  }

  /// Ensure collection schedule monthly document exists (creates if not present)
  /// Uses in-memory cache to avoid redundant Firestore reads.
  /// Tries cache first to avoid unnecessary server round-trips.
  Future<void> ensureCollectionScheduleMonthlyDocExists(DateTime date) async {
    final monthKey = getMonthlyDocumentId(date);
    if (_knownCollectionScheduleMonthIds.contains(monthKey)) return;

    final doc = getCollectionScheduleMonthlyDoc(date);

    // Try cache first — only trust positive existence (avoids server read)
    try {
      final cached = await doc.get(const GetOptions(source: Source.cache));
      if (cached.exists) {
        _knownCollectionScheduleMonthIds.add(monthKey);
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
        'month': monthKey,
        'collectionJobs': [], // Initialize with empty collection jobs array
      });

      // Invalidate months cache since a new month was created
      _cachedCollectionScheduleMonths = null;
      _collectionScheduleMonthsCacheTime = null;
    } else {
      // Ensure collectionJobs field exists for existing documents
      final data = docSnapshot.data() as Map<String, dynamic>?;
      if (data != null && !data.containsKey('collectionJobs')) {
        await doc.update({'collectionJobs': []});
      }
    }

    _knownCollectionScheduleMonthIds.add(monthKey);
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

    _cachedScheduleMonths = snapshot.docs.map((doc) => doc.id).toList()
      ..sort((a, b) => _parseMonthYear(b).compareTo(_parseMonthYear(a)));
    _scheduleMonthsCacheTime = now;
    return _cachedScheduleMonths!;
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

    _cachedJobListMonths = snapshot.docs.map((doc) => doc.id).toList()
      ..sort((a, b) => _parseMonthYear(b).compareTo(_parseMonthYear(a)));
    _jobListMonthsCacheTime = now;
    return _cachedJobListMonths!;
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
        .map((doc) => doc.id)
        .toList()
      ..sort((a, b) => _parseMonthYear(b).compareTo(_parseMonthYear(a)));
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

  /// Get date range for a monthly document
  DateTimeRange getMonthDateRange(String monthlyDocId) {
    final date = _parseMonthYear(monthlyDocId);
    final start = DateTime(date.year, date.month, 1);
    final end = DateTime(date.year, date.month + 1, 0, 23, 59, 59, 999);

    return DateTimeRange(start: start, end: end);
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
}

/// Date range class for convenience
class DateTimeRange {
  final DateTime start;
  final DateTime end;

  DateTimeRange({required this.start, required this.end});
}
