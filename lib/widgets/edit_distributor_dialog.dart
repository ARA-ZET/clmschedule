import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../models/distributor.dart';
import '../services/storage_upload.dart';

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
  late DistributorRole _selectedRole;
  final _formKey = GlobalKey<FormState>();

  // Image upload state
  Uint8List? _pendingImageBytes;
  String? _pendingImageFileName;
  String? _previewImageUrl; // current or newly picked
  bool _uploading = false;

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
    _selectedRole = widget.distributor.role;
    _previewImageUrl = widget.distributor.imageUrl;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _indexController.dispose();
    _phone1Controller.dispose();
    _phone2Controller.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _pendingImageBytes = bytes;
      _pendingImageFileName = picked.name;
      // Show a local memory preview while the image hasn't been uploaded yet
      _previewImageUrl = null;
    });
  }

  Future<String?> _uploadImage(String distributorId) async {
    if (_pendingImageBytes == null) return null;
    final ext = (_pendingImageFileName ?? 'photo.jpg')
        .split('.')
        .last
        .toLowerCase();
    final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
    final ref = FirebaseStorage.instance
        .ref()
        .child('distributor_photos/$distributorId.$ext');
    await StorageUpload.safePutData(
      ref,
      _pendingImageBytes!,
      metadata: SettableMetadata(contentType: contentType),
    );
    return await ref.getDownloadURL();
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

  Widget _buildPhotoSection() {
    ImageProvider? imageProvider;
    if (_pendingImageBytes != null) {
      imageProvider = MemoryImage(_pendingImageBytes!);
    } else if (_previewImageUrl != null && _previewImageUrl!.isNotEmpty) {
      imageProvider = NetworkImage(_previewImageUrl!);
    }

    return Column(
      children: [
        GestureDetector(
          onTap: _pickImage,
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              CircleAvatar(
                radius: 50,
                backgroundImage: imageProvider,
                backgroundColor: Colors.grey.shade200,
                child: imageProvider == null
                    ? const Icon(Icons.person, size: 48, color: Colors.grey)
                    : null,
              ),
              Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1565C0),
                ),
                padding: const EdgeInsets.all(6),
                child: const Icon(Icons.camera_alt,
                    size: 16, color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: _pickImage,
          icon: const Icon(Icons.photo_library, size: 16),
          label: Text(
            imageProvider == null ? 'Add photo' : 'Change photo',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
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
                // ── Profile photo ──────────────────────────────────────────
                _buildPhotoSection(),
                const SizedBox(height: 16),

                // ── Name ──────────────────────────────────────────────────
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

                // ── Position index ─────────────────────────────────────────
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
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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

                // ── Phone 1 ────────────────────────────────────────────────
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

                // ── Phone 2 ────────────────────────────────────────────────
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

                // ── Role ───────────────────────────────────────────────────
                DropdownButtonFormField<DistributorRole>(
                  initialValue: _selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Role (ID card)',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  items: DistributorRole.values.map((role) {
                    return DropdownMenuItem(
                      value: role,
                      child: Text(role.displayName),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() => _selectedRole = value!);
                  },
                ),
                const SizedBox(height: 16),

                // ── Status ─────────────────────────────────────────────────
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
                          Icon(_getStatusIcon(status),
                              size: 16, color: _getStatusColor(status)),
                          const SizedBox(width: 8),
                          Text(status.displayName),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() => _selectedStatus = value!);
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
          onPressed: _uploading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _uploading
              ? null
              : () async {
                  if (!_formKey.currentState!.validate()) return;

                  setState(() => _uploading = true);

                  String? finalImageUrl = widget.distributor.imageUrl;

                  // Upload new image if one was picked
                  if (_pendingImageBytes != null) {
                    try {
                      finalImageUrl =
                          await _uploadImage(widget.distributor.id);
                    } catch (e) {
                      setState(() => _uploading = false);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('Image upload failed: $e'),
                              backgroundColor: Colors.red),
                        );
                      }
                      return;
                    }
                  }

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
                    role: _selectedRole,
                    imageUrl: finalImageUrl,
                  );

                  if (mounted) {
                    Navigator.of(context).pop({
                      'distributor': updatedDistributor,
                      'oldIndex': widget.distributor.index,
                    });
                  }
                },
          child: _uploading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save Changes'),
        ),
      ],
    );
  }
}
