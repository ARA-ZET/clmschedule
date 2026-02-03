import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/happy_sun_project.dart';
import '../models/happy_sun_shared.dart'; // For CategorizedTools, ChecklistData

class HappySunProjectService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String collectionName = 'happySunProjects';

  // Create a new project
  Future<String> createProject(HappySunProject project) async {
    try {
      final docRef =
          await _firestore.collection(collectionName).add(project.toMap());
      return docRef.id;
    } catch (e) {
      print('Error creating project: $e');
      rethrow;
    }
  }

  // Get project by ID
  Future<HappySunProject?> getProject(String projectId) async {
    try {
      final doc =
          await _firestore.collection(collectionName).doc(projectId).get();
      if (doc.exists && doc.data() != null) {
        return HappySunProject.fromMap(doc.id, doc.data()!);
      }
      return null;
    } catch (e) {
      print('Error getting project: $e');
      rethrow;
    }
  }

  // Get all projects
  Stream<List<HappySunProject>> getAllProjects() {
    return _firestore
        .collection(collectionName)
        .orderBy('scheduledDate', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => HappySunProject.fromMap(doc.id, doc.data()))
          .toList();
    });
  }

  // Get projects by date range
  Stream<List<HappySunProject>> getProjectsByDateRange(
      DateTime startDate, DateTime endDate) {
    return _firestore
        .collection(collectionName)
        .where('scheduledDate',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startDate))
        .where('scheduledDate',
            isLessThanOrEqualTo: Timestamp.fromDate(endDate))
        .orderBy('scheduledDate', descending: false)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => HappySunProject.fromMap(doc.id, doc.data()))
          .toList();
    });
  }

  // Get projects by status
  Stream<List<HappySunProject>> getProjectsByStatus(String status) {
    return _firestore
        .collection(collectionName)
        .where('status', isEqualTo: status)
        .orderBy('scheduledDate', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => HappySunProject.fromMap(doc.id, doc.data()))
          .toList();
    });
  }

  // Update project
  Future<void> updateProject(HappySunProject project) async {
    try {
      await _firestore.collection(collectionName).doc(project.id).update(
          project.toMap()..['updatedAt'] = FieldValue.serverTimestamp());
    } catch (e) {
      print('Error updating project: $e');
      rethrow;
    }
  }

  // Update specific fields in a project
  Future<void> updateProjectFields(
      String projectId, Map<String, dynamic> fields) async {
    try {
      final updateData = Map<String, dynamic>.from(fields);
      updateData['updatedAt'] = FieldValue.serverTimestamp();
      await _firestore
          .collection(collectionName)
          .doc(projectId)
          .update(updateData);
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
      await _firestore.collection(collectionName).doc(projectId).update({
        'checkout': checkout.toMap(),
        'status': 'in-progress',
        'updatedAt': FieldValue.serverTimestamp(),
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
      await _firestore.collection(collectionName).doc(projectId).update({
        'checklist': checklist.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
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
      await _firestore.collection(collectionName).doc(projectId).update({
        'checkin': checkin.toMap(),
        'status': 'completed',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error performing checkin: $e');
      rethrow;
    }
  }

  // Delete project
  Future<void> deleteProject(String projectId) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).delete();
    } catch (e) {
      print('Error deleting project: $e');
      rethrow;
    }
  }

  // Update project status
  Future<void> updateProjectStatus(String projectId, String status) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      });
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
      await _firestore.collection(collectionName).doc(projectId).update({
        'startTime': Timestamp.fromDate(startTime),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating start time: $e');
      rethrow;
    }
  }

  // Update end time
  Future<void> updateEndTime(String projectId, DateTime endTime) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'endTime': Timestamp.fromDate(endTime),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating end time: $e');
      rethrow;
    }
  }

  // Update notes
  Future<void> updateNotes(String projectId, String notes) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'notes': notes,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating notes: $e');
      rethrow;
    }
  }

  // Update weather conditions
  Future<void> updateWeatherConditions(
      String projectId, String weatherConditions) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'weatherConditions': weatherConditions,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating weather conditions: $e');
      rethrow;
    }
  }

  // Add photo URL
  Future<void> addPhotoUrl(String projectId, String photoUrl) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'photoUrls': FieldValue.arrayUnion([photoUrl]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error adding photo URL: $e');
      rethrow;
    }
  }

  // Remove photo URL
  Future<void> removePhotoUrl(String projectId, String photoUrl) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'photoUrls': FieldValue.arrayRemove([photoUrl]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error removing photo URL: $e');
      rethrow;
    }
  }

  // Update tools used
  Future<void> updateToolsUsed(
      String projectId, CategorizedTools toolsUsed) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'toolsUsedCategorized': toolsUsed.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
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
      await _firestore.collection(collectionName).doc(projectId).update({
        'teamMemberIds': teamMemberIds,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating team members: $e');
      rethrow;
    }
  }

  // Add team member
  Future<void> addTeamMember(String projectId, String memberId) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'teamMemberIds': FieldValue.arrayUnion([memberId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error adding team member: $e');
      rethrow;
    }
  }

  // Remove team member
  Future<void> removeTeamMember(String projectId, String memberId) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'teamMemberIds': FieldValue.arrayRemove([memberId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error removing team member: $e');
      rethrow;
    }
  }

  // Update checklist data (from job execution)
  Future<void> updateChecklistData(
      String projectId, ChecklistData checklistData) async {
    try {
      await _firestore.collection(collectionName).doc(projectId).update({
        'checklistData': checklistData.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
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
      await _firestore.collection(collectionName).doc(projectId).update({
        'statusId': statusId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error syncing status: $e');
      rethrow;
    }
  }
}
