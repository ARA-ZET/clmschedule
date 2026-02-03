import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/inventory_tool.dart';
import '../providers/inventory_provider.dart';

class EditBaseNameToolsDialog extends StatefulWidget {
  final String baseName;
  final List<InventoryTool> tools;

  const EditBaseNameToolsDialog({
    super.key,
    required this.baseName,
    required this.tools,
  });

  @override
  State<EditBaseNameToolsDialog> createState() =>
      _EditBaseNameToolsDialogState();
}

class _EditBaseNameToolsDialogState extends State<EditBaseNameToolsDialog> {
  late TextEditingController _baseNameController;
  late String _selectedCategory;
  late ToolType _selectedToolType;
  late int _quantity;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _baseNameController = TextEditingController(text: widget.baseName);
    _selectedCategory = widget.tools.first.category;
    _selectedToolType = widget.tools.first.toolType;
    _quantity = widget.tools.length;
  }

  @override
  void dispose() {
    _baseNameController.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    if (_baseNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Base name cannot be empty'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final inventoryProvider = context.read<InventoryProvider>();
      final newBaseName = _baseNameController.text.trim();
      final currentQuantity = widget.tools.length;
      final quantityDiff = _quantity - currentQuantity;

      // Handle basename change - update all existing tools
      if (newBaseName != widget.baseName) {
        for (int i = 0; i < widget.tools.length; i++) {
          final tool = widget.tools[i];
          final newName = '$newBaseName #${i + 1}';
          await inventoryProvider.updateTool(
            tool.copyWith(
              name: newName,
              category: _selectedCategory,
              toolType: _selectedToolType,
            ),
          );
        }
      }
      // Handle category or tool type change - update all existing tools
      else if (_selectedCategory != widget.tools.first.category ||
          _selectedToolType != widget.tools.first.toolType) {
        for (final tool in widget.tools) {
          await inventoryProvider.updateTool(
            tool.copyWith(
              category: _selectedCategory,
              toolType: _selectedToolType,
            ),
          );
        }
      }

      // Handle quantity increase - add new tools
      if (quantityDiff > 0) {
        for (int i = 0; i < quantityDiff; i++) {
          final newNumber = currentQuantity + i + 1;
          final newToolName = '$newBaseName #$newNumber';

          // Add single tool using addTools with quantity 1
          await inventoryProvider.addToolsWithImage(
            newToolName,
            widget.tools.first.description,
            widget.tools.first.imageUrl,
            _selectedCategory,
            1, // quantity
            toolType: _selectedToolType,
          );
        }
      }
      // Handle quantity decrease - delete tools
      else if (quantityDiff < 0) {
        final toolsToDelete = widget.tools.sublist(0, -quantityDiff);
        for (final tool in toolsToDelete) {
          await inventoryProvider.deleteTool(tool.id);
        }

        // Renumber remaining tools
        final remainingTools = widget.tools.sublist(-quantityDiff);
        for (int i = 0; i < remainingTools.length; i++) {
          final tool = remainingTools[i];
          final newName = '$newBaseName #${i + 1}';
          if (tool.name != newName) {
            await inventoryProvider.updateTool(
              tool.copyWith(name: newName),
            );
          }
        }
      }

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              quantityDiff > 0
                  ? 'Added $quantityDiff tools successfully'
                  : quantityDiff < 0
                      ? 'Removed ${-quantityDiff} tools successfully'
                      : 'Tools updated successfully',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating tools: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.blue.shade700, Colors.blue.shade500],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.edit, color: Colors.white, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Edit Tool Group',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Editing ${widget.tools.length} tools',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Info banner
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.blue.shade50,
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: Colors.blue.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Changes will apply to all ${widget.tools.length} tools in this group',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Base Name
                    const Text(
                      'Base Name',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _baseNameController,
                      decoration: InputDecoration(
                        hintText: 'Enter tool base name',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'All tools will be renamed to: ${_baseNameController.text} #1, #2, #3...',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        fontStyle: FontStyle.italic,
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Category
                    const Text(
                      'Category',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: _selectedCategory,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      items: ToolCategory.all.map((category) {
                        return DropdownMenuItem(
                          value: category,
                          child: Text(category),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedCategory = value);
                        }
                      },
                    ),

                    const SizedBox(height: 24),

                    // Tool Type
                    const Text(
                      'Tool Type',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<ToolType>(
                      value: _selectedToolType,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      items: ToolType.values.map((type) {
                        return DropdownMenuItem(
                          value: type,
                          child: Text(type.displayName),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedToolType = value);
                        }
                      },
                    ),

                    const SizedBox(height: 24),

                    // Quantity
                    const Text(
                      'Quantity',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton.filled(
                          onPressed: _quantity > 1
                              ? () {
                                  setState(() => _quantity--);
                                }
                              : null,
                          icon: const Icon(Icons.remove),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.red.shade400,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: Text(
                            _quantity.toString(),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        IconButton.filled(
                          onPressed: () {
                            setState(() => _quantity++);
                          },
                          icon: const Icon(Icons.add),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.green.shade400,
                            foregroundColor: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_quantity > widget.tools.length)
                                Text(
                                  '+${_quantity - widget.tools.length} new tools will be added',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.green.shade700,
                                    fontWeight: FontWeight.w500,
                                  ),
                                )
                              else if (_quantity < widget.tools.length)
                                Text(
                                  '${widget.tools.length - _quantity} tools will be deleted',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.red.shade700,
                                    fontWeight: FontWeight.w500,
                                  ),
                                )
                              else
                                Text(
                                  'No quantity change',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    if (_quantity < widget.tools.length) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber,
                                color: Colors.red.shade700, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'The first ${widget.tools.length - _quantity} tools will be deleted',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.red.shade700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Footer
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                border: Border(
                  top: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _isSaving ? null : _saveChanges,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: Text(_isSaving ? 'Saving...' : 'Save Changes'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
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
