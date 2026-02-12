import 'package:flutter/material.dart';
import 'dart:async';
import '../models/happy_sun_project.dart';
import '../models/happy_sun_shared.dart'; // For CategorizedTools, ChecklistData
import '../services/happy_sun_project_service.dart';
import '../services/happy_sun_local_storage.dart';
import '../services/happy_sun_sync_service.dart';
import '../services/connectivity_service.dart';
import '../config/flavor_config.dart';

class HappySunProjectProvider extends ChangeNotifier {
  final HappySunProjectService _projectService = HappySunProjectService();

  // Offline support services (nullable for CLM flavor compatibility)
  HappySunLocalStorage? _localStorage;
  HappySunSyncService? _syncService;
  ConnectivityService? _connectivityService;

  // Getter for project service (needed by sync service)
  HappySunProjectService get projectService => _projectService;

  List<HappySunProject> _projects = [];
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<HappySunProject>>? _projectsSubscription;
  DateTime _currentMonth = DateTime.now();

  List<HappySunProject> get projects => _projects;
  bool get isLoading => _isLoading;
  String? get error => _error;
  DateTime get currentMonth => _currentMonth;

  // Sync status for offline support
  Map<String, dynamic>? get syncStatus => _syncService?.getSyncStatus();
  bool get isOnline => _connectivityService?.isOnline ?? true;

  /// Set offline services (called after they're initialized in main.dart)
  void setOfflineServices({
    required HappySunLocalStorage localStorage,
    required HappySunSyncService syncService,
    required ConnectivityService connectivityService,
  }) {
    _localStorage = localStorage;
    _syncService = syncService;
    _connectivityService = connectivityService;
    debugPrint('📱 HappySunProjectProvider: Offline services configured');
  }

  HappySunProjectProvider() {
    _initializeProjects();
  }

  void setMonth(int year, int month) {
    _currentMonth = DateTime(year, month);
    _initializeProjects(); // Reload projects for the new month
    notifyListeners();
  }

