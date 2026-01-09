import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/invoice_status_provider.dart';
import '../models/custom_invoice_status.dart';

class InvoiceStatusManagementDialog extends StatefulWidget {
  const InvoiceStatusManagementDialog({super.key});

  @override
  State<InvoiceStatusManagementDialog> createState() =>
      _InvoiceStatusManagementDialogState();
}

class _InvoiceStatusManagementDialogState
    extends State<InvoiceStatusManagementDialog> {
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

  void _startEdit(CustomInvoiceStatus status) {
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

    final provider =
        Provider.of<InvoiceStatusProvider>(context, listen: false);

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
          Provider.of<InvoiceStatusProvider>(context, listen: false);
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
    // Define 6 shades for each color family (lightest to darkest)
    final colorFamilies = {
      'Red': [
        const Color(0xFFFFEBEE), // Red 50
        const Color(0xFFEF9A9A), // Red 300
        const Color(0xFFE57373), // Red 400
        const Color(0xFFD32F2F), // Red 700
        const Color(0xFFC62828), // Red 800
        const Color.fromARGB(255, 161, 2, 2), // Red 900 (darkest)
      ],
      'Blue': [
        const Color(0xFFE3F2FD), // Blue 50
        const Color(0xFF90CAF9), // Blue 300
        const Color(0xFF64B5F6), // Blue 400
        const Color(0xFF1976D2), // Blue 700
        const Color(0xFF1565C0), // Blue 800
        const Color.fromARGB(255, 0, 60, 151), // Blue 900 (darkest)
      ],
      'Green': [
        const Color(0xFFE8F5E8), // Green 50
        const Color(0xFFA5D6A7), // Green 300
        const Color(0xFF81C784), // Green 400
        const Color(0xFF388E3C), // Green 700
        const Color(0xFF2E7D32), // Green 800
        const Color.fromARGB(255, 2, 89, 8), // Green 900 (darkest)
      ],
      'Grey': [
        const Color(0xFFFAFAFA), // Grey 50
        const Color(0xFFE0E0E0), // Grey 300
        const Color(0xFFBDBDBD), // Grey 400
        const Color(0xFF616161), // Grey 700
        const Color(0xFF424242), // Grey 800
        const Color.fromARGB(255, 0, 0, 0), // Grey 900 (darkest)
      ],
      'Orange': [
        const Color(0xFFFFF3E0), // Orange 50
        const Color(0xFFFFB74D), // Orange 300
        const Color(0xFFFF9800), // Orange 500
        const Color(0xFFE65100), // Orange 900
        const Color(0xFFBF360C), // Deep Orange 800
        const Color.fromARGB(255, 80, 43, 36), // Brown 900 (darkest)
      ],
      'Teal': [
        const Color(0xFFE0F2F1), // Teal 50
        const Color(0xFF80CBC4), // Teal 300
        const Color(0xFF4DB6AC), // Teal 400
        const Color(0xFF00796B), // Teal 700
        const Color(0xFF00695C), // Teal 800
        const Color.fromARGB(255, 0, 77, 64), // Teal 900 (darkest)
      ],
    };

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Color'),
        content: SizedBox(
          width: 320,
          height: 380,
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
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: isSelected
                                        ? Colors.black
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: isSelected
                                    ? const Icon(Icons.check,
                                        color: Colors.white)
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
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Manage Invoice Statuses',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 16),

            // Add/Edit Form
            if (_isAdding || _editingId != null) ...[
              Text(
                _isAdding ? 'Add New Status' : 'Edit Status',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _labelController,
                decoration: const InputDecoration(
                  labelText: 'Status Label',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Color: '),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _showColorPicker,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _selectedColor,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _showColorPicker,
                    child: const Text('Choose Color'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
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
                    child: Text(_isAdding ? 'Add' : 'Save'),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 16),
            ],

            // Add Button
            if (!_isAdding && _editingId == null)
              ElevatedButton.icon(
                onPressed: _startAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add New Status'),
              ),
            const SizedBox(height: 16),

            // Status List
            Expanded(
              child: Consumer<InvoiceStatusProvider>(
                builder: (context, provider, child) {
                  if (provider.isLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (provider.statuses.isEmpty) {
                    return const Center(
                      child: Text('No invoice statuses yet'),
                    );
                  }

                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: provider.statuses.length,
                    itemBuilder: (context, index) {
                      final status = provider.statuses[index];
                      return Card(
                        child: ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: status.color,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          title: Text(status.label),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
