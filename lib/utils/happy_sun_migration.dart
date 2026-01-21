import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/job_list_item.dart';
import '../models/happy_sun_job.dart';
import '../providers/job_list_provider.dart';
import '../providers/happy_sun_job_provider.dart';

/// Helper function to migrate existing window cleaning jobs to Happy Sun collection
Future<Map<String, dynamic>> migrateWindowCleaningJobsToHappySun({
  required BuildContext context,
  required JobListProvider jobListProvider,
  required HappySunJobProvider happySunJobProvider,
  DateTime? targetMonth,
}) async {
  final now = DateTime.now();
  final month = targetMonth ?? DateTime(now.year, now.month);

  int totalJobs = 0;
  int migratedJobs = 0;
  int skippedJobs = 0;
  int failedJobs = 0;
  List<String> errors = [];

  try {
    // Get all job list items
    final allJobs = jobListProvider.jobListItems;

    // Filter for window cleaning and solar panel cleaning jobs in the target month
    final happySunJobs = allJobs.where((job) {
      final jobMonth = DateTime(job.date.year, job.date.month);
      final targetMonthNorm = DateTime(month.year, month.month);

      return (job.jobType == JobType.windowCleaning ||
              job.jobType == JobType.solarPanelCleaning) &&
          jobMonth == targetMonthNorm;
    }).toList();

    totalJobs = happySunJobs.length;

    print('Found $totalJobs Happy Sun jobs in ${month.year}-${month.month}');

    // Check existing Happy Sun jobs to avoid duplicates
    final existingHappySunJobIds =
        happySunJobProvider.jobs.map((j) => j.id).toSet();

    for (final job in happySunJobs) {
      try {
        // Skip if already exists
        if (existingHappySunJobIds.contains(job.id)) {
          print('Skipping ${job.id} - already exists in Happy Sun collection');
          skippedJobs++;
          continue;
        }

        // Create Happy Sun job with empty tools list (tools can be configured later)
        final success = await happySunJobProvider.createJobFromJobListItem(
          job,
          CategorizedTools(), // Empty tools for migration
        );

        if (success) {
          migratedJobs++;
          print(
              'Migrated job ${job.id} - ${job.client} (${job.jobType.displayName})');
        } else {
          failedJobs++;
          errors.add('Failed to migrate ${job.id} - ${job.client}');
        }
      } catch (e) {
        failedJobs++;
        errors.add('Error migrating ${job.id}: $e');
        print('Error migrating ${job.id}: $e');
      }
    }

    return {
      'success': true,
      'totalJobs': totalJobs,
      'migratedJobs': migratedJobs,
      'skippedJobs': skippedJobs,
      'failedJobs': failedJobs,
      'errors': errors,
      'message':
          'Migration completed: $migratedJobs migrated, $skippedJobs skipped, $failedJobs failed',
    };
  } catch (e) {
    return {
      'success': false,
      'error': e.toString(),
      'message': 'Migration failed: $e',
    };
  }
}

/// Show migration dialog and execute migration
Future<void> showMigrationDialog(BuildContext context) async {
  final jobListProvider = context.read<JobListProvider>();
  final happySunJobProvider = context.read<HappySunJobProvider>();

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Migrate Happy Sun Jobs'),
      content: const Text(
        'This will migrate all window cleaning and solar panel cleaning jobs '
        'from the current month in the Job List to the Happy Sun collection.\n\n'
        'Existing jobs will be skipped.\n\n'
        'Do you want to continue?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Migrate'),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return;

  // Show loading dialog
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const Center(
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Migrating Happy Sun jobs...'),
            ],
          ),
        ),
      ),
    ),
  );

  // Run migration
  final result = await migrateWindowCleaningJobsToHappySun(
    context: context,
    jobListProvider: jobListProvider,
    happySunJobProvider: happySunJobProvider,
  );

  if (!context.mounted) return;

  // Close loading dialog
  Navigator.pop(context);

  // Show result dialog
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        result['success'] ? 'Migration Complete' : 'Migration Failed',
        style: TextStyle(
          color: result['success'] ? Colors.green : Colors.red,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result['message']),
            if (result['success']) ...[
              const SizedBox(height: 16),
              Text('Total Jobs Found: ${result['totalJobs']}'),
              Text('Migrated: ${result['migratedJobs']}'),
              Text('Skipped (already exist): ${result['skippedJobs']}'),
              if (result['failedJobs'] > 0)
                Text('Failed: ${result['failedJobs']}',
                    style: const TextStyle(color: Colors.red)),
              if (result['errors'].isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Errors:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                ...result['errors']
                    .map((e) => Text(e, style: const TextStyle(fontSize: 12))),
              ],
            ] else ...[
              const SizedBox(height: 16),
              Text('Error: ${result['error']}',
                  style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
