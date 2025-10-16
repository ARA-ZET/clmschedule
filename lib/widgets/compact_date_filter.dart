import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class CompactDateFilter extends StatefulWidget {
  final String currentFilter; // 'all', 'single', 'range'
  final DateTime? startDate;
  final DateTime? endDate;
  final Function({
    required String filterType,
    DateTime? startDate,
    DateTime? endDate,
  }) onFilterChanged;
  final VoidCallback onClear;

  const CompactDateFilter({
    super.key,
    required this.currentFilter,
    this.startDate,
    this.endDate,
    required this.onFilterChanged,
    required this.onClear,
  });

  @override
  State<CompactDateFilter> createState() => _CompactDateFilterState();
}

class _CompactDateFilterState extends State<CompactDateFilter> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _showDateFilterPopup,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(4),
          color: widget.currentFilter != 'all'
              ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.1)
              : null,
        ),
        child: Row(
          children: [
            Icon(
              Icons.date_range,
              size: 20,
              color: widget.currentFilter != 'all'
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade600,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _getDisplayText(),
                style: TextStyle(
                  fontSize: 14,
                  color: widget.currentFilter != 'all'
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.currentFilter != 'all') ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () {
                  widget.onClear();
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
    switch (widget.currentFilter) {
      case 'single':
        if (widget.startDate != null) {
          return DateFormat('MMM dd, yyyy').format(widget.startDate!);
        }
        return 'Select date';
      case 'range':
        if (widget.startDate != null && widget.endDate != null) {
          return '${DateFormat('MMM dd').format(widget.startDate!)} - ${DateFormat('MMM dd, yyyy').format(widget.endDate!)}';
        } else if (widget.startDate != null) {
          return '${DateFormat('MMM dd, yyyy').format(widget.startDate!)} - End date';
        }
        return 'Select range';
      default:
        return 'Filter by date';
    }
  }

  void _showDateFilterPopup() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return _DateFilterDialog(
          currentFilter: widget.currentFilter,
          startDate: widget.startDate,
          endDate: widget.endDate,
          onFilterChanged: widget.onFilterChanged,
          onClear: widget.onClear,
        );
      },
    );
  }
}

class _DateFilterDialog extends StatefulWidget {
  final String currentFilter;
  final DateTime? startDate;
  final DateTime? endDate;
  final Function({
    required String filterType,
    DateTime? startDate,
    DateTime? endDate,
  }) onFilterChanged;
  final VoidCallback onClear;

  const _DateFilterDialog({
    required this.currentFilter,
    this.startDate,
    this.endDate,
    required this.onFilterChanged,
    required this.onClear,
  });

  @override
  State<_DateFilterDialog> createState() => _DateFilterDialogState();
}

class _DateFilterDialogState extends State<_DateFilterDialog> {
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
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.date_range, color: Colors.blue),
          SizedBox(width: 8),
          Text('Filter by Date'),
        ],
      ),
      content: SizedBox(
        width: 350,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Filter type selection
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

            const SizedBox(height: 16),

            // Date selection based on filter type
            if (_selectedFilter == 'single') ...[
              const Text(
                'Select Date:',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blue.shade300),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.blue.shade50,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _selectSingleDate,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.calendar_today,
                              size: 20, color: Colors.blue.shade700),
                          const SizedBox(width: 8),
                          Text(
                            _tempStartDate != null
                                ? DateFormat('EEEE, MMM dd, yyyy')
                                    .format(_tempStartDate!)
                                : 'Click to select date',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ] else if (_selectedFilter == 'range') ...[
              const Text(
                'Select Date Range:',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),

              // Start date
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.green.shade300),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.green.shade50,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _selectStartDate,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.calendar_today,
                              size: 20, color: Colors.green.shade700),
                          const SizedBox(width: 8),
                          Text(
                            _tempStartDate != null
                                ? 'From: ${DateFormat('MMM dd, yyyy').format(_tempStartDate!)}'
                                : 'Click to select start date',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.green.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // End date
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.orange.shade300),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.orange.shade50,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _selectEndDate,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.calendar_today,
                              size: 20, color: Colors.orange.shade700),
                          const SizedBox(width: 8),
                          Text(
                            _tempEndDate != null
                                ? 'To: ${DateFormat('MMM dd, yyyy').format(_tempEndDate!)}'
                                : 'Click to select end date',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.orange.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        if (_selectedFilter != 'all')
          TextButton(
            onPressed: () {
              widget.onClear();
              Navigator.of(context).pop();
            },
            child: const Text('Clear'),
          ),
        ElevatedButton(
          onPressed: _canApplyFilter() ? _applyFilter : null,
          child: const Text('Apply'),
        ),
      ],
    );
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
    Navigator.of(context).pop();
  }

  Future<void> _selectSingleDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _tempStartDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: Colors.blue,
                  onPrimary: Colors.white,
                ),
          ),
          child: child!,
        );
      },
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
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: Colors.green,
                  onPrimary: Colors.white,
                ),
          ),
          child: child!,
        );
      },
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
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: Colors.orange,
                  onPrimary: Colors.white,
                ),
          ),
          child: child!,
        );
      },
    );

    if (date != null) {
      setState(() {
        _tempEndDate = date;
      });
    }
  }
}
