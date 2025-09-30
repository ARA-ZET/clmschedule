import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/job_list_status_provider.dart';
import '../models/custom_job_list_status.dart';

class JobListStatusManagementDialog extends StatefulWidget {
  const JobListStatusManagementDialog({super.key});

  @override
  State<JobListStatusManagementDialog> createState() =>
      _JobListStatusManagementDialogState();
}

class _JobListStatusManagementDialogState
    extends State<JobListStatusManagementDialog> {
  final TextEditingController _labelController = TextEditingController();
  Color _selectedColor = Colors.blue;
  bool _isAdding = false;
  String? _editingId;

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  void _startAdd() {
    setState(() {
      _isAdding = true;
      _editingId = null;
      _labelController.clear();
      _selectedColor = Colors.blue;
    });
  }

  void _startEdit(CustomJobListStatus status) {
    setState(() {
      _isAdding = false;
      _editingId = status.id;
      _labelController.text = status.label;
      _selectedColor = status.color;
    });
  }

  void _cancelEdit() {
    setState(() {
      _isAdding = false;
      _editingId = null;
      _labelController.clear();
    });
  }

  Future<void> _saveStatus() async {
    if (_labelController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a label')),
      );
      return;
    }

    final provider = Provider.of<JobListStatusProvider>(context, listen: false);

    try {
      if (_isAdding) {
        await provider.addStatus(_labelController.text.trim(), _selectedColor);
      } else if (_editingId != null) {
        await provider.updateStatus(
          _editingId!,
          _labelController.text.trim(),
          _selectedColor,
        );
      }

      _cancelEdit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving status: $e')),
        );
      }
    }
  }

  Future<void> _deleteStatus(String id, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Status'),
        content: Text('Are you sure you want to delete "$label"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final provider =
          Provider.of<JobListStatusProvider>(context, listen: false);
      try {
        await provider.deleteStatus(id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting status: $e')),
          );
        }
      }
    }
  }

  void _showColorPicker() {
    // Define 4 shades for each color family (lightest to darkest)
    final colorFamilies = {
      'Red': [
        const Color(0xFFFFEBEE), // Red 50
        const Color(0xFFEF9A9A), // Red 300
        const Color(0xFFE57373), // Red 400
        const Color(0xFFD32F2F), // Red 700
      ],
      'Blue': [
        const Color(0xFFE3F2FD), // Blue 50
        const Color(0xFF90CAF9), // Blue 300
        const Color(0xFF64B5F6), // Blue 400
        const Color(0xFF1976D2), // Blue 700
      ],
      'Green': [
        const Color(0xFFE8F5E8), // Green 50
        const Color(0xFFA5D6A7), // Green 300
        const Color(0xFF81C784), // Green 400
        const Color(0xFF388E3C), // Green 700
      ],
      'Grey': [
        const Color(0xFFFAFAFA), // Grey 50
        const Color(0xFFE0E0E0), // Grey 300
        const Color(0xFFBDBDBD), // Grey 400
        const Color(0xFF616161), // Grey 700
      ],
      'Orange': [
        const Color(0xFFFFF3E0), // Orange 50
        const Color(0xFFFFB74D), // Orange 300
        const Color(0xFFFF9800), // Orange 500
        const Color(0xFFE65100), // Orange 900
      ],
    };

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Color'),
        content: SizedBox(
          width: 320,
          height: 320,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: colorFamilies.entries.map((entry) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.key,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: entry.value.map((color) {
                          final isSelected = _selectedColor == color;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedColor = color;
                                });
                                Navigator.of(context).pop();
                              },
                              child: Container(
                                height: 40,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                decoration: BoxDecoration(
                                  color: color,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isSelected
                                        ? Colors.black
                                        : Colors.grey.withOpacity(0.3),
                                    width: isSelected ? 3 : 1,
                                  ),
                                ),
                                child: isSelected
                                    ? const Icon(
                                        Icons.check,
                                        color: Colors.white,
                                        size: 20,
                                      )
                                    : null,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<JobListStatusProvider>(
      builder: (context, provider, child) {
        return AlertDialog(
          title: const Text('Manage Job List Statuses'),
          content: SizedBox(
            width: 400,
            height: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (provider.error != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      border: Border.all(color: Colors.red),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      provider.error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isAdding || _editingId != null) ...[
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _isAdding
                                        ? 'Add New Status'
                                        : 'Edit Status',
                                    style:
                                        Theme.of(context).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 16),
                                  TextField(
                                    controller: _labelController,
                                    decoration: const InputDecoration(
                                      labelText: 'Status Label',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      const Text('Color: '),
                                      GestureDetector(
                                        onTap: _showColorPicker,
                                        child: Container(
                                          width: 40,
                                          height: 40,
                                          decoration: BoxDecoration(
                                            color: _selectedColor,
                                            border:
                                                Border.all(color: Colors.grey),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      TextButton(
                                        onPressed: _showColorPicker,
                                        child: const Text('Change Color'),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton(
                                        onPressed: _cancelEdit,
                                        child: const Text('Cancel'),
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton(
                                        onPressed: _saveStatus,
                                        child:
                                            Text(_isAdding ? 'Add' : 'Update'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (provider.isLoading)
                          const Center(child: CircularProgressIndicator())
                        else
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: provider.statuses.length,
                            itemBuilder: (context, index) {
                              final status = provider.statuses[index];
                              return Card(
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
                                      ? const Text('Default Status')
                                      : null,
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!status.isDefault) ...[
                                        IconButton(
                                          icon: const Icon(Icons.edit),
                                          onPressed: () => _startEdit(status),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete,
                                              color: Colors.red),
                                          onPressed: () => _deleteStatus(
                                              status.id, status.label),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            if (!_isAdding && _editingId == null)
              ElevatedButton(
                onPressed: _startAdd,
                child: const Text('Add Status'),
              ),
          ],
        );
      },
    );
  }
}
