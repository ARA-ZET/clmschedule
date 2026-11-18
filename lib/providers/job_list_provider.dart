import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:clmschedule/utils/schedule_time.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/job_list_item.dart';
import '../utils/distribution_lag.dart';
import '../utils/friendly_error.dart';
import '../utils/job_list_search.dart';
import '../models/job_list_item_update.dart';
import '../models/job_reminder.dart';
import '../services/job_list_service.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import '../shareable_maps/services/map_link_service.dart';
import '../config/flavor_config.dart';
import 'auth_provider.dart';
import 'invoice_status_provider.dart';
import 'job_list_status_provider.dart';
import 'job_type_provider.dart';
import '../services/sync_status.dart';

final jobListRiverpod = riverpod.ChangeNotifierProvider<JobListProvider>(
  (ref) => JobListProvider(
    ref.read(jobListServiceRiverpod),
    ref.read(authRiverpod),
  ),
);

class JobListProvider extends ChangeNotifier {
  final JobListService _jobListService;
  final AuthProvider _authProvider;
  List<JobListItem> _jobListItems = [];
  Set<String> _knownJobIds = {}; // Track known job IDs to detect new additions
  bool _isLoading = false;
  bool _isInitialized = false;

  /// Why the Job List could not be loaded, in plain words (see
  /// [friendlyFirebaseError]); [errorDetail] keeps the raw error.
  String? _error;
  String? _errorDetail;

  /// A save, add, delete or status change that failed. Kept apart from
  /// [_error] so one failed write does not hide the whole list behind
  /// "Error loading Job List".
  String? _actionError;
  String? _actionErrorDetail;

  /// The live listener dropped and is being re-opened (see [_onStreamError]).
  bool _isReconnecting = false;
  int _streamFailures = 0;
  Timer? _reconnectTimer;

  /// Clears [_streamFailures] once a re-opened listener has stayed up for
  /// [_healthyAfter]. Not on its first snapshot: with offline persistence
  /// every re-listen first replays the cache, so resetting there let a
  /// listener the server keeps rejecting retry every 2 s forever.
  Timer? _healthyTimer;
  static const _healthyAfter = Duration(seconds: 60);

  /// Clears the app-wide "live updates paused" banner once a re-opened
  /// listener has delivered and not failed again for a few seconds.
  Timer? _syncUpTimer;
  bool _disposed = false;

  /// Waits before each re-open of a failed listener. Past the last one the
  /// error is shown with a Retry button.
  static const _reconnectDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  String _searchQuery = '';
  Set<String> _statusFilters = {};
  final Set<String> _invoiceStatusFilters = {};
  DateTime _currentMonth = scheduleNow();

  // Date filtering properties
  String _dateFilter = 'all'; // 'all', 'single', 'range'
  DateTime? _startDate;
  DateTime? _endDate;

  // Subscription for job list items stream (current month only)
  StreamSubscription<List<JobListItem>>? _jobListSubscription;

  // Sorting functionality
  String _sortField = 'date'; // Default sort by date
  bool _sortAscending = true; // Default ascending order

  // Debounced batch update system
  Timer? _debounceTimer;
  final Map<String, JobListItem> _pendingUpdates = {};
  final Map<String, DateTime> _updateTimestamps = {};

  /// Edits not yet confirmed saved: queued plus the ones being written right
  /// now (the queue itself empties the moment a save pass starts). Drives
  /// the "Saving…" chip.
  final ValueNotifier<int> unsavedCount = ValueNotifier<int>(0);
  int _inFlightSaves = 0;

  void _syncUnsavedCount() {
    if (_disposed) return;
    unsavedCount.value = _pendingUpdates.length + _inFlightSaves + _pendingAdds;
    // The connection banner and the web leave-page warning cover the Job
    // List too, alongside the schedule and payroll.
    SyncStatus.instance.reportPendingWrites('jobList', unsavedCount.value);
  }
  static const Duration _debounceDelay = Duration(milliseconds: 500);

  // Search debouncing
  Timer? _searchDebounceTimer;
  String _pendingSearchQuery = '';
  final ValueNotifier<bool> _isSearchingNotifier = ValueNotifier<bool>(false);
  // Items are already in memory, so this only waits for a pause in typing
  // before the (heavy) grid rebuild — not for any fetch.
  static const Duration _searchDebounceDelay = Duration(milliseconds: 400);

  // Filter/search UI feedback — when true the grid shows a spinner
  // instead of the table so the heavy rebuild doesn't block the spinner.
  bool _isApplyingFilter = false;

  // Lazy loading state
  bool _hasInitialLoad = false;

  // Last checked time for updates
  DateTime? _lastCheckedTime;
  bool _lastCheckedTimeLoaded = false;
  bool _isRefreshingLastChecked = false;

  // Callback for Happy Sun job syncing
  Function(JobListItem)? _onJobListItemAdded;
  Function(JobListItem oldItem, JobListItem newItem)? _onJobListItemUpdated;
  Function(JobListItem)? _onJobListItemDeleted;

  // Track jobs added locally to prevent duplicate Happy Sun sync from listener
  final Set<String> _locallyAddedJobIds = {};

  JobListProvider(this._jobListService, this._authProvider);

  // Set callbacks for Happy Sun job syncing
  void setHappySunCallbacks({
    Function(JobListItem)? onAdded,
    Function(JobListItem oldItem, JobListItem newItem)? onUpdated,
    Function(JobListItem)? onDeleted,
    Future<DocumentReference<Map<String, dynamic>>?> Function(JobListItem)?
        projectRef,
  }) {
    _onJobListItemAdded = onAdded;
    _onJobListItemUpdated = onUpdated;
    _onJobListItemDeleted = onDeleted;
    _happySunProjectRef = projectRef;
  }

  /// Where a job's Happy Sun project is stored, so deleting the job copies
  /// it into the Recycle Bin too.
  Future<DocumentReference<Map<String, dynamic>>?> Function(JobListItem)?
      _happySunProjectRef;

  // Async initialization method - call explicitly for concurrent loading
  Future<void> initialize() async {
    if (_hasInitialLoad) return;

    // Run initialization tasks concurrently
    await Future.wait([
      _initializeCurrentMonthData(),
      _loadLastCheckedTimeFromDatabase(),
    ]);
  }

  // Reset all state and re-initialize. Use when a previous initialization
  // failed and the user explicitly retries (e.g., error retry button).
  Future<void> resetAndInitialize() async {
    _jobListSubscription?.cancel();
    _jobListSubscription = null;
    _reconnectTimer?.cancel();
    _healthyTimer?.cancel();
    _syncUpTimer?.cancel();
    _syncUpTimer = null;
    SyncStatus.instance.reportListenerUp('jobList');
    _streamFailures = 0;
    _isReconnecting = false;
    _hasInitialLoad = false;
    _isInitialized = false;
    _error = null;
    _errorDetail = null;
    _jobListItems = [];
    _knownJobIds = {};
    _lastCheckedTimeLoaded = false;
    _invalidateItemCaches();
    notifyListeners();
    await initialize();
  }

  // Getters
  List<JobListItem> get jobListItems => _filteredJobListItems();
  List<JobListItem> get allJobListItems => _getMergedJobListItems();
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  bool get isApplyingFilter => _isApplyingFilter;
  String? get error => _error;
  String? get errorDetail => _errorDetail;
  String? get actionError => _actionError;
  String? get actionErrorDetail => _actionErrorDetail;
  bool get isReconnecting => _isReconnecting;
  String get searchQuery => _searchQuery;
  Set<String> get statusFilters => _statusFilters;
  Set<String> get invoiceStatusFilters => _invoiceStatusFilters;
  String get sortField => _sortField;
  bool get sortAscending => _sortAscending;
  DateTime get currentMonth => _currentMonth;
  String get dateFilter => _dateFilter;
  DateTime? get startDate => _startDate;
  DateTime? get endDate => _endDate;
  String get currentMonthDisplay =>
      _jobListService.getMonthlyDocumentId(_currentMonth);
  DateTime? get lastCheckedTime => _lastCheckedTime;
  bool get lastCheckedTimeLoaded => _lastCheckedTimeLoaded;
  bool get isRefreshingLastChecked => _isRefreshingLastChecked;
  ValueNotifier<bool> get isSearchingNotifier => _isSearchingNotifier;

