import 'package:clmschedule/providers/toggler_provider.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../models/distributor.dart';
import '../providers/schedule_provider.dart';
import '../providers/scale_provider.dart';
import 'month_navigation_widget.dart';
import 'schedule_job_cell.dart';

/// Data class to optimize grid rebuilds with Selector pattern
class _ScheduleGridData {
  final List<Distributor> distributors;
  final DateTime currentMonth;
  final bool hasJobsInNextMonth;
  final String currentMonthDisplay;
  final double scale;
  final int jobsCount; // Track job count to trigger rebuilds
  final int jobsHash; // Track job modifications

  const _ScheduleGridData({
    required this.distributors,
    required this.currentMonth,
    required this.hasJobsInNextMonth,
    required this.currentMonthDisplay,
    required this.scale,
    required this.jobsCount,
    required this.jobsHash,
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
          jobsHash == other.jobsHash;

  @override
  int get hashCode =>
      distributors.length.hashCode ^
      currentMonth.hashCode ^
      hasJobsInNextMonth.hashCode ^
      currentMonthDisplay.hashCode ^
      scale.hashCode ^
      jobsCount.hashCode ^
      jobsHash.hashCode;
}

class ScheduleGrid extends StatefulWidget {
  const ScheduleGrid({super.key});

  @override
  State<ScheduleGrid> createState() => _ScheduleGridState();
}

class _ScheduleGridState extends State<ScheduleGrid> {
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
    final today = DateTime.now();
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
    final isFullscreen = context.watch<TogglerProvider>().isFullview;

    // Use Selector to only rebuild when specific data changes
    return Selector<ScheduleProvider, _ScheduleGridData>(
      selector: (_, scheduleProvider) {
        final jobs = scheduleProvider.jobs;
        // Create a hash from job IDs and their key properties to detect changes
        final jobsHash = jobs.fold<int>(
            0,
            (hash, job) =>
                hash ^
                job.id.hashCode ^
                job.distributorId.hashCode ^
                job.date.hashCode ^
                job.statusId.hashCode);

        return _ScheduleGridData(
          distributors: scheduleProvider.distributors,
          currentMonth: scheduleProvider.currentMonth,
          hasJobsInNextMonth: scheduleProvider.hasJobsInNextMonth,
          currentMonthDisplay: scheduleProvider.currentMonthDisplay,
          scale: context.read<ScaleProvider>().scale,
          jobsCount: jobs.length,
          jobsHash: jobsHash,
        );
      },
      builder: (context, gridData, child) {
        final scheduleProvider = context.read<ScheduleProvider>();
        final scaleProvider = context.read<ScaleProvider>();

        // Check if month changed and reset scroll position
        if (_currentMonthDisplay != gridData.currentMonthDisplay) {
          _currentMonthDisplay = gridData.currentMonthDisplay;
          _hasScrolledToToday = false; // Reset scroll flag for new month
        }

        final dates = _getDates(gridData.currentMonth, scheduleProvider);
        final distributors = gridData.distributors;

        final double rowHeight =
            isFullscreen ? 92.0 * gridData.scale : 40.0 * gridData.scale;

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
            ),

            // Week navigation removed - using month navigation only
            // Table scroll hint
            // Container(
            //   padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            //   child: Row(
            //     children: [
            //       Icon(Icons.swipe_left, size: 16, color: Colors.grey[600]),
            //       const SizedBox(width: 4),
            //       Text(
            //         'Scroll horizontally and vertically to view all schedule data',
            //         style: TextStyle(
            //           fontSize: 12,
            //           color: Colors.grey[600],
            //           fontStyle: FontStyle.italic,
            //         ),
            //       ),
            //       const Spacer(),
            //       Icon(Icons.swipe_right, size: 16, color: Colors.grey[600]),
            //       const SizedBox(width: 8),
            //       Icon(Icons.swipe_up, size: 16, color: Colors.grey[600]),
            //       Icon(Icons.swipe_down, size: 16, color: Colors.grey[600]),
            //     ],
            //   ),
            // ),
            // Grid
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
                    rowCount:
                        distributors.length + 1, // +1 for date headers row
                    columnBuilder: (int column) {
                      return TableSpan(
                        extent:
                            FixedTableSpanExtent(column == 0 ? 150 : cellWidth),
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
                                            message:
                                                'Cancel adding distributor',
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
                                                  scheduleProvider
                                                      .addDistributor(
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
                          final today = DateTime.now();
                          final isToday = date.year == today.year &&
                              date.month == today.month &&
                              date.day == today.day;

                          return TableViewCell(
                            child: Card(
                              color: isToday
                                  ? Theme.of(context)
                                      .primaryColor
                                      .withOpacity(0.2)
                                  : null,
                              child: Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    '${DateFormat('EEE').format(date)} ${date.day} ${_getMonthAbbreviation(date.month)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight:
                                              isToday ? FontWeight.bold : null,
                                          color: isToday
                                              ? Theme.of(context).primaryColor
                                              : null,
                                        ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
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
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
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
                          final jobs =
                              scheduleProvider.getJobsForDistributorAndDate(
                                  distributor.id, date);

                          return TableViewCell(
                            child: ScheduleJobCell(
                              distributor: distributor,
                              date: date,
                              jobs: jobs,
                              cellWidth: cellWidth,
                              rowHeight: rowHeight,
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
      },
    );
  }
}
