import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/job.dart';
import '../models/work_area.dart';
import '../models/custom_polygon.dart';
import '../providers/job_status_provider.dart';
import 'map_view.dart';
import 'print_map_view.dart';
import '../providers/schedule_provider.dart';
import '../providers/job_list_provider.dart';
import '../providers/scale_provider.dart';

class JobCard extends StatelessWidget {
  final Job job;

  const JobCard({super.key, required this.job});

  Color _getStatusColor(BuildContext context) {
    final statusProvider = context.read<JobStatusProvider>();
    final status = statusProvider.getStatusById(job.statusId);
    return status?.color ??
        Colors.grey.shade700; // Darker grey for better contrast
  }

  void _printMapLink(BuildContext context) {
    // Get distributor name from the schedule provider
    final scheduleProvider = context.read<ScheduleProvider>();
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
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
        return Card(
          margin: const EdgeInsets.all(1),
          color: _getStatusColor(context),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Main Row with Client Info and Work Area
                Flexible(
                  flex: 3,
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: _ClientListEditor(
                          job: job,
                          onClientsChanged: (List<String> updatedClients) {
                            context.read<ScheduleProvider>().updateJob(
                                  job.copyWith(clients: updatedClients),
                                );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 1,
                  color: Colors.white54,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                ),
                // Work Area Row
                Flexible(
                  flex: 3,
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: _WorkAreaListEditor(
                          job: job,
                          onWorkAreasChanged:
                              (List<CustomPolygon> updatedWorkMaps) {
                            final updatedWorkingAreas = updatedWorkMaps
                                .map((polygon) => polygon.name)
                                .toList();
                            context.read<ScheduleProvider>().updateJob(
                                  job.copyWith(
                                    workingAreas: updatedWorkingAreas,
                                    workMaps: updatedWorkMaps,
                                  ),
                                );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                Container(
                  height: 1,
                  color: Colors.white54,
                  margin: const EdgeInsets.only(top: 2, bottom: 4),
                ),
                // Status Row
                Flexible(
                  flex: 1,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Tooltip(
                        message: 'Open location in Google Maps',
                        child: GestureDetector(
                          onTap: () => _printMapLink(context),
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
                            // Make text uppercase
                            textScaler: TextScaler.linear(1),
                            // The actual text is already 'Open Map', so use .toUpperCase()
                            // But since it's a const Text, change to:
                            // child: Text('OPEN MAP', ...)
                            maxLines: 1,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: 'Change job status',
                        child: Consumer<JobStatusProvider>(
                          builder: (context, statusProvider, child) {
                            final currentStatus =
                                statusProvider.getStatusById(job.statusId);
                            return TextButton(
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Change Status'),
                                    content: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children:
                                          statusProvider.statuses.map((status) {
                                        final isSelected =
                                            status.id == job.statusId;
                                        return ListTile(
                                          dense: true,
                                          title: Text(status.label),
                                          tileColor: isSelected
                                              ? status.color.withOpacity(0.3)
                                              : null,
                                          leading: Container(
                                            width: 20,
                                            height: 20,
                                            decoration: BoxDecoration(
                                              color: status.color,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          onTap: () {
                                            context
                                                .read<ScheduleProvider>()
                                                .updateJob(
                                                  job.copyWith(
                                                      statusId: status.id),
                                                );
                                            Navigator.of(context).pop();
                                          },
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                );
                              },
                              style: TextButton.styleFrom(
                                backgroundColor: _getStatusColor(context),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                (currentStatus?.label ?? 'UNKNOWN')
                                    .toUpperCase(),
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: scaleProvider.smallFontSize),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ClientListEditor extends StatefulWidget {
  final Job job;
  final Function(List<String>) onClientsChanged;

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
        onClientsChanged: (updatedClients) {
          setState(() {
            _localClients = updatedClients;
            _controller.text = updatedClients.join(', ');
          });
          widget.onClientsChanged(updatedClients);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
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
  final Function(List<String>) onClientsChanged;

  const _ClientListDialog({
    required this.clients,
    required this.onClientsChanged,
  });

  @override
  State<_ClientListDialog> createState() => _ClientListDialogState();
}

class _ClientListDialogState extends State<_ClientListDialog> {
  late List<TextEditingController> _controllers;
  late List<String> _clients;

  @override
  void initState() {
    super.initState();
    _clients = List.from(widget.clients);
    if (_clients.isEmpty) _clients.add('');
    _controllers =
        _clients.map((client) => TextEditingController(text: client)).toList();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _addClient() {
    setState(() {
      _clients.add('');
      _controllers.add(TextEditingController());
    });
  }

  void _removeClient(int index) {
    if (_clients.length > 1) {
      setState(() {
        _clients.removeAt(index);
        _controllers[index].dispose();
        _controllers.removeAt(index);
      });
    }
  }

  void _saveClients() {
    final validClients = _controllers
        .map((controller) => controller.text.trim())
        .where((client) => client.isNotEmpty)
        .toList();

    widget.onClientsChanged(validClients);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<JobListProvider, ScaleProvider>(
      builder: (context, jobListProvider, scaleProvider, child) {
        // Get unique client names for suggestions
        final uniqueClients = jobListProvider.jobListItems
            .map((item) => item.client)
            .where((client) => client.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

        return AlertDialog(
          title: const Text('Edit Client List'),
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
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
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
                                  return uniqueClients.where((String client) {
                                    return client.toLowerCase().contains(
                                          textEditingValue.text.toLowerCase(),
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
                                    controller.text = _controllers[index].text;
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
                                          itemBuilder: (BuildContext context,
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
    if (_localWorkMaps.isEmpty) {
      return 'add work area';
    }
    final names = _localWorkMaps.map((w) => w.name).where((n) => n.isNotEmpty);
    return names.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
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

                  final result =
                      await Navigator.of(context).push<List<CustomPolygon>>(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (BuildContext context) => MapView(
                        jobId: widget.job.id,
                        customPolygons: _localWorkMaps,
                        title: widget.job.clientsDisplay,
                        isEditable: true,
                      ),
                    ),
                  );

                  if (result != null && context.mounted) {
                    try {
                      setState(() {
                        _localWorkMaps = result;
                        _hasUnsavedChanges =
                            false; // Clear unsaved changes since we're auto-saving
                      });
                      // Immediately save the changes to the database
                      widget.onWorkAreasChanged(_localWorkMaps);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Failed to save work area: $e'),
                            backgroundColor: Colors.red.shade800,
                          ),
                        );
                      }
                    }
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to open map: $e'),
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

class _WorkAreaListDialog extends StatefulWidget {
  final List<CustomPolygon> workMaps;
  final Function(List<CustomPolygon>, bool) onWorkAreasChanged;
  final VoidCallback onSaveChanges;

  const _WorkAreaListDialog({
    required this.workMaps,
    required this.onWorkAreasChanged,
    required this.onSaveChanges,
  });

  @override
  State<_WorkAreaListDialog> createState() => _WorkAreaListDialogState();
}

class _WorkAreaListDialogState extends State<_WorkAreaListDialog> {
  late List<CustomPolygon> _workMaps;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    _workMaps = List.from(widget.workMaps);
  }

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

    widget.onWorkAreasChanged(_workMaps, _hasUnsavedChanges);
  }

  void _removeWorkArea(int index) {
    setState(() {
      _workMaps.removeAt(index);
      _hasUnsavedChanges = true;
    });

    widget.onWorkAreasChanged(_workMaps, _hasUnsavedChanges);
  }

  void _saveChanges() {
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
    return Consumer2<ScheduleProvider, ScaleProvider>(
      builder: (context, scheduleProvider, scaleProvider, child) {
        final workAreas = scheduleProvider.workAreas;

        return AlertDialog(
          title: Row(
            children: [
              const Text('Manage Work Areas'),
              if (_hasUnsavedChanges)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
                      return workAreas.where((area) =>
                          !_workMaps.any((wm) => wm.name == area.name));
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
      },
    );
  }
}
