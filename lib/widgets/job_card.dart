import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/job.dart';
import '../models/work_area.dart';
import '../models/custom_polygon.dart';
import '../providers/job_status_provider.dart';
import '../utils/work_area_converter.dart';
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
    return status?.color ?? Colors.grey.shade700; // Darker grey for better contrast
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
            backgroundColor: Colors.red.shade800, // Darker red for better contrast
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
                Flexible(
                  flex: 3,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Work Area Selection with Buttons
                      Expanded(
                        flex: 3,
                        child: Consumer<ScheduleProvider>(
                          builder: (context, provider, child) {
                            final workAreas = provider.workAreas;

                            return Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // Work Area Autocomplete
                                Expanded(
                                  child: Autocomplete<WorkArea>(
                                    initialValue: TextEditingValue(
                                      text: job.workingAreasDisplay,
                                    ),
                                    displayStringForOption: (WorkArea area) =>
                                        area.name,
                                    onSelected: (WorkArea area) {
                                      // Convert WorkArea to CustomPolygon and add to workMaps
                                      final customPolygon = WorkAreaConverter
                                          .workAreaToCustomPolygon(area);

                                      // Update working areas list and workMaps
                                      final updatedAreas =
                                          job.workingAreas.isEmpty
                                              ? [area.name]
                                              : <String>[
                                                  area.name,
                                                  ...job.workingAreas.skip(1)
                                                ];

                                      // Update or add to workMaps
                                      final updatedWorkMaps = <CustomPolygon>[
                                        customPolygon,
                                        ...job.workMaps.where(
                                            (map) => map.name != area.name),
                                      ];

                                      context
                                          .read<ScheduleProvider>()
                                          .updateJob(
                                            job.copyWith(
                                              workingAreas: updatedAreas,
                                              workMaps: updatedWorkMaps,
                                            ),
                                          );
                                    },
                                    optionsBuilder:
                                        (TextEditingValue textEditingValue) {
                                      if (textEditingValue.text.isEmpty) {
                                        return workAreas;
                                      }
                                      return workAreas.where((WorkArea area) {
                                        return area.name.toLowerCase().contains(
                                                  textEditingValue.text
                                                      .toLowerCase(),
                                                ) ||
                                            area.description
                                                .toLowerCase()
                                                .contains(
                                                  textEditingValue.text
                                                      .toLowerCase(),
                                                );
                                      });
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
                                        onFieldSubmitted: (String value) {
                                          onFieldSubmitted();
                                        },
                                        decoration: InputDecoration(
                                          isDense: true,
                                          border: InputBorder.none,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          labelStyle: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium?.color,
                                          ),
                                        ),
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: scaleProvider.smallFontSize,
                                        ),
                                        maxLines: 2,
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
                                              itemBuilder: (
                                                BuildContext context,
                                                int index,
                                              ) {
                                                final WorkArea option =
                                                    options.elementAt(index);
                                                return InkWell(
                                                  onTap: () {
                                                    onSelected(option);
                                                  },
                                                  child: ListTile(
                                                    dense: true,
                                                    title: Text(
                                                      option.name,
                                                      style: TextStyle(
                                                        color: Theme.of(context)
                                                            .textTheme
                                                            .bodyMedium
                                                            ?.color,
                                                      ),
                                                    ),
                                                    subtitle: Text(
                                                      option.description,
                                                      style: TextStyle(
                                                        color: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.color,
                                                        fontSize: scaleProvider
                                                            .smallFontSize,
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
                                      final result =
                                          await showDialog<List<LatLng>>(
                                        context: context,
                                        useSafeArea: true,
                                        builder: (BuildContext context) =>
                                            Dialog.fullscreen(
                                          child: MapView(
                                            jobId: job.id,
                                            customPolygons: job.workMaps,
                                            title: job.clientsDisplay,
                                            isEditable: true,
                                          ),
                                        ),
                                      );

                                      if (result != null) {
                                        try {
                                          // Create new CustomPolygon with the edited points
                                          final newCustomPolygon =
                                              WorkAreaConverter
                                                  .createCustomPolygonFromPoints(
                                            result,
                                            name: '${job.primaryClient} ',
                                            description:
                                                'Custom work area for ${job.primaryClient}',
                                          );

                                          // Add or update the custom polygon in workMaps
                                          final updatedWorkMaps =
                                              <CustomPolygon>[
                                            newCustomPolygon,
                                            ...job.workMaps.where((map) =>
                                                map.name !=
                                                newCustomPolygon.name),
                                          ];

                                          // Update working areas if needed
                                          final updatedWorkingAreas =
                                              job.workingAreas.contains(
                                                      newCustomPolygon.name)
                                                  ? job.workingAreas
                                                  : [
                                                      newCustomPolygon.name,
                                                      ...job.workingAreas
                                                    ];

                                          context
                                              .read<ScheduleProvider>()
                                              .updateJob(
                                                job.copyWith(
                                                  workingAreas:
                                                      updatedWorkingAreas,
                                                  workMaps: updatedWorkMaps,
                                                ),
                                              );
                                        } catch (e) {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                    'Failed to save work area: $e'),
                                                backgroundColor: Colors.red.shade800, // Darker red for better contrast
                                              ),
                                            );
                                          }
                                        }
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content:
                                                Text('Failed to open map: $e'),
                                            backgroundColor: Colors.red.shade800, // Darker red for better contrast
                                          ),
                                        );
                                      }
                                    }
                                  },
                                ),
                              ],
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
                              decoration: TextDecoration.underline,
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
  bool _isEditing = false;

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
        _isEditing = false; // Reset editing state when job changes
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
    return Consumer2<JobListProvider, ScaleProvider>(
      builder: (context, jobListProvider, scaleProvider, child) {
        // Get unique client names from current month job list items
        final uniqueClients = jobListProvider.jobListItems
            .map((item) => item.client)
            .where((client) => client.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

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
