import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_project.dart';
import '../providers/happy_sun_project_provider.dart';

class HappySunAddProjectDialog extends StatefulWidget {
  const HappySunAddProjectDialog({super.key});

  @override
  State<HappySunAddProjectDialog> createState() =>
      _HappySunAddProjectDialogState();
}

class _HappySunAddProjectDialogState extends State<HappySunAddProjectDialog> {
  final _formKey = GlobalKey<FormState>();
  final _clientNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _timeController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  int _numberOfTeamMembers = 2;
  bool _isLoading = false;

  @override
  void dispose() {
    _clientNameController.dispose();
    _addressController.dispose();
    _timeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add New Project'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _clientNameController,
                  decoration: const InputDecoration(
                    labelText: 'Client Name *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter client name';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _addressController,
                  decoration: const InputDecoration(
                    labelText: 'Address *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.location_on),
                  ),
                  maxLines: 2,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: const Text('Scheduled Date'),
                  subtitle: Text(
                    '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}',
                  ),
                  onTap: _selectDate,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _timeController,
                  decoration: const InputDecoration(
                    labelText: 'Scheduled Time (optional)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.access_time),
                    hintText: 'e.g., 9:00 AM - 5:00 PM',
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Number of Team Members',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    IconButton(
                      onPressed: _numberOfTeamMembers > 1
                          ? () {
                              setState(() {
                                _numberOfTeamMembers--;
                              });
                            }
                          : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '$_numberOfTeamMembers',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _numberOfTeamMembers++;
                        });
                      },
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _createProject,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _createProject() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final project = HappySunProject(
      id: '', // Will be set by Firestore
      clientName: _clientNameController.text,
      address: _addressController.text,
      scheduledDate: _selectedDate,
      scheduledTime: _timeController.text.isEmpty ? null : _timeController.text,
      numberOfTeamMembers: _numberOfTeamMembers,
      status: 'pending',
      createdAt: DateTime.now(),
    );

    final projectProvider = context.read<HappySunProjectProvider>();
    final projectId = await projectProvider.createProject(project);

    if (mounted) {
      setState(() {
        _isLoading = false;
      });

      if (projectId != null) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Project created successfully'),
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
