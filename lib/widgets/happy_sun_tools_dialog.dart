import 'package:flutter/material.dart';
import '../models/happy_sun_shared.dart';
import '../models/inventory_tool.dart';

/// Reusable tools dialog for Happy Sun jobs
/// Shows categorized tools with quick add/remove buttons
class HappySunToolsDialog extends StatefulWidget {
  final CategorizedTools currentTools;
  final List<InventoryTool> availableTools;

  const HappySunToolsDialog({
    super.key,
    required this.currentTools,
    required this.availableTools,
  });

  @override
  State<HappySunToolsDialog> createState() => _HappySunToolsDialogState();
}

class _HappySunToolsDialogState extends State<HappySunToolsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Working copies of tools
  late Map<String, _ToolEntry> _teamTools;
  late Map<String, _ToolEntry> _individualTools;
  late Map<String, _ToolEntry> _extrasTools;
  late Map<String, _ToolEntry> _accessoriesTools;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _initializeTools();
  }

  void _initializeTools() {
    // Group available tools by base name and category
    final toolsByBaseName = <String, List<InventoryTool>>{};
    for (final tool in widget.availableTools) {
      final baseName = _extractBaseName(tool.name);
      toolsByBaseName.putIfAbsent(baseName, () => []).add(tool);
    }

    // Initialize team tools
    _teamTools = {};
    for (final entry in toolsByBaseName.entries) {
      final baseName = entry.key;
      final tools = entry.value;
      if (tools.isNotEmpty && tools.first.toolType == ToolType.team) {
        final category = tools.first.category;
        final currentQty = widget.currentTools.teamTools
            .where((t) => t.baseName == baseName)
            .fold(0, (sum, t) => sum + t.totalQuantity);
        _teamTools[baseName] = _ToolEntry(
          baseName: baseName,
          category: category,
          quantity: currentQty,
          availableCount: tools.length,
        );
      }
    }

    // Initialize individual tools
    _individualTools = {};
    for (final entry in toolsByBaseName.entries) {
      final baseName = entry.key;
      final tools = entry.value;
      if (tools.isNotEmpty && tools.first.toolType == ToolType.individual) {
        final category = tools.first.category;
        final currentQty = widget.currentTools.individualTools
            .where((t) => t.baseName == baseName)
            .fold(0, (sum, t) => sum + t.totalQuantity);
        _individualTools[baseName] = _ToolEntry(
          baseName: baseName,
          category: category,
          quantity: currentQty,
          availableCount: tools.length,
        );
      }
    }

    // Initialize extras
    _extrasTools = {};
    for (final entry in toolsByBaseName.entries) {
      final baseName = entry.key;
      final tools = entry.value;
      if (tools.isNotEmpty && tools.first.toolType == ToolType.extras) {
        final category = tools.first.category;
        final currentQty = widget.currentTools.extras
            .where((t) => t.baseName == baseName)
            .fold(0, (sum, t) => sum + t.totalQuantity);
        _extrasTools[baseName] = _ToolEntry(
          baseName: baseName,
          category: category,
          quantity: currentQty,
          availableCount: tools.length,
        );
      }
    }

    // Initialize accessories
    _accessoriesTools = {};
    for (final entry in toolsByBaseName.entries) {
      final baseName = entry.key;
      final tools = entry.value;
      if (tools.isNotEmpty && tools.first.toolType == ToolType.accessories) {
        final category = tools.first.category;
        final currentQty = widget.currentTools.accessories
            .where((t) => t.baseName == baseName)
            .fold(0, (sum, t) => sum + t.totalQuantity);
        _accessoriesTools[baseName] = _ToolEntry(
          baseName: baseName,
          category: category,
          quantity: currentQty,
          availableCount: tools.length,
        );
      }
    }
  }

  String _extractBaseName(String toolName) {
    // Extract "Ladder" from "Ladder #1"
    final parts = toolName.split(' #');
    return parts.first;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _incrementTool(String baseName, Map<String, _ToolEntry> toolsMap) {
    setState(() {
      final entry = toolsMap[baseName]!;
      if (entry.quantity < entry.availableCount) {
        entry.quantity++;
      }
    });
  }

  void _decrementTool(String baseName, Map<String, _ToolEntry> toolsMap) {
    setState(() {
      final entry = toolsMap[baseName]!;
      if (entry.quantity > 0) {
        entry.quantity--;
      }
    });
  }

  CategorizedTools _buildCategorizedTools() {
    // Helper to get base name
    String getBaseName(String toolName) {
      final hashIndex = toolName.lastIndexOf('#');
      if (hashIndex > 0) {
        return toolName.substring(0, hashIndex).trim();
      }
      return toolName;
    }

    // Track all tools including accessories
    final Map<String, Map<String, dynamic>> allToolsMap = {};

    // Track manually selected accessories first
    final Map<String, int> manualAccessories = {};
    for (final entry
        in _accessoriesTools.entries.where((e) => e.value.quantity > 0)) {
      manualAccessories[entry.key] = entry.value.quantity;
    }

    // Process team tools and their accessories
    for (final entry in _teamTools.entries.where((e) => e.value.quantity > 0)) {
      final baseName = entry.key;
      final toolEntry = entry.value;

      allToolsMap[baseName] = {
        'category': toolEntry.category,
        'quantity': toolEntry.quantity,
        'type': 'team',
      };

      // Find accessories for this tool using requiredAccessories
      final matchingTools = widget.availableTools
          .where((t) => getBaseName(t.name) == baseName)
          .toList();

      if (matchingTools.isNotEmpty) {
        final tool = matchingTools.first;

        // Process requiredAccessories (base name + quantity per tool)
        for (final accessoryReq in tool.requiredAccessories) {
          final accessoryBaseName = accessoryReq.baseName;
          final qtyPerTool = accessoryReq.quantity;
          final totalQty = qtyPerTool * toolEntry.quantity;

          final currentQty = allToolsMap[accessoryBaseName]?['quantity'] ?? 0;
          final maxQty = manualAccessories[accessoryBaseName] ?? 0;

          if (totalQty > maxQty) {
            // Find category for this accessory
            final accessoryTools = widget.availableTools
                .where((t) => getBaseName(t.name) == accessoryBaseName)
                .toList();

            if (accessoryTools.isNotEmpty) {
              if (!allToolsMap.containsKey(accessoryBaseName)) {
                allToolsMap[accessoryBaseName] = {
                  'category': accessoryTools.first.category,
                  'quantity': totalQty,
                  'type': 'accessories',
                };
              } else {
                allToolsMap[accessoryBaseName]!['quantity'] =
                    totalQty > currentQty ? totalQty : currentQty;
              }
            }
          }
        }
      }
    }

    // Process individual tools and their accessories
    for (final entry
        in _individualTools.entries.where((e) => e.value.quantity > 0)) {
      final baseName = entry.key;
      final toolEntry = entry.value;

      if (!allToolsMap.containsKey(baseName)) {
        allToolsMap[baseName] = {
          'category': toolEntry.category,
          'quantity': toolEntry.quantity,
          'type': 'individual',
        };
      } else {
        allToolsMap[baseName]!['quantity'] += toolEntry.quantity;
      }

      // Find accessories for this tool
      final matchingTools = widget.availableTools
          .where((t) => getBaseName(t.name) == baseName)
          .toList();

      if (matchingTools.isNotEmpty) {
        final tool = matchingTools.first;

        for (final accessoryReq in tool.requiredAccessories) {
          final accessoryBaseName = accessoryReq.baseName;
          final qtyPerTool = accessoryReq.quantity;
          final totalQty = qtyPerTool * toolEntry.quantity;

          final currentQty = allToolsMap[accessoryBaseName]?['quantity'] ?? 0;
          final maxQty = manualAccessories[accessoryBaseName] ?? 0;

          if (totalQty > maxQty) {
            final accessoryTools = widget.availableTools
                .where((t) => getBaseName(t.name) == accessoryBaseName)
                .toList();

            if (accessoryTools.isNotEmpty) {
              if (!allToolsMap.containsKey(accessoryBaseName)) {
                allToolsMap[accessoryBaseName] = {
                  'category': accessoryTools.first.category,
                  'quantity': totalQty,
                  'type': 'accessories',
                };
              } else {
                allToolsMap[accessoryBaseName]!['quantity'] =
                    totalQty > currentQty ? totalQty : currentQty;
              }
            }
          }
        }
      }
    }

    // Process extras (no accessories typically)
    for (final entry
        in _extrasTools.entries.where((e) => e.value.quantity > 0)) {
      final baseName = entry.key;
      final toolEntry = entry.value;

      allToolsMap[baseName] = {
        'category': toolEntry.category,
        'quantity': toolEntry.quantity,
        'type': 'extras',
      };
    }

    // Process manually selected accessories
    // Only add if they exceed auto-calculated requirements
    for (final entry in manualAccessories.entries) {
      final baseName = entry.key;
      final manualQty = entry.value;
      final autoQty = allToolsMap[baseName]?['quantity'] ?? 0;

      if (manualQty > autoQty) {
        final accessoryEntry = _accessoriesTools[baseName]!;
        allToolsMap[baseName] = {
          'category': accessoryEntry.category,
          'quantity': manualQty,
          'type': 'accessories',
        };
      }
    }

    // Convert to GroupedToolItems by type
    final teamTools = allToolsMap.entries
        .where((e) => e.value['type'] == 'team')
        .map((e) => GroupedToolItem(
              baseName: e.key,
              category: e.value['category'],
              totalQuantity: e.value['quantity'],
              toolIds: [],
            ))
        .toList();

    final individualTools = allToolsMap.entries
        .where((e) => e.value['type'] == 'individual')
        .map((e) => GroupedToolItem(
              baseName: e.key,
              category: e.value['category'],
              totalQuantity: e.value['quantity'],
              toolIds: [],
            ))
        .toList();

    final extras = allToolsMap.entries
        .where((e) => e.value['type'] == 'extras')
        .map((e) => GroupedToolItem(
              baseName: e.key,
              category: e.value['category'],
              totalQuantity: e.value['quantity'],
              toolIds: [],
            ))
        .toList();

    final accessories = allToolsMap.entries
        .where((e) => e.value['type'] == 'accessories')
        .map((e) => GroupedToolItem(
              baseName: e.key,
              category: e.value['category'],
              totalQuantity: e.value['quantity'],
              toolIds: [],
            ))
        .toList();

    return CategorizedTools(
      teamTools: teamTools,
      individualTools: individualTools,
      extras: extras,
      accessories: accessories,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Dialog(
      child: Container(
        width: isMobile ? MediaQuery.of(context).size.width * 0.95 : 800,
        height: isMobile ? MediaQuery.of(context).size.height * 0.9 : 700,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Select Tools Needed',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Tabs
            TabBar(
              controller: _tabController,
              labelColor: Colors.orange,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.orange,
              tabs: const [
                Tab(text: 'Team'),
                Tab(text: 'Individual'),
                Tab(text: 'Extras'),
                Tab(text: 'Accessories'),
              ],
            ),
            const SizedBox(height: 16),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildToolsList(_teamTools),
                  _buildToolsList(_individualTools),
                  _buildToolsList(_extrasTools),
                  _buildToolsList(_accessoriesTools),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    final result = _buildCategorizedTools();
                    Navigator.of(context).pop(result);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                  child: const Text('Save Tools'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolsList(Map<String, _ToolEntry> toolsMap) {
    final sortedEntries = toolsMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    if (sortedEntries.isEmpty) {
      return const Center(
        child: Text('No tools available in this category'),
      );
    }

    return ListView.builder(
      itemCount: sortedEntries.length,
      itemBuilder: (context, index) {
        final entry = sortedEntries[index];
        final baseName = entry.key;
        final tool = entry.value;

        final isSelected = tool.quantity > 0;

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          color: isSelected ? null : Colors.grey[200],
          child: ListTile(
            title: Text(
              baseName,
              style: TextStyle(
                color: isSelected ? null : Colors.grey[500],
                fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              '${tool.category} • Available: ${tool.availableCount}',
              style: TextStyle(
                color: isSelected ? Colors.grey[600] : Colors.grey[400],
                fontSize: 12,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: tool.quantity > 0
                      ? () => _decrementTool(baseName, toolsMap)
                      : null,
                  color: isSelected ? Colors.orange : Colors.grey[400],
                ),
                Container(
                  width: 40,
                  alignment: Alignment.center,
                  child: Text(
                    '${tool.quantity}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? null : Colors.grey[500],
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: tool.quantity < tool.availableCount
                      ? () => _incrementTool(baseName, toolsMap)
                      : null,
                  color: Colors.green,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Helper class to track tool quantities in the dialog
class _ToolEntry {
  final String baseName;
  final String category;
  int quantity;
  final int availableCount;

  _ToolEntry({
    required this.baseName,
    required this.category,
    required this.quantity,
    required this.availableCount,
  });
}
