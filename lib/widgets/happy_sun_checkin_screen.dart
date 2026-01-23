import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_job.dart';
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

class _HappySunCheckinScreenState extends State<HappySunCheckinScreen> {
  final Map<String, _ToolCheckinStatus> _toolStatus = {}; // toolId -> status
  bool _isChecking = false;

  @override
  void initState() {
    super.initState();
    _initializeToolStatus();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check-in Tools'),
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
      ),
      body: Column(
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
            child: ListView.builder(
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
                                          color:
                                              status.checklistStatus == 'broken'
                                                  ? Colors.orange.shade100
                                                  : Colors.red.shade100,
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          status.checklistStatus.toUpperCase(),
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
                                  'ID: $toolId • ${status.category}',
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
                                      borderRadius: BorderRadius.circular(4),
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
                  ),
                );
              },
            ),
          ),
          _buildBottomActions(),
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
              label: Text(_isChecking ? 'Checking in...' : 'Complete Check-in'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        ],
      ),
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
