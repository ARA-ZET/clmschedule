import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/happy_sun_job.dart';
import '../models/inventory_tool.dart';
import '../providers/happy_sun_job_provider.dart';
import '../providers/inventory_provider.dart';

class HappySunCheckinScreen extends StatefulWidget {
  final HappySunJob job;

  const HappySunCheckinScreen({
    super.key,
    required this.job,
  });

  @override
  State<HappySunCheckinScreen> createState() => _HappySunCheckinScreenState();
}

class _HappySunCheckinScreenState extends State<HappySunCheckinScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  MobileScannerController? _scannerController;
  bool _isScanning = false;

  final Map<String, _ToolCheckinStatus> _toolStatus = {}; // toolId -> status
  bool _isChecking = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initializeToolStatus();

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

  @override
  void dispose() {
    _tabController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  void _initializeToolStatus() {
    // Use checklist data if available
    if (widget.job.checklistData != null) {
      for (final item in widget.job.checklistData!.items) {
        _toolStatus[item.toolId] = _ToolCheckinStatus(
          toolId: item.toolId,
          baseName: item.baseName,
          category: item.category,
          isReturned: false,
          checklistStatus: item.status, // present, broken, missing
          checklistNotes: item.notes,
        );
      }
    } else if (widget.job.toolsUsedCategorized != null) {
      // Fallback: use tools used data
      final categorized = widget.job.toolsUsedCategorized!;
      for (final tool in [
        ...categorized.teamTools,
        ...categorized.individualTools,
        ...categorized.extras
      ]) {
        for (final toolId in tool.toolIds) {
          if (toolId.isNotEmpty) {
            _toolStatus[toolId] = _ToolCheckinStatus(
              toolId: toolId,
              baseName: tool.baseName,
              category: tool.category,
              isReturned: false,
              checklistStatus: 'present',
              checklistNotes: '',
            );
          }
        }
      }
    }
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

        // Check if tool is in the check-in list
        if (!_toolStatus.containsKey(tool.id)) {
          _showScanError('This tool is not in the check-in list');
          continue;
        }

        // Check if already returned
        if (_toolStatus[tool.id]!.isReturned) {
          _showScanError('Tool already checked in: ${tool.name}');
          continue;
        }

        // Mark as returned
        setState(() {
          _toolStatus[tool.id]!.isReturned = true;
        });

        // Show success feedback
        _showScanSuccess('Checked in: ${tool.name}');
      } catch (e) {
        // Tool not found
        _showScanError('Tool not found or not in list: $code');
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
      final jobProvider = context.read<HappySunJobProvider>();
      final inventoryProvider = context.read<InventoryProvider>();

      // Get all tool IDs that were returned
      final returnedToolIds = _toolStatus.entries
          .where((entry) => entry.value.isReturned)
          .map((entry) => entry.key)
          .toList();

      // Record end time for the job
      await jobProvider.recordEndTime(
        widget.job.id,
        widget.job.date,
        DateTime.now(),
      );

      // Mark tools as available in inventory
      await inventoryProvider.checkInTools(returnedToolIds);

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

  @override
  Widget build(BuildContext context) {
    final isCompleted = widget.job.endTime != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isCompleted ? 'Check-in (Completed)' : 'Check-in Tools'),
        backgroundColor: isCompleted ? Colors.green : Colors.purple,
        foregroundColor: Colors.white,
        bottom: !isCompleted
            ? TabBar(
                controller: _tabController,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: const [
                  Tab(icon: Icon(Icons.qr_code_scanner), text: 'Scan'),
                  Tab(icon: Icon(Icons.assignment_return), text: 'Check-in'),
                ],
              )
            : null,
        actions: isCompleted
            ? [
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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.check_circle,
                              color: Colors.green, size: 16),
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
                ),
              ]
            : null,
      ),
      body: isCompleted
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
                              ),
                            ),
                            // Instructions
                            Positioned(
                              top: 50,
                              left: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 20),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.7),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  'Scan tool QR code or ID',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : const Center(
                          child: CircularProgressIndicator(
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
            ),
            // Scanner controls
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isScanning)
                    ElevatedButton.icon(
                      onPressed: _stopScanning,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop Scanning'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                      ),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: _startScanning,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Start Scanning'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCheckinTab() {
    return Column(
      children: [
        // Check-in details banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.purple.shade700, Colors.purple.shade500],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.assignment_return,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Tool Check-in',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.job.jobType == 'windowCleaning'
                              ? 'Window Cleaning Job'
                              : 'Solar Panel Cleaning Job',
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(color: Colors.white24, height: 1),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildInfoTile(
                      'Total Tools',
                      _getTotalTools().toString(),
                      Icons.build_circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildInfoTile(
                      'Date',
                      '${widget.job.date.day}/${widget.job.date.month}/${widget.job.date.year}',
                      Icons.calendar_today,
                    ),
                  ),
                ],
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
                padding: const EdgeInsets.all(16),
                itemCount: _toolStatus.length,
                itemBuilder: (context, index) {
                  final entry = _toolStatus.entries.elementAt(index);
                  final toolId = entry.key;
                  final status = entry.value;

                  return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            status.isReturned = !status.isReturned;
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Checkbox(
                                value: status.isReturned,
                                onChanged: (value) {
                                  setState(() {
                                    status.isReturned = value ?? false;
                                  });
                                },
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
                                            status.baseName,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        if (status.checklistStatus != 'present')
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: status.checklistStatus ==
                                                      'broken'
                                                  ? Colors.orange.shade100
                                                  : Colors.red.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              status.checklistStatus
                                                  .toUpperCase(),
                                              style: TextStyle(
                                                fontSize: 10,
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
                                    const SizedBox(height: 4),
                                    Text(
                                      'ID: ${_getReadableToolId(toolId, tools)} • ${status.category}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                    if (status.checklistNotes.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.shade50,
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          border: Border.all(
                                              color: Colors.blue.shade200),
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Icon(
                                              Icons.note,
                                              size: 14,
                                              color: Colors.blue.shade700,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                status.checklistNotes,
                                                style: TextStyle(
                                                  fontSize: 11,
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

  Widget _buildInfoTile(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              count.toString(),
              style: const TextStyle(
                fontSize: 10,
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
    final isCompleted = widget.job.endTime != null;
    final allReturned = _areAllToolsReturned();
    final progress =
        _getTotalTools() > 0 ? _getReturnedCount() / _getTotalTools() : 0.0;

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCompleted) ...[
            // View Details button when completed
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _showCheckinDetails,
                icon: const Icon(Icons.info_outline),
                label: const Text('View Check-in Details'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
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
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
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
            const SizedBox(height: 16),
            // Complete button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: !_isChecking ? _completeCheckin : null,
                icon: _isChecking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle),
                label:
                    Text(_isChecking ? 'Checking in...' : 'Complete Check-in'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showCheckinDetails() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        child: Container(
          width: 600,
          constraints: const BoxConstraints(maxHeight: 700),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.green.shade700, Colors.green.shade500],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: Colors.white,
                      size: 32,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Check-in Completed',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (widget.job.endTime != null)
                            Text(
                              'Completed at ${widget.job.endTime!.hour.toString().padLeft(2, '0')}:${widget.job.endTime!.minute.toString().padLeft(2, '0')} on ${widget.job.date.day}/${widget.job.date.month}/${widget.job.date.year}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              // Summary
              Container(
                padding: const EdgeInsets.all(16),
                color: Colors.green.shade50,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildSummaryTile(
                      'Total Tools',
                      _getTotalTools().toString(),
                      Icons.build_circle,
                      Colors.green,
                    ),
                    _buildSummaryTile(
                      'Returned',
                      _getReturnedCount().toString(),
                      Icons.check_circle,
                      Colors.green,
                    ),
                    if (widget.job.workDuration != null)
                      _buildSummaryTile(
                        'Duration',
                        '${widget.job.workDuration!.inHours}h ${widget.job.workDuration!.inMinutes.remainder(60)}m',
                        Icons.timer,
                        Colors.green,
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
                      padding: const EdgeInsets.all(16),
                      itemCount: _toolStatus.length,
                      itemBuilder: (context, index) {
                        final entry = _toolStatus.entries.elementAt(index);
                        final toolId = entry.key;
                        final status = entry.value;

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(
                                  status.isReturned
                                      ? Icons.check_circle
                                      : Icons.cancel,
                                  color: status.isReturned
                                      ? Colors.green
                                      : Colors.red,
                                  size: 24,
                                ),
                                const SizedBox(width: 12),
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
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          if (status.checklistStatus !=
                                              'present')
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 4),
                                              decoration: BoxDecoration(
                                                color: status.checklistStatus ==
                                                        'broken'
                                                    ? Colors.orange.shade100
                                                    : Colors.red.shade100,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Text(
                                                status.checklistStatus
                                                    .toUpperCase(),
                                                style: TextStyle(
                                                  fontSize: 10,
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
                                      const SizedBox(height: 4),
                                      Text(
                                        'ID: ${_getReadableToolId(toolId, tools)} • ${status.category}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      if (status.checklistNotes.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Colors.blue.shade50,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            border: Border.all(
                                                color: Colors.blue.shade200),
                                          ),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Icon(
                                                Icons.note,
                                                size: 14,
                                                color: Colors.blue.shade700,
                                              ),
                                              const SizedBox(width: 4),
                                              Expanded(
                                                child: Text(
                                                  status.checklistNotes,
                                                  style: TextStyle(
                                                    fontSize: 11,
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
      String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
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
