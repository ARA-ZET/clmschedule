import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/job_reminder.dart';

class ReminderDialog extends StatefulWidget {
  final List<JobReminder> existingReminders;
  final String invoiceStatus;

  const ReminderDialog({
    super.key,
    this.existingReminders = const [],
    required this.invoiceStatus,
  });

  @override
  State<ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<ReminderDialog> {
  late TextEditingController _notesController;
  late DateTime _selectedDate;
  final _formKey = GlobalKey<FormState>();
  bool _showNewReminderForm = false;

  @override
  void initState() {
    super.initState();
    _notesController = TextEditingController();
    _selectedDate = DateTime.now().add(const Duration(days: 7));

    // Auto-show form if no active reminders
    _showNewReminderForm = !widget.existingReminders.any((r) => r.isActive);
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  void _setDaysFromNow(int days) {
    setState(() {
      _selectedDate = DateTime.now().add(Duration(days: days));
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeReminders =
        widget.existingReminders.where((r) => r.isActive).toList();
    final inactiveReminders =
        widget.existingReminders.where((r) => !r.isActive).toList();

    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 700),
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(Icons.alarm, color: Theme.of(context).primaryColor),
                  const SizedBox(width: 12),
                  Text(
                    'Invoice Reminders',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Active Reminders Section
              if (activeReminders.isNotEmpty) ...[
                Text(
                  'Active Reminders',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                ...activeReminders
                    .map((reminder) => _buildReminderCard(reminder, true)),
                const SizedBox(height: 16),
              ],

              // History Section - Always show if there are any reminders
              if (widget.existingReminders.isNotEmpty) ...[
                ExpansionTile(
                  initiallyExpanded:
                      inactiveReminders.isNotEmpty && activeReminders.isEmpty,
                  title: Row(
                    children: [
                      Icon(Icons.history, size: 18, color: Colors.grey[700]),
                      const SizedBox(width: 8),
                      Text(
                        'All Reminders (${widget.existingReminders.length})',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  children: [
                    if (activeReminders.isNotEmpty) ...[
                      Padding(
                        padding:
                            const EdgeInsets.only(left: 16, top: 8, bottom: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Active (${activeReminders.length})',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue[700],
                            ),
                          ),
                        ),
                      ),
                      ...activeReminders.map(
                          (reminder) => _buildReminderCard(reminder, false)),
                    ],
                    if (inactiveReminders.isNotEmpty) ...[
                      Padding(
                        padding:
                            const EdgeInsets.only(left: 16, top: 8, bottom: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'History (${inactiveReminders.length})',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                      ),
                      ...inactiveReminders.map(
                          (reminder) => _buildReminderCard(reminder, false)),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // New Reminder Form
              if (_showNewReminderForm) ...[
                const Divider(),
                const SizedBox(height: 16),
                _buildNewReminderForm(),
              ] else ...[
                const SizedBox(height: 8),
                Center(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _showNewReminderForm = true;
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add New Reminder'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReminderCard(JobReminder reminder, bool showActions) {
    final isOverdue = reminder.isOverdue;
    final statusColor = reminder.status == ReminderStatus.completed
        ? Colors.green
        : reminder.status == ReminderStatus.cancelled
            ? Colors.grey
            : isOverdue
                ? Colors.orange
                : Colors.blue;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  reminder.status == ReminderStatus.completed
                      ? Icons.check_circle
                      : reminder.status == ReminderStatus.cancelled
                          ? Icons.cancel
                          : Icons.alarm,
                  color: statusColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Due: ${DateFormat('MMM dd, yyyy').format(reminder.dueDate)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        reminder.notes,
                        style: const TextStyle(fontSize: 12),
                      ),
                      Text(
                        'Created: ${DateFormat('MMM dd, yyyy').format(reminder.createdAt)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                      if (reminder.completedAt != null)
                        Text(
                          '${reminder.status == ReminderStatus.completed ? "Completed" : "Cancelled"}: ${DateFormat('MMM dd, yyyy').format(reminder.completedAt!)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                        ),
                    ],
                  ),
                ),
                if (showActions && reminder.isActive) ...[
                  IconButton(
                    icon: const Icon(Icons.check, color: Colors.green),
                    iconSize: 20,
                    onPressed: () {
                      Navigator.of(context).pop({
                        'action': 'complete',
                        'reminder': reminder,
                      });
                    },
                    tooltip: 'Mark as completed',
                  ),
                  IconButton(
                    icon: const Icon(Icons.cancel, color: Colors.red),
                    iconSize: 20,
                    onPressed: () {
                      Navigator.of(context).pop({
                        'action': 'cancel',
                        'reminder': reminder,
                      });
                    },
                    tooltip: 'Cancel reminder',
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNewReminderForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'New Reminder',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              if (widget.existingReminders.any((r) => r.isActive))
                TextButton(
                  onPressed: () {
                    setState(() {
                      _showNewReminderForm = false;
                      _notesController.clear();
                    });
                  },
                  child: const Text('Cancel'),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Quick date buttons
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildQuickDateButton('3 days', 3),
              _buildQuickDateButton('7 days', 7),
              _buildQuickDateButton('14 days', 14),
              _buildQuickDateButton('30 days', 30),
            ],
          ),
          const SizedBox(height: 12),

          // Custom date picker
          InkWell(
            onTap: _selectDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, size: 20),
                  const SizedBox(width: 12),
                  Text(
                    DateFormat('MMM dd, yyyy').format(_selectedDate),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const Spacer(),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Notes field
          TextFormField(
            controller: _notesController,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'Add notes about this reminder...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please add notes for this reminder';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // Save button
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: () {
                if (_formKey.currentState!.validate()) {
                  final reminder = JobReminder(
                    dueDate: _selectedDate,
                    notes: _notesController.text.trim(),
                    createdAt: DateTime.now(),
                  );
                  Navigator.of(context).pop({
                    'action': 'add',
                    'reminder': reminder,
                  });
                }
              },
              icon: const Icon(Icons.save),
              label: const Text('Save Reminder'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickDateButton(String label, int days) {
    final isSelected = _selectedDate.difference(DateTime.now()).inDays == days;
    return OutlinedButton(
      onPressed: () => _setDaysFromNow(days),
      style: OutlinedButton.styleFrom(
        backgroundColor:
            isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
        side: BorderSide(
          color: isSelected
              ? Theme.of(context).primaryColor
              : Colors.grey.shade400,
        ),
      ),
      child: Text(label),
    );
  }
}
