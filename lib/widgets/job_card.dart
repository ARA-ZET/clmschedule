import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/job.dart';
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MapView(
          initialLocation: job.mapLink,
          title: '${job.client} - ${job.workingArea}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(2),
      color: _getStatusColor(),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EditableTextField(
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

              EditableTextField(
                initialValue: job.workingArea,
                onChanged: (value) {
                  if (value != job.workingArea) {
                    context.read<ScheduleProvider>().updateJob(
                      job.copyWith(workingArea: value),
                    );
                  }
                },
                hintText: 'Working Area',
              ),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: () => _openMapLink(context),
                    child: Text(
                      'Open Map',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      // Show status change dialog
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Change Status'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: JobStatus.values.map((status) {
                              return ListTile(
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
      ),
    );
  }
}
