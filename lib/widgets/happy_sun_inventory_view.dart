import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/inventory_provider.dart';
import '../models/inventory_tool.dart';
import 'tool_details_dialog.dart';
import 'add_tool_dialog.dart';
import 'qr_scanner_dialog.dart';
import 'tool_settings_dialog.dart';

class HappySunInventoryView extends StatefulWidget {
  const HappySunInventoryView({super.key});

  @override
  State<HappySunInventoryView> createState() => _HappySunInventoryViewState();
}

class _HappySunInventoryViewState extends State<HappySunInventoryView> {
  bool _hasInitialized = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<InventoryProvider>(
      builder: (context, inventoryProvider, child) {
        // Initialize on first build
        if (!_hasInitialized) {
          _hasInitialized = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            inventoryProvider.initialize();
          });
        }

        if (inventoryProvider.isLoading && inventoryProvider.tools.isEmpty) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        if (inventoryProvider.error != null &&
            inventoryProvider.tools.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text('Error: ${inventoryProvider.error}'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => inventoryProvider.initialize(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            // Header with filters and actions
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Filters and Actions Row
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          decoration: const InputDecoration(
                            labelText: 'Search tools...',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                          ),
                          onChanged: (value) {
                            inventoryProvider.setSearchQuery(value);
                          },
                        ),
                      ),
                      // Category filter
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          value: inventoryProvider.selectedCategory ?? 'All',
                          decoration: const InputDecoration(
                            labelText: 'Category',
                            prefixIcon: Icon(Icons.category),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                          ),
                          items: inventoryProvider.categories.map((category) {
                            return DropdownMenuItem(
                              value: category,
                              child: Text(category),
                            );
                          }).toList(),
                          onChanged: (value) {
                            inventoryProvider.setCategory(value);
                          },
                        ),
                      ),

                      // Availability filter
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          value:
                              inventoryProvider.selectedAvailability ?? 'All',
                          decoration: const InputDecoration(
                            labelText: 'Status',
                            prefixIcon: Icon(Icons.check_circle_outline),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'All',
                              child: Text('All Status'),
                            ),
                            DropdownMenuItem(
                              value: 'available',
                              child: Text('Available'),
                            ),
                            DropdownMenuItem(
                              value: 'in-use',
                              child: Text('In Use'),
                            ),
                          ],
                          onChanged: (value) {
                            inventoryProvider.setAvailability(value);
                          },
                        ),
                      ),

                      // Clear filters button
                      if (inventoryProvider.selectedCategory != null &&
                              inventoryProvider.selectedCategory != 'All' ||
                          inventoryProvider.selectedAvailability != null &&
                              inventoryProvider.selectedAvailability != 'All' ||
                          inventoryProvider.searchQuery.isNotEmpty)
                        IconButton(
                          onPressed: () {
                            inventoryProvider.clearFilters();
                          },
                          icon: const Icon(Icons.clear_all),
                          tooltip: 'Clear Filters',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.grey[200],
                          ),
                        ),

                      // Scan QR Code button
                      ElevatedButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => const QrScannerDialog(),
                          );
                        },
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Add tool button
                      ElevatedButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => const AddToolDialog(),
                          );
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Add'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      // Tools setting screen
                      IconButton(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => const ToolSettingsDialog(),
                          );
                        },
                        icon: const Icon(Icons.settings),
                        tooltip: 'Tool Requirements Settings',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey[200],
                        ),
                      ),
                    ],
                  ),
                  // Results count
                  if (inventoryProvider.filteredTools.length !=
                      inventoryProvider.tools.length) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Showing ${inventoryProvider.filteredTools.length} of ${inventoryProvider.tools.length} tools',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Tools grid - grouped by base name
            Expanded(
              child: inventoryProvider.filteredTools.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.inventory,
                              size: 64, color: Colors.grey),
                          const SizedBox(height: 16),
                          Text(
                            'No tools found',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Add your first tool to get started',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : _buildGroupedToolsGrid(inventoryProvider),
            ),
          ],
        );
      },
    );
  }

  Widget _buildGroupedToolsGrid(InventoryProvider inventoryProvider) {
    // Group tools by base name
    final Map<String, List<InventoryTool>> groupedTools = {};
    for (final tool in inventoryProvider.filteredTools) {
      final baseName = tool.baseName;
      if (!groupedTools.containsKey(baseName)) {
        groupedTools[baseName] = [];
      }
      groupedTools[baseName]!.add(tool);
    }

    final groups = groupedTools.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.75,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final baseName = group.key;
        final tools = group.value;
        return GroupedToolCard(baseName: baseName, tools: tools);
      },
    );
  }
}

