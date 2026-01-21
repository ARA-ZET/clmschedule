import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_project.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/auth_provider.dart';

class HappySunChecklistDialog extends StatefulWidget {
  final HappySunProject project;

  const HappySunChecklistDialog({
    super.key,
    required this.project,
  });

  @override
  State<HappySunChecklistDialog> createState() =>
      _HappySunChecklistDialogState();
}

class _HappySunChecklistDialogState extends State<HappySunChecklistDialog> {
  final _notesController = TextEditingController();
  final List<ChecklistItem> _checklistItems = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initializeChecklist();
  }

  void _initializeChecklist() {
    // Initialize with common checklist items
    _checklistItems.addAll([
      ChecklistItem(
        id: '1',
        name: 'All tools accounted for',
        isChecked: false,
      ),
      ChecklistItem(
        id: '2',
        name: 'Work area cleaned',
        isChecked: false,
      ),
      ChecklistItem(
        id: '3',
        name: 'Equipment properly stored',
        isChecked: false,
      ),
      ChecklistItem(
        id: '4',
        name: 'Safety gear collected',
        isChecked: false,
      ),
      ChecklistItem(
        id: '5',
        name: 'Site inspection completed',
        isChecked: false,
      ),
    ]);
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final checkedCount = _checklistItems.where((item) => item.isChecked).length;
    final totalCount = _checklistItems.length;

    return AlertDialog(
      title: const Text('Site Checklist'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Project: ${widget.project.clientName}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: totalCount > 0 ? checkedCount / totalCount : 0,
                backgroundColor: Colors.grey[300],
                valueColor: AlwaysStoppedAnimation<Color>(
                  checkedCount == totalCount ? Colors.green : Colors.blue,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$checkedCount of $totalCount items checked',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              const Text(
                'Verify all items before leaving site:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ..._checklistItems.map((item) => CheckboxListTile(
                    dense: true,
                    title: Text(item.name),
                    value: item.isChecked,
                    onChanged: (checked) {
                      setState(() {
                        final index = _checklistItems.indexOf(item);
                        _checklistItems[index] =
                            item.copyWith(isChecked: checked ?? false);
                      });
                    },
                  )),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _addCustomItem,
                icon: const Icon(Icons.add),
                label: const Text('Add Custom Item'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submitChecklist,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }

  void _addCustomItem() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Custom Item'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Item Description',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() {
                  _checklistItems.add(ChecklistItem(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: controller.text,
                    isChecked: false,
                  ));
                });
                Navigator.of(context).pop();
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _submitChecklist() async {
    setState(() {
      _isLoading = true;
    });

    final projectProvider = context.read<HappySunProjectProvider>();
    final authProvider = context.read<AuthProvider>();
    final userId = authProvider.user?.uid ?? 'unknown';

    final success = await projectProvider.performChecklist(
      projectId: widget.project.id,
      items: _checklistItems,
      notes: _notesController.text.isEmpty ? null : _notesController.text,
      userId: userId,
    );

    if (mounted) {
      setState(() {
        _isLoading = false;
      });

      if (success) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Checklist submitted successfully'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${projectProvider.error ?? "Unknown error"}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
