import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';
import '../models/happy_sun_project.dart';

/// Local storage service for Happy Sun projects using Hive
/// Provides offline-first data persistence for Happy Sun flavor
class HappySunLocalStorage {
  static const String _projectsBoxName = 'happy_sun_projects';
  static const String _pendingSyncBoxName = 'happy_sun_pending_sync';

  Box<Map>? _projectsBox;
  Box<Map>? _pendingSyncBox;

  /// Deep convert dynamic maps to typed maps recursively
  static Map<String, dynamic> _deepConvertMap(dynamic map) {
    if (map == null) return {};
    if (map is Map<String, dynamic>) return map;

    final result = <String, dynamic>{};
    if (map is Map) {
      map.forEach((key, value) {
        final stringKey = key.toString();
        if (value is Map) {
          result[stringKey] = _deepConvertMap(value);
        } else if (value is List) {
          result[stringKey] = _deepConvertList(value);
        } else {
          result[stringKey] = value;
        }
      });
    }
    return result;
  }

  /// Deep convert dynamic lists recursively
  static List<dynamic> _deepConvertList(List<dynamic> list) {
    return list.map((item) {
      if (item is Map) {
        return _deepConvertMap(item);
      } else if (item is List) {
        return _deepConvertList(item);
      }
      return item;
    }).toList();
  }

  bool get isInitialized => _projectsBox != null && _pendingSyncBox != null;

  /// Initialize Hive and open boxes
  Future<void> initialize() async {
    try {
      debugPrint('💾 HappySunLocalStorage: Initializing Hive...');

      // Initialize Hive
      await Hive.initFlutter();

      // Open boxes
      _projectsBox = await Hive.openBox<Map>(_projectsBoxName);
      _pendingSyncBox = await Hive.openBox<Map>(_pendingSyncBoxName);

      debugPrint('💾 HappySunLocalStorage: Initialized successfully');
      debugPrint('   - Projects count: ${_projectsBox?.length ?? 0}');
      debugPrint('   - Pending sync count: ${_pendingSyncBox?.length ?? 0}');
    } catch (e) {
      debugPrint('❌ HappySunLocalStorage: Initialization error: $e');
      rethrow;
    }
  }

  /// Save a project to local storage
  Future<void> saveProject(HappySunProject project) async {
    if (!isInitialized) {
      throw Exception('HappySunLocalStorage not initialized');
    }

    try {
      final projectMap = _convertToHiveCompatible(project.toMap());
      await _projectsBox!.put(project.id, projectMap);
      debugPrint('💾 Saved project ${project.id} to local storage');
    } catch (e) {
      debugPrint('❌ Error saving project to local storage: $e');
      rethrow;
    }
  }

  /// Save multiple projects to local storage
  Future<void> saveProjects(List<HappySunProject> projects) async {
    if (!isInitialized) {
      throw Exception('HappySunLocalStorage not initialized');
    }

    try {
      final entries = <String, Map>{};
      for (final project in projects) {
        entries[project.id] = _convertToHiveCompatible(project.toMap());
      }
      await _projectsBox!.putAll(entries);
      debugPrint('💾 Saved ${projects.length} projects to local storage');
    } catch (e) {
      debugPrint('❌ Error saving projects to local storage: $e');
      rethrow;
    }
  }

  /// Get a project from local storage by ID
  HappySunProject? getProject(String projectId) {
    if (!isInitialized) return null;

    try {
      final projectMap = _projectsBox!.get(projectId);
      if (projectMap == null) return null;

      return HappySunProject.fromMap(
        projectId,
        _deepConvertMap(projectMap),
      );
    } catch (e) {
      debugPrint('❌ Error getting project from local storage: $e');
      return null;
    }
  }

  /// Get all projects from local storage
  List<HappySunProject> getAllProjects() {
    if (!isInitialized) return [];

    try {
      final projects = <HappySunProject>[];
      for (final key in _projectsBox!.keys) {
        final projectMap = _projectsBox!.get(key);
        if (projectMap != null) {
          try {
            final project = HappySunProject.fromMap(
              key.toString(),
              _deepConvertMap(projectMap),
            );
            projects.add(project);
          } catch (e) {
            debugPrint('❌ Error parsing project $key: $e');
          }
        }
      }
      return projects;
    } catch (e) {
      debugPrint('❌ Error getting all projects from local storage: $e');
      return [];
    }
  }

