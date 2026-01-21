import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/inventory_tool.dart';
import '../models/happy_sun_job.dart';
import '../providers/inventory_provider.dart';
import '../providers/happy_sun_job_provider.dart';

class HappySunToolsNeededDialog extends StatefulWidget {
  final HappySunJob job;

  const HappySunToolsNeededDialog({
    super.key,
    required this.job,
  });

  @override
  State<HappySunToolsNeededDialog> createState() =>
      _HappySunToolsNeededDialogState();
}

class _HappySunToolsNeededDialogState extends State<HappySunToolsNeededDialog> {
  late Map<String, int>
      _selectedTools; // toolName (without #number) -> quantity
  String _searchQuery = '';
  String? _selectedCategory;

  @override
  void initState() {
    super.initState();
    // Initialize with existing tools needed
    _selectedTools = {};
    for (var tool in widget.job.toolsNeeded) {
      final baseName = _getBaseName(tool.toolName);
      _selectedTools[baseName] = tool.quantity;
    }
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
                  // Selected tools summary
                  Expanded(
                    flex: 1,
                    child: _buildSelectedToolsSummary(),
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
    final totalTools = _selectedTools.values.fold(0, (sum, qty) => sum + qty);

    return Card(
      color: Colors.orange.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Selected ($totalTools tools)',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _selectedTools.isEmpty
                ? Center(
                    child: Text(
                      'No tools selected',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  )
                : ListView.builder(
                    itemCount: _selectedTools.length,
                    itemBuilder: (context, index) {
                      final toolName = _selectedTools.keys.elementAt(index);
                      final quantity = _selectedTools[toolName]!;

                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.check_circle,
                          color: Colors.orange,
                          size: 20,
                        ),
                        title: Text(toolName),
                        subtitle: Text('Qty: $quantity'),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            setState(() {
                              _selectedTools.remove(toolName);
                            });
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveToolsNeeded() async {
    final inventoryProvider = context.read<InventoryProvider>();
    final happySunProvider = context.read<HappySunJobProvider>();

    // Convert selected tools to HappySunToolUsage
    final toolsNeeded = <HappySunToolUsage>[];

    for (var entry in _selectedTools.entries) {
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

      toolsNeeded.add(HappySunToolUsage(
        toolId: baseName, // Use base name as ID for grouping
        toolName: baseName,
        category: matchingTool.category,
        quantity: quantity,
      ));
    }

    // Update the job with tools needed
    try {
      await happySunProvider.updateToolsNeeded(
        widget.job.id,
        widget.job.date,
        toolsNeeded,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved ${toolsNeeded.length} tool types needed'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
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
