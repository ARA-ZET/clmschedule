import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/collection_job.dart';
import '../../models/driver.dart';
import '../../models/dropsheet_day.dart';
import '../../models/dropsheet_task.dart';
import '../../models/dropsheet_task_type_config.dart';
import '../../providers/driver_provider.dart';
import '../../providers/dropsheet_provider.dart';
import '../../providers/dropsheet_task_config_provider.dart';
import '../../config/cloud_feature_flags.dart';
import '../../providers/schedule_provider.dart';
import '../../services/dropsheet_route_planner.dart';
import '../../utils/dropsheet_maps.dart';
import '../dropsheet/dropsheet_tab.dart' show TaskDragPayload;
import 'day_planner_palette.dart';

/// Shared per-session state: maps section ID → true when the pick-up view is
/// active for that section. Watched by the map page to filter markers.
final sectionPickUpViewProvider =
    riverpod.StateProvider<Map<String, bool>>((ref) => {});

/// Whether map markers should show their label badges. Toggled from the
/// 'Plan drivers' header and watched by the day-planner map page.
final markerLabelsProvider =
    riverpod.StateProvider<bool>((ref) => true);

/// Compact dropsheet panel used inside the day planner split screen.
///
/// Lists the day's distributor drop-off stops grouped by driver section
/// (plus the synthetic "Unassigned" bucket at the top) and allows the
/// user to drag stops between drivers and reorder within a driver. All
/// changes write through `dropsheetRiverpod` and sync live with the
/// regular dropsheet view.
class DayPlannerPanel extends riverpod.ConsumerStatefulWidget {
  final DateTime date;
  const DayPlannerPanel({super.key, required this.date});

  @override
  riverpod.ConsumerState<DayPlannerPanel> createState() =>
      _DayPlannerPanelState();
}

