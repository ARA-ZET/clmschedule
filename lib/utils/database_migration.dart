import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/job_status_migration_service.dart';
import '../providers/job_status_provider.dart';

/// Utility class to help with database structure migration
/// from subcollection-based jobs to array-based jobs
class DatabaseMigration {
  final FirebaseFirestore _firestore;
  final JobStatusMigrationService _migrationService;

  DatabaseMigration({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _migrationService =
            JobStatusMigrationService(firestore ?? FirebaseFirestore.instance);

  /// Check if the database needs migration from old structure
  Future<bool> needsMigration() async {
    return await _migrationService.isMigrationNeeded();
  }

  /// Perform complete database migration
  /// This will:
  /// 1. Ensure default job statuses exist
  /// 2. Migrate jobs from subcollection to array structure
  /// 3. Update job status references
  Future<void> performMigration(JobStatusProvider statusProvider) async {
    try {
      print('Starting complete database migration...');

      final migrationNeeded = await needsMigration();
      if (!migrationNeeded) {
        print('No migration needed - database already up to date');
        return;
      }

      // Perform the migration
      await _migrationService.performFullMigration(statusProvider);

      print('Database migration completed successfully!');

      // Note: Old subcollections can be cleaned up manually using cleanupOldSubcollections() method
    } catch (e) {
      print('Database migration failed: $e');
      throw Exception('Migration failed: $e');
    }
  }

  /// Clean up old jobs subcollections after successful migration
  /// WARNING: This permanently deletes the old subcollection data
  /// Only run this after confirming the new array structure is working
  Future<void> cleanupOldSubcollections() async {
    try {
      print('Starting cleanup of old jobs subcollections...');

      final schedulesSnapshot = await _firestore.collection('schedules').get();

      for (final monthDoc in schedulesSnapshot.docs) {
        final jobsSnapshot = await monthDoc.reference.collection('jobs').get();

        if (jobsSnapshot.docs.isNotEmpty) {
          print('Cleaning up jobs subcollection for ${monthDoc.id}...');

          // Delete all jobs in the subcollection
          WriteBatch batch = _firestore.batch();
          for (final jobDoc in jobsSnapshot.docs) {
            batch.delete(jobDoc.reference);
          }
          await batch.commit();

          print(
              'Cleaned up ${jobsSnapshot.docs.length} old job documents for ${monthDoc.id}');
        }
      }

      print('Cleanup completed');
    } catch (e) {
      print('Error during cleanup: $e');
      throw Exception('Cleanup failed: $e');
    }
  }

  /// Get migration status report
  Future<Map<String, dynamic>> getMigrationStatus() async {
    try {
      final schedulesSnapshot = await _firestore.collection('schedules').get();

      int monthsWithArrayStructure = 0;
      int monthsWithSubcollectionStructure = 0;
      int totalJobs = 0;
      List<String> monthsNeedingMigration = [];

      for (final monthDoc in schedulesSnapshot.docs) {
        final data = monthDoc.data();

        if (data.containsKey('jobs') && data['jobs'] is List) {
          monthsWithArrayStructure++;
          final jobsArray = data['jobs'] as List;
          totalJobs += jobsArray.length;
        } else {
          // Check subcollection
          final jobsSnapshot =
              await monthDoc.reference.collection('jobs').get();

          if (jobsSnapshot.docs.isNotEmpty) {
            monthsWithSubcollectionStructure++;
            totalJobs += jobsSnapshot.docs.length;
            monthsNeedingMigration.add(monthDoc.id);
          }
        }
      }

      return {
        'monthsWithArrayStructure': monthsWithArrayStructure,
        'monthsWithSubcollectionStructure': monthsWithSubcollectionStructure,
        'totalJobs': totalJobs,
        'monthsNeedingMigration': monthsNeedingMigration,
        'migrationNeeded': monthsWithSubcollectionStructure > 0,
      };
    } catch (e) {
      return {
        'error': e.toString(),
      };
    }
  }
}
