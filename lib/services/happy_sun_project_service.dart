import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/happy_sun_project.dart';
import '../models/happy_sun_shared.dart'; // For CategorizedTools, ChecklistData

class HappySunProjectService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String collectionName = 'happySunProjects';

  /// Get month document ID in format YYYY-MM
  String _getMonthDocId(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }

  /// Get reference to projects subcollection for a given month
  CollectionReference _getProjectsCollection(DateTime date) {
    final monthDocId = _getMonthDocId(date);
    return _firestore
        .collection(collectionName)
        .doc(monthDocId)
        .collection('projects');
  }

  // Create a new project with jobListItemId as the document ID
  Future<String> createProject(
      HappySunProject project, String jobListItemId) async {
    try {
      final monthDocId = _getMonthDocId(project.scheduledDate);
      final projectsCollection = _getProjectsCollection(project.scheduledDate);

      // Use jobListItemId as the document ID to prevent duplicates
      final projectDoc = projectsCollection.doc(jobListItemId);

      // Check if project already exists
      final existingDoc = await projectDoc.get();
      if (existingDoc.exists) {
        debugPrint(
            '⚠️ HappySunProjectService: Project $jobListItemId already exists, skipping creation');
        return jobListItemId;
      }

      final projectData = project.toMap();
      projectData['id'] = jobListItemId;
      projectData['createdAt'] = FieldValue.serverTimestamp();
      projectData['updatedAt'] = FieldValue.serverTimestamp();

      debugPrint('   Writing project document to Firestore subcollection...');
      // Create the project document
      await projectDoc.set(projectData);
      debugPrint('   ✅ Document written to subcollection');

      // Ensure month document exists (for queries)
      // Also remove any legacy array-based field to prevent confusion
      debugPrint(
          '   Updating month document metadata (removing legacy array if present)...');
      await _firestore.collection(collectionName).doc(monthDocId).set({
        'month': monthDocId,
        'lastUpdated': FieldValue.serverTimestamp(),
        'projects': FieldValue.delete(),
      }, SetOptions(merge: true));
      debugPrint('   ✅ Month document updated (legacy projects array removed)');

      debugPrint('✅ HappySunProjectService: Project creation COMPLETE');
      debugPrint(
          '   Document path: /happySunProjects/$monthDocId/projects/$jobListItemId');
      return jobListItemId;
    } catch (e) {
      print('Error creating project: $e');
      rethrow;
    }
  }

  // Get project by ID (searches current month and nearby months)
  Future<HappySunProject?> getProject(String projectId) async {
    try {
      // Search through monthly documents to find the project
      final now = DateTime.now();
      // Search current month and 6 months before/after
      for (int i = -6; i <= 6; i++) {
        final checkDate = DateTime(now.year, now.month + i);
        final projectDoc =
            await _getProjectsCollection(checkDate).doc(projectId).get();

        if (projectDoc.exists && projectDoc.data() != null) {
          return HappySunProject.fromMap(
              projectId, projectDoc.data() as Map<String, dynamic>);
        }
      }
      return null;
    } catch (e) {
      print('Error getting project: $e');
      rethrow;
    }
  }

  // Get all projects for a specific month
  Stream<List<HappySunProject>> getProjectsForMonth(DateTime month) {
    final monthDocId = _getMonthDocId(month);
    debugPrint('🔍 HappySunProjectService.getProjectsForMonth: $monthDocId');
    debugPrint(
        '   Querying subcollection: /happySunProjects/$monthDocId/projects');
    return _getProjectsCollection(month).snapshots().map((snapshot) {
      debugPrint(
          '   📥 Snapshot received: ${snapshot.docs.length} documents in subcollection');
      return snapshot.docs.map((doc) {
        debugPrint('      - Document ID: ${doc.id}');
        return HappySunProject.fromMap(
            doc.id, doc.data() as Map<String, dynamic>);
      }).toList()
        ..sort((a, b) => b.scheduledDate.compareTo(a.scheduledDate));
    });
  }

  // Get projects by date range
  Stream<List<HappySunProject>> getProjectsByDateRange(
      DateTime startDate, DateTime endDate) {
    // For monthly structure, we'll return projects for the start month
    // If you need cross-month queries, you'll need to combine multiple streams
    return getProjectsForMonth(startDate);
  }

  // Get projects by status (within current month)
  Stream<List<HappySunProject>> getProjectsByStatus(String status) {
    return getProjectsForMonth(DateTime.now()).map((projects) {
      return projects.where((p) => p.status == status).toList();
    });
  }

  // Update project
  Future<void> updateProject(HappySunProject project) async {
    try {
      final projectDoc =
          _getProjectsCollection(project.scheduledDate).doc(project.id);

      final updatedData = project.toMap();
      updatedData['updatedAt'] = FieldValue.serverTimestamp();

      await projectDoc.update(updatedData);
    } catch (e) {
      print('Error updating project: $e');
      rethrow;
    }
  }

  // Update specific fields in a project
  Future<void> updateProjectFields(
      String projectId, Map<String, dynamic> fields) async {
    try {
      // Find the project first to get its month
      final project = await getProject(projectId);
      if (project == null) {
        throw Exception('Project not found');
      }

      final projectDoc =
          _getProjectsCollection(project.scheduledDate).doc(projectId);

      fields['updatedAt'] = FieldValue.serverTimestamp();

      await projectDoc.update(fields);
    } catch (e) {
      print('Error updating project fields: $e');
      rethrow;
    }
  }

  // Perform checkout
  Future<void> performCheckout(
    String projectId,
    ProjectCheckout checkout,
  ) async {
    try {
      await updateProjectFields(projectId, {
        'checkout': checkout.toMap(),
        'status': 'in-progress',
      });
    } catch (e) {
      print('Error performing checkout: $e');
      rethrow;
    }
  }

  // Perform checklist
  Future<void> performChecklist(
    String projectId,
    ProjectChecklist checklist,
  ) async {
    try {
      await updateProjectFields(projectId, {
        'checklist': checklist.toMap(),
      });
    } catch (e) {
      print('Error performing checklist: $e');
      rethrow;
    }
  }

  // Perform checkin
  Future<void> performCheckin(
    String projectId,
    ProjectCheckin checkin,
  ) async {
    try {
      await updateProjectFields(projectId, {
        'checkin': checkin.toMap(),
        'status': 'completed',
      });
    } catch (e) {
      print('Error performing checkin: $e');
      rethrow;
    }
  }

  // Delete project
  Future<void> deleteProject(String projectId) async {
    try {
      // Find the project first to get its month
      final project = await getProject(projectId);
      if (project == null) {
        // Project already deleted or doesn't exist - not an error
        debugPrint(
            'ℹ️ HappySunProjectService: Project $projectId not found, may already be deleted');
        return;
      }

      final projectDoc =
          _getProjectsCollection(project.scheduledDate).doc(projectId);
      await projectDoc.delete();

      debugPrint('✅ HappySunProjectService: Deleted project $projectId');
    } catch (e) {
      print('Error deleting project: $e');
      rethrow;
    }
  }

  // Update project status
  Future<void> updateProjectStatus(String projectId, String status) async {
    try {
      await updateProjectFields(projectId, {'status': status});
    } catch (e) {
      print('Error updating project status: $e');
      rethrow;
    }
  }

  // Get projects for today
  Stream<List<HappySunProject>> getTodayProjects() {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return getProjectsByDateRange(startOfDay, endOfDay);
  }

  // Get upcoming projects (next 7 days)
  Stream<List<HappySunProject>> getUpcomingProjects() {
    final now = DateTime.now();
    final startDate = DateTime(now.year, now.month, now.day);
    final endDate = startDate.add(const Duration(days: 7));
    return getProjectsByDateRange(startDate, endDate);
  }

  // Job Execution Methods

  // Update start time
  Future<void> updateStartTime(String projectId, DateTime startTime) async {
    try {
      await updateProjectFields(projectId, {
        'startTime': Timestamp.fromDate(startTime),
      });
    } catch (e) {
      print('Error updating start time: $e');
      rethrow;
    }
  }

  // Update end time
  Future<void> updateEndTime(String projectId, DateTime endTime) async {
    try {
      await updateProjectFields(projectId, {
        'endTime': Timestamp.fromDate(endTime),
      });
    } catch (e) {
      print('Error updating end time: $e');
      rethrow;
    }
  }

  // Update notes
  Future<void> updateNotes(String projectId, String notes) async {
    try {
      await updateProjectFields(projectId, {'notes': notes});
    } catch (e) {
      print('Error updating notes: $e');
      rethrow;
    }
  }

  // Update weather conditions
  Future<void> updateWeatherConditions(
      String projectId, String weatherConditions) async {
    try {
      await updateProjectFields(
          projectId, {'weatherConditions': weatherConditions});
    } catch (e) {
      print('Error updating weather conditions: $e');
      rethrow;
    }
  }

  // Add photo URL
  Future<void> addPhotoUrl(String projectId, String photoUrl) async {
    try {
      final project = await getProject(projectId);
      if (project == null) {
        throw Exception('Project not found');
      }

      final updatedPhotoUrls = [...?project.photoUrls, photoUrl];
      await updateProjectFields(projectId, {'photoUrls': updatedPhotoUrls});
    } catch (e) {
      print('Error adding photo URL: $e');
      rethrow;
    }
  }

  // Remove photo URL
  Future<void> removePhotoUrl(String projectId, String photoUrl) async {
    try {
      final project = await getProject(projectId);
      if (project == null) {
        throw Exception('Project not found');
      }

      final updatedPhotoUrls =
          project.photoUrls?.where((url) => url != photoUrl).toList() ?? [];
      await updateProjectFields(projectId, {'photoUrls': updatedPhotoUrls});
    } catch (e) {
      print('Error removing photo URL: $e');
      rethrow;
    }
  }

  // Update tools used
  Future<void> updateToolsUsed(
      String projectId, CategorizedTools toolsUsed) async {
    try {
      await updateProjectFields(projectId, {
        'toolsUsedCategorized': toolsUsed.toMap(),
      });
    } catch (e) {
      print('Error updating tools used: $e');
      rethrow;
    }
  }

  // Update team members
  Future<void> updateTeamMembers(
      String projectId, List<String> teamMemberIds) async {
    try {
      await updateProjectFields(projectId, {'teamMemberIds': teamMemberIds});
    } catch (e) {
      print('Error updating team members: $e');
      rethrow;
    }
  }

  // Add team member
  Future<void> addTeamMember(String projectId, String memberId) async {
    try {
      final project = await getProject(projectId);
      if (project == null) {
        throw Exception('Project not found');
      }

      if (!project.teamMemberIds.contains(memberId)) {
        final updatedMembers = [...project.teamMemberIds, memberId];
        await updateProjectFields(projectId, {'teamMemberIds': updatedMembers});
      }
    } catch (e) {
      print('Error adding team member: $e');
      rethrow;
    }
  }

  // Remove team member
  Future<void> removeTeamMember(String projectId, String memberId) async {
    try {
      final project = await getProject(projectId);
      if (project == null) {
        throw Exception('Project not found');
      }

      final updatedMembers =
          project.teamMemberIds.where((id) => id != memberId).toList();
      await updateProjectFields(projectId, {'teamMemberIds': updatedMembers});
    } catch (e) {
      print('Error removing team member: $e');
      rethrow;
    }
  }

  // Update checklist data (from job execution)
  Future<void> updateChecklistData(
      String projectId, ChecklistData checklistData) async {
    try {
      await updateProjectFields(projectId, {
        'checklistData': checklistData.toMap(),
      });
    } catch (e) {
      print('Error updating checklist data: $e');
      rethrow;
    }
  }

  // Sync statusId from JobListItem
  Future<void> syncStatusFromJobListItem(
      String projectId, String statusId) async {
    try {
      await updateProjectFields(projectId, {'statusId': statusId});
    } catch (e) {
      print('Error syncing status: $e');
      rethrow;
    }
  }
}
