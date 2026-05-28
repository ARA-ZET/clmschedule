import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../config/flavor_config.dart';
import '../models/job.dart';
import '../models/work_area.dart';
import '../models/custom_polygon.dart';
import '../providers/job_status_provider.dart';
import 'print_map_view.dart';
import '../providers/schedule_provider.dart';
import '../providers/job_list_provider.dart';
import '../providers/scale_provider.dart';
import '../providers/unfinished_work_areas_provider.dart';
import '../shareable_maps/providers/shareable_map_provider.dart';
import '../shareable_maps/adapters/schedule_job_adapter.dart';
import '../shareable_maps/widgets/shareable_map_editor.dart';

class JobCard extends riverpod.ConsumerWidget {
  final Job job;
  final bool isFullscreen;

  const JobCard({super.key, required this.job, required this.isFullscreen});

  Color _getStatusColor(riverpod.WidgetRef ref) {
    final statusProvider = ref.watch(jobStatusRiverpod);

    // Safety check for provider loading state
    if (statusProvider.isLoading || statusProvider.statuses.isEmpty) {
      return Colors.grey.shade700; // Default color while loading
    }

    final status = statusProvider.getStatusById(job.statusId);
    return status?.color ??
        Colors.grey.shade700; // Darker grey for better contrast
  }