  // Get merged data (database + pending local changes), cached
  List<JobListItem>? _cachedMergedItems;
  bool _mergedItemsDirty = true;

  List<JobListItem> _getMergedJobListItems() {
    if (!_mergedItemsDirty && _cachedMergedItems != null) {
      return _cachedMergedItems!;
    }
    _cachedMergedItems = _pendingUpdates.isEmpty
        ? _jobListItems
        : _jobListItems.map((item) {
            return _pendingUpdates[item.id] ?? item;
          }).toList();
    _mergedItemsDirty = false;
    return _cachedMergedItems!;
  }

  void _invalidateItemCaches() {
    _mergedItemsDirty = true;
    _cachedMergedItems = null;
    _cachedFilteredItems = null;
    _lastFilterHash = '';
  }

  /// Two-phase notify that keeps the UI responsive:
  /// Phase 1: Set _isApplyingFilter = true → notifyListeners().
  ///   The grid skips building the heavy table and shows a spinner instead
  ///   (cheap frame, spinner animates freely).
  /// Phase 2: After a short delay (so spinner paints a few frames),
  ///   set _isApplyingFilter = false → notifyListeners().
  ///   The grid rebuilds with the new filtered data. The user was seeing
  ///   a spinner, so the one heavy frame is not perceived as a freeze.
  void _notifyWithLoadingFeedback() {
    _isApplyingFilter = true;
    _isSearchingNotifier.value = true;
    notifyListeners(); // Phase 1 — lightweight, shows spinner

    // Give the spinner 2-3 frames to paint and animate before heavy rebuild
    Future.delayed(const Duration(milliseconds: 50), () {
      _isApplyingFilter = false;
      _isSearchingNotifier.value = false;
      notifyListeners(); // Phase 2 — grid rebuilds with new data
    });
  }

  // Cached filtered results
  List<JobListItem>? _cachedFilteredItems;
  String _lastFilterHash = ''; // Made mutable to enable caching

  // Get filtered job list items with caching
  List<JobListItem> _filteredJobListItems() {
    // Create hash of current filter state (includes sort for full cache coverage)
    final currentHash =
        '${_searchQuery}_${_statusFilters.join(',')}_${_invoiceStatusFilters.join(',')}_${_dateFilter}_${_startDate?.millisecondsSinceEpoch}_${_endDate?.millisecondsSinceEpoch}_${_sortField}_$_sortAscending';

    // Return cached results if filters haven't changed
    if (_cachedFilteredItems != null && _lastFilterHash == currentHash) {
      return _cachedFilteredItems!;
    }

    final source = _getMergedJobListItems();

    // Pre-compute filter predicates outside the loop
    final bool isHappySun = FlavorConfig.instance.isHappySun;
    final bool hasSearch = _searchQuery.isNotEmpty;
    final JobListSearch? search = hasSearch
        ? JobListSearch(_searchQuery, labels: _searchLabels)
        : null;
    final bool hasStatusFilter = _statusFilters.isNotEmpty;
    final bool hasInvoiceFilter = _invoiceStatusFilters.isNotEmpty;
    final bool hasDateFilter = _dateFilter != 'all' && _startDate != null;
    final bool isSingleDate = _dateFilter == 'single';
    final bool isRangeDate = _dateFilter == 'range' && _endDate != null;
    final DateTime? rangeStart =
        hasDateFilter ? _startDate!.subtract(const Duration(days: 1)) : null;
    final DateTime? rangeEnd = hasDateFilter && isRangeDate
        ? _endDate!.add(const Duration(days: 1))
        : null;

    // Single-pass filter — no intermediate list allocations
    final filtered = source.where((item) {
      // Happy Sun flavor filter
      if (isHappySun &&
          !(JobTypeProvider.instance?.isHappySunService(item.jobTypeId) ??
              false)) {
        return false;
      }

      // Search filter
      if (hasSearch && !search!.matches(item)) {
        return false;
      }

      // Status filter
      if (hasStatusFilter && !_statusFilters.contains(item.jobStatusId)) {
        return false;
      }

      // Invoice status filter
      if (hasInvoiceFilter &&
          !_invoiceStatusFilters.contains(item.invoiceStatusId)) {
        return false;
      }

      // Date filter
      if (hasDateFilter) {
        if (isSingleDate && !_isSameDay(item.date, _startDate!)) {
          return false;
        } else if (isRangeDate &&
            (!item.date.isAfter(rangeStart!) ||
                !item.date.isBefore(rangeEnd!))) {
          return false;
        }
      }

      return true;
    }).toList();

    // Apply sorting
    filtered.sort((a, b) {
      int comparison;

      switch (_sortField) {
        case 'date':
          comparison = a.date.compareTo(b.date);
          break;
        case 'collectionDate':
          comparison = a.collectionDate.compareTo(b.collectionDate);
          break;
        case 'client':
          comparison = a.client.toLowerCase().compareTo(b.client.toLowerCase());
          break;
        case 'invoice':
          comparison =
              a.invoice.toLowerCase().compareTo(b.invoice.toLowerCase());
          break;
        case 'amount':
          comparison = a.amount.compareTo(b.amount);
          break;
        case 'area':
          comparison = a.area.toLowerCase().compareTo(b.area.toLowerCase());
          break;
        case 'quantity':
          comparison = a.quantity.compareTo(b.quantity);
          break;
        case 'manDays':
          comparison = a.manDays.compareTo(b.manDays);
          break;
        default:
          comparison = a.date.compareTo(b.date);
      }

      return _sortAscending ? comparison : -comparison;
    });

    // Update cache after filtering
    _lastFilterHash = currentHash;
    _cachedFilteredItems = filtered;

    return filtered;
  }

  // Initialize current month data with lazy loading
  Future<void> _initializeCurrentMonthData() async {
    if (_hasInitialLoad) return;

    // Don't set loading to true initially - let stream handle it
    // This prevents showing loading indicator if cache has data
    _isInitialized = true;
    _hasInitialLoad = true;

    try {
      // Set up snapshot listener for current month only
      // The listener will handle loading state based on data availability
      await _setupCurrentMonthListener();
    } catch (error) {
      _error = friendlyFirebaseError(error, action: 'load the Job List');
      _errorDetail = error.toString();
      debugPrint('JobListProvider: Initialization error: $error');
      notifyListeners();
    }
  }

  // Trigger Happy Sun sync asynchronously (fire and forget with error logging)
  void _triggerHappySunSync(JobListItem job) {
    _onJobListItemAdded!(job).catchError((error) {
      debugPrint(
          '❌ JobListProvider: Happy Sun sync error for ${job.id}: $error');
    });
  }

