import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../models/collection_job.dart';
import '../providers/collection_schedule_provider.dart';
import '../providers/scale_provider.dart';
import 'month_navigation_widget.dart';

extension VehicleTypeExtension on VehicleType {
  String get displayName {
    switch (this) {
      case VehicleType.hyundai:
        return 'Hyundai';
      case VehicleType.mahindra:
        return 'Mahindra';
      case VehicleType.nissan:
        return 'Nissan';
    }
  }
}

extension TrailerTypeExtension on TrailerType {
  String get displayName {
    switch (this) {
      case TrailerType.bigTrailer:
        return 'Big Trailer';
      case TrailerType.smallTrailer:
        return 'Small Trailer';
      case TrailerType.noTrailer:
        return 'No Trailer';
    }
  }
}

class CollectionScheduleGrid extends StatefulWidget {
  const CollectionScheduleGrid({super.key});

  @override
  State<CollectionScheduleGrid> createState() => _CollectionScheduleGridState();
}

class _CollectionScheduleGridState extends State<CollectionScheduleGrid> {
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

  // Generate list of days for the current month plus the next month
  List<DateTime> _getDates(DateTime baseDate) {
    // Get first day of the current month
    final firstDayOfMonth = DateTime(baseDate.year, baseDate.month, 1);

    // Get last day of the current month only
    final lastDayOfCurrentMonth =
        DateTime(baseDate.year, baseDate.month + 1, 0);

    // Calculate total days in the current month
    final totalDays =
        lastDayOfCurrentMonth.difference(firstDayOfMonth).inDays + 1;

    // Generate all dates in the range (current month only)
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
            final viewportWidth = MediaQuery.of(context).size.width;
            const pinnedColumnWidth = 150.0; // Width of time slot column
            final availableWidth = viewportWidth - pinnedColumnWidth;
            const cellWidth = 200.0;

            // Calculate position to center today's column
            final targetPosition = (todayIndex * cellWidth) -
                (availableWidth / 2) +
                (cellWidth / 2);
            final maxScrollExtent =
                _horizontalScrollController.position.maxScrollExtent;
            final scrollPosition = targetPosition.clamp(0.0, maxScrollExtent);

            _horizontalScrollController.animateTo(
              scrollPosition,
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeInOut,
            );
            _hasScrolledToToday = true;
          }
        });
      }
    }
  }

  // Generate time slots from 08:00 to 16:00
  List<int> _getTimeSlots() {
    return List.generate(9, (index) => 8 + index); // 8, 9, 10, ..., 16
  }

  static const double cellWidth = 250.0;
  static const double headerHeight = 60.0;

  @override
  Widget build(BuildContext context) {
    return Consumer2<CollectionScheduleProvider, ScaleProvider>(
      builder: (context, collectionProvider, scaleProvider, child) {
        // Check if month changed and reset scroll state
        if (_currentMonthDisplay != collectionProvider.currentMonthDisplay) {
          _currentMonthDisplay = collectionProvider.currentMonthDisplay;
          _hasScrolledToToday = false;
        }

        final currentMonth = collectionProvider.currentMonth;
        final dates = _getDates(currentMonth);
        final timeSlots = _getTimeSlots();

        final double rowHeight = 80.0 * scaleProvider.scale;

        // Scroll to today if not done yet
        _scrollToToday(dates);

        return Column(
          children: [
            // Month navigation
            MonthNavigationWidget(
              currentMonthDisplay: collectionProvider.currentMonthDisplay,
              onPreviousMonth: collectionProvider.goToPreviousMonth,
              onNextMonth: collectionProvider.goToNextMonth,
              onCurrentMonth: collectionProvider.goToCurrentMonth,
              onMonthSelected: collectionProvider.goToMonth,
              availableMonths: collectionProvider.getAvailableMonths(),
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
                    columnCount: dates.length + 1, // +1 for time slot column
                    rowCount: timeSlots.length + 1, // +1 for date headers row
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
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        '${DateFormat('EEE').format(date)} ${date.day} ${_getMonthAbbreviation(date.month)}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: isToday
                                                  ? FontWeight.bold
                                                  : null,
                                              color: isToday
                                                  ? Theme.of(context)
                                                      .primaryColor
                                                  : null,
                                            ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children:
                                          VehicleType.values.map((vehicleType) {
                                        final color =
                                            _getVehicleColor(vehicleType);
                                        return Expanded(
                                          child: Text(
                                            vehicleType.name.toUpperCase(),
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: color,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }
                      } else {
                        final timeSlot = timeSlots[vicinity.row - 1];
                        if (vicinity.column == 0) {
                          // Time slot column
                          return TableViewCell(
                            child: Card(
                              child: Center(
                                child: Text(
                                  '${timeSlot.toString().padLeft(2, '0')}:00',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w500,
                                      ),
                                ),
                              ),
                            ),
                          );
                        } else {
                          // Collection job cells
                          final date = dates[vicinity.column - 1];

                          return TableViewCell(
                            child: Card(
                              child: SizedBox(
                                height: rowHeight - 8,
                                child: Column(
                                  children: [
                                    // Vehicle type tabs
                                    Expanded(
                                      child: Row(
                                        children: VehicleType.values
                                            .map((vehicleType) {
                                          final vehicleJobs = collectionProvider
                                              .getJobsForVehicleAndTimeSlot(
                                                  vehicleType, date, timeSlot);
                                          final hasJob = vehicleJobs.isNotEmpty;
                                          final color =
                                              _getVehicleColor(vehicleType);

                                          return Expanded(
                                            child: Container(
                                              margin: const EdgeInsets.all(1),
                                              decoration: BoxDecoration(
                                                color: hasJob
                                                    ? color.withOpacity(0.1)
                                                    : Colors.grey.shade50,
                                                border: Border.all(
                                                  color: hasJob
                                                      ? color
                                                      : Colors.grey.shade300,
                                                  width: hasJob ? 2 : 1,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: hasJob
                                                  ? _buildCollectionJobCard(
                                                      vehicleJobs.first, color)
                                                  : _buildAddButton(vehicleType,
                                                      date, timeSlot, color),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ],
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

  Color _getVehicleColor(VehicleType vehicleType) {
    switch (vehicleType) {
      case VehicleType.hyundai:
        return Colors.blue.shade700;
      case VehicleType.mahindra:
        return Colors.green.shade700;
      case VehicleType.nissan:
        return Colors.orange.shade700;
    }
  }

  Widget _buildCollectionJobCard(CollectionJob job, Color color) {
    return Tooltip(
      message: _buildJobTooltip(job),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Job Type
            Text(
              job.jobType,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: color,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            // Location
            Text(
              job.location,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color.withOpacity(0.9),
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (job.clients.isNotEmpty) ...[
              const SizedBox(height: 1),
              // Client
              Text(
                job.clients.first,
                style: TextStyle(
                  fontSize: 8,
                  color: color.withOpacity(0.8),
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            // Trailer Type
            if (job.trailerType != TrailerType.noTrailer) ...[
              const SizedBox(height: 1),
              Text(
                job.trailerType.displayName,
                style: TextStyle(
                  fontSize: 8,
                  color: color.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            // Staff info
            if (job.assignedStaff.isNotEmpty || job.staffCount > 0) ...[
              const SizedBox(height: 1),
              Text(
                job.assignedStaff.isNotEmpty
                    ? job.assignedStaff.join(', ')
                    : '${job.staffCount} staff needed',
                style: TextStyle(
                  fontSize: 7,
                  color: color.withOpacity(0.6),
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _buildJobTooltip(CollectionJob job) {
    final buffer = StringBuffer();
    buffer.writeln('${job.jobType} - ${job.vehicleType.displayName}');
    buffer.writeln('Location: ${job.location}');
    if (job.clients.isNotEmpty) {
      buffer.writeln('Client: ${job.clients.join(', ')}');
    }
    buffer.writeln('Trailer: ${job.trailerType.displayName}');
    if (job.assignedStaff.isNotEmpty) {
      buffer.writeln('Staff: ${job.assignedStaff.join(', ')}');
    } else if (job.staffCount > 0) {
      buffer.writeln('Staff needed: ${job.staffCount}');
    }
    if (job.notes.isNotEmpty) {
      buffer.writeln('Notes: ${job.notes}');
    }
    buffer.writeln('Status: ${job.statusId}');
    return buffer.toString().trim();
  }

  Widget _buildAddButton(
      VehicleType vehicleType, DateTime date, int timeSlot, Color color) {
    return Center(
      child: IconButton(
        icon: Icon(
          Icons.add,
          size: 16,
          color: color.withOpacity(0.5),
        ),
        onPressed: () {
          _showAddCollectionJobDialog(vehicleType, date, timeSlot);
        },
        tooltip: 'Add ${vehicleType.displayName} collection job',
      ),
    );
  }

  void _showAddCollectionJobDialog(
      VehicleType vehicleType, DateTime date, int timeSlot) {
    showDialog(
      context: context,
      builder: (context) => _AddCollectionJobDialog(
        vehicleType: vehicleType,
        date: date,
        timeSlot: timeSlot,
      ),
    );
  }
}

class _AddCollectionJobDialog extends StatefulWidget {
  final VehicleType vehicleType;
  final DateTime date;
  final int timeSlot;

  const _AddCollectionJobDialog({
    required this.vehicleType,
    required this.date,
    required this.timeSlot,
  });

  @override
  State<_AddCollectionJobDialog> createState() =>
      _AddCollectionJobDialogState();
}

class _AddCollectionJobDialogState extends State<_AddCollectionJobDialog> {
  final _locationController = TextEditingController();
  final _staffController = TextEditingController();
  TrailerType _selectedTrailerType = TrailerType.noTrailer;

  @override
  void dispose() {
    _locationController.dispose();
    _staffController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add ${widget.vehicleType.displayName} Collection Job'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${DateFormat('EEE, MMM d, y').format(widget.date)} at ${widget.timeSlot.toString().padLeft(2, '0')}:00',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade600,
                ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _locationController,
            decoration: const InputDecoration(
              labelText: 'Location',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<TrailerType>(
            initialValue: _selectedTrailerType,
            decoration: const InputDecoration(
              labelText: 'Trailer Type',
              border: OutlineInputBorder(),
            ),
            items: TrailerType.values.map((type) {
              return DropdownMenuItem(
                value: type,
                child: Text(type.displayName),
              );
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() {
                  _selectedTrailerType = value;
                });
              }
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _staffController,
            decoration: const InputDecoration(
              labelText: 'Assigned Staff (comma-separated)',
              border: OutlineInputBorder(),
              hintText: 'John, Mary, Pete',
            ),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed:
              _locationController.text.isNotEmpty ? _saveCollectionJob : null,
          child: const Text('Add Job'),
        ),
      ],
    );
  }

  void _saveCollectionJob() {
    final staff = _staffController.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final job = CollectionJob(
      id: '', // Will be set by Firestore
      vehicleType: widget.vehicleType,
      trailerType: _selectedTrailerType,
      date: widget.date,
      timeSlot: widget.timeSlot,
      location: _locationController.text.trim(),
      assignedStaff: staff,
      staffCount: staff.isEmpty ? 1 : staff.length,
      jobType: 'junk collection', // Default job type
      statusId: 'scheduled', // Default status
      clients: [], // Empty clients list initially
    );

    final provider = context.read<CollectionScheduleProvider>();
    provider.addCollectionJob(job);

    Navigator.of(context).pop();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Added ${widget.vehicleType.displayName} collection job for ${_locationController.text}'),
        backgroundColor: Colors.green,
      ),
    );
  }
}