  void _printMapLink(BuildContext context) {
    // Get distributor name from the schedule provider
    final scheduleProvider =
        riverpod.ProviderScope.containerOf(context).read(scheduleRiverpod);
    String? distributorName;

    try {
      final distributor = scheduleProvider.distributors
          .firstWhere((d) => d.id == job.distributorId);
      distributorName = distributor.name;
    } catch (e) {
      // If distributor not found, use null
      distributorName = null;
    }

    try {
      showDialog(
        context: context,
        useSafeArea: true,
        builder: (BuildContext context) => Dialog.fullscreen(
          child: PrintMapView(
            job: job,
            distributorName: distributorName,
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open print map: $e'),
            backgroundColor:
                Colors.red.shade800, // Darker red for better contrast
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    // isFullscreen is passed from the parent grid (single TogglerProvider subscription
    // at the grid level), avoiding per-card Provider subscriptions.
    final statusColor = _getStatusColor(ref);

    return Card(
      margin: const EdgeInsets.all(1),
      color: statusColor,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Client section
            _JobClientSection(job: job),

            if (isFullscreen) ...[
              const _JobDivider(),
              // Work area section
              _JobWorkAreaSection(job: job),
              const _JobDivider(),
              // Status and actions section
              _JobActionsSection(
                job: job,
                statusColor: statusColor,
                onPrintMap: () => _printMapLink(context),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Divider line between job card sections
class _JobDivider extends StatelessWidget {
  const _JobDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: Colors.white54,
      margin: const EdgeInsets.symmetric(vertical: 2),
    );
  }
}

/// Client list section of job card
class _JobClientSection extends StatelessWidget {
  final Job job;

  const _JobClientSection({required this.job});

  @override
  Widget build(BuildContext context) {
    return Flexible(
      flex: 3,
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: _ClientListEditor(
              job: job,
              onClientsChanged: (List<String> updatedClients,
                  List<String> updatedInstructions) {
                // Get fresh job data from provider to avoid stale state
                final scheduleProvider =
                    riverpod.ProviderScope.containerOf(context)
                        .read(scheduleRiverpod);
                final freshJob = scheduleProvider.jobs.firstWhere(
                  (j) => j.id == job.id,
                  orElse: () => job,
                );
                final originalJob = freshJob;
                final modifiedJob = freshJob.copyWith(
                  clients: updatedClients,
                  clientInstructions: updatedInstructions,
                );
                scheduleProvider.updateJobWithUndo(
                  originalJob,
                  modifiedJob,
                  freshJob.date,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Work area list section of job card
class _JobWorkAreaSection extends StatelessWidget {
  final Job job;

  const _JobWorkAreaSection({required this.job});

  @override
  Widget build(BuildContext context) {
    return Flexible(
      flex: 3,
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: _WorkAreaListEditor(
              job: job,
              onWorkAreasChanged: (List<CustomPolygon> updatedWorkMaps) {
                // Get fresh job data from provider to avoid stale state
                final scheduleProvider =
                    riverpod.ProviderScope.containerOf(context)
                        .read(scheduleRiverpod);
                final freshJob = scheduleProvider.jobs.firstWhere(
                  (j) => j.id == job.id,
                  orElse: () => job,
                );
                final updatedWorkingAreas =
                    updatedWorkMaps.map((polygon) => polygon.name).toList();
                final originalJob = freshJob;
                final modifiedJob = freshJob.copyWith(
                  workingAreas: updatedWorkingAreas,
                  workMaps: updatedWorkMaps,
                );
                scheduleProvider.updateJobWithUndo(
                  originalJob,
                  modifiedJob,
                  freshJob.date,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Actions section with print map and status buttons
class _JobActionsSection extends riverpod.ConsumerWidget {
  final Job job;
  final Color statusColor;
  final VoidCallback onPrintMap;

  const _JobActionsSection({
    required this.job,
    required this.statusColor,
    required this.onPrintMap,
  });

  void _showMapInstructionsDialog(BuildContext context) {
    final controller = TextEditingController(text: job.mapInstructions);
    // Capture the provider reference NOW while context is definitely mounted,
    // not inside the dialog callback where the outer context may be stale.
    final scheduleProvider =
        riverpod.ProviderScope.containerOf(context).read(scheduleRiverpod);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Map Instructions'),
          content: SizedBox(
            width: 360,
            child: TextField(
              controller: controller,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(
                hintText:
                    'Enter driver notes: access codes, landmarks, parking…',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                controller.dispose();
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final newInstructions = controller.text.trim();
                final freshJob = scheduleProvider.jobs.firstWhere(
                  (j) => j.id == job.id,
                  orElse: () => job,
                );
                final modifiedJob =
                    freshJob.copyWith(mapInstructions: newInstructions);
                scheduleProvider.updateJobWithUndo(
                    freshJob, modifiedJob, freshJob.date);
                Navigator.of(ctx).pop();
                controller.dispose();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final scaleProvider = ref.read(scaleRiverpod);

    return Flexible(
      flex: 1,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Print map button
          Tooltip(
            message: 'Open location in Google Maps',
            child: GestureDetector(
              onTap: onPrintMap,
              child: Text(
                'PRINT MAP',
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: scaleProvider.smallFontSize,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w500,
                ),
                textScaler: const TextScaler.linear(1),
                maxLines: 1,
              ),
            ),
          ),
          // Map instructions button
          Tooltip(
            message: job.mapInstructions.isNotEmpty
                ? 'Instructions: ${job.mapInstructions}'
                : 'Add map instructions',
            child: IconButton(
              icon: Icon(
                job.mapInstructions.isNotEmpty
                    ? Icons.info
                    : Icons.info_outline,
                color: job.mapInstructions.isNotEmpty
                    ? Colors.amber
                    : Colors.white54,
                size: scaleProvider.smallIconSize,
              ),
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
              iconSize: scaleProvider.smallIconSize,
              onPressed: () => _showMapInstructionsDialog(context),
            ),
          ),
          // Status button
          _JobStatusButton(job: job, statusColor: statusColor),
        ],
      ),
    );
  }
}

/// Status button for changing job status
class _JobStatusButton extends riverpod.ConsumerWidget {
  final Job job;
  final Color statusColor;

  const _JobStatusButton({
    required this.job,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final scaleProvider = ref.read(scaleRiverpod);
    final statusProvider = ref.watch(jobStatusRiverpod);
    final currentStatus = statusProvider.getStatusById(job.statusId);

    return Tooltip(
      message: 'Change job status',
      child: TextButton(
        onPressed: () => _showStatusDialog(context, statusProvider),
        style: TextButton.styleFrom(
          backgroundColor: statusColor,
          padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 4,
          ),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          (currentStatus?.label ?? 'UNKNOWN').toUpperCase(),
          style: TextStyle(
            color: Colors.white,
            fontSize: scaleProvider.smallFontSize,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
    );
  }

  void _showStatusDialog(
      BuildContext context, JobStatusProvider statusProvider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change Status'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: statusProvider.statuses.map((status) {
              final isSelected = status.id == job.statusId;
              return ListTile(
                dense: true,
                title: Text(status.label),
                tileColor:
                    isSelected ? status.color.withValues(alpha: 0.3) : null,
                leading: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: status.color,
                    shape: BoxShape.circle,
                  ),
                ),
                onTap: () {
                  // Get fresh job data from provider to avoid stale state
                  final scheduleProvider =
                      riverpod.ProviderScope.containerOf(context)
                          .read(scheduleRiverpod);
                  final freshJob = scheduleProvider.jobs.firstWhere(
                    (j) => j.id == job.id,
                    orElse: () => job,
                  );
                  final originalJob = freshJob;
                  final modifiedJob = freshJob.copyWith(statusId: status.id);
                  scheduleProvider.updateJobWithUndo(
                    originalJob,
                    modifiedJob,
                    freshJob.date,
                  );
                  Navigator.of(context).pop();
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _ClientListEditor extends StatefulWidget {
  final Job job;
  final Function(List<String> clients, List<String> instructions)
      onClientsChanged;

  const _ClientListEditor({
    required this.job,
    required this.onClientsChanged,
  });

  @override
  State<_ClientListEditor> createState() => _ClientListEditorState();
}

class _ClientListEditorState extends State<_ClientListEditor> {
  late TextEditingController _controller;
  late List<String> _localClients;

  @override
  void initState() {
    super.initState();
    _localClients = List.from(widget.job.clients);
    _controller = TextEditingController(text: widget.job.clientsDisplay);
  }

  @override
  void didUpdateWidget(_ClientListEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.job.clients != widget.job.clients) {
      setState(() {
        _localClients = List.from(widget.job.clients);
        _controller.text = widget.job.clientsDisplay;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showClientListDialog() {
    showDialog(
      context: context,
      builder: (context) => _ClientListDialog(
        clients: _localClients,
        clientInstructions: widget.job.clientInstructions,
        jobId: widget.job.id,
        onClientsChanged: (updatedClients, updatedInstructions) {
          setState(() {
            _localClients = updatedClients;
            _controller.text = updatedClients.join(', ');
          });
          widget.onClientsChanged(updatedClients, updatedInstructions);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return riverpod.Consumer(
      builder: (context, ref, child) {
        final scaleProvider = ref.watch(scaleRiverpod);
        return Row(
          children: [
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(left: 4),
                child: Text(
                  _localClients.isEmpty
                      ? 'add client'
                      : _localClients
                          .map((e) => e.trim())
                          .where((e) => e.isNotEmpty)
                          .join(', '),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                  style: TextStyle(
                      fontSize: scaleProvider.mediumFontSize,
                      color: Colors.white,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),

            // Always show edit button for client management
            IconButton(
              icon: Icon(_localClients.length > 1 ? Icons.list : Icons.edit,
                  color: Colors.white, size: scaleProvider.smallIconSize),
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
              iconSize: scaleProvider.smallIconSize,
              onPressed: _showClientListDialog,
              tooltip:
                  _localClients.length > 1 ? 'Edit client list' : 'Edit client',
            ),
          ],
        );
      },
    );
  }
}

class _ClientListDialog extends StatefulWidget {
  final List<String> clients;
  final List<String> clientInstructions;
  final Function(List<String> clients, List<String> instructions)
      onClientsChanged;
  final String jobId;

  const _ClientListDialog({
    required this.clients,
    required this.clientInstructions,
    required this.onClientsChanged,
    required this.jobId,
  });

  @override
  State<_ClientListDialog> createState() => _ClientListDialogState();
}

class _ClientListDialogState extends State<_ClientListDialog> {
  late List<TextEditingController> _controllers;
  late List<TextEditingController> _instructionControllers;
  late List<String> _clients;

  @override
  void initState() {
    super.initState();
    _clients = List.from(widget.clients);
    if (_clients.isEmpty) _clients.add('');
    _controllers =
        _clients.map((client) => TextEditingController(text: client)).toList();
    // Pad instructions to match client count (backward compat with old jobs).
    final instructions = List<String>.from(widget.clientInstructions);
    while (instructions.length < _clients.length) {
      instructions.add('');
    }
    _instructionControllers = instructions
        .map((instr) => TextEditingController(text: instr))
        .toList();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final controller in _instructionControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _addClient() {
    setState(() {
      _clients.add('');
      _controllers.add(TextEditingController());
      _instructionControllers.add(TextEditingController());
    });
  }

  void _removeClient(int index) {
    if (_clients.length > 1) {
      setState(() {
        _clients.removeAt(index);
        _controllers[index].dispose();
        _controllers.removeAt(index);
        _instructionControllers[index].dispose();
        _instructionControllers.removeAt(index);
      });
    }
  }

  void _saveClients() {
    final validPairs = List.generate(_controllers.length, (i) {
      return (
        client: _controllers[i].text.trim(),
        instruction: _instructionControllers[i].text.trim(),
      );
    }).where((p) => p.client.isNotEmpty).toList();

    widget.onClientsChanged(
      validPairs.map((p) => p.client).toList(),
      validPairs.map((p) => p.instruction).toList(),
    );
    Navigator.of(context).pop();
  }

  void _showDeleteJobConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Job'),
        content: const Text(
          'Are you sure you want to permanently delete this entire job from the database?\n\n'
          'This action cannot be undone and will remove all job data including clients, work areas, and schedule information.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          _DeleteJobButton(jobId: widget.jobId),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return riverpod.Consumer(
      builder: (context, ref, child) {
        final scaleProvider = ref.watch(scaleRiverpod);
        final jobListProvider = ref.watch(jobListRiverpod);
        // Get unique client names for suggestions
        final uniqueClients = jobListProvider.jobListItems
            .map((item) => item.client)
            .where((client) => client.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

        return AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Edit Client List'),
              IconButton(
                icon: const Icon(Icons.delete_forever, color: Colors.red),
                onPressed: () => _showDeleteJobConfirmation(context),
                tooltip: 'Delete entire job from database',
              ),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Edit or add multiple clients for this job:'),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _controllers.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── Client name row ──────────────────────
                            Row(
                              children: [
                                Expanded(
                                  child: Autocomplete<String>(
                                    initialValue: TextEditingValue(
                                      text: _controllers[index].text,
                                    ),
                                    optionsBuilder:
                                        (TextEditingValue textEditingValue) {
                                      if (textEditingValue.text.isEmpty) {
                                        return uniqueClients.take(10);
                                      }
                                      return uniqueClients
                                          .where((String client) {
                                        return client.toLowerCase().contains(
                                              textEditingValue.text
                                                  .toLowerCase(),
                                            );
                                      }).take(10);
                                    },
                                    onSelected: (String selectedClient) {
                                      _controllers[index].text = selectedClient;
                                      _clients[index] = selectedClient;
                                    },
                                    fieldViewBuilder: (
                                      BuildContext context,
                                      TextEditingController controller,
                                      FocusNode focusNode,
                                      VoidCallback onFieldSubmitted,
                                    ) {
                                      // Sync the autocomplete controller with our local controller
                                      if (controller.text !=
                                          _controllers[index].text) {
                                        controller.text =
                                            _controllers[index].text;
                                        controller.selection =
                                            TextSelection.collapsed(
                                          offset: controller.text.length,
                                        );
                                      }

                                      return TextFormField(
                                        controller: controller,
                                        focusNode: focusNode,
                                        decoration: InputDecoration(
                                          labelText: 'Client ${index + 1}',
                                          border: const OutlineInputBorder(),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                        ),
                                        onChanged: (value) {
                                          _controllers[index].text = value;
                                          _clients[index] = value;
                                        },
                                        onFieldSubmitted: (String value) {
                                          onFieldSubmitted();
                                        },
                                      );
                                    },
                                    optionsViewBuilder: (
                                      BuildContext context,
                                      void Function(String) onSelected,
                                      Iterable<String> options,
                                    ) {
                                      return Align(
                                        alignment: Alignment.topLeft,
                                        child: Material(
                                          elevation: 4.0,
                                          child: Container(
                                            width: 300,
                                            constraints: const BoxConstraints(
                                              maxHeight: 200,
                                            ),
                                            child: ListView.builder(
                                              padding: EdgeInsets.zero,
                                              shrinkWrap: true,
                                              itemCount: options.length,
                                              itemBuilder:
                                                  (BuildContext context,
                                                      int index) {
                                                final String option =
                                                    options.elementAt(index);
                                                return InkWell(
                                                  onTap: () {
                                                    onSelected(option);
                                                  },
                                                  child: ListTile(
                                                    dense: true,
                                                    title: Text(
                                                      option,
                                                      style: TextStyle(
                                                        color: Theme.of(context)
                                                            .textTheme
                                                            .bodyMedium
                                                            ?.color,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (_controllers.length > 1)
                                  IconButton(
                                    icon: Icon(Icons.remove_circle_outline,
                                        size: scaleProvider.mediumIconSize),
                                    onPressed: () => _removeClient(index),
                                    tooltip: 'Remove client',
                                  ),
                              ],
                            ),
                            // ── Per-client instructions ──────────────
                            const SizedBox(height: 6),
                            TextField(
                              controller: _instructionControllers[index],
                              maxLines: 2,
                              style: TextStyle(
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                                color: Colors.grey.shade800,
                              ),
                              decoration: InputDecoration(
                                labelText:
                                    'Instructions for client ${index + 1}',
                                hintText:
                                    'Access code, landmark, special notes…',
                                border: OutlineInputBorder(
                                  borderSide:
                                      BorderSide(color: Colors.teal.shade300),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderSide:
                                      BorderSide(color: Colors.teal.shade300),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderSide:
                                      BorderSide(color: Colors.teal, width: 2),
                                ),
                                labelStyle: TextStyle(
                                  color: Colors.teal.shade700,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                ),
                                hintStyle: TextStyle(
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                  color: Colors.grey.shade400,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                isDense: true,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: 'Add a new client to the list',
                    child: TextButton.icon(
                      onPressed: _addClient,
                      icon: Icon(Icons.add, size: scaleProvider.mediumIconSize),
                      label: const Text('Add Client'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            Tooltip(
              message: 'Cancel changes',
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
            Tooltip(
              message: 'Save client list changes',
              child: ElevatedButton(
                onPressed: _saveClients,
                child: const Text('Save'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WorkAreaListEditor extends StatefulWidget {
  final Job job;
  final Function(List<CustomPolygon>) onWorkAreasChanged;

  const _WorkAreaListEditor({
    required this.job,
    required this.onWorkAreasChanged,
  });

  @override
  State<_WorkAreaListEditor> createState() => _WorkAreaListEditorState();
}

class _WorkAreaListEditorState extends State<_WorkAreaListEditor> {
  late List<CustomPolygon> _localWorkMaps;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    _localWorkMaps = List.from(widget.job.workMaps);
  }

  @override
  void didUpdateWidget(_WorkAreaListEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.job.workMaps != widget.job.workMaps) {
      setState(() {
        _localWorkMaps = List.from(widget.job.workMaps);
        _hasUnsavedChanges = false; // Clear unsaved changes when job updates
      });
    }
  }

  void _showWorkAreaListDialog() {
    showDialog(
      context: context,
      builder: (context) => _WorkAreaListDialog(
        workMaps: _localWorkMaps,
        onWorkAreasChanged: (updatedWorkMaps, bool hasChanges) {
          setState(() {
            _localWorkMaps = updatedWorkMaps;
            _hasUnsavedChanges = hasChanges;
          });
        },
        onSaveChanges: () {
          widget.onWorkAreasChanged(_localWorkMaps);
          setState(() {
            _hasUnsavedChanges = false;
          });
        },
      ),
    );
  }

  String _getDisplayText() {
    // Exclude point-type entries (dropoff, pickup, etc.) from the label.
    final polygonMaps = _localWorkMaps.where((w) => !w.isPoint).toList();
    if (polygonMaps.isEmpty) {
      return 'add work area';
    }
    final names = polygonMaps.map((w) => w.name).where((n) => n.isNotEmpty);
    return names.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return riverpod.Consumer(
      builder: (context, ref, child) {
        final scaleProvider = ref.watch(scaleRiverpod);
        return Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _showWorkAreaListDialog,
                child: Container(
                  margin: const EdgeInsets.only(left: 4),
                  child: Text(
                    _getDisplayText(),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: scaleProvider.mediumFontSize,
                      color: _hasUnsavedChanges ? Colors.amber : Colors.white,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),

            // Map Edit Button
            IconButton(
              icon: const Icon(
                Icons.edit_location_alt,
                color: Colors.white,
              ),
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
              iconSize: scaleProvider.mediumIconSize,
              tooltip: 'Edit work area on map',
              onPressed: () async {
                try {
                  // Add a small delay to prevent rapid dialog opening/closing
                  await Future.delayed(const Duration(milliseconds: 100));

                  if (!context.mounted) return;

                  // Use the ShareableMapEditor with ScheduleJobAdapter
                  final mapProvider = ref.read(shareableMapRiverpod);
                  final scheduleProvider = ref.read(scheduleRiverpod);
                  // Only inject the unfinished-work-areas layer in schedule
                  // flavors (not the standalone maps flavor).
                  final unfinishedProvider = FlavorConfig.instance.isMaps
                      ? null
                      : ref.read(unfinishedWorkAreasRiverpod);

                  // Resolve distributor name for the map editor title
                  String? distributorName;
                  try {
                    final distributor = scheduleProvider.distributors
                        .firstWhere((d) => d.id == widget.job.distributorId);
                    distributorName = distributor.name;
                  } catch (_) {}

                  // Create a save callback that updates the job via ScheduleProvider
                  final adapter = ScheduleJobAdapter(
                    job: widget.job,
                    distributorName: distributorName,
                    unfinishedProvider: unfinishedProvider,
                    onSave: (polygons, workingAreaNames) async {
                      debugPrint(
                          '[JobCard.onSave] Received ${polygons.length} polygons to save');
                      for (final p in polygons) {
                        debugPrint(
                            '  "${p.name}" type=${p.type} points=${p.points.length} '
                            'pointCategory=${p.pointCategory.id}');
                      }
                      final freshJob = scheduleProvider.jobs.firstWhere(
                        (j) => j.id == widget.job.id,
                        orElse: () => widget.job,
                      );
                      final modifiedJob = freshJob.copyWith(
                        workingAreas: workingAreaNames,
                        workMaps: polygons,
                      );
                      debugPrint(
                          '[JobCard.onSave] modifiedJob workMaps: ${modifiedJob.workMaps.length}');
                      for (final wm in modifiedJob.workMaps) {
                        debugPrint(
                            '  "${wm.name}" type=${wm.type} points=${wm.points.length} '
                            'pointCategory=${wm.pointCategory.id}');
                      }
                      await scheduleProvider.updateJobWithUndo(
                        freshJob,
                        modifiedJob,
                        freshJob.date,
                      );
                    },
                  );

                  await mapProvider.loadFromAdapter(adapter);

                  if (!context.mounted) return;

                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => const ShareableMapEditor(),
                    ),
                  );

                  // After returning from editor, update local state
                  if (context.mounted) {
                    // Get fresh job data from provider
                    final freshJob = scheduleProvider.jobs.firstWhere(
                      (j) => j.id == widget.job.id,
                      orElse: () => widget.job,
                    );
                    setState(() {
                      _localWorkMaps = List.from(freshJob.workMaps);
                      _hasUnsavedChanges = false;
                    });
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to open map editor: $e'),
                        backgroundColor: Colors.red.shade800,
                      ),
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }
}

class _WorkAreaListDialog extends riverpod.ConsumerStatefulWidget {
  final List<CustomPolygon> workMaps;
  final Function(List<CustomPolygon>, bool) onWorkAreasChanged;
  final VoidCallback onSaveChanges;

  const _WorkAreaListDialog({
    required this.workMaps,
    required this.onWorkAreasChanged,
    required this.onSaveChanges,
  });

  @override
  riverpod.ConsumerState<_WorkAreaListDialog> createState() =>
      _WorkAreaListDialogState();
}

class _WorkAreaListDialogState
    extends riverpod.ConsumerState<_WorkAreaListDialog> {
  late List<CustomPolygon> _workMaps; // polygon/polyline only
  late List<CustomPolygon> _pointWorkMaps; // preserved: dropoff, pickup, etc.
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    // Separate point-type entries (dropoff, pickup) from editable polygon maps
    // so they are never accidentally removed from the job via this dialog.
    _pointWorkMaps = widget.workMaps.where((wm) => wm.isPoint).toList();
    _workMaps = widget.workMaps.where((wm) => !wm.isPoint).toList();
  }

  /// Returns the full work-map list (polygons + preserved point entries).
  List<CustomPolygon> get _mergedWorkMaps => [..._workMaps, ..._pointWorkMaps];

  void _addWorkArea(WorkArea workArea) {
    // Generate a unique color for the new work area
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal
    ];
    final color = colors[_workMaps.length % colors.length];

    final customPolygon = CustomPolygon(
      name: workArea.name,
      description: workArea.description,
      points: workArea.polygonPoints,
      color: color,
    );

    setState(() {
      _workMaps.add(customPolygon);
      _hasUnsavedChanges = true;
    });

    widget.onWorkAreasChanged(_mergedWorkMaps, _hasUnsavedChanges);
  }

  void _removeWorkArea(int index) {
    setState(() {
      _workMaps.removeAt(index);
      _hasUnsavedChanges = true;
    });

    widget.onWorkAreasChanged(_mergedWorkMaps, _hasUnsavedChanges);
  }

  void _saveChanges() {
    // Sync the merged list to the parent before triggering the save so
    // point-type entries (dropoff, pickup) are not lost.
    widget.onWorkAreasChanged(_mergedWorkMaps, false);
    widget.onSaveChanges();
    setState(() {
      _hasUnsavedChanges = false;
    });
    Navigator.of(context).pop();
  }

  void _discardChanges() {
    if (_hasUnsavedChanges) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard Changes?'),
          content: const Text(
              'You have unsaved changes. Are you sure you want to discard them?'),
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

  @override
  Widget build(BuildContext context) {
    final scheduleProvider = ref.watch(scheduleRiverpod);
    final workAreas = scheduleProvider.workAreas;

    return AlertDialog(
      title: Row(
        children: [
          const Text('Manage Work Areas'),
          if (_hasUnsavedChanges)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.amber,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Unsaved',
                style: TextStyle(fontSize: 10, color: Colors.black),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Current work areas:'),
            const SizedBox(height: 8),
            if (_workMaps.isEmpty)
              const Text('No work areas selected')
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _workMaps.length,
                  itemBuilder: (context, index) {
                    final workMap = _workMaps[index];
                    return Card(
                      child: ListTile(
                        leading: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: workMap.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(workMap.name),
                        subtitle: Text(workMap.description),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () => _removeWorkArea(index),
                          tooltip: 'Remove work area',
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
            const Text('Add work area:'),
            const SizedBox(height: 8),
            Autocomplete<WorkArea>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text.isEmpty) {
                  return workAreas.where(
                      (area) => !_workMaps.any((wm) => wm.name == area.name));
                }
                return workAreas.where((WorkArea area) {
                  if (_workMaps.any((wm) => wm.name == area.name)) {
                    return false; // Don't show already added areas
                  }
                  return area.name.toLowerCase().contains(
                            textEditingValue.text.toLowerCase(),
                          ) ||
                      area.description.toLowerCase().contains(
                            textEditingValue.text.toLowerCase(),
                          );
                });
              },
              displayStringForOption: (WorkArea area) => area.name,
              onSelected: (WorkArea area) {
                _addWorkArea(area);
              },
              fieldViewBuilder: (
                BuildContext context,
                TextEditingController controller,
                FocusNode focusNode,
                VoidCallback onFieldSubmitted,
              ) {
                return TextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'Search work areas...',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.search),
                  ),
                  onFieldSubmitted: (String value) {
                    onFieldSubmitted();
                  },
                );
              },
              optionsViewBuilder: (
                BuildContext context,
                void Function(WorkArea) onSelected,
                Iterable<WorkArea> options,
              ) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4.0,
                    child: Container(
                      width: 400,
                      constraints: const BoxConstraints(
                        maxHeight: 200,
                      ),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (BuildContext context, int index) {
                          final WorkArea option = options.elementAt(index);
                          return InkWell(
                            onTap: () {
                              onSelected(option);
                            },
                            child: ListTile(
                              dense: true,
                              title: Text(option.name),
                              subtitle: Text(option.description),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _discardChanges,
          child: const Text('Cancel'),
        ),
        if (_hasUnsavedChanges)
          ElevatedButton(
            onPressed: _saveChanges,
            child: const Text('Save Changes'),
          ),
      ],
    );
  }
}

class _DeleteJobButton extends riverpod.ConsumerStatefulWidget {
  final String jobId;

  const _DeleteJobButton({
    required this.jobId,
  });

  @override
  riverpod.ConsumerState<_DeleteJobButton> createState() =>
      _DeleteJobButtonState();
}

class _DeleteJobButtonState extends riverpod.ConsumerState<_DeleteJobButton> {
  bool _isDeleting = false;

  Future<void> _deleteJob() async {
    if (_isDeleting) return;

    setState(() {
      _isDeleting = true;
    });

    try {
      await ref.read(scheduleRiverpod).deleteJob(widget.jobId);

      if (context.mounted) {
        Navigator.of(context).pop(); // Close confirmation dialog
        Navigator.of(context).pop(); // Close client list dialog

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Job deleted successfully'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop(); // Close confirmation dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete job: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (context.mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: _isDeleting ? null : _deleteJob,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
      ),
      child: _isDeleting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          : const Text('Delete Job'),
    );
  }
}