class GroupedToolCard extends StatelessWidget {
  final String baseName;
  final List<InventoryTool> tools;

  const GroupedToolCard({
    super.key,
    required this.baseName,
    required this.tools,
  });

  @override
  Widget build(BuildContext context) {
    final availableCount = tools.where((t) => t.isAvailable).length;
    final inUseCount = tools.length - availableCount;
    final totalCount = tools.length;

    // Use first tool for category, image, and type
    final firstTool = tools.first;

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ToolDetailListScreen(
                baseName: baseName,
                tools: tools,
              ),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Image
            Expanded(
              child: Container(
                margin: EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(4)),
                ),
                child: firstTool.imageUrl != null
                    ? Image.network(
                        firstTool.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return const Icon(Icons.construction,
                              size: 64, color: Colors.grey);
                        },
                      )
                    : const Icon(Icons.construction,
                        size: 64, color: Colors.grey),
              ),
            ),
            // Details
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                spacing: 4,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    baseName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    firstTool.category,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                    ),
                  ),
                  // Tool type and quantity in same row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: firstTool.toolType == ToolType.team
                              ? Colors.blue.shade100
                              : firstTool.toolType == ToolType.individual
                                  ? Colors.purple.shade100
                                  : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          firstTool.toolType.displayName.toUpperCase(),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: firstTool.toolType == ToolType.team
                                ? Colors.blue.shade700
                                : firstTool.toolType == ToolType.individual
                                    ? Colors.purple.shade700
                                    : Colors.grey.shade700,
                          ),
                        ),
                      ),
                      Text(
                        'Qty: $totalCount',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  // Available and in-use counts in same row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 14,
                            color: Colors.green,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Available',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '$availableCount',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                  // In use count
                  if (inUseCount > 0)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.schedule,
                              size: 14,
                              color: Colors.orange,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'In Use',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.orange,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '$inUseCount',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
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

// Detail screen showing all individual tools with same base name
class ToolDetailListScreen extends StatelessWidget {
  final String baseName;
  final List<InventoryTool> tools;

  const ToolDetailListScreen({
    super.key,
    required this.baseName,
    required this.tools,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(baseName),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          childAspectRatio: 0.75,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: tools.length,
        itemBuilder: (context, index) {
          final tool = tools[index];
          return ToolCard(tool: tool);
        },
      ),
    );
  }
}

class ToolCard extends StatelessWidget {
  final InventoryTool tool;

  const ToolCard({super.key, required this.tool});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: () {
          showDialog(
            context: context,
            builder: (context) => ToolDetailsDialog(tool: tool),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Image
            Expanded(
              child: Container(
                margin: EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(4)),
                ),
                child: tool.imageUrl != null
                    ? Image.network(
                        tool.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return const Icon(Icons.construction,
                              size: 64, color: Colors.grey);
                        },
                      )
                    : const Icon(Icons.construction,
                        size: 64, color: Colors.grey),
              ),
            ),
            // Details
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                spacing: 4,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    tool.toolId,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.blue[700],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    tool.category,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                    ),
                  ),
                  // Tool type badge
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: tool.toolType == ToolType.team
                          ? Colors.blue.shade100
                          : tool.toolType == ToolType.individual
                              ? Colors.purple.shade100
                              : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      tool.toolType.displayName.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: tool.toolType == ToolType.team
                            ? Colors.blue.shade700
                            : tool.toolType == ToolType.individual
                                ? Colors.purple.shade700
                                : Colors.grey.shade700,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        tool.isAvailable ? Icons.check_circle : Icons.schedule,
                        size: 16,
                        color: tool.isAvailable ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        tool.isAvailable ? 'Available' : 'In Use',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color:
                              tool.isAvailable ? Colors.green : Colors.orange,
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
