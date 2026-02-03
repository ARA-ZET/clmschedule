import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/happy_sun_shared.dart';
import '../models/happy_sun_project.dart';
import '../models/inventory_tool.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/inventory_provider.dart';

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
  MobileScannerController? _scannerController;
  bool _isScanning = false;

  // Track tools taken with actual tool IDs
  final Map<String, List<String>> _toolsTaken =
      {}; // baseName -> [toolId1, toolId2, ...]
  bool _isSaving = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initializeToolsTaken();

    // Auto-start scanner when scan tab is selected
    _tabController.addListener(() {
      if (_tabController.index == 0 && !_isScanning) {
        _startScanning();
      } else if (_tabController.index != 0 && _isScanning) {
        _stopScanning();
      }
    });

    // Start scanner immediately if on scan tab
    if (_tabController.index == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startScanning();
      });
    }
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
    _scannerController?.dispose();
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
        appBar: AppBar(
          title: const Text('Checkout Tools'),
          backgroundColor: Colors.orange,
          foregroundColor: Colors.white,
          actions: [
            if (_hasUnsavedChanges)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
        body: Column(
          children: [
            Expanded(
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
        ),
      ),
    );
  }

  Widget _buildScanTab() {
    return Consumer<InventoryProvider>(
      builder: (context, inventoryProvider, child) {
        return Column(
          children: [
            // Scanner area
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300, width: 2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _isScanning && _scannerController != null
                      ? Stack(
                          children: [
                            MobileScanner(
                              controller: _scannerController,
                              onDetect: (capture) => _handleBarcodeScan(
                                  capture, inventoryProvider),
                            ),
                            // Scan overlay
                            Center(
                              child: Container(
                                width: 250,
                                height: 250,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.green,
                                    width: 3,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.7),
                                        borderRadius: const BorderRadius.only(
                                          bottomLeft: Radius.circular(8),
                                          bottomRight: Radius.circular(8),
                                        ),
                                      ),
                                      child: const Text(
                                        'Align QR code within frame',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        )
                      : Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const CircularProgressIndicator(
                                color: Colors.orange,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Initializing camera...',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
            // Recently scanned
            if (_toolsTaken.isNotEmpty) ...[
              const Divider(),
              Padding(
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
                            onDeleted: () => _removeToolById(entry.key, toolId),
                          );
                        });
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  void _startScanning() {
    setState(() {
      _isScanning = true;
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    });
  }

  void _stopScanning() {
    setState(() {
      _isScanning = false;
      _scannerController?.dispose();
      _scannerController = null;
    });
  }

  void _handleBarcodeScan(
      BarcodeCapture capture, InventoryProvider inventoryProvider) {
    final List<Barcode> barcodes = capture.barcodes;

    for (final barcode in barcodes) {
      final String? code = barcode.rawValue;

      if (code == null || code.isEmpty) continue;

      // Find the tool in inventory by QR code or tool ID
      try {
        final tool = inventoryProvider.tools.firstWhere(
          (t) => t.qrCode == code || t.toolId == code,
        );

        final baseName = _extractBaseName(tool.name);

        // Check if tool is already scanned
        if (_toolsTaken[baseName]?.contains(tool.id) == true) {
          _showScanError('Tool already scanned: ${tool.name}');
          continue;
        }

        // Check if tool is in use by another job
        if (tool.isInUse && tool.currentProject != widget.project.id) {
          _showScanError('Tool is currently in use on another job');
          continue;
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
  }

  void _showScanSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showScanError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
              margin: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                onTap: () => _showManualSelection(
                  context,
                  inventoryProvider,
                  tool.baseName,
                  tool.category,
                  entry.type,
                  needed,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: entry.color.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          _getCategoryIcon(tool.category),
                          color: entry.color,
                        ),
                      ),
                      const SizedBox(width: 16),
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
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: entry.color.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    entry.type,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: entry.color,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              tool.category,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  isComplete
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  size: 16,
                                  color:
                                      isComplete ? Colors.green : Colors.orange,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Taken: $taken / $needed',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: isComplete
                                        ? Colors.green
                                        : Colors.orange,
                                  ),
                                ),
                              ],
                            ),
                            if (takenIds.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: takenIds.map((id) {
                                  final readableId = _getReadableToolId(
                                      id, inventoryProvider.tools);
                                  return Chip(
                                    label: Text(
                                      readableId,
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                    deleteIcon:
                                        const Icon(Icons.close, size: 14),
                                    onDeleted: () =>
                                        _removeToolById(tool.baseName, id),
                                    visualDensity: VisualDensity.compact,
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
                                                color: Colors.orange.shade700),
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
                                                          : Colors
                                                              .orange.shade700,
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
                                                    color: Colors.grey.shade600,
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

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final takenIds = _toolsTaken[baseName] ?? [];

          return AlertDialog(
            title: Text('Select $baseName'),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
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
      child: Row(
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
            onPressed: _hasUnsavedChanges && !_isSaving ? _saveProgress : null,
            icon: _isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: const Text('Save'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