  /// Get projects for a specific month
  List<HappySunProject> getProjectsForMonth(DateTime month) {
    final allProjects = getAllProjects();
    return allProjects.where((project) {
      return project.scheduledDate.year == month.year &&
          project.scheduledDate.month == month.month;
    }).toList();
  }

  /// Delete a project from local storage
  Future<void> deleteProject(String projectId) async {
    if (!isInitialized) return;

    try {
      await _projectsBox!.delete(projectId);
      debugPrint('💾 Deleted project $projectId from local storage');
    } catch (e) {
      debugPrint('❌ Error deleting project from local storage: $e');
      rethrow;
    }
  }

  /// Mark a project for syncing when online
  Future<void> markForSync(
      String projectId, Map<String, dynamic> changes) async {
    if (!isInitialized) return;

    try {
      final syncData = {
        'projectId': projectId,
        'changes': changes,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      await _pendingSyncBox!.put(projectId, syncData);
      debugPrint('💾 Marked project $projectId for sync');
    } catch (e) {
      debugPrint('❌ Error marking project for sync: $e');
      rethrow;
    }
  }

  /// Get all projects pending sync
  List<Map<String, dynamic>> getPendingSyncProjects() {
    if (!isInitialized) return [];

    try {
      final pendingSync = <Map<String, dynamic>>[];
      for (final key in _pendingSyncBox!.keys) {
        final syncData = _pendingSyncBox!.get(key);
        if (syncData != null) {
          pendingSync.add(Map<String, dynamic>.from(syncData));
        }
      }
      return pendingSync;
    } catch (e) {
      debugPrint('❌ Error getting pending sync projects: $e');
      return [];
    }
  }

  /// Remove a project from pending sync queue after successful sync
  Future<void> removePendingSync(String projectId) async {
    if (!isInitialized) return;

    try {
      await _pendingSyncBox!.delete(projectId);
      debugPrint('💾 Removed project $projectId from pending sync');
    } catch (e) {
      debugPrint('❌ Error removing pending sync: $e');
      rethrow;
    }
  }

  /// Clear all local data (useful for sign out or data reset)
  Future<void> clearAll() async {
    if (!isInitialized) return;

    try {
      await _projectsBox!.clear();
      await _pendingSyncBox!.clear();
      debugPrint('💾 Cleared all local storage');
    } catch (e) {
      debugPrint('❌ Error clearing local storage: $e');
      rethrow;
    }
  }

  /// Close storage boxes
  Future<void> dispose() async {
    await _projectsBox?.close();
    await _pendingSyncBox?.close();
    debugPrint('💾 HappySunLocalStorage: Disposed');
  }

  /// Convert Firestore Timestamps to Hive-compatible format
  Map<String, dynamic> _convertToHiveCompatible(Map<String, dynamic> data) {
    final result = <String, dynamic>{};

    for (final entry in data.entries) {
      final value = entry.value;

      // Convert Timestamp to ISO8601 string
      if (value.runtimeType.toString() == 'Timestamp') {
        final timestamp = value as dynamic;
        final dateTime = DateTime.fromMillisecondsSinceEpoch(
          timestamp.millisecondsSinceEpoch as int,
        );
        result[entry.key] = dateTime.toIso8601String();
      }
      // Recursively handle nested maps
      else if (value is Map<String, dynamic>) {
        result[entry.key] = _convertToHiveCompatible(value);
      }
      // Handle lists
      else if (value is List) {
        result[entry.key] = value.map((item) {
          if (item is Map<String, dynamic>) {
            return _convertToHiveCompatible(item);
          }
          return item;
        }).toList();
      }
      // Keep other types as-is
      else {
        result[entry.key] = value;
      }
    }

    return result;
  }
}
