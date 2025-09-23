import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/distributor.dart';
import '../providers/schedule_provider.dart';
import 'edit_distributor_dialog.dart';

class DistributorManagementDialog extends StatefulWidget {
  const DistributorManagementDialog({super.key});

  @override
  State<DistributorManagementDialog> createState() =>
      _DistributorManagementDialogState();
}

class _DistributorManagementDialogState
    extends State<DistributorManagementDialog> {
  // Track changes locally before committing to database
  List<Distributor> _localDistributors = [];
  final Set<String> _deletedDistributorIds = {};
  bool _hasChanges = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Initialize with current distributors
    _initializeLocalDistributors();
  }

  void _initializeLocalDistributors() {
    final provider = Provider.of<ScheduleProvider>(context, listen: false);
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
    return Consumer<ScheduleProvider>(
      builder: (context, provider, child) {
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.2),
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
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withOpacity(0.1),
                                child: Text(
                                  distributor.index.toString(),
                                  style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(distributor.name),
                              subtitle: Text('Position: ${distributor.index}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (distributor.index > 0)
                                    IconButton(
                                      icon: const Icon(Icons.keyboard_arrow_up),
                                      tooltip: 'Move Up',
                                      onPressed: () =>
                                          _swapDistributorPositions(
                                              distributor, true),
                                    ),
                                  if (distributor.index <
                                      _localDistributors.length - 1)
                                    IconButton(
                                      icon:
                                          const Icon(Icons.keyboard_arrow_down),
                                      tooltip: 'Move Down',
                                      onPressed: () =>
                                          _swapDistributorPositions(
                                              distributor, false),
                                    ),
                                  IconButton(
                                    icon: const Icon(Icons.edit),
                                    tooltip: 'Edit Distributor',
                                    onPressed: () =>
                                        _editDistributorLocal(distributor),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete),
                                    tooltip: 'Delete Distributor',
                                    onPressed: () =>
                                        _deleteDistributorLocal(distributor),
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
                            color: _hasChanges
                                ? Colors.orange[700]
                                : Colors.grey[600],
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
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
      },
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
      final currentIndex = distributor.index;
      final targetIndex = moveUp ? currentIndex - 1 : currentIndex + 1;

      // Find the distributor at the target position
      final targetDistributor = _localDistributors.firstWhere(
        (d) => d.index == targetIndex,
        orElse: () => throw StateError('Target distributor not found'),
      );

      // Find the indices in the list for both distributors
      final currentDistributorListIndex =
          _localDistributors.indexWhere((d) => d.id == distributor.id);
      final targetDistributorListIndex =
          _localDistributors.indexWhere((d) => d.id == targetDistributor.id);

      if (currentDistributorListIndex == -1 ||
          targetDistributorListIndex == -1) {
        return; // Safety check
      }

      // Swap the indices
      _localDistributors[currentDistributorListIndex] =
          distributor.copyWith(index: targetIndex);
      _localDistributors[targetDistributorListIndex] =
          targetDistributor.copyWith(index: currentIndex);

      // Sort by index to maintain display order
      _localDistributors.sort((a, b) => a.index.compareTo(b.index));
      _markAsChanged();
    });
  }

  void _reindexDistributors() {
    // Only use this for cleanup operations like after deletion
    // Sort by index and reassign sequential indices starting from 0
    _localDistributors.sort((a, b) => a.index.compareTo(b.index));
    for (int i = 0; i < _localDistributors.length; i++) {
      _localDistributors[i] = _localDistributors[i].copyWith(index: i);
    }
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
      final oldIndex = result['oldIndex'] as int;

      setState(() {
        final distributorIndex =
            _localDistributors.indexWhere((d) => d.id == distributor.id);
        if (distributorIndex != -1) {
          // If index changed, use smart move logic
          if (oldIndex != updatedDistributor.index) {
            // Remove the distributor temporarily
            _localDistributors.removeAt(distributorIndex);

            // Update other distributors using smart indexing logic
            final currentIndex = oldIndex;
            final newIndex = updatedDistributor.index;

            if (currentIndex < newIndex) {
              // Moving down: shift distributors up
              for (int i = 0; i < _localDistributors.length; i++) {
                final other = _localDistributors[i];
                if (other.index > currentIndex && other.index <= newIndex) {
                  _localDistributors[i] =
                      other.copyWith(index: other.index - 1);
                }
              }
            } else {
              // Moving up: shift distributors down
              for (int i = 0; i < _localDistributors.length; i++) {
                final other = _localDistributors[i];
                if (other.index >= newIndex && other.index < currentIndex) {
                  _localDistributors[i] =
                      other.copyWith(index: other.index + 1);
                }
              }
            }

            // Add the updated distributor back
            _localDistributors.add(updatedDistributor);
          } else {
            // Just update name if index didn't change
            _localDistributors[distributorIndex] = updatedDistributor;
          }

          // Sort by index to maintain display order
          _localDistributors.sort((a, b) => a.index.compareTo(b.index));
          _markAsChanged();
        }
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
                _reindexDistributors();
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
      final provider = Provider.of<ScheduleProvider>(context, listen: false);
      _localDistributors =
          provider.distributors.map((d) => d.copyWith()).toList();
      _localDistributors.sort((a, b) => a.index.compareTo(b.index));
      _deletedDistributorIds.clear();
      _hasChanges = false;
    });
  }

  Future<void> _saveChanges() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final provider = Provider.of<ScheduleProvider>(context, listen: false);

      // Delete distributors first
      for (String deletedId in _deletedDistributorIds) {
        await provider.deleteDistributorSmart(deletedId);
      }

      // For updates, we need to be more careful about batch operations
      // Let's create a mapping of current state vs what we want
      final currentDistributors = provider.distributors
          .where((d) => !_deletedDistributorIds.contains(d.id))
          .toList();
      final distributorsToUpdate = <Distributor>[];

      for (Distributor localDistributor in _localDistributors) {
        final currentDistributor = currentDistributors.firstWhere(
          (d) => d.id == localDistributor.id,
          orElse: () => localDistributor,
        );

        // Only update if there are actual changes
        if (currentDistributor.name != localDistributor.name ||
            currentDistributor.index != localDistributor.index) {
          distributorsToUpdate.add(localDistributor);
        }
      }

      // Update distributors with smart indexing
      for (final distributor in distributorsToUpdate) {
        final currentDistributor =
            currentDistributors.firstWhere((d) => d.id == distributor.id);
        await provider.updateDistributorSmart(
            distributor, currentDistributor.index);

        // Update the current distributors list to reflect the change
        final index =
            currentDistributors.indexWhere((d) => d.id == distributor.id);
        if (index != -1) {
          currentDistributors[index] = distributor;
        }
      }

      setState(() {
        _hasChanges = false;
        _deletedDistributorIds.clear();
        _isLoading = false;
      });

      // Refresh local distributors from provider after successful save
      final updatedDistributors =
          provider.distributors.map((d) => d.copyWith()).toList();
      updatedDistributors.sort((a, b) => a.index.compareTo(b.index));
      setState(() {
        _localDistributors = updatedDistributors;
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
      setState(() {
        _isLoading = false;
      });

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
}
