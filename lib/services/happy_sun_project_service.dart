import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/happy_sun_project.dart';

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
}
