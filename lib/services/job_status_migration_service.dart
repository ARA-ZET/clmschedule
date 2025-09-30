import 'package:cloud_firestore/cloud_firestore.dart';
import '../providers/job_status_provider.dart';

/// Utility class to help migrate existing data from old enum-based job status
/// to new custom job status system
class JobStatusMigrationService {
  final FirebaseFirestore _firestore;

  JobStatusMigrationService(this._firestore);

  /// Migrate jobs from old subcollection structure to new array structure
  /// AND migrate from enum-based status to custom statusId
  /// This should be run once after implementing the new array structure
  Future<void> migrateJobsToCustomStatus() async {
    try {
      print('Starting job status and structure migration...');

      // Get all schedule monthly documents
      final schedulesSnapshot = await _firestore.collection('schedules').get();

      int totalUpdateCount = 0;

      for (final monthDoc in schedulesSnapshot.docs) {
        print('Processing month: ${monthDoc.id}');

        // Check if already has jobs array (new structure)
        final monthData = monthDoc.data();
        if (monthData.containsKey('jobs') && monthData['jobs'] is List) {
          print(
              'Month ${monthDoc.id} already has jobs array, skipping subcollection migration');
          continue;
        }

        // Get old jobs from subcollection
        final jobsSnapshot = await monthDoc.reference.collection('jobs').get();

        if (jobsSnapshot.docs.isEmpty) {
          print('No jobs found in ${monthDoc.id}');
          continue;
        }

        List<Map<String, dynamic>> migratedJobs = [];

        for (final jobDoc in jobsSnapshot.docs) {
          final data = jobDoc.data();

          // Ensure job has an ID
          data['id'] = jobDoc.id;

          // Migrate status if needed
          String newStatusId;
          String? oldStatus = data['status'] as String?;

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

          data['statusId'] = newStatusId;
          data['status'] = newStatusId; // Keep for backwards compatibility

          migratedJobs.add(data);
          totalUpdateCount++;
        }

        // Update monthly document with jobs array
        await monthDoc.reference.update({
          'jobs': migratedJobs,
        });

        print('Migrated ${migratedJobs.length} jobs for month ${monthDoc.id}');
      }

      print(
          'Migration completed: Updated $totalUpdateCount jobs across all months');
    } catch (e) {
      print('Error during migration: $e');
      throw Exception('Job status migration failed: $e');
    }
  }

  /// Check if migration is needed by looking for old subcollection structure
  Future<bool> isMigrationNeeded() async {
    try {
      final schedulesSnapshot = await _firestore
          .collection('schedules')
          .limit(5) // Just check a few documents
          .get();

      for (final monthDoc in schedulesSnapshot.docs) {
        final data = monthDoc.data();

        // If any month document doesn't have jobs array, check for old subcollection
        if (!data.containsKey('jobs') || data['jobs'] is! List) {
          // Check if there are jobs in the old subcollection structure
          final jobsSnapshot =
              await monthDoc.reference.collection('jobs').limit(1).get();

          if (jobsSnapshot.docs.isNotEmpty) {
            return true; // Found old structure
          }
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
