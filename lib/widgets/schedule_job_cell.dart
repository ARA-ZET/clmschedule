import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/job.dart';
import '../models/custom_polygon.dart';
import '../models/distributor.dart';
import '../providers/schedule_provider.dart';
import '../providers/scale_provider.dart';
import 'job_card.dart';
import 'job_drop_confirmation_dialog.dart';

/// Isolated widget for a single schedule grid cell
/// Only rebuilds when its specific cell data changes
class ScheduleJobCell extends StatelessWidget {
  final Distributor distributor;
  final DateTime date;
  final List<Job> jobs;
  final double cellWidth;
  final double rowHeight;

  const ScheduleJobCell({
    super.key,
    required this.distributor,
    required this.date,
    required this.jobs,
    required this.cellWidth,
    required this.rowHeight,
  });

  @override
  Widget build(BuildContext context) {
    final scheduleProvider = context.read<ScheduleProvider>();
    final scaleProvider = context.read<ScaleProvider>();

    return DragTarget<Job>(
      onAcceptWithDetails: (jobDetails) async {
        // Get the dragged job - fetch fresh data from provider
        final draggedJobId = jobDetails.data.id;

        // Get fresh job data from provider to avoid stale state
        final scheduleProvider = context.read<ScheduleProvider>();
        final draggedJob = scheduleProvider.jobs.firstWhere(
          (j) => j.id == draggedJobId,
          orElse: () => jobDetails.data, // Fallback to original if not found
        );

        // DEBUG: Log dragged job data
        print('=== DRAG AND DROP DEBUG ===');
        print('Dragged Job (FRESH from provider):');
        print('  ID: ${draggedJob.id}');
        print('  StatusId: ${draggedJob.statusId}');
        print('  Clients: ${draggedJob.clients}');
        print('  WorkingAreas: ${draggedJob.workingAreas}');
        print('  WorkMaps count: ${draggedJob.workMaps.length}');
        print('  DistributorId: ${draggedJob.distributorId}');
        print('  Date: ${draggedJob.date}');
        print('Target:');
        print('  DistributorId: ${distributor.id}');
        print('  Distributor Name: ${distributor.name}');
        print('  Date: $date');
        print('===========================');

        // Check if dropping on the same day and distributor (no changes)
        final isSameDayAndDistributor =
            draggedJob.distributorId == distributor.id &&
                draggedJob.date.year == date.year &&
                draggedJob.date.month == date.month &&
                draggedJob.date.day == date.day;

        if (isSameDayAndDistributor) {
          // Show feedback that no changes will be made
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Job is already on ${DateFormat('EEE, MMM d').format(date)} for ${distributor.name}',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return; // Exit early, no changes needed
        }

        // If there's already a job in the target cell
        if (jobs.isNotEmpty) {
          // Get fresh target job data from provider to avoid stale state
          final targetJobId = jobs.first.id;
          final targetJob = scheduleProvider.jobs.firstWhere(
            (j) => j.id == targetJobId,
            orElse: () => jobs.first,
          );

          print('=== TARGET JOB (FRESH) ===');
          print('  ID: ${targetJob.id}');
          print('  Clients: ${targetJob.clients}');
          print('  WorkingAreas: ${targetJob.workingAreas}');
          print('  WorkMaps: ${targetJob.workMaps.length}');
          print('==========================');

          // Show confirmation dialog
          final action = await showDialog<DropAction>(
            context: context,
            builder: (context) => JobDropConfirmationDialog(
              draggedJob: draggedJob,
              targetJob: targetJob,
              distributorName: distributor.name,
              targetDate: date,
            ),
          );

          if (action == null) return; // User cancelled

          if (action == DropAction.swap) {
            // Swap the jobs using undo/redo command
            print('=== SWAP JOBS DEBUG ===');
            print('DraggedJob:');
            print('  Clients: ${draggedJob.clients}');
            print('  WorkMaps: ${draggedJob.workMaps.length}');
            print('TargetJob:');
            print('  Clients: ${targetJob.clients}');
            print('  WorkMaps: ${targetJob.workMaps.length}');
            print('======================');

            await scheduleProvider.swapJobsWithUndo(
              draggedJob,
              targetJob,
              date,
            );
          } else if (action == DropAction.addToExisting) {
            // Combine the jobs - merge clients, working areas, and polygons
            print('=== COMBINE JOBS DEBUG ===');
            print('Before combine - DraggedJob:');
            print('  Clients: ${draggedJob.clients}');
            print('  WorkingAreas: ${draggedJob.workingAreas}');
            print('  WorkMaps: ${draggedJob.workMaps.length}');
            print('Before combine - TargetJob:');
            print('  Clients: ${targetJob.clients}');
            print('  WorkingAreas: ${targetJob.workingAreas}');
            print('  WorkMaps: ${targetJob.workMaps.length}');

            final combinedClients = <String>{
              ...targetJob.clients,
              ...draggedJob.clients,
            }.toList(); // Remove duplicates

            final combinedWorkingAreas = <String>{
              ...targetJob.workingAreas,
              ...draggedJob.workingAreas,
            }.toList(); // Remove duplicates

            // Combine work maps from both jobs
            final combinedWorkMaps = <CustomPolygon>[
              ...targetJob.workMaps,
              ...draggedJob.workMaps,
            ];

            print('After combine:');
            print('  Combined Clients: $combinedClients');
            print('  Combined WorkingAreas: $combinedWorkingAreas');
            print('  Combined WorkMaps count: ${combinedWorkMaps.length}');

            // Create combined job with target job's status preserved
            final combinedJob = targetJob.copyWith(
              clients: combinedClients,
              workingAreas: combinedWorkingAreas,
              workMaps: combinedWorkMaps,
            );

            print('CombinedJob after copyWith:');
            print('  Clients: ${combinedJob.clients}');
            print('  WorkingAreas: ${combinedJob.workingAreas}');
            print('  WorkMaps: ${combinedJob.workMaps.length}');
            print('=========================');

            // Use undo/redo command for combine operation
            await scheduleProvider.combineJobsWithUndo(
              draggedJob,
              targetJob,
              combinedJob,
              date,
            );
          } else if (action == DropAction.copy) {
            // Copy & Combine - preserve source job, create combined job at target
            print('=== COPY & COMBINE DEBUG ===');
            print('Before combine - DraggedJob:');
            print('  ID: ${draggedJob.id}');
            print('  Clients: ${draggedJob.clients}');
            print('  WorkingAreas: ${draggedJob.workingAreas}');
            print('  WorkMaps: ${draggedJob.workMaps.length}');
            print('Before combine - TargetJob:');
            print('  ID: ${targetJob.id}');
            print('  Clients: ${targetJob.clients}');
            print('  WorkingAreas: ${targetJob.workingAreas}');
            print('  WorkMaps: ${targetJob.workMaps.length}');

            final combinedClients = <String>{
              ...targetJob.clients,
              ...draggedJob.clients,
            }.toList(); // Remove duplicates

            final combinedWorkingAreas = <String>{
              ...targetJob.workingAreas,
              ...draggedJob.workingAreas,
            }.toList(); // Remove duplicates

            // Combine work maps from both jobs
            final combinedWorkMaps = <CustomPolygon>[
              ...targetJob.workMaps,
              ...draggedJob.workMaps,
            ];

            print('After combining arrays:');
            print('  Combined Clients: $combinedClients');
            print('  Combined WorkingAreas: $combinedWorkingAreas');
            print('  Combined WorkMaps count: ${combinedWorkMaps.length}');

            // Create combined job with target job's status preserved
            final combinedJob = targetJob.copyWith(
              clients: combinedClients,
              workingAreas: combinedWorkingAreas,
              workMaps: combinedWorkMaps,
            );

            print('CombinedJob after copyWith:');
            print('  ID: ${combinedJob.id}');
            print('  Clients: ${combinedJob.clients}');
            print('  WorkingAreas: ${combinedJob.workingAreas}');
            print('  WorkMaps: ${combinedJob.workMaps.length}');
            print('============================');

            // Use undo/redo command for copy & combine operation
            await scheduleProvider.copyAndCombineJobsWithUndo(
              targetJob,
              combinedJob,
              date,
            );
          }
        } else {
          // If target cell is empty, just move the dragged job
          print('=== SIMPLE MOVE DEBUG ===');
          print('Original draggedJob before copyWith:');
          print('  ID: ${draggedJob.id}');
          print('  Clients: ${draggedJob.clients}');
          print('  WorkingAreas: ${draggedJob.workingAreas}');
          print('  WorkMaps count: ${draggedJob.workMaps.length}');

          final movedJob = draggedJob.copyWith(
            distributorId: distributor.id,
            date: date,
          );

          print('After copyWith - movedJob:');
          print('  ID: ${movedJob.id}');
          print('  Clients: ${movedJob.clients}');
          print('  WorkingAreas: ${movedJob.workingAreas}');
          print('  WorkMaps count: ${movedJob.workMaps.length}');
          print('  DistributorId: ${movedJob.distributorId}');
          print('  Date: ${movedJob.date}');
          print('========================');

          // Use undo/redo command for simple move operation
          await scheduleProvider.updateJobWithUndo(
            draggedJob,
            movedJob,
            date,
          );
        }
      },
      onWillAcceptWithDetails: (job) => true,
      builder: (context, candidateData, rejectedData) {
        return Card(
          color: candidateData.isNotEmpty
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : null,
          child: jobs.isEmpty
              ? _AddJobButton(
                  distributor: distributor,
                  date: date,
                  scaleProvider: scaleProvider,
                )
              : LongPressDraggable<Job>(
                  data: jobs.first,
                  delay: const Duration(milliseconds: 250),
                  hapticFeedbackOnStart: true,
                  feedback: Material(
                    elevation: 8.0,
                    color: Colors.transparent,
                    child: SizedBox(
                      width: cellWidth - 8,
                      height: rowHeight - 8,
                      child: Opacity(
                        opacity: 0.7,
                        child: JobCard(job: jobs.first),
                      ),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.2,
                    child: JobCard(job: jobs.first),
                  ),
                  child: JobCard(job: jobs.first),
                ),
        );
      },
    );
  }
}

/// Button widget for adding a new job to an empty cell
class _AddJobButton extends StatefulWidget {
  final Distributor distributor;
  final DateTime date;
  final ScaleProvider scaleProvider;

  const _AddJobButton({
    required this.distributor,
    required this.date,
    required this.scaleProvider,
  });

  @override
  State<_AddJobButton> createState() => _AddJobButtonState();
}

class _AddJobButtonState extends State<_AddJobButton> {
  bool _isLoading = false;

  Future<void> _addJob() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final newJob = Job(
        id: '', // Will be set by Firestore
        clients: [],
        workingAreas: [], // Empty names to be selected later
        workMaps: [], // Empty work maps to be added later
        distributorId: widget.distributor.id,
        date: widget.date,
        statusId: 'scheduled', // Use default scheduled status
      );

      if (mounted) {
        await context
            .read<ScheduleProvider>()
            .addJobWithUndo(newJob, newJob.date);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add job: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: _isLoading
          ? SizedBox(
              width: widget.scaleProvider.mediumIconSize,
              height: widget.scaleProvider.mediumIconSize,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).primaryColor,
                ),
              ),
            )
          : IconButton(
              icon: Icon(
                Icons.add,
                size: widget.scaleProvider.mediumIconSize,
              ),
              tooltip: 'Add new job',
              onPressed: _addJob,
            ),
    );
  }
}
