import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/inventory_tool.dart';
import '../providers/inventory_provider.dart';

class ManageAccessoriesDialog extends StatefulWidget {
  final InventoryTool tool;

  const ManageAccessoriesDialog({super.key, required this.tool});

  @override
  State<ManageAccessoriesDialog> createState() =>
      _ManageAccessoriesDialogState();
}

class _ManageAccessoriesDialogState extends State<ManageAccessoriesDialog> {
  // Map of base name to quantity needed
  final Map<String, int> _selectedAccessories = {};
  bool _isLoading = false;
  String? _searchQuery;

  @override
  void initState() {
    super.initState();
    // Load existing required accessories
    for (final accessory in widget.tool.requiredAccessories) {
      _selectedAccessories[accessory.baseName] = accessory.quantity;
    }
  }

  String _getBaseName(String name) {
    final lastHashIndex = name.lastIndexOf('#');
    if (lastHashIndex != -1) {
      return name.substring(0, lastHashIndex).trim();
    }
    return name;
  }

  Future<void> _saveAccessories() async {
    setState(() => _isLoading = true);

    try {
      final inventoryProvider = context.read<InventoryProvider>();

      // Convert base name quantities to AccessoryRequirement objects
      final List<AccessoryRequirement> requiredAccessories = [];
      for (final entry in _selectedAccessories.entries) {
        requiredAccessories.add(AccessoryRequirement(
          baseName: entry.key,
          quantity: entry.value,
        ));
      }

      await inventoryProvider.updateToolRequiredAccessories(
        widget.tool.id,
        requiredAccessories,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Accessories updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating accessories: $e'),
            backgroundColor: Colors.red,
          ),
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
    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 700),
        child: Column(
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
                  const Icon(
                    Icons.extension,
                    color: Colors.white,
                    size: 32,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Manage Accessories',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'for ${widget.tool.name}',
                          style: const TextStyle(
                            fontSize: 14,
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
                      'Select tools that must always be checked out together with ${widget.tool.name}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Search bar
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search for accessories...',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value.toLowerCase();
                  });
                },
              ),
            ),

            // Tools list
            Expanded(
              child: Consumer<InventoryProvider>(
                builder: (context, inventoryProvider, child) {
                  // Filter to show only accessories type tools
                  var availableTools = inventoryProvider.tools
                      .where((t) =>
                          t.id != widget.tool.id &&
                          t.toolType == ToolType.accessories)
                      .toList();

                  // Group by base name
                  final Map<String, List<InventoryTool>> groupedTools = {};
                  for (final tool in availableTools) {
                    final baseName = _getBaseName(tool.name);
                    groupedTools.putIfAbsent(baseName, () => []).add(tool);
                  }

                  // Apply search filter
                  var baseNames = groupedTools.keys.toList();
                  if (_searchQuery != null && _searchQuery!.isNotEmpty) {
                    baseNames = baseNames
                        .where((baseName) =>
                            baseName.toLowerCase().contains(_searchQuery!) ||
                            groupedTools[baseName]!.any((t) =>
                                t.toolId.toLowerCase().contains(_searchQuery!)))
                        .toList();
                  }

                  baseNames.sort();

                  if (baseNames.isEmpty) {
                    return const Center(
                      child: Text('No tools available as accessories'),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: baseNames.length,
                    itemBuilder: (context, index) {
                      final baseName = baseNames[index];
                      final tools = groupedTools[baseName]!;
                      final availableCount = tools.length;
                      final selectedQuantity =
                          _selectedAccessories[baseName] ?? 0;
                      final firstTool = tools.first;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              // Icon
                              CircleAvatar(
                                backgroundColor: selectedQuantity > 0
                                    ? Colors.blue.shade100
                                    : Colors.grey.shade200,
                                child: Icon(
                                  Icons.build,
                                  color: selectedQuantity > 0
                                      ? Colors.blue.shade700
                                      : Colors.grey.shade600,
                                ),
                              ),
                              const SizedBox(width: 12),

                              // Tool info
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      baseName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${firstTool.category} • Available: $availableCount',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Quantity selector
                              Row(
                                children: [
                                  IconButton(
                                    onPressed: selectedQuantity > 0
                                        ? () {
                                            setState(() {
                                              final newQuantity =
                                                  selectedQuantity - 1;
                                              if (newQuantity == 0) {
                                                _selectedAccessories
                                                    .remove(baseName);
                                              } else {
                                                _selectedAccessories[baseName] =
                                                    newQuantity;
                                              }
                                            });
                                          }
                                        : null,
                                    icon:
                                        const Icon(Icons.remove_circle_outline),
                                    color: Colors.blue.shade700,
                                  ),
                                  Container(
                                    width: 40,
                                    alignment: Alignment.center,
                                    child: Text(
                                      '$selectedQuantity',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: selectedQuantity > 0
                                            ? Colors.blue.shade700
                                            : Colors.grey.shade600,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: selectedQuantity < availableCount
                                        ? () {
                                            setState(() {
                                              _selectedAccessories[baseName] =
                                                  selectedQuantity + 1;
                                            });
                                          }
                                        : null,
                                    icon: const Icon(Icons.add_circle_outline),
                                    color: selectedQuantity < availableCount
                                        ? Colors.blue.shade700
                                        : Colors.grey.shade400,
                                  ),
                                ],
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_selectedAccessories.values.fold(0, (sum, qty) => sum + qty)} accessories selected',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed:
                            _isLoading ? null : () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isLoading ? null : _saveAccessories,
                        icon: _isLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.save),
                        label: const Text('Save'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
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
