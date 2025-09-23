import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/custom_job_status.dart';
import '../providers/job_status_provider.dart';

class JobStatusManagementDialog extends StatefulWidget {
  const JobStatusManagementDialog({super.key});

  @override
  State<JobStatusManagementDialog> createState() =>
      _JobStatusManagementDialogState();
}

class _JobStatusManagementDialogState extends State<JobStatusManagementDialog> {
  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Manage Job Statuses',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Status list
            Expanded(
              child: Consumer<JobStatusProvider>(
                builder: (context, statusProvider, child) {
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: statusProvider.statuses.length,
                    itemBuilder: (context, index) {
                      final status = statusProvider.statuses[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: status.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          title: Text(status.label),
                          subtitle: status.isDefault
                              ? const Text(
                                  'Default Status',
                                  style: TextStyle(
                                    fontStyle: FontStyle.italic,
                                    fontSize: 12,
                                  ),
                                )
                              : null,
                          trailing: status.isDefault
                              ? IconButton(
                                  icon: const Icon(Icons.edit),
                                  onPressed: () =>
                                      _showEditStatusDialog(context, status),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit),
                                      onPressed: () => _showEditStatusDialog(
                                          context, status),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete),
                                      onPressed: () => _showDeleteConfirmDialog(
                                          context, status),
                                    ),
                                  ],
                                ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // Add button
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add New Status'),
                  onPressed: () => _showAddStatusDialog(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddStatusDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const _StatusFormDialog(),
    );
  }

  void _showEditStatusDialog(BuildContext context, CustomJobStatus status) {
    showDialog(
      context: context,
      builder: (context) => _StatusFormDialog(status: status),
    );
  }

  void _showDeleteConfirmDialog(BuildContext context, CustomJobStatus status) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Status'),
        content: Text(
          'Are you sure you want to delete the "${status.label}" status?\n\n'
          'This action cannot be undone. Jobs using this status will need to be updated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await context.read<JobStatusProvider>().deleteStatus(status.id);
              Navigator.of(context).pop();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _StatusFormDialog extends StatefulWidget {
  final CustomJobStatus? status; // null for add, non-null for edit

  const _StatusFormDialog({this.status});

  @override
  State<_StatusFormDialog> createState() => _StatusFormDialogState();
}

class _StatusFormDialogState extends State<_StatusFormDialog> {
  final _labelController = TextEditingController();
  Color _selectedColor = Colors.blue;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    if (widget.status != null) {
      _labelController.text = widget.status!.label;
      _selectedColor = widget.status!.color;
    }
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.status != null;

    return AlertDialog(
      title: Text(isEditing ? 'Edit Status' : 'Add New Status'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Label field
            TextFormField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Status Label',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter a status label';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Color picker
            Row(
              children: [
                Text('Color: '),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _showColorPicker(),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _selectedColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Tap to change',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saveStatus,
          child: Text(isEditing ? 'Update' : 'Add'),
        ),
      ],
    );
  }

  void _showColorPicker() {
    final colors = [
      Colors.red,
      Colors.pink,
      Colors.purple,
      Colors.deepPurple,
      Colors.indigo,
      Colors.blue,
      Colors.lightBlue,
      Colors.cyan,
      Colors.teal,
      Colors.green,
      Colors.lightGreen,
      Colors.lime,
      Colors.yellow,
      Colors.amber,
      Colors.orange,
      Colors.deepOrange,
      Colors.brown,
      Colors.grey,
      Colors.blueGrey,
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Color'),
        content: Container(
          width: 300,
          height: 200,
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: colors.length,
            itemBuilder: (context, index) {
              final color = colors[index];
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedColor = color;
                  });
                  Navigator.of(context).pop();
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _selectedColor == color
                          ? Colors.black
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _saveStatus() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final statusProvider = context.read<JobStatusProvider>();

    try {
      if (widget.status == null) {
        // Adding new status
        final newStatus = CustomJobStatus(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          label: _labelController.text.trim(),
          color: _selectedColor,
          isDefault: false,
        );
        await statusProvider.addStatus(newStatus);
      } else {
        // Updating existing status
        final updatedStatus = widget.status!.copyWith(
          label: _labelController.text.trim(),
          color: _selectedColor,
        );
        await statusProvider.updateStatus(updatedStatus);
      }

      Navigator.of(context).pop();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving status: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
