import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../providers/job_type_provider.dart';
import '../models/custom_job_type.dart';

class JobTypeManagementDialog extends riverpod.ConsumerStatefulWidget {
  const JobTypeManagementDialog({super.key});

  @override
  riverpod.ConsumerState<JobTypeManagementDialog> createState() =>
      _JobTypeManagementDialogState();
}

class _JobTypeManagementDialogState
    extends riverpod.ConsumerState<JobTypeManagementDialog> {
  final TextEditingController _labelController = TextEditingController();
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
    });
  }

  void _startEdit(CustomJobType jobType) {
    setState(() {
      _isAdding = false;
      _editingId = jobType.id;
      _labelController.text = jobType.label;
    });
  }

  void _cancelEdit() {
    setState(() {
      _isAdding = false;
      _editingId = null;
      _labelController.clear();
    });
  }

  Future<void> _save() async {
    if (_labelController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a label')),
      );
      return;
    }

    final provider = ref.read(jobTypeRiverpod);

    try {
      if (_isAdding) {
        await provider.addJobType(_labelController.text.trim());
      } else if (_editingId != null) {
        await provider.updateJobType(_editingId!, _labelController.text.trim());
      }
      _cancelEdit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _delete(String id, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Job Type'),
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
      final provider = ref.read(jobTypeRiverpod);
      try {
        await provider.deleteJobType(id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        final provider = ref.watch(jobTypeRiverpod);
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.work_outline),
              const SizedBox(width: 8),
              const Text('Manage Job Types'),
              const Spacer(),
              if (!_isAdding && _editingId == null)
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Colors.green),
                  onPressed: _startAdd,
                  tooltip: 'Add Job Type',
                ),
            ],
          ),
          content: SizedBox(
            width: 400,
            height: 500,
            child: Column(
              children: [
                if (_isAdding || _editingId != null) ...[
                  _buildEditCard(),
                  const SizedBox(height: 8),
                  const Divider(),
                ],
                Expanded(
                  child: ListView.builder(
                    itemCount: provider.jobTypes.length,
                    itemBuilder: (context, index) {
                      final jobType = provider.jobTypes[index];
                      final isEditing = _editingId == jobType.id;
                      return ListTile(
                        leading: Icon(
                          jobType.isDefault
                              ? Icons.lock_outline
                              : Icons.work_outline,
                          color: jobType.isDefault ? Colors.grey : Colors.blue,
                          size: 20,
                        ),
                        title: Text(
                          jobType.label,
                          style: TextStyle(
                            fontWeight:
                                isEditing ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 18),
                              onPressed: () => _startEdit(jobType),
                              tooltip: 'Edit',
                            ),
                            if (!jobType.isDefault)
                              IconButton(
                                icon: const Icon(Icons.delete,
                                    size: 18, color: Colors.red),
                                onPressed: () =>
                                    _delete(jobType.id, jobType.label),
                                tooltip: 'Delete',
                              ),
                          ],
                        ),
                      );
                    },
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
          ],
        );
      },
    );
  }

  Widget _buildEditCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isAdding ? 'Add New Job Type' : 'Edit Job Type',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Job Type Label',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              onSubmitted: (_) => _save(),
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
                  onPressed: _save,
                  child: Text(_isAdding ? 'Add' : 'Update'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
