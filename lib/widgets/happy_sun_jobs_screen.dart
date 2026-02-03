import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/happy_sun_project.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/scale_provider.dart';

class HappySunJobsScreen extends StatefulWidget {
  const HappySunJobsScreen({super.key});

  @override
  State<HappySunJobsScreen> createState() => _HappySunJobsScreenState();
}

class _HappySunJobsScreenState extends State<HappySunJobsScreen> {
  @override
  void initState() {
    super.initState();
    // Load jobs for current month when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<HappySunProjectProvider>();
      final now = DateTime.now();
      provider.setMonth(now.year, now.month);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<HappySunProjectProvider, ScaleProvider>(
      builder: (context, jobProvider, scaleProvider, child) {
        if (jobProvider.isLoading) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading Happy Sun jobs...'),
              ],
            ),
          );
        }

        if (jobProvider.error != null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Error: ${jobProvider.error}'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    final now = DateTime.now();
                    jobProvider.setMonth(now.year, now.month);
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        final projects = jobProvider.projects;

        if (projects.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.wb_sunny,
                  size: 64,
                  color: Colors.orange.shade300,
                ),
                const SizedBox(height: 16),
                const Text(
                  'No Happy Sun Jobs',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Window cleaning and solar panel cleaning jobs\nwill appear here',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            // Header with month selector
            _buildHeader(jobProvider, scaleProvider),
            // Jobs list
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.all(16 * scaleProvider.scale),
                itemCount: projects.length,
                itemBuilder: (context, index) {
                  return _buildJobCard(projects[index], scaleProvider);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(
      HappySunProjectProvider provider, ScaleProvider scaleProvider) {
    final currentMonth = provider.currentMonth;
    final monthFormat = DateFormat('MMMM yyyy');

    return Container(
      padding: EdgeInsets.all(16 * scaleProvider.scale),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              final newMonth = DateTime(
                currentMonth.year,
                currentMonth.month - 1,
              );
              provider.setMonth(newMonth.year, newMonth.month);
            },
          ),
          Expanded(
            child: Text(
              monthFormat.format(currentMonth),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18 * scaleProvider.scale,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              final newMonth = DateTime(
                currentMonth.year,
                currentMonth.month + 1,
              );
              provider.setMonth(newMonth.year, newMonth.month);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildJobCard(HappySunProject project, ScaleProvider scaleProvider) {
    final dateFormat = DateFormat('EEE, MMM d, yyyy');

    return Card(
      margin: EdgeInsets.only(bottom: 12 * scaleProvider.scale),
      child: Padding(
        padding: EdgeInsets.all(16 * scaleProvider.scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Icon(
                  project.jobType == 'windowCleaning'
                      ? Icons.cleaning_services
                      : Icons.solar_power,
                  color: Colors.orange,
                  size: 24 * scaleProvider.scale,
                ),
                SizedBox(width: 8 * scaleProvider.scale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.jobType == 'windowCleaning'
                            ? 'Window Cleaning'
                            : 'Solar Panel Cleaning',
                        style: TextStyle(
                          fontSize: 16 * scaleProvider.scale,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        dateFormat.format(project.scheduledDate),
                        style: TextStyle(
                          fontSize: 14 * scaleProvider.scale,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusChip(project.statusId, scaleProvider),
              ],
            ),

            if (project.toolsUsedCategorized != null &&
                project.toolsUsedCategorized!.allTools.isNotEmpty) ...[
              SizedBox(height: 12 * scaleProvider.scale),
              const Divider(),
              SizedBox(height: 8 * scaleProvider.scale),
              Text(
                'Tools Used',
                style: TextStyle(
                  fontSize: 14 * scaleProvider.scale,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8 * scaleProvider.scale),
              Wrap(
                spacing: 8 * scaleProvider.scale,
                runSpacing: 8 * scaleProvider.scale,
                children: project.toolsUsedCategorized!.allTools.map((tool) {
                  return Chip(
                    label: Text(
                      '${tool.baseName} (${tool.totalQuantity})',
                      style: TextStyle(fontSize: 12 * scaleProvider.scale),
                    ),
                    backgroundColor: Colors.blue.shade50,
                  );
                }).toList(),
              ),
            ],

            if (project.teamMemberIds.isNotEmpty) ...[
              SizedBox(height: 12 * scaleProvider.scale),
              const Divider(),
              SizedBox(height: 8 * scaleProvider.scale),
              Text(
                'Team Members',
                style: TextStyle(
                  fontSize: 14 * scaleProvider.scale,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8 * scaleProvider.scale),
              Wrap(
                spacing: 8 * scaleProvider.scale,
                runSpacing: 8 * scaleProvider.scale,
                children: project.teamMemberIds.map((member) {
                  return Chip(
                    avatar: const CircleAvatar(
                      child: Icon(Icons.person, size: 16),
                    ),
                    label: Text(
                      member,
                      style: TextStyle(fontSize: 12 * scaleProvider.scale),
                    ),
                    backgroundColor: Colors.green.shade50,
                  );
                }).toList(),
              ),
            ],

            if (project.startTime != null || project.endTime != null) ...[
              SizedBox(height: 12 * scaleProvider.scale),
              const Divider(),
              SizedBox(height: 8 * scaleProvider.scale),
              Row(
                children: [
                  if (project.startTime != null) ...[
                    Icon(
                      Icons.access_time,
                      size: 16 * scaleProvider.scale,
                      color: Colors.grey[600],
                    ),
                    SizedBox(width: 4 * scaleProvider.scale),
                    Text(
                      'Start: ${DateFormat('HH:mm').format(project.startTime!)}',
                      style: TextStyle(
                        fontSize: 12 * scaleProvider.scale,
                        color: Colors.grey[600],
                      ),
                    ),
                    SizedBox(width: 16 * scaleProvider.scale),
                  ],
                  if (project.endTime != null) ...[
                    Icon(
                      Icons.access_time_filled,
                      size: 16 * scaleProvider.scale,
                      color: Colors.grey[600],
                    ),
                    SizedBox(width: 4 * scaleProvider.scale),
                    Text(
                      'End: ${DateFormat('HH:mm').format(project.endTime!)}',
                      style: TextStyle(
                        fontSize: 12 * scaleProvider.scale,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ],
              ),
            ],

            if (project.notes != null && project.notes!.isNotEmpty) ...[
              SizedBox(height: 12 * scaleProvider.scale),
              const Divider(),
              SizedBox(height: 8 * scaleProvider.scale),
              Text(
                'Notes',
                style: TextStyle(
                  fontSize: 14 * scaleProvider.scale,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 4 * scaleProvider.scale),
              Text(
                project.notes!,
                style: TextStyle(
                  fontSize: 12 * scaleProvider.scale,
                  color: Colors.grey[700],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(String statusId, ScaleProvider scaleProvider) {
    Color color;
    String label;

    // Map common status IDs to colors (you can expand this)
    switch (statusId.toLowerCase()) {
      case 'completed':
      case 'job_done':
        color = Colors.green;
        label = 'Completed';
        break;
      case 'in_progress':
      case 'job_under_way':
        color = Colors.blue;
        label = 'In Progress';
        break;
      case 'scheduled':
        color = Colors.orange;
        label = 'Scheduled';
        break;
      default:
        color = Colors.grey;
        label = statusId.replaceAll('_', ' ');
        label = label[0].toUpperCase() + label.substring(1);
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scaleProvider.scale,
        vertical: 6 * scaleProvider.scale,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12 * scaleProvider.scale,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
