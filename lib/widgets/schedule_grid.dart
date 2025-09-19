import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../models/job.dart';
import '../providers/schedule_provider.dart';
import 'job_card.dart';
import 'month_navigation_widget.dart';

class ScheduleGrid extends StatefulWidget {
  const ScheduleGrid({super.key});

  @override
  State<ScheduleGrid> createState() => _ScheduleGridState();
}

class _ScheduleGridState extends State<ScheduleGrid> {
  // Navigation offsets
  int _selectedWeekOffset = 0; // Selected week in the week selector
  int _viewOffset = 0; // Offset for the 5-week view in the top bar
  int _dayOffset = 0; // Day-based navigation offset

  // Keep track of current month to reset offsets when it changes
  String _currentMonthDisplay = '';

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

  // Get the start of the current week (Friday) based on selected month
  DateTime _getCurrentWeekStart(DateTime baseDate) {
    final daysUntilFriday = (DateTime.friday - baseDate.weekday + 7) % 7;
    return DateTime(
        baseDate.year, baseDate.month, baseDate.day + daysUntilFriday);
  }

  // Get week number and year
  String _getWeekLabel(DateTime date) {
    final firstDayOfYear = DateTime(date.year, 1, 1);
    final daysOffset = firstDayOfYear.weekday - DateTime.friday;
    final firstFriday = firstDayOfYear.add(
      Duration(days: (daysOffset + 7) % 7),
    );
    final diff = date.difference(firstFriday);
    final weekNum = (diff.inDays / 7).floor() + 1;
    return 'Week $weekNum';
  }

  // Generate list of weeks for the top bar
  List<DateTime> _getWeekStarts(DateTime baseDate) {
    final currentWeekStart = _getCurrentWeekStart(baseDate);
    return List.generate(5, (index) {
      return currentWeekStart.add(
        Duration(days: 7 * (index + _viewOffset - 2)),
      );
    });
  }

  // Generate list of 12 days centered around the selected week
  List<DateTime> _getDates(DateTime baseDate) {
    final selectedWeekStart = _getCurrentWeekStart(baseDate).add(
      Duration(days: 7 * _selectedWeekOffset),
    );
    // Start 2 days before the selected week, and add day offset
    final startDate = selectedWeekStart
        .subtract(const Duration(days: 2))
        .add(Duration(days: _dayOffset));
    return List.generate(12, (index) {
      return startDate.add(Duration(days: index));
    });
  }

  void _previousWeeks(ScheduleProvider scheduleProvider) {
    setState(() {
      _viewOffset--;
      _dayOffset = 0; // Reset day offset when changing weeks
    });

    // Check if we moved to a different month
    final currentMonth = scheduleProvider.currentMonth;
    final newWeekStart = _getCurrentWeekStart(currentMonth).add(
      Duration(days: 7 * (_viewOffset - 2)),
    );

    if (newWeekStart.month != currentMonth.month ||
        newWeekStart.year != currentMonth.year) {
      scheduleProvider
          .setCurrentMonth(DateTime(newWeekStart.year, newWeekStart.month));
    }
  }

  void _nextWeeks(ScheduleProvider scheduleProvider) {
    setState(() {
      _viewOffset++;
      _dayOffset = 0; // Reset day offset when changing weeks
    });

    // Check if we moved to a different month
    final currentMonth = scheduleProvider.currentMonth;
    final newWeekStart = _getCurrentWeekStart(currentMonth).add(
      Duration(days: 7 * (_viewOffset + 2)),
    );

    if (newWeekStart.month != currentMonth.month ||
        newWeekStart.year != currentMonth.year) {
      scheduleProvider
          .setCurrentMonth(DateTime(newWeekStart.year, newWeekStart.month));
    }
  }

  void _selectWeek(int offset, ScheduleProvider scheduleProvider) {
    setState(() {
      _selectedWeekOffset = offset + _viewOffset - 2;
      _dayOffset = 0; // Reset day offset when selecting a new week
    });

    // Calculate the date for the selected week
    final currentMonth = scheduleProvider.currentMonth;
    final selectedWeekStart = _getCurrentWeekStart(currentMonth).add(
      Duration(days: 7 * _selectedWeekOffset),
    );

    // Check if the selected week is in a different month
    if (selectedWeekStart.month != currentMonth.month ||
        selectedWeekStart.year != currentMonth.year) {
      // Update the provider to the new month
      scheduleProvider.setCurrentMonth(
          DateTime(selectedWeekStart.year, selectedWeekStart.month));
    }
  }

  void _previousDays() {
    setState(() {
      _dayOffset -= 2; // Move 2 days back
    });
  }

  void _nextDays() {
    setState(() {
      _dayOffset += 2; // Move 2 days forward
    });
  }

  static const double cellWidth = 200.0;
  static const double headerHeight = 40.0;
  static const double rowHeight = 90.0; // Adjusted to match card height

