import 'package:clmschedule/providers/toggler_provider.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../providers/window_cleaning_provider.dart';
import '../providers/scale_provider.dart';
import 'month_navigation_widget.dart';

class WindowCleaningScheduleGrid extends StatefulWidget {
  const WindowCleaningScheduleGrid({super.key});

  @override
  State<WindowCleaningScheduleGrid> createState() =>
      _WindowCleaningScheduleGridState();
}

class _WindowCleaningScheduleGridState
    extends State<WindowCleaningScheduleGrid> {
  String _currentMonthDisplay = '';
  bool _hasScrolledToToday = false;

  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();

  List<DateTime>? _cachedDates;
  DateTime? _cachedCurrentMonth;
  List<String>? _cachedTimeSlots;

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    super.dispose();
  }

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

  List<DateTime> _getDates(DateTime baseDate, WindowCleaningProvider provider) {
    final daysInMonth = DateTime(baseDate.year, baseDate.month + 1, 0).day;
    final dates = <DateTime>[];

    for (int day = 1; day <= daysInMonth; day++) {
      dates.add(DateTime(baseDate.year, baseDate.month, day));
    }

    // Add days from next month if there are jobs
    if (provider.hasJobsInNextMonth(baseDate)) {
      final nextMonth = DateTime(baseDate.year, baseDate.month + 1, 1);
      final nextMonthDays =
          DateTime(nextMonth.year, nextMonth.month + 1, 0).day;
      for (int day = 1; day <= nextMonthDays; day++) {
        dates.add(DateTime(nextMonth.year, nextMonth.month, day));
      }
    }

    return dates;
  }

  void _scrollToToday(List<DateTime> dates) {
    if (_hasScrolledToToday || !_horizontalScrollController.hasClients) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final today = DateTime.now();
      final todayIndex = dates.indexWhere(
        (date) =>
            date.year == today.year &&
            date.month == today.month &&
            date.day == today.day,
      );

      if (todayIndex != -1 && _horizontalScrollController.hasClients) {
        final offset = todayIndex * cellWidth - 100;
        final maxScroll = _horizontalScrollController.position.maxScrollExtent;
        final targetOffset = offset.clamp(0.0, maxScroll);

        _horizontalScrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
        _hasScrolledToToday = true;
      }
    });
  }

  List<String> _getTimeSlots() {
    if (_cachedTimeSlots != null) return _cachedTimeSlots!;

    final timeSlots = <String>[];
    // Generate from 08:00 to 16:00 with 30-minute intervals
    for (int hour = 8; hour <= 16; hour++) {
      timeSlots.add('${hour.toString().padLeft(2, '0')}:00');
      if (hour < 16) {
        timeSlots.add('${hour.toString().padLeft(2, '0')}:30');
      }
    }

    _cachedTimeSlots = timeSlots;
    return timeSlots;
  }

  List<DateTime> _getCachedDates(
      DateTime baseDate, WindowCleaningProvider provider) {
    if (_cachedDates != null &&
        _cachedCurrentMonth != null &&
        _cachedCurrentMonth!.year == baseDate.year &&
        _cachedCurrentMonth!.month == baseDate.month) {
      return _cachedDates!;
    }

    _cachedCurrentMonth = baseDate;
    _cachedDates = _getDates(baseDate, provider);
    return _cachedDates!;
  }

  static const double cellWidth = 250.0;
  static const double headerHeight = 60.0;

  @override
  Widget build(BuildContext context) {
    final bool isFullview = context.watch<TogglerProvider>().isFullview;
    return Consumer2<WindowCleaningProvider, ScaleProvider>(
      builder: (context, windowCleaningProvider, scaleProvider, child) {
        if (_currentMonthDisplay !=
            windowCleaningProvider.currentMonthDisplay) {
          _currentMonthDisplay = windowCleaningProvider.currentMonthDisplay;
          _hasScrolledToToday = false;
          _cachedDates = null;
          _cachedCurrentMonth = null;
        }

        final currentMonth = windowCleaningProvider.currentMonth;
        final dates = _getCachedDates(currentMonth, windowCleaningProvider);
        final timeSlots = _getTimeSlots();

        final double rowHeight = isFullview
            ? 90.0 * scaleProvider.scale
            : 32.0 * scaleProvider.scale;

        _scrollToToday(dates);

        return Column(
          children: [
            // Month navigation
            MonthNavigationWidget(
              currentMonthDisplay: windowCleaningProvider.currentMonthDisplay,
              onPreviousMonth: () async {
                final newMonth = DateTime(currentMonth.year,
                    currentMonth.month - 1, currentMonth.day);
                await windowCleaningProvider.changeMonth(newMonth);
              },
              onNextMonth: () async {
                final newMonth = DateTime(currentMonth.year,
                    currentMonth.month + 1, currentMonth.day);
                await windowCleaningProvider.changeMonth(newMonth);
              },
              onCurrentMonth: () async {
                await windowCleaningProvider.changeMonth(DateTime.now());
              },
              onMonthSelected: (String monthId) async {
                // Parse monthId like "Jan 2026" to DateTime
                final parts = monthId.split(' ');
                if (parts.length == 2) {
                  final monthNames = [
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
                    'Dec'
                  ];
                  final monthIndex = monthNames.indexOf(parts[0]) + 1;
                  final year = int.tryParse(parts[1]);
                  if (monthIndex > 0 && year != null) {
                    await windowCleaningProvider
                        .changeMonth(DateTime(year, monthIndex, 1));
                  }
                }
              },
              availableMonths: Future.value(<String>[]),
              onRefresh: windowCleaningProvider.refresh,
            ),

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
                    columnCount: dates.length + 1,
                    rowCount: timeSlots.length + 1,
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
                          return TableViewCell(
                            child: Card(
                              key: const ValueKey('header_corner'),
                              child: Center(
                                child: Text(
                                  'Time',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ),
                            ),
                          );
                        } else {
                          // Date headers
                          final date = dates[vicinity.column - 1];
                          final dateKey = 'header_${date.toIso8601String()}';
                          final today = DateTime.now();
                          final isToday = date.year == today.year &&
                              date.month == today.month &&
                              date.day == today.day;

                          return TableViewCell(
                            child: Card(
                              key: ValueKey(dateKey),
                              color: isToday
                                  ? Theme.of(context)
                                      .primaryColor
                                      .withValues(alpha: 0.2)
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      _getMonthAbbreviation(date.month),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontSize: 10,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${date.day}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      DateFormat('EEE').format(date),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontSize: 10,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }
                      } else {
                        // Data cells
                        if (vicinity.column == 0) {
                          // Time slot labels
                          final timeSlotIndex = vicinity.row - 1;
                          final timeSlot = timeSlots[timeSlotIndex];

                          return TableViewCell(
                            child: Card(
                              child: Center(
                                child: Text(
                                  timeSlot,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          );
                        } else {
                          // Job cells
                          final date = dates[vicinity.column - 1];
                          final timeSlotIndex = vicinity.row - 1;
                          final timeSlot = timeSlots[timeSlotIndex];

                          // Get jobs for this cell
                          final jobs = windowCleaningProvider
                              .getJobsOccupyingSlot(date, timeSlot);

                          return TableViewCell(
                            child: Card(
                              color: jobs.isNotEmpty
                                  ? Colors.blue.withValues(alpha: 0.3)
                                  : null,
                              child: jobs.isEmpty
                                  ? const SizedBox.shrink()
                                  : Padding(
                                      padding: const EdgeInsets.all(4.0),
                                      child: SingleChildScrollView(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: jobs.map((job) {
                                            return Container(
                                              margin: const EdgeInsets.only(
                                                  bottom: 2),
                                              padding: const EdgeInsets.all(4),
                                              decoration: BoxDecoration(
                                                color: Colors.blue,
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    job.client,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 12,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    maxLines: 1,
                                                  ),
                                                  Text(
                                                    job.location,
                                                    style: const TextStyle(
                                                      color: Colors.white70,
                                                      fontSize: 10,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    maxLines: 1,
                                                  ),
                                                  if (job.amount > 0)
                                                    Text(
                                                      'R ${job.amount.toStringAsFixed(2)}',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      ),
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
      },
    );
  }
}
