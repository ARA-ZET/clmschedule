import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DateFilterWidget extends StatefulWidget {
  final String currentFilter; // 'all', 'single', 'range'
  final DateTime? startDate;
  final DateTime? endDate;
  final Function({
    required String filterType,
    DateTime? startDate,
    DateTime? endDate,
  }) onFilterChanged;
  final VoidCallback onClear;

  const DateFilterWidget({
    super.key,
    required this.currentFilter,
    this.startDate,
    this.endDate,
    required this.onFilterChanged,
    required this.onClear,
  });

  @override
  State<DateFilterWidget> createState() => _DateFilterWidgetState();
}

class _DateFilterWidgetState extends State<DateFilterWidget> {
  late String _selectedFilter;
  DateTime? _tempStartDate;
  DateTime? _tempEndDate;

  @override
  void initState() {
    super.initState();
    _selectedFilter = widget.currentFilter;
    _tempStartDate = widget.startDate;
    _tempEndDate = widget.endDate;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        title: Row(
          children: [
            const Icon(Icons.date_range, size: 20),
            const SizedBox(width: 8),
            Text(
              _getFilterDisplayText(),
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.currentFilter != 'all')
              IconButton(
                icon: const Icon(Icons.clear, size: 16),
                onPressed: () {
                  setState(() {
                    _selectedFilter = 'all';
                    _tempStartDate = null;
                    _tempEndDate = null;
                  });
                  widget.onClear();
                },
                tooltip: 'Clear date filter',
              ),
            const Icon(Icons.expand_more),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Filter type selection
                const Text(
                  'Filter by Date:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),

                // Radio buttons for filter type
                Column(
                  children: [
                    RadioListTile<String>(
                      title: const Text('Show all dates'),
                      value: 'all',
                      groupValue: _selectedFilter,
                      onChanged: (value) {
                        setState(() {
                          _selectedFilter = value!;
                          _tempStartDate = null;
                          _tempEndDate = null;
                        });
                        _applyFilter();
                      },
                    ),
                    RadioListTile<String>(
                      title: const Text('Single day'),
                      value: 'single',
                      groupValue: _selectedFilter,
                      onChanged: (value) {
                        setState(() {
                          _selectedFilter = value!;
                          _tempEndDate = null;
                        });
                      },
                    ),
                    RadioListTile<String>(
                      title: const Text('Date range'),
                      value: 'range',
                      groupValue: _selectedFilter,
                      onChanged: (value) {
                        setState(() {
                          _selectedFilter = value!;
                        });
                      },
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Date selection based on filter type
                if (_selectedFilter == 'single') ...[
                  const Text(
                    'Select Date:',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(
                            _tempStartDate != null
                                ? DateFormat('MMM dd, yyyy')
                                    .format(_tempStartDate!)
                                : 'Select date',
                          ),
                          onPressed: () => _selectSingleDate(),
                        ),
                      ),
                    ],
                  ),
                ] else if (_selectedFilter == 'range') ...[
                  const Text(
                    'Select Date Range:',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(
                            _tempStartDate != null
                                ? DateFormat('MMM dd, yyyy')
                                    .format(_tempStartDate!)
                                : 'Start date',
                          ),
                          onPressed: () => _selectStartDate(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('to'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(
                            _tempEndDate != null
                                ? DateFormat('MMM dd, yyyy')
                                    .format(_tempEndDate!)
                                : 'End date',
                          ),
                          onPressed: () => _selectEndDate(),
                        ),
                      ),
                    ],
                  ),
                ],

                if (_selectedFilter != 'all') ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _selectedFilter = 'all';
                            _tempStartDate = null;
                            _tempEndDate = null;
                          });
                          widget.onClear();
                        },
                        child: const Text('Clear'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _canApplyFilter() ? _applyFilter : null,
                        child: const Text('Apply'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getFilterDisplayText() {
    switch (widget.currentFilter) {
      case 'single':
        if (widget.startDate != null) {
          return 'Date: ${DateFormat('MMM dd, yyyy').format(widget.startDate!)}';
        }
        return 'Single date filter';
      case 'range':
        if (widget.startDate != null && widget.endDate != null) {
          return 'Range: ${DateFormat('MMM dd').format(widget.startDate!)} - ${DateFormat('MMM dd, yyyy').format(widget.endDate!)}';
        }
        return 'Date range filter';
      default:
        return 'Filter by date';
    }
  }

  bool _canApplyFilter() {
    if (_selectedFilter == 'all') return true;
    if (_selectedFilter == 'single') return _tempStartDate != null;
    if (_selectedFilter == 'range') {
      return _tempStartDate != null && _tempEndDate != null;
    }
    return false;
  }

  void _applyFilter() {
    widget.onFilterChanged(
      filterType: _selectedFilter,
      startDate: _tempStartDate,
      endDate: _tempEndDate,
    );
  }

  Future<void> _selectSingleDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _tempStartDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );

    if (date != null) {
      setState(() {
        _tempStartDate = date;
      });
    }
  }

  Future<void> _selectStartDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _tempStartDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: _tempEndDate ?? DateTime(2030),
    );

    if (date != null) {
      setState(() {
        _tempStartDate = date;
        // Reset end date if it's before start date
        if (_tempEndDate != null && _tempEndDate!.isBefore(date)) {
          _tempEndDate = null;
        }
      });
    }
  }

  Future<void> _selectEndDate() async {
    if (_tempStartDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a start date first')),
      );
      return;
    }

    final date = await showDatePicker(
      context: context,
      initialDate: _tempEndDate ?? _tempStartDate!.add(const Duration(days: 1)),
      firstDate: _tempStartDate!,
      lastDate: DateTime(2030),
    );

    if (date != null) {
      setState(() {
        _tempEndDate = date;
      });
    }
  }
}
