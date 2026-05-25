import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/job.dart';
import '../providers/unfinished_work_areas_provider.dart';
import '../providers/schedule_provider.dart';
import '../providers/scale_provider.dart';
import 'print_map_view.dart';

/// A toggleable side panel that shows unfinished work areas.
/// Supports drag-and-drop:
///  - Drag FROM this panel TO the schedule grid → assigns to distributor/date
///  - Drag FROM the schedule grid TO this panel → unassigns and stores here
class UnfinishedWorkAreasPanel extends riverpod.ConsumerStatefulWidget {
  const UnfinishedWorkAreasPanel({super.key});

  @override
  riverpod.ConsumerState<UnfinishedWorkAreasPanel> createState() =>
      _UnfinishedWorkAreasPanelState();
}

class _UnfinishedWorkAreasPanelState
    extends riverpod.ConsumerState<UnfinishedWorkAreasPanel> {
  final TextEditingController _clientController = TextEditingController();
  final TextEditingController _areaController = TextEditingController();

  @override
  void dispose() {
    _clientController.dispose();
    _areaController.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final provider = ref.read(unfinishedWorkAreasRiverpod);
    final clients = _clientController.text.trim().isEmpty
        ? <String>[]
        : [_clientController.text.trim()];
    final areas = _areaController.text.trim().isEmpty
        ? <String>[]
        : [_areaController.text.trim()];

    await provider.addItem(clients: clients, workingAreas: areas);
    _clientController.clear();
    _areaController.clear();
  }

  /// Show a confirmation dialog before removing an unfinished work area item.
  Future<void> _confirmDelete(
    BuildContext context,
    Job item,
    UnfinishedWorkAreasProvider provider,
  ) async {
    final clientText =
        item.clients.isNotEmpty ? item.clients.join(', ') : 'No client';
    final areaText =
        item.workingAreas.isNotEmpty ? item.workingAreas.join(', ') : 'No area';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete unfinished work area?'),
        content: Text(
          'Are you sure you want to delete this item?\n\n'
          'Client: $clientText\n'
          'Area: $areaText',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await provider.removeItem(item.id);
    }
  }

  /// Handle a job dropped from the schedule grid into this panel.
  Future<void> _handleDropFromGrid(Job job) async {
    final unfinishedProvider = ref.read(unfinishedWorkAreasRiverpod);
    final scheduleProvider = ref.read(scheduleRiverpod);

    try {
      // Step 1: Add to destination first (safe — worst case is a temporary duplicate)
      await unfinishedProvider.addFromJob(job);

      try {
        // Step 2: Remove from source only after destination write succeeded
        await scheduleProvider.deleteJobWithUndo(job, job.date);
      } catch (deleteError) {
        // Add succeeded but delete failed — job exists in both places (recoverable duplicate)
        debugPrint(
            'Warning: Job ${job.id} added to unfinished but failed to remove from schedule: $deleteError');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                  'Job moved but may still appear on schedule. Please remove it manually if so.'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
    } catch (addError) {
      // Add failed — don't remove from schedule (no data loss)
      debugPrint('Failed to add job to unfinished pool: $addError');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to move job: $addError'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.move_to_inbox, color: Colors.white),
              SizedBox(width: 8),
              Expanded(child: Text('Moved to unfinished work areas')),
            ],
          ),
          backgroundColor: Colors.orange.shade700,
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(unfinishedWorkAreasRiverpod);
    final scaleProvider = ref.read(scaleRiverpod);
    final items = provider.items;

    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          left: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(-2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.inversePrimary,
            ),
            child: Row(
              children: [
                Icon(Icons.pending_actions, size: scaleProvider.mediumIconSize),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Unfinished Work',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                Text(
                  '${items.length}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: scaleProvider.smallIconSize + 4,
                  height: scaleProvider.smallIconSize + 4,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: scaleProvider.smallIconSize,
                    icon: const Icon(Icons.close),
                    tooltip: 'Close panel',
                    onPressed: () => provider.togglePanel(),
                  ),
                ),
              ],
            ),
          ),
          // Add new item button
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label:
                    const Text('Add Work Area', style: TextStyle(fontSize: 12)),
                onPressed: () => _showAddDialog(context),
              ),
            ),
          ),

          // Drop target + scrollable grid of items
          Expanded(
            child: DragTarget<Job>(
              onAcceptWithDetails: (details) =>
                  _handleDropFromGrid(details.data),
              onWillAcceptWithDetails: (details) {
                // Accept jobs that have a distributorId (i.e. from the grid)
                return details.data.distributorId.isNotEmpty;
              },
              builder: (context, candidateData, rejectedData) {
                final isHovering = candidateData.isNotEmpty;

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: isHovering
                        ? Colors.orange.withValues(alpha: 0.15)
                        : Colors.transparent,
                    border: isHovering
                        ? Border.all(color: Colors.orange, width: 2)
                        : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  child: provider.isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : items.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    isHovering
                                        ? Icons.move_to_inbox
                                        : Icons.inbox_outlined,
                                    size: 48,
                                    color: isHovering
                                        ? Colors.orange
                                        : Colors.grey.shade400,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    isHovering
                                        ? 'Drop here to unassign'
                                        : 'No unfinished items\nDrag jobs here to unassign',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: isHovering
                                          ? Colors.orange.shade800
                                          : Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(4),
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                return _UnfinishedItemCard(
                                  item: item,
                                  onDelete: () =>
                                      _confirmDelete(context, item, provider),
                                );
                              },
                            ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showAddDialog(BuildContext context) {
    _clientController.clear();
    _areaController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Unfinished Work Area'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _clientController,
              decoration: const InputDecoration(labelText: 'Client'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _areaController,
              decoration: const InputDecoration(labelText: 'Work Area'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              _addItem();
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

/// A single draggable card for an unfinished work area item.
class _UnfinishedItemCard extends StatelessWidget {
  final Job item;
  final VoidCallback onDelete;

  const _UnfinishedItemCard({required this.item, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final clientText =
        item.clients.isNotEmpty ? item.clients.join(', ') : 'No client';
    final areaText =
        item.workingAreas.isNotEmpty ? item.workingAreas.join(', ') : 'No area';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: LongPressDraggable<Job>(
        data: item,
        delay: const Duration(milliseconds: 200),
        hapticFeedbackOnStart: true,
        feedback: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 200,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade400),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clientText,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                    color: Colors.black87,
                  ),
                ),
                Text(
                  areaText,
                  style: const TextStyle(
                    fontSize: 11,
                    decoration: TextDecoration.none,
                    color: Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: _buildCardContent(context, clientText, areaText),
        ),
        child: _buildCardContent(context, clientText, areaText),
      ),
    );
  }

  Widget _buildCardContent(
      BuildContext context, String clientText, String areaText) {
    return Card(
      margin: EdgeInsets.zero,
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    clientText,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    areaText,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 16,
                icon: Icon(Icons.map_outlined, color: Colors.blue.shade400),
                tooltip: 'View map',
                onPressed: () {
                  showDialog(
                    context: context,
                    useSafeArea: true,
                    builder: (BuildContext context) => Dialog.fullscreen(
                      child: PrintMapView(
                        job: item,
                        distributorName: null,
                      ),
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 16,
                icon: Icon(Icons.delete_outline, color: Colors.red.shade300),
                tooltip: 'Remove',
                onPressed: onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
