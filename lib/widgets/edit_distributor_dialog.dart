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
  late TextEditingController _phone1Controller;
  late TextEditingController _phone2Controller;
  late DistributorStatus _selectedStatus;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.distributor.name);
    _indexController =
        TextEditingController(text: widget.distributor.index.toString());
    _phone1Controller =
        TextEditingController(text: widget.distributor.phone1 ?? '');
    _phone2Controller =
        TextEditingController(text: widget.distributor.phone2 ?? '');
    _selectedStatus = widget.distributor.status;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _indexController.dispose();
    _phone1Controller.dispose();
    _phone2Controller.dispose();
    super.dispose();
  }

  IconData _getStatusIcon(DistributorStatus status) {
    switch (status) {
      case DistributorStatus.active:
        return Icons.check_circle;
      case DistributorStatus.inactive:
        return Icons.cancel;
      case DistributorStatus.suspended:
        return Icons.block;
      case DistributorStatus.onLeave:
        return Icons.flight_takeoff;
    }
  }

  Color _getStatusColor(DistributorStatus status) {
    switch (status) {
      case DistributorStatus.active:
        return Colors.green;
      case DistributorStatus.inactive:
        return Colors.grey;
      case DistributorStatus.suspended:
        return Colors.red;
      case DistributorStatus.onLeave:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Distributor'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
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
                TextFormField(
                  controller: _phone1Controller,
                  decoration: const InputDecoration(
                    labelText: 'Phone 1 (Primary)',
                    hintText: 'Enter primary phone number',
                    prefixIcon: Icon(Icons.phone),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _phone2Controller,
                  decoration: const InputDecoration(
                    labelText: 'Phone 2 (Secondary)',
                    hintText: 'Enter secondary phone number (optional)',
                    prefixIcon: Icon(Icons.phone_android),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<DistributorStatus>(
                  initialValue: _selectedStatus,
                  decoration: const InputDecoration(
                    labelText: 'Status',
                    prefixIcon: Icon(Icons.work_outline),
                  ),
                  items: DistributorStatus.values.map((status) {
                    return DropdownMenuItem(
                      value: status,
                      child: Row(
                        children: [
                          Icon(
                            _getStatusIcon(status),
                            size: 16,
                            color: _getStatusColor(status),
                          ),
                          const SizedBox(width: 8),
                          Text(status.displayName),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedStatus = value!;
                    });
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
                phone1: _phone1Controller.text.trim().isEmpty
                    ? null
                    : _phone1Controller.text.trim(),
                phone2: _phone2Controller.text.trim().isEmpty
                    ? null
                    : _phone2Controller.text.trim(),
                status: _selectedStatus,
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
