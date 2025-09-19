import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/job.dart';
import '../models/work_area.dart';
import 'map_view.dart';
import '../providers/schedule_provider.dart';
import 'editable_text_field.dart';

class JobCard extends StatelessWidget {
  final Job job;

  const JobCard({super.key, required this.job});

  Color _getStatusColor() {
    switch (job.status) {
      case JobStatus.standby:
        return Colors.grey.shade700; // Darker grey
      case JobStatus.scheduled:
        return const Color.fromARGB(255, 188, 85, 0); // Deep orange
      case JobStatus.done:
        return Colors.green.shade700; // Forest green
      case JobStatus.urgent:
        return Colors.red.shade700; // Deep red
    }
  }

  void _openMapLink(BuildContext context) {
    showDialog(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => Dialog.fullscreen(
        child: MapView(
          jobId: job.id,
          workAreaId: job.workAreaId,
          customWorkArea: job.customWorkArea,
          title: job.client,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(2),
      color: _getStatusColor(),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Main Row with Client Info and Work Area
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: EditableTextField(
                    initialValue: job.client,
                    onChanged: (value) {
                      if (value != job.client) {
                        context.read<ScheduleProvider>().updateJob(
                              job.copyWith(client: value),
                            );
                      }
                    },
                    hintText: 'Client Name',
                  ),
                ),
              ],
            ),
            Row(
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
                                text: job.workingArea,
                              ),
                              displayStringForOption: (WorkArea area) =>
                                  area.name,
                              onSelected: (WorkArea area) {
                                if (area.id != job.workAreaId ||
                                    area.name != job.workingArea) {
                                  context.read<ScheduleProvider>().updateJob(
                                        job.copyWith(
                                          workAreaId: area.id,
                                          workingArea: area.name,
                                          customWorkArea: null,
                                        ),
                                      );
                                }
                              },
                              optionsBuilder:
                                  (TextEditingValue textEditingValue) {
                                if (textEditingValue.text.isEmpty) {
                                  return workAreas;
                                }
                                return workAreas.where((WorkArea area) {
                                  return area.name.toLowerCase().contains(
                                            textEditingValue.text.toLowerCase(),
                                          ) ||
                                      area.description.toLowerCase().contains(
                                            textEditingValue.text.toLowerCase(),
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
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    labelStyle: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium?.color,
                                    ),
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
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
                                                  fontSize: 12,
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
                            iconSize: 20,
                            onPressed: () async {
                              final result = await showDialog<List<LatLng>>(
                                context: context,
                                useSafeArea: true,
                                builder: (BuildContext context) =>
                                    Dialog.fullscreen(
                                  child: MapView(
                                    jobId: job.id,
                                    workAreaId: job.workAreaId,
                                    customWorkArea: job.customWorkArea,
                                    title: job.client,
                                    isEditable: true,
                                  ),
                                ),
                              );

                              if (result != null) {
                                final customWorkArea = WorkArea(
                                  id: job.id,
                                  name: 'Custom - ${job.client}',
                                  description:
                                      'Custom work area for ${job.client}',
                                  polygonPoints: result,
                                  kmlFileName: '',
                                  createdAt: DateTime.now(),
                                  updatedAt: DateTime.now(),
                                );

                                context.read<ScheduleProvider>().updateJob(
                                      job.copyWith(
                                        workAreaId: '',
                                        workingArea: 'Custom - ${job.client}',
                                        customWorkArea: customWorkArea,
                                      ),
                                    );
                              }
                            },
                          ),
                          // Map View Button
                          IconButton(
                            icon: const Icon(Icons.map, color: Colors.white),
                            constraints: const BoxConstraints(),
                            padding: EdgeInsets.zero,
                            iconSize: 20,
                            onPressed: () => _openMapLink(context),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),

            // Status Row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () => _openMapLink(context),
                  child: const Text(
                    'Open Map',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Change Status'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: JobStatus.values.map((status) {
                            return ListTile(
                              dense: true,
                              title: Text(status.name),
                              tileColor: status == job.status
                                  ? _getStatusColor()
                                  : null,
                              onTap: () {
                                context.read<ScheduleProvider>().updateJob(
                                      job.copyWith(status: status),
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
                    backgroundColor: _getStatusColor(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    job.status.name.toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