  // Set up real-time listener for current month data only
  Future<void> _setupCurrentMonthListener() async {
    // Cancel existing subscription
    _jobListSubscription?.cancel();
    _reconnectTimer?.cancel();

    // For Happy Sun flavor, only listen to Happy Sun-flagged job types.
    List<String>? jobTypesFilter;
    if (FlavorConfig.instance.isHappySun) {
      final ids =
          JobTypeProvider.instance?.happySunServiceTypeIds ?? const <String>[];
      // Firestore whereIn requires a non-empty list — fall back to a
      // sentinel that matches nothing so the query stays valid.
      jobTypesFilter = ids.isEmpty ? ['__none__'] : ids;
    }

    _jobListSubscription =
        _jobListService.getJobListItems(_currentMonth, jobTypesFilter).listen(
      (jobListItems) {
        // Store previous known IDs before updating
        final previousKnownIds = Set<String>.from(_knownJobIds);

        // Update known IDs first
        _knownJobIds = jobListItems.map((job) => job.id).toSet();

        // Detect new window/solar cleaning jobs and trigger Happy Sun sync
        // Only trigger for jobs that were truly just added (not in previous known IDs)
        // Skip jobs that were added locally (already synced)
        if (_onJobListItemAdded != null && previousKnownIds.isNotEmpty) {
          for (final job in jobListItems) {
            if (!previousKnownIds.contains(job.id) &&
                !_locallyAddedJobIds.contains(job.id) &&
                (JobTypeProvider.instance?.isHappySunService(job.jobTypeId) ??
                    false)) {
              // New Happy Sun job detected - trigger sync asynchronously
              debugPrint(
                  '🆕 JobListProvider: New Happy Sun job detected: ${job.id}');
              _triggerHappySunSync(job);
            }
          }
        }

        // Clean up locally added job IDs after processing
        _locallyAddedJobIds.clear();

        _jobListItems = jobListItems;
        _isLoading = false;
        _error = null;
        _errorDetail = null;
        _isReconnecting = false;
        if (_streamFailures > 0) {
          _syncUpTimer ??= Timer(const Duration(seconds: 5), () {
            _syncUpTimer = null;
            SyncStatus.instance.reportListenerUp('jobList');
          });
        }
        if (_streamFailures > 0 && _healthyTimer == null) {
          _healthyTimer = Timer(_healthyAfter, () {
            _healthyTimer = null;
            _streamFailures = 0;
          });
        }
        // Invalidate all caches when new data arrives
        _invalidateItemCaches();
        notifyListeners();
      },
      onError: _onStreamError,
    );
  }

