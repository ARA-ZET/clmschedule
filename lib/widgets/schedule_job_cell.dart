import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/job.dart';
import '../models/custom_polygon.dart';
import '../models/distributor.dart';
import '../providers/day_off_provider.dart';
import '../providers/schedule_provider.dart';
import '../providers/unfinished_work_areas_provider.dart';
import '../providers/scale_provider.dart';
import 'job_card.dart';
import 'job_drop_confirmation_dialog.dart';

/// Isolated widget for a single schedule grid cell
/// Only rebuilds when its specific cell data changes
class ScheduleJobCell extends riverpod.ConsumerWidget {
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

  /// Handles a drop from the unfinished work areas panel into this cell.
  Future<void> _handleUnfinishedDrop(
    BuildContext context,
    riverpod.WidgetRef ref,
    Job unfinishedItem,
    ScheduleProvider scheduleProvider,
  ) async {
    try {
      final unfinishedProvider = ref.read(unfinishedWorkAreasRiverpod);

      // Step 1: Add to schedule (destination) first
      if (jobs.isNotEmpty) {
        // Cell already has a job — combine the unfinished item into it
        final targetJob = scheduleProvider.jobs.firstWhere(
          (j) => j.id == jobs.first.id,
          orElse: () => jobs.first,
        );

        final combinedJob = _mergeScheduleJobs(
          targetJob: targetJob,
          incomingJob: unfinishedItem,
        );

        await scheduleProvider.updateJobWithUndo(targetJob, combinedJob, date);
      } else {
        // Empty cell — create a new job assigned to this distributor/date
        final newJob = Job(
          id: '', // Will be set by Firestore
          clients: unfinishedItem.clients,
          workingAreas: unfinishedItem.workingAreas,
          workMaps: unfinishedItem.workMaps,
          distributorId: distributor.id,
          date: date,
          statusId: unfinishedItem.statusId,
          dropOffPoint: unfinishedItem.dropOffPoint,
        );
        await scheduleProvider.addJobWithUndo(newJob, date);
      }

      // Step 2: Remove from source only after destination write succeeded
      try {
        await unfinishedProvider.removeItem(unfinishedItem.id);
      } catch (removeError) {
        // Add succeeded but remove failed — duplicate (recoverable)
        debugPrint(
            'Warning: Job assigned to schedule but failed to remove from unfinished: $removeError');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                  'Job assigned but may still appear in unfinished list. Please remove it manually if so.'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Expanded(child: Text('Assigned to schedule')),
              ],
            ),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      // Add to schedule failed — nothing removed, no data loss
      debugPrint('Unfinished drop failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to assign: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Merge two lists of string tokens, deduplicating case-insensitively while
  /// preserving the casing of the first occurrence. Empty / whitespace-only
  /// entries are dropped.
  static List<String> _mergeStringsPreserveCase(
    List<String> a,
    List<String> b,
  ) {
    final seen = <String>{};
    final out = <String>[];
    for (final v in [...a, ...b]) {
      final trimmed = v.trim();
      if (trimmed.isEmpty) continue;
      final key = trimmed.toLowerCase();
      if (seen.add(key)) out.add(trimmed);
    }
    return out;
  }

  /// Merge two schedule jobs without dropping instructions or access notes.
  static Job _mergeScheduleJobs({
    required Job targetJob,
    required Job incomingJob,
  }) {
    final combinedClients = _mergeStringsPreserveCase(
      targetJob.clients,
      incomingJob.clients,
    );
    final combinedClientInstructions = _mergeStringsPreserveCase(
      targetJob.clientInstructions,
      incomingJob.clientInstructions,
    );
    final combinedWorkingAreas = _mergeStringsPreserveCase(
      targetJob.workingAreas,
      incomingJob.workingAreas,
    );
    final combinedWorkMaps = _mergeWorkMaps(
      targetJob.workMaps,
      incomingJob.workMaps,
    );

    return targetJob.copyWith(
      clients: combinedClients,
      clientInstructions: combinedClientInstructions,
      workingAreas: combinedWorkingAreas,
      workMaps: combinedWorkMaps,
      mapInstructions: _mergeTextBlocks(
        targetJob.mapInstructions,
        incomingJob.mapInstructions,
      ),
      dropOffPoint: targetJob.dropOffPoint ?? incomingJob.dropOffPoint,
      pickUpPoint: targetJob.pickUpPoint ?? incomingJob.pickUpPoint,
    );
  }

  /// Combine two free-form instruction blocks without losing either side.
  static String _mergeTextBlocks(String a, String b) {
    final lines = <String>[];
    for (final value in [a, b]) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) continue;
      if (!lines.contains(trimmed)) lines.add(trimmed);
    }
    return lines.join('\n');
  }

