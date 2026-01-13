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
        // Get the dragged job
        final draggedJob = jobDetails.data;

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
          final targetJob = jobs.first;

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
            await scheduleProvider.swapJobsWithUndo(
              draggedJob,
              targetJob,
              date,
            );
          } else if (action == DropAction.addToExisting) {
            // Combine the jobs - merge clients, working areas, and polygons
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

            // Create combined job with target job's status preserved
            final combinedJob = targetJob.copyWith(
              clients: combinedClients,
              workingAreas: combinedWorkingAreas,
              workMaps: combinedWorkMaps,
            );

            // Use undo/redo command for combine operation
            await scheduleProvider.combineJobsWithUndo(
              draggedJob,
              targetJob,
              combinedJob,
              date,
            );
          } else if (action == DropAction.copy) {
            // Copy & Combine - preserve source job, create combined job at target
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

            // Create combined job with target job's status preserved
            final combinedJob = targetJob.copyWith(
              clients: combinedClients,
              workingAreas: combinedWorkingAreas,
              workMaps: combinedWorkMaps,
            );

            // Use undo/redo command for copy & combine operation
            await scheduleProvider.copyAndCombineJobsWithUndo(
              targetJob,
              combinedJob,
              date,
            );
          }
        } else {
          // If target cell is empty, just move the dragged job
          final movedJob = draggedJob.copyWith(
            distributorId: distributor.id,
            date: date,
          );

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
