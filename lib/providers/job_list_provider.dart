import 'package:flutter/material.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/job_list_item.dart';
import '../models/job_list_item_update.dart';
import '../models/job_reminder.dart';
import '../services/job_list_service.dart';
import 'auth_provider.dart';

class JobListProvider extends ChangeNotifier {
  final JobListService _jobListService;
  final AuthProvider _authProvider;
  List<JobListItem> _jobListItems = [];
  Set<String> _knownJobIds = {}; // Track known job IDs to detect new additions
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;
  String _searchQuery = '';
  Set<String> _statusFilters = {};
  final Set<String> _invoiceStatusFilters = {};
  DateTime _currentMonth = DateTime.now();

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
  static const Duration _debounceDelay = Duration(seconds: 5);

  // Search debouncing
  Timer? _searchDebounceTimer;
  String _pendingSearchQuery = '';
  final ValueNotifier<bool> _isSearchingNotifier = ValueNotifier<bool>(false);
  static const Duration _searchDebounceDelay = Duration(seconds: 2);

  // Lazy loading state
  bool _hasInitialLoad = false;

  // Last checked time for updates
  DateTime? _lastCheckedTime;
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
  }) {
    _onJobListItemAdded = onAdded;
    _onJobListItemUpdated = onUpdated;
    _onJobListItemDeleted = onDeleted;
  }

  // Async initialization method - call explicitly for concurrent loading
  Future<void> initialize() async {
    if (_hasInitialLoad) return;

    // Run initialization tasks concurrently
    await Future.wait([
      _initializeCurrentMonthData(),
      _loadLastCheckedTimeFromDatabase(),
    ]);
  }

  // Getters
  List<JobListItem> get jobListItems => _filteredJobListItems();
  List<JobListItem> get allJobListItems => _getMergedJobListItems();
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get error => _error;
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
  bool get isRefreshingLastChecked => _isRefreshingLastChecked;
  ValueNotifier<bool> get isSearchingNotifier => _isSearchingNotifier;

  // Get merged data (database + pending local changes)
  List<JobListItem> _getMergedJobListItems() {
    return _jobListItems.map((item) {
      // Return pending update if exists, otherwise original item
      return _pendingUpdates[item.id] ?? item;
    }).toList();
  }

  // Cached filtered results
  List<JobListItem>? _cachedFilteredItems;
  String _lastFilterHash = ''; // Made mutable to enable caching

  // Get filtered job list items with caching
  List<JobListItem> _filteredJobListItems() {
    // Create hash of current filter state
    final currentHash =
        '${_searchQuery}_${_statusFilters.join(',')}_${_invoiceStatusFilters.join(',')}_${_dateFilter}_${_startDate?.millisecondsSinceEpoch}_${_endDate?.millisecondsSinceEpoch}';

    // Return cached results if filters haven't changed
    if (_cachedFilteredItems != null && _lastFilterHash == currentHash) {
      return _cachedFilteredItems!;
    }

    var filtered = _getMergedJobListItems();

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((item) {
        return item.client.toLowerCase().contains(query) ||
            item.invoice.toLowerCase().contains(query) ||
            item.area.toLowerCase().contains(query);
      }).toList();
    }

    // Apply status filter
    if (_statusFilters.isNotEmpty) {
      final statusSet =
          _statusFilters.toSet(); // Convert to Set for faster lookup
      filtered = filtered
          .where((item) => statusSet.contains(item.jobStatusId))
          .toList();
    }

    // Apply invoice status filter
    if (_invoiceStatusFilters.isNotEmpty) {
      final invoiceStatusSet =
          _invoiceStatusFilters.toSet(); // Convert to Set for faster lookup
      filtered = filtered
          .where((item) => invoiceStatusSet.contains(item.invoiceStatusId))
          .toList();
    }

    // Apply date filter
    if (_dateFilter != 'all' && _startDate != null) {
      filtered = filtered.where((item) {
        if (_dateFilter == 'single') {
          // Single day filter - check if item date matches the selected date
          return _isSameDay(item.date, _startDate!);
        } else if (_dateFilter == 'range' && _endDate != null) {
          // Date range filter - check if item date is within range
          return item.date
                  .isAfter(_startDate!.subtract(const Duration(days: 1))) &&
              item.date.isBefore(_endDate!.add(const Duration(days: 1)));
        }
        return true;
      }).toList();
    }

    // Apply sorting
    filtered.sort((a, b) {
      int comparison = 0;

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
      _error = 'Failed to initialize data: $error';
      print('JobListProvider: Initialization error: $error');
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

    // Debug logging
    print(
        'JobListProvider: Setting up listener for month: ${_jobListService.getMonthlyDocumentId(_currentMonth)}');

    _jobListSubscription =
        _jobListService.getJobListItems(_currentMonth).listen(
      (jobListItems) {
        print(
            'JobListProvider: Received ${jobListItems.length} job list items via snapshot');

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
                (job.jobType == JobType.windowCleaning ||
                    job.jobType == JobType.solarPanelCleaning)) {
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
        // Invalidate cache when new data arrives
        _cachedFilteredItems = null;
        _lastFilterHash = '';
        notifyListeners();
      },
      onError: (error) {
        print('JobListProvider: Snapshot error: $error');
        _error = error.toString();
        _isLoading = false;
        notifyListeners();
      },
    );
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
    _isLoading = true;
    notifyListeners();

    try {
      // Set up listener for new month
      await _setupCurrentMonthListener();
      print('JobListProvider: Successfully changed from $oldMonth to $month');
    } catch (error) {
      // Revert on error
      _currentMonth = oldMonth;
      _error =
          'Failed to load data for ${_jobListService.getMonthlyDocumentId(month)}: $error';
      print('JobListProvider: Error changing month: $error');
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
    await setCurrentMonth(DateTime.now());
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
      print(
          'JobListProvider: No changes detected for item ${jobListItem.id}, skipping update');
      return;
    }

    // Debug reminder changes
    if (currentItem != null &&
        !_areRemindersEqual(currentItem.reminders, jobListItem.reminders)) {
      print('JobListProvider: Reminders changed for item ${jobListItem.id}');
      print('  Old reminders count: ${currentItem.reminders.length}');
      print('  New reminders count: ${jobListItem.reminders.length}');
    }

    print(
        'JobListProvider: Changes detected for item ${jobListItem.id}, processing update');

    // Store the update locally
    _pendingUpdates[jobListItem.id] = jobListItem;
    _updateTimestamps[jobListItem.id] = DateTime.now();

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
        item1.jobType == item2.jobType &&
        item1.area == item2.area &&
        item1.quantity == item2.quantity &&
        item1.manDays == item2.manDays &&
        _areDatesEqual(item1.date, item2.date, item1.jobType) &&
        item1.collectionAddress == item2.collectionAddress &&
        _areDatesEqual(
            item1.collectionDate, item2.collectionDate, item1.jobType) &&
        item1.specialInstructions == item2.specialInstructions &&
        item1.quantityDistributed == item2.quantityDistributed &&
        item1.invoiceDetails == item2.invoiceDetails &&
        item1.reportAddresses == item2.reportAddresses &&
        item1.whoToInvoice == item2.whoToInvoice &&
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
  bool _areDatesEqual(DateTime date1, DateTime date2, JobType jobType) {
    // For job types that need time slots, compare full date-time but ignore milliseconds
    if (_needsTimeDisplay(jobType)) {
      return date1.year == date2.year &&
          date1.month == date2.month &&
          date1.day == date2.day &&
          date1.hour == date2.hour &&
          date1.minute == date2.minute;
    }
    // For other job types, just compare the date
    return _isSameDay(date1, date2);
  }

  // Helper method to check if job type needs time display
  bool _needsTimeDisplay(JobType jobType) {
    return jobType == JobType.junkCollection ||
        jobType == JobType.furnitureMove ||
        jobType == JobType.trailerTowing ||
        jobType == JobType.windowCleaning ||
        jobType == JobType.solarPanelCleaning;
  }

  // Process all pending updates as batch to database
  Future<void> _processPendingUpdates() async {
    if (_pendingUpdates.isEmpty) return;

    // Create a copy to work with
    final updatesToProcess = Map<String, JobListItem>.from(_pendingUpdates);
    _pendingUpdates.clear();
    _updateTimestamps.clear();

    // Process each update
    for (final entry in updatesToProcess.entries) {
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
            print(
                'JobListProvider: Job ${updatedJob.client} needs to move from $originalMonth to $newMonth');
            // Use the new move method that handles cross-month updates
            await _jobListService.moveJobListItemToMonth(
                updatedJob, originalJob.date, updatedJob.date);

            // Remove from current month's local cache if it's being moved away
            if (originalMonth ==
                    _jobListService.getMonthlyDocumentId(_currentMonth) &&
                originalIndex >= 0 &&
                originalIndex < _jobListItems.length) {
              _jobListItems.removeAt(originalIndex);
            }

            // Clear any pending updates for this job since it's been successfully moved
            _pendingUpdates.remove(entry.key);
            _updateTimestamps.remove(entry.key);
          } else {
            // Regular update within the same month
            await _jobListService.updateJobListItem(
                updatedJob, updatedJob.date);

            // Update local cache
            if (originalIndex >= 0 && originalIndex < _jobListItems.length) {
              _jobListItems[originalIndex] = updatedJob;
            }
          }
        } else {
          // Fallback: treat as regular update if original job not found
          await _jobListService.updateJobListItem(updatedJob, updatedJob.date);
        }
      } catch (error) {
        print(
            'JobListProvider: Error processing update for ${entry.value.client}: $error');

        // Only retry if it's not a RangeError or if the job hasn't been moved
        // RangeErrors often indicate the job is no longer in the expected location
        if (!error.toString().contains('RangeError')) {
          // Re-add failed update to pending updates for retry
          _pendingUpdates[entry.key] = entry.value;
          _updateTimestamps[entry.key] = DateTime.now();

          _error = 'Failed to update ${entry.value.client}: $error';

          // Schedule retry after a short delay
          Timer(const Duration(seconds: 10), () {
            if (_pendingUpdates.containsKey(entry.key)) {
              _processPendingUpdates();
            }
          });
        } else {
          // For RangeErrors, just log and continue - likely the job was moved
          print(
              'JobListProvider: RangeError for ${entry.value.client}, possibly job was moved to different month');
          _error =
              null; // Clear the error since this is expected for moved jobs
        }
      }
    }

    if (_error == null) {
      // Notify listeners of successful batch update
      notifyListeners();
    } else {
      notifyListeners();
    }
  }

  // Add job list item
  Future<void> addJobListItem(JobListItem jobListItem) async {
    try {
      await _jobListService.addJobListItem(jobListItem, jobListItem.date);

      // NOTE: Do NOT trigger Happy Sun sync here because we don't have the generated ID yet.
      // The Firestore listener will pick up the new job, and if needed, callers should use
      // addJobListItemAndReturn() to get the saved job with its ID for immediate sync.
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Add job list item and return the saved job with generated ID
  Future<JobListItem> addJobListItemAndReturn(JobListItem jobListItem) async {
    try {
      final generatedId =
          await _jobListService.addJobListItem(jobListItem, jobListItem.date);
      final savedJob = JobListItem(
        id: generatedId,
        invoice: jobListItem.invoice,
        amount: jobListItem.amount,
        client: jobListItem.client,
        jobStatusId: jobListItem.jobStatusId,
        invoiceStatusId: jobListItem.invoiceStatusId,
        jobType: jobListItem.jobType,
        area: jobListItem.area,
        quantity: jobListItem.quantity,
        manDays: jobListItem.manDays,
        date: jobListItem.date,
        collectionAddress: jobListItem.collectionAddress,
        collectionDate: jobListItem.collectionDate,
        specialInstructions: jobListItem.specialInstructions,
        quantityDistributed: jobListItem.quantityDistributed,
        invoiceDetails: jobListItem.invoiceDetails,
        reportAddresses: jobListItem.reportAddresses,
        whoToInvoice: jobListItem.whoToInvoice,
        collectionJobId: jobListItem.collectionJobId,
      );

      // Track this job as locally added to prevent duplicate sync from listener
      _locallyAddedJobIds.add(savedJob.id);

      // Trigger Happy Sun sync if job is window/solar cleaning
      if (_onJobListItemAdded != null &&
          (savedJob.jobType == JobType.windowCleaning ||
              savedJob.jobType == JobType.solarPanelCleaning)) {
        debugPrint(
            '🔄 JobListProvider: Triggering Happy Sun sync for ${savedJob.id}');
        await _onJobListItemAdded!(savedJob);
        debugPrint(
            '✅ JobListProvider: Happy Sun sync completed for ${savedJob.id}');
      }

      return savedJob;
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Add job list item without allocation (skip schedule assignment)
  Future<void> addJobListItemWithoutAllocation(JobListItem jobListItem) async {
    try {
      await _jobListService.addJobListItem(jobListItem, jobListItem.date);

      // NOTE: Happy Sun sync will be triggered by the Firestore listener when it detects the new job
      // This prevents issues with missing/temporary IDs
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      rethrow;
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
          print(
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
      print(
          'JobListProvider: Error in immediate update for ${jobListItem.client}: $error');

      // Don't rethrow RangeErrors for moved jobs
      if (!error.toString().contains('RangeError')) {
        _error = error.toString();
        notifyListeners();
        rethrow;
      } else {
        print(
            'JobListProvider: RangeError in immediate update, possibly job was moved');
        _error = null; // Clear the error since this is expected for moved jobs
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
    String? Function(int quantity, JobType jobType)? resolveQuantityLabel,
  }) async {
    final currentUser = _authProvider.user;
    final currentAppUser = _authProvider.appUser;

    if (currentUser == null) {
      throw Exception('User must be authenticated to make changes');
    }

    // Create item with tracked changes
    final trackedItem = originalItem.copyWithTrackedChange(
      userId: currentUser.uid,
      userDisplayName:
          currentAppUser?.displayName ?? currentUser.email ?? 'Unknown User',
      invoice: updatedItem.invoice != originalItem.invoice
          ? updatedItem.invoice
          : null,
      amount:
          updatedItem.amount != originalItem.amount ? updatedItem.amount : null,
      client:
          updatedItem.client != originalItem.client ? updatedItem.client : null,
      jobStatusId: updatedItem.jobStatusId != originalItem.jobStatusId
          ? updatedItem.jobStatusId
          : null,
      invoiceStatusId:
          updatedItem.invoiceStatusId != originalItem.invoiceStatusId
              ? updatedItem.invoiceStatusId
              : null,
      jobType: updatedItem.jobType != originalItem.jobType
          ? updatedItem.jobType
          : null,
      area: updatedItem.area != originalItem.area ? updatedItem.area : null,
      quantity: updatedItem.quantity != originalItem.quantity
          ? updatedItem.quantity
          : null,
      manDays: updatedItem.manDays != originalItem.manDays
          ? updatedItem.manDays
          : null,
      date: !_areDatesEqual(
              updatedItem.date, originalItem.date, updatedItem.jobType)
          ? updatedItem.date
          : null,
      collectionAddress:
          updatedItem.collectionAddress != originalItem.collectionAddress
              ? updatedItem.collectionAddress
              : null,
      collectionDate: !_areDatesEqual(updatedItem.collectionDate,
              originalItem.collectionDate, updatedItem.jobType)
          ? updatedItem.collectionDate
          : null,
      specialInstructions:
          updatedItem.specialInstructions != originalItem.specialInstructions
              ? updatedItem.specialInstructions
              : null,
      quantityDistributed:
          updatedItem.quantityDistributed != originalItem.quantityDistributed
              ? updatedItem.quantityDistributed
              : null,
      invoiceDetails: updatedItem.invoiceDetails != originalItem.invoiceDetails
          ? updatedItem.invoiceDetails
          : null,
      reportAddresses:
          updatedItem.reportAddresses != originalItem.reportAddresses
              ? updatedItem.reportAddresses
              : null,
      whoToInvoice: updatedItem.whoToInvoice != originalItem.whoToInvoice
          ? updatedItem.whoToInvoice
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
    );

    // Update locally first, then save
    updateJobListItemLocal(trackedItem);

    // Trigger Happy Sun tools update if manDays changed for window/solar cleaning
    if (_onJobListItemUpdated != null &&
        updatedItem.manDays != originalItem.manDays &&
        (updatedItem.jobType == JobType.windowCleaning ||
            updatedItem.jobType == JobType.solarPanelCleaning)) {
      _onJobListItemUpdated!(originalItem, updatedItem);
    }
  }

  // Delete job list item
  Future<void> deleteJobListItem(String id) async {
    try {
      // Find the item to get its date for proper monthly context
      final item = getJobListItemById(id);
      final itemDate = item?.date ?? _currentMonth;

      // Trigger callback before deletion (while item still exists)
      if (item != null && _onJobListItemDeleted != null) {
        await _onJobListItemDeleted!(item);
      }

      await _jobListService.deleteJobListItem(id, itemDate);
    } catch (error) {
      _error = error.toString();
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
      _error = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Set search query with debouncing
  void setSearchQuery(String query) {
    _pendingSearchQuery = query;

    // Cancel existing timer
    _searchDebounceTimer?.cancel();

    // If query is empty, apply immediately
    if (query.isEmpty) {
      _searchQuery = query;
      _isSearchingNotifier.value = false;
      _cachedFilteredItems = null;
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
    _isSearchingNotifier.value = false;
    _cachedFilteredItems = null;
    notifyListeners();
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
    _cachedFilteredItems = null; // Clear cache
    notifyListeners();
  }

  // Add status to filter
  void addStatusFilter(String statusId) {
    _statusFilters.add(statusId);
    _cachedFilteredItems = null; // Clear cache
    notifyListeners();
  }

  // Remove status from filter
  void removeStatusFilter(String statusId) {
    _statusFilters.remove(statusId);
    _cachedFilteredItems = null; // Clear cache
    notifyListeners();
  }

  // Toggle status filter
  void toggleStatusFilter(String statusId) {
    if (_statusFilters.contains(statusId)) {
      _statusFilters.remove(statusId);
    } else {
      _statusFilters.add(statusId);
    }
    _cachedFilteredItems = null; // Clear cache
    notifyListeners();
  }

  // Toggle invoice status filter
  void toggleInvoiceStatusFilter(String statusId) {
    if (_invoiceStatusFilters.contains(statusId)) {
      _invoiceStatusFilters.remove(statusId);
    } else {
      _invoiceStatusFilters.add(statusId);
    }
    _cachedFilteredItems = null; // Clear cache
    notifyListeners();
  }

  // Clear filters
  void clearFilters() {
    _searchQuery = '';
    _statusFilters.clear();
    _invoiceStatusFilters.clear();
    _dateFilter = 'all';
    _startDate = null;
    _endDate = null;
    notifyListeners();
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
    _cachedFilteredItems = null; // Clear cache
    notifyListeners();
  }

  void clearDateFilter() {
    _dateFilter = 'all';
    _startDate = null;
    _endDate = null;
    _cachedFilteredItems = null; // Clear cache
    notifyListeners();
  }

  // Simple date filter methods for new UI
  void setSimpleDateFilter(DateTime date) {
    _startDate = date;
    _endDate = null;
    _dateFilter = 'single';
    _cachedFilteredItems = null;
    notifyListeners();
  }

  void setSimpleDateRangeFilter(DateTime startDate, DateTime endDate) {
    _startDate = startDate;
    _endDate = endDate;
    _dateFilter = 'range';
    _cachedFilteredItems = null;
    notifyListeners();
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
    notifyListeners();
  }

  void setSorting(String field, bool ascending) {
    _sortField = field;
    _sortAscending = ascending;
    notifyListeners();
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
  Future<void> _loadLastCheckedTimeFromDatabase() async {
    try {
      final currentUser = _authProvider.user;
      if (currentUser == null) return;

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();

      if (userDoc.exists) {
        final data = userDoc.data()!;
        if (data.containsKey('lastCheckedTime')) {
          _lastCheckedTime = (data['lastCheckedTime'] as Timestamp).toDate();
          notifyListeners();
        }
      }
    } catch (e) {
      print('JobListProvider: Error loading last checked time: $e');
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
        print('JobListProvider: Error saving last checked time: $e2');
      }
    }
  }

  // Refresh the last checked time for updates
  Future<void> refreshLastCheckedTime() async {
    _isRefreshingLastChecked = true;
    notifyListeners();

    try {
      final now = DateTime.now();
      _lastCheckedTime = now;

      // Save to database
      await _saveLastCheckedTimeToDatabase(now);

      notifyListeners();
    } catch (e) {
      print('JobListProvider: Error refreshing last checked time: $e');
    } finally {
      _isRefreshingLastChecked = false;
      notifyListeners();
    }
  }

  // Check if a job has updates after the last checked time
  bool hasUpdatesAfterLastCheck(JobListItem item) {
    if (_lastCheckedTime == null || item.updates.isEmpty) {
      return false;
    }

    return item.updates
        .any((update) => update.timestamp.isAfter(_lastCheckedTime!));
  }

  // Get updates that occurred after the last checked time
  List<JobListItemUpdate> getUpdatesAfterLastCheck(JobListItem item) {
    if (_lastCheckedTime == null) {
      return item.updates;
    }

    return item.updates
        .where((update) => update.timestamp.isAfter(_lastCheckedTime!))
        .toList();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _jobListSubscription?.cancel();
    _isSearchingNotifier.dispose();
    super.dispose();
  }
}