  /// Merge two polygon/work-map lists. The [target] list keeps priority.
  ///
  /// Incoming polygons whose `(type, name)` collides with an entry already
  /// present get their name suffixed so no data is lost:
  ///   * first collision  → `"<name> gap"`
  ///   * further collisions → `"<name> gap1"`, `"<name> gap2"`, … (cumulative)
  ///
  /// Unnamed polygons are always appended as-is (no reliable way to
  /// deduplicate geometry by name).
  static List<CustomPolygon> _mergeWorkMaps(
    List<CustomPolygon> target,
    List<CustomPolygon> incoming,
  ) {
    String keyFor(String type, String name) => '$type::${name.trim()}';

    // Seed the "used keys" set with everything already in the target.
    final used = <String>{};
    for (final p in target) {
      final n = p.name.trim();
      if (n.isNotEmpty) used.add(keyFor(p.type.toString(), n));
    }

    final merged = <CustomPolygon>[...target];
    for (final p in incoming) {
      final originalName = p.name.trim();
      if (originalName.isEmpty) {
        merged.add(p); // unnamed: keep, cannot dedupe safely
        continue;
      }

      final typeStr = p.type.toString();
      final originalKey = keyFor(typeStr, originalName);
      if (used.add(originalKey)) {
        merged.add(p);
        continue;
      }

      // Collision — find next free "<name> gap" / "<name> gapN" suffix.
      String candidate = '$originalName gap';
      if (used.contains(keyFor(typeStr, candidate))) {
        var n = 1;
        while (used.contains(keyFor(typeStr, '$originalName gap$n'))) {
          n++;
        }
        candidate = '$originalName gap$n';
      }
      used.add(keyFor(typeStr, candidate));
      merged.add(p.copyWith(name: candidate));
    }
    return merged;
  }

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final scaleProvider = ref.read(scaleRiverpod);
    final isDayOff = ref.watch(dayOffRiverpod).isDayOff(distributor.id, date);

