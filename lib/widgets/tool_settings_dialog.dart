import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tool_settings.dart';
import '../models/inventory_tool.dart';
import '../providers/tool_settings_provider.dart';
import '../providers/inventory_provider.dart';

class ToolSettingsDialog extends StatefulWidget {
  const ToolSettingsDialog({super.key});

  @override
  State<ToolSettingsDialog> createState() => _ToolSettingsDialogState();
}

class _ToolSettingsDialogState extends State<ToolSettingsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    // Load settings when dialog opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ToolSettingsProvider>().loadSettings();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 900,
        height: 700,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.settings, size: 28),
                const SizedBox(width: 12),
                const Text(
                  'Default Tool Requirements',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Configure default tools needed for teams and individual cleaners',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            // Tabs
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Team Tools'),
                Tab(text: 'Individual Cleaner Tools'),
              ],
            ),
            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildTeamToolsTab(),
                  _buildIndividualToolsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTeamToolsTab() {
    return Consumer2<ToolSettingsProvider, InventoryProvider>(
      builder: (context, settingsProvider, inventoryProvider, child) {
        if (settingsProvider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            const Text(
              'Tools needed for the entire team (regardless of team size)',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            // Add tool button
            ElevatedButton.icon(
              onPressed: () => _showAddToolDialog(context, ToolType.team),
              icon: const Icon(Icons.add),
              label: const Text('Add Team Tool'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            // Tools list
            Expanded(
              child: settingsProvider.settings.teamTools.isEmpty
                  ? const Center(
                      child: Text(
                        'No team tools configured.\nAdd tools that the entire team needs.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: settingsProvider.settings.teamTools.length,
                      itemBuilder: (context, index) {
                        final tool = settingsProvider.settings.teamTools[index];
                        return _buildToolListItem(
                            tool, settingsProvider, ToolType.team);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildIndividualToolsTab() {
    return Consumer2<ToolSettingsProvider, InventoryProvider>(
      builder: (context, settingsProvider, inventoryProvider, child) {
        if (settingsProvider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            const Text(
              'Tools needed per cleaner (quantities will be multiplied by number of cleaners)',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            // Add tool button
            ElevatedButton.icon(
              onPressed: () => _showAddToolDialog(context, ToolType.individual),
              icon: const Icon(Icons.add),
              label: const Text('Add Individual Tool'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            // Tools list
            Expanded(
              child: settingsProvider.settings.individualTools.isEmpty
                  ? const Center(
                      child: Text(
                        'No individual tools configured.\nAdd tools that each cleaner needs.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount:
                          settingsProvider.settings.individualTools.length,
                      itemBuilder: (context, index) {
                        final tool =
                            settingsProvider.settings.individualTools[index];
                        return _buildToolListItem(
                            tool, settingsProvider, ToolType.individual);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildToolListItem(
    ToolRequirement tool,
    ToolSettingsProvider provider,
    ToolType toolType,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.orange.shade100,
          child: const Icon(Icons.construction, color: Colors.orange),
        ),
        title: Text(
          tool.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tool.category),
            Text('ID: ${tool.toolId}', style: const TextStyle(fontSize: 11)),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Quantity controls
            IconButton(
              onPressed: tool.quantity > 1
                  ? () {
                      if (toolType == ToolType.team) {
                        provider.updateTeamToolQuantity(
                            tool.toolId, tool.quantity - 1);
                      } else {
                        provider.updateIndividualToolQuantity(
                            tool.toolId, tool.quantity - 1);
                      }
                    }
                  : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${tool.quantity}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            IconButton(
              onPressed: () {
                if (toolType == ToolType.team) {
                  provider.updateTeamToolQuantity(
                      tool.toolId, tool.quantity + 1);
                } else {
                  provider.updateIndividualToolQuantity(
                      tool.toolId, tool.quantity + 1);
                }
              },
              icon: const Icon(Icons.add_circle_outline),
            ),
            // Delete button
            IconButton(
              onPressed: () {
                if (toolType == ToolType.team) {
                  provider.removeTeamTool(tool.toolId);
                } else {
                  provider.removeIndividualTool(tool.toolId);
                }
              },
              icon: const Icon(Icons.delete, color: Colors.red),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddToolDialog(BuildContext context, ToolType toolType) {
    showDialog(
      context: context,
      builder: (dialogContext) => _AddToolToSettingsDialog(toolType: toolType),
    );
  }
}

class _AddToolToSettingsDialog extends StatefulWidget {
  final ToolType toolType;

  const _AddToolToSettingsDialog({required this.toolType});

  @override
  State<_AddToolToSettingsDialog> createState() =>
      _AddToolToSettingsDialogState();
}

class _AddToolToSettingsDialogState extends State<_AddToolToSettingsDialog> {
  final Map<String, bool> _selectedTools = {};
  final Map<String, int> _toolQuantities = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.toolType == ToolType.team
          ? 'Add Team Tools'
          : 'Add Individual Tools'),
      content: SizedBox(
        width: 600,
        height: 500,
        child: Consumer2<InventoryProvider, ToolSettingsProvider>(
          builder: (context, inventoryProvider, settingsProvider, child) {
            // Get already added tool IDs to filter them out
            final existingToolIds = widget.toolType == ToolType.team
                ? settingsProvider.settings.teamTools
                    .map((t) => t.toolId)
                    .toSet()
                : settingsProvider.settings.individualTools
                    .map((t) => t.toolId)
                    .toSet();

            // Filter tools based on designation and exclude already added ones
            final availableTools = inventoryProvider.tools.where((tool) {
              // Exclude tools already added
              if (existingToolIds.contains(tool.toolId)) return false;

              // Filter by tool type
              return tool.toolType == widget.toolType;
            }).toList();

            if (availableTools.isEmpty) {
              return Center(
                child: Text(
                  widget.toolType == ToolType.team
                      ? 'No team tools available.\nMark tools as "Team Tool" when adding them to inventory.'
                      : 'No individual tools available.\nMark tools as "Individual Tool" when adding them to inventory.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              );
            }

            return Column(
              children: [
                // Header with select all
                Row(
                  children: [
                    Checkbox(
                      value:
                          _selectedTools.values.every((selected) => selected) &&
                              _selectedTools.length == availableTools.length,
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            for (var tool in availableTools) {
                              _selectedTools[tool.toolId] = true;
                              _toolQuantities[tool.toolId] ??= 1;
                            }
                          } else {
                            _selectedTools.clear();
                          }
                        });
                      },
                    ),
                    const Text(
                      'Select All',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    Text(
                      '${_selectedTools.values.where((v) => v).length} selected',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
                const Divider(),
                // Tools list
                Expanded(
                  child: ListView.builder(
                    itemCount: availableTools.length,
                    itemBuilder: (context, index) {
                      final tool = availableTools[index];
                      final isSelected = _selectedTools[tool.toolId] ?? false;
                      final quantity = _toolQuantities[tool.toolId] ?? 1;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Checkbox(
                            value: isSelected,
                            onChanged: (value) {
                              setState(() {
                                _selectedTools[tool.toolId] = value ?? false;
                                if (value == true) {
                                  _toolQuantities[tool.toolId] ??= 1;
                                }
                              });
                            },
                          ),
                          title: Text(
                            tool.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(tool.category),
                              Text(
                                'ID: ${tool.toolId}',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                          trailing: isSelected
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Qty:'),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      onPressed: quantity > 1
                                          ? () {
                                              setState(() {
                                                _toolQuantities[tool.toolId] =
                                                    quantity - 1;
                                              });
                                            }
                                          : null,
                                      icon: const Icon(
                                          Icons.remove_circle_outline),
                                      iconSize: 20,
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade200,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        '$quantity',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () {
                                        setState(() {
                                          _toolQuantities[tool.toolId] =
                                              quantity + 1;
                                        });
                                      },
                                      icon:
                                          const Icon(Icons.add_circle_outline),
                                      iconSize: 20,
                                    ),
                                  ],
                                )
                              : null,
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selectedTools.values.any((selected) => selected)
              ? () async {
                  final settingsProvider = context.read<ToolSettingsProvider>();
                  final inventoryProvider = context.read<InventoryProvider>();

                  // Get selected tools
                  final selectedToolIds = _selectedTools.entries
                      .where((entry) => entry.value)
                      .map((entry) => entry.key)
                      .toList();

                  // Add each selected tool
                  for (final toolId in selectedToolIds) {
                    final tool = inventoryProvider.tools.firstWhere(
                      (t) => t.toolId == toolId,
                    );
                    final quantity = _toolQuantities[toolId] ?? 1;

                    final toolRequirement = ToolRequirement(
                      toolId: tool.toolId,
                      name: tool.name,
                      category: tool.category,
                      quantity: quantity,
                    );

                    if (widget.toolType == ToolType.team) {
                      await settingsProvider.addTeamTool(toolRequirement);
                    } else {
                      await settingsProvider.addIndividualTool(toolRequirement);
                    }
                  }

                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                }
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
          ),
          child: Text(
            'Add ${_selectedTools.values.where((v) => v).length} Tool${_selectedTools.values.where((v) => v).length != 1 ? 's' : ''}',
          ),
        ),
      ],
    );
  }
}
