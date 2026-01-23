import 'package:flutter/material.dart';
import '../models/happy_sun_job.dart';
import '../models/inventory_tool.dart';

class ProjectToolsDialog extends StatefulWidget {
  final CategorizedTools toolsNeeded;
  final List<InventoryTool> availableTools;
  final Function(CategorizedTools) onSave;

  const ProjectToolsDialog({
    super.key,
    required this.toolsNeeded,
    required this.availableTools,
    required this.onSave,
  });

  @override
  State<ProjectToolsDialog> createState() => _ProjectToolsDialogState();
}

class _ProjectToolsDialogState extends State<ProjectToolsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late List<GroupedToolItem> _teamTools;
  late List<GroupedToolItem> _individualTools;
  late List<GroupedToolItem> _extras;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _teamTools = List.from(widget.toolsNeeded.teamTools);
    _individualTools = List.from(widget.toolsNeeded.individualTools);
    _extras = List.from(widget.toolsNeeded.extras);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _markAsChanged() {
    setState(() {
      _hasChanges = true;
    });
  }

  void _saveChanges() {
    final updatedTools = CategorizedTools(
      teamTools: _teamTools,
      individualTools: _individualTools,
      extras: _extras,
    );
    widget.onSave(updatedTools);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        width: double.infinity,
        height: MediaQuery.of(context).size.height * 0.9,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.construction, size: 28, color: Colors.orange),
                const SizedBox(width: 12),
                const Text(
                  'Project Tools Needed',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (_hasChanges)
                  const Chip(
                    label: Text('Unsaved changes'),
                    backgroundColor: Colors.orange,
                    labelStyle: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Total: ${_teamTools.fold<int>(0, (sum, t) => sum + t.totalQuantity) + _individualTools.fold<int>(0, (sum, t) => sum + t.totalQuantity) + _extras.fold<int>(0, (sum, t) => sum + t.totalQuantity)} tools',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            // Tabs
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Team Tools'),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(
                            '${_teamTools.fold<int>(0, (sum, t) => sum + t.totalQuantity)}'),
                        backgroundColor: Colors.blue.shade100,
                        labelStyle: const TextStyle(fontSize: 12),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Individual'),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(
                            '${_individualTools.fold<int>(0, (sum, t) => sum + t.totalQuantity)}'),
                        backgroundColor: Colors.green.shade100,
                        labelStyle: const TextStyle(fontSize: 12),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Extras'),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(
                            '${_extras.fold<int>(0, (sum, t) => sum + t.totalQuantity)}'),
                        backgroundColor: Colors.purple.shade100,
                        labelStyle: const TextStyle(fontSize: 12),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildToolsList(_teamTools, ToolType.team, Colors.blue),
                  _buildToolsList(
                      _individualTools, ToolType.individual, Colors.green),
                  _buildToolsList(_extras, ToolType.extras, Colors.purple),
                ],
              ),
            ),
            // Action buttons
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _hasChanges ? _saveChanges : null,
                  icon: const Icon(Icons.save),
                  label: const Text('Save Changes'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolsList(
      List<GroupedToolItem> tools, ToolType toolType, Color accentColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        // Add tool button
        ElevatedButton.icon(
          onPressed: () => _showAddToolDialog(toolType),
          icon: const Icon(Icons.add),
          label: const Text('Add Tool'),
          style: ElevatedButton.styleFrom(
            backgroundColor: accentColor,
            foregroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        // Tools list
        Expanded(
          child: tools.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.construction,
                          size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        'No ${toolType.displayName.toLowerCase()} configured',
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: tools.length,
                  itemBuilder: (context, index) {
                    final tool = tools[index];
                    return _buildToolCard(tool, toolType, accentColor, () {
                      setState(() {
                        if (toolType == ToolType.team) {
                          _teamTools.removeAt(index);
                        } else if (toolType == ToolType.individual) {
                          _individualTools.removeAt(index);
                        } else {
                          _extras.removeAt(index);
                        }
                        _markAsChanged();
                      });
                    }, (newQuantity) {
                      setState(() {
                        // Update quantity
                        final updatedTool = GroupedToolItem(
                          baseName: tool.baseName,
                          category: tool.category,
                          totalQuantity: newQuantity,
                          toolIds: List.generate(newQuantity, (_) => ''),
                        );
                        if (toolType == ToolType.team) {
                          _teamTools[index] = updatedTool;
                        } else if (toolType == ToolType.individual) {
                          _individualTools[index] = updatedTool;
                        } else {
                          _extras[index] = updatedTool;
                        }
                        _markAsChanged();
                      });
                    });
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildToolCard(
    GroupedToolItem tool,
    ToolType toolType,
    Color accentColor,
    VoidCallback onDelete,
    Function(int) onQuantityChange,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Tool icon
            CircleAvatar(
              backgroundColor: accentColor.withOpacity(0.2),
              child: Icon(Icons.construction, color: accentColor),
            ),
            const SizedBox(width: 16),
            // Tool details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool.baseName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tool.category,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            // Quantity controls
            IconButton(
              onPressed: tool.totalQuantity > 1
                  ? () => onQuantityChange(tool.totalQuantity - 1)
                  : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${tool.totalQuantity}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
            IconButton(
              onPressed: () => onQuantityChange(tool.totalQuantity + 1),
              icon: const Icon(Icons.add_circle_outline),
            ),
            // Delete button
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete, color: Colors.red),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddToolDialog(ToolType toolType) {
    // Get available base names from inventory that match the tool type
    final availableBaseNames = widget.availableTools
        .where((tool) => tool.toolType == toolType)
        .map((tool) => tool.baseName)
        .toSet()
        .toList()
      ..sort();

    // Filter out already added tools
    final List<GroupedToolItem> currentTools;
    if (toolType == ToolType.team) {
      currentTools = _teamTools;
    } else if (toolType == ToolType.individual) {
      currentTools = _individualTools;
    } else {
      currentTools = _extras;
    }

    final existingBaseNames = currentTools.map((t) => t.baseName).toSet();
    final selectableBaseNames = availableBaseNames
        .where((baseName) => !existingBaseNames.contains(baseName))
        .toList();

    if (selectableBaseNames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'No ${toolType.displayName.toLowerCase()} available in inventory'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => _AddToolDialog(
        availableBaseNames: selectableBaseNames,
        availableTools: widget.availableTools,
        toolType: toolType,
        onAdd: (baseName, category, quantity) {
          setState(() {
            final newTool = GroupedToolItem(
              baseName: baseName,
              category: category,
              totalQuantity: quantity,
              toolIds: List.generate(quantity, (_) => ''),
            );
            if (toolType == ToolType.team) {
              _teamTools.add(newTool);
            } else if (toolType == ToolType.individual) {
              _individualTools.add(newTool);
            } else {
              _extras.add(newTool);
            }
            _markAsChanged();
          });
        },
      ),
    );
  }
}

class _AddToolDialog extends StatefulWidget {
  final List<String> availableBaseNames;
  final List<InventoryTool> availableTools;
  final ToolType toolType;
  final Function(String baseName, String category, int quantity) onAdd;

  const _AddToolDialog({
    required this.availableBaseNames,
    required this.availableTools,
    required this.toolType,
    required this.onAdd,
  });

  @override
  State<_AddToolDialog> createState() => _AddToolDialogState();
}

class _AddToolDialogState extends State<_AddToolDialog> {
  String? _selectedBaseName;
  int _quantity = 1;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add ${widget.toolType.displayName}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Base name dropdown
            DropdownButtonFormField<String>(
              value: _selectedBaseName,
              decoration: const InputDecoration(
                labelText: 'Tool Base Name',
                border: OutlineInputBorder(),
              ),
              items: widget.availableBaseNames.map((baseName) {
                final tool = widget.availableTools.firstWhere(
                  (t) =>
                      t.baseName == baseName && t.toolType == widget.toolType,
                );
                return DropdownMenuItem(
                  value: baseName,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(baseName,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(tool.category,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedBaseName = value;
                });
              },
            ),
            const SizedBox(height: 16),
            // Quantity selector
            Row(
              children: [
                const Text('Quantity:', style: TextStyle(fontSize: 16)),
                const Spacer(),
                IconButton(
                  onPressed:
                      _quantity > 1 ? () => setState(() => _quantity--) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$_quantity',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _quantity++),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selectedBaseName != null
              ? () {
                  final tool = widget.availableTools.firstWhere(
                    (t) =>
                        t.baseName == _selectedBaseName &&
                        t.toolType == widget.toolType,
                  );
                  widget.onAdd(_selectedBaseName!, tool.category, _quantity);
                  Navigator.pop(context);
                }
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
          ),
          child: const Text('Add Tool'),
        ),
      ],
    );
  }
}
