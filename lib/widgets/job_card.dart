import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/job.dart';
import '../providers/schedule_provider.dart';
import 'editable_text_field.dart';

class JobCard extends StatelessWidget {
  final Job job;

  const JobCard({
    super.key,
    required this.job,
  });

  Color _getStatusColor() {
    switch (job.status) {
      case JobStatus.scheduled:
        return Colors.green;
      case JobStatus.inProgress:
        return Colors.purple;
      case JobStatus.completed:
        return Colors.blue;
    }
  }

  Future<void> _openMapLink() async {
    final Uri url = Uri.parse(job.mapLink);
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(4),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: _getStatusColor(),
            width: 2,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
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
              const SizedBox(height: 4),
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
              const SizedBox(height: 4),
              GestureDetector(
                onTap: _openMapLink,
                child: Text(
                  'Open Map',
                  style: TextStyle(
                    color: Colors.blue[700],
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${job.startTime.hour}:${job.startTime.minute.toString().padLeft(2, '0')} - '
                '${job.endTime.hour}:${job.endTime.minute.toString().padLeft(2, '0')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}