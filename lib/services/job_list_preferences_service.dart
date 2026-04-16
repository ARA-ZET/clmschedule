import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/job_list_preferences.dart';

final jobListPreferencesServiceRiverpod =
    riverpod.Provider<JobListPreferencesService>(
  (ref) => JobListPreferencesService(FirebaseFirestore.instance),
);

/// Service for managing job list preferences in Firestore
class JobListPreferencesService {
  final FirebaseFirestore _firestore;

  JobListPreferencesService(this._firestore);

  /// Get user's job list preferences
  Future<JobListPreferences> getUserPreferences(String userId) async {
    try {
      final doc = await _firestore
          .collection('userPreferences')
          .doc(userId)
          .collection('jobList')
          .doc('preferences')
          .get();

      if (doc.exists && doc.data() != null) {
        return JobListPreferences.fromMap(userId, doc.data()!);
      }

      // Return default preferences if none exist
      return JobListPreferences.defaultPreferences(userId);
    } catch (e) {
      print('Error loading job list preferences: $e');
      return JobListPreferences.defaultPreferences(userId);
    }
  }

  /// Save user's job list preferences
  Future<void> saveUserPreferences(JobListPreferences preferences) async {
    try {
      await _firestore
          .collection('userPreferences')
          .doc(preferences.userId)
          .collection('jobList')
          .doc('preferences')
          .set(preferences.toMap(), SetOptions(merge: true));
    } catch (e) {
      print('Error saving job list preferences: $e');
      rethrow;
    }
  }

  /// Stream user's job list preferences for real-time updates
  Stream<JobListPreferences> streamUserPreferences(String userId) {
    return _firestore
        .collection('userPreferences')
        .doc(userId)
        .collection('jobList')
        .doc('preferences')
        .snapshots()
        .map((doc) {
      if (doc.exists && doc.data() != null) {
        return JobListPreferences.fromMap(userId, doc.data()!);
      }
      return JobListPreferences.defaultPreferences(userId);
    });
  }

  /// Reset to default preferences
  Future<void> resetToDefaults(String userId) async {
    final defaultPrefs = JobListPreferences.defaultPreferences(userId);
    await saveUserPreferences(defaultPrefs);
  }
}