  @override
  Widget build(BuildContext context) {
    return Consumer<ScheduleProvider>(
      builder: (context, scheduleProvider, child) {
        // Check if month changed and reset offsets
        if (_currentMonthDisplay != scheduleProvider.currentMonthDisplay) {
          _currentMonthDisplay = scheduleProvider.currentMonthDisplay;
          _selectedWeekOffset = 0;
          _viewOffset = 0;
          _dayOffset = 0;
        }

        final currentMonth = scheduleProvider.currentMonth;
        final dates = _getDates(currentMonth);
        final weekStarts = _getWeekStarts(currentMonth);
        final distributors = scheduleProvider.distributors;

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

            Container(
              decoration: ShapeDecoration.fromBoxDecoration(
                BoxDecoration(
                  color: Theme.of(context).appBarTheme.backgroundColor,
                  boxShadow: [
                    BoxShadow(
                      color: const Color.fromARGB(
                        255,
                        1,
                        141,
                        211,
                      ).withOpacity(0.15),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_left),
                    onPressed: () => _previousWeeks(scheduleProvider),
                    padding: EdgeInsets.zero,
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(5, (index) {
                        final weekStart = weekStarts[index];
                        final isSelected =
                            index == 2 + _selectedWeekOffset - _viewOffset;
                        return TextButton(
                          onPressed: () => _selectWeek(index, scheduleProvider),
                          style: TextButton.styleFrom(
                            backgroundColor: isSelected
                                ? Theme.of(
                                    context,
                                  ).primaryColor.withOpacity(0.1)
                                : null,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: Text(_getWeekLabel(weekStart)),
                        );
                      }),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_right),
                    onPressed: () => _nextWeeks(scheduleProvider),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
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
                    columnCount: 13, // 12 days + 1 for distributor names column
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
                                icon: const Icon(Icons.person_add),
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
                                          TextButton(
                                            onPressed: () {
                                              Navigator.of(context).pop();
                                            },
                                            child: const Text('Cancel'),
                                          ),
                                          TextButton(
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
                          final isFirstColumn = vicinity.column == 1;
                          final isLastColumn = vicinity.column == dates.length;

                          return TableViewCell(
                            child: Card(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final dateText =
                                      '${DateFormat('EEE').format(date)} ${date.day} ${_getMonthAbbreviation(date.month)}';

                                  return Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (isFirstColumn)
                                        IconButton(
                                          icon: const Icon(Icons.arrow_left),
                                          onPressed: _previousDays,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          iconSize: 16,
                                        ),
                                      Expanded(
                                        child: Center(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              dateText,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleMedium,
                                              textAlign: TextAlign.center,
                                              maxLines: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (isLastColumn)
                                        IconButton(
                                          icon: const Icon(Icons.arrow_right),
                                          onPressed: _nextDays,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          iconSize: 16,
                                        ),
                                    ],
                                  );
                                },
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
                                        ).textTheme.titleMedium,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        } else {
                          // Job cells
                          final date = dates[vicinity.column - 1];
                          final jobs =
                              scheduleProvider.getJobsForDistributorAndDate(
                                  distributor.id, date);

                          return TableViewCell(
                            child: DragTarget<Job>(
                              onAcceptWithDetails: (jobDetails) {
                                // Get the dragged job
                                final draggedJob = jobDetails.data;

                                // If there's already a job in the target cell
                                if (jobs.isNotEmpty) {
                                  final targetJob = jobs.first;

                                  // Swap the jobs by updating both
                                  scheduleProvider.updateJob(
                                    draggedJob.copyWith(
                                      distributorId: distributor.id,
                                      date: date,
                                    ),
                                  );

                                  scheduleProvider.updateJob(
                                    targetJob.copyWith(
                                      distributorId: draggedJob.distributorId,
                                      date: draggedJob.date,
                                    ),
                                  );
                                } else {
                                  // If target cell is empty, just move the dragged job
                                  scheduleProvider.updateJob(
                                    draggedJob.copyWith(
                                      distributorId: distributor.id,
                                      date: date,
                                    ),
                                  );
                                }
                              },
                              onWillAcceptWithDetails: (job) => true,
                              builder: (context, candidateData, rejectedData) {
                                return Card(
                                  color: candidateData.isNotEmpty
                                      ? Theme.of(
                                          context,
                                        ).primaryColor.withOpacity(0.1)
                                      : null,
                                  child: jobs.isEmpty
                                      ? Center(
                                          child: IconButton(
                                            icon: const Icon(Icons.add),
                                            onPressed: () {
                                              final newJob = Job(
                                                id: '', // Will be set by Firestore
                                                client: '',
                                                workAreaId:
                                                    '', // Empty ID to be selected later
                                                workingArea:
                                                    '', // Empty name to be selected later
                                                distributorId: distributor.id,
                                                date: date,
                                                status: JobStatus.scheduled,
                                              );
                                              scheduleProvider.addJob(newJob);
                                            },
                                          ),
                                        )
                                      : Draggable<Job>(
                                          data: jobs.first,
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
