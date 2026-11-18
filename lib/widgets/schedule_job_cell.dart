import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/job.dart';
import '../models/distributor.dart';
import '../providers/day_off_provider.dart';
import '../providers/distribution_lag_provider.dart';
import '../providers/schedule_provider.dart';
import '../providers/unfinished_work_areas_provider.dart';
import '../providers/scale_provider.dart';
import '../providers/schedule_selection_provider.dart';
import '../utils/distribution_lag.dart';
import '../utils/grid_drag_auto_scroll.dart';
import '../utils/schedule_job_merge.dart';
import 'job_card.dart';
import 'schedule_batch_drop.dart';
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

  /// Shown when a drag/drop refers to a job that no longer exists in the
  /// provider (deleted or moved by another user while the gesture was in
  /// flight). Aborting instead of falling back to the stale copy prevents
  /// deleted jobs from being re-written to Firestore.
  static void _showJobGoneSnackBar(BuildContext context) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showToast(
      const SnackBar(
        content: Text('Job no longer exists — it was changed or deleted'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

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
        // Cell already has a job — combine the unfinished item into it.
        // Must be fresh from the provider; a stale copy could resurrect a
        // deleted job.
        final targetJob = scheduleProvider.jobs
            .where((j) => j.id == jobs.first.id)
            .firstOrNull;
        if (targetJob == null) {
          _showJobGoneSnackBar(context);
          return;
        }

        final combinedJob = mergeScheduleJobs(
          target: targetJob,
          incoming: unfinishedItem,
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
          ScaffoldMessenger.of(context).showToast(
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
        ScaffoldMessenger.of(context).showToast(
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
        ScaffoldMessenger.of(context).showToast(
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

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final scaleProvider = ref.read(scaleRiverpod);
    // select: a days-off change rebuilds only the cells whose answer changed,
    // not the whole grid.
    final isDayOff = ref.watch(
        dayOffRiverpod.select((p) => p.isDayOff(distributor.id, date)));
    // Worst lag behind the Job List date over every job in this cell; the
    // select keeps cells from rebuilding unless their own lag changes.
    final lag =
        ref.watch(distributionLagRiverpod.select((p) => p.lagForJobs(jobs)));

    // A multi-job selection dropped here moves from this date onwards,
    // each job to the first free distributor.
    return DragTarget<ScheduleJobsDrag>(
      onAcceptWithDetails: (details) =>
          dropJobsOnDate(context, ref, details.data, date),
      builder: (context, candidates, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border.all(color: Colors.blue.shade600, width: 2),
        ),
        child: DragTarget<Job>(
          onAcceptWithDetails: (jobDetails) async {
            // A drop ends selecting.
            ref.read(scheduleSelectionRiverpod).setSelectMode(false);
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

            final draggedJob = scheduleProvider.jobs
                .where((j) => j.id == draggedJobId)
                .firstOrNull;
            if (draggedJob == null) {
              // The dragged job vanished mid-gesture (deleted/moved elsewhere).
              _showJobGoneSnackBar(context);
              return;
            }

            // Check if dropping on the same day and distributor (no changes)
            final isSameDayAndDistributor =
                draggedJob.distributorId == distributor.id &&
                    draggedJob.date.year == date.year &&
                    draggedJob.date.month == date.month &&
                    draggedJob.date.day == date.day;

            if (isSameDayAndDistributor) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showToast(
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
                final staleTargetJob = scheduleProvider.jobs
                    .where((j) => j.id == jobs.first.id)
                    .firstOrNull;
                if (staleTargetJob == null) {
                  _showJobGoneSnackBar(context);
                  return;
                }

                // Show confirmation dialog
                if (!context.mounted) return;
                final action = await showDialog<DropAction>(
                  context: context,
                  builder: (context) => JobDropConfirmationDialog(
                    draggedJob: draggedJob,
                    targetJob: staleTargetJob,
                    distributorName: distributor.name,
                    targetDate: date,
                  ),
                );

                if (action == null) return; // User cancelled

                // Re-validate after the dialog's async gap — the stream may have
                // removed or changed either job while the dialog was open.
                final freshDragged = scheduleProvider.jobs
                    .where((j) => j.id == draggedJob.id)
                    .firstOrNull;
                final targetJob = scheduleProvider.jobs
                    .where((j) => j.id == staleTargetJob.id)
                    .firstOrNull;
                if (freshDragged == null || targetJob == null) {
                  if (context.mounted) _showJobGoneSnackBar(context);
                  return;
                }
                final confirmedDraggedJob = freshDragged;

                if (action == DropAction.swap) {
                  await scheduleProvider.swapJobsWithUndo(
                    confirmedDraggedJob,
                    targetJob,
                    date,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showToast(
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
                  final combinedJob = mergeScheduleJobs(
                    target: targetJob,
                    incoming: confirmedDraggedJob,
                  );

                  await scheduleProvider.combineJobsWithUndo(
                    confirmedDraggedJob,
                    targetJob,
                    combinedJob,
                    date,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showToast(
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
                  final combinedJob = mergeScheduleJobs(
                    target: targetJob,
                    incoming: confirmedDraggedJob,
                  );

                  await scheduleProvider.copyAndCombineJobsWithUndo(
                    targetJob,
                    combinedJob,
                    date,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showToast(
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
                ScaffoldMessenger.of(context).showToast(
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
            final card = Card(
              color: candidateData.isNotEmpty
                  ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
                  : null,
              child: jobs.isEmpty
                  ? _AddJobButton(
                      distributor: distributor,
                      date: date,
                      scaleProvider: scaleProvider,
                    )
                  : _buildCellContent(lag == null ? null : _lagColor(lag.$1)),
            );
            if (lag == null) return card;
            // Manual trigger: hover still shows it on web, but a long press
            // stays free for dragging the job.
            return Tooltip(
              message: _lagMessage(lag.$2),
              triggerMode: TooltipTriggerMode.manual,
              child: card,
            );
          },
        ),
      ),
    );
  }

  static Color _lagColor(DistributionLag lag) => switch (lag) {
        DistributionLag.onTime => Colors.green.shade600,
        DistributionLag.late => Colors.orange.shade700,
        DistributionLag.overdue => Colors.red.shade700,
      };

  static String _lagMessage(JobLag lag) {
    final days = lag.days;
    final when = days == 0
        ? 'on'
        : '${days.abs()} ${days.abs() == 1 ? 'day' : 'days'} '
            '${days > 0 ? 'after' : 'before'}';
    return '${lag.client}: $when its Job List date '
        '(${DateFormat('d MMM').format(lag.listDate)})';
  }

  /// Cell body. A single job fills the cell (unchanged behaviour); a cell
  /// holding more than one job splits vertically into one independently
  /// draggable card per job, so no job is hidden and each can be moved on its
  /// own. Each card is clipped to its slot to avoid overflow paint.
  /// [borderColor] is the cell's worst lag, drawn on every card in it.
  Widget _buildCellContent(Color? borderColor) {
    if (jobs.length == 1) return _buildDraggableJob(jobs.first, borderColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final job in jobs)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: ClipRect(child: _buildDraggableJob(job, borderColor)),
            ),
          ),
      ],
    );
  }

  /// One job rendered as a draggable card. Its drag carries the whole
  /// selection when the job is part of a multi-job selection.
  Widget _buildDraggableJob(Job job, Color? borderColor) => _SelectableJob(
        job: job,
        borderColor: borderColor,
        cellWidth: cellWidth,
        rowHeight: rowHeight,
        isFullscreen: isFullscreen,
      );
}

/// A schedule job card that can be selected for a multi-job move and dragged.
///
/// While selecting (the "Select" toggle, or Ctrl / ⌘ / Shift held) a click
/// toggles the job instead of reaching the card's own controls, and a drag
/// starts straight away; otherwise a long press starts the drag as before.
class _SelectableJob extends riverpod.ConsumerWidget {
  /// Shift-click selects the range from the last clicked job; any other
  /// click (plain, Ctrl, ⌘) toggles just this job.
  void _onSelectTap(riverpod.WidgetRef ref) {
    final selection = ref.read(scheduleSelectionRiverpod);
    if (!HardwareKeyboard.instance.isShiftPressed) {
      selection.toggle(job.id,
          distributorId: job.distributorId, date: job.date);
      return;
    }
    final schedule = ref.read(scheduleRiverpod);
    selection.selectRangeTo(
      job.id,
      distributorId: job.distributorId,
      date: job.date,
      rowOrder: [for (final d in schedule.gridDistributors) d.id],
      jobsIn: (distributorId, date) => schedule
          .getJobsForDistributorAndDate(distributorId, date)
          .map((j) => j.id),
    );
  }

  final Job job;
  final Color? borderColor;
  final double cellWidth;
  final double rowHeight;
  final bool isFullscreen;

  const _SelectableJob({
    required this.job,
    required this.borderColor,
    required this.cellWidth,
    required this.rowHeight,
    required this.isFullscreen,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final selected =
        ref.watch(scheduleSelectionRiverpod.select((s) => s.contains(job.id)));
    // Rebuild a selected card on every selection change, so the payload
    // below is the full current selection when a drag starts.
    ref.watch(scheduleSelectionRiverpod
        .select((s) => s.contains(job.id) ? s.version : -1));
    final selecting =
        ref.watch(scheduleSelectionRiverpod.select((s) => s.isSelecting));
    final selection = ref.read(scheduleSelectionRiverpod);

    // Dragging a selected job moves the whole selection.
    final dragCount = selected ? selection.count : 1;
    final Object data =
        dragCount > 1 ? ScheduleJobsDrag(selection.ids.toList()) : job;

    Widget card({double opacity = 1}) => Opacity(
          opacity: opacity,
          child: JobCard(
            job: job,
            isFullscreen: isFullscreen,
            borderColor: borderColor,
          ),
        );

    final feedback = Material(
      elevation: 8.0,
      color: Colors.transparent,
      child: SizedBox(
        width: cellWidth - 8,
        height: rowHeight - 8,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: card(opacity: 0.7)),
            if (dragCount > 1)
              Positioned(
                top: -8,
                right: -8,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: Colors.blue.shade700,
                  child: Text(
                    '$dragCount',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    final child = Stack(
      children: [
        Positioned.fill(child: card()),
        if (selected)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.18),
                  border: Border.all(color: Colors.blue.shade700, width: 2.5),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        if (selecting)
          Positioned.fill(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _onSelectTap(ref),
              ),
            ),
          ),
      ],
    );
    final whenDragging =
        selected ? card(opacity: 0.2) : Opacity(opacity: 0.2, child: child);

    // One widget type in both modes, with only the delay changing. Swapping
    // between Draggable and LongPressDraggable remounted the JobCard whenever
    // selection mode toggled, disposing the state an open card dialog (the
    // client list) was about to save into — so its Save did nothing.
    return LongPressDraggable<Object>(
      data: data,
      delay: selecting ? Duration.zero : const Duration(milliseconds: 250),
      hapticFeedbackOnStart: !selecting,
      feedback: feedback,
      childWhenDragging: whenDragging,
      onDragStarted: GridDragAutoScroll.start,
      onDragUpdate: (details) =>
          GridDragAutoScroll.update(details.globalPosition),
      onDragEnd: (_) => GridDragAutoScroll.end(),
      child: child,
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

  Future<void> _addJob() async {
    if (_isAddingJob) return;
    // Captured now: the new job shows at once, which replaces this empty
    // cell (and this widget) long before the save finishes or fails.
    final messenger = ScaffoldMessenger.of(context);
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
      messenger.showToast(
        SnackBar(
          content: Text('Failed to add job: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _isAddingJob = false);
    }
  }

  /// No spinner: [DayOffProvider] shows the day as off straight away and
  /// saves it behind. Marking twice is harmless (arrayUnion).
  Future<void> _markDayOff() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(dayOffRiverpod)
          .markDayOff(widget.distributor.id, widget.date);
    } catch (e) {
      messenger.showToast(
        SnackBar(
          content: Text('Failed to mark day off: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.scaleProvider.mediumIconSize;

    if (_isAddingJob) {
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
  /// [DayOffProvider] clears the day at once and saves behind — no spinner,
  /// the cell turns back into an empty one straight away. This card is gone
  /// by the time the save finishes, so the messenger is captured first.
  Future<void> _removeDayOff() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(dayOffRiverpod)
          .removeDayOff(widget.distributor.id, widget.date);
    } catch (e) {
      messenger.showToast(
        SnackBar(
          content: Text('Failed to remove day off: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaleProvider = ref.read(scaleRiverpod);

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
                  GestureDetector(
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_busy,
                  color: Colors.white70, size: scaleProvider.smallIconSize),
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
