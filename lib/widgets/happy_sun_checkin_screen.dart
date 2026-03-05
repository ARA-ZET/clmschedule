import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_project.dart';
import '../models/inventory_tool.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/inventory_provider.dart';
import '../services/sound_service.dart';
import 'happy_sun_qr_scanner_widget.dart';

class HappySunCheckinScreen extends StatefulWidget {
  final HappySunProject project;

  const HappySunCheckinScreen({
    super.key,
    required this.project,
  });

  @override
  State<HappySunCheckinScreen> createState() => _HappySunCheckinScreenState();
}

class _HappySunCheckinScreenState extends State<HappySunCheckinScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final GlobalKey<HappySunQRScannerWidgetState> _scannerKey = GlobalKey();

  final Map<String, _ToolCheckinStatus> _toolStatus = {}; // toolId -> status
  bool _isChecking = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initializeToolStatus();

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

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _initializeToolStatus() {
    // Load existing check-in progress if available
    final existingCheckin = widget.project.checkin;
    final returnedToolsMap = existingCheckin != null
        ? {for (var tool in existingCheckin.returnedTools) tool.toolId: true}
        : <String, bool>{};

    // Use checklist data if available
    if (widget.project.checklistData != null) {
      for (final item in widget.project.checklistData!.items) {
        _toolStatus[item.toolId] = _ToolCheckinStatus(
          toolId: item.toolId,
          baseName: item.baseName,
          category: item.category,
          isReturned: returnedToolsMap[item.toolId] ?? false,
          checklistStatus: item.status, // present, broken, missing
          checklistNotes: item.notes,
        );
      }
    } else if (widget.project.toolsUsedCategorized != null) {
      // Fallback: use tools used data
      final categorized = widget.project.toolsUsedCategorized!;
      for (final tool in [
        ...categorized.teamTools,
        ...categorized.individualTools,
        ...categorized.extras,
        ...categorized.accessories
      ]) {
        for (final toolId in tool.toolIds) {
          if (toolId.isNotEmpty) {
            _toolStatus[toolId] = _ToolCheckinStatus(
              toolId: toolId,
              baseName: tool.baseName,
              category: tool.category,
              isReturned: returnedToolsMap[toolId] ?? false,
              checklistStatus: 'present',
              checklistNotes: '',
            );
          }
        }
      }
    }
  }

  void _handleBarcodeScan(String code) {
    final inventoryProvider = context.read<InventoryProvider>();

    // Find the tool in inventory by QR code or tool ID
    try {
      final tool = inventoryProvider.tools.firstWhere(
        (t) => t.qrCode == code || t.toolId == code,
      );

      // Check if tool is in the check-in list
      if (!_toolStatus.containsKey(tool.id)) {
        _scannerKey.currentState?.showErrorFeedback();
        _showScanError('❌ Not in check-in list: ${tool.name}');
        return;
      }

      // Check if already returned
      if (_toolStatus[tool.id]!.isReturned) {
        _scannerKey.currentState?.showErrorFeedback();
        _showScanError('✓ Already checked in: ${tool.name}');
        return;
      }

      // Mark as returned
      setState(() {
        _toolStatus[tool.id]!.isReturned = true;
        _hasUnsavedChanges = true;
      });

      // Show success feedback
      _scannerKey.currentState?.showSuccessFeedback();
      _showScanSuccess('✅ Checked in: ${tool.name}');
    } catch (e) {
      // Tool not found
      _scannerKey.currentState?.showErrorFeedback();
      _showScanError('❓ Tool not found: $code');
    }
  }

  void _showScanSuccess(String message) {
    // Play success sound
    SoundService().playSuccess();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.green,
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
      ),
    );
  }

  void _showScanError(String message) {
    // Play warning sound
    SoundService().playWarning();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.red,
        duration: const Duration(milliseconds: 2000),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
      ),
    );
  }

  String _getReadableToolId(String firestoreId, List<InventoryTool> tools) {
    try {
      final tool = tools.firstWhere((t) => t.id == firestoreId);
      return tool.toolId;
    } catch (e) {
      return firestoreId; // Fallback
    }
  }

  // Get accessories for a parent tool
  List<InventoryTool> _getAccessoriesForTool(
      String toolId, List<InventoryTool> allTools) {
    try {
      final tool = allTools.firstWhere((t) => t.id == toolId);
      return allTools.where((t) => tool.accessoryIds.contains(t.id)).toList();
    } catch (e) {
      return [];
    }
  }

  // Get status of a tool in checkin
  _ToolCheckinStatus? _getToolReturnStatus(String toolId) {
    return _toolStatus[toolId];
  }

  int _getTotalTools() => _toolStatus.length;

  int _getReturnedCount() =>
      _toolStatus.values.where((s) => s.isReturned).length;

  bool _areAllToolsReturned() =>
      _toolStatus.values.every((status) => status.isReturned);

  Future<void> _saveProgress() async {
    setState(() => _isChecking = true);

    try {
      final checkinData = _buildCheckinData(isCompleted: false);
      final jobProvider = context.read<HappySunProjectProvider>();

      await jobProvider.performCheckin(
        projectId: widget.project.id,
        checkin: checkinData,
      );

      setState(() {
        _hasUnsavedChanges = false;
        _isChecking = false;
      });

      // Play success sound
      SoundService().playSuccess();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Progress saved'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _isChecking = false);

      // Play warning sound
      SoundService().playWarning();

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

  Future<void> _completeCheckin() async {
    if (!_areAllToolsReturned()) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Incomplete Check-in'),
          content: Text(
            'Not all tools have been checked in.\n\n'
            'Returned: ${_getReturnedCount()} / ${_getTotalTools()}\n\n'
            'Do you want to continue anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
              ),
              child: const Text('Continue Anyway'),
            ),
          ],
        ),
      );

      if (confirm != true) return;
    }

    setState(() => _isChecking = true);

    try {
      final checkinData = _buildCheckinData(isCompleted: true);
      final jobProvider = context.read<HappySunProjectProvider>();
      final inventoryProvider = context.read<InventoryProvider>();

      // Get all tool IDs that were returned
      final returnedToolIds = _toolStatus.entries
          .where((entry) => entry.value.isReturned)
          .map((entry) => entry.key)
          .toList();

      // Save check-in data
      await jobProvider.performCheckin(
        projectId: widget.project.id,
        checkin: checkinData,
      );

      // Record end time for the job
      await jobProvider.updateEndTime(
        widget.project.id,
        DateTime.now(),
      );

      // Mark tools as available in inventory
      await inventoryProvider.checkInTools(returnedToolIds);

      // Play success sound
      SoundService().playSuccess();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Check-in completed successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isChecking = false);

      // Play warning sound
      SoundService().playWarning();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error completing check-in: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  ProjectCheckin _buildCheckinData({required bool isCompleted}) {
    // Get returned tools
    final returnedToolIds = _toolStatus.entries
        .where((entry) => entry.value.isReturned)
        .map((entry) => entry.key)
        .toList();

    // Get missing tools
    final missingToolIds = _toolStatus.entries
        .where((entry) => !entry.value.isReturned)
        .map((entry) => entry.key)
        .toList();

    // Convert tool statuses to CheckedOutTool format
    final returnedTools = returnedToolIds.map((toolId) {
      final status = _toolStatus[toolId]!;
      return CheckedOutTool(
        toolId: toolId,
        toolName: status.baseName,
        category: status.category,
        quantity: 1,
      );
    }).toList();

    return ProjectCheckin(
      checkinTime: DateTime.now(),
      returnedTools: returnedTools,
      missingTools: missingToolIds,
      notes: null,
      checkedInBy: 'Current User', // TODO: Get from auth
      isCompleted: isCompleted,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCompleted = widget.project.checkin?.isCompleted == true;

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
          title: Text(
            isCompleted ? 'Check-in (Completed)' : 'Check-in Tools',
            style: const TextStyle(fontSize: 16),
          ),
          backgroundColor: isCompleted ? Colors.green : Colors.purple,
          foregroundColor: Colors.white,
          bottom: !isCompleted
              ? TabBar(
                  controller: _tabController,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  indicatorColor: Colors.white,
                  tabs: const [
                    Tab(
                      icon: Icon(Icons.qr_code_scanner, size: 20),
                      text: 'Scan',
                      height: 48,
                    ),
                    Tab(
                      icon: Icon(Icons.assignment_return, size: 20),
                      text: 'Check-in',
                      height: 48,
                    ),
                  ],
                )
              : null,
          actions: [
            if (isCompleted)
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.check_circle, color: Colors.green, size: 16),
                        SizedBox(width: 4),
                        Text(
                          'Completed',
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else if (_hasUnsavedChanges)
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
                        color: Colors.purple,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: SafeArea(
          child: isCompleted
              ? Column(
                  children: [
                    Expanded(child: _buildCheckinTab()),
                    _buildBottomActions(),
                  ],
                )
              : Column(
                  children: [
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildScanTab(),
                          _buildCheckinTab(),
                        ],
                      ),
                    ),
                    _buildBottomActions(),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildScanTab() {
    return Consumer<InventoryProvider>(
      builder: (context, inventoryProvider, child) {
        final isScanning = _scannerKey.currentState?.isScanning ?? false;
        return SingleChildScrollView(
          child: Column(
            children: [
              // Scanner widget
              HappySunQRScannerWidget(
                key: _scannerKey,
                onScan: _handleBarcodeScan,
                instructionText: 'Scan tool QR code or ID',
                autoStart: false,
              ),
              // Scanner controls
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isScanning)
                      ElevatedButton.icon(
                        onPressed: () {
                          _scannerKey.currentState?.stopScanning();
                          setState(() {});
                        },
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text(
                          'Stop',
                          style: TextStyle(fontSize: 13),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                      )
                    else
                      ElevatedButton.icon(
                        onPressed: () {
                          _scannerKey.currentState?.startScanning();
                          setState(() {});
                        },
                        icon: const Icon(Icons.qr_code_scanner, size: 18),
                        label: const Text(
                          'Start Scanning',
                          style: TextStyle(fontSize: 13),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purple,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCheckinTab() {
    return Column(
      children: [
        // Check-in details banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.purple.shade700, Colors.purple.shade500],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.assignment_return,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Tool Check-in',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      widget.project.jobType == 'windowCleaning'
                          ? 'Window Cleaning Job'
                          : 'Solar Panel Cleaning Job',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              _buildCompactInfoTile(
                Icons.build_circle,
                _getTotalTools().toString(),
              ),
              const SizedBox(width: 8),
              _buildCompactInfoTile(
                Icons.calendar_today,
                '${widget.project.scheduledDate.day}/${widget.project.scheduledDate.month}',
              ),
            ],
          ),
        ),
        // Status banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.purple.shade50,
            border: Border(
              bottom: BorderSide(color: Colors.purple.shade200),
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.inventory_2, color: Colors.purple),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Check in tools returned from site',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Mark each tool as returned to make it available',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildStatusChip(
                      'Returned', _getReturnedCount(), Colors.green),
                  const SizedBox(width: 8),
                  _buildStatusChip(
                    'Remaining',
                    _getTotalTools() - _getReturnedCount(),
                    Colors.orange,
                  ),
                ],
              ),
            ],
          ),
        ),
        // Tools list
        Expanded(
          child: Consumer<InventoryProvider>(
            builder: (context, inventoryProvider, child) {
              final tools = inventoryProvider.tools;

              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _toolStatus.length,
                itemBuilder: (context, index) {
                  final entry = _toolStatus.entries.elementAt(index);
                  final toolId = entry.key;
                  final status = entry.value;

                  return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            status.isReturned = !status.isReturned;
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 30,
                                height: 30,
                                child: Checkbox(
                                  value: status.isReturned,
                                  onChanged: (value) {
                                    setState(() {
                                      status.isReturned = value ?? false;
                                    });
                                  },
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            status.baseName,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        if (status.checklistStatus != 'present')
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: status.checklistStatus ==
                                                      'broken'
                                                  ? Colors.orange.shade100
                                                  : Colors.red.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                            child: Text(
                                              status.checklistStatus
                                                  .toUpperCase(),
                                              style: TextStyle(
                                                fontSize: 8,
                                                fontWeight: FontWeight.bold,
                                                color: status.checklistStatus ==
                                                        'broken'
                                                    ? Colors.orange.shade700
                                                    : Colors.red.shade700,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'ID: ${_getReadableToolId(toolId, tools)} • ${status.category}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                    if (status.checklistNotes.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.shade50,
                                          borderRadius:
                                              BorderRadius.circular(3),
                                          border: Border.all(
                                              color: Colors.blue.shade200),
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Icon(
                                              Icons.note,
                                              size: 12,
                                              color: Colors.blue.shade700,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                status.checklistNotes,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.blue.shade700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],

                                    // Show required accessories
                                    ...(() {
                                      final accessories =
                                          _getAccessoriesForTool(toolId, tools);
                                      if (accessories.isEmpty) {
                                        return <Widget>[];
                                      }

                                      return [
                                        const SizedBox(height: 10),
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Colors.orange.shade50,
                                            borderRadius:
                                                BorderRadius.circular(6),
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
                                                      size: 12,
                                                      color: Colors
                                                          .orange.shade700),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    'Required accessories:',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors
                                                          .orange.shade700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Wrap(
                                                spacing: 6,
                                                runSpacing: 6,
                                                children: accessories
                                                    .map((accessory) {
                                                  final accessoryStatus =
                                                      _getToolReturnStatus(
                                                          accessory.id);
                                                  final isReturned =
                                                      accessoryStatus
                                                              ?.isReturned ??
                                                          false;

                                                  return Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 6,
                                                        vertical: 3),
                                                    decoration: BoxDecoration(
                                                      color: isReturned
                                                          ? Colors
                                                              .green.shade100
                                                          : Colors.white,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              10),
                                                      border: Border.all(
                                                        color: isReturned
                                                            ? Colors.green
                                                            : Colors.orange
                                                                .shade300,
                                                        width: 1.5,
                                                      ),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          isReturned
                                                              ? Icons
                                                                  .check_circle
                                                              : Icons
                                                                  .radio_button_unchecked,
                                                          size: 10,
                                                          color: isReturned
                                                              ? Colors.green
                                                              : Colors.orange,
                                                        ),
                                                        const SizedBox(
                                                            width: 4),
                                                        Text(
                                                          accessory.toolId,
                                                          style: TextStyle(
                                                            fontSize: 9,
                                                            color: isReturned
                                                                ? Colors.green
                                                                    .shade700
                                                                : Colors.orange
                                                                    .shade700,
                                                            fontWeight:
                                                                FontWeight.w500,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }).toList(),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ];
                                    })(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ));
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCompactInfoTile(IconData icon, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              count.toString(),
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions() {
    final isCompleted = widget.project.endTime != null;
    final allReturned = _areAllToolsReturned();
    final progress =
        _getTotalTools() > 0 ? _getReturnedCount() / _getTotalTools() : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCompleted) ...[
            // View Details button when completed
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _showCheckinDetails,
                icon: const Icon(Icons.info_outline, size: 18),
                label: const Text('View Check-in Details',
                    style: TextStyle(fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ] else ...[
            // Progress bar
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Progress: ${_getReturnedCount()} / ${_getTotalTools()} tools returned',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          allReturned ? Colors.green : Colors.purple,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _hasUnsavedChanges && !_isChecking
                        ? _saveProgress
                        : null,
                    icon: _isChecking
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save, size: 16),
                    label: const Text('Save Progress',
                        style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed:
                        allReturned && !_isChecking ? _completeCheckin : null,
                    icon: const Icon(Icons.check_circle, size: 16),
                    label:
                        const Text('Complete', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _showCheckinDetails() {
    final isMobile = MediaQuery.of(context).size.width < 600;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: isMobile
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: Container(
          width: isMobile ? double.infinity : 600,
          height: isMobile ? double.infinity : null,
          constraints: isMobile ? null : const BoxConstraints(maxHeight: 700),
          child: Column(
            mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: EdgeInsets.all(isMobile ? 12 : 20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.green.shade700, Colors.green.shade500],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Colors.white,
                      size: isMobile ? 20 : 32,
                    ),
                    SizedBox(width: isMobile ? 10 : 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Check-in Completed',
                            style: TextStyle(
                              fontSize: isMobile ? 14 : 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          if (isMobile)
                            const SizedBox(height: 2)
                          else
                            const SizedBox(height: 4),
                          if (widget.project.endTime != null)
                            Text(
                              'Completed at ${widget.project.endTime!.hour.toString().padLeft(2, '0')}:${widget.project.endTime!.minute.toString().padLeft(2, '0')} on ${widget.project.scheduledDate.day}/${widget.project.scheduledDate.month}/${widget.project.scheduledDate.year}',
                              style: TextStyle(
                                fontSize: isMobile ? 9 : 12,
                                color: Colors.white70,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close,
                          color: Colors.white, size: isMobile ? 20 : 24),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              // Summary
              Container(
                padding: EdgeInsets.all(isMobile ? 10 : 16),
                color: Colors.green.shade50,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildSummaryTile(
                      'Total Tools',
                      _getTotalTools().toString(),
                      Icons.build_circle,
                      Colors.green,
                      isMobile,
                    ),
                    _buildSummaryTile(
                      'Returned',
                      _getReturnedCount().toString(),
                      Icons.check_circle,
                      Colors.green,
                      isMobile,
                    ),
                    if (widget.project.workDuration != null)
                      _buildSummaryTile(
                        'Duration',
                        '${widget.project.workDuration!.inHours}h ${widget.project.workDuration!.inMinutes.remainder(60)}m',
                        Icons.timer,
                        Colors.green,
                        isMobile,
                      ),
                  ],
                ),
              ),
              // Tools list
              Expanded(
                child: Consumer<InventoryProvider>(
                  builder: (context, inventoryProvider, child) {
                    final tools = inventoryProvider.tools;

                    return ListView.builder(
                      padding: EdgeInsets.all(isMobile ? 10 : 16),
                      itemCount: _toolStatus.length,
                      itemBuilder: (context, index) {
                        final entry = _toolStatus.entries.elementAt(index);
                        final toolId = entry.key;
                        final status = entry.value;

                        return Card(
                          margin: EdgeInsets.only(bottom: isMobile ? 8 : 12),
                          child: Padding(
                            padding: EdgeInsets.all(isMobile ? 10 : 16),
                            child: Row(
                              children: [
                                Icon(
                                  status.isReturned
                                      ? Icons.check_circle
                                      : Icons.cancel,
                                  color: status.isReturned
                                      ? Colors.green
                                      : Colors.red,
                                  size: isMobile ? 18 : 24,
                                ),
                                SizedBox(width: isMobile ? 8 : 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              status.baseName,
                                              style: TextStyle(
                                                fontSize: isMobile ? 11 : 14,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          if (status.checklistStatus !=
                                              'present')
                                            Container(
                                              padding: EdgeInsets.symmetric(
                                                  horizontal: isMobile ? 5 : 8,
                                                  vertical: isMobile ? 2 : 4),
                                              decoration: BoxDecoration(
                                                color: status.checklistStatus ==
                                                        'broken'
                                                    ? Colors.orange.shade100
                                                    : Colors.red.shade100,
                                                borderRadius:
                                                    BorderRadius.circular(
                                                        isMobile ? 8 : 12),
                                              ),
                                              child: Text(
                                                status.checklistStatus
                                                    .toUpperCase(),
                                                style: TextStyle(
                                                  fontSize: isMobile ? 7 : 10,
                                                  fontWeight: FontWeight.bold,
                                                  color:
                                                      status.checklistStatus ==
                                                              'broken'
                                                          ? Colors
                                                              .orange.shade700
                                                          : Colors.red.shade700,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      SizedBox(height: isMobile ? 2 : 4),
                                      Text(
                                        'ID: ${_getReadableToolId(toolId, tools)} • ${status.category}',
                                        style: TextStyle(
                                          fontSize: isMobile ? 9 : 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      if (status.checklistNotes.isNotEmpty) ...[
                                        SizedBox(height: isMobile ? 5 : 8),
                                        Container(
                                          padding:
                                              EdgeInsets.all(isMobile ? 5 : 8),
                                          decoration: BoxDecoration(
                                            color: Colors.blue.shade50,
                                            borderRadius:
                                                BorderRadius.circular(3),
                                            border: Border.all(
                                                color: Colors.blue.shade200),
                                          ),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Icon(
                                                Icons.note,
                                                size: isMobile ? 11 : 14,
                                                color: Colors.blue.shade700,
                                              ),
                                              SizedBox(width: isMobile ? 3 : 4),
                                              Expanded(
                                                child: Text(
                                                  status.checklistNotes,
                                                  style: TextStyle(
                                                    fontSize: isMobile ? 9 : 11,
                                                    color: Colors.blue.shade700,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryTile(
      String label, String value, IconData icon, Color color,
      [bool isMobile = false]) {
    return Column(
      children: [
        Icon(icon, color: color, size: isMobile ? 20 : 28),
        SizedBox(height: isMobile ? 4 : 8),
        Text(
          value,
          style: TextStyle(
            fontSize: isMobile ? 14 : 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        SizedBox(height: isMobile ? 2 : 4),
        Text(
          label,
          style: TextStyle(
            fontSize: isMobile ? 9 : 12,
            color: Colors.grey.shade700,
          ),
        ),
      ],
    );
  }
}

class _ToolCheckinStatus {
  final String toolId;
  final String baseName;
  final String category;
  bool isReturned;
  final String checklistStatus; // present, broken, missing
  final String checklistNotes;

  _ToolCheckinStatus({
    required this.toolId,
    required this.baseName,
    required this.category,
    required this.isReturned,
    required this.checklistStatus,
    required this.checklistNotes,
  });
}
