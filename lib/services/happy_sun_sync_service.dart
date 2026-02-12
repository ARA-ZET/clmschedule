import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/happy_sun_project.dart';
import 'happy_sun_project_service.dart';
import 'happy_sun_local_storage.dart';
import 'connectivity_service.dart';

/// Sync service to synchronize Happy Sun data between local storage and Firebase
class HappySunSyncService {
  final HappySunProjectService _firebaseService;
  final HappySunLocalStorage _localStorage;
  final ConnectivityService _connectivityService;

  bool _isSyncing = false;
  DateTime? _lastSyncTime;

  StreamSubscription? _connectivitySubscription;

  HappySunSyncService({
    required HappySunProjectService firebaseService,
    required HappySunLocalStorage localStorage,
    required ConnectivityService connectivityService,
  })  : _firebaseService = firebaseService,
        _localStorage = localStorage,
        _connectivityService = connectivityService;

  /// Initialize sync service and listen to connectivity changes
  void initialize() {
    debugPrint('🔄 HappySunSyncService: Initializing...');

    // Listen to connectivity changes
    _connectivitySubscription = _connectivityService.connectivityStream.listen(
      (isOnline) {
        if (isOnline) {
          debugPrint('🔄 Network is online, triggering sync...');
          syncPendingChanges();
        } else {
          debugPrint('🔄 Network is offline, sync paused');
        }
      },
    );

    // Trigger initial sync if online
    if (_connectivityService.isOnline) {
      syncPendingChanges();
    }
  }

  /// Sync pending changes to Firebase
  Future<void> syncPendingChanges() async {
    if (_isSyncing) {
      debugPrint('🔄 Sync already in progress, skipping...');
      return;
    }

    if (!_connectivityService.isOnline) {
      debugPrint('🔄 Device is offline, sync skipped');
      return;
    }

    _isSyncing = true;
    debugPrint('🔄 Starting sync of pending changes...');

    try {
      final pendingSync = _localStorage.getPendingSyncProjects();

      if (pendingSync.isEmpty) {
        debugPrint('🔄 No pending changes to sync');
        _isSyncing = false;
        return;
      }

      debugPrint('🔄 Syncing ${pendingSync.length} pending changes...');
      int successCount = 0;
      int failCount = 0;

      for (final syncItem in pendingSync) {
        try {
          final projectId = syncItem['projectId'] as String;
          final changes = Map<String, dynamic>.from(syncItem['changes']);

          // Get the local project
          final localProject = _localStorage.getProject(projectId);
          if (localProject == null) {
            debugPrint(
                '⚠️ Local project $projectId not found, removing from sync queue');
            await _localStorage.removePendingSync(projectId);
            continue;
          }

          // Check if this is a create operation
          if (changes.containsKey('operation') &&
              changes['operation'] == 'create') {
            final jobListItemId = changes['jobListItemId'] as String;
            final projectData =
                Map<String, dynamic>.from(changes['projectData']);
            final project = HappySunProject.fromMap(projectId, projectData);
            await _firebaseService.createProject(project, jobListItemId);
          } else {
            // Update operation - sync changed fields
            await _firebaseService.updateProjectFields(projectId, changes);
          }

          // Remove from pending sync after successful operation
          await _localStorage.removePendingSync(projectId);
          successCount++;

          debugPrint('✅ Synced project $projectId successfully');
        } catch (e) {
          failCount++;
          debugPrint('❌ Failed to sync project: $e');
          // Keep in pending sync for retry later
        }
      }

      _lastSyncTime = DateTime.now();
      debugPrint(
          '🔄 Sync complete: $successCount succeeded, $failCount failed');
    } catch (e) {
      debugPrint('❌ Error during sync: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// Download fresh data from Firebase to local storage
  Future<void> downloadDataForMonth(DateTime month) async {
    if (!_connectivityService.isOnline) {
      debugPrint('🔄 Device is offline, using cached data');
      return;
    }

    try {
      debugPrint('🔄 Downloading data for month: ${month.year}-${month.month}');

      // Get projects from Firebase
      final projects = await _firebaseService.getProjectsForMonth(month).first;

      // Save to local storage
      await _localStorage.saveProjects(projects);

      debugPrint('🔄 Downloaded ${projects.length} projects to local storage');
    } catch (e) {
      debugPrint('❌ Error downloading data: $e');
      rethrow;
    }
  }

  /// Save project with offline support
  /// Saves to local storage immediately and syncs to Firebase when online
  Future<void> saveProjectOffline(
      HappySunProject project, Map<String, dynamic> changes) async {
    try {
      // Save to local storage first
      await _localStorage.saveProject(project);

      // Mark for sync
      await _localStorage.markForSync(project.id, changes);

      debugPrint('💾 Project ${project.id} saved locally and marked for sync');

      // Try immediate sync if online
      if (_connectivityService.isOnline) {
        syncPendingChanges();
      }
    } catch (e) {
      debugPrint('❌ Error saving project offline: $e');
      rethrow;
    }
  }

  /// Create new project with offline support
  Future<String> createProjectOffline(
      HappySunProject project, String jobListItemId) async {
    try {
      // Save to local storage first
      await _localStorage.saveProject(project);

      // Mark for sync (create operation)
      await _localStorage.markForSync(project.id, {
        'operation': 'create',
        'jobListItemId': jobListItemId,
        'projectData': project.toMap(),
      });

      debugPrint(
          '💾 Project ${project.id} created locally and marked for sync');

      // Try immediate sync if online
      if (_connectivityService.isOnline) {
        syncPendingChanges();
      }

      return project.id;
    } catch (e) {
      debugPrint('❌ Error creating project offline: $e');
      rethrow;
    }
  }

  /// Mark project for sync with operation type
  Future<void> markForSync(String projectId, String operationType) async {
    try {
      await _localStorage.markForSync(projectId, {
        'operation': operationType,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      debugPrint('💾 Marked project $projectId for sync: $operationType');

      // Try immediate sync if online
      if (_connectivityService.isOnline) {
        syncPendingChanges();
      }
    } catch (e) {
      debugPrint('❌ Error marking project for sync: $e');
      rethrow;
    }
  }

  /// Get sync status
  Map<String, dynamic> getSyncStatus() {
    return {
      'isSyncing': _isSyncing,
      'lastSyncTime': _lastSyncTime,
      'pendingChanges': _localStorage.getPendingSyncProjects().length,
      'isOnline': _connectivityService.isOnline,
    };
  }

  /// Dispose of resources
  void dispose() {
    _connectivitySubscription?.cancel();
    debugPrint('🔄 HappySunSyncService: Disposed');
  }
}
