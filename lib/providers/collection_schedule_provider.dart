import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/collection_job.dart';
import '../models/job_list_item.dart';
import '../models/work_area.dart';
import '../utils/schedule_time.dart';
import '../services/firestore_service.dart';
import '../services/job_list_service.dart';
import 'job_type_provider.dart';

final collectionScheduleRiverpod =
    riverpod.ChangeNotifierProvider<CollectionScheduleProvider>(
  (ref) => CollectionScheduleProvider(
    jobListService: ref.read(jobListServiceRiverpod),
  ),
);

class CollectionScheduleProvider extends ChangeNotifier {
  final FirestoreService _firestoreService;
  final JobListService _jobListService;

  // Own independent stream — does not share month state with JobListProvider
  List<JobListItem> _ownJobListItems = [];
  StreamSubscription<List<JobListItem>>? _ownJobListSubscription;

  List<CollectionJob> _collectionJobs = [];
  List<WorkArea> _workAreas = [];
  DateTime _currentMonth = scheduleNow();
  bool _isInitialized = false;
  bool _isLoading = false;

  // Cached monthly view
  List<CollectionJob>? _cachedMonthJobs;
  int? _cachedMonthKey; // year*100+month

  // Fingerprint of last job list data to skip redundant rebuilds
  int _lastJobListFingerprint = 0;

  // True between setCurrentMonth() and the first stream delivery for the new month.
  // Drives the loading overlay so the user sees a spinner instead of a blank grid.
  bool _isMonthChanging = false;

  // Cache for time slot occupation checks to avoid expensive filtering during UI renders
  // Key: "vehicleType_yyyy-MM-dd_timeSlot", Value: List of jobs occupying that slot
  final Map<String, List<CollectionJob>> _timeSlotCache = {};

  // Getters
  List<CollectionJob> get collectionJobs => _collectionJobs;
  List<CollectionJob> get currentMonthCollectionJobs {
    final key = _currentMonth.year * 100 + _currentMonth.month;
    if (_cachedMonthJobs != null && _cachedMonthKey == key) {
      return _cachedMonthJobs!;
    }
    _cachedMonthJobs = _getJobsForMonth(_currentMonth);
    _cachedMonthKey = key;
    return _cachedMonthJobs!;
  }

  List<WorkArea> get workAreas => _workAreas;
  DateTime get currentMonth => _currentMonth;
  String get currentMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(_currentMonth);
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading || _isMonthChanging;

  CollectionScheduleProvider({
    FirestoreService? firestoreService,
    required JobListService jobListService,
  })  : _firestoreService = firestoreService ?? FirestoreService(),
        _jobListService = jobListService;

  /// Called whenever the own Firestore stream delivers new job list data.
  /// Applies a fingerprint check to skip rebuilds when nothing relevant changed.
  void _onOwnStreamData(List<JobListItem> items) {
    // Always clear the month-change loading flag on the first delivery for a
    // new month, even if the fingerprint matches (e.g. empty month).
    final wasMonthChanging = _isMonthChanging;
    _isMonthChanging = false;
    final jobTypeProvider = JobTypeProvider.instance;
    int fp = items.length;
    for (final item in items) {
      if (jobTypeProvider?.appearsOnCollectionSchedule(item.jobTypeId) ??
          false) {
        fp = fp * 31 +
            item.id.hashCode +
            item.date.millisecondsSinceEpoch +
            item.collectionDate.millisecondsSinceEpoch +
            item.quantity +
            item.quantityDistributed +
            item.manDays.hashCode +
            item.jobStatusId.hashCode +
            item.vehicleTrailerCombo.hashCode +
            item.collectionAddress.hashCode +
            item.area.hashCode +
            item.offloadingAddress.hashCode +
            item.client.hashCode +
            item.specialInstructions.hashCode +
            // Schedule-owned fields must participate, otherwise editing a job
            // from the Collection Schedule leaves the fingerprint unchanged
            // and the rebuild is skipped.
            item.timeSlot.hashCode +
            item.timeSlots +
            item.staffCount +
            Object.hashAll(item.assignedStaff);
      }
    }
    if (fp == _lastJobListFingerprint) {
      if (wasMonthChanging) notifyListeners(); // dismiss the loading overlay
      return;
    }
    _lastJobListFingerprint = fp;

    _ownJobListItems = items;
    _buildCollectionJobs();
    _rebuildTimeSlotCache();
    _invalidateMonthCache();
    notifyListeners();
  }

