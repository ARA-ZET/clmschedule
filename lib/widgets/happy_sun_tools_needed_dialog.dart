import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/inventory_tool.dart';
import '../models/happy_sun_shared.dart';
import '../models/happy_sun_project.dart';
import '../providers/inventory_provider.dart';
import '../providers/happy_sun_project_provider.dart';

class HappySunToolsNeededDialog extends StatefulWidget {
  final HappySunProject project;

  const HappySunToolsNeededDialog({
    super.key,
    required this.project,
  });

  @override
  State<HappySunToolsNeededDialog> createState() =>
      _HappySunToolsNeededDialogState();
}

class _HappySunToolsNeededDialogState extends State<HappySunToolsNeededDialog> {
  late Map<String, int>
      _selectedTools; // toolName (without #number) -> quantity
  Map<String, int> _calculatedAccessories =
      {}; // Automatically calculated accessories
  String _searchQuery = '';
  String? _selectedCategory;

  @override
  void initState() {
    super.initState();
    // Initialize with existing tools needed
    _selectedTools = {};
    if (widget.project.toolsNeeded != null) {
      // toolsNeeded is CategorizedTools, need to iterate through all categories
      for (var tool in widget.project.toolsNeeded!.allTools) {
        final baseName = tool.baseName;
        // Only add non-accessory tools to selected tools
        _selectedTools[baseName] = tool.totalQuantity;
      }
    }
    // Calculate accessories after initialization
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recalculateAccessories();
    });
  }

  void _recalculateAccessories() {
    debugPrint('\n🔄 Recalculating accessories...');
    debugPrint('   Selected tools: $_selectedTools');

    final inventoryProvider = context.read<InventoryProvider>();
    final Map<String, int> accessories = {};

    // For each selected tool, find its required accessories
    for (final entry in _selectedTools.entries) {
      final baseName = entry.key;
      final quantity = entry.value;
      debugPrint('   Processing: $baseName × $quantity');

      // Find tool instances with this base name
      final matchingTools = inventoryProvider.tools
          .where((t) => _getBaseName(t.name) == baseName)
          .toList();
      debugPrint('      Found ${matchingTools.length} matching tools');

      if (matchingTools.isNotEmpty) {
        // Get the required accessories from the first tool (they all have the same)
        final tool = matchingTools.first;
        debugPrint('      Tool has ${tool.requiredAccessories.length} required accessories');

        // For each quantity of this tool, add its required accessories
        for (var i = 0; i < quantity; i++) {
          for (final accessoryReq in tool.requiredAccessories) {
            final accessoryBaseName = accessoryReq.baseName;
            final accessoryQty = accessoryReq.quantity;
            
            accessories[accessoryBaseName] =
                (accessories[accessoryBaseName] ?? 0) + accessoryQty;
            debugPrint(
                '         + Accessory: $accessoryBaseName × $accessoryQty');
          }
        }
      }
    }

    debugPrint('   ✅ Calculated accessories: $accessories\n');
    setState(() {
      _calculatedAccessories = accessories;
    });
  }

  // Remove #number from tool name
  String _getBaseName(String toolName) {
    final hashIndex = toolName.lastIndexOf('#');
    if (hashIndex > 0) {
      return toolName.substring(0, hashIndex).trim();
    }
    return toolName;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 800,
        height: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.build, color: Colors.orange),
                const SizedBox(width: 12),
                const Text(
                  'Tools Needed',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 16),

            // Search and Filter
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search tools...',
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
                        _searchQuery = value;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Consumer<InventoryProvider>(
                  builder: (context, inventoryProvider, child) {
                    return DropdownButton<String>(
                      value: _selectedCategory,
                      hint: const Text('Category'),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('All Categories'),
                        ),
                        ...inventoryProvider.categories
                            .where((cat) => cat != 'All')
                            .map((category) => DropdownMenuItem(
                                  value: category,
                                  child: Text(category),
                                )),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedCategory = value;
                        });
                      },
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Tools list and selection
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Available tools list
                  Expanded(
                    flex: 2,
                    child: _buildToolsList(),
                  ),
                  const SizedBox(width: 16),
                  // Right side: Selected tools and accessories
                  Expanded(
                    flex: 1,
                    child: Column(
                      children: [
                        // Selected tools summary
                        Expanded(
                          flex: 3,
                          child: _buildSelectedToolsSummary(),
                        ),
                        const SizedBox(height: 16),
                        // Accessories section
                        Expanded(
                          flex: 2,
                          child: _buildAccessoriesSection(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            // Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _saveToolsNeeded,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save Tools Needed'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolsList() {
    return Consumer<InventoryProvider>(
      builder: (context, inventoryProvider, child) {
        // Group tools by base name (excluding #number)
        final groupedTools = <String, List<InventoryTool>>{};

        var tools = inventoryProvider.tools;

        // Apply filters
        if (_selectedCategory != null) {
          tools = tools.where((t) => t.category == _selectedCategory).toList();
        }

        if (_searchQuery.isNotEmpty) {
          final query = _searchQuery.toLowerCase();
          tools = tools
              .where((t) =>
                  t.name.toLowerCase().contains(query) ||
                  t.toolId.toLowerCase().contains(query))
              .toList();
        }

        for (var tool in tools) {
          final baseName = _getBaseName(tool.name);
          groupedTools.putIfAbsent(baseName, () => []).add(tool);
        }

        if (groupedTools.isEmpty) {
          return Center(
            child: Text(
              _searchQuery.isNotEmpty
                  ? 'No tools found'
                  : 'No tools in inventory',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          );
        }

        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Available Tools (${groupedTools.length} types)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: groupedTools.length,
                  itemBuilder: (context, index) {
                    final baseName = groupedTools.keys.elementAt(index);
                    final tools = groupedTools[baseName]!;
                    final quantity = _selectedTools[baseName] ?? 0;

                    return ListTile(
                      leading: Icon(
                        Icons.build_circle,
                        color: quantity > 0 ? Colors.orange : Colors.grey,
                      ),
                      title: Text(baseName),
                      subtitle: Text(
                        '${tools.first.category} • ${tools.length} available',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: quantity > 0
                                ? () {
                                    setState(() {
                                      _selectedTools[baseName] = quantity - 1;
                                      if (_selectedTools[baseName]! <= 0) {
                                        _selectedTools.remove(baseName);
                                      }
                                    });
                                    _recalculateAccessories();
                                  }
                                : null,
                          ),
                          Container(
                            width: 40,
                            alignment: Alignment.center,
                            child: Text(
                              quantity.toString(),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: quantity < tools.length
                                ? () {
                                    setState(() {
                                      _selectedTools[baseName] = quantity + 1;
                                    });
                                    _recalculateAccessories();
                                  }
                                : null,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSelectedToolsSummary() {
    final totalMainTools =
        _selectedTools.values.fold(0, (sum, qty) => sum + qty);

    return Card(
      color: Colors.blue.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.shade100,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.build_circle, color: Colors.blue, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Main Tools',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),
                      Text(
                        'Total: $totalMainTools items',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blue.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _selectedTools.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.arrow_back, 
                          color: Colors.grey.shade400,
                          size: 48,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Select tools from the left',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(8),
                    children: _selectedTools.entries.map((entry) {
                      final toolName = entry.key;
                      final quantity = entry.value;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.check_circle,
                            color: Colors.blue,
                            size: 20,
                          ),
                          title: Text(
                            toolName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text('Quantity: $quantity'),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            color: Colors.red.shade300,
                            onPressed: () {
                              setState(() {
                                _selectedTools.remove(toolName);
                              });
                              _recalculateAccessories();
                            },
                          ),
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccessoriesSection() {
    final totalAccessories =
        _calculatedAccessories.values.fold(0, (sum, qty) => sum + qty);

    return Card(
      color: Colors.orange.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.extension, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Required Accessories',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                        ),
                      ),
                      Text(
                        'Auto-calculated: $totalAccessories items',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _calculatedAccessories.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.info_outline,
                          color: Colors.grey.shade400,
                          size: 48,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No accessories required',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Accessories will appear here\nwhen you select tools',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(8),
                    children: _calculatedAccessories.entries.map((entry) {
                      final accessoryName = entry.key;
                      final quantity = entry.value;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        elevation: 1,
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.extension,
                            color: Colors.orange.shade400,
                            size: 20,
                          ),
                          title: Text(
                            accessoryName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text('Quantity: $quantity'),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              'AUTO',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveToolsNeeded() async {
    debugPrint('\n💾 Saving tools needed...');
    debugPrint('   Job ID: ${widget.project.id}');
    debugPrint('   Job Date: ${widget.project.scheduledDate}');

    final inventoryProvider = context.read<InventoryProvider>();
    final happySunProvider = context.read<HappySunProjectProvider>();

    // Convert selected tools to GroupedToolItem
    final toolsList = <GroupedToolItem>[];

    // Create a map to track all tools including auto-added accessories
    final Map<String, int> allToolsWithQuantities = Map.from(_selectedTools);
    debugPrint('   Initial selected tools: $allToolsWithQuantities');

    // For each selected tool, check if it has required accessories and add them
    for (final entry in _selectedTools.entries) {
      final baseName = entry.key;
      final quantity = entry.value;
      debugPrint('   Processing for save: $baseName × $quantity');

      // Find tool instances with this base name
      final matchingTools = inventoryProvider.tools
          .where((t) => _getBaseName(t.name) == baseName)
          .toList();
      debugPrint('      Found ${matchingTools.length} matching tool instances');

      if (matchingTools.isNotEmpty) {
        // Get the required accessories from the first tool (they all have the same)
        final tool = matchingTools.first;
        debugPrint('      Tool has ${tool.requiredAccessories.length} required accessories');

        // For each quantity of this tool, add its required accessories
        for (var i = 0; i < quantity; i++) {
          for (final accessoryReq in tool.requiredAccessories) {
            final accessoryBaseName = accessoryReq.baseName;
            final accessoryQty = accessoryReq.quantity;
            
            allToolsWithQuantities[accessoryBaseName] =
                (allToolsWithQuantities[accessoryBaseName] ?? 0) + accessoryQty;
            debugPrint('         + Added accessory: $accessoryBaseName × $accessoryQty');
          }
        }
      }
    }

    debugPrint('   Final tools with accessories: $allToolsWithQuantities');

    // Now create HappySunToolUsage for all tools including auto-added accessories
    debugPrint('   Creating HappySunToolUsage objects...');
    for (var entry in allToolsWithQuantities.entries) {
      final baseName = entry.key;
      final quantity = entry.value;

      // Find a tool with this base name to get category
      final matchingTool = inventoryProvider.tools.firstWhere(
        (t) => _getBaseName(t.name) == baseName,
        orElse: () => InventoryTool(
          id: '',
          name: baseName,
          description: '',
          category: 'General',
          toolId: '',
          qrCode: '',
          createdAt: DateTime.now(),
        ),
      );

      toolsList.add(GroupedToolItem(
        baseName: baseName,
        category: matchingTool.category,
        totalQuantity: quantity,
        toolIds: [], // Will be filled during checkout
      ));
      debugPrint(
          '      Created: $baseName × $quantity (${matchingTool.category})');
    }

    debugPrint('   Total tool types to save: ${toolsList.length}');

    // Create CategorizedTools (for now, put everything in teamTools)
    final categorizedTools = CategorizedTools(
      teamTools: toolsList,
      individualTools: [],
      extras: [],
    );

    // Update the job with tools needed
    try {
      debugPrint('   Calling updateToolsNeeded...');
      await happySunProvider.updateToolsNeeded(
        widget.project.id,
        widget.project.scheduledDate,
        categorizedTools,
      );
      debugPrint('   ✅ Successfully saved tools needed\n');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved ${toolsList.length} tool types needed'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('   ❌ Error saving tools: $e\n');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving tools: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
