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
  final bool isFullscreen;

  const ScheduleJobCell({
    super.key,
    required this.distributor,
    required this.date,
    required this.jobs,
    required this.cellWidth,
    required this.rowHeight,
    required this.isFullscreen,
  });

  @override
  Widget build(BuildContext context) {
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

        // Check if dropping on the same day and distributor (no changes)
        final isSameDayAndDistributor =
            draggedJob.distributorId == distributor.id &&
                draggedJob.date.year == date.year &&
                draggedJob.date.month == date.month &&
                draggedJob.date.day == date.day;

        if (isSameDayAndDistributor) {
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
          return;
        }

        try {
          // If there's already a job in the target cell
          if (jobs.isNotEmpty) {
            // Get fresh target job data from provider to avoid stale state
            final targetJobId = jobs.first.id;
            final targetJob = scheduleProvider.jobs.firstWhere(
              (j) => j.id == targetJobId,
              orElse: () => jobs.first,
            );

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
              await scheduleProvider.swapJobsWithUndo(
                draggedJob,
                targetJob,
                date,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Row(
                      children: [
                        Icon(Icons.swap_horiz, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Jobs swapped'),
                      ],
                    ),
                    backgroundColor: Colors.blue.shade700,
                    duration: const Duration(milliseconds: 1500),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } else if (action == DropAction.addToExisting) {
              final combinedClients = <String>{
                ...targetJob.clients,
                ...draggedJob.clients,
              }.toList();

              final combinedWorkingAreas = <String>{
                ...targetJob.workingAreas,
                ...draggedJob.workingAreas,
              }.toList();

              final combinedWorkMaps = <CustomPolygon>[
                ...targetJob.workMaps,
                ...draggedJob.workMaps,
              ];

              final combinedJob = targetJob.copyWith(
                clients: combinedClients,
                workingAreas: combinedWorkingAreas,
                workMaps: combinedWorkMaps,
              );

              await scheduleProvider.combineJobsWithUndo(
                draggedJob,
                targetJob,
                combinedJob,
                date,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Row(
                      children: [
                        Icon(Icons.merge_type, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Jobs combined'),
                      ],
                    ),
                    backgroundColor: Colors.green.shade700,
                    duration: const Duration(milliseconds: 1500),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } else if (action == DropAction.copy) {
              final combinedClients = <String>{
                ...targetJob.clients,
                ...draggedJob.clients,
              }.toList();

              final combinedWorkingAreas = <String>{
                ...targetJob.workingAreas,
                ...draggedJob.workingAreas,
              }.toList();

              final combinedWorkMaps = <CustomPolygon>[
                ...targetJob.workMaps,
                ...draggedJob.workMaps,
              ];

              final combinedJob = targetJob.copyWith(
                clients: combinedClients,
                workingAreas: combinedWorkingAreas,
                workMaps: combinedWorkMaps,
              );

              await scheduleProvider.copyAndCombineJobsWithUndo(
                targetJob,
                combinedJob,
                date,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Row(
                      children: [
                        Icon(Icons.copy, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Job copied & combined'),
                      ],
                    ),
                    backgroundColor: Colors.purple.shade700,
                    duration: const Duration(milliseconds: 1500),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }
          } else {
            // If target cell is empty, just move the dragged job
            final movedJob = draggedJob.copyWith(
              distributorId: distributor.id,
              date: date,
            );

            await scheduleProvider.updateJobWithUndo(
              draggedJob,
              movedJob,
              date,
            );
          }
        } catch (e) {
          debugPrint('Drag-drop operation failed: $e');
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Operation failed: $e'),
                    ),
                  ],
                ),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
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
                        child: JobCard(
                            job: jobs.first, isFullscreen: isFullscreen),
                      ),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.2,
                    child: JobCard(job: jobs.first, isFullscreen: isFullscreen),
                  ),
                  child: JobCard(job: jobs.first, isFullscreen: isFullscreen),
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
