import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_project.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/auth_provider.dart';

class HappySunCheckinDialog extends StatefulWidget {
  final HappySunProject project;

  const HappySunCheckinDialog({
    super.key,
    required this.project,
  });

  @override
  State<HappySunCheckinDialog> createState() => _HappySunCheckinDialogState();
}

class _HappySunCheckinDialogState extends State<HappySunCheckinDialog> {
  final _notesController = TextEditingController();
  final List<String> _missingTools = [];
  final Map<String, int> _returnedQuantities = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initializeReturnedTools();
  }

  void _initializeReturnedTools() {
    // Initialize with all checked out tools
    final checkout = widget.project.checkout;
    if (checkout != null) {
      for (var tool in checkout.tools) {
        _returnedQuantities[tool.toolId] = tool.quantity;
      }
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final checkout = widget.project.checkout;

    if (checkout == null || checkout.tools.isEmpty) {
      return AlertDialog(
        title: const Text('Check-in'),
        content: const Text('No tools were checked out for this project.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Check-in Tools'),
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
                'Verify returned tools:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...checkout.tools.map((tool) => _buildToolCheckItem(tool)),
              const SizedBox(height: 16),
              if (_missingTools.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    border: Border.all(color: Colors.red),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.warning, color: Colors.red, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Missing Tools:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ..._missingTools.map((toolId) {
                        final tool = checkout.tools
                            .firstWhere((t) => t.toolId == toolId);
                        return Text('• ${tool.toolName}',
                            style: const TextStyle(color: Colors.red));
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
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
          onPressed: _isLoading ? null : _performCheckin,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Check In'),
        ),
      ],
    );
  }

  Widget _buildToolCheckItem(CheckedOutTool tool) {
    final isReturned = !_missingTools.contains(tool.toolId);
    final returnedQty = _returnedQuantities[tool.toolId] ?? tool.quantity;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: isReturned,
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _missingTools.remove(tool.toolId);
                      } else {
                        _missingTools.add(tool.toolId);
                      }
                    });
                  },
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tool.toolName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          decoration: isReturned
                              ? TextDecoration.none
                              : TextDecoration.lineThrough,
                        ),
                      ),
                      Text(
                        'Category: ${tool.category}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (isReturned && tool.quantity > 1) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 48), // Align with checkbox
                  const Text('Returned quantity: '),
                  const SizedBox(width: 8),
                  Container(
                    width: 60,
                    height: 32,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            onPressed: returnedQty > 0
                                ? () {
                                    setState(() {
                                      _returnedQuantities[tool.toolId] =
                                          returnedQty - 1;
                                    });
                                  }
                                : null,
                            icon: const Icon(Icons.remove),
                          ),
                        ),
                        Text('$returnedQty'),
                        Expanded(
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            onPressed: returnedQty < tool.quantity
                                ? () {
                                    setState(() {
                                      _returnedQuantities[tool.toolId] =
                                          returnedQty + 1;
                                    });
                                  }
                                : null,
                            icon: const Icon(Icons.add),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(' / ${tool.quantity}'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _performCheckin() async {
    setState(() {
      _isLoading = true;
    });

    final checkout = widget.project.checkout!;
    final returnedTools = checkout.tools
        .where((tool) => !_missingTools.contains(tool.toolId))
        .map((tool) {
      final returnedQty = _returnedQuantities[tool.toolId] ?? tool.quantity;
      return CheckedOutTool(
        toolId: tool.toolId,
        toolName: tool.toolName,
        category: tool.category,
        quantity: returnedQty,
      );
    }).toList();

    final projectProvider = context.read<HappySunProjectProvider>();
    final authProvider = context.read<AuthProvider>();
    final userId = authProvider.user?.uid ?? 'unknown';

    final success = await projectProvider.performCheckin(
      projectId: widget.project.id,
      returnedTools: returnedTools,
      missingTools: _missingTools,
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
          SnackBar(
            content: Text(
              _missingTools.isEmpty
                  ? 'Check-in completed successfully'
                  : 'Check-in completed with ${_missingTools.length} missing tools',
            ),
            backgroundColor:
                _missingTools.isEmpty ? Colors.green : Colors.orange,
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
