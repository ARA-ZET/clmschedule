import 'package:flutter/material.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/job_list_item.dart';
import '../models/job_list_item_update.dart';
import '../services/job_list_service.dart';
import '../services/undo_redo_manager.dart';
import '../commands/job_list_commands.dart';
import 'auth_provider.dart';

class JobListProvider extends ChangeNotifier {
  final JobListService _jobListService;
  final UndoRedoManager _undoRedoManager;
  final AuthProvider _authProvider;
  List<JobListItem> _jobListItems = [];
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;
  String _searchQuery = '';
  Set<String> _statusFilters = {};
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

  // Lazy loading state
  bool _hasInitialLoad = false;

  // Last checked time for updates
  DateTime? _lastCheckedTime;
  bool _isRefreshingLastChecked = false;

  JobListProvider(
      this._jobListService, this._undoRedoManager, this._authProvider) {
    // Initialize with postFrameCallback to avoid blocking UI
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCurrentMonthData();
      _loadLastCheckedTimeFromDatabase();
    });
  }

  // Getters
  List<JobListItem> get jobListItems => _filteredJobListItems();
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get error => _error;
  String get searchQuery => _searchQuery;
  Set<String> get statusFilters => _statusFilters;
  String get sortField => _sortField;
  bool get sortAscending => _sortAscending;
  DateTime get currentMonth => _currentMonth;
  String get dateFilter => _dateFilter;
  DateTime? get startDate => _startDate;
  DateTime? get endDate => _endDate;
  UndoRedoManager get undoRedoManager => _undoRedoManager;
  String get currentMonthDisplay =>
      _jobListService.getMonthlyDocumentId(_currentMonth);
  DateTime? get lastCheckedTime => _lastCheckedTime;
  bool get isRefreshingLastChecked => _isRefreshingLastChecked;

  // Get merged data (database + pending local changes)
  List<JobListItem> _getMergedJobListItems() {
    return _jobListItems.map((item) {
      // Return pending update if exists, otherwise original item
      return _pendingUpdates[item.id] ?? item;
    }).toList();
  }

  // Cached filtered results
  List<JobListItem>? _cachedFilteredItems;
  final String _lastFilterHash = '';

  // Get filtered job list items with caching
  List<JobListItem> _filteredJobListItems() {
    // Create hash of current filter state
    final currentHash =
        '${_searchQuery}_${_statusFilters.join(',')}_${_dateFilter}_${_startDate?.millisecondsSinceEpoch}_${_endDate?.millisecondsSinceEpoch}';

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

    return filtered;
  }

  // Initialize current month data with lazy loading
  Future<void> _initializeCurrentMonthData() async {
    if (_hasInitialLoad) return;

    _isLoading = true;
    notifyListeners();

    try {
      // Set up snapshot listener for current month only
      await _setupCurrentMonthListener();
      _hasInitialLoad = true;
      _isInitialized = true;
    } catch (error) {
      _error = 'Failed to initialize data: $error';
      print('JobListProvider: Initialization error: $error');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
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
        _jobListItems = jobListItems;
        _isLoading = false;
        _error = null;
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

    // Clear current data and show loading state
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
        item1.jobType == item2.jobType &&
        item1.area == item2.area &&
        item1.quantity == item2.quantity &&
        item1.manDays == item2.manDays &&
        item1.date.isAtSameMomentAs(item2.date) &&
        item1.collectionAddress == item2.collectionAddress &&
        item1.collectionDate.isAtSameMomentAs(item2.collectionDate) &&
        item1.specialInstructions == item2.specialInstructions &&
        item1.quantityDistributed == item2.quantityDistributed &&
        item1.invoiceDetails == item2.invoiceDetails &&
        item1.reportAddresses == item2.reportAddresses &&
        item1.whoToInvoice == item2.whoToInvoice;
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
      return JobListItem(
        id: generatedId,
        invoice: jobListItem.invoice,
        amount: jobListItem.amount,
        client: jobListItem.client,
        jobStatusId: jobListItem.jobStatusId,
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
      JobListItem originalItem, JobListItem updatedItem) async {
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
      date: !_isSameDay(updatedItem.date, originalItem.date)
          ? updatedItem.date
          : null,
      collectionAddress:
          updatedItem.collectionAddress != originalItem.collectionAddress
              ? updatedItem.collectionAddress
              : null,
      collectionDate:
          !_isSameDay(updatedItem.collectionDate, originalItem.collectionDate)
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
    );

    // Update locally first, then save
    updateJobListItemLocal(trackedItem);
  }

  // Delete job list item
  Future<void> deleteJobListItem(String id) async {
    try {
      // Find the item to get its date for proper monthly context
      final item = getJobListItemById(id);
      final itemDate = item?.date ?? _currentMonth;
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

  // Set search query
  void setSearchQuery(String query) {
    _searchQuery = query;
    _cachedFilteredItems = null; // Clear cache
    notifyListeners();
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

  // Clear filters
  void clearFilters() {
    _searchQuery = '';
    _statusFilters.clear();
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

  // Undo/Redo functionality
  Future<void> addJobListItemWithUndo(JobListItem jobListItem) async {
    final command = AddJobListItemCommand(
      service: _jobListService,
      jobListItem: jobListItem,
      targetDate: jobListItem.date,
    );
    await undoRedoManager.executeCommand(command, UndoRedoContext.jobList);
  }

  Future<void> updateJobListItemWithUndo(
      JobListItem originalItem, JobListItem modifiedItem) async {
    final command = EditJobListItemCommand(
      service: _jobListService,
      originalItem: originalItem,
      modifiedItem: modifiedItem,
      targetDate: modifiedItem.date,
    );
    await undoRedoManager.executeCommand(command, UndoRedoContext.jobList);
  }

  Future<void> deleteJobListItemWithUndo(JobListItem jobListItem) async {
    final command = DeleteJobListItemCommand(
      service: _jobListService,
      jobListItem: jobListItem,
      targetDate: jobListItem.date,
    );
    await undoRedoManager.executeCommand(command, UndoRedoContext.jobList);
  }

  Future<void> updateJobStatusWithUndo(String jobId, JobListStatus newStatus,
      JobListStatus originalStatus, DateTime targetDate) async {
    final command = UpdateJobStatusCommand(
      service: _jobListService,
      jobId: jobId,
      newStatus: newStatus,
      originalStatus: originalStatus,
      targetDate: targetDate,
    );
    await undoRedoManager.executeCommand(command, UndoRedoContext.jobList);
  }

  Future<void> moveJobListItemWithUndo(
      JobListItem jobListItem, DateTime fromDate, DateTime toDate) async {
    final command = MoveJobListItemCommand(
      service: _jobListService,
      jobListItem: jobListItem,
      fromDate: fromDate,
      toDate: toDate,
    );
    await undoRedoManager.executeCommand(command, UndoRedoContext.jobList);
  }

  // Access to job list undo/redo functionality
  bool get canUndo =>
      undoRedoManager.canUndoForContext(UndoRedoContext.jobList);
  bool get canRedo =>
      undoRedoManager.canRedoForContext(UndoRedoContext.jobList);
  String? get nextUndoDescription =>
      undoRedoManager.nextUndoDescriptionForContext(UndoRedoContext.jobList);
  String? get nextRedoDescription =>
      undoRedoManager.nextRedoDescriptionForContext(UndoRedoContext.jobList);

  Future<bool> undo() async {
    return await undoRedoManager.undo(UndoRedoContext.jobList);
  }

  Future<bool> redo() async {
    return await undoRedoManager.redo(UndoRedoContext.jobList);
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
    _jobListSubscription?.cancel();
    super.dispose();
  }
}
