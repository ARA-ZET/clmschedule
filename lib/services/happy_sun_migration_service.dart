import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Service for migrating existing HappySunJob data to HappySunProject documents
class HappySunMigrationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Migrates all existing HappySunJob data to HappySunProject documents
  /// Returns a summary of the migration (jobs processed, projects created, errors)
  Future<Map<String, int>> migrateJobsToProjects() async {
    int jobsProcessed = 0;
    int projectsCreated = 0;
    int projectsUpdated = 0;
    int errors = 0;

    try {
      debugPrint('Starting Happy Sun Projects migration...');

      // Get all monthly documents from happySun collection
      final happySunSnapshot = await _firestore.collection('happySun').get();
      debugPrint('Found ${happySunSnapshot.docs.length} monthly documents');

      for (final monthDoc in happySunSnapshot.docs) {
        final monthData = monthDoc.data();
        final jobs = monthData['jobs'] as List<dynamic>? ?? [];

        debugPrint('Processing ${jobs.length} jobs from ${monthDoc.id}...');

        for (final jobData in jobs) {
          try {
            jobsProcessed++;
            final jobMap = jobData as Map<String, dynamic>;
            final jobId = jobMap['id'] as String;
            final jobDate = (jobMap['date'] as Timestamp?)?.toDate();

            if (jobDate == null) {
              debugPrint('Skipping job $jobId - no date found');
              errors++;
              continue;
            }

            // Check if project already exists
            final existingProject = await _firestore
                .collection('happySunProjects')
                .doc(jobId)
                .get();

            if (existingProject.exists) {
              // Update numberOfTeamMembers if it's different
              final existingData = existingProject.data()!;
              final jobListItem = await _getJobListItem(jobId, jobDate);

              if (jobListItem != null) {
                final numberOfCleaners =
                    (jobListItem['manDays'] as num?)?.ceil() ?? 1;
                final currentNumberOfTeamMembers =
                    existingData['numberOfTeamMembers'] as int?;

                if (currentNumberOfTeamMembers != numberOfCleaners) {
                  await _firestore
                      .collection('happySunProjects')
                      .doc(jobId)
                      .update({
                    'numberOfTeamMembers': numberOfCleaners,
                    'updatedAt': FieldValue.serverTimestamp(),
                  });
                  projectsUpdated++;
                  debugPrint(
                      'Updated project $jobId with $numberOfCleaners team members');
                }
              }
              continue;
            }

            // Fetch details from job list
            final jobListItem = await _getJobListItem(jobId, jobDate);

            if (jobListItem == null) {
              debugPrint(
                  'Warning: Could not find job list item for job $jobId');
              errors++;
              continue;
            }

            // Extract data with fallbacks
            final clientName =
                jobListItem['client'] as String? ?? 'Unknown Client';
            final address = (jobListItem['collectionAddress'] as String?) ??
                (jobListItem['area'] as String?) ??
                'Unknown Address';
            final numberOfCleaners =
                (jobListItem['manDays'] as num?)?.ceil() ?? 1;

            // Create project document
            final projectData = {
              'id': jobId,
              'clientName': clientName,
              'address': address,
              'scheduledDate': Timestamp.fromDate(jobDate),
              'numberOfTeamMembers': numberOfCleaners,
              'status': 'pending',
              'createdAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            };

            await _firestore
                .collection('happySunProjects')
                .doc(jobId)
                .set(projectData);
            projectsCreated++;
            debugPrint(
                'Created project for job $jobId: $clientName ($numberOfCleaners team members)');
          } catch (e) {
            errors++;
            debugPrint('Error processing job: $e');
          }
        }
      }

      debugPrint('\nMigration complete!');
      debugPrint('Jobs processed: $jobsProcessed');
      debugPrint('Projects created: $projectsCreated');
      debugPrint('Projects updated: $projectsUpdated');
      debugPrint('Errors: $errors');

      return {
        'jobsProcessed': jobsProcessed,
        'projectsCreated': projectsCreated,
        'projectsUpdated': projectsUpdated,
        'errors': errors,
      };
    } catch (e) {
      debugPrint('Migration failed: $e');
      rethrow;
    }
  }

  /// Fetches a job list item for the given job ID and date
  Future<Map<String, dynamic>?> _getJobListItem(
      String jobId, DateTime date) async {
    try {
      // Format: YYYY-MM
      final monthId = '${date.year}-${date.month.toString().padLeft(2, '0')}';
      // Format: DD
      final day = date.day.toString().padLeft(2, '0');

      final dailyDoc = await _firestore
          .collection('schedule')
          .doc('daily')
          .collection(monthId)
          .doc(day)
          .get();

      if (!dailyDoc.exists) {
        return null;
      }

      final jobs = dailyDoc.data()?['jobs'] as List<dynamic>? ?? [];
      final jobData = jobs.firstWhere(
        (job) => job['id'] == jobId,
        orElse: () => <String, dynamic>{},
      ) as Map<String, dynamic>;

      return jobData.isEmpty ? null : jobData;
    } catch (e) {
      debugPrint('Error fetching job list item: $e');
      return null;
    }
  }
}
