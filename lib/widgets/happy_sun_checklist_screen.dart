import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_shared.dart';
import '../models/happy_sun_project.dart';
import '../models/inventory_tool.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/inventory_provider.dart';
import 'happy_sun_qr_scanner_widget.dart';

class HappySunChecklistScreen extends StatefulWidget {
  final HappySunProject project;

  const HappySunChecklistScreen({
    super.key,
    required this.project,
  });

  @override
  State<HappySunChecklistScreen> createState() =>
      _HappySunChecklistScreenState();
}

class _HappySunChecklistScreenState extends State<HappySunChecklistScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final GlobalKey<HappySunQRScannerWidgetState> _scannerKey = GlobalKey();

  // Track tool verification status
  final Map<String, _ToolCheckStatus> _toolStatus = {}; // toolId -> status
  bool _isSaving = false;
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
    if (widget.project.toolsUsedCategorized == null) return;

    final categorized = widget.project.toolsUsedCategorized!;

    // Check if we have existing checklist data
    final existingChecklistData = widget.project.checklistData;
    final existingItemsMap = existingChecklistData != null
        ? {for (var item in existingChecklistData.items) item.toolId: item}
        : <String, ToolChecklistItem>{};

    // Initialize status for all tools taken
    for (final tool in [
      ...categorized.teamTools,
      ...categorized.individualTools,
      ...categorized.extras,
      ...categorized.accessories
    ]) {
      for (final toolId in tool.toolIds) {
        if (toolId.isNotEmpty) {
          // Load existing data if available
          final existingItem = existingItemsMap[toolId];
          _toolStatus[toolId] = _ToolCheckStatus(
            toolId: toolId,
            baseName: tool.baseName,
            category: tool.category,
            isVerified: existingItem?.isVerified ?? false,
            status: existingItem?.status ?? 'present',
            notes: existingItem?.notes ?? '',
          );
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

      // Check if tool is in the checklist
      if (!_toolStatus.containsKey(tool.id)) {
        _showScanError('This tool is not in the checklist');
        return;
      }

      // Check if already verified
      if (_toolStatus[tool.id]!.isVerified) {
        _showScanError('Tool already verified: ${tool.name}');
        return;
      }

      // Mark as verified
      setState(() {
        _toolStatus[tool.id] = _toolStatus[tool.id]!.copyWith(
          isVerified: true,
          status: 'present',
        );
        _hasUnsavedChanges = true;
      });

      // Show success feedback
      _showScanSuccess('Verified: ${tool.name}');
    } catch (e) {
      // Tool not found
      _showScanError('Tool not found or not in checklist: $code');
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

  bool _areAllToolsChecked() {
    return _toolStatus.values.every((status) => status.isVerified);
  }

  int _getTotalTools() => _toolStatus.length;

  int _getVerifiedCount() =>
      _toolStatus.values.where((s) => s.isVerified).length;

  int _getBrokenCount() =>
      _toolStatus.values.where((s) => s.status == 'broken').length;

  int _getMissingCount() =>
      _toolStatus.values.where((s) => s.status == 'missing').length;

  Future<void> _saveProgress() async {
    setState(() => _isSaving = true);

    try {
      final checklistData = _buildChecklistData();
      final jobProvider = context.read<HappySunProjectProvider>();

      await jobProvider.updateChecklistData(
        widget.project.id,
        checklistData,
      );

      setState(() {
        _hasUnsavedChanges = false;
        _isSaving = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Checklist saved'),
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

  Future<void> _completeChecklist() async {
    if (!_areAllToolsChecked()) return;

    // Check if there are missing or broken tools
    final hasBroken = _getBrokenCount() > 0;
    final hasMissing = _getMissingCount() > 0;
    final brokenCount = _getBrokenCount();
    final missingCount = _getMissingCount();

    if (hasBroken || hasMissing) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Complete Checklist?'),
          content: Text(
            'You have marked some tools as:\n'
            '${hasBroken ? '• Broken: $brokenCount\n' : ''}'
            '${hasMissing ? '• Missing: $missingCount\n' : ''}'
            '\nDo you want to complete the checklist?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Review'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
              ),
              child: const Text('Complete Anyway'),
            ),
          ],
        ),
      );

      if (confirm != true) return;
    }

    setState(() => _isSaving = true);

    try {
      final checklistData = _buildChecklistData();
      final jobProvider = context.read<HappySunProjectProvider>();

      await jobProvider.updateChecklistData(
        widget.project.id,
        checklistData,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Checklist completed successfully!'),
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
            content: Text('Error completing checklist: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  ChecklistData _buildChecklistData() {
    final items = _toolStatus.values
        .map((status) => ToolChecklistItem(
              toolId: status.toolId,
              baseName: status.baseName,
              category: status.category,
              status: status.status,
              notes: status.notes,
              isVerified: status.isVerified,
            ))
        .toList();

    return ChecklistData(
      items: items,
      completedAt: DateTime.now(),
      completedBy: 'Current User', // TODO: Get from auth provider
      totalTools: _getTotalTools(),
      verifiedCount: _getVerifiedCount(),
      brokenCount: _getBrokenCount(),
      missingCount: _getMissingCount(),
      summary: _buildChecklistSummary(),
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

  // Get status of a tool in checklist
  _ToolCheckStatus? _getToolStatus(String toolId) {
    try {
      return _toolStatus.values.firstWhere((t) => t.toolId == toolId);
    } catch (e) {
      return null;
    }
  }

  String _buildChecklistSummary() {
    final buffer = StringBuffer();
    buffer.writeln('=== CHECKLIST SUMMARY ===');
    buffer.writeln('Verified: $_getVerifiedCount() / $_getTotalTools()');
    buffer.writeln('Broken: $_getBrokenCount()');
    buffer.writeln('Missing: $_getMissingCount()');
    buffer.writeln('\n=== TOOL STATUS ===');

    for (final entry in _toolStatus.entries) {
      final status = entry.value;
      buffer.writeln('\n${status.baseName} (${entry.key}):');
      buffer.writeln('  Status: ${status.status}');
      if (status.notes.isNotEmpty) {
        buffer.writeln('  Notes: ${status.notes}');
      }
    }

    return buffer.toString();
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
          title: Text(widget.project.checklistData != null
              ? 'Checklist (Completed)'
              : 'Pre-Departure Checklist'),
          backgroundColor:
              widget.project.checklistData != null ? Colors.green : Colors.blue,
          foregroundColor: Colors.white,
          bottom: widget.project.checklistData == null
              ? TabBar(
                  controller: _tabController,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  indicatorColor: Colors.white,
                  tabs: const [
                    Tab(icon: Icon(Icons.qr_code_scanner), text: 'Scan'),
                    Tab(icon: Icon(Icons.checklist), text: 'Checklist'),
                  ],
                )
              : null,
          actions: [
            if (widget.project.checklistData != null)
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
                      children: [
                        Icon(Icons.check_circle, color: Colors.green, size: 16),
                        const SizedBox(width: 4),
                        const Text(
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
                        color: Colors.blue,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: widget.project.checklistData != null
            ? Column(
                children: [
                  Expanded(child: _buildChecklistTab()),
                  _buildBottomActions(),
                ],
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  // Calculate available height for TabBarView (subtract approximate bottom actions height)
                  final tabViewHeight = constraints.maxHeight - 120;

                  return Column(
                    children: [
                      SizedBox(
                        height: tabViewHeight,
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _buildScanTab(),
                            _buildChecklistTab(),
                          ],
                        ),
                      ),
                      _buildBottomActions(),
                    ],
                  );
                },
              ),
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
              instructionText: 'Scan tool QR code or ID',
              autoStart: false,
            ),
          ],
        );
      },
    );
  }

  Widget _buildChecklistTab() {
    return Column(
      children: [
        // Completion banner if already completed
        if (widget.project.checklistData != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              border: Border(
                bottom: BorderSide(color: Colors.green.shade200, width: 2),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Checklist Completed',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Completed on ${_formatDateTime(widget.project.checklistData!.completedAt)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        // Checklist details banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.project.checklistData != null
                  ? [Colors.green.shade700, Colors.green.shade500]
                  : [Colors.blue.shade700, Colors.blue.shade500],
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
                  Icons.assignment_turned_in,
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
                      'Pre-Departure Checklist',
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
                'Total Tools',
                _getTotalTools().toString(),
                Icons.build_circle,
              ),
              const SizedBox(width: 8),
              _buildCompactInfoTile(
                'Date',
                '${widget.project.scheduledDate.day}/${widget.project.scheduledDate.month}/${widget.project.scheduledDate.year}',
                Icons.calendar_today,
              ),
            ],
          ),
        ),
        // Status banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            border: Border(
              bottom: BorderSide(color: Colors.blue.shade200),
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.checklist, color: Colors.blue, size: 16),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Verify all tools before leaving',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _buildStatusChip(
                      'Verified', _getVerifiedCount(), Colors.green),
                  const SizedBox(width: 6),
                  _buildStatusChip('Remaining',
                      _getTotalTools() - _getVerifiedCount(), Colors.grey),
                  if (_getBrokenCount() > 0) ...[
                    const SizedBox(width: 6),
                    _buildStatusChip(
                        'Broken', _getBrokenCount(), Colors.orange),
                  ],
                  if (_getMissingCount() > 0) ...[
                    const SizedBox(width: 6),
                    _buildStatusChip('Missing', _getMissingCount(), Colors.red),
                  ],
                ],
              ),
            ],
          ),
        ),
        // Tools list
        Expanded(
          child: _buildToolsList(),
        ),
      ],
    );
  }

  Widget _buildStatusChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(width: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
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

  Widget _buildToolsList() {
    if (_toolStatus.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24.0),
        child: Center(
          child: Text('No tools to verify'),
        ),
      );
    }

    // Group by base name
    final groupedTools = <String, List<_ToolCheckStatus>>{};
    for (final status in _toolStatus.values) {
      groupedTools.putIfAbsent(status.baseName, () => []).add(status);
    }

    final sortedGroups = groupedTools.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Consumer<InventoryProvider>(
      builder: (context, inventoryProvider, child) {
        final inventoryTools = inventoryProvider.tools;

        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: sortedGroups.length,
          itemBuilder: (context, index) {
            final entry = sortedGroups[index];
            final baseName = entry.key;
            final tools = entry.value;
            final allVerified = tools.every((t) => t.isVerified);
            final anyBroken = tools.any((t) => t.status == 'broken');
            final anyMissing = tools.any((t) => t.status == 'missing');

            Color borderColor = Colors.grey.shade300;
            if (allVerified) {
              borderColor = anyBroken
                  ? Colors.orange
                  : (anyMissing ? Colors.red : Colors.green);
            }

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(color: borderColor, width: 2),
              ),
              child: ExpansionTile(
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                leading: Icon(
                  allVerified
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: borderColor,
                  size: 20,
                ),
                title: Text(
                  baseName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  '${tools.length} ${tools.length == 1 ? 'tool' : 'tools'} • ${tools.where((t) => t.isVerified).length} verified',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade600,
                  ),
                ),
                children: tools
                    .map((tool) => _buildToolItem(tool, inventoryTools))
                    .toList(),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildToolItem(
      _ToolCheckStatus toolStatus, List<InventoryTool> tools) {
    Color statusColor;
    IconData statusIcon;

    switch (toolStatus.status) {
      case 'broken':
        statusColor = Colors.orange;
        statusIcon = Icons.build;
        break;
      case 'missing':
        statusColor = Colors.red;
        statusIcon = Icons.error;
        break;
      default:
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: toolStatus.isVerified ? statusColor.withOpacity(0.05) : null,
        border: Border(
          top: BorderSide(color: Colors.grey.shade200),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: Checkbox(
                  value: toolStatus.isVerified,
                  onChanged: (value) {
                    setState(() {
                      toolStatus.isVerified = value ?? false;
                      _hasUnsavedChanges = true;
                    });
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _getReadableToolId(toolStatus.toolId, tools),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        decoration: toolStatus.isVerified
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    Text(
                      toolStatus.category,
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              // Status dropdown
              DropdownButton<String>(
                value: toolStatus.status,
                underline: Container(),
                icon: Icon(statusIcon, color: statusColor, size: 16),
                items: const [
                  DropdownMenuItem(
                      value: 'present',
                      child: Text('Present', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(
                      value: 'broken',
                      child: Text('Broken', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(
                      value: 'missing',
                      child: Text('Missing', style: TextStyle(fontSize: 12))),
                ],
                onChanged: (value) {
                  setState(() {
                    toolStatus.status = value ?? 'present';
                    _hasUnsavedChanges = true;
                  });
                },
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  toolStatus.notes.isEmpty ? Icons.note_add : Icons.note,
                  color: toolStatus.notes.isEmpty ? Colors.grey : Colors.blue,
                  size: 18,
                ),
                onPressed: () => _showNotesDialog(toolStatus),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          if (toolStatus.notes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(Icons.note, size: 12, color: Colors.blue.shade700),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      toolStatus.notes,
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
                _getAccessoriesForTool(toolStatus.toolId, tools);
            if (accessories.isEmpty) return <Widget>[];

            return [
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.extension,
                            size: 10, color: Colors.orange.shade700),
                        const SizedBox(width: 4),
                        Text(
                          'Required accessories:',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: accessories.map((accessory) {
                        final accessoryStatus = _getToolStatus(accessory.id);
                        final isVerified = accessoryStatus?.isVerified ?? false;
                        final status = accessoryStatus?.status ?? 'unknown';

                        Color color = Colors.grey;
                        IconData icon = Icons.radio_button_unchecked;

                        if (isVerified) {
                          if (status == 'broken') {
                            color = Colors.orange;
                            icon = Icons.build;
                          } else if (status == 'missing') {
                            color = Colors.red;
                            icon = Icons.error;
                          } else {
                            color = Colors.green;
                            icon = Icons.check_circle;
                          }
                        }

                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: isVerified
                                ? color.withOpacity(0.1)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: color, width: 1.5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, size: 10, color: color),
                              const SizedBox(width: 4),
                              Text(
                                accessory.toolId,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: color,
                                  fontWeight: FontWeight.w500,
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
    );
  }

  void _showNotesDialog(_ToolCheckStatus toolStatus) {
    final controller = TextEditingController(text: toolStatus.notes);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Notes for ${toolStatus.toolId}'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Notes',
            hintText: 'Add notes about this tool...',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                toolStatus.notes = controller.text;
                _hasUnsavedChanges = true;
              });
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions() {
    final allChecked = _areAllToolsChecked();
    final progress =
        _getTotalTools() > 0 ? _getVerifiedCount() / _getTotalTools() : 0.0;

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
          // Progress bar
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Progress: ${_getVerifiedCount()} / ${_getTotalTools()} tools verified',
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
                        allChecked ? Colors.green : Colors.blue,
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
                  onPressed:
                      _hasUnsavedChanges && !_isSaving ? _saveProgress : null,
                  icon: _isSaving
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
                      allChecked && !_isSaving ? _completeChecklist : null,
                  icon: const Icon(Icons.check_circle, size: 16),
                  label: const Text('Complete', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
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

  Widget _buildCompactInfoTile(String label, String value, IconData icon) {
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

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.day}/${dateTime.month}/${dateTime.year} at ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}

class _ToolCheckStatus {
  final String toolId;
  final String baseName;
  final String category;
  bool isVerified;
  String status; // present, broken, missing
  String notes;

  _ToolCheckStatus({
    required this.toolId,
    required this.baseName,
    required this.category,
    required this.isVerified,
    required this.status,
    required this.notes,
  });

  _ToolCheckStatus copyWith({
    bool? isVerified,
    String? status,
    String? notes,
  }) {
    return _ToolCheckStatus(
      toolId: toolId,
      baseName: baseName,
      category: category,
      isVerified: isVerified ?? this.isVerified,
      status: status ?? this.status,
      notes: notes ?? this.notes,
    );
  }
}
