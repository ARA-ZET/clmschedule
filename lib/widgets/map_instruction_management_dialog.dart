import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../providers/map_instruction_provider.dart';

class MapInstructionManagementDialog extends riverpod.ConsumerStatefulWidget {
  const MapInstructionManagementDialog({super.key});

  @override
  riverpod.ConsumerState<MapInstructionManagementDialog> createState() =>
      _MapInstructionManagementDialogState();
}

class _MapInstructionManagementDialogState
    extends riverpod.ConsumerState<MapInstructionManagementDialog> {
  final _textController = TextEditingController();
  bool _isAdding = false;
  String? _editingId;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _startAdd() {
    setState(() {
      _isAdding = true;
      _editingId = null;
      _textController.clear();
    });
  }

  void _startEdit(String id, String text) {
    setState(() {
      _isAdding = false;
      _editingId = id;
      _textController.text = text;
    });
  }

  void _cancel() {
    setState(() {
      _isAdding = false;
      _editingId = null;
      _textController.clear();
    });
  }

  Future<void> _save() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an instruction')),
      );
      return;
    }
    final provider = ref.read(mapInstructionRiverpod);
    try {
      if (_isAdding) {
        await provider.addInstruction(text);
      } else if (_editingId != null) {
        await provider.updateInstruction(_editingId!, text);
      }
      _cancel();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _delete(String id, String text) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Instruction'),
        content: Text('Delete "$text"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await ref.read(mapInstructionRiverpod).deleteInstruction(id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  Widget _buildEditCard({required bool isAdding}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isAdding ? 'Add New Instruction' : 'Edit Instruction',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Instruction text',
                hintText: 'e.g. Do house only',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _cancel, child: const Text('Cancel')),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _save,
                  child: Text(isAdding ? 'Add' : 'Update'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(mapInstructionRiverpod);
    return AlertDialog(
      title: const Text('Map Instructions'),
      content: SizedBox(
        width: 400,
        height: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (provider.error != null)
              Container(
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  border: Border.all(color: Colors.red),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(provider.error!,
                    style: const TextStyle(color: Colors.red)),
              ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isAdding) ...[
                      _buildEditCard(isAdding: true),
                      const SizedBox(height: 12),
                    ],
                    if (provider.isLoading)
                      const Center(child: CircularProgressIndicator())
                    else
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: provider.instructions.length,
                        itemBuilder: (context, index) {
                          final instr = provider.instructions[index];
                          if (_editingId == instr.id) {
                            return _buildEditCard(isAdding: false);
                          }
                          return Card(
                            child: ListTile(
                              leading: const Icon(Icons.format_list_bulleted),
                              title: Text(instr.text),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit),
                                    tooltip: 'Edit',
                                    onPressed: () =>
                                        _startEdit(instr.id, instr.text),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete,
                                        color: Colors.red),
                                    tooltip: 'Delete',
                                    onPressed: () =>
                                        _delete(instr.id, instr.text),
                                  ),
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
          ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add Instruction'),
            onPressed: _startAdd,
          ),
      ],
    );
  }
}
