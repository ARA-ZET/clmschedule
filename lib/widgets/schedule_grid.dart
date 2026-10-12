import 'dart:async';

import 'package:clmschedule/providers/toggler_provider.dart';
import 'package:flutter/material.dart';
import 'package:clmschedule/utils/schedule_time.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../models/distributor.dart';
import '../models/job.dart';
import '../models/schedule_confirmation_status.dart';
import '../providers/auth_provider.dart';
import '../providers/schedule_provider.dart';
import '../providers/scale_provider.dart';
import '../providers/schedule_selection_provider.dart';
import 'day_planner/day_planner_page.dart';
import 'month_navigation_widget.dart';
import 'schedule_batch_drop.dart';
import 'schedule_job_cell.dart';

/// Data class to optimize grid rebuilds with Selector pattern
class _ScheduleGridData {
  final List<Distributor> distributors;
  final DateTime currentMonth;
  final bool hasJobsInNextMonth;
  final String currentMonthDisplay;
  final double scale;
  final int jobsCount; // Track job count to trigger rebuilds
  final int jobsVersion; // Monotonic version counter from provider
  final bool isFullscreen;

  const _ScheduleGridData({
    required this.distributors,
    required this.currentMonth,
    required this.hasJobsInNextMonth,
    required this.currentMonthDisplay,
    required this.scale,
    required this.jobsCount,
    required this.jobsVersion,
    required this.isFullscreen,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ScheduleGridData &&
          runtimeType == other.runtimeType &&
          distributors.length == other.distributors.length &&
          currentMonth == other.currentMonth &&
          hasJobsInNextMonth == other.hasJobsInNextMonth &&
          currentMonthDisplay == other.currentMonthDisplay &&
          scale == other.scale &&
          jobsCount == other.jobsCount &&
          jobsVersion == other.jobsVersion &&
          isFullscreen == other.isFullscreen;

  @override
  int get hashCode =>
      distributors.length.hashCode ^
      currentMonth.hashCode ^
      hasJobsInNextMonth.hashCode ^
      currentMonthDisplay.hashCode ^
      scale.hashCode ^
      jobsCount.hashCode ^
      jobsVersion.hashCode ^
      isFullscreen.hashCode;
}

class ScheduleGrid extends riverpod.ConsumerStatefulWidget {
  const ScheduleGrid({super.key});

  @override
  riverpod.ConsumerState<ScheduleGrid> createState() => _ScheduleGridState();
}

class _ScheduleGridState extends riverpod.ConsumerState<ScheduleGrid> {
  // Keep track of current month to reset scroll position when it changes
  String _currentMonthDisplay = '';
  bool _hasScrolledToToday = false;

  // Scroll controllers for horizontal and vertical scrolling
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    super.dispose();
  }

  // Helper method to convert month number to abbreviation
  String _getMonthAbbreviation(int month) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[month - 1];
  }

