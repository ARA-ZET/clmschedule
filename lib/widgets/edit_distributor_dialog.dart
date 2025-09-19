import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/distributor.dart';

class EditDistributorDialog extends StatefulWidget {
  final Distributor distributor;
  final int totalDistributors;

  const EditDistributorDialog({
    super.key,
    required this.distributor,
    required this.totalDistributors,
  });

  @override
  State<EditDistributorDialog> createState() => _EditDistributorDialogState();
}

class _EditDistributorDialogState extends State<EditDistributorDialog> {
  late TextEditingController _nameController;
  late TextEditingController _indexController;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.distributor.name);
    _indexController =
        TextEditingController(text: widget.distributor.index.toString());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _indexController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Distributor'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Distributor Name',
                hintText: 'Enter distributor name',
                prefixIcon: Icon(Icons.person),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter a distributor name';
                }
                if (value.trim().length < 2) {
                  return 'Name must be at least 2 characters long';
                }
                return null;
              },
              autofocus: true,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _indexController,
              decoration: InputDecoration(
                labelText: 'Position Index',
                hintText:
                    'Enter position (0 to ${widget.totalDistributors - 1})',
                prefixIcon: const Icon(Icons.format_list_numbered),
                helperText: 'Position in the list (0 is first)',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a position index';
                }
                final index = int.tryParse(value);
                if (index == null) {
                  return 'Please enter a valid number';
                }
                if (index < 0 || index >= widget.totalDistributors) {
                  return 'Index must be between 0 and ${widget.totalDistributors - 1}';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: Colors.blue.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Changing the position will automatically adjust other distributors\' positions to avoid conflicts.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blue.shade700,
                        ),
                      ),
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
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              final updatedDistributor = widget.distributor.copyWith(
                name: _nameController.text.trim(),
                index: int.parse(_indexController.text),
              );
              Navigator.of(context).pop({
                'distributor': updatedDistributor,
                'oldIndex': widget.distributor.index,
              });
            }
          },
          child: const Text('Save Changes'),
        ),
      ],
    );
  }
}