    return DragTarget<Job>(
      onAcceptWithDetails: (jobDetails) async {
        // Get the dragged job - fetch fresh data from provider
        final draggedJobId = jobDetails.data.id;

        // Get fresh job data from provider to avoid stale state
        final scheduleProvider = ref.read(scheduleRiverpod);

        // Check if this is an unfinished work area item (no distributorId)
        final isFromUnfinishedPanel = jobDetails.data.distributorId.isEmpty;

        if (isFromUnfinishedPanel) {
          await _handleUnfinishedDrop(
            context,
            ref,
            jobDetails.data,
            scheduleProvider,
          );
          return;
        }

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
              final combinedJob = _mergeScheduleJobs(
                targetJob: targetJob,
                incomingJob: draggedJob,
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
              final combinedJob = _mergeScheduleJobs(
                targetJob: targetJob,
                incomingJob: draggedJob,
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
      onWillAcceptWithDetails: (job) => !isDayOff,
      builder: (context, candidateData, rejectedData) {
        if (isDayOff) {
          return _DayOffCard(
            distributor: distributor,
            date: date,
            isFullscreen: isFullscreen,
          );
        }
        return Card(
          color: candidateData.isNotEmpty
              ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
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

/// Button widget for adding a new job to an empty cell.
/// Also shows a day-off toggle button alongside the add button.
class _AddJobButton extends riverpod.ConsumerStatefulWidget {
  final Distributor distributor;
  final DateTime date;
  final ScaleProvider scaleProvider;

  const _AddJobButton({
    required this.distributor,
    required this.date,
    required this.scaleProvider,
  });

  @override
  riverpod.ConsumerState<_AddJobButton> createState() => _AddJobButtonState();
}

class _AddJobButtonState extends riverpod.ConsumerState<_AddJobButton> {
  bool _isAddingJob = false;
  bool _isMarkingDayOff = false;

  Future<void> _addJob() async {
    if (_isAddingJob) return;
    setState(() => _isAddingJob = true);
    try {
      final newJob = Job(
        id: '',
        clients: [],
        workingAreas: [],
        workMaps: [],
        distributorId: widget.distributor.id,
        date: widget.date,
        statusId: 'scheduled',
      );
      if (mounted) {
        await riverpod.ProviderScope.containerOf(context)
            .read(scheduleRiverpod)
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
      if (mounted) setState(() => _isAddingJob = false);
    }
  }

  Future<void> _markDayOff() async {
    if (_isMarkingDayOff) return;
    setState(() => _isMarkingDayOff = true);
    try {
      await ref
          .read(dayOffRiverpod)
          .markDayOff(widget.distributor.id, widget.date);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to mark day off: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isMarkingDayOff = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.scaleProvider.mediumIconSize;

    if (_isAddingJob || _isMarkingDayOff) {
      return Center(
        child: SizedBox(
          width: iconSize,
          height: iconSize,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(
              Theme.of(context).primaryColor,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(Icons.add, size: iconSize),
          tooltip: 'Add new job',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: _addJob,
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(Icons.event_busy,
              size: iconSize - 2, color: Colors.blueGrey.shade300),
          tooltip: 'Mark as day off',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: _markDayOff,
        ),
      ],
    );
  }
}

/// Card shown in a schedule cell when a distributor has a day off on that date.
/// Collapsed: icon + "DAY OFF" label.
/// Expanded (isFullscreen): adds "Not available" subtitle and a REMOVE action.
class _DayOffCard extends riverpod.ConsumerStatefulWidget {
  final Distributor distributor;
  final DateTime date;
  final bool isFullscreen;

  const _DayOffCard({
    required this.distributor,
    required this.date,
    required this.isFullscreen,
  });

  @override
  riverpod.ConsumerState<_DayOffCard> createState() => _DayOffCardState();
}

class _DayOffCardState extends riverpod.ConsumerState<_DayOffCard> {
  bool _isLoading = false;

  Future<void> _removeDayOff() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await ref
          .read(dayOffRiverpod)
          .removeDayOff(widget.distributor.id, widget.date);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove day off: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaleProvider = ref.read(scaleRiverpod);

    final loadingIndicator = SizedBox(
      width: 12,
      height: 12,
      child: CircularProgressIndicator(
        strokeWidth: 1.5,
        valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
      ),
    );

    if (widget.isFullscreen) {
      return Card(
        margin: const EdgeInsets.all(1),
        color: Colors.blueGrey,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.event_busy,
                      color: Colors.white70,
                      size: scaleProvider.mediumIconSize),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'DAY OFF',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: scaleProvider.mediumFontSize,
                        letterSpacing: 1,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _isLoading
                      ? loadingIndicator
                      : GestureDetector(
                          onTap: _removeDayOff,
                          child: Text(
                            'REMOVE',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                              fontSize: scaleProvider.smallFontSize,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                ],
              ),
              Container(
                height: 1,
                color: Colors.white24,
                margin: const EdgeInsets.symmetric(vertical: 3),
              ),
              Text(
                'Not available',
                style: TextStyle(
                    color: Colors.white, fontSize: scaleProvider.smallFontSize),
              ),
            ],
          ),
        ),
      );
    }

    // Collapsed view — tap anywhere to remove
    return Card(
      margin: const EdgeInsets.all(1),
      color: Colors.blueGrey.shade800,
      child: InkWell(
        onTap: _removeDayOff,
        borderRadius: BorderRadius.circular(4),
        child: Center(
          child: _isLoading
              ? loadingIndicator
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.event_busy,
                        color: Colors.white70,
                        size: scaleProvider.smallIconSize),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        'DAY OFF',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: scaleProvider.smallFontSize,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
