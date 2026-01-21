import 'package:flutter/material.dart';
import 'dart:async';
import '../models/happy_sun_project.dart';
import '../services/happy_sun_project_service.dart';

class HappySunProjectProvider extends ChangeNotifier {
  final HappySunProjectService _projectService = HappySunProjectService();

  List<HappySunProject> _projects = [];
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<HappySunProject>>? _projectsSubscription;

  List<HappySunProject> get projects => _projects;
  bool get isLoading => _isLoading;
  String? get error => _error;

  HappySunProjectProvider() {
    _initializeProjects();
  }

  void _initializeProjects() {
    _setLoading(true);
    _projectsSubscription = _projectService.getAllProjects().listen(
      (projects) {
        _projects = projects;
        _setLoading(false);
        notifyListeners();
      },
      onError: (error) {
        _error = error.toString();
        _setLoading(false);
        notifyListeners();
      },
    );
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  // Create a new project
  Future<String?> createProject(HappySunProject project) async {
    try {
      _error = null;
      final projectId = await _projectService.createProject(project);
      notifyListeners();
      return projectId;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  // Update project
  Future<bool> updateProject(HappySunProject project) async {
    try {
      _error = null;
      await _projectService.updateProject(project);
      notifyListeners();
      return true;
    } catch (e) {
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
      await _projectService.performCheckout(projectId, checkout);
      notifyListeners();
      return true;
    } catch (e) {
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
      await _projectService.performChecklist(projectId, checklist);
      notifyListeners();
      return true;
    } catch (e) {
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
      await _projectService.performCheckin(projectId, checkin);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Delete project
  Future<bool> deleteProject(String projectId) async {
    try {
      _error = null;
      await _projectService.deleteProject(projectId);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // Update project status
  Future<bool> updateProjectStatus(String projectId, String status) async {
    try {
      _error = null;
      await _projectService.updateProjectStatus(projectId, status);
      notifyListeners();
      return true;
    } catch (e) {
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

  @override
  void dispose() {
    _projectsSubscription?.cancel();
    super.dispose();
  }
}
