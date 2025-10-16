import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class SimpleDateFilter extends StatefulWidget {
  final DateTime? startDate;
  final DateTime? endDate;
  final Function(DateTime date) onSingleDateSelected;
  final Function(DateTime startDate, DateTime endDate) onDateRangeSelected;
  final VoidCallback onClear;

  const SimpleDateFilter({
    super.key,
    this.startDate,
    this.endDate,
    required this.onSingleDateSelected,
    required this.onDateRangeSelected,
    required this.onClear,
  });

  @override
  State<SimpleDateFilter> createState() => _SimpleDateFilterState();
}

class _SimpleDateFilterState extends State<SimpleDateFilter> {
  DateTime? _tempStartDate;
  DateTime? _tempEndDate;

  @override
  void initState() {
    super.initState();
    _tempStartDate = widget.startDate;
    _tempEndDate = widget.endDate;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _showDatePicker,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(4),
          color: (_tempStartDate != null)
              ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.1)
              : null,
        ),
        child: Row(
          children: [
            Icon(
              Icons.date_range,
              size: 20,
              color: (_tempStartDate != null)
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade600,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _getDisplayText(),
                style: TextStyle(
                  fontSize: 14,
                  color: (_tempStartDate != null)
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_tempStartDate != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () {
                  widget.onClear();
                  setState(() {
                    _tempStartDate = null;
                    _tempEndDate = null;
                  });
                },
                child: Icon(
                  Icons.clear,
                  size: 16,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getDisplayText() {
    if (_tempStartDate == null) {
      return 'Filter by date';
    }

    if (_tempEndDate != null) {
      // Range mode
      return '${DateFormat('MMM dd').format(_tempStartDate!)} - ${DateFormat('MMM dd, yyyy').format(_tempEndDate!)}';
    } else {
      // Single date mode
      return DateFormat('MMM dd, yyyy').format(_tempStartDate!);
    }
  }

  void _showDatePicker() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return _SimpleDatePickerDialog(
          initialStartDate: _tempStartDate,
          initialEndDate: _tempEndDate,
          onDateSelected: _handleDateSelection,
        );
      },
    );
  }

  void _handleDateSelection(DateTime? startDate, DateTime? endDate) {
    setState(() {
      _tempStartDate = startDate;
      _tempEndDate = endDate;
    });

    if (startDate != null) {
      if (endDate != null) {
        // Range selected
        widget.onDateRangeSelected(startDate, endDate);
      } else {
        // Single date selected
        widget.onSingleDateSelected(startDate);
      }
    }
  }
}

class _SimpleDatePickerDialog extends StatefulWidget {
  final DateTime? initialStartDate;
  final DateTime? initialEndDate;
  final Function(DateTime? startDate, DateTime? endDate) onDateSelected;

  const _SimpleDatePickerDialog({
    this.initialStartDate,
    this.initialEndDate,
    required this.onDateSelected,
  });

  @override
  State<_SimpleDatePickerDialog> createState() =>
      _SimpleDatePickerDialogState();
}

class _SimpleDatePickerDialogState extends State<_SimpleDatePickerDialog> {
  DateTime? _startDate;
  DateTime? _endDate;
  DateTime _displayMonth = DateTime.now();

  @override
  void initState() {
    super.initState();
    _startDate = widget.initialStartDate;
    _endDate = widget.initialEndDate;
    if (_startDate != null) {
      _displayMonth = DateTime(_startDate!.year, _startDate!.month);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.date_range, color: Colors.blue),
          const SizedBox(width: 8),
          const Text('Select Date'),
          const Spacer(),
          if (_startDate != null)
            TextButton(
              onPressed: () {
                setState(() {
                  _startDate = null;
                  _endDate = null;
                });
              },
              child: const Text('Clear'),
            ),
        ],
      ),
      content: SizedBox(
        width: 320,
        height: 400,
        child: Column(
          children: [
            // Instructions
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: const Text(
                'Click a date for single day filter.\nClick two dates for date range filter.',
                style: TextStyle(fontSize: 12, color: Colors.blue),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),

            // Month navigation
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: () {
                    setState(() {
                      _displayMonth =
                          DateTime(_displayMonth.year, _displayMonth.month - 1);
                    });
                  },
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  DateFormat('MMMM yyyy').format(_displayMonth),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _displayMonth =
                          DateTime(_displayMonth.year, _displayMonth.month + 1);
                    });
                  },
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),

            // Calendar grid
            Expanded(
              child: _buildCalendarGrid(),
            ),

            // Selected dates display
            if (_startDate != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Column(
                  children: [
                    Text(
                      _endDate != null
                          ? 'Range: ${DateFormat('MMM dd').format(_startDate!)} - ${DateFormat('MMM dd, yyyy').format(_endDate!)}'
                          : 'Single: ${DateFormat('MMM dd, yyyy').format(_startDate!)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.green),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _startDate != null
              ? () {
                  widget.onDateSelected(_startDate, _endDate);
                  Navigator.of(context).pop();
                }
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _buildCalendarGrid() {
    final firstDayOfMonth =
        DateTime(_displayMonth.year, _displayMonth.month, 1);
    final lastDayOfMonth =
        DateTime(_displayMonth.year, _displayMonth.month + 1, 0);
    final firstWeekdayOfMonth = firstDayOfMonth.weekday % 7; // Sunday = 0

    final days = <Widget>[];

    // Add weekday headers
    const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    for (final weekday in weekdays) {
      days.add(
        Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.all(8),
          child: Text(
            weekday,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ),
      );
    }

    // Add empty cells for days before the first day of the month
    for (int i = 0; i < firstWeekdayOfMonth; i++) {
      days.add(const SizedBox());
    }

    // Add day cells
    for (int day = 1; day <= lastDayOfMonth.day; day++) {
      final date = DateTime(_displayMonth.year, _displayMonth.month, day);
      days.add(_buildDayCell(date));
    }

    return GridView.count(
      crossAxisCount: 7,
      children: days,
    );
  }

  Widget _buildDayCell(DateTime date) {
    final isSelected = _isDateSelected(date);
    final isInRange = _isDateInRange(date);
    final isToday = _isSameDay(date, DateTime.now());

    return GestureDetector(
      onTap: () => _selectDate(date),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blue
              : isInRange
                  ? Colors.blue.shade100
                  : isToday
                      ? Colors.grey.shade200
                      : null,
          borderRadius: BorderRadius.circular(8),
          border: isToday ? Border.all(color: Colors.grey.shade400) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          date.day.toString(),
          style: TextStyle(
            color: isSelected
                ? Colors.white
                : isInRange
                    ? Colors.blue.shade700
                    : Colors.black87,
            fontWeight:
                isSelected || isInRange ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  bool _isDateSelected(DateTime date) {
    return (_startDate != null && _isSameDay(date, _startDate!)) ||
        (_endDate != null && _isSameDay(date, _endDate!));
  }

  bool _isDateInRange(DateTime date) {
    if (_startDate == null || _endDate == null) return false;
    return date.isAfter(_startDate!) && date.isBefore(_endDate!);
  }

  bool _isSameDay(DateTime date1, DateTime date2) {
    return date1.year == date2.year &&
        date1.month == date2.month &&
        date1.day == date2.day;
  }

  void _selectDate(DateTime date) {
    setState(() {
      if (_startDate == null) {
        // First date selection
        _startDate = date;
        _endDate = null;
      } else if (_endDate == null) {
        // Second date selection
        if (date.isBefore(_startDate!)) {
          // If second date is before first, swap them
          _endDate = _startDate;
          _startDate = date;
        } else if (_isSameDay(date, _startDate!)) {
          // If same date clicked, keep as single date
          _endDate = null;
        } else {
          // Normal range selection
          _endDate = date;
        }
      } else {
        // Reset and start over
        _startDate = date;
        _endDate = null;
      }
    });
  }
}
