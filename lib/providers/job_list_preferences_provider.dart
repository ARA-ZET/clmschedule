import 'package:flutter/material.dart';
import 'dart:async';
import '../models/job_list_preferences.dart';
import '../services/job_list_preferences_service.dart';
import 'auth_provider.dart';

/// Provider for managing job list column preferences
class JobListPreferencesProvider extends ChangeNotifier {
  final JobListPreferencesService _preferencesService;
  final AuthProvider _authProvider;

  JobListPreferences? _preferences;
  bool _isLoading = false;
  String? _error;
  StreamSubscription<JobListPreferences>? _preferencesSubscription;

  JobListPreferencesProvider(this._preferencesService, this._authProvider) {
    _initializePreferences();
  }

  // Getters
  JobListPreferences? get preferences => _preferences;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Initialize preferences for current user
  Future<void> _initializePreferences() async {
    final userId = _authProvider.user?.uid;
    if (userId == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      // Load initial preferences
      _preferences = await _preferencesService.getUserPreferences(userId);

      // Set up real-time listener
      _preferencesSubscription?.cancel();
      _preferencesSubscription =
          _preferencesService.streamUserPreferences(userId).listen((prefs) {
        _preferences = prefs;
        _error = null;
        notifyListeners();
      }, onError: (error) {
        _error = error.toString();
        notifyListeners();
      });

      _error = null;
    } catch (e) {
      _error = 'Failed to load preferences: $e';
      // Use default preferences on error
      _preferences = JobListPreferences.defaultPreferences(userId);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Check if a column is visible
  bool isColumnVisible(String columnKey) {
    return _preferences?.isColumnVisible(columnKey) ?? true;
  }

  /// Check if a column can be toggled
  bool canToggleColumn(String columnKey) {
    return _preferences?.canToggleColumn(columnKey) ?? false;
  }

  /// Toggle column visibility
  Future<void> toggleColumnVisibility(String columnKey) async {
    if (_preferences == null) return;
    if (!canToggleColumn(columnKey)) return;

    final newVisibility =
        Map<String, bool>.from(_preferences!.columnVisibility);
    newVisibility[columnKey] = !(newVisibility[columnKey] ?? true);

    final updatedPreferences = _preferences!.copyWith(
      columnVisibility: newVisibility,
      lastUpdated: DateTime.now(),
    );

    // Optimistically update local state
    _preferences = updatedPreferences;
    notifyListeners();

    // Save to Firestore
    try {
      await _preferencesService.saveUserPreferences(updatedPreferences);
    } catch (e) {
      _error = 'Failed to save preferences: $e';
      // Revert on error
      await _initializePreferences();
    }
  }

  /// Set multiple column visibilities at once
  Future<void> setColumnVisibilities(Map<String, bool> visibilities) async {
    if (_preferences == null) return;

    final newVisibility =
        Map<String, bool>.from(_preferences!.columnVisibility);

    // Only update columns that can be toggled
    visibilities.forEach((key, value) {
      if (canToggleColumn(key)) {
        newVisibility[key] = value;
      }
    });

    final updatedPreferences = _preferences!.copyWith(
      columnVisibility: newVisibility,
      lastUpdated: DateTime.now(),
    );

    // Optimistically update local state
    _preferences = updatedPreferences;
    notifyListeners();

    // Save to Firestore
    try {
      await _preferencesService.saveUserPreferences(updatedPreferences);
    } catch (e) {
      _error = 'Failed to save preferences: $e';
      // Revert on error
      await _initializePreferences();
    }
  }

  /// Reset to default preferences
  Future<void> resetToDefaults() async {
    final userId = _authProvider.user?.uid;
    if (userId == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      await _preferencesService.resetToDefaults(userId);
      _preferences = JobListPreferences.defaultPreferences(userId);
      _error = null;
    } catch (e) {
      _error = 'Failed to reset preferences: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Get set of visible column keys
  Set<String> get visibleColumns {
    if (_preferences == null) {
      return JobListPreferences.defaultColumnVisibility.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toSet();
    }
    return _preferences!.columnVisibility.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toSet();
  }

  /// Get count of visible columns
  int get visibleColumnCount {
    if (_preferences == null) {
      return JobListPreferences.defaultColumnVisibility.length;
    }
    return _preferences!.columnVisibility.values
        .where((visible) => visible)
        .length;
  }

  /// Get count of hidden columns
  int get hiddenColumnCount {
    if (_preferences == null) return 0;
    return _preferences!.columnVisibility.values
        .where((visible) => !visible)
        .length;
  }

  @override
  void dispose() {
    _preferencesSubscription?.cancel();
    super.dispose();
  }
}