  /// Opens the date schedule map page with distributor tabs.
  Future<void> _openDateMap(BuildContext context, DateTime date) async {
    final scheduleProvider = ref.read(scheduleRiverpod);

    final jobs = scheduleProvider.getJobsForDate(date);
    final jobsWithMaps = jobs.where((j) => j.workMaps.isNotEmpty).toList();

    if (jobsWithMaps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No map areas for this day')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => DayPlannerPage(
          date: date,
          jobs: jobsWithMaps,
          distributors: scheduleProvider.distributors,
        ),
      ),
    );
  }

  // Generate list of days for the current month, plus next month if it has jobs
  List<DateTime> _getDates(DateTime baseDate, ScheduleProvider provider) {
    // Get first day of the current month
    final firstDayOfMonth = DateTime(baseDate.year, baseDate.month, 1);

    // Get last day of the current month
    final lastDayOfCurrentMonth =
        DateTime(baseDate.year, baseDate.month + 1, 0);

    // Calculate total days in the current month
    final currentMonthDays =
        lastDayOfCurrentMonth.difference(firstDayOfMonth).inDays + 1;

    // Check if next month has jobs
    final includeNextMonth = provider.hasJobsInNextMonth;

    DateTime lastDay;
    int totalDays;

    if (includeNextMonth) {
      // Include next month dates
      lastDay = DateTime(baseDate.year, baseDate.month + 2, 0);
      totalDays = lastDay.difference(firstDayOfMonth).inDays + 1;
    } else {
      // Current month only
      lastDay = lastDayOfCurrentMonth;
      totalDays = currentMonthDays;
    }

    // Generate all dates in the range
    return List.generate(totalDays, (index) {
      return firstDayOfMonth.add(Duration(days: index));
    });
  }

  // Find the index of today's date in the dates list
  int _getTodayIndex(List<DateTime> dates) {
    final today = scheduleNow();
    final todayDateOnly = DateTime(today.year, today.month, today.day);

    for (int i = 0; i < dates.length; i++) {
      final dateOnly = DateTime(dates[i].year, dates[i].month, dates[i].day);
      if (dateOnly == todayDateOnly) {
        return i;
      }
    }
    return 0; // Fallback to first date if today is not found
  }

  // Scroll to today's date in the horizontal scrollbar
  void _scrollToToday(List<DateTime> dates) {
    if (!_hasScrolledToToday && dates.isNotEmpty) {
      final todayIndex = _getTodayIndex(dates);
      if (todayIndex >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_horizontalScrollController.hasClients && mounted) {
            // Calculate the scroll position to center today's date
            // Account for viewport width and pinned column
            final viewportWidth = MediaQuery.of(context).size.width;
            const pinnedColumnWidth =
                150.0; // Width of distributor names column
            final availableWidth = viewportWidth - pinnedColumnWidth;

            // Position to center today's column in the viewport
            final targetPosition = (todayIndex * cellWidth) -
                (availableWidth / 2) +
                (cellWidth / 2);

            final maxScroll =
                _horizontalScrollController.position.maxScrollExtent;
            final scrollPosition = targetPosition.clamp(0.0, maxScroll);

            _horizontalScrollController.animateTo(
              scrollPosition,
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeInOut,
            );
          }
        });

        _hasScrolledToToday = true;
      }
    }
  }

  static const double cellWidth = 200.0;
  static const double headerHeight = 40.0;

  @override
  Widget build(BuildContext context) {
    // Watch providers for reactive rebuilds
    final scheduleProvider = ref.watch(scheduleRiverpod);
    ref.watch(togglerRiverpod);

    final jobs = scheduleProvider.jobs;
    final gridData = _ScheduleGridData(
      distributors: scheduleProvider.gridDistributors,
      currentMonth: scheduleProvider.currentMonth,
      hasJobsInNextMonth: scheduleProvider.hasJobsInNextMonth,
      currentMonthDisplay: scheduleProvider.currentMonthDisplay,
      scale: ref.read(scaleRiverpod).scale,
      jobsCount: jobs.length,
      jobsVersion: scheduleProvider.jobsVersion,
      isFullscreen: ref.read(togglerRiverpod).isFullviewSchedule,
    );

    final scaleProvider = ref.read(scaleRiverpod);

    // Check if month changed and reset scroll position
    if (_currentMonthDisplay != gridData.currentMonthDisplay) {
      _currentMonthDisplay = gridData.currentMonthDisplay;
      _hasScrolledToToday = false; // Reset scroll flag for new month
    }

    final dates = _getDates(gridData.currentMonth, scheduleProvider);
    final distributors = gridData.distributors;

    final double rowHeight =
        gridData.isFullscreen ? 92.0 * gridData.scale : 40.0 * gridData.scale;

    // Scroll to today's date when data is loaded
    _scrollToToday(dates);

    return Column(
      children: [
        // Month navigation
        MonthNavigationWidget(
          currentMonthDisplay: scheduleProvider.currentMonthDisplay,
          onPreviousMonth: scheduleProvider.goToPreviousMonth,
          onNextMonth: scheduleProvider.goToNextMonth,
          onCurrentMonth: scheduleProvider.goToCurrentMonth,
          onMonthSelected: scheduleProvider.goToMonth,
          availableMonths: scheduleProvider.getAvailableMonths(),
          mode: Mode.schedule,
          extraActions: [
            const _DayConfirmationButton(label: 'Today', dayOffset: 0),
            const _DayConfirmationButton(label: 'Tomorrow', dayOffset: 1),
            const _SelectJobsButton(),
          ],
        ),

        Expanded(
          child: Scrollbar(
            controller: _horizontalScrollController,
            thumbVisibility: true,
            trackVisibility: true,
            thickness: 12,
            radius: const Radius.circular(6),
            child: Scrollbar(
              controller: _verticalScrollController,
              thumbVisibility: true,
              trackVisibility: true,
              thickness: 12,
              radius: const Radius.circular(6),
              child: TableView.builder(
                horizontalDetails: ScrollableDetails.horizontal(
                  controller: _horizontalScrollController,
                ),
                verticalDetails: ScrollableDetails.vertical(
                  controller: _verticalScrollController,
                ),
                pinnedRowCount: 1,
                pinnedColumnCount: 1,
                columnCount: dates.length +
                    1, // All dates + 1 for distributor names column
                rowCount: distributors.length + 1, // +1 for date headers row
                columnBuilder: (int column) {
                  return TableSpan(
                    extent: FixedTableSpanExtent(column == 0 ? 150 : cellWidth),
                  );
                },
                rowBuilder: (int row) {
                  return TableSpan(
                    extent: FixedTableSpanExtent(
                      row == 0 ? headerHeight : rowHeight,
                    ),
                  );
                },

                cellBuilder: (context, vicinity) {
                  if (vicinity.row == 0) {
                    // Header row
                    if (vicinity.column == 0) {
                      // Top-left corner cell
                      return TableViewCell(
                        child: Card(
                          child: IconButton(
                            icon: Icon(Icons.person_add,
                                size: scaleProvider.mediumIconSize),
                            tooltip: 'Add new distributor',
                            onPressed: () {
                              // Show dialog to add new distributor
                              showDialog(
                                context: context,
                                builder: (context) {
                                  final nameController =
                                      TextEditingController();
                                  return AlertDialog(
                                    title: const Text('Add Distributor'),
                                    content: TextField(
                                      controller: nameController,
                                      decoration: const InputDecoration(
                                        labelText: 'Distributor Name',
                                      ),
                                      autofocus: true,
                                    ),
                                    actions: [
                                      Tooltip(
                                        message: 'Cancel adding distributor',
                                        child: TextButton(
                                          onPressed: () {
                                            Navigator.of(context).pop();
                                          },
                                          child: const Text('Cancel'),
                                        ),
                                      ),
                                      Tooltip(
                                        message: 'Add new distributor',
                                        child: TextButton(
                                          onPressed: () {
                                            if (nameController
                                                .text.isNotEmpty) {
                                              scheduleProvider.addDistributor(
                                                nameController.text,
                                              );
                                              Navigator.of(context).pop();
                                            }
                                          },
                                          child: const Text('Add'),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      );
                    } else {
                      // Date headers
                      final date = dates[vicinity.column - 1];
                      final today = scheduleNow();
                      final isToday = date.year == today.year &&
                          date.month == today.month &&
                          date.day == today.day;

                      return TableViewCell(
                        child: _DateHeaderCell(
                          date: date,
                          isToday: isToday,
                          label:
                              '${DateFormat('EEE').format(date)} ${date.day} ${_getMonthAbbreviation(date.month)}',
                          onOpenMap: () => _openDateMap(context, date),
                        ),
                      );
                    }
                  } else {
                    final distributor = distributors[vicinity.row - 1];
                    if (vicinity.column == 0) {
                      // Distributor names column
                      return TableViewCell(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                Text(
                                  '${vicinity.row}.', // Index number
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    distributor.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    } else {
                      // Job cells - use isolated widget for better performance
                      final date = dates[vicinity.column - 1];
                      final jobs = scheduleProvider
                          .getJobsForDistributorAndDate(distributor.id, date);

                      return TableViewCell(
                        child: RepaintBoundary(
                          child: ScheduleJobCell(
                            distributor: distributor,
                            date: date,
                            jobs: jobs,
                            cellWidth: cellWidth,
                            rowHeight: rowHeight,
                            isFullscreen: gridData.isFullscreen,
                          ),
                        ),
                      );
                    }
                  }
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A date column's header. Drop selected jobs (or one job) here to move
/// them onto this date and the days after it, each to the first free
/// distributor. While selecting, a click selects every job on the day.
class _DateHeaderCell extends riverpod.ConsumerWidget {
  final DateTime date;
  final bool isToday;
  final String label;
  final VoidCallback onOpenMap;

  const _DateHeaderCell({
    required this.date,
    required this.isToday,
    required this.label,
    required this.onOpenMap,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final scaleProvider = ref.read(scaleRiverpod);
    final selecting =
        ref.watch(scheduleSelectionRiverpod.select((s) => s.isSelecting));
    final theme = Theme.of(context);

    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) =>
          d.data is ScheduleJobsDrag || d.data is Job,
      onAcceptWithDetails: (d) => dropJobsOnDate(context, ref, d.data, date),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        return Tooltip(
          message: selecting
              ? 'Click to select every job on this day'
              : 'Drop jobs here to move them to this day',
          waitDuration: const Duration(milliseconds: 600),
          child: Card(
            color: hovering
                ? Colors.blue.withValues(alpha: 0.25)
                : isToday
                    ? theme.primaryColor.withValues(alpha: 0.2)
                    : null,
            shape: hovering
                ? RoundedRectangleBorder(
                    side: BorderSide(color: Colors.blue.shade600, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  )
                : null,
            child: InkWell(
              onTap: selecting
                  ? () => ref.read(scheduleSelectionRiverpod).toggleAll(ref
                      .read(scheduleRiverpod)
                      .getJobsForDate(date)
                      .map((j) => j.id))
                  : null,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: isToday ? FontWeight.bold : null,
                        color: isToday ? theme.primaryColor : null,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: scaleProvider.smallIconSize,
                      width: scaleProvider.smallIconSize,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: scaleProvider.smallIconSize - 2,
                        icon: const Icon(Icons.map_outlined),
                        tooltip: 'View all areas for this day',
                        onPressed: onOpenMap,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Toolbar toggle for selecting several jobs to move together; shows the
/// count and a clear button while any are selected.
class _SelectJobsButton extends riverpod.ConsumerWidget {
  const _SelectJobsButton();

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final selection = ref.watch(scheduleSelectionRiverpod);
    final count = selection.count;
    final on = selection.selectMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: on
                ? 'Stop selecting (Esc)'
                : 'Select several jobs to drag onto a date together '
                    '(Ctrl / ⌘-click picks one job, Shift-click selects everything '
                    'in between)',
            child: FilterChip(
              avatar:
                  Icon(on ? Icons.checklist : Icons.checklist_rtl, size: 18),
              label: Text(count > 0 ? '$count selected' : 'Select'),
              selected: on || count > 0,
              onSelected: (v) => selection.setSelectMode(v),
            ),
          ),
          if (count > 0)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              tooltip: 'Clear selection',
              visualDensity: VisualDensity.compact,
              onPressed: selection.clear,
            ),
        ],
      ),
    );
  }
}

/// Quick-access badge/button for Today or Tomorrow, placed next to the
/// month navigation's "Current" button. Tapping it jumps the grid to that
/// date's month and opens a menu to set the admin confirmation status
/// (Confirmed/Pending/Not Confirmed), which is surfaced to distributors on
/// the public clmworking.web.app roster.
///
/// Takes a *day offset* rather than a date: the grid is routinely left open
/// for days, and a date captured at build time silently goes stale. The state
/// re-resolves "today" against the SAST clock and re-points its stream at the
/// new day doc when the date rolls over, so the badge and the write it
/// performs always refer to the same day everyone else is looking at.
class _DayConfirmationButton extends riverpod.ConsumerStatefulWidget {
  final String label;

  /// Days from SAST today: 0 = today, 1 = tomorrow.
  final int dayOffset;

  const _DayConfirmationButton({required this.label, required this.dayOffset});

  @override
  riverpod.ConsumerState<_DayConfirmationButton> createState() =>
      _DayConfirmationButtonState();
}

class _DayConfirmationButtonState
    extends riverpod.ConsumerState<_DayConfirmationButton> {
  final GlobalKey _key = GlobalKey();
  ScheduleDayConfirmation _lastKnown = const ScheduleDayConfirmation();
  late DateTime _date;
  late Stream<ScheduleDayConfirmation> _stream;
  Timer? _rolloverTimer;
  bool _saving = false;

  DateTime get _targetDate =>
      scheduleToday().add(Duration(days: widget.dayOffset));

  @override
  void initState() {
    super.initState();
    _date = _targetDate;
    _stream = ref.read(scheduleRiverpod).watchDayConfirmation(_date);
    // Cheap tick; the work only happens on the one minute a day the SAST
    // calendar date actually changes.
    _rolloverTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _syncDate());
  }

  @override
  void dispose() {
    _rolloverTimer?.cancel();
    super.dispose();
  }

  /// Re-points the stream at the current target day if the date rolled over.
  /// Returns the date the button now refers to.
  DateTime _syncDate() {
    final next = _targetDate;
    if (next == _date) return _date;
    setState(() {
      _date = next;
      _lastKnown = const ScheduleDayConfirmation();
      _stream = ref.read(scheduleRiverpod).watchDayConfirmation(next);
    });
    return next;
  }

  Future<void> _openMenu() async {
    // Resolve the day *before* reading or writing anything, so a session that
    // has been open since yesterday cannot confirm the wrong day.
    final date = _syncDate();
    final scheduleProvider = ref.read(scheduleRiverpod);
    scheduleProvider.goToMonthContaining(date);

    final renderBox = _key.currentContext!.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = renderBox.localToGlobal(
      renderBox.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final position = RelativeRect.fromRect(
      Rect.fromPoints(topLeft, bottomRight),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu<ScheduleConfirmationStatus>(
      context: context,
      position: position,
      items: ScheduleConfirmationStatus.values.map((s) {
        return PopupMenuItem<ScheduleConfirmationStatus>(
          value: s,
          child: Row(
            children: [
              Icon(s.icon, size: 16, color: s.color),
              const SizedBox(width: 8),
              Text(s.displayName),
              if (s == _lastKnown.status) ...[
                const Spacer(),
                const Icon(Icons.check, size: 16),
              ],
            ],
          ),
        );
      }).toList(),
    );

    if (selected == null || !mounted) return;

    final authProvider = ref.read(authRiverpod);
    final confirmedBy = authProvider.appUser?.name ??
        authProvider.user?.displayName ??
        authProvider.user?.email ??
        'Unknown';

    setState(() => _saving = true);
    try {
      await scheduleProvider.setDayConfirmation(
        date,
        selected,
        confirmedBy: confirmedBy,
      );
    } catch (e) {
      // A silently swallowed failure here is what makes the button look
      // unresponsive — the write never landed but nothing said so.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red,
            content: Text(
              'Could not set ${widget.label} to ${selected.displayName}: $e',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ScheduleDayConfirmation>(
      stream: _stream,
      builder: (context, snapshot) {
        final confirmation = snapshot.data ?? const ScheduleDayConfirmation();
        _lastKnown = confirmation;
        final status = confirmation.status;
        // Only a server-acknowledged value is what other users see; anything
        // else is this client's own optimistic/cached copy.
        final unsynced = snapshot.hasData && confirmation.isUnsynced;
        final dateLabel = DateFormat('EEE d MMM').format(_date);

        return Padding(
          key: _key,
          padding: const EdgeInsets.only(left: 8),
          child: Material(
            color: Colors.transparent,
            child: Tooltip(
              message: unsynced
                  ? '${widget.label} — $dateLabel\n'
                      '${status.displayName} (not yet synced — other users '
                      'may still see the previous status)'
                  : '${widget.label} — $dateLabel\n${status.displayName}'
                      '${confirmation.confirmedBy != null ? '\nby ${confirmation.confirmedBy}' : ''}',
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _saving ? null : _openMenu,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: status.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        Border.all(color: status.color.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_saving)
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: status.color,
                          ),
                        )
                      else
                        Icon(status.icon, size: 16, color: status.color),
                      const SizedBox(width: 6),
                      Text(
                        widget.label,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: status.color,
                        ),
                      ),
                      if (unsynced) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.cloud_off,
                          size: 12,
                          color: status.color.withValues(alpha: 0.8),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