class _DayPlannerPanelState extends riverpod.ConsumerState<DayPlannerPanel> {
  @override
  void initState() {
    super.initState();
    // Make sure the global dropsheet provider is showing the same date
    // as the planner page. setDate is idempotent if already set.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(dropsheetRiverpod).setDate(widget.date);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dropsheet = ref.watch(dropsheetRiverpod);
    final day = dropsheet.day;
    final isLoading = dropsheet.isLoading && day.sections.isEmpty;

    return Material(
      color: const Color(0xFFF5F5F5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelHeader(
            date: widget.date,
            onAddDriver: () => _showAddDriverDialog(context),
            onSyncFromSchedule: () async {
              await dropsheet.syncFromSchedule();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Synced new stops from schedule.')),
              );
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : _SectionList(day: day, date: widget.date),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddDriverDialog(BuildContext context) async {
    final drivers = ref.read(driverRiverpod);
    final dropsheet = ref.read(dropsheetRiverpod);
    final used = dropsheet.day.sections.map((s) => s.driverId).toSet();
    final available =
        drivers.activeDrivers.where((d) => !used.contains(d.id)).toList();

    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'All active drivers are already on this day. Add more drivers from the Dropsheet tab.'),
        ),
      );
      return;
    }

    Driver? selected = available.first;
    VehicleType? vehicle = selected.defaultVehicle;
    TrailerType? trailer = selected.defaultTrailer ?? TrailerType.noTrailer;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Add driver'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<Driver>(
                  initialValue: selected,
                  decoration: const InputDecoration(labelText: 'Driver'),
                  items: available
                      .map((d) =>
                          DropdownMenuItem(value: d, child: Text(d.name)))
                      .toList(),
                  onChanged: (d) => setState(() {
                    selected = d;
                    vehicle = d?.defaultVehicle;
                    trailer = d?.defaultTrailer ?? TrailerType.noTrailer;
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<VehicleType>(
                  initialValue: vehicle,
                  decoration: const InputDecoration(labelText: 'Vehicle'),
                  items: VehicleType.values
                      .map((v) => DropdownMenuItem(
                          value: v, child: Text(v.displayName)))
                      .toList(),
                  onChanged: (v) => setState(() => vehicle = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<TrailerType>(
                  initialValue: trailer,
                  decoration: const InputDecoration(labelText: 'Trailer'),
                  items: TrailerType.values
                      .map((t) => DropdownMenuItem(
                          value: t, child: Text(t.displayName)))
                      .toList(),
                  onChanged: (t) => setState(() => trailer = t),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ADD'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || selected == null) return;
    await dropsheet.addDriverSection(
      selected!,
      vehicle: vehicle,
      trailer: trailer,
    );
  }
}

class _PanelHeader extends riverpod.ConsumerWidget {
  final DateTime date;
  final VoidCallback onAddDriver;
  final VoidCallback onSyncFromSchedule;

  const _PanelHeader({
    required this.date,
    required this.onAddDriver,
    required this.onSyncFromSchedule,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final showLabels = ref.watch(markerLabelsProvider);
    return Container(
      color: const Color(0xFF202124),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Plan drivers',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Sync new stops from schedule',
            icon: const Icon(Icons.sync, color: Colors.white70),
            onPressed: onSyncFromSchedule,
          ),
          // Marker label toggle.
          Tooltip(
            message: showLabels ? 'Hide labels' : 'Show labels',
            child: GestureDetector(
              onTap: () => ref
                  .read(markerLabelsProvider.notifier)
                  .state = !showLabels,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(
                    horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: showLabels
                      ? const Color(0xFF00897B)
                      : const Color(0xFF424242),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      showLabels ? Icons.label : Icons.label_off,
                      color: Colors.white,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      showLabels ? 'Labels' : 'Numbers',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: onAddDriver,
            icon: const Icon(Icons.person_add, size: 18),
            label: const Text('Add driver'),
          ),
        ],
      ),
    );
  }
}

class _SectionList extends riverpod.ConsumerWidget {
  final DropsheetDay day;
  final DateTime date;
  const _SectionList({required this.day, required this.date});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    // Live job IDs scheduled for this date — distributor stops are only
    // shown if their underlying schedule job still exists.
    final schedule = ref.watch(scheduleRiverpod);
    final jobIds = {
      for (final j in schedule.getJobsForDate(date)) j.id,
    };

    if (day.sections.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No stops scheduled for this day.\nUse "Sync" once jobs are scheduled.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: day.sections.length,
      itemBuilder: (context, i) {
        final section = day.sections[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _PanelSection(
            section: section,
            allSections: day.sections,
            liveJobIds: jobIds,
            date: date,
          ),
        );
      },
    );
  }
}

class _PanelSection extends riverpod.ConsumerStatefulWidget {
  final DropsheetDriverSection section;
  final List<DropsheetDriverSection> allSections;
  final Set<String> liveJobIds;
  final DateTime date;

  const _PanelSection({
    required this.section,
    required this.allSections,
    required this.liveJobIds,
    required this.date,
  });

  @override
  riverpod.ConsumerState<_PanelSection> createState() => _PanelSectionState();
}

class _PanelSectionState extends riverpod.ConsumerState<_PanelSection> {
  bool _optimising = false;
  bool _calculating = false;

  void _setShowPickUp(bool v) {
    ref
        .read(sectionPickUpViewProvider.notifier)
        .update((m) => {...m, widget.section.id: v});
  }

  bool _isDistributorStop(DropsheetTask t) =>
      t.type == DropsheetTaskType.dropOff || t.type == DropsheetTaskType.pickUp;

  /// Tasks that should appear in the planner panel.
  /// Mandatory in-depot tasks (Inspect / Pack / Leave) stay hidden —
  /// they aren't routing stops.
  bool _isVisibleStop(DropsheetTask t) => !t.isMandatory;

  bool _hasLiveJob(DropsheetTask t) {
    final id = t.typeData['distributorJobId'] as String?;
    // Tasks not seeded from the schedule (no jobId) are still shown so
    // user-added stops aren't hidden. Schedule-seeded tasks must point
    // at a job that still exists for the current date.
    return id == null || widget.liveJobIds.contains(id);
  }

  /// Reads the Leave task's startTime for this section, falling back to
  /// the global depot startTime.
  String _leaveTime(DepotConfig depot) {
    try {
      final leave = widget.section.tasks.firstWhere(
          (t) => t.type == DropsheetTaskType.leave &&
              t.typeData['isPickupDivider'] != true &&
              t.startTime.isNotEmpty);
      return leave.startTime;
    } catch (_) {
      return depot.startTime;
    }
  }

  Future<void> _runRoute({required bool optimise}) async {
    if (_optimising || _calculating) return;
    final config = ref.read(dropsheetTaskConfigRiverpod);
    final dropsheet = ref.read(dropsheetRiverpod);
    final messenger = ScaffoldMessenger.of(context);

    if (config.depot.lat == null || config.depot.lng == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
              'Office is not yet geocoded. Open Task manager and save the office address first.'),
        ),
      );
      return;
    }

    if (optimise) {
      setState(() => _optimising = true);
    } else {
      setState(() => _calculating = true);
    }

    final leaveTime = _leaveTime(config.depot);
    debugPrint('[DayPlanner] ${optimise ? 'optimise' : 'calculate'} '
        'section=${widget.section.id} '
        'tasks=${widget.section.tasks.where((t) => !t.isMandatory).length} '
        'leaveTime=$leaveTime');
    try {
      final planner = DropsheetRoutePlanner(
        config: config,
        useCloud: CloudFeatureFlags.useCloudRouteOptimizer,
      );
      final route = optimise
          ? await planner.optimizeSection(
              section: widget.section,
              depot: config.depot,
              baseDate: widget.date,
              startTime: leaveTime,
            )
          : await planner.calculateInPlace(
              section: widget.section,
              depot: config.depot,
              baseDate: widget.date,
              startTime: leaveTime,
            );

      if (!mounted) return;
      if (route == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
                'No routable stops in this section (need geocoded addresses).'),
          ),
        );
        return;
      }

