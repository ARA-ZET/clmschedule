import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/inventory_tool.dart';
import '../providers/inventory_provider.dart';

class AddToolDialog extends riverpod.ConsumerStatefulWidget {
  final InventoryTool? tool; // If provided, edit mode

  const AddToolDialog({super.key, this.tool});

  @override
  riverpod.ConsumerState<AddToolDialog> createState() => _AddToolDialogState();
}

class _AddToolDialogState extends riverpod.ConsumerState<AddToolDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _quantityController;
  String _selectedCategory = ToolCategory.squeegees;
  String? _imageUrl;
  XFile? _selectedImageFile;
  bool _isLoading = false;
  ToolType _toolType = ToolType.extras;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.tool?.name ?? '');
    _descriptionController =
        TextEditingController(text: widget.tool?.description ?? '');
    _quantityController =
        TextEditingController(text: '1'); // Always default to 1 for edit mode
    _selectedCategory = widget.tool?.category ?? ToolCategory.squeegees;
    _imageUrl = widget.tool?.imageUrl;
    _toolType = widget.tool?.toolType ?? ToolType.extras;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();

      // Show options to choose camera or gallery
      final ImageSource? source = await showDialog<ImageSource>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose Image Source'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Colors.blue),
                title: const Text('Camera'),
                subtitle: const Text('Take a photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.green),
                title: const Text('Gallery'),
                subtitle: const Text('Choose from library'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );

      if (source == null) return;

      // Explicitly use the selected source
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
        preferredCameraDevice: CameraDevice.rear,
      );

      if (image != null && mounted) {
        setState(() {
          _selectedImageFile = image;
          // Show preview using local file path
          _imageUrl = image.path;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking image: $e')),
        );
      }
    }
  }

  Future<void> _saveTool() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final quantity = int.parse(_quantityController.text);
      final inventoryProvider = ref.read(inventoryRiverpod);

      if (widget.tool == null) {
        // Add new tools (creates multiple entries if quantity > 1)
        // If image selected, pass the file so it can be uploaded with proper tool ID
        // Otherwise use existing URL if any
        if (_selectedImageFile != null) {
          await inventoryProvider.addToolsWithImageFile(
            _nameController.text.trim(),
            _descriptionController.text.trim(),
            _selectedImageFile!,
            _selectedCategory,
            quantity,
            toolType: _toolType,
          );
        } else {
          await inventoryProvider.addToolsWithImage(
            _nameController.text.trim(),
            _descriptionController.text.trim(),
            _imageUrl,
            _selectedCategory,
            quantity,
            toolType: _toolType,
          );
        }

        if (mounted) {
          // Pop dialog first
          Navigator.of(context).pop();
          // Show snackbar after a brief delay to avoid widget tree issues
          Future.delayed(const Duration(milliseconds: 100), () {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(quantity == 1
                      ? 'Tool added successfully'
                      : '$quantity tools added successfully'),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          });
        }
      } else {
        // Update existing tool
        String? uploadedImageUrl;

        // Upload new image if selected
        if (_selectedImageFile != null) {
          uploadedImageUrl = await inventoryProvider.uploadImage(
            _nameController.text.trim(),
            _selectedImageFile!,
          );

          if (uploadedImageUrl == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Failed to upload image')),
              );
              setState(() => _isLoading = false);
            }
            return;
          }

          // Check if we need to delete old image
          // Note: If uploading to same path, Firebase overwrites so no deletion needed
          if (widget.tool!.imageUrl != null &&
              widget.tool!.imageUrl != uploadedImageUrl) {
            // Extract paths to compare (ignore tokens)
            final oldPath = Uri.parse(widget.tool!.imageUrl!)
                .pathSegments
                .last
                .split('?')
                .first;
            final newPath =
                Uri.parse(uploadedImageUrl).pathSegments.last.split('?').first;

            if (oldPath != newPath) {
              // Different files, safe to delete old one
              await inventoryProvider.deleteImage(widget.tool!.imageUrl!);
            }
          }

          // Update image URL for all tools with the same base name
          await inventoryProvider.updateImageForAllToolsWithSameName(
            _nameController.text.trim(),
            uploadedImageUrl,
          );
        }

        final updatedTool = widget.tool!.copyWith(
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim(),
          imageUrl: uploadedImageUrl ?? _imageUrl,
          category: _selectedCategory,
          toolType: _toolType,
        );

        await inventoryProvider.updateTool(updatedTool);

        if (mounted) {
          Navigator.of(context).pop();
          Future.delayed(const Duration(milliseconds: 100), () {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(uploadedImageUrl != null
                      ? 'Tool and image updated successfully'
                      : 'Tool updated successfully'),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving tool: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Dialog(
      insetPadding: isMobile
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        width: isMobile ? double.infinity : 500,
        height: isMobile ? double.infinity : null,
        constraints: isMobile ? null : const BoxConstraints(maxHeight: 700),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(isMobile ? 12 : 16),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                borderRadius: isMobile
                    ? null
                    : const BorderRadius.vertical(top: Radius.circular(4)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.tool == null ? 'Add New Tool' : 'Edit Tool',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: isMobile ? 16 : 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close,
                        color: Colors.white, size: isMobile ? 20 : 24),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            // Form
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(isMobile ? 16 : 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Image picker
                      Center(
                        child: GestureDetector(
                          onTap: _pickImage,
                          child: Container(
                            width: isMobile ? 120 : 150,
                            height: isMobile ? 120 : 150,
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey),
                            ),
                            child: _imageUrl != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: _selectedImageFile != null
                                        ? (kIsWeb
                                            ? Image.network(
                                                _imageUrl!,
                                                fit: BoxFit.cover,
                                              )
                                            : Image.file(
                                                File(_imageUrl!),
                                                fit: BoxFit.cover,
                                              ))
                                        : Image.network(
                                            _imageUrl!,
                                            fit: BoxFit.cover,
                                            errorBuilder:
                                                (context, error, stackTrace) {
                                              return const Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                      Icons.add_photo_alternate,
                                                      size: 40),
                                                  SizedBox(height: 8),
                                                  Text('Add Photo'),
                                                ],
                                              );
                                            },
                                          ),
                                  )
                                : const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_photo_alternate, size: 40),
                                      SizedBox(height: 8),
                                      Text('Add Photo'),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Name
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Tool Name *',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a tool name';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      // Category
                      DropdownButtonFormField<String>(
                        initialValue: _selectedCategory,
                        decoration: const InputDecoration(
                          labelText: 'Category *',
                          border: OutlineInputBorder(),
                        ),
                        items: ToolCategory.all.map((category) {
                          return DropdownMenuItem(
                            value: category,
                            child: Text(category),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedCategory = value!;
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      // Quantity
                      TextFormField(
                        controller: _quantityController,
                        decoration: const InputDecoration(
                          labelText: 'Quantity *',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter quantity';
                          }
                          final quantity = int.tryParse(value);
                          if (quantity == null || quantity <= 0) {
                            return 'Please enter a valid quantity';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      // Description
                      TextFormField(
                        controller: _descriptionController,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 24),
                      // Tool designation section
                      const Text(
                        'Tool Type',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<ToolType>(
                        initialValue: _toolType,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items: ToolType.values.map((type) {
                          String description;
                          switch (type) {
                            case ToolType.team:
                              description = 'Used by the entire team';
                              break;
                            case ToolType.individual:
                              description = 'Each cleaner needs one';
                              break;
                            case ToolType.extras:
                              description = 'Extra or optional equipment';
                              break;
                            case ToolType.accessories:
                              description =
                                  'Required accessories for other tools';
                              break;
                          }
                          return DropdownMenuItem(
                            value: type,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(type.displayName),
                                Text(
                                  description,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _toolType = value;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Actions
            Container(
              padding: EdgeInsets.all(isMobile ? 10 : 16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: isMobile
                    ? null
                    : const BorderRadius.vertical(bottom: Radius.circular(4)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _isLoading ? null : () => Navigator.of(context).pop(),
                    child: Text('Cancel',
                        style: TextStyle(fontSize: isMobile ? 13 : 14)),
                  ),
                  SizedBox(width: isMobile ? 6 : 8),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _saveTool,
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: isMobile ? 16 : 20,
                        vertical: isMobile ? 10 : 12,
                      ),
                    ),
                    child: _isLoading
                        ? SizedBox(
                            width: isMobile ? 16 : 20,
                            height: isMobile ? 16 : 20,
                            child:
                                const CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            widget.tool == null ? 'Add Tool' : 'Save Changes',
                            style: TextStyle(fontSize: isMobile ? 13 : 14),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
