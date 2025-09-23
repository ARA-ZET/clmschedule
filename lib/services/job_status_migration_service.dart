import 'package:cloud_firestore/cloud_firestore.dart';
import '../providers/job_status_provider.dart';

/// Utility class to help migrate existing data from old enum-based job status
/// to new custom job status system
class JobStatusMigrationService {
  final FirebaseFirestore _firestore;

  JobStatusMigrationService(this._firestore);

  /// Migrate jobs collection from enum-based status to custom statusId
  /// This should be run once after implementing the custom job status system
  Future<void> migrateJobsToCustomStatus() async {
    try {
      print('Starting job status migration...');

      // Get all jobs
      final jobsSnapshot = await _firestore.collection('jobs').get();

      // Create a batch for efficient updates
      WriteBatch batch = _firestore.batch();
      int updateCount = 0;

      for (final doc in jobsSnapshot.docs) {
        final data = doc.data();

        // Check if job already has statusId (already migrated)
        if (data.containsKey('statusId') && data['statusId'] != null) {
          continue; // Skip already migrated jobs
        }

        // Get old status field
        String? oldStatus = data['status'] as String?;
        String newStatusId;

        // Map old enum values to new status IDs
        switch (oldStatus) {
          case 'JobStatus.standby':
          case 'standby':
            newStatusId = 'standby';
            break;
          case 'JobStatus.scheduled':
          case 'scheduled':
            newStatusId = 'scheduled';
            break;
          case 'JobStatus.done':
          case 'done':
            newStatusId = 'done';
            break;
          case 'JobStatus.urgent':
          case 'urgent':
            newStatusId = 'urgent';
            break;
          default:
            newStatusId = 'scheduled'; // Default fallback
        }

        // Update the job document
        batch.update(doc.reference, {
          'statusId': newStatusId,
          'status': newStatusId, // Keep for backwards compatibility
        });

        updateCount++;
      }

      // Commit the batch
      if (updateCount > 0) {
        await batch.commit();
        print('Migration completed: Updated $updateCount jobs');
      } else {
        print('Migration completed: No jobs needed migration');
      }
    } catch (e) {
      print('Error during migration: $e');
      throw Exception('Job status migration failed: $e');
    }
  }

  /// Check if migration is needed by looking for jobs with old status format
  Future<bool> isMigrationNeeded() async {
    try {
      final jobsSnapshot = await _firestore
          .collection('jobs')
          .limit(10) // Just check a few documents
          .get();

      for (final doc in jobsSnapshot.docs) {
        final data = doc.data();

        // If any job doesn't have statusId, migration is needed
        if (!data.containsKey('statusId') || data['statusId'] == null) {
          return true;
        }
      }

      return false;
    } catch (e) {
      print('Error checking migration status: $e');
      return false;
    }
  }

  /// Initialize default job statuses if they don't exist
  Future<void> ensureDefaultStatusesExist(
      JobStatusProvider statusProvider) async {
    try {
      // Check if default statuses exist
      final statusesSnapshot = await _firestore.collection('jobStatuses').get();

      if (statusesSnapshot.docs.isEmpty) {
        print('No job statuses found, creating defaults...');
        await statusProvider.initializeDefaultStatuses();
        print('Default job statuses created');
      } else {
        print('Job statuses already exist, skipping creation');
      }
    } catch (e) {
      print('Error ensuring default statuses exist: $e');
      throw Exception('Failed to ensure default statuses: $e');
    }
  }

  /// Full migration process: create default statuses and migrate existing jobs
  Future<void> performFullMigration(JobStatusProvider statusProvider) async {
    try {
      print('Starting full job status migration...');

      // Step 1: Ensure default statuses exist
      await ensureDefaultStatusesExist(statusProvider);

      // Step 2: Load statuses in provider
      await statusProvider.loadStatuses();

      // Step 3: Check if job migration is needed
      final migrationNeeded = await isMigrationNeeded();

      if (migrationNeeded) {
        // Step 4: Migrate jobs
        await migrateJobsToCustomStatus();
      } else {
        print('Job migration not needed - all jobs already migrated');
      }

      print('Full migration completed successfully');
    } catch (e) {
      print('Error during full migration: $e');
      throw Exception('Full migration failed: $e');
    }
  }
}
