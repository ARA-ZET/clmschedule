import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/distributor.dart';
import '../providers/schedule_provider.dart';
import 'digital_id_card.dart';
import 'edit_distributor_dialog.dart';

class DistributorManagementDialog extends riverpod.ConsumerStatefulWidget {
  const DistributorManagementDialog({super.key});

  @override
  riverpod.ConsumerState<DistributorManagementDialog> createState() =>
      _DistributorManagementDialogState();
}

class _DistributorManagementDialogState
    extends riverpod.ConsumerState<DistributorManagementDialog> {
  // Track changes locally before committing to database
  List<Distributor> _localDistributors = [];
  final Set<String> _deletedDistributorIds = {};
  bool _hasChanges = false;
  bool _isLoading = false;
  String? _expandedDistributorId;

  @override
  void initState() {
    super.initState();
    // Initialize with current distributors
    _initializeLocalDistributors();
  }

  void _initializeLocalDistributors() {
    final provider = ref.read(scheduleRiverpod);
    _localDistributors =
        provider.distributors.map((d) => d.copyWith()).toList();
    // Ensure proper sorting by index
    _localDistributors.sort((a, b) => a.index.compareTo(b.index));
  }

  void _markAsChanged() {
    if (!_hasChanges) {
      setState(() {
        _hasChanges = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(scheduleRiverpod);
    // Update local distributors if they haven't been modified locally
    if (!_hasChanges) {
      _localDistributors =
          provider.distributors.map((d) => d.copyWith()).toList();
      _localDistributors.sort((a, b) => a.index.compareTo(b.index));
    }

    return Dialog(
      child: Container(
        width: 500,
        height: 600,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.people, size: 24),
                const SizedBox(width: 8),
                const Text(
                  'Distributor Management',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (_hasChanges)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Unsaved changes',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange[800],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => _handleClose(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${_localDistributors.length} distributors',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const Divider(),

            // Content
            Expanded(
              child: _localDistributors.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 64,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'No distributors found',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: _localDistributors.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final distributor = _localDistributors[index];
                        final activeCount = _localDistributors
                            .where(
                                (d) => d.status == DistributorStatus.active)
                            .length;
                        final isActive =
                            distributor.status == DistributorStatus.active;
                        final canMoveUp = isActive
                            ? distributor.index > 0
                            : distributor.index > activeCount;
                        final canMoveDown = isActive
                            ? distributor.index < activeCount - 1
                            : distributor.index < _localDistributors.length - 1;
                        return Card(
                          key: ValueKey(distributor.id),
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ExpansionTile(
                            initiallyExpanded:
                                distributor.id == _expandedDistributorId,
                            onExpansionChanged: (expanded) {
                              _expandedDistributorId =
                                  expanded ? distributor.id : null;
                            },
                            leading: Stack(
                              children: [
                                CircleAvatar(
                                  backgroundColor: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.1),
                                  child: Text(
                                    distributor.index.toString(),
                                    style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: -2,
                                  top: -2,
                                  child: Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color:
                                          _getStatusColor(distributor.status),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            title: Row(
                              children: [
                                Expanded(child: Text(distributor.name)),
                                Icon(
                                  _getStatusIcon(distributor.status),
                                  size: 16,
                                  color: _getStatusColor(distributor.status),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  distributor.status.displayName,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _getStatusColor(distributor.status),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Position: ${distributor.index}'),
                                if (distributor.phone1 != null)
                                  Text(
                                    'Phone: ${distributor.phone1}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                              ],
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.phone, size: 16),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Phone 1: ${distributor.phone1 ?? 'Not set'}',
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        const Icon(Icons.phone_android,
                                            size: 16),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Phone 2: ${distributor.phone2 ?? 'Not set'}',
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        if (canMoveUp)
                                          IconButton(
                                            icon: const Icon(
                                                Icons.keyboard_arrow_up),
                                            tooltip: 'Move Up',
                                            onPressed: () =>
                                                _swapDistributorPositions(
                                                    distributor, true),
                                          ),
                                        if (canMoveDown)
                                          IconButton(
                                            icon: const Icon(
                                                Icons.keyboard_arrow_down),
                                            tooltip: 'Move Down',
                                            onPressed: () =>
                                                _swapDistributorPositions(
                                                    distributor, false),
                                          ),
                                        IconButton(
                                          icon: const Icon(Icons.badge_outlined),
                                          tooltip: 'View Digital ID Card',
                                          onPressed: () =>
                                              showDigitalIdCard(
                                                  context, distributor),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.edit),
                                          tooltip: 'Edit Distributor',
                                          onPressed: () =>
                                              _editDistributorLocal(
                                                  distributor),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete),
                                          tooltip: 'Delete Distributor',
                                          onPressed: () =>
                                              _deleteDistributorLocal(
                                                  distributor),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),

            // Footer with save/cancel actions
            const Divider(),
            Row(
              children: [
                Text(
                  _hasChanges
                      ? 'You have unsaved changes'
                      : 'No changes to save',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            _hasChanges ? Colors.orange[700] : Colors.grey[600],
                      ),
                ),
                const Spacer(),
                if (_hasChanges) ...[
                  TextButton(
                    onPressed: _isLoading ? null : _discardChanges,
                    child: const Text('Discard'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _saveChanges,
                    child: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save Changes'),
                  ),
                ] else
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _handleClose() {
    if (_hasChanges) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Unsaved Changes'),
          content: const Text(
              'You have unsaved changes. Do you want to discard them?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close confirmation dialog
                Navigator.of(context).pop(); // Close main dialog
              },
              child: const Text('Discard'),
            ),
          ],
        ),
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  void _swapDistributorPositions(Distributor distributor, bool moveUp) {
    setState(() {
      _localDistributors.sort((a, b) => a.index.compareTo(b.index));
      final listIndex =
          _localDistributors.indexWhere((d) => d.id == distributor.id);
      final swapIndex = moveUp ? listIndex - 1 : listIndex + 1;

      if (swapIndex < 0 || swapIndex >= _localDistributors.length) return;

      final temp = _localDistributors[listIndex];
      _localDistributors[listIndex] = _localDistributors[swapIndex];
      _localDistributors[swapIndex] = temp;

      _normalizeIndexes();
      _markAsChanged();
    });
  }

  void _normalizeIndexes() {
    // Active distributors keep their relative order; all non-active go to the end.
    // Always produces sequential, gap-free indexes with no duplicates.
    final active = <Distributor>[];
    final inactive = <Distributor>[];
    for (final d in _localDistributors) {
      if (d.status == DistributorStatus.active) {
        active.add(d);
      } else {
        inactive.add(d);
      }
    }
    final ordered = [...active, ...inactive];
    _localDistributors = [
      for (int i = 0; i < ordered.length; i++) ordered[i].copyWith(index: i),
    ];
  }

  Future<void> _editDistributorLocal(Distributor distributor) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => EditDistributorDialog(
        distributor: distributor,
        totalDistributors: _localDistributors.length,
      ),
    );

    if (result != null) {
      final updatedDistributor = result['distributor'] as Distributor;
      final oldIndex = (result['oldIndex'] as num).toInt();
      final newIndex = updatedDistributor.index;

      setState(() {
        _localDistributors.sort((a, b) => a.index.compareTo(b.index));
        final listIndex =
            _localDistributors.indexWhere((d) => d.id == distributor.id);
        if (listIndex == -1) return;

        if (oldIndex != newIndex) {
          _localDistributors.removeAt(listIndex);
          final insertAt = newIndex.clamp(0, _localDistributors.length);
          _localDistributors.insert(insertAt, updatedDistributor);
        } else {
          _localDistributors[listIndex] = updatedDistributor;
        }

        _normalizeIndexes();
        _markAsChanged();
      });
    }
  }

  void _deleteDistributorLocal(Distributor distributor) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Distributor'),
        content: Text(
            'Are you sure you want to delete "${distributor.name}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                _localDistributors.removeWhere((d) => d.id == distributor.id);
                _deletedDistributorIds.add(distributor.id);
                _normalizeIndexes();
                _markAsChanged();
              });
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _discardChanges() {
    setState(() {
      final provider = ref.read(scheduleRiverpod);
      _localDistributors =
          provider.distributors.map((d) => d.copyWith()).toList();
      _localDistributors.sort((a, b) => a.index.compareTo(b.index));
      _deletedDistributorIds.clear();
      _hasChanges = false;
    });
  }

  Future<void> _saveChanges() async {
    setState(() => _isLoading = true);

    try {
      await ref.read(scheduleRiverpod).saveDistributorChanges(
            finalState: _localDistributors,
            deletedIds: Set.of(_deletedDistributorIds),
          );

      setState(() {
        _hasChanges = false;
        _deletedDistributorIds.clear();
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Changes saved successfully!'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save changes: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  IconData _getStatusIcon(DistributorStatus status) {
    switch (status) {
      case DistributorStatus.active:
        return Icons.check_circle;
      case DistributorStatus.inactive:
        return Icons.cancel;
      case DistributorStatus.suspended:
        return Icons.block;
      case DistributorStatus.onLeave:
        return Icons.flight_takeoff;
    }
  }

  Color _getStatusColor(DistributorStatus status) {
    switch (status) {
      case DistributorStatus.active:
        return Colors.green;
      case DistributorStatus.inactive:
        return Colors.grey;
      case DistributorStatus.suspended:
        return Colors.red;
      case DistributorStatus.onLeave:
        return Colors.orange;
    }
  }
}