  void _initializeProjects() {
    debugPrint(
        '\n📦 HappySunProjectProvider: Initializing projects for ${_currentMonth.year}-${_currentMonth.month}');
    _error = null; // Clear any previous errors
    _setLoading(true);

    // Load from local storage first (instant, offline-first)
    if (FlavorConfig.instance.isHappySun && _localStorage != null) {
      final localProjects = _localStorage!.getProjectsForMonth(_currentMonth);
      if (localProjects.isNotEmpty) {
        debugPrint(
            '   💾 Loaded ${localProjects.length} projects from local storage');
        _projects = localProjects;
        _setLoading(false);
        notifyListeners();
      }
    }

    _projectsSubscription?.cancel(); // Cancel previous subscription
    debugPrint('   Setting up stream listener for projects subcollection...');
    _projectsSubscription =
        _projectService.getProjectsForMonth(_currentMonth).listen(
      (projects) {
        debugPrint(
            '   ✅ Received ${projects.length} projects from subcollection');
        for (final project in projects) {
          debugPrint('      - ${project.id}: ${project.clientName}');
        }
        _projects = projects;

        // Save to local storage for offline access
        if (FlavorConfig.instance.isHappySun && _localStorage != null) {
          _localStorage!.saveProjects(projects);
        }

        _error = null; // Clear error on successful load
        _setLoading(false);
        notifyListeners();
      },
      onError: (error) {
        debugPrint('   ⚠️ Error loading projects from Firebase: $error');

        // Check if error is due to being offline (unavailable/permission-denied are common offline errors)
        final errorString = error.toString().toLowerCase();
        final isOfflineError = errorString.contains('unavailable') ||
            errorString.contains('failed to get document') ||
            errorString.contains('connection') ||
            errorString.contains('network');

        if (isOfflineError) {
          debugPrint('   📴 Offline error detected - using cached data');
          // Keep the locally cached projects, don't set error
          if (_projects.isEmpty &&
              FlavorConfig.instance.isHappySun &&
              _localStorage != null) {
            // Try to load from local storage if we don't have any projects yet
            final localProjects =
                _localStorage!.getProjectsForMonth(_currentMonth);
            if (localProjects.isNotEmpty) {
              debugPrint(
                  '   💾 Loaded ${localProjects.length} projects from cache');
              _projects = localProjects;
            }
          }

          // If we have projects (either from cache or previously loaded), clear any existing error
          if (_projects.isNotEmpty) {
            debugPrint(
                '   ✅ Using ${_projects.length} cached projects, clearing error');
            _error = null;
          } else {
            // No cached data available while offline
            debugPrint('   ⚠️ No cached data available');
            _error =
                'Offline: No cached data available. Please connect to the internet.';
          }
        } else {
          // Real error (not offline) - show error message
          debugPrint('   ❌ Non-offline error - clearing projects');
          _projects = [];
          _error = error.toString();
        }

        _setLoading(false);
        notifyListeners();
      },
    );
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  // Create a new project with jobListItemId as the document ID
  Future<String?> createProject(
      HappySunProject project, String jobListItemId) async {
    try {
      debugPrint('\n🏗️ HappySunProjectProvider.createProject: CALLED');
      debugPrint('   Job List Item ID: $jobListItemId');
      debugPrint('   Client: ${project.clientName}');
      debugPrint('   Job Type: ${project.jobType}');
      debugPrint('   Scheduled Date: ${project.scheduledDate}');
      debugPrint('   Stack trace:');
      debugPrint(StackTrace.current.toString().split('\n').take(5).join('\n'));

      _error = null;

      // Offline-first approach for Happy Sun flavor
      if (FlavorConfig.instance.isHappySun && _syncService != null) {
        final projectId =
            await _syncService!.createProjectOffline(project, jobListItemId);
        debugPrint('   ✅ Provider: Project saved offline-first');
        notifyListeners();
        return projectId;
      } else {
        // Online-only for CLM flavor
        final projectId =
            await _projectService.createProject(project, jobListItemId);
        debugPrint('   ✅ Provider: Project created successfully');
        notifyListeners();
        return projectId;
      }
    } catch (e) {
      debugPrint('   ❌ Provider: Error creating project: $e');
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  // Update project
  Future<bool> updateProject(HappySunProject project) async {
    try {
      _error = null;

      // Try to update online first
      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.updateProject(project);
        } catch (e) {
          // If online but Firebase fails, save locally
          debugPrint('⚠️ Firebase update failed, saving locally: $e');
          if (_localStorage != null && _syncService != null) {
            await _localStorage!.saveProject(project);
            await _syncService!.markForSync(project.id, 'update');
          }
        }
      } else {
        // Offline: save locally and mark for sync
        debugPrint('📴 Offline: Saving project locally for sync later');
        if (_localStorage != null && _syncService != null) {
          await _localStorage!.saveProject(project);
          await _syncService!.markForSync(project.id, 'update');
        }
      }

      // Update local list
      final index = _projects.indexWhere((p) => p.id == project.id);
      if (index != -1) {
        _projects[index] = project;
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error updating project: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Perform checkout
  Future<bool> performCheckout({
    required String projectId,
    required List<CheckedOutTool> tools,
    String? notes,
    required String userId,
  }) async {
    try {
      _error = null;
      final checkout = ProjectCheckout(
        checkoutTime: DateTime.now(),
        tools: tools,
        notes: notes,
        checkedOutBy: userId,
      );

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.performCheckout(projectId, checkout);
        } catch (e) {
          debugPrint('⚠️ Firebase checkout failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'checkout');
          }
        }
      } else {
        debugPrint('📴 Offline: Checkout will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'checkout');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error performing checkout: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Perform checklist
  Future<bool> performChecklist({
    required String projectId,
    required List<ChecklistItem> items,
    String? notes,
    required String userId,
  }) async {
    try {
      _error = null;
      final allChecked = items.every((item) => item.isChecked);
      final checklist = ProjectChecklist(
        checklistTime: DateTime.now(),
        items: items,
        allItemsChecked: allChecked,
        notes: notes,
        checkedBy: userId,
      );

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.performChecklist(projectId, checklist);
        } catch (e) {
          debugPrint('⚠️ Firebase checklist failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'checklist');
          }
        }
      } else {
        debugPrint('📴 Offline: Checklist will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'checklist');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error performing checklist: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Perform checkin
  Future<bool> performCheckin({
    required String projectId,
    required List<CheckedOutTool> returnedTools,
    List<String> missingTools = const [],
    String? notes,
    required String userId,
  }) async {
    try {
      _error = null;
      final checkin = ProjectCheckin(
        checkinTime: DateTime.now(),
        returnedTools: returnedTools,
        missingTools: missingTools,
        notes: notes,
        checkedInBy: userId,
      );

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.performCheckin(projectId, checkin);
        } catch (e) {
          debugPrint('⚠️ Firebase checkin failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'checkin');
          }
        }
      } else {
        debugPrint('📴 Offline: Checkin will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'checkin');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error performing checkin: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Delete project
  Future<bool> deleteProject(String projectId) async {
    try {
      _error = null;

      // Remove from local list immediately for instant UI update
      _projects.removeWhere((project) => project.id == projectId);

      // Delete from Firebase or queue for sync
      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.deleteProject(projectId);
        } catch (e) {
          debugPrint('⚠️ Firebase deleteProject failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'delete');
          }
        }
      } else {
        debugPrint('📴 Offline: Project deletion will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'delete');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ HappySunProjectProvider: Error deleting project: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update project status
  Future<bool> updateProjectStatus(String projectId, String status) async {
    try {
      _error = null;

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.updateProjectStatus(projectId, status);
        } catch (e) {
          debugPrint(
              '⚠️ Firebase updateProjectStatus failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'updateStatus');
          }
        }
      } else {
        debugPrint('📴 Offline: Status update will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'updateStatus');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error updating project status: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Get project by ID
  HappySunProject? getProjectById(String projectId) {
    try {
      return _projects.firstWhere((project) => project.id == projectId);
    } catch (e) {
      return null;
    }
  }

  // Get projects by status
  List<HappySunProject> getProjectsByStatus(String status) {
    return _projects.where((project) => project.status == status).toList();
  }

  // Get today's projects
  List<HappySunProject> getTodayProjects() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _projects.where((project) {
      final projectDate = DateTime(
        project.scheduledDate.year,
        project.scheduledDate.month,
        project.scheduledDate.day,
      );
      return projectDate.isAtSameMomentAs(today);
    }).toList();
  }

  // Get upcoming projects (next 7 days)
  List<HappySunProject> getUpcomingProjects() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final nextWeek = today.add(const Duration(days: 7));
    return _projects.where((project) {
      final projectDate = DateTime(
        project.scheduledDate.year,
        project.scheduledDate.month,
        project.scheduledDate.day,
      );
      return projectDate.isAfter(today) && projectDate.isBefore(nextWeek);
    }).toList();
  }

  // Job Execution Methods

  // Update start time
  Future<bool> updateStartTime(String projectId, DateTime startTime) async {
    try {
      _error = null;

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.updateStartTime(projectId, startTime);
        } catch (e) {
          debugPrint(
              '⚠️ Firebase updateStartTime failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'updateStartTime');
          }
        }
      } else {
        debugPrint('📴 Offline: Start time update will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'updateStartTime');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error updating start time: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update end time
  Future<bool> updateEndTime(String projectId, DateTime endTime) async {
    try {
      _error = null;

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.updateEndTime(projectId, endTime);
        } catch (e) {
          debugPrint('⚠️ Firebase updateEndTime failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'updateEndTime');
          }
        }
      } else {
        debugPrint('📴 Offline: End time update will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'updateEndTime');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error updating end time: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update notes
  Future<bool> updateNotes(String projectId, String notes) async {
    try {
      _error = null;

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.updateNotes(projectId, notes);
        } catch (e) {
          debugPrint('⚠️ Firebase updateNotes failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'updateNotes');
          }
        }
      } else {
        debugPrint('📴 Offline: Notes update will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'updateNotes');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error updating notes: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update weather conditions
  Future<bool> updateWeatherConditions(
      String projectId, String weatherConditions) async {
    try {
      _error = null;
      await _projectService.updateWeatherConditions(
          projectId, weatherConditions);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Add photo URL
  Future<bool> addPhotoUrl(String projectId, String photoUrl) async {
    try {
      _error = null;

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.addPhotoUrl(projectId, photoUrl);
        } catch (e) {
          debugPrint('⚠️ Firebase addPhotoUrl failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'addPhotoUrl');
          }
        }
      } else {
        debugPrint('📴 Offline: Photo URL will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'addPhotoUrl');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error adding photo URL: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Remove photo URL
  Future<bool> removePhotoUrl(String projectId, String photoUrl) async {
    try {
      _error = null;

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.removePhotoUrl(projectId, photoUrl);
        } catch (e) {
          debugPrint('⚠️ Firebase removePhotoUrl failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'removePhotoUrl');
          }
        }
      } else {
        debugPrint('📴 Offline: Photo removal will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'removePhotoUrl');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error removing photo URL: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update tools used
  Future<bool> updateToolsUsed(
      String projectId, CategorizedTools toolsUsed) async {
    try {
      _error = null;
      await _projectService.updateToolsUsed(projectId, toolsUsed);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update tools needed (preparation list)
  Future<bool> updateToolsNeeded(String projectId, DateTime projectDate,
      CategorizedTools toolsNeeded) async {
    try {
      _error = null;
      // Update the project document
      await _projectService.updateProjectFields(
        projectId,
        {'toolsNeeded': toolsNeeded.toMap()},
      );
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update project fields (generic update)
  Future<bool> updateProjectFields(String projectId, DateTime projectDate,
      Map<String, dynamic> fields) async {
    try {
      _error = null;

      if (_connectivityService?.isOnline ?? true) {
        try {
          await _projectService.updateProjectFields(projectId, fields);
        } catch (e) {
          debugPrint(
              '⚠️ Firebase updateProjectFields failed, marking for sync: $e');
          if (_syncService != null) {
            await _syncService!.markForSync(projectId, 'updateFields');
          }
        }
      } else {
        debugPrint('📴 Offline: Project field updates will sync later');
        if (_syncService != null) {
          await _syncService!.markForSync(projectId, 'updateFields');
        }
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Error updating project fields: $e');
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update team members
  Future<bool> updateTeamMembers(
      String projectId, List<String> teamMemberIds) async {
    try {
      _error = null;
      await _projectService.updateTeamMembers(projectId, teamMemberIds);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Add team member
  Future<bool> addTeamMember(String projectId, String memberId) async {
    try {
      _error = null;
      await _projectService.addTeamMember(projectId, memberId);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Remove team member
  Future<bool> removeTeamMember(String projectId, String memberId) async {
    try {
      _error = null;
      await _projectService.removeTeamMember(projectId, memberId);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update checklist data
  Future<bool> updateChecklistData(
      String projectId, ChecklistData checklistData) async {
    try {
      _error = null;
      await _projectService.updateChecklistData(projectId, checklistData);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Sync status from JobListItem
  Future<bool> syncStatusFromJobListItem(
      String projectId, String statusId) async {
    try {
      _error = null;
      await _projectService.syncStatusFromJobListItem(projectId, statusId);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _projectsSubscription?.cancel();
    super.dispose();
  }
}