  /// Cancel any existing subscription and open a new stream for [_currentMonth].
  /// This is independent of JobListProvider — navigating months here does not
  /// affect the Job List tab and vice versa.
  Future<void> _setupOwnStream() async {
    await _ownJobListSubscription?.cancel();
    _ownJobListSubscription = _jobListService
        .getJobListItems(_currentMonth)
        .listen(_onOwnStreamData, onError: (e) {
      debugPrint('CollectionScheduleProvider: Stream error: $e');
    });
  }

  void _invalidateMonthCache() {
    _cachedMonthJobs = null;
    _cachedMonthKey = null;
  }

  // Manual initialization - call this when the tab is opened
  Future<void> initialize() async {
    if (_isInitialized) return;

    _isLoading = true;
    notifyListeners();

    try {
      // Mark initialized before any awaits so _onOwnStreamData() is never
      // dropped while work areas are loading.
      _isInitialized = true;

      // Open own Firestore stream for the current month.
      await _setupOwnStream();

      notifyListeners(); // surface whatever the cache delivers immediately

      await _loadWorkAreas();

      // Rebuild after work areas arrive (they can affect display).
      _buildCollectionJobs();
      _rebuildTimeSlotCache();
      _invalidateMonthCache();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Rebuild collection data after a month change (the stream is already restarted)
  void _loadDataForMonth() {
    _buildCollectionJobs();
    _rebuildTimeSlotCache();
    _invalidateMonthCache();
    notifyListeners();
  }

  // Build collection jobs from the own stream data
  void _buildCollectionJobs() {
    final jobListItems = _ownJobListItems;
    final jobTypeProvider = JobTypeProvider.instance;
    _collectionJobs = jobListItems
        .where((job) =>
            jobTypeProvider?.appearsOnCollectionSchedule(job.jobTypeId) ??
            false)
        .map((job) => _jobListItemToCollectionJob(job))
        .toList();
  }

  // Pre-compute which jobs occupy which time slots — synchronous, fast
  void _rebuildTimeSlotCache() {
    _timeSlotCache.clear();

    for (final job in _collectionJobs) {
      final availableTimeSlots = CollectionJob.availableTimeSlots;
      final jobStartIndex = availableTimeSlots.indexOf(job.timeSlot);

      if (jobStartIndex == -1) continue;

      for (int j = 0; j < job.timeSlots; j++) {
        final slotIndex = jobStartIndex + j;
        if (slotIndex >= availableTimeSlots.length) break;

        final timeSlot = availableTimeSlots[slotIndex];
        final dateStr =
            '${job.date.year}-${job.date.month.toString().padLeft(2, '0')}-${job.date.day.toString().padLeft(2, '0')}';
        final cacheKey = '${job.vehicleType.name}_${dateStr}_$timeSlot';

        _timeSlotCache.putIfAbsent(cacheKey, () => []).add(job);
      }
    }
  }

  // Load work areas (one-time fetch, cache-first to avoid billed reads)
  Future<void> _loadWorkAreas() async {
    try {
      _workAreas = await _firestoreService.fetchWorkAreasOnce();
    } catch (e) {
      debugPrint('CollectionScheduleProvider: Error loading work areas: $e');
    }
  }

  // Refresh data manually when needed
  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();

    try {
      _loadDataForMonth();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Convert JobListItem to CollectionJob
  CollectionJob _jobListItemToCollectionJob(JobListItem jobListItem) {
    // Parse vehicle/trailer from new enum field, with legacy fallback
    final combo =
        VehicleTrailerCombo.tryParse(jobListItem.vehicleTrailerCombo) ??
            VehicleTrailerCombo.fromLegacyQuantity(jobListItem.quantity,
                jobTypeId: jobListItem.jobTypeId);

    // Duration, start time and staffing now have dedicated fields on
    // JobListItem. The resolved* getters fall back to the legacy derivations
    // (quantityDistributed / date's time component / manDays.ceil()) so
    // records written before those fields existed still render identically.
    final timeSlots = jobListItem.resolvedTimeSlots;
    final timeSlot = jobListItem.resolvedTimeSlot;

    // Use collectionDate if it has a meaningful time, otherwise fall back to the main date
    final effectiveDate = (jobListItem.collectionDate.year != 2000 &&
            jobListItem.collectionDate.month != 1 &&
            jobListItem.collectionDate.day != 1)
        ? jobListItem.collectionDate
        : jobListItem.date;

    return CollectionJob(
      id: jobListItem.id,
      location: jobListItem.collectionAddress.isNotEmpty
          ? jobListItem.collectionAddress
          : jobListItem.area,
      vehicleType: combo?.vehicleType ?? VehicleType.hyundai,
      trailerType: combo?.trailerType ?? TrailerType.noTrailer,
      date: effectiveDate,
      timeSlot: timeSlot,
      timeSlots: timeSlots,
      assignedStaff: jobListItem.assignedStaff,
      staffCount: jobListItem.resolvedStaffCount,
      jobType: jobListItem.jobTypeId,
      statusId: jobListItem.jobStatusId,
      clients: [jobListItem.client],
      notes: jobListItem.specialInstructions,
      jobListItemId: jobListItem.id,
      offloadLocation: jobListItem.offloadingAddress,
    );
  }

  // Helper method to get jobs for a specific month
  List<CollectionJob> _getJobsForMonth(DateTime month) {
    return _collectionJobs
        .where((job) =>
            job.date.year == month.year && job.date.month == month.month)
        .toList();
  }

  // Helper method to check if the next month has any jobs
  bool hasJobsInNextMonth(DateTime currentMonth) {
    final nextMonth = DateTime(currentMonth.year, currentMonth.month + 1, 1);
    return _getJobsForMonth(nextMonth).isNotEmpty;
  }

  // Month navigation methods
  Future<void> setCurrentMonth(DateTime month) async {
    if (_currentMonth.year == month.year &&
        _currentMonth.month == month.month) {
      return;
    }

    _currentMonth = month;
    _isMonthChanging = true; // Show loading overlay until stream delivers data
    _invalidateMonthCache();

    // Reset state for the new month so stale data is not shown.
    _lastJobListFingerprint = 0;
    _ownJobListItems = [];

    // Restart the stream for the new month. This is fully independent of
    // JobListProvider — the Job List tab keeps its own month unchanged.
    await _setupOwnStream();

    _loadDataForMonth();
  }

  void goToNextMonth() {
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    setCurrentMonth(nextMonth);
  }

  void goToPreviousMonth() {
    final previousMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    setCurrentMonth(previousMonth);
  }

  void goToCurrentMonth() {
    setCurrentMonth(scheduleNow());
  }

  void goToMonth(String monthString) {
    final DateTime? month = _parseMonthString(monthString);
    if (month != null) {
      setCurrentMonth(month);
    }
  }

  // Helper method to parse month string back to DateTime
  DateTime? _parseMonthString(String monthString) {
    final parts = monthString.split(' ');
    if (parts.length != 2) return null;

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

    final monthNum = months[parts[0]];
    final year = int.tryParse(parts[1]);

    if (monthNum != null && year != null) {
      return DateTime(year, monthNum);
    }
    return null;
  }

  // Get available months
  Future<List<String>> getAvailableMonths() {
    return _firestoreService.getAvailableCollectionScheduleMonths();
  }

  // COLLECTION JOB OPERATIONS
  //
  // A CollectionJob is a derived view of a JobListItem — there is no separate
  // collection-job document. Every write here therefore patches the underlying
  // JobListItem, which is what keeps the job visible on the Job List: it is
  // the same record, not a copy.

  /// Apply the schedule-owned fields of [job] onto [base], leaving every
  /// Job List field (invoice, amount, VAT, reminders, polygons, …) untouched.
  JobListItem _applyToJobListItem(JobListItem base, CollectionJob job) {
    final combo = VehicleTrailerCombo.fromParts(job.vehicleType, job.trailerType);

    // `timeSlot` is authoritative, but the projection still reads
    // `collectionDate` for the date, so keep its time component in sync.
    final parts = job.timeSlot.split(':');
    final hour = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 8;
    final minute = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
    final collectionDateTime = DateTime(
      job.date.year,
      job.date.month,
      job.date.day,
      hour,
      minute,
    );

    return base.copyWith(
      collectionAddress: job.location,
      offloadingAddress: job.offloadLocation,
      collectionDate: collectionDateTime,
      timeSlot: job.timeSlot,
      timeSlots: job.timeSlots,
      assignedStaff: job.assignedStaff,
      staffCount: job.staffCount,
      specialInstructions: job.notes,
      jobStatusId: job.statusId,
      vehicleTrailerCombo: combo?.name ?? base.vehicleTrailerCombo,
    );
  }

  /// Create a new collection job. Writes a JobListItem, so the job appears on
  /// both the Collection Schedule and the Job List.
  ///
  /// [jobTypeId] must be a type flagged as appearing on the Collection
  /// Schedule, otherwise the new job will not render in the grid.
  Future<String> addCollectionJob(
    CollectionJob job, {
    required String jobTypeId,
    String client = '',
    String invoice = '',
    double amount = 0.0,
  }) async {
    try {
      final base = JobListItem(
        id: '', // assigned by Firestore
        invoice: invoice,
        amount: amount,
        client: client,
        jobStatusId: job.statusId,
        jobTypeId: jobTypeId,
        area: job.location,
        quantity: 0,
        manDays: 0.0,
        date: job.date,
        collectionAddress: job.location,
        collectionDate: job.date,
        specialInstructions: job.notes,
        quantityDistributed: 0,
        invoiceDetails: '',
        reportAddresses: '',
        whoToInvoice: '',
        amountExclVat: amount,
      );

      final id = await _jobListService.addJobListItem(
        _applyToJobListItem(base, job),
        job.date,
      );
      debugPrint('Added collection job as job list item $id');
      return id;
    } catch (e) {
      debugPrint('Error adding collection job: $e');
      rethrow;
    }
  }

  /// Persist a schedule-side edit back to the underlying JobListItem.
  Future<void> updateCollectionJob(CollectionJob job) async {
    try {
      final base = _ownJobListItems.where((i) => i.id == job.id).firstOrNull ??
          await _jobListService.getJobListItemById(job.id, job.date);
      if (base == null) {
        throw StateError(
            'No job list item backing collection job ${job.id} — cannot update.');
      }

      await _jobListService.updateJobListItem(
        _applyToJobListItem(base, job),
        base.date,
      );
      debugPrint('Updated collection job ${job.id}');
    } catch (e) {
      debugPrint('Error updating collection job: $e');
      rethrow;
    }
  }

  /// Delete the collection job. Because the schedule and the Job List share one
  /// record, this removes the job from **both** — there is no schedule-only
  /// copy to drop.
  Future<void> deleteCollectionJob(String jobId) async {
    try {
      final base = _ownJobListItems.where((i) => i.id == jobId).firstOrNull;
      final jobDate = base?.date ??
          collectionJobs.where((j) => j.id == jobId).firstOrNull?.date ??
          _currentMonth;
      await _jobListService.deleteJobListItem(jobId, jobDate);
      debugPrint('Successfully deleted collection job $jobId');
    } catch (e) {
      debugPrint('Error deleting collection job: $e');
      rethrow;
    }
  }

  /// Record the Zoho invoice raised for a collection job on its backing
  /// JobListItem. Leaves the Job List's own `invoice` number and
  /// `invoiceStatusId` alone — those are yours, not Zoho's.
  Future<void> linkZohoInvoice({
    required String jobId,
    required String contactId,
    required String invoiceId,
    required String invoiceNumber,
    required String status,
  }) async {
    final base = _ownJobListItems.where((i) => i.id == jobId).firstOrNull ??
        await _jobListService.getJobListItemById(jobId, _currentMonth);
    if (base == null) {
      throw StateError('No job list item $jobId — cannot link Zoho invoice.');
    }

    await _jobListService.updateJobListItem(
      base.copyWith(
        zohoContactId: contactId,
        zohoInvoiceId: invoiceId,
        zohoInvoiceNumber: invoiceNumber,
        zohoInvoiceStatus: status,
        zohoSyncedAt: DateTime.now(),
      ),
      base.date,
    );
  }

  /// The JobListItem backing a collection job, for callers that need the
  /// commercial fields (amount, client, Zoho links) the grid does not carry.
  JobListItem? jobListItemFor(String jobId) =>
      _ownJobListItems.where((i) => i.id == jobId).firstOrNull;

  CollectionJob? getCollectionJobById(String jobId) {
    try {
      return collectionJobs.where((job) => job.id == jobId).firstOrNull;
    } catch (e) {
      debugPrint('Error finding collection job by ID $jobId: $e');
      return null;
    }
  }

  // Helper methods for filtering jobs

  List<CollectionJob> getJobsForVehicleAndDate(
      VehicleType vehicleType, DateTime date) {
    return collectionJobs
        .where((job) =>
            job.vehicleType == vehicleType &&
            job.date.year == date.year &&
            job.date.month == date.month &&
            job.date.day == date.day)
        .toList();
  }

  List<CollectionJob> getJobsForVehicleAndTimeSlot(
      VehicleType vehicleType, DateTime date, String timeSlot) {
    // Use pre-computed cache for instant lookup instead of filtering
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final cacheKey = '${vehicleType.name}_${dateStr}_$timeSlot';

    return _timeSlotCache[cacheKey] ?? [];
  }

  // Helper method to check if a job occupies a specific time slot
  bool _jobOccupiesTimeSlot(CollectionJob job, String timeSlot) {
    final availableTimeSlots = CollectionJob.availableTimeSlots;
    final jobStartIndex = availableTimeSlots.indexOf(job.timeSlot);
    final checkIndex = availableTimeSlots.indexOf(timeSlot);

    if (jobStartIndex == -1 || checkIndex == -1) {
      return job.timeSlot == timeSlot; // Fallback to exact match
    }

    // Check if the timeSlot falls within the job's duration
    final isOccupied = checkIndex >= jobStartIndex &&
        checkIndex < (jobStartIndex + job.timeSlots);

    return isOccupied;
  }

  List<CollectionJob> getJobsForDate(DateTime date) {
    return collectionJobs
        .where((job) =>
            job.date.year == date.year &&
            job.date.month == date.month &&
            job.date.day == date.day)
        .toList();
  }

  List<CollectionJob> getJobsForVehicle(VehicleType vehicleType) {
    return collectionJobs
        .where((job) => job.vehicleType == vehicleType)
        .toList();
  }

  // Check if a specific time slot is available for a vehicle on a date
  bool isTimeSlotAvailable(
      VehicleType vehicleType, DateTime date, String timeSlot) {
    // Use cache for instant lookup
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final cacheKey = '${vehicleType.name}_${dateStr}_$timeSlot';

    return !_timeSlotCache.containsKey(cacheKey) ||
        _timeSlotCache[cacheKey]!.isEmpty;
  }

  // Get all occupied time slots for a vehicle on a specific date
  List<String> getOccupiedTimeSlots(VehicleType vehicleType, DateTime date,
      {String? excludeJobId}) {
    const allTimeSlots = [
      "07:30",
      "08:00",
      "08:30",
      "09:00",
      "09:30",
      "10:00",
      "10:30",
      "11:00",
      "11:30",
      "12:00",
      "12:30",
      "13:00",
      "13:30",
      "14:00",
      "14:30",
      "15:00",
      "15:30",
      "16:00",
      "16:30",
      "17:00",
      "17:30",
      "18:00",
      "18:30",
      "19:00",
      "19:30",
      "20:00"
    ];

    Set<String> occupiedSlots = {};

    for (var job in collectionJobs) {
      // Skip the job being edited if excludeJobId is provided
      if (excludeJobId != null && job.id == excludeJobId) continue;

      if (job.vehicleType == vehicleType &&
          job.date.year == date.year &&
          job.date.month == date.month &&
          job.date.day == date.day) {
        // Add all time slots occupied by this job
        for (var timeSlot in allTimeSlots) {
          if (_jobOccupiesTimeSlot(job, timeSlot)) {
            occupiedSlots.add(timeSlot);
          }
        }
      }
    }

    return occupiedSlots.toList();
  }

  // Check if selecting a time slot with given duration would overlap with existing jobs
  bool wouldOverlapWithExistingJobs(VehicleType vehicleType, DateTime date,
      String startTimeSlot, int duration,
      {String? excludeJobId}) {
    const allTimeSlots = [
      "07:30",
      "08:00",
      "08:30",
      "09:00",
      "09:30",
      "10:00",
      "10:30",
      "11:00",
      "11:30",
      "12:00",
      "12:30",
      "13:00",
      "13:30",
      "14:00",
      "14:30",
      "15:00",
      "15:30",
      "16:00",
      "16:30",
      "17:00",
      "17:30",
      "18:00",
      "18:30",
      "19:00",
      "19:30",
      "20:00"
    ];

    final startIndex = allTimeSlots.indexOf(startTimeSlot);
    if (startIndex == -1) return false;

    // Check if any of the slots this job would occupy are already taken
    for (int i = 0; i < duration; i++) {
      if (startIndex + i >= allTimeSlots.length) break;

      final slotToCheck = allTimeSlots[startIndex + i];
      if (!isTimeSlotAvailable(vehicleType, date, slotToCheck)) {
        // If excludeJobId is provided, check if the conflict is with a different job
        if (excludeJobId != null) {
          final conflictingJobs = collectionJobs.where((job) =>
              job.id != excludeJobId &&
              job.vehicleType == vehicleType &&
              job.date.year == date.year &&
              job.date.month == date.month &&
              job.date.day == date.day &&
              _jobOccupiesTimeSlot(job, slotToCheck));

          if (conflictingJobs.isNotEmpty) return true;
        } else {
          return true;
        }
      }
    }

    return false;
  }

  // Get available time slots for a vehicle on a specific date
  List<String> getAvailableTimeSlots(VehicleType vehicleType, DateTime date) {
    const allTimeSlots = [
      "07:30",
      "08:00",
      "08:30",
      "09:00",
      "09:30",
      "10:00",
      "10:30",
      "11:00",
      "11:30",
      "12:00",
      "12:30",
      "13:00",
      "13:30",
      "14:00",
      "14:30",
      "15:00",
      "15:30",
      "16:00",
      "16:30",
      "17:00",
      "17:30",
      "18:00",
      "18:30",
      "19:00",
      "19:30",
      "20:00"
    ];
    return allTimeSlots
        .where((slot) => isTimeSlotAvailable(vehicleType, date, slot))
        .toList();
  }

  @override
  void dispose() {
    _ownJobListSubscription?.cancel();
    super.dispose();
  }
}
