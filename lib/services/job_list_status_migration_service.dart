import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/job_list_item.dart';
import '../providers/job_list_status_provider.dart';

class JobListStatusMigrationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final JobListStatusProvider _statusProvider;

  JobListStatusMigrationService(this._statusProvider);

  /// Check if migration is needed for job list items
  Future<bool> isMigrationNeeded() async {
    try {
      print(
          'JobListStatusMigrationService: Checking if migration is needed...');

      // Get all available months
      final monthsSnapshot = await _firestore.collection('jobList').get();

      for (final monthDoc in monthsSnapshot.docs) {
        final jobListData = monthDoc.data();

        for (final jobData in jobListData.values) {
          if (jobData is Map<String, dynamic>) {
            // If jobStatus exists but jobStatusId doesn't, migration is needed
            if (jobData['jobStatus'] != null &&
                jobData['jobStatusId'] == null) {
              print(
                  'JobListStatusMigrationService: Migration needed for job list items');
              return true;
            }
          }
        }
      }

      print('JobListStatusMigrationService: No migration needed');
      return false;
    } catch (e) {
      print('JobListStatusMigrationService: Error checking migration: $e');
      return false;
    }
  }

  /// Migrate all job list items from enum-based JobStatus to String jobStatusId
  Future<void> migrateJobListItemsToCustomStatus() async {
    try {
      print(
          'JobListStatusMigrationService: Starting migration of job list items...');

      // Ensure default statuses are initialized
      if (_statusProvider.statuses.isEmpty) {
        await _statusProvider.initializeDefaultStatuses();
      }

      // Get all job list months
      final monthsSnapshot = await _firestore.collection('jobList').get();

      int migratedCount = 0;
      final batch = _firestore.batch();

      for (final monthDoc in monthsSnapshot.docs) {
        final monthId = monthDoc.id;
        final jobListData = monthDoc.data();
        bool monthNeedsUpdate = false;
        final updatedJobList = <String, dynamic>{};

        for (final entry in jobListData.entries) {
          final jobId = entry.key;
          final jobData = entry.value;

          if (jobData is Map<String, dynamic>) {
            final updatedJobData = Map<String, dynamic>.from(jobData);

            // Check if this job needs migration
            if (jobData['jobStatus'] != null &&
                jobData['jobStatusId'] == null) {
              try {
                // Convert old enum to new status ID
                final oldStatus = JobListStatus.values.firstWhere(
                  (e) => e.name == jobData['jobStatus'],
                  orElse: () => JobListStatus.standby,
                );

                updatedJobData['jobStatusId'] = oldStatus.customStatusId;
                monthNeedsUpdate = true;
                migratedCount++;

                print(
                    '  Migrated job $jobId: ${jobData['jobStatus']} -> ${oldStatus.customStatusId}');
              } catch (e) {
                print('  Error migrating job $jobId: $e - using default');
                updatedJobData['jobStatusId'] = 'standby'; // Default fallback
                monthNeedsUpdate = true;
                migratedCount++;
              }
            }

            updatedJobList[jobId] = updatedJobData;
          } else {
            updatedJobList[jobId] = jobData;
          }
        }

        // Update the month document if needed
        if (monthNeedsUpdate) {
          batch.update(
            _firestore.collection('jobList').doc(monthId),
            updatedJobList,
          );
        }
      }

      if (migratedCount > 0) {
        await batch.commit();
        print(
            'JobListStatusMigrationService: Migration completed successfully! Migrated $migratedCount job list items');
      } else {
        print(
            'JobListStatusMigrationService: No job list items needed migration');
      }
    } catch (e) {
      print('JobListStatusMigrationService: Error during migration: $e');
      throw Exception('Failed to migrate job list items: $e');
    }
  }

  /// Perform a complete migration including status initialization
  Future<void> performFullMigration() async {
    try {
      print(
          'JobListStatusMigrationService: Starting full migration process...');

      // Step 1: Initialize default job list statuses
      if (_statusProvider.statuses.isEmpty) {
        print(
            'JobListStatusMigrationService: Initializing default statuses...');
        await _statusProvider.loadStatuses();
      }

      // Step 2: Check if migration is needed
      final migrationNeeded = await isMigrationNeeded();

      if (migrationNeeded) {
        print('JobListStatusMigrationService: Migration needed, proceeding...');
        await migrateJobListItemsToCustomStatus();
      } else {
        print('JobListStatusMigrationService: No migration needed');
      }

      print('JobListStatusMigrationService: Full migration process completed');
    } catch (e) {
      print('JobListStatusMigrationService: Error in full migration: $e');
      if (kDebugMode) {
        rethrow;
      }
    }
  }
}