  /// Firestore closes a listener for good after any error, so before this a
  /// single hiccup — a sign-in token being refreshed after the computer
  /// slept, a dropped connection, a rules deploy rolling out — left the Job
  /// List on "permission-denied" until the user pressed Retry. Now the last
  /// good data stays on screen and the listener is re-opened with a fresh
  /// token a few times before the error is shown.
  void _onStreamError(Object error) {
    _healthyTimer?.cancel();
    _healthyTimer = null;
    _syncUpTimer?.cancel();
    _syncUpTimer = null;
    _streamFailures++;
    if (_authProvider.user != null) {
      SyncStatus.instance.reportListenerDown('jobList', 'the Job List');
    }
    _isLoading = false;
    unawaited(_logStreamFailure(error, _streamFailures));

    final user = _authProvider.user;
    final retriesLeft = _streamFailures <= _reconnectDelays.length;
    if (user == null || !isTransientFirebaseError(error) || !retriesLeft) {
      _isReconnecting = false;
      _error = user == null
          ? "You've been signed out. Sign in again to see the Job List."
          : friendlyFirebaseError(error, action: 'load the Job List');
      _errorDetail = error.toString();
      notifyListeners();
      return;
    }

    _isReconnecting = true;
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelays[_streamFailures - 1], () async {
      final code = firebaseErrorCode(error);
      if (code == 'permission-denied' || code == 'unauthenticated') {
        // The rules only ask for a signed-in user, so a denial for one means
        // the request went without a valid token. Fetch a fresh one first.
        try {
          await _authProvider.user?.getIdToken(true);
        } catch (e) {
          debugPrint('JobListProvider: token refresh failed: $e');
        }
      }
      if (_disposed) return;
      await _setupCurrentMonthListener();
    });
  }

  /// Logs what the server will have seen of the sign-in, so the cause of a
  /// denial can be told apart (no user, anonymous, expired token, …).
  Future<void> _logStreamFailure(Object error, int attempt) async {
    final user = _authProvider.user;
    var auth = 'no signed-in user';
    if (user != null) {
      try {
        final token = await user.getIdTokenResult();
        auth = 'uid=${user.uid} provider=${token.signInProvider} '
            'tokenExpires=${token.expirationTime?.toLocal()}';
      } catch (e) {
        auth = 'uid=${user.uid} (token unreadable: $e)';
      }
    }
    debugPrint('JobListProvider: listener failed (#$attempt) on '
        '${_jobListService.getMonthlyDocumentId(_currentMonth)}: $error — $auth');
  }

  /// Records a failed write for the banner above the list. The caller still
  /// gets the error (the write sites rethrow).
  void _setActionError(Object error, String action) {
    _actionError = friendlyFirebaseError(error, action: action);
    _actionErrorDetail = error.toString();
  }

  void clearActionError() {
    if (_actionError == null) return;
    _actionError = null;
    _actionErrorDetail = null;
    notifyListeners();
  }

  // Change current month (optimized)
  Future<void> setCurrentMonth(DateTime month) async {
    if (_currentMonth.year == month.year &&
        _currentMonth.month == month.month) {
      return; // No change needed
    }

    final oldMonth = _currentMonth;
    _currentMonth = month;

    // Clear current data and known IDs when changing months
    _knownJobIds.clear();
    _healthyTimer?.cancel();
    _healthyTimer = null;
    _syncUpTimer?.cancel();
    _syncUpTimer = null;
    SyncStatus.instance.reportListenerUp('jobList');
    _streamFailures = 0;
    _isLoading = true;
    notifyListeners();

    try {
      // Set up listener for new month
      await _setupCurrentMonthListener();
      debugPrint(
          'JobListProvider: Successfully changed from $oldMonth to $month');
    } catch (error) {
      // Revert on error
      _currentMonth = oldMonth;
      _error = friendlyFirebaseError(error,
          action: 'load ${_jobListService.getMonthlyDocumentId(month)}');
      _errorDetail = error.toString();
      debugPrint('JobListProvider: Error changing month: $error');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Go to next month (optimized)
  Future<void> goToNextMonth() async {
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    await setCurrentMonth(nextMonth);
  }

  // Go to previous month (optimized)
  Future<void> goToPreviousMonth() async {
    final previousMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    await setCurrentMonth(previousMonth);
  }

  // Go to current month (optimized)
  Future<void> goToCurrentMonth() async {
    await setCurrentMonth(scheduleNow());
  }

  // Go to specific month by month string (e.g., "Sep 2025") (optimized)
  Future<void> goToMonth(String monthString) async {
    final DateTime? month = _parseMonthString(monthString);
    if (month != null) {
      await setCurrentMonth(month);
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

  // Get available months (cached for better performance)
  Future<List<String>> getAvailableMonths() {
    return _jobListService.getAvailableJobListMonths();
  }

  // Debounced update system - store locally first, batch update to database after delay
  void updateJobListItemLocal(JobListItem jobListItem) {
    // Get the current item to compare
    final currentItem = getJobListItemById(jobListItem.id);

    // Check if there's actually a change
    if (currentItem != null && _areJobItemsEqual(currentItem, jobListItem)) {
      debugPrint(
          'JobListProvider: No changes detected for item ${jobListItem.id}, skipping update');
      return;
    }

    // Debug reminder changes
    if (currentItem != null &&
        !_areRemindersEqual(currentItem.reminders, jobListItem.reminders)) {
      debugPrint(
          'JobListProvider: Reminders changed for item ${jobListItem.id}');
      debugPrint('  Old reminders count: ${currentItem.reminders.length}');
      debugPrint('  New reminders count: ${jobListItem.reminders.length}');
    }

    debugPrint(
        'JobListProvider: Changes detected for item ${jobListItem.id}, processing update');

    // Store the update locally
    _pendingUpdates[jobListItem.id] = jobListItem;
    _updateTimestamps[jobListItem.id] = DateTime.now();
    _syncUnsavedCount();

    // Invalidate caches since merged data changed
    _invalidateItemCaches();

    // If the area field carries a CLM Maps share URL and the job either has
    // no map linked or the area changed, auto-link the matching map.
    final areaChanged =
        currentItem == null || currentItem.area != jobListItem.area;
    final needsLink = jobListItem.shareableMapId.isEmpty || areaChanged;
    if (needsLink && _extractClmMapShareCode(jobListItem.area) != null) {
      unawaited(_autoLinkMapFromArea(
        jobId: jobListItem.id,
        area: jobListItem.area,
        date: jobListItem.date,
      ));
    }

    // Immediately update UI
    notifyListeners();

    // Cancel existing timer if any
    _debounceTimer?.cancel();

    // Start new timer to batch update to database
    _debounceTimer = Timer(_debounceDelay, () {
      _processPendingUpdates();
    });
  }

  // Helper method to compare job items for equality
  bool _areJobItemsEqual(JobListItem item1, JobListItem item2) {
    return item1.id == item2.id &&
        item1.invoice == item2.invoice &&
        item1.amount == item2.amount &&
        item1.client == item2.client &&
        item1.jobStatusId == item2.jobStatusId &&
        item1.invoiceStatusId == item2.invoiceStatusId &&
        item1.jobTypeId == item2.jobTypeId &&
        item1.area == item2.area &&
        item1.quantity == item2.quantity &&
        item1.manDays == item2.manDays &&
        _areDatesEqual(item1.date, item2.date, item1.jobTypeId) &&
        item1.collectionAddress == item2.collectionAddress &&
        _areDatesEqual(
            item1.collectionDate, item2.collectionDate, item1.jobTypeId) &&
        item1.specialInstructions == item2.specialInstructions &&
        item1.quantityDistributed == item2.quantityDistributed &&
        item1.invoiceDetails == item2.invoiceDetails &&
        item1.reportAddresses == item2.reportAddresses &&
        item1.whoToInvoice == item2.whoToInvoice &&
        item1.vehicleTrailerCombo == item2.vehicleTrailerCombo &&
        item1.offloadingAddress == item2.offloadingAddress &&
        item1.priceIsInclVat == item2.priceIsInclVat &&
        item1.amountExclVat == item2.amountExclVat &&
        item1.amountInclVat == item2.amountInclVat &&
        item1.needsFlyerCollection == item2.needsFlyerCollection &&
        item1.contactPerson == item2.contactPerson &&
        item1.contactPhone == item2.contactPhone &&
        item1.timeSlot == item2.timeSlot &&
        item1.timeSlots == item2.timeSlots &&
        _areRemindersEqual(item1.reminders, item2.reminders);
  }

  // Helper method to compare reminders lists
  bool _areRemindersEqual(List<JobReminder> list1, List<JobReminder> list2) {
    if (list1.length != list2.length) return false;

    // Sort by createdAt for consistent comparison
    final sorted1 = List<JobReminder>.from(list1)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final sorted2 = List<JobReminder>.from(list2)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (int i = 0; i < sorted1.length; i++) {
      final r1 = sorted1[i];
      final r2 = sorted2[i];

      // Compare dates by milliseconds to avoid precision issues
      if (r1.dueDate.millisecondsSinceEpoch !=
              r2.dueDate.millisecondsSinceEpoch ||
          r1.notes != r2.notes ||
          r1.status != r2.status ||
          r1.createdAt.millisecondsSinceEpoch !=
              r2.createdAt.millisecondsSinceEpoch ||
          (r1.completedAt?.millisecondsSinceEpoch ?? 0) !=
              (r2.completedAt?.millisecondsSinceEpoch ?? 0)) {
        return false;
      }
    }
    return true;
  }

  // Helper method to compare dates based on job type requirements
  bool _areDatesEqual(DateTime date1, DateTime date2, String jobTypeId) {
    // For job types that need time slots, compare full date-time but ignore milliseconds
    if (_needsTimeDisplay(jobTypeId)) {
      return date1.year == date2.year &&
          date1.month == date2.month &&
          date1.day == date2.day &&
          date1.hour == date2.hour &&
          date1.minute == date2.minute;
    }
    // For other job types, just compare the date
    return _isSameDay(date1, date2);
  }

  // Helper method to check if job type needs time display.
  // Delegates to [JobTypeProvider] so behaviour is flag-driven.
  bool _needsTimeDisplay(String jobTypeId) {
    final provider = JobTypeProvider.instance;
    if (provider == null) return false;
    return provider.needsTimeSlot(jobTypeId);
  }

  /// The save pass in progress, so a debounce or retry timer firing mid-pass
  /// waits for it instead of saving the same jobs twice at once.
  Future<void>? _processingRun;

  /// One shared retry for failed saves (see [_scheduleRetry]).
  Timer? _retryTimer;
  int _retryAttempt = 0;
  static const _retryDelays = [
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 60),
  ];

  // Process all pending updates as batch to database
  Future<void> _processPendingUpdates() async {
    while (_processingRun != null) {
      await _processingRun;
    }
    if (_disposed || _pendingUpdates.isEmpty) return;
    final run = _runPendingUpdates();
    _processingRun = run;
    try {
      await run;
    } finally {
      _processingRun = null;
    }
  }

  /// Retries failed saves after a backoff (10 s → 60 s), one timer for all
  /// of them — each failure used to start its own timer that re-ran the
  /// whole queue.
  void _scheduleRetry() {
    if (_disposed) return;
    final delay =
        _retryDelays[_retryAttempt.clamp(0, _retryDelays.length - 1)];
    _retryAttempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_pendingUpdates.isNotEmpty) _processPendingUpdates();
    });
  }

  void _replaceLocalItem(String id, JobListItem item) {
    final index = _jobListItems.indexWhere((j) => j.id == id);
    if (index >= 0) _jobListItems[index] = item;
  }

  Future<void> _runPendingUpdates() async {
    // Create a copy to work with. Anything added to [_pendingUpdates] while
    // this pass runs is a newer edit and must survive it.
    final updatesToProcess = Map<String, JobListItem>.from(_pendingUpdates);
    _pendingUpdates.clear();
    _updateTimestamps.clear();
    _inFlightSaves = updatesToProcess.length;
    _syncUnsavedCount();

    var anyFailed = false;

    // Process each update
    for (final entry in updatesToProcess.entries) {
      if (_disposed) return;
      try {
        final updatedJob = entry.value;

        // Find the original job to check for month changes
        final originalIndex =
            _jobListItems.indexWhere((item) => item.id == entry.key);
        final originalJob =
            originalIndex >= 0 ? _jobListItems[originalIndex] : null;

        if (originalJob != null) {
          // Check if primary date moved to a different month
          final originalMonth =
              _jobListService.getMonthlyDocumentId(originalJob.date);
          final newMonth =
              _jobListService.getMonthlyDocumentId(updatedJob.date);

          // Determine if we need to move the job based on primary date change
          final needsMove = originalMonth != newMonth;

          if (needsMove) {
            debugPrint(
                'JobListProvider: Job ${updatedJob.client} needs to move from $originalMonth to $newMonth');
            // Use the new move method that handles cross-month updates
            await _jobListService.moveJobListItemToMonth(
                updatedJob, originalJob.date, updatedJob.date);

            // Remove from current month's local cache if it's being moved
            // away. Looked up again by id: a snapshot may have replaced the
            // list while the move was saving.
            if (originalMonth ==
                _jobListService.getMonthlyDocumentId(_currentMonth)) {
              _jobListItems.removeWhere((j) => j.id == entry.key);
            }
          } else {
            // Regular update within the same month
            await _jobListService.updateJobListItem(
                updatedJob, updatedJob.date);

            // Update local cache
            _replaceLocalItem(entry.key, updatedJob);
          }
        } else {
          // Fallback: treat as regular update if original job not found
          await _jobListService.updateJobListItem(updatedJob, updatedJob.date);
        }
      } catch (error) {
        debugPrint(
            'JobListProvider: Error processing update for ${entry.value.client}: $error');

        if (firebaseErrorCode(error) == 'not-found') {
          // Someone else deleted (or moved) the job — the save can never
          // succeed, so stop retrying it and say so.
          _pendingUpdates.remove(entry.key);
          _updateTimestamps.remove(entry.key);
          _invalidateItemCaches();
          _actionError = "'${entry.value.client}' was deleted or moved by "
              "someone else, so your last changes to it weren't saved.";
          _actionErrorDetail = error.toString();
        } else if (!error.toString().contains('RangeError')) {
          // Retry it — unless the user edited the job again meanwhile, in
          // which case their newer edit is already queued and wins.
          if (!_pendingUpdates.containsKey(entry.key)) {
            _pendingUpdates[entry.key] = entry.value;
            _updateTimestamps[entry.key] = DateTime.now();
          }
          anyFailed = true;

          _setActionError(
              error,
              'save your changes to ${entry.value.client} '
              "(we'll keep trying)");
        } else {
          // For RangeErrors, just log and continue - likely the job was moved
          debugPrint(
              'JobListProvider: RangeError for ${entry.value.client}, possibly job was moved to different month');
          // Expected for moved jobs — not worth a banner.
        }
      } finally {
        _inFlightSaves--;
        _syncUnsavedCount();
      }
    }

    if (anyFailed) {
      _scheduleRetry();
    } else {
      _retryAttempt = 0;
    }

    if (!_disposed) notifyListeners();
  }

  /// New jobs saved on this device whose save the server has not yet
  /// confirmed (see [addJobListItemLocal]).
  int _pendingAdds = 0;

  /// Saves a new job **without waiting for the server**, and returns it with
  /// its id straight away.
  ///
  /// The id is made on this device and the Job List shows the job at once
  /// from the local write. Adding a job used to wait for the server to
  /// confirm the save — and, before that, for a read of the month document
  /// that failed outright on a flaky connection ("client is offline").
  /// Firestore keeps the write queued through dropped connections, so
  /// [saved] (the server's confirmation) only fails for a refusal, which is
  /// reported through [actionError]. Until then the job counts in
  /// [unsavedCount], which drives the "Saving…" chip, the connection banner
  /// and the leave-page warning.
  ({JobListItem job, Future<void> saved}) addJobListItemLocal(
      JobListItem jobListItem) {
    final id = _jobListService.newJobListItemId(jobListItem.date);
    final job = jobListItem.copyWith(id: id);

    // Before the write: the listener sees the local write at once, and must
    // not start a second Happy Sun sync for it.
    _locallyAddedJobIds.add(id);
    _pendingAdds++;
    _syncUnsavedCount();

    final saved = () async {
      try {
        await _jobListService.setNewJobListItem(id, job);
      } catch (error) {
        _setActionError(error, 'save the new job "${job.client}"');
        if (!_disposed) notifyListeners();
        rethrow;
      } finally {
        _pendingAdds--;
        _syncUnsavedCount();
      }
    }();
    // Callers may not listen; the failure is already reported above.
    unawaited(saved.then((_) {}, onError: (_) {}));

    // Best-effort: auto-link a CLM Maps share URL pasted into the area field
    // to the matching shareable map.
    unawaited(_autoLinkMapFromArea(jobId: id, area: job.area, date: job.date));

    // A Happy Sun-flagged type gets its project. Not waited for: it needs
    // nothing back, and the user should not sit through it.
    final onAdded = _onJobListItemAdded;
    if (onAdded != null &&
        (JobTypeProvider.instance?.isHappySunService(job.jobTypeId) ??
            false)) {
      debugPrint('🔄 JobListProvider: Triggering Happy Sun sync for $id');
      unawaited(Future.sync(() => onAdded(job)).then((_) {
        debugPrint('✅ JobListProvider: Happy Sun sync completed for $id');
      }, onError: (Object e) {
        debugPrint('⚠️ JobListProvider: Happy Sun sync for $id failed: $e');
      }));
    }

    return (job: job, saved: saved);
  }

  /// Adds a job; see [addJobListItemLocal]. Returns once it is on the Job
  /// List, or — with [waitForServer] — once the server has it (the invoice
  /// saga needs that: its link transaction reads the job from the server).
  Future<JobListItem> addJobListItemAndReturn(JobListItem jobListItem,
      {bool waitForServer = false}) async {
    final added = addJobListItemLocal(jobListItem);
    if (waitForServer) await added.saved;
    return added.job;
  }

  /// Adds a job; see [addJobListItemLocal].
  Future<void> addJobListItem(JobListItem jobListItem) async {
    addJobListItemLocal(jobListItem);
  }

  /// Links an existing shareable map to a job list item.
  ///
  /// Writes only `shareableMapId` and `area` (the share URL) on the job, and
  /// the `jobListItemId` back-reference on the map. The job's folder is left
  /// alone: the job owns its folder, and the `onJobListItemWritten` Cloud
  /// Function points the map at it as soon as `shareableMapId` changes.
  /// Copying the map's folder onto the job instead would hand this job
  /// whatever folder the map happened to have — often another job's — and
  /// the function would then move that folder in under this job's name.
  Future<void> linkExistingMapToJob({
    required String jobId,
    required String mapId,
    required String monthKey,
    required String mapName,

    /// Optional in-memory fallback used when the Firestore stream hasn't yet
    /// delivered the newly-created job (e.g. right after a copy operation).
    JobListItem? fallbackJob,
  }) async {
    try {
      final job = getJobListItemById(jobId) ?? fallbackJob;
      if (job == null) return;

      // Generate/get share link for the area field
      String areaLink = job.area;
      try {
        final linkService =
            MapLinkService(firestore: FirebaseFirestore.instance);
        final shareCode = await linkService.createShareLink(
          monthKey: monthKey,
          mapId: mapId,
          mapName: mapName,
        );
        areaLink = MapLinkService.buildShareUrl(shareCode);
      } catch (e) {
        debugPrint('⚠️ Share link for existing map failed: $e');
      }

      // Update the map's jobListItemId reference. Written before the job so
      // the Cloud Function finds the map by it when the job update lands.
      try {
        final mapService = ShareableMapsFirestoreService(
            firestore: FirebaseFirestore.instance);
        await mapService.updateMapFields(
          monthKey,
          mapId,
          {'jobListItemId': jobId},
        );
        await mapService.releaseJobListItemLink(jobId, keepMapId: mapId);
      } catch (e) {
        debugPrint('⚠️ Failed to update map jobListItemId: $e');
      }

      await _writeMapLink(job, {'shareableMapId': mapId, 'area': areaLink});
    } catch (e) {
      debugPrint('⚠️ Link existing map to job failed: $e');
    }
  }

  /// Persist map-link [fields] on [job] without touching anything else.
  ///
  /// A queued debounced edit for the same job would otherwise land after
  /// this write and put the old `area` back, so it is patched too.
  Future<void> _writeMapLink(
      JobListItem job, Map<String, String> fields) async {
    await _jobListService.updateJobListItemFields(job.id, job.date, fields);
    final pending = _pendingUpdates[job.id];
    if (pending != null) {
      _pendingUpdates[job.id] = pending.copyWith(
        shareableMapId: fields['shareableMapId'],
        area: fields['area'],
      );
    }
    notifyListeners();
  }

  /// Detects a CLM Maps share URL anywhere inside [text] and returns the
  /// share code (e.g. "x7Kp2m") or null if no valid link is present.
  ///
  /// Lives on [MapLinkService] so the distribution report resolves an `area`
  /// value through exactly the same rule this does.
  static String? _extractClmMapShareCode(String? text) =>
      MapLinkService.extractShareCodeFromText(text);

  /// Auto-link a CLM Maps share URL embedded in the job's `area` field to
  /// the corresponding shareable map. No-op if:
  ///   * `area` does not contain a CLM Maps URL,
  ///   * the share code can't be resolved,
  ///   * the job is already linked to that map.
  /// Failures are logged but never thrown.
  Future<void> _autoLinkMapFromArea({
    required String jobId,
    required String area,
    required DateTime date,
  }) async {
    final shareCode = _extractClmMapShareCode(area);
    if (shareCode == null) return;
    if (jobId.isEmpty) return;

    try {
      final linkService = MapLinkService(firestore: FirebaseFirestore.instance);
      final resolved = await linkService.resolveShareCode(shareCode);
      if (resolved == null) {
        debugPrint(
            '🔗 [AutoLink] Share code "$shareCode" did not resolve to any map');
        return;
      }

      // Look up the job's current state. The job may have just been written,
      // so prefer Firestore over the in-memory cache to avoid a race.
      final mapService =
          ShareableMapsFirestoreService(firestore: FirebaseFirestore.instance);
      final mapDoc = await mapService.getMap(resolved.monthKey, resolved.mapId);
      if (mapDoc == null) {
        debugPrint(
            '🔗 [AutoLink] Map ${resolved.monthKey}/${resolved.mapId} no longer exists');
        return;
      }

      final job = getJobListItemById(jobId);
      // Skip if already linked to the same map.
      if (job != null && job.shareableMapId == resolved.mapId) {
        debugPrint(
            '🔗 [AutoLink] Job $jobId already linked to ${resolved.mapId} — skipping');
        return;
      }

      debugPrint(
          '🔗 [AutoLink] Linking job $jobId → map ${resolved.monthKey}/${resolved.mapId} ("${resolved.mapName}")');

      // 1. Mirror the job-list-item id onto the map document.
      try {
        await mapService.updateMapFields(
          resolved.monthKey,
          resolved.mapId,
          {'jobListItemId': jobId},
        );
        await mapService.releaseJobListItemLink(jobId,
            keepMapId: resolved.mapId);
      } catch (e) {
        debugPrint('🔗 [AutoLink] Failed to set jobListItemId on map: $e');
      }

      // 2. Persist the link onto the job — `shareableMapId` only. The job's
      //    folder is the job's own; the Cloud Function points the map at it.
      if (job != null) {
        await _writeMapLink(job, {'shareableMapId': resolved.mapId});
      } else {
        // Job not yet in local cache — this handles the immediately-after-add
        // case, where only the date passed in can locate its month.
        await _jobListService.updateJobListItemFields(
            jobId, date, {'shareableMapId': resolved.mapId});
      }
      debugPrint('✅ [AutoLink] Linked job $jobId → ${resolved.mapId}');
    } catch (e, st) {
      debugPrint('❌ [AutoLink] Failed for job $jobId: $e\n$st');
    }
  }

  // Update job list item (immediate database update - use sparingly)
  Future<void> updateJobListItemImmediate(JobListItem jobListItem) async {
    try {
      // Find the original job to check for month changes
      final originalJob = getJobListItemById(jobListItem.id);

      if (originalJob != null) {
        // Check if primary date moved to a different month
        final originalMonth =
            _jobListService.getMonthlyDocumentId(originalJob.date);
        final newMonth = _jobListService.getMonthlyDocumentId(jobListItem.date);

        if (originalMonth != newMonth) {
          debugPrint(
              'JobListProvider: Immediate update moving job ${jobListItem.client} from $originalMonth to $newMonth');
          // Use the move method for cross-month updates
          await _jobListService.moveJobListItemToMonth(
              jobListItem, originalJob.date, jobListItem.date);
        } else {
          // Regular update within the same month
          await _jobListService.updateJobListItem(
              jobListItem, jobListItem.date);
        }
      } else {
        // Fallback: treat as regular update if original job not found
        await _jobListService.updateJobListItem(jobListItem, jobListItem.date);
      }
    } catch (error) {
      debugPrint(
          'JobListProvider: Error in immediate update for ${jobListItem.client}: $error');

      // Don't rethrow RangeErrors for moved jobs
      if (!error.toString().contains('RangeError')) {
        _setActionError(error, 'save your changes');
        notifyListeners();
        rethrow;
      } else {
        debugPrint(
            'JobListProvider: RangeError in immediate update, possibly job was moved');
        // Expected for moved jobs — nothing to report.
        notifyListeners();
      }
    }
  }

  // Update job list item (debounced - recommended for frequent edits)
  Future<void> updateJobListItem(JobListItem jobListItem) async {
    updateJobListItemLocal(jobListItem);
  }

  // Update job list item with change tracking
  Future<void> updateJobListItemWithTracking(
    JobListItem originalItem,
    JobListItem updatedItem, {
    String? Function(String statusId)? resolveJobStatusLabel,
    String? Function(String statusId)? resolveInvoiceStatusLabel,
    String? Function(int quantity, String jobTypeId)? resolveQuantityLabel,
  }) async {
    final currentUser = _authProvider.user;
    final currentAppUser = _authProvider.appUser;

    if (currentUser == null) {
      throw Exception('User must be authenticated to make changes');
    }

    // Create item with tracked changes, then overlay the VAT fields which
    // copyWithTrackedChange doesn't know about.
    final trackedItem = originalItem
        .copyWithTrackedChange(
          userId: currentUser.uid,
          userDisplayName: currentAppUser?.displayName ??
              currentUser.email ??
              'Unknown User',
          invoice: updatedItem.invoice != originalItem.invoice
              ? updatedItem.invoice
              : null,
          amount: updatedItem.amount != originalItem.amount
              ? updatedItem.amount
              : null,
          client: updatedItem.client != originalItem.client
              ? updatedItem.client
              : null,
          contactPerson:
              updatedItem.contactPerson != originalItem.contactPerson
                  ? updatedItem.contactPerson
                  : null,
          contactPhone: updatedItem.contactPhone != originalItem.contactPhone
              ? updatedItem.contactPhone
              : null,
          jobStatusId: updatedItem.jobStatusId != originalItem.jobStatusId
              ? updatedItem.jobStatusId
              : null,
          invoiceStatusId:
              updatedItem.invoiceStatusId != originalItem.invoiceStatusId
                  ? updatedItem.invoiceStatusId
                  : null,
          jobTypeId: updatedItem.jobTypeId != originalItem.jobTypeId
              ? updatedItem.jobTypeId
              : null,
          area: updatedItem.area != originalItem.area ? updatedItem.area : null,
          quantity: updatedItem.quantity != originalItem.quantity
              ? updatedItem.quantity
              : null,
          manDays: updatedItem.manDays != originalItem.manDays
              ? updatedItem.manDays
              : null,
          date: !_areDatesEqual(
                  updatedItem.date, originalItem.date, updatedItem.jobTypeId)
              ? updatedItem.date
              : null,
          collectionAddress:
              updatedItem.collectionAddress != originalItem.collectionAddress
                  ? updatedItem.collectionAddress
                  : null,
          collectionDate: !_areDatesEqual(updatedItem.collectionDate,
                  originalItem.collectionDate, updatedItem.jobTypeId)
              ? updatedItem.collectionDate
              : null,
          needsFlyerCollection: updatedItem.needsFlyerCollection !=
                  originalItem.needsFlyerCollection
              ? updatedItem.needsFlyerCollection
              : null,
          // The appointment's booked slot (Add/Edit Job, the Date cell).
          // Without these an edited time would revert here, and the
          // Collection Schedule, which reads timeSlot first, never moves.
          timeSlot: updatedItem.timeSlot != originalItem.timeSlot
              ? updatedItem.timeSlot
              : null,
          timeSlots: updatedItem.timeSlots != originalItem.timeSlots
              ? updatedItem.timeSlots
              : null,
          specialInstructions: updatedItem.specialInstructions !=
                  originalItem.specialInstructions
              ? updatedItem.specialInstructions
              : null,
          quantityDistributed: updatedItem.quantityDistributed !=
                  originalItem.quantityDistributed
              ? updatedItem.quantityDistributed
              : null,
          invoiceDetails:
              updatedItem.invoiceDetails != originalItem.invoiceDetails
                  ? updatedItem.invoiceDetails
                  : null,
          reportAddresses:
              updatedItem.reportAddresses != originalItem.reportAddresses
                  ? updatedItem.reportAddresses
                  : null,
          whoToInvoice: updatedItem.whoToInvoice != originalItem.whoToInvoice
              ? updatedItem.whoToInvoice
              : null,
          vehicleTrailerCombo: updatedItem.vehicleTrailerCombo !=
                  originalItem.vehicleTrailerCombo
              ? updatedItem.vehicleTrailerCombo
              : null,
          collectionJobId:
              updatedItem.collectionJobId != originalItem.collectionJobId
                  ? updatedItem.collectionJobId
                  : null,
          reminders:
              !_areRemindersEqual(updatedItem.reminders, originalItem.reminders)
                  ? updatedItem.reminders
                  : null,
          resolveJobStatusLabel: resolveJobStatusLabel,
          resolveInvoiceStatusLabel: resolveInvoiceStatusLabel,
          resolveQuantityLabel: resolveQuantityLabel,
        )
        .copyWith(
          // These fields are not tracked for change history but must always reflect
          // the dialog's edit. copyWithTrackedChange doesn't carry them, so without
          // this overlay they would silently revert to the original values.
          amountExclVat: updatedItem.amountExclVat,
          amountInclVat: updatedItem.amountInclVat,
          priceIsInclVat: updatedItem.priceIsInclVat,
          offloadingAddress: updatedItem.offloadingAddress,
          toolsNeeded: updatedItem.toolsNeeded,
        );

    // Update locally first, then save
    updateJobListItemLocal(trackedItem);

    // Trigger Happy Sun tools update if manDays changed for a Happy Sun-flagged type
    if (_onJobListItemUpdated != null &&
        updatedItem.manDays != originalItem.manDays &&
        (JobTypeProvider.instance?.isHappySunService(updatedItem.jobTypeId) ??
            false)) {
      _onJobListItemUpdated!(originalItem, updatedItem);
    }
  }

  /// Deletes the job into the Recycle Bin — with its invoice indexes and its
  /// Happy Sun project — and returns the bin entry id.
  Future<String?> deleteJobListItem(String id) async {
    try {
      final item = getJobListItemById(id);
      if (item == null) {
        // Not loaded, so nothing to copy from; the month is a best guess.
        await _jobListService.deleteJobListItem(id, _currentMonth);
        return null;
      }

      final projectRef = await _happySunProjectRef?.call(item);
      final entryId = await _jobListService.deleteJobListItemToBin(
        item,
        extraRelated: [if (projectRef != null) projectRef],
      );

      // Happy Sun's own clean-up (offline queue, local list), now that the
      // copy is safe in the bin.
      if (_onJobListItemDeleted != null) {
        await _onJobListItemDeleted!(item);
      }
      return entryId;
    } catch (error) {
      _setActionError(error, 'delete the job');
      notifyListeners();
      rethrow;
    }
  }

  // Update job status (debounced)
  Future<void> updateJobStatus(String id, JobListStatus newStatus) async {
    // Find the job item to update
    JobListItem? currentItem = getJobListItemById(id);
    if (currentItem == null) return;

    // Create updated item with new status
    final updatedItem =
        currentItem.copyWith(jobStatusId: newStatus.customStatusId);

    // Use debounced update
    updateJobListItemLocal(updatedItem);
  }

  // Update job status immediately (use sparingly)
  Future<void> updateJobStatusImmediate(
      String id, JobListStatus newStatus) async {
    try {
      // Find the item to get its date for proper monthly context
      final item = getJobListItemById(id);
      final itemDate = item?.date ?? _currentMonth;
      await _jobListService.updateJobStatus(id, newStatus, itemDate);
    } catch (error) {
      _setActionError(error, 'change the job status');
      notifyListeners();
      rethrow;
    }
  }

  /// Status and job-type names for [JobListSearch], resolved per search so
  /// renamed labels are found by their current name.
  static Iterable<String?> _searchLabels(JobListItem item) => [
        JobListStatusProvider.instance
            ?.getStatusById(item.jobStatusId)
            ?.label,
        InvoiceStatusProvider.instance
            ?.getStatusById(item.invoiceStatusId)
            ?.label,
        JobTypeProvider.instance?.getJobTypeLabel(item.jobTypeId),
      ];

  // Set search query with debouncing
  void setSearchQuery(String query) {
    _pendingSearchQuery = query;

    // Cancel existing timer
    _searchDebounceTimer?.cancel();

    // If query is empty, apply immediately
    if (query.isEmpty) {
      _searchQuery = query;
      _isSearchingNotifier.value = false;
      _invalidateItemCaches();
      notifyListeners();
      return;
    }

    // Show searching indicator without rebuilding entire tree
    _isSearchingNotifier.value = true;

    // Start new timer for debounced search
    _searchDebounceTimer = Timer(_searchDebounceDelay, () {
      _applySearchQuery();
    });
  }

  // Apply the pending search query
  void _applySearchQuery() {
    _searchQuery = _pendingSearchQuery;
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Force apply search immediately (for manual triggers)
  void applySearchNow() {
    _searchDebounceTimer?.cancel();
    if (_pendingSearchQuery.isNotEmpty) {
      _applySearchQuery();
    }
  }

  // Set status filter
  void setStatusFilter(String? statusId) {
    _statusFilters = statusId != null ? {statusId} : {};
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Add status to filter
  void addStatusFilter(String statusId) {
    _statusFilters.add(statusId);
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Remove status from filter
  void removeStatusFilter(String statusId) {
    _statusFilters.remove(statusId);
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Toggle status filter
  void toggleStatusFilter(String statusId) {
    if (_statusFilters.contains(statusId)) {
      _statusFilters.remove(statusId);
    } else {
      _statusFilters.add(statusId);
    }
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Toggle invoice status filter
  void toggleInvoiceStatusFilter(String statusId) {
    if (_invoiceStatusFilters.contains(statusId)) {
      _invoiceStatusFilters.remove(statusId);
    } else {
      _invoiceStatusFilters.add(statusId);
    }
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Clear filters
  void clearFilters() {
    _searchQuery = '';
    _statusFilters.clear();
    _invoiceStatusFilters.clear();
    _dateFilter = 'all';
    _startDate = null;
    _endDate = null;
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Helper method to check if two dates are the same day
  bool _isSameDay(DateTime date1, DateTime date2) {
    return date1.year == date2.year &&
        date1.month == date2.month &&
        date1.day == date2.day;
  }

  // Date filter methods
  void setDateFilter({
    required String filterType, // 'all', 'single', 'range'
    DateTime? startDate,
    DateTime? endDate,
  }) {
    _dateFilter = filterType;
    _startDate = startDate;
    _endDate = endDate;
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  void clearDateFilter() {
    _dateFilter = 'all';
    _startDate = null;
    _endDate = null;
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Simple date filter methods for new UI
  void setSimpleDateFilter(DateTime date) {
    _startDate = date;
    _endDate = null;
    _dateFilter = 'single';
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  void setSimpleDateRangeFilter(DateTime startDate, DateTime endDate) {
    _startDate = startDate;
    _endDate = endDate;
    _dateFilter = 'range';
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Sorting methods
  void setSortField(String field) {
    if (_sortField == field) {
      // If same field, toggle ascending/descending
      _sortAscending = !_sortAscending;
    } else {
      // If new field, set ascending and change field
      _sortField = field;
      _sortAscending = true;
    }
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  void setSorting(String field, bool ascending) {
    _sortField = field;
    _sortAscending = ascending;
    _invalidateItemCaches();
    _notifyWithLoadingFeedback();
  }

  // Get job list item by ID (includes pending updates)
  JobListItem? getJobListItemById(String id) {
    // Check pending updates first
    if (_pendingUpdates.containsKey(id)) {
      return _pendingUpdates[id];
    }

    // Fall back to database version
    try {
      return _jobListItems.firstWhere((item) => item.id == id);
    } catch (e) {
      return null;
    }
  }

  // Get status counts for dashboard (includes pending updates)
  Map<JobListStatus, int> getStatusCounts() {
    final counts = <JobListStatus, int>{};
    final mergedItems = _getMergedJobListItems();

    for (final status in JobListStatus.values) {
      counts[status] =
          mergedItems.where((item) => item.jobStatus == status).length;
    }
    return counts;
  }

  // Clear error
  void clearError() {
    _error = null;
    _errorDetail = null;
    notifyListeners();
  }

  // Get pending updates count (for debugging/UI status)
  int get pendingUpdatesCount => _pendingUpdates.length;

  // Force process pending updates (for testing or manual triggers)
  Future<void> processPendingUpdatesNow() async {
    _debounceTimer?.cancel();
    await _processPendingUpdates();
  }

  // Load last checked time from database
  // Waits briefly for auth to be ready since this runs in parallel with AuthProvider.initialize()
  Future<void> _loadLastCheckedTimeFromDatabase() async {
    try {
      // If user isn't available yet (parallel init race), wait briefly for auth
      var currentUser = _authProvider.user;
      if (currentUser == null) {
        // Wait up to 5 seconds for auth to complete
        for (int i = 0; i < 10; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          currentUser = _authProvider.user;
          if (currentUser != null) break;
        }
        if (currentUser == null) {
          debugPrint(
              'JobListProvider: Auth not ready, skipping last checked time load');
          return;
        }
      }

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();

      if (userDoc.exists) {
        final data = userDoc.data()!;
        if (data.containsKey('lastCheckedTime')) {
          _lastCheckedTime = (data['lastCheckedTime'] as Timestamp).toDate();
        }
      }
      _lastCheckedTimeLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('JobListProvider: Error loading last checked time: $e');
    }
  }

  // Save last checked time to database
  Future<void> _saveLastCheckedTimeToDatabase(DateTime time) async {
    try {
      final currentUser = _authProvider.user;
      if (currentUser == null) return;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .update({
        'lastCheckedTime': Timestamp.fromDate(time),
      });
    } catch (e) {
      // If document doesn't exist, create it
      try {
        final currentUser = _authProvider.user;
        if (currentUser == null) return;

        await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .set({
          'lastCheckedTime': Timestamp.fromDate(time),
        }, SetOptions(merge: true));
      } catch (e2) {
        debugPrint('JobListProvider: Error saving last checked time: $e2');
      }
    }
  }

  // Refresh the last checked time for updates
  // Refresh the last checked time for updates
  Future<void> refreshLastCheckedTime() async {
    _isRefreshingLastChecked = true;
    notifyListeners();

    try {
      final now = DateTime.now();
      _lastCheckedTime = now;
      _lastCheckedTimeLoaded = true;

      // Save to database
      await _saveLastCheckedTimeToDatabase(now);
    } catch (e) {
      debugPrint('JobListProvider: Error refreshing last checked time: $e');
    } finally {
      _isRefreshingLastChecked = false;
      notifyListeners(); // Single notification after all state changes
    }
  }

  // Check if a job has updates after the last checked time
  bool hasUpdatesAfterLastCheck(JobListItem item) {
    if (!_lastCheckedTimeLoaded ||
        _lastCheckedTime == null ||
        item.updates.isEmpty) {
      return false;
    }

    return item.updates
        .any((update) => update.timestamp.isAfter(_lastCheckedTime!));
  }

  // Get updates that occurred after the last checked time
  List<JobListItemUpdate> getUpdatesAfterLastCheck(JobListItem item) {
    if (!_lastCheckedTimeLoaded || _lastCheckedTime == null) {
      return [];
    }

    return item.updates
        .where((update) => update.timestamp.isAfter(_lastCheckedTime!))
        .toList();
  }

  // Ensure lastCheckedTime is loaded (call after auth is guaranteed ready)
  Future<void> ensureLastCheckedTimeLoaded() async {
    if (_lastCheckedTimeLoaded) return;
    await _loadLastCheckedTimeFromDatabase();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _reconnectTimer?.cancel();
    _healthyTimer?.cancel();
    _syncUpTimer?.cancel();
    SyncStatus.instance.reportListenerUp('jobList');
    SyncStatus.instance.reportPendingWrites('jobList', 0);
    _retryTimer?.cancel();
    _jobListSubscription?.cancel();
    _isSearchingNotifier.dispose();
    unsavedCount.dispose();
    super.dispose();
  }

  // ── Duplicate client name check ──────────────────────────────────────────

  /// monthKey → that month's jobs, for months other than the loaded one.
  /// Only what the typing hint reads; a save re-reads with `fresh: true`.
  final Map<String, List<JobListItem>> _monthItemsCache = {};

  /// Jobs in [date]'s month whose client name is [client], compared by
  /// [jobListClientKey] — the key the schedule, maps and Cloud Files pair
  /// on, so two such jobs would be indistinguishable to them.
  ///
  /// • Loaded month → the live in-memory list (0 extra reads).
  /// • Other month → one read of that month, cached for the typing hint.
  ///   [fresh] bypasses the cache: a save must see jobs other people added
  ///   since.
  ///
  /// [excludeId] is the job being edited, which never clashes with itself.
  Future<List<JobListItem>> findJobsWithClientName(
    String client,
    DateTime date, {
    String excludeId = '',
    bool fresh = false,
  }) async {
    final needle = jobListClientKey(client);
    if (needle.isEmpty) return const [];

    final List<JobListItem> items;
    final isLoaded =
        _currentMonth.year == date.year && _currentMonth.month == date.month;
    if (isLoaded) {
      items = allJobListItems;
    } else {
      final key = _jobListService.getMonthlyDocumentId(date);
      final cached = fresh ? null : _monthItemsCache[key];
      if (cached != null) {
        items = cached;
      } else {
        final snapshot =
            await _jobListService.getJobListItemsCollectionForMonth(date).get();
        items = [
          for (final d in snapshot.docs)
            if (d.data() is Map<String, dynamic>)
              JobListItem.fromMap(d.id, d.data() as Map<String, dynamic>),
        ];
        _monthItemsCache[key] = items;
      }
    }

    return [
      for (final item in items)
        if (item.id != excludeId && jobListClientKey(item.client) == needle)
          item,
    ];
  }
}
