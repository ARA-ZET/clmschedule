import 'package:flutter/material.dart';
import 'dart:async';
import '../models/job_list_item.dart';
import '../services/job_list_service.dart';
import '../services/undo_redo_manager.dart';
import '../commands/job_list_commands.dart';

class JobListProvider extends ChangeNotifier {
  final JobListService _jobListService;
  final UndoRedoManager _undoRedoManager;
  List<JobListItem> _jobListItems = [];
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;
  String _searchQuery = '';
  Set<String> _statusFilters = {};
  DateTime _currentMonth = DateTime.now();

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

  JobListProvider(this._jobListService, this._undoRedoManager) {
    // Initialize with postFrameCallback to avoid blocking UI
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCurrentMonthData();
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
  UndoRedoManager get undoRedoManager => _undoRedoManager;
  String get currentMonthDisplay =>
      _jobListService.getMonthlyDocumentId(_currentMonth);

  // Get merged data (database + pending local changes)
  List<JobListItem> _getMergedJobListItems() {
    return _jobListItems.map((item) {
      // Return pending update if exists, otherwise original item
      return _pendingUpdates[item.id] ?? item;
    }).toList();
  }

  // Get filtered job list items
  List<JobListItem> _filteredJobListItems() {
    var filtered = _getMergedJobListItems();

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((item) {
        return item.client.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            item.invoice.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            item.area.toLowerCase().contains(_searchQuery.toLowerCase());
      }).toList();
    }

    // Apply status filter
    if (_statusFilters.isNotEmpty) {
      filtered = filtered
          .where((item) => _statusFilters.contains(item.jobStatusId))
          .toList();
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
    notifyListeners();
  }

  // Set status filter
  void setStatusFilter(String? statusId) {
    _statusFilters = statusId != null ? {statusId} : {};
    notifyListeners();
  }

  // Add status to filter
  void addStatusFilter(String statusId) {
    _statusFilters.add(statusId);
    notifyListeners();
  }

  // Remove status from filter
  void removeStatusFilter(String statusId) {
    _statusFilters.remove(statusId);
    notifyListeners();
  }

  // Toggle status filter
  void toggleStatusFilter(String statusId) {
    if (_statusFilters.contains(statusId)) {
      _statusFilters.remove(statusId);
    } else {
      _statusFilters.add(statusId);
    }
    notifyListeners();
  }

  // Clear filters
  void clearFilters() {
    _searchQuery = '';
    _statusFilters.clear();
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

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _jobListSubscription?.cancel();
    super.dispose();
  }
}
