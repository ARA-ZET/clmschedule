import 'package:flutter/material.dart';
import 'dart:async';
import '../models/job_list_item.dart';
import '../services/job_list_service.dart';

class JobListProvider extends ChangeNotifier {
  final JobListService _jobListService;
  List<JobListItem> _jobListItems = [];
  bool _isLoading = false;
  String? _error;
  String _searchQuery = '';
  Set<JobListStatus> _statusFilters = {};
  DateTime _currentMonth = DateTime.now();

  // Subscription for job list items stream
  StreamSubscription<List<JobListItem>>? _jobListSubscription;

  // Sorting functionality
  String _sortField = 'date'; // Default sort by date
  bool _sortAscending = true; // Default ascending order

  // Debounced batch update system
  Timer? _debounceTimer;
  final Map<String, JobListItem> _pendingUpdates = {};
  final Map<String, DateTime> _updateTimestamps = {};
  static const Duration _debounceDelay = Duration(seconds: 5);

  JobListProvider(this._jobListService) {
    _loadJobListItems();
  }

  // Getters
  List<JobListItem> get jobListItems => _filteredJobListItems();
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get searchQuery => _searchQuery;
  Set<JobListStatus> get statusFilters => _statusFilters;
  String get sortField => _sortField;
  bool get sortAscending => _sortAscending;
  DateTime get currentMonth => _currentMonth;
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
          .where((item) => _statusFilters.contains(item.jobStatus))
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

  // Load job list items for current month
  void _loadJobListItems() {
    _isLoading = true;
    _error = null;
    notifyListeners();

    // Debug logging
    print(
        'JobListProvider: Loading data for month: ${_jobListService.getMonthlyDocumentId(_currentMonth)}');
    print('JobListProvider: Current month date: $_currentMonth');

    // Cancel existing subscription
    _jobListSubscription?.cancel();

    _jobListSubscription =
        _jobListService.getJobListItems(_currentMonth).listen(
      (jobListItems) {
        print('JobListProvider: Loaded ${jobListItems.length} job list items');
        _jobListItems = jobListItems;
        _isLoading = false;
        _error = null;
        notifyListeners();
      },
      onError: (error) {
        print('JobListProvider: Error loading job list items: $error');
        _error = error.toString();
        _isLoading = false;
        notifyListeners();
      },
    );
  }

  // Change current month
  void setCurrentMonth(DateTime month) {
    if (_currentMonth != month) {
      _currentMonth = month;
      _loadJobListItems();
      notifyListeners();
    }
  }

  // Go to next month
  void goToNextMonth() {
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    setCurrentMonth(nextMonth);
  }

  // Go to previous month
  void goToPreviousMonth() {
    final previousMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    setCurrentMonth(previousMonth);
  }

  // Go to current month
  void goToCurrentMonth() {
    setCurrentMonth(DateTime.now());
  }

  // Go to specific month by month string (e.g., "Sep 2025")
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
    return _jobListService.getAvailableJobListMonths();
  }

  // Debounced update system - store locally first, batch update to database after delay
  void updateJobListItemLocal(JobListItem jobListItem) {
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
        await _jobListService.updateJobListItem(entry.value, entry.value.date);

        // Update local cache with successful database update
        final index = _jobListItems.indexWhere((item) => item.id == entry.key);
        if (index >= 0) {
          _jobListItems[index] = entry.value;
        }
      } catch (error) {
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

  // Update job list item (immediate database update - use sparingly)
  Future<void> updateJobListItemImmediate(JobListItem jobListItem) async {
    try {
      await _jobListService.updateJobListItem(jobListItem, jobListItem.date);
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      rethrow;
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
    final updatedItem = currentItem.copyWith(jobStatus: newStatus);

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
  void setStatusFilter(JobListStatus? status) {
    _statusFilters = status != null ? {status} : {};
    notifyListeners();
  }

  // Add status to filter
  void addStatusFilter(JobListStatus status) {
    _statusFilters.add(status);
    notifyListeners();
  }

  // Remove status from filter
  void removeStatusFilter(JobListStatus status) {
    _statusFilters.remove(status);
    notifyListeners();
  }

  // Toggle status filter
  void toggleStatusFilter(JobListStatus status) {
    if (_statusFilters.contains(status)) {
      _statusFilters.remove(status);
    } else {
      _statusFilters.add(status);
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

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _jobListSubscription?.cancel();
    super.dispose();
  }
}
