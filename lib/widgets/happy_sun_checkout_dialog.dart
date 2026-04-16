import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/happy_sun_project.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/inventory_provider.dart';
import '../providers/auth_provider.dart';

class HappySunCheckoutDialog extends riverpod.ConsumerStatefulWidget {
  final HappySunProject project;

  const HappySunCheckoutDialog({
    super.key,
    required this.project,
  });

  @override
  riverpod.ConsumerState<HappySunCheckoutDialog> createState() =>
      _HappySunCheckoutDialogState();
}

class _HappySunCheckoutDialogState
    extends riverpod.ConsumerState<HappySunCheckoutDialog> {
  final _notesController = TextEditingController();
  final List<CheckedOutTool> _selectedTools = [];
  bool _isLoading = false;

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Checkout Tools'),
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
              const SizedBox(height: 16),
              const Text(
                'Select tools to checkout:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              _buildToolsList(),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _addCustomTool,
                icon: const Icon(Icons.add),
                label: const Text('Add Tool'),
              ),
              const SizedBox(height: 16),
              if (_selectedTools.isNotEmpty) ...[
                const Text(
                  'Selected Tools:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ..._selectedTools.map((tool) => ListTile(
                      dense: true,
                      title: Text(tool.toolName),
                      subtitle:
                          Text('${tool.category} - Qty: ${tool.quantity}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, size: 20),
                        onPressed: () {
                          setState(() {
                            _selectedTools.remove(tool);
                          });
                        },
                      ),
                    )),
                const Divider(),
              ],
              const SizedBox(height: 8),
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
          onPressed:
              _isLoading || _selectedTools.isEmpty ? null : _performCheckout,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Check Out'),
        ),
      ],
    );
  }

  Widget _buildToolsList() {
    return Builder(
      builder: (context) {
        final inventoryProvider = ref.watch(inventoryRiverpod);
        final tools = inventoryProvider.tools;

        if (tools.isEmpty) {
          return const Text(
            'No tools available in inventory',
            style: TextStyle(color: Colors.grey),
          );
        }

        return Container(
          constraints: const BoxConstraints(maxHeight: 200),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: tools.length,
            itemBuilder: (context, index) {
              final tool = tools[index];
              return CheckboxListTile(
                dense: true,
                title: Text(tool.name),
                subtitle: Text(tool.category),
                value: _selectedTools.any((t) => t.toolId == tool.id),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _selectedTools.add(CheckedOutTool(
                        toolId: tool.id,
                        toolName: tool.name,
                        category: tool.category,
                        quantity: 1,
                      ));
                    } else {
                      _selectedTools.removeWhere((t) => t.toolId == tool.id);
                    }
                  });
                },
              );
            },
          ),
        );
      },
    );
  }

  void _addCustomTool() {
    final nameController = TextEditingController();
    final categoryController = TextEditingController(text: 'General');
    final quantityController = TextEditingController(text: '1');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Custom Tool'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Tool Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: categoryController,
              decoration: const InputDecoration(
                labelText: 'Category',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: quantityController,
              decoration: const InputDecoration(
                labelText: 'Quantity',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                setState(() {
                  _selectedTools.add(CheckedOutTool(
                    toolId: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                    toolName: nameController.text,
                    category: categoryController.text,
                    quantity: int.tryParse(quantityController.text) ?? 1,
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

  Future<void> _performCheckout() async {
    setState(() {
      _isLoading = true;
    });

    final projectProvider = ref.read(happySunProjectRiverpod);
    final authProvider = ref.read(authRiverpod);
    final userId = authProvider.user?.uid ?? 'unknown';

    final success = await projectProvider.performCheckout(
      projectId: widget.project.id,
      tools: _selectedTools,
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
            content: Text('Checkout completed successfully'),
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
