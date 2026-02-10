import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/inventory_provider.dart';
import '../models/inventory_tool.dart';
import 'tool_details_dialog.dart';
import 'add_tool_dialog.dart';
import 'qr_scanner_dialog.dart';
import 'tool_settings_dialog.dart';
import 'edit_basename_tools_dialog.dart';
import 'qr_code_print_preview_dialog.dart';

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
              padding: EdgeInsets.all(
                  MediaQuery.of(context).size.width < 600 ? 10 : 16),
              color: Colors.white,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isMobile = constraints.maxWidth < 600;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Compact header row with filters, search, and actions
                      Row(
                        children: [
                          // Category filter icon button with dropdown
                          PopupMenuButton<String>(
                            initialValue:
                                inventoryProvider.selectedCategory ?? 'All',
                            icon: Icon(Icons.filter_list,
                                size: isMobile ? 20 : 24),
                            tooltip: 'Category Filter',
                            onSelected: (value) {
                              inventoryProvider.setCategory(value);
                            },
                            itemBuilder: (context) {
                              return inventoryProvider.categories
                                  .map((category) {
                                return PopupMenuItem(
                                  value: category,
                                  child: Row(
                                    children: [
                                      Icon(Icons.category,
                                          size: isMobile ? 16 : 20),
                                      SizedBox(width: 8),
                                      Text(category,
                                          style: TextStyle(
                                              fontSize: isMobile ? 12 : 14)),
                                    ],
                                  ),
                                );
                              }).toList();
                            },
                          ),
                          SizedBox(width: isMobile ? 4 : 8),
                          // Status filter dropdown
                          SizedBox(
                            width: isMobile ? 110 : 140,
                            child: DropdownButtonFormField<String>(
                              initialValue:
                                  inventoryProvider.selectedAvailability ??
                                      'All',
                              decoration: InputDecoration(
                                prefixIcon: Icon(Icons.check_circle_outline,
                                    size: isMobile ? 16 : 20),
                                border: const OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: isMobile ? 4 : 8,
                                  vertical: isMobile ? 4 : 8,
                                ),
                                isDense: true,
                              ),
                              style: TextStyle(
                                  fontSize: isMobile ? 11 : 13,
                                  color: Colors.black),
                              items: [
                                DropdownMenuItem(
                                  value: 'All',
                                  child: Text('All',
                                      style: TextStyle(
                                          fontSize: isMobile ? 11 : 13)),
                                ),
                                DropdownMenuItem(
                                  value: 'available',
                                  child: Text('Available',
                                      style: TextStyle(
                                          fontSize: isMobile ? 11 : 13)),
                                ),
                                DropdownMenuItem(
                                  value: 'in-use',
                                  child: Text('In Use',
                                      style: TextStyle(
                                          fontSize: isMobile ? 11 : 13)),
                                ),
                              ],
                              onChanged: (value) {
                                inventoryProvider.setAvailability(value);
                              },
                            ),
                          ),
                          SizedBox(width: isMobile ? 4 : 8),
                          // Expanded search bar
                          Expanded(
                            child: TextField(
                              decoration: InputDecoration(
                                hintText: 'Search tools...',
                                hintStyle:
                                    TextStyle(fontSize: isMobile ? 11 : 14),
                                prefixIcon: Icon(Icons.search,
                                    size: isMobile ? 18 : 20),
                                suffixIcon: inventoryProvider
                                            .searchQuery.isNotEmpty ||
                                        (inventoryProvider.selectedCategory !=
                                                null &&
                                            inventoryProvider
                                                    .selectedCategory !=
                                                'All') ||
                                        (inventoryProvider
                                                    .selectedAvailability !=
                                                null &&
                                            inventoryProvider
                                                    .selectedAvailability !=
                                                'All')
                                    ? IconButton(
                                        icon: Icon(Icons.clear,
                                            size: isMobile ? 18 : 20),
                                        onPressed: () {
                                          inventoryProvider.clearFilters();
                                        },
                                      )
                                    : null,
                                border: const OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: isMobile ? 8 : 12,
                                  vertical: isMobile ? 8 : 12,
                                ),
                                isDense: true,
                              ),
                              style: TextStyle(fontSize: isMobile ? 12 : 14),
                              onChanged: (value) {
                                inventoryProvider.setSearchQuery(value);
                              },
                            ),
                          ),
                          SizedBox(width: isMobile ? 4 : 8),
                          // Actions menu button
                          PopupMenuButton<String>(
                            icon:
                                Icon(Icons.more_vert, size: isMobile ? 20 : 24),
                            tooltip: 'Actions',
                            onSelected: (value) {
                              switch (value) {
                                case 'scan':
                                  showDialog(
                                    context: context,
                                    builder: (context) =>
                                        const QrScannerDialog(),
                                  );
                                  break;
                                case 'add':
                                  showDialog(
                                    context: context,
                                    builder: (context) => const AddToolDialog(),
                                  );
                                  break;
                                case 'settings':
                                  showDialog(
                                    context: context,
                                    builder: (context) =>
                                        const ToolSettingsDialog(),
                                  );
                                  break;
                                case 'print':
                                  if (inventoryProvider.tools.isNotEmpty) {
                                    showDialog(
                                      context: context,
                                      builder: (context) =>
                                          QrCodePrintPreviewDialog(
                                        tools: inventoryProvider.tools,
                                      ),
                                    );
                                  }
                                  break;
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'scan',
                                child: Row(
                                  children: [
                                    Icon(Icons.qr_code_scanner,
                                        color: Colors.blue,
                                        size: isMobile ? 18 : 20),
                                    SizedBox(width: 8),
                                    Text('Scan',
                                        style: TextStyle(
                                            fontSize: isMobile ? 12 : 14)),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'add',
                                child: Row(
                                  children: [
                                    Icon(Icons.add,
                                        color: Colors.green,
                                        size: isMobile ? 18 : 20),
                                    SizedBox(width: 8),
                                    Text('Add',
                                        style: TextStyle(
                                            fontSize: isMobile ? 12 : 14)),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'settings',
                                child: Row(
                                  children: [
                                    Icon(Icons.settings,
                                        color: Colors.grey[700],
                                        size: isMobile ? 18 : 20),
                                    SizedBox(width: 8),
                                    Text('Settings',
                                        style: TextStyle(
                                            fontSize: isMobile ? 12 : 14)),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'print',
                                enabled: inventoryProvider.tools.isNotEmpty,
                                child: Row(
                                  children: [
                                    Icon(Icons.print,
                                        color: inventoryProvider.tools.isEmpty
                                            ? Colors.grey
                                            : Colors.orange,
                                        size: isMobile ? 18 : 20),
                                    SizedBox(width: 8),
                                    Text('QR Stickers',
                                        style: TextStyle(
                                            fontSize: isMobile ? 12 : 14)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      // Results count
                      if (inventoryProvider.filteredTools.length !=
                          inventoryProvider.tools.length) ...[
                        SizedBox(height: isMobile ? 6 : 12),
                        Text(
                          'Showing ${inventoryProvider.filteredTools.length} of ${inventoryProvider.tools.length} tools',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 13,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  );
                },
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        return GridView.builder(
          padding: EdgeInsets.all(isMobile ? 10 : 16),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: isMobile ? 160 : 200,
            childAspectRatio: isMobile ? 0.72 : 0.75,
            crossAxisSpacing: isMobile ? 10 : 16,
            mainAxisSpacing: isMobile ? 10 : 16,
          ),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final group = groups[index];
            final baseName = group.key;
            final tools = group.value;
            return GroupedToolCard(baseName: baseName, tools: tools);
          },
        );
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
    final isMobile = MediaQuery.of(context).size.width < 600;

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
                margin: EdgeInsets.all(isMobile ? 3 : 4),
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
                          return Icon(Icons.construction,
                              size: isMobile ? 48 : 64, color: Colors.grey);
                        },
                      )
                    : Icon(Icons.construction,
                        size: isMobile ? 48 : 64, color: Colors.grey),
              ),
            ),
            // Details
            Padding(
              padding: EdgeInsets.all(isMobile ? 8 : 12),
              child: Column(
                spacing: isMobile ? 3 : 4,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    baseName,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: isMobile ? 13 : 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    firstTool.category,
                    style: TextStyle(
                      fontSize: isMobile ? 9 : 11,
                      color: Colors.grey[600],
                    ),
                  ),
                  // Tool type and quantity in same row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: isMobile ? 4 : 6,
                            vertical: isMobile ? 1 : 2),
                        decoration: BoxDecoration(
                          color: firstTool.toolType == ToolType.team
                              ? Colors.blue.shade100
                              : firstTool.toolType == ToolType.individual
                                  ? Colors.purple.shade100
                                  : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          firstTool.toolType.displayName.toUpperCase(),
                          style: TextStyle(
                            fontSize: isMobile ? 7 : 9,
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
                          fontSize: isMobile ? 10 : 12,
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
                            size: isMobile ? 12 : 14,
                            color: Colors.green,
                          ),
                          SizedBox(width: isMobile ? 2 : 4),
                          Text(
                            'Available',
                            style: TextStyle(
                              fontSize: isMobile ? 9 : 11,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '$availableCount',
                        style: TextStyle(
                          fontSize: isMobile ? 10 : 12,
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
                              size: isMobile ? 12 : 14,
                              color: Colors.orange,
                            ),
                            SizedBox(width: isMobile ? 2 : 4),
                            Text(
                              'In Use',
                              style: TextStyle(
                                fontSize: isMobile ? 9 : 11,
                                color: Colors.orange,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '$inUseCount',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 12,
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
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit Group',
            onPressed: () async {
              final result = await showDialog<bool>(
                context: context,
                builder: (context) => EditBaseNameToolsDialog(
                  baseName: baseName,
                  tools: tools,
                ),
              );

              // If changes were made, pop back to refresh the list
              if (result == true && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Info banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.blue.shade50,
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue.shade700, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tap "Edit" to change all ${tools.length} tools at once (base name, category, quantity)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isMobile = constraints.maxWidth < 600;
                return GridView.builder(
                  padding: EdgeInsets.all(isMobile ? 10 : 16),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: isMobile ? 160 : 200,
                    childAspectRatio: isMobile ? 0.72 : 0.75,
                    crossAxisSpacing: isMobile ? 10 : 16,
                    mainAxisSpacing: isMobile ? 10 : 16,
                  ),
                  itemCount: tools.length,
                  itemBuilder: (context, index) {
                    final tool = tools[index];
                    return ToolCard(tool: tool);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ToolCard extends StatelessWidget {
  final InventoryTool tool;

  const ToolCard({super.key, required this.tool});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

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
                margin: EdgeInsets.all(isMobile ? 3 : 4),
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
                          return Icon(Icons.construction,
                              size: isMobile ? 48 : 64, color: Colors.grey);
                        },
                      )
                    : Icon(Icons.construction,
                        size: isMobile ? 48 : 64, color: Colors.grey),
              ),
            ),
            // Details
            Padding(
              padding: EdgeInsets.all(isMobile ? 8 : 12),
              child: Column(
                spacing: isMobile ? 3 : 4,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool.name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: isMobile ? 13 : 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    tool.toolId,
                    style: TextStyle(
                      fontSize: isMobile ? 9 : 11,
                      color: Colors.blue[700],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    tool.category,
                    style: TextStyle(
                      fontSize: isMobile ? 9 : 11,
                      color: Colors.grey[600],
                    ),
                  ),
                  // Tool type badge
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: isMobile ? 4 : 6,
                        vertical: isMobile ? 1 : 2),
                    decoration: BoxDecoration(
                      color: tool.toolType == ToolType.team
                          ? Colors.blue.shade100
                          : tool.toolType == ToolType.individual
                              ? Colors.purple.shade100
                              : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      tool.toolType.displayName.toUpperCase(),
                      style: TextStyle(
                        fontSize: isMobile ? 7 : 9,
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
                        size: isMobile ? 13 : 16,
                        color: tool.isAvailable ? Colors.green : Colors.orange,
                      ),
                      SizedBox(width: isMobile ? 2 : 4),
                      Text(
                        tool.isAvailable ? 'Available' : 'In Use',
                        style: TextStyle(
                          fontSize: isMobile ? 10 : 12,
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
