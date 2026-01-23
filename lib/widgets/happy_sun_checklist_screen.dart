import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_job.dart';
import '../providers/happy_sun_job_provider.dart';

class HappySunChecklistScreen extends StatefulWidget {
  final HappySunJob job;

  const HappySunChecklistScreen({
    super.key,
    required this.job,
  });

  @override
  State<HappySunChecklistScreen> createState() =>
      _HappySunChecklistScreenState();
}

class _HappySunChecklistScreenState extends State<HappySunChecklistScreen> {
  // Track tool verification status
  final Map<String, _ToolCheckStatus> _toolStatus = {}; // toolId -> status
  bool _isSaving = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    _initializeToolStatus();
  }

  void _initializeToolStatus() {
    if (widget.job.toolsUsedCategorized == null) return;

    final categorized = widget.job.toolsUsedCategorized!;

    // Check if we have existing checklist data
    final existingChecklistData = widget.job.checklistData;
    final existingItemsMap = existingChecklistData != null
        ? {for (var item in existingChecklistData.items) item.toolId: item}
        : <String, ToolChecklistItem>{};

    // Initialize status for all tools taken
    for (final tool in [
      ...categorized.teamTools,
      ...categorized.individualTools,
      ...categorized.extras
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
      final jobProvider = context.read<HappySunJobProvider>();

      await jobProvider.updateChecklistData(
        widget.job.id,
        widget.job.date,
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

    if (hasBroken || hasMissing) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Complete Checklist?'),
          content: Text(
            'You have marked some tools as:\n'
            '${hasBroken ? '• Broken: $_getBrokenCount()\n' : ''}'
            '${hasMissing ? '• Missing: $_getMissingCount()\n' : ''}'
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
      final jobProvider = context.read<HappySunJobProvider>();

      await jobProvider.updateChecklistData(
        widget.job.id,
        widget.job.date,
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
          title: Text(widget.job.checklistData != null
              ? 'Checklist (Completed)'
              : 'Pre-Departure Checklist'),
          backgroundColor:
              widget.job.checklistData != null ? Colors.green : Colors.blue,
          foregroundColor: Colors.white,
          actions: [
            if (widget.job.checklistData != null)
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
        body: Column(
          children: [
            // Completion banner if already completed
            if (widget.job.checklistData != null) ...[
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
                            'Completed on ${_formatDateTime(widget.job.checklistData!.completedAt)}',
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
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: widget.job.checklistData != null
                      ? [Colors.green.shade700, Colors.green.shade500]
                      : [Colors.blue.shade700, Colors.blue.shade500],
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
                          Icons.assignment_turned_in,
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
                              'Pre-Departure Checklist',
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
                color: Colors.blue.shade50,
                border: Border(
                  bottom: BorderSide(color: Colors.blue.shade200),
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.checklist, color: Colors.blue),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Verify all tools before leaving',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Mark each tool as present, broken, or missing',
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
                          'Verified', _getVerifiedCount(), Colors.green),
                      const SizedBox(width: 8),
                      _buildStatusChip('Remaining',
                          _getTotalTools() - _getVerifiedCount(), Colors.grey),
                      const SizedBox(width: 8),
                      if (_getBrokenCount() > 0)
                        _buildStatusChip(
                            'Broken', _getBrokenCount(), Colors.orange),
                      if (_getMissingCount() > 0) ...[
                        const SizedBox(width: 8),
                        _buildStatusChip(
                            'Missing', _getMissingCount(), Colors.red),
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
            // Bottom actions
            _buildBottomActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
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

  Widget _buildToolsList() {
    if (_toolStatus.isEmpty) {
      return const Center(
        child: Text('No tools to verify'),
      );
    }

    // Group by base name
    final groupedTools = <String, List<_ToolCheckStatus>>{};
    for (final status in _toolStatus.values) {
      groupedTools.putIfAbsent(status.baseName, () => []).add(status);
    }

    final sortedGroups = groupedTools.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return ListView.builder(
      padding: const EdgeInsets.all(16),
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
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: borderColor, width: 2),
          ),
          child: ExpansionTile(
            leading: Icon(
              allVerified ? Icons.check_circle : Icons.radio_button_unchecked,
              color: borderColor,
            ),
            title: Text(
              baseName,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              '${tools.length} ${tools.length == 1 ? 'tool' : 'tools'} • ${tools.where((t) => t.isVerified).length} verified',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
            children: tools.map((tool) => _buildToolItem(tool)).toList(),
          ),
        );
      },
    );
  }

  Widget _buildToolItem(_ToolCheckStatus toolStatus) {
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              Checkbox(
                value: toolStatus.isVerified,
                onChanged: (value) {
                  setState(() {
                    toolStatus.isVerified = value ?? false;
                    _hasUnsavedChanges = true;
                  });
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      toolStatus.toolId,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        decoration: toolStatus.isVerified
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    Text(
                      toolStatus.category,
                      style: TextStyle(
                        fontSize: 11,
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
                icon: Icon(statusIcon, color: statusColor, size: 20),
                items: const [
                  DropdownMenuItem(value: 'present', child: Text('Present')),
                  DropdownMenuItem(value: 'broken', child: Text('Broken')),
                  DropdownMenuItem(value: 'missing', child: Text('Missing')),
                ],
                onChanged: (value) {
                  setState(() {
                    toolStatus.status = value ?? 'present';
                    _hasUnsavedChanges = true;
                  });
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                  toolStatus.notes.isEmpty ? Icons.note_add : Icons.note,
                  color: toolStatus.notes.isEmpty ? Colors.grey : Colors.blue,
                ),
                onPressed: () => _showNotesDialog(toolStatus),
              ),
            ],
          ),
          if (toolStatus.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(Icons.note, size: 14, color: Colors.blue.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      toolStatus.notes,
                      style: TextStyle(
                        fontSize: 12,
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
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
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
          const SizedBox(height: 16),
          // Buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      _hasUnsavedChanges && !_isSaving ? _saveProgress : null,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: const Text('Save Progress'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed:
                      allChecked && !_isSaving ? _completeChecklist : null,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Complete'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
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
}