      final legByKey = <String, Map<String, dynamic>>{};
      route.legBeforeStop.forEach((key, leg) {
        legByKey[key] = {
          'distanceMeters': leg.distanceMeters,
          'durationSeconds': leg.durationSeconds,
        };
      });

      await dropsheet.applyOptimizedRoute(
        sectionId: widget.section.id,
        taskOrder: route.taskOrder,
        arrivalByTaskKey: route.arrivalTimes,
        legByTaskKey: legByKey,
        polyline: route.fullPolyline,
        totalDistanceMeters: route.totalDistanceMeters,
        totalDurationSeconds: route.totalDurationSeconds,
      );

      if (!mounted) return;
      final verb = optimise ? 'optimised' : 'calculated';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Route $verb: ${route.taskOrder.length} stops · '
            '${(route.totalDistanceMeters / 1000).toStringAsFixed(1)} km · '
            '${(route.totalDurationSeconds / 60).round()} min'
            '${route.skippedTaskIds.isEmpty ? '' : ' (${route.skippedTaskIds.length} skipped — missing coords)'}',
          ),
        ),
      );
    } catch (e, st) {
      debugPrint('[DayPlanner] route FAILED: $e\n$st');
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Route calculation failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _optimising = false;
          _calculating = false;
        });
      }
    }
  }

  Future<void> _optimiseRoute() => _runRoute(optimise: true);
  Future<void> _calculateRoute() => _runRoute(optimise: false);

  @override
  Widget build(BuildContext context) {
    final dropsheet = ref.watch(dropsheetRiverpod);
    final config = ref.watch(dropsheetTaskConfigRiverpod);
    final pickUpViewMap = ref.watch(sectionPickUpViewProvider);
    final color = colorForSection(widget.section.id, widget.allSections);
    final isUnassigned = widget.section.id == kUnassignedSectionId;
    final section = widget.section;
    final showPickUp = pickUpViewMap[section.id] ?? false;

    // Leave task — shown as the departure row above numbered stops.
    final leaveTask = isUnassigned
        ? null
        : section.tasks
            .where((t) =>
                t.type == DropsheetTaskType.leave &&
                t.typeData['isPickupDivider'] != true)
            .firstOrNull;

    // Filtered visible stops, but we still need their absolute index in
    // `section.tasks` for `moveTask` calls.
    final stops = <_StopEntry>[];
    for (var i = 0; i < section.tasks.length; i++) {
      final t = section.tasks[i];
      if (!_isVisibleStop(t)) continue;
      // Distributor stops still respect the "live job" filter so deleted
      // schedule jobs disappear from the planner.
      if (_isDistributorStop(t) && !_hasLiveJob(t)) continue;
      stops.add(_StopEntry(task: t, absoluteIndex: i, order: stops.length + 1));
    }

    // Show the drop-off/pick-up toggle only for non-Unassigned sections that
    // contain at least one pick-up task.
    final hasPickUp = !isUnassigned &&
        stops.any((e) => e.task.type == DropsheetTaskType.pickUp);

    // Build the view-filtered list with sequential order numbers.
    final viewStops = <_StopEntry>[];
    for (final entry in stops) {
      if (hasPickUp) {
        final isPickUp = entry.task.type == DropsheetTaskType.pickUp;
        if (showPickUp && !isPickUp) continue;
        if (!showPickUp && isPickUp) continue;
      }
      viewStops.add(_StopEntry(
        task: entry.task,
        absoluteIndex: entry.absoluteIndex,
        order: viewStops.length + 1,
      ));
    }

    return DragTarget<TaskDragPayload>(
      onWillAcceptWithDetails: (d) => d.data.fromSectionId != section.id,
      onAcceptWithDetails: (d) {
        // Append at end of visible stops within this section.
        final destAbs =
            stops.isEmpty ? section.tasks.length : stops.last.absoluteIndex + 1;
        // Defer the mutation so we don't notify listeners while the
        // ReorderableListView / DragTarget machinery is still laying
        // out (which would mutate a LayoutBuilder mid-layout).
        Future.microtask(() => dropsheet.moveTask(
              fromSectionId: d.data.fromSectionId,
              fromIndex: d.data.fromIndex,
              toSectionId: section.id,
              toIndex: destAbs,
            ));
      },
      builder: (context, candidate, rejected) {
        final hover = candidate.isNotEmpty;
        return Card(
          margin: EdgeInsets.zero,
          elevation: hover ? 4 : 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: hover ? color : Colors.transparent,
              width: 2,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionHeader(
                section: section,
                color: color,
                stopCount: stops.length,
                onRemove: isUnassigned
                    ? null
                    : () => dropsheet.removeDriverSection(section.id),
                onOptimise:
                    isUnassigned || stops.isEmpty ? null : _optimiseRoute,
                onCalculate:
                    isUnassigned || stops.isEmpty ? null : _calculateRoute,
                isOptimising: _optimising,
                isCalculating: _calculating,
              ),
              if (leaveTask != null)
                _DepartureBanner(
                  leaveTask: leaveTask,
                  officeAddress: config.depot.address,
                  color: color,
                ),
              if (hasPickUp)
                _StopViewToggle(
                  showPickUp: showPickUp,
                  color: color,
                  onChanged: _setShowPickUp,
                ),
              if (viewStops.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      hover
                          ? 'Drop here'
                          : stops.isEmpty
                              ? (isUnassigned
                                  ? 'Nothing unassigned'
                                  : 'Drag stops here')
                              : (showPickUp
                                  ? 'No pick-up stops'
                                  : 'No drop-off stops'),
                      style: TextStyle(
                        color: hover ? color : Colors.black45,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                )
              else
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(viewStops.length, (index) {
                    final entry = viewStops[index];
                    return _StopRow(
                      key: ValueKey(entry.task.id),
                      task: entry.task,
                      sectionId: section.id,
                      absoluteIndex: entry.absoluteIndex,
                      color: color,
                      number: entry.order,
                      canMoveUp: index > 0,
                      canMoveDown: index < viewStops.length - 1,
                      onMoveUp: () => Future.microtask(() => dropsheet.moveTask(
                            fromSectionId: section.id,
                            fromIndex: entry.absoluteIndex,
                            toSectionId: section.id,
                            toIndex: viewStops[index - 1].absoluteIndex,
                          )),
                      onMoveDown: () =>
                          Future.microtask(() => dropsheet.moveTask(
                                fromSectionId: section.id,
                                fromIndex: entry.absoluteIndex,
                                toSectionId: section.id,
                                toIndex: viewStops[index + 1].absoluteIndex,
                              )),
                      otherSections: widget.allSections
                          .where((s) => s.id != section.id)
                          .toList(),
                    );
                  }),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StopEntry {
  final DropsheetTask task;
  final int absoluteIndex;
  final int order;
  _StopEntry({
    required this.task,
    required this.absoluteIndex,
    required this.order,
  });
}

class _SectionHeader extends StatelessWidget {
  final DropsheetDriverSection section;
  final Color color;
  final int stopCount;
  final VoidCallback? onRemove;
  final VoidCallback? onOptimise;
  final VoidCallback? onCalculate;
  final bool isOptimising;
  final bool isCalculating;

  const _SectionHeader({
    required this.section,
    required this.color,
    required this.stopCount,
    required this.onRemove,
    this.onOptimise,
    this.onCalculate,
    this.isOptimising = false,
    this.isCalculating = false,
  });

  @override
  Widget build(BuildContext context) {
    final isUnassigned = section.id == kUnassignedSectionId;
    final hasRoute = section.routeDistanceMeters > 0;
    final routeBits = hasRoute
        ? '${(section.routeDistanceMeters / 1000).toStringAsFixed(1)} km · '
            '${(section.routeDurationSeconds / 60).round()} min'
        : null;
    final subtitle = isUnassigned
        ? '$stopCount unassigned'
        : [
            if (section.vehicle != null) section.vehicle!.displayName,
            if (section.trailer != null &&
                section.trailer != TrailerType.noTrailer)
              section.trailer!.displayName,
            '$stopCount stop${stopCount == 1 ? '' : 's'}',
            if (routeBits != null) routeBits,
          ].join(' • ');

    final busy = isOptimising || isCalculating;

    return Container(
      color: color,
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Colors.white,
            child: Icon(
              isUnassigned ? Icons.help_outline : Icons.local_shipping,
              size: 16,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  section.driverName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onCalculate != null)
            IconButton(
              tooltip: 'Calculate ETAs (keep order)',
              icon: isCalculating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.calculate, color: Colors.white, size: 20),
              onPressed: busy ? null : onCalculate,
            ),
          if (onOptimise != null)
            IconButton(
              tooltip: 'Optimise route',
              icon: isOptimising
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.alt_route, color: Colors.white, size: 20),
              onPressed: busy ? null : onOptimise,
            ),
          if (onRemove != null)
            IconButton(
              tooltip: 'Remove driver',
              icon: const Icon(Icons.close, color: Colors.white70, size: 18),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Departure banner — shown above the numbered stops, displays when the driver
// leaves the office and the office address.
// ─────────────────────────────────────────────────────────────────────────────

class _DepartureBanner extends StatelessWidget {
  final DropsheetTask leaveTask;
  final String officeAddress;
  final Color color;

  const _DepartureBanner({
    required this.leaveTask,
    required this.officeAddress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final time = leaveTask.startTime.isNotEmpty ? leaveTask.startTime : null;
    final address =
        officeAddress.trim().isNotEmpty ? officeAddress.trim() : 'Office';
    return Container(
      color: color.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.logout_outlined, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Depart from Office',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                Text(
                  address,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (time != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                time,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StopRow extends riverpod.ConsumerWidget {
  final DropsheetTask task;
  final String sectionId;
  final int absoluteIndex;
  final Color color;
  final int number;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final List<DropsheetDriverSection> otherSections;

  const _StopRow({
    super.key,
    required this.task,
    required this.sectionId,
    required this.absoluteIndex,
    required this.color,
    required this.number,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.otherSections,
    this.onMoveUp,
    this.onMoveDown,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final dropsheet = ref.read(dropsheetRiverpod);
    final config = ref.watch(dropsheetTaskConfigRiverpod);

    // Title: distributor name for distributor stops, otherwise the
    // type's display label.
    final titleText = _titleFor(task);

    // Subtitle line 1: human location (workArea / address / loading→offload).
    final locationLine = DropsheetMaps.locationLabel(task);

    // Subtitle line 2: ETA / leg info, if the route was optimised.
    final eta = (task.typeData['eta'] as String?) ??
        (task.typeData['offloadEta'] as String?) ??
        (task.typeData['loadingEta'] as String?);
    final legDistance = (task.typeData['legDistanceM'] as num?)?.toDouble();
    final legDuration = (task.typeData['legDurationS'] as num?)?.toInt();
    final routeBits = <String>[
      if (legDistance != null && legDistance > 0)
        '${(legDistance / 1000).toStringAsFixed(1)} km',
      if (legDuration != null && legDuration > 0)
        '${(legDuration / 60).round()} min',
      if (eta != null && eta.isNotEmpty) 'arr $eta',
    ].join(' · ');

    // Coordinate availability — drives the warning chip.
    final hasCoords = _hasCoords(task);

    // Chip label: for dynamic types use the custom label from config;
    // for built-in types use the (possibly user-renamed) effective label.
    final dynId = task.typeData['dynamicTypeId'] as String?;
    final chipLabel = (dynId != null && dynId.isNotEmpty)
        ? (config.dynamicTypeById(dynId)?.label ?? task.type.displayName)
        : config.effectiveLabelFor(task.type);

    final payload = TaskDragPayload(
      fromSectionId: sectionId,
      fromIndex: absoluteIndex,
      toIndex: 0,
      task: task,
    );

    final tile = Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFEEEEEE), width: 1),
        ),
      ),
      child: ListTile(
        dense: true,
        leading: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                titleText.isEmpty ? '(no name)' : titleText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 6),
            _TypeChip(type: task.type, label: chipLabel),
            if (!hasCoords) ...[
              const SizedBox(width: 4),
              const Tooltip(
                message: 'No coordinates — open task to fix the address.',
                child: Icon(Icons.location_off,
                    size: 14, color: Colors.deepOrange),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (locationLine.isNotEmpty)
              Text(
                locationLine,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            if (routeBits.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  routeBits,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Up / down ordering buttons.
            SizedBox(
              width: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 20,
                    width: 20,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 14,
                      tooltip: 'Move up',
                      icon: Icon(
                        Icons.arrow_drop_up,
                        color: canMoveUp ? Colors.black54 : Colors.black12,
                      ),
                      onPressed: canMoveUp ? onMoveUp : null,
                    ),
                  ),
                  SizedBox(
                    height: 20,
                    width: 20,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 14,
                      tooltip: 'Move down',
                      icon: Icon(
                        Icons.arrow_drop_down,
                        color: canMoveDown ? Colors.black54 : Colors.black12,
                      ),
                      onPressed: canMoveDown ? onMoveDown : null,
                    ),
                  ),
                ],
              ),
            ),
            if (otherSections.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'Move to driver',
                icon: const Icon(Icons.swap_horiz, size: 18),
                onSelected: (targetId) {
                  Future.microtask(() => dropsheet.moveTask(
                        fromSectionId: sectionId,
                        fromIndex: absoluteIndex,
                        toSectionId: targetId,
                        toIndex: 0,
                      ));
                },
                itemBuilder: (_) => otherSections
                    .map((s) => PopupMenuItem(
                          value: s.id,
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: colorForSection(s.id, [
                                    ...otherSections,
                                    DropsheetDriverSection(
                                      id: sectionId,
                                      driverId: sectionId,
                                      driverName: '',
                                    ),
                                  ]),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              Flexible(child: Text(s.driverName)),
                            ],
                          ),
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );

    return LongPressDraggable<TaskDragPayload>(
      data: payload,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 220,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            titleText,
            style: const TextStyle(color: Colors.white),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
    );
  }

  // ---------------------------------------------------------------------------
  // Display helpers
  // ---------------------------------------------------------------------------

  String _titleFor(DropsheetTask t) {
    switch (t.type) {
      case DropsheetTaskType.dropOff:
      case DropsheetTaskType.pickUp:
        final name = (t.typeData['distributorName'] as String?) ?? t.contact;
        return name.isNotEmpty ? name : t.job;
      case DropsheetTaskType.collection:
      case DropsheetTaskType.jobReturn:
      case DropsheetTaskType.pickFlyers:
        final client = (t.typeData['client'] as String?) ?? t.contact;
        return client.isNotEmpty ? client : t.type.displayName;
      case DropsheetTaskType.furnitureMove:
        final notes = (t.typeData['notes'] as String?) ?? '';
        return notes.isNotEmpty ? notes : 'Furniture move';
      case DropsheetTaskType.custom:
        return t.job.isNotEmpty ? t.job : 'Custom task';
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
      case DropsheetTaskType.leave:
      case DropsheetTaskType.arrive:
        return t.type.displayName;
    }
  }

  bool _hasCoords(DropsheetTask t) {
    final lat = (t.typeData['lat'] as num?)?.toDouble();
    final lng = (t.typeData['lng'] as num?)?.toDouble();
    if (lat != null && lng != null) return true;
    if (t.type == DropsheetTaskType.furnitureMove) {
      final ll = (t.typeData['loadingLat'] as num?)?.toDouble();
      final lo = (t.typeData['loadingLng'] as num?)?.toDouble();
      final ol = (t.typeData['offloadLat'] as num?)?.toDouble();
      final og = (t.typeData['offloadLng'] as num?)?.toDouble();
      return ll != null && lo != null && ol != null && og != null;
    }
    return false;
  }
}

class _TypeChip extends StatelessWidget {
  final DropsheetTaskType type;
  final String label;
  const _TypeChip({required this.type, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = _typeScheme(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: scheme.fg,
        ),
      ),
    );
  }

  ({Color bg, Color fg}) _typeScheme(DropsheetTaskType t) {
    switch (t) {
      case DropsheetTaskType.dropOff:
        return (bg: const Color(0xFFE3F2FD), fg: const Color(0xFF1565C0));
      case DropsheetTaskType.pickUp:
        return (bg: const Color(0xFFE8F5E9), fg: const Color(0xFF2E7D32));
      case DropsheetTaskType.collection:
        return (bg: const Color(0xFFFFF8E1), fg: const Color(0xFFEF6C00));
      case DropsheetTaskType.jobReturn:
        return (bg: const Color(0xFFEDE7F6), fg: const Color(0xFF4527A0));
      case DropsheetTaskType.pickFlyers:
        return (bg: const Color(0xFFFCE4EC), fg: const Color(0xFFAD1457));
      case DropsheetTaskType.furnitureMove:
        return (bg: const Color(0xFFE0F2F1), fg: const Color(0xFF00695C));
      case DropsheetTaskType.custom:
        return (bg: const Color(0xFFECEFF1), fg: const Color(0xFF455A64));
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
      case DropsheetTaskType.leave:
      case DropsheetTaskType.arrive:
        return (bg: const Color(0xFFEEEEEE), fg: const Color(0xFF424242));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Drop-off / Pick-up view toggle — shown inside a driver section when the
// section contains at least one pick-up task.
// ─────────────────────────────────────────────────────────────────────────────

class _StopViewToggle extends StatelessWidget {
  final bool showPickUp;
  final Color color;
  final ValueChanged<bool> onChanged;

  const _StopViewToggle({
    required this.showPickUp,
    required this.color,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: const Border(
          bottom: BorderSide(color: Color(0xFFEEEEEE)),
        ),
      ),
      child: Row(
        children: [
          _buildChip(
            label: 'Drop-off',
            icon: Icons.arrow_circle_down_outlined,
            selected: !showPickUp,
            onTap: () => onChanged(false),
          ),
          const SizedBox(width: 8),
          _buildChip(
            label: 'Pick-up',
            icon: Icons.arrow_circle_up_outlined,
            selected: showPickUp,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }

  Widget _buildChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? color : Colors.black26,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: selected ? Colors.white : Colors.black54,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
