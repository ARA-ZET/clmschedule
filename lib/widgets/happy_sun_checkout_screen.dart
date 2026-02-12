import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_shared.dart';
import '../models/happy_sun_project.dart';
import '../models/inventory_tool.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/inventory_provider.dart';
import 'happy_sun_qr_scanner_widget.dart';

class HappySunCheckoutScreen extends StatefulWidget {
  final HappySunProject project;

  const HappySunCheckoutScreen({
    super.key,
    required this.project,
  });

  @override
  State<HappySunCheckoutScreen> createState() => _HappySunCheckoutScreenState();
}

class _HappySunCheckoutScreenState extends State<HappySunCheckoutScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final GlobalKey<HappySunQRScannerWidgetState> _scannerKey = GlobalKey();

  // Track tools taken with actual tool IDs
  final Map<String, List<String>> _toolsTaken =
      {}; // baseName -> [toolId1, toolId2, ...]
  bool _isSaving = false;
  bool _hasUnsavedChanges = false;

  // Scan feedback
  String _scanMessage = 'Align QR code within frame';
  Color _scanMessageColor = Colors.white;
  Timer? _scanMessageTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initializeToolsTaken();

    // Auto-start scanner when scan tab is selected
    _tabController.addListener(() {
      if (_tabController.index == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scannerKey.currentState?.startScanning();
        });
      } else {
        _scannerKey.currentState?.stopScanning();
      }
    });
  }

  void _initializeToolsTaken() {
    // Initialize from existing tools if any (for resume scenario)
    if (widget.project.toolsUsedCategorized != null) {
      final categorized = widget.project.toolsUsedCategorized!;

      // Load existing tool IDs
      for (final tool in [
        ...categorized.teamTools,
        ...categorized.individualTools,
        ...categorized.extras,
        ...categorized.accessories
      ]) {
        _toolsTaken[tool.baseName] =
            List.from(tool.toolIds.where((id) => id.isNotEmpty));
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scanMessageTimer?.cancel();
    super.dispose();
  }

  bool _areAllToolsTaken() {
    if (widget.project.toolsNeeded == null) return true;

    final needed = widget.project.toolsNeeded!;

    // Check team tools
    for (final tool in needed.teamTools) {
      final taken = _toolsTaken[tool.baseName]?.length ?? 0;
      if (taken < tool.totalQuantity) return false;
    }

    // Check individual tools
    for (final tool in needed.individualTools) {
      final taken = _toolsTaken[tool.baseName]?.length ?? 0;
      if (taken < tool.totalQuantity) return false;
    }

    // Check extras
    for (final tool in needed.extras) {
      final taken = _toolsTaken[tool.baseName]?.length ?? 0;
      if (taken < tool.totalQuantity) return false;
    }

    // Check accessories
    for (final tool in needed.accessories) {
      final taken = _toolsTaken[tool.baseName]?.length ?? 0;
      if (taken < tool.totalQuantity) return false;
    }

    return true;
  }

  Future<void> _saveProgress() async {
    setState(() => _isSaving = true);

    try {
      final categorizedTools = _buildCategorizedToolsUsed();
      final jobProvider = context.read<HappySunProjectProvider>();

      await jobProvider.updateToolsUsed(
        widget.project.id,
        categorizedTools,
      );

      setState(() {
        _hasUnsavedChanges = false;
        _isSaving = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Progress saved'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _completeCheckout() async {
    if (!_areAllToolsTaken()) return;

    setState(() => _isSaving = true);

    try {
      final categorizedTools = _buildCategorizedToolsUsed();
      final jobProvider = context.read<HappySunProjectProvider>();
      final inventoryProvider = context.read<InventoryProvider>();

      // Get all tool IDs that were taken
      final allToolIds = <String>[];
      for (final toolIds in _toolsTaken.values) {
        allToolIds.addAll(toolIds);
      }

      // Update tools used and record start time
      await jobProvider.updateToolsUsed(
        widget.project.id,
        categorizedTools,
      );

      await jobProvider.updateStartTime(
        widget.project.id,
        DateTime.now(),
      );

      // Mark tools as checked out in inventory
      await inventoryProvider.checkOutTools(allToolIds, widget.project.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Checkout completed successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error completing checkout: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  CategorizedTools _buildCategorizedToolsUsed() {
    if (widget.project.toolsNeeded == null) {
      return CategorizedTools();
    }

    final needed = widget.project.toolsNeeded!;

    // Build team tools with actual IDs
    final teamTools = needed.teamTools
        .map((tool) {
          final takenIds = _toolsTaken[tool.baseName] ?? [];
          return GroupedToolItem(
            baseName: tool.baseName,
            category: tool.category,
            totalQuantity: takenIds.length,
            toolIds: takenIds,
          );
        })
        .where((tool) => tool.totalQuantity > 0)
        .toList();

    // Build individual tools with actual IDs
    final individualTools = needed.individualTools
        .map((tool) {
          final takenIds = _toolsTaken[tool.baseName] ?? [];
          return GroupedToolItem(
            baseName: tool.baseName,
            category: tool.category,
            totalQuantity: takenIds.length,
            toolIds: takenIds,
          );
        })
        .where((tool) => tool.totalQuantity > 0)
        .toList();

    // Build extras with actual IDs
    final extras = needed.extras
        .map((tool) {
          final takenIds = _toolsTaken[tool.baseName] ?? [];
          return GroupedToolItem(
            baseName: tool.baseName,
            category: tool.category,
            totalQuantity: takenIds.length,
            toolIds: takenIds,
          );
        })
        .where((tool) => tool.totalQuantity > 0)
        .toList();

    // Build accessories with actual IDs
    final accessories = needed.accessories
        .map((tool) {
          final takenIds = _toolsTaken[tool.baseName] ?? [];
          return GroupedToolItem(
            baseName: tool.baseName,
            category: tool.category,
            totalQuantity: takenIds.length,
            toolIds: takenIds,
          );
        })
        .where((tool) => tool.totalQuantity > 0)
        .toList();

    return CategorizedTools(
      teamTools: teamTools,
      individualTools: individualTools,
      extras: extras,
      accessories: accessories,
    );
  }

  String _getReadableToolId(String firestoreId, List<InventoryTool> tools) {
    try {
      final tool = tools.firstWhere((t) => t.id == firestoreId);
      return tool.toolId;
    } catch (e) {
      return firestoreId; // Fallback to showing Firestore ID if tool not found
    }
  }

  // Helper to get base name from tool name (e.g., "Ladder #1" -> "Ladder")
  String _getBaseName(String toolName) {
    final hashIndex = toolName.lastIndexOf('#');
    if (hashIndex > 0) {
      return toolName.substring(0, hashIndex).trim();
    }
    return toolName;
  }

  // Get accessories needed for a specific tool (by baseName)
  List<AccessoryRequirement> _getRequiredAccessoriesForTool(
      String toolBaseName, List<InventoryTool> allTools) {
    try {
      // Find any tool matching this baseName
      final tool = allTools
          .where((t) => _getBaseName(t.name) == toolBaseName)
          .firstOrNull;
      if (tool != null) {
        return tool.requiredAccessories;
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  // Get number of accessories taken for a specific baseName
  int _getAccessoriesTakenCount(String accessoryBaseName) {
    return _toolsTaken[accessoryBaseName]?.length ?? 0;
  }

  void _addToolById(String toolId, String baseName) {
    setState(() {
      _toolsTaken.putIfAbsent(baseName, () => []).add(toolId);
      _hasUnsavedChanges = true;
    });
  }

  void _removeToolById(String baseName, String toolId) {
    setState(() {
      _toolsTaken[baseName]?.remove(toolId);
      if (_toolsTaken[baseName]?.isEmpty ?? false) {
        _toolsTaken.remove(baseName);
      }
      _hasUnsavedChanges = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return WillPopScope(
      onWillPop: () async {
        if (_hasUnsavedChanges) {
          final result = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Unsaved Changes'),
              content: const Text(
                  'You have unsaved changes. Do you want to save before leaving?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Discard'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Save'),
                ),
              ],
            ),
          );

          if (result == true) {
            await _saveProgress();
          }
        }
        return true;
      },
      child: Scaffold(
        appBar: isMobile
            ? null
            : AppBar(
                title: const Text('Checkout Tools'),
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                actions: [
                  if (_hasUnsavedChanges)
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Unsaved',
                            style: TextStyle(
                              color: Colors.orange,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
                bottom: TabBar(
                  controller: _tabController,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  indicatorColor: Colors.white,
                  tabs: const [
                    Tab(icon: Icon(Icons.qr_code_scanner), text: 'Scan'),
                    Tab(icon: Icon(Icons.list), text: 'Tools Taken'),
                  ],
                ),
              ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Calculate height for mobile header if present
              final mobileHeaderHeight = isMobile ? 120.0 : 0.0;
              // Calculate height for bottom actions
              final bottomActionsHeight = isMobile ? 140.0 : 100.0;
              // Calculate available height for TabBarView
              final tabViewHeight = constraints.maxHeight -
                  mobileHeaderHeight -
                  bottomActionsHeight;

              return Column(
                children: [
                  if (isMobile) _buildMobileHeader(),
                  SizedBox(
                    height: tabViewHeight,
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildScanTab(),
                        _buildToolsTakenTab(),
                      ],
                    ),
                  ),
                  _buildBottomActions(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildMobileHeader() {
    return Container(
      color: Colors.orange,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        children: [
          // Top row with back button and title
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Checkout Tools',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (_hasUnsavedChanges)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Unsaved',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Tab bar
          TabBar(
            controller: _tabController,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            tabs: const [
              Tab(icon: Icon(Icons.qr_code_scanner, size: 20), text: 'Scan'),
              Tab(icon: Icon(Icons.list, size: 20), text: 'Tools Taken'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScanTab() {
    return Consumer<InventoryProvider>(
      builder: (context, inventoryProvider, child) {
        return Column(
          children: [
            // Scanner widget
            HappySunQRScannerWidget(
              key: _scannerKey,
              onScan: _handleBarcodeScan,
              instructionText: _scanMessage,
              autoStart: false,
            ),
            // Recently scanned (scrollable and takes remaining space)
            if (_toolsTaken.isNotEmpty) ...[
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Recently Scanned',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _toolsTaken.entries.expand((entry) {
                          return entry.value.map((toolId) {
                            final readableId = _getReadableToolId(
                                toolId, inventoryProvider.tools);
                            return Chip(
                              avatar: const Icon(Icons.check_circle, size: 16),
                              label: Text('${entry.key} - $readableId'),
                              deleteIcon: const Icon(Icons.close, size: 16),
                              onDeleted: () =>
                                  _removeToolById(entry.key, toolId),
                            );
                          });
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  void _handleBarcodeScan(String code) {
    final inventoryProvider = context.read<InventoryProvider>();

    // Find the tool in inventory by QR code or tool ID
    try {
      final tool = inventoryProvider.tools.firstWhere(
        (t) => t.qrCode == code || t.toolId == code,
      );

      final baseName = _extractBaseName(tool.name);

      // Check if tool is already scanned
      if (_toolsTaken[baseName]?.contains(tool.id) == true) {
        _showScanError('Tool already scanned: ${tool.name}');
        return;
      }

      // Check if tool is in use by another job
      if (tool.isInUse && tool.currentProject != widget.project.id) {
        _showScanError('Tool is currently in use on another job');
        return;
      }

      // Add the tool
      _addToolById(tool.id, baseName);

      // Show success feedback
      _showScanSuccess('Added: ${tool.name}');

      // Vibrate or provide haptic feedback
      // HapticFeedback.mediumImpact(); // Uncomment if you want haptic feedback
    } catch (e) {
      // Tool not found
      _showScanError('Tool not found: $code');
    }
  }

  void _showScanSuccess(String message) {
    _scanMessageTimer?.cancel();
    setState(() {
      _scanMessage = message;
      _scanMessageColor = Colors.green;
    });

    _scanMessageTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _scanMessage = 'Align QR code within frame';
          _scanMessageColor = Colors.white;
        });
      }
    });
  }

  void _showScanError(String message) {
    _scanMessageTimer?.cancel();
    setState(() {
      _scanMessage = message;
      _scanMessageColor = Colors.red;
    });

    _scanMessageTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _scanMessage = 'Align QR code within frame';
          _scanMessageColor = Colors.white;
        });
      }
    });
  }

  Widget _buildToolsTakenTab() {
    if (widget.project.toolsNeeded == null) {
      return const Center(
        child: Text('No tools needed for this job'),
      );
    }

    final needed = widget.project.toolsNeeded!;
    final allNeededTools = [
      ...needed.teamTools.map((t) => _ToolNeededEntry(t, 'Team', Colors.blue)),
      ...needed.individualTools
          .map((t) => _ToolNeededEntry(t, 'Individual', Colors.green)),
      ...needed.extras.map((t) => _ToolNeededEntry(t, 'Extras', Colors.purple)),
      ...needed.accessories
          .map((t) => _ToolNeededEntry(t, 'Accessories', Colors.orange)),
    ];

    return Consumer<InventoryProvider>(
      builder: (context, inventoryProvider, child) {
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: allNeededTools.length,
          itemBuilder: (context, index) {
            final entry = allNeededTools[index];
            final tool = entry.tool;
            final takenIds = _toolsTaken[tool.baseName] ?? [];
            final needed = tool.totalQuantity;
            final taken = takenIds.length;
            final isComplete = taken >= needed;

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: isComplete ? Colors.green.shade600 : null,
              child: isComplete
                  ? ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          _getCategoryIcon(tool.category),
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              tool.baseName,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                          ),
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: Colors.white,
                          ),
                        ],
                      ),
                      subtitle: Text(
                        tool.category,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.check_circle,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Taken: $taken / $needed',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                              if (takenIds.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 3,
                                  runSpacing: 3,
                                  children: takenIds.map((id) {
                                    final readableId = _getReadableToolId(
                                        id, inventoryProvider.tools);
                                    return Chip(
                                      label: Text(
                                        readableId,
                                        style: const TextStyle(fontSize: 9),
                                      ),
                                      deleteIcon:
                                          const Icon(Icons.close, size: 12),
                                      onDeleted: () =>
                                          _removeToolById(tool.baseName, id),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    );
                                  }).toList(),
                                ),
                              ],

                              // Show accessories that need to be checked
                              ...(() {
                                final accessories = <Widget>[];

                                // Get required accessories for this tool baseName
                                final requiredAccessories =
                                    _getRequiredAccessoriesForTool(
                                        tool.baseName, inventoryProvider.tools);

                                if (requiredAccessories.isNotEmpty &&
                                    takenIds.isNotEmpty) {
                                  accessories.add(const SizedBox(height: 12));
                                  accessories.add(
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade50,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                            color: Colors.orange.shade200),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(Icons.extension,
                                                  size: 14,
                                                  color:
                                                      Colors.orange.shade700),
                                              const SizedBox(width: 6),
                                              Text(
                                                'Accessories needed for ${takenIds.length} × ${tool.baseName}:',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.orange.shade700,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          ...requiredAccessories
                                              .map((accessoryReq) {
                                            final neededQty =
                                                accessoryReq.quantity *
                                                    takenIds.length;
                                            final takenQty =
                                                _getAccessoriesTakenCount(
                                                    accessoryReq.baseName);
                                            final isComplete =
                                                takenQty >= neededQty;

                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 6),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    isComplete
                                                        ? Icons.check_circle
                                                        : Icons
                                                            .radio_button_unchecked,
                                                    size: 14,
                                                    color: isComplete
                                                        ? Colors.green
                                                        : Colors.orange,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      '${accessoryReq.baseName}: $takenQty / $neededQty',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: isComplete
                                                            ? Colors
                                                                .green.shade700
                                                            : Colors.orange
                                                                .shade700,
                                                        fontWeight: isComplete
                                                            ? FontWeight.w600
                                                            : FontWeight.normal,
                                                      ),
                                                    ),
                                                  ),
                                                  Text(
                                                    '(${accessoryReq.quantity} each)',
                                                    style: TextStyle(
                                                      fontSize: 9,
                                                      color:
                                                          Colors.grey.shade600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }),
                                        ],
                                      ),
                                    ),
                                  );
                                }
                                return accessories;
                              })(),
                            ],
                          ),
                        ),
                      ],
                    )
                  : InkWell(
                      onTap: () => _showManualSelection(
                        context,
                        inventoryProvider,
                        tool.baseName,
                        tool.category,
                        entry.type,
                        needed,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: entry.color.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                _getCategoryIcon(tool.category),
                                color: entry.color,
                                size: 14,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          tool.baseName,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: entry.color.withOpacity(0.2),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          entry.type,
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: entry.color,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    tool.category,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.radio_button_unchecked,
                                        size: 14,
                                        color: Colors.orange,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Taken: $taken / $needed',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.orange,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (takenIds.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 3,
                                      runSpacing: 3,
                                      children: takenIds.map((id) {
                                        final readableId = _getReadableToolId(
                                            id, inventoryProvider.tools);
                                        return Chip(
                                          label: Text(
                                            readableId,
                                            style: const TextStyle(fontSize: 9),
                                          ),
                                          deleteIcon:
                                              const Icon(Icons.close, size: 12),
                                          onDeleted: () => _removeToolById(
                                              tool.baseName, id),
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        );
                                      }).toList(),
                                    ),
                                  ],

                                  // Show accessories that need to be checked
                                  ...(() {
                                    final accessories = <Widget>[];

                                    // Get required accessories for this tool baseName
                                    final requiredAccessories =
                                        _getRequiredAccessoriesForTool(
                                            tool.baseName,
                                            inventoryProvider.tools);

                                    if (requiredAccessories.isNotEmpty &&
                                        takenIds.isNotEmpty) {
                                      accessories
                                          .add(const SizedBox(height: 12));
                                      accessories.add(
                                        Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: Colors.orange.shade50,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                                color: Colors.orange.shade200),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Icon(Icons.extension,
                                                      size: 14,
                                                      color: Colors
                                                          .orange.shade700),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    'Accessories needed for ${takenIds.length} × ${tool.baseName}:',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors
                                                          .orange.shade700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 8),
                                              ...requiredAccessories
                                                  .map((accessoryReq) {
                                                final neededQty =
                                                    accessoryReq.quantity *
                                                        takenIds.length;
                                                final takenQty =
                                                    _getAccessoriesTakenCount(
                                                        accessoryReq.baseName);
                                                final isComplete =
                                                    takenQty >= neededQty;

                                                return Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          bottom: 6),
                                                  child: Row(
                                                    children: [
                                                      Icon(
                                                        isComplete
                                                            ? Icons.check_circle
                                                            : Icons
                                                                .radio_button_unchecked,
                                                        size: 14,
                                                        color: isComplete
                                                            ? Colors.green
                                                            : Colors.orange,
                                                      ),
                                                      const SizedBox(width: 6),
                                                      Expanded(
                                                        child: Text(
                                                          '${accessoryReq.baseName}: $takenQty / $neededQty',
                                                          style: TextStyle(
                                                            fontSize: 11,
                                                            color: isComplete
                                                                ? Colors.green
                                                                    .shade700
                                                                : Colors.orange
                                                                    .shade700,
                                                            fontWeight:
                                                                isComplete
                                                                    ? FontWeight
                                                                        .w600
                                                                    : FontWeight
                                                                        .normal,
                                                          ),
                                                        ),
                                                      ),
                                                      Text(
                                                        '(${accessoryReq.quantity} each)',
                                                        style: TextStyle(
                                                          fontSize: 9,
                                                          color: Colors
                                                              .grey.shade600,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              }),
                                            ],
                                          ),
                                        ),
                                      );
                                    }
                                    return accessories;
                                  })(),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right, color: Colors.grey),
                          ],
                        ),
                      ),
                    ),
            );
          },
        );
      },
    );
  }

  void _showManualSelection(
    BuildContext context,
    InventoryProvider inventoryProvider,
    String baseName,
    String category,
    String type,
    int needed,
  ) {
    final availableTools = inventoryProvider.tools
        .where(
            (tool) => _extractBaseName(tool.name) == baseName && !tool.isInUse)
        .toList();

    final isMobile = MediaQuery.of(context).size.width < 600;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final takenIds = _toolsTaken[baseName] ?? [];
          // Get image URL from first tool (all tools with same basename share same image)
          final imageUrl =
              availableTools.isNotEmpty ? availableTools.first.imageUrl : null;

          return AlertDialog(
            insetPadding: isMobile ? EdgeInsets.zero : const EdgeInsets.all(40),
            title: Text('Select $baseName'),
            content: SizedBox(
              width: isMobile
                  ? MediaQuery.of(context).size.width
                  : double.maxFinite,
              height: isMobile ? MediaQuery.of(context).size.height * 0.7 : 400,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, color: Colors.orange),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Need: $needed | Selected: ${takenIds.length}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (availableTools.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text('No available tools of this type'),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        itemCount: availableTools.length,
                        itemBuilder: (context, index) {
                          final tool = availableTools[index];
                          final isSelected = takenIds.contains(tool.id);

                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (value) {
                              setState(() {
                                if (value == true) {
                                  _addToolById(tool.id, baseName);
                                } else {
                                  _removeToolById(baseName, tool.id);
                                }
                              });
                              // Update dialog UI without closing
                              setDialogState(() {});
                            },
                            title: Text(tool.name),
                            subtitle: Text(tool.toolId),
                            secondary: Icon(
                              _getCategoryIcon(tool.category),
                              color: Colors.orange,
                            ),
                          );
                        },
                      ),
                    ),
                  // Show single image at the bottom for all tools with this basename
                  if (imageUrl != null && imageUrl.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 8),
                    const Text(
                      'Tool Reference Image:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        imageUrl,
                        height: 200,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 200,
                            color: Colors.grey.shade200,
                            child: const Center(
                              child: Icon(
                                Icons.broken_image,
                                color: Colors.grey,
                                size: 48,
                              ),
                            ),
                          );
                        },
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) {
                            return child;
                          }
                          return Container(
                            height: 200,
                            color: Colors.grey.shade100,
                            child: Center(
                              child: CircularProgressIndicator(
                                value: loadingProgress.expectedTotalBytes !=
                                        null
                                    ? loadingProgress.cumulativeBytesLoaded /
                                        loadingProgress.expectedTotalBytes!
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBottomActions() {
    final allTaken = _areAllToolsTaken();
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: isMobile
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Progress
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Progress: ${_getTotalTaken()} / ${_getTotalNeeded()} tools',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: _getTotalNeeded() > 0
                          ? _getTotalTaken() / _getTotalNeeded()
                          : 0,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        allTaken ? Colors.green : Colors.orange,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Buttons
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _hasUnsavedChanges && !_isSaving
                            ? _saveProgress
                            : null,
                        icon: _isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save),
                        label: const Text('Save'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed:
                            allTaken && !_isSaving ? _completeCheckout : null,
                        icon: const Icon(Icons.check_circle, size: 20),
                        label: const Text('Complete'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Progress: ${_getTotalTaken()} / ${_getTotalNeeded()} tools',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: _getTotalNeeded() > 0
                            ? _getTotalTaken() / _getTotalNeeded()
                            : 0,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          allTaken ? Colors.green : Colors.orange,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed:
                      _hasUnsavedChanges && !_isSaving ? _saveProgress : null,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: const Text('Save'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: allTaken && !_isSaving ? _completeCheckout : null,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Complete Checkout'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                  ),
                ),
              ],
            ),
    );
  }

  int _getTotalNeeded() {
    if (widget.project.toolsNeeded == null) return 0;
    final needed = widget.project.toolsNeeded!;
    return needed.totalCount;
  }

  int _getTotalTaken() {
    return _toolsTaken.values.fold(0, (sum, ids) => sum + ids.length);
  }

  String _extractBaseName(String toolName) {
    final parts = toolName.split(' #');
    return parts.first;
  }

  IconData _getCategoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'cleaning':
        return Icons.cleaning_services;
      case 'safety':
        return Icons.shield;
      case 'electrical':
        return Icons.electrical_services;
      case 'access':
        return Icons.stairs;
      default:
        return Icons.build;
    }
  }
}

class _ToolNeededEntry {
  final GroupedToolItem tool;
  final String type;
  final Color color;

  _ToolNeededEntry(this.tool, this.type, this.color);
}
