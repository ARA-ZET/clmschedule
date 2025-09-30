import 'package:flutter/material.dart';
import '../models/collection_job.dart';
import '../models/job_list_item.dart';

/// Helper class to integrate collection schedule functionality with the existing job system
class CollectionJobIntegrationHelper {
  /// Check if a job type requires collection scheduling
  static bool requiresCollectionScheduling(JobType jobType) {
    return jobType == JobType.junkCollection ||
        jobType == JobType.furnitureMove;
  }

  /// Convert a JobListItem to a CollectionJob for collection scheduling
  static CollectionJob convertToCollectionJob(
    JobListItem jobListItem, {
    required VehicleType vehicleType,
    required TrailerType trailerType,
    required int timeSlot,
    List<String>? assignedStaff,
  }) {
    return CollectionJob(
      id: '', // Will be set by Firestore
      location: jobListItem.collectionAddress.isNotEmpty
          ? jobListItem.collectionAddress
          : jobListItem.area,
      vehicleType: vehicleType,
      trailerType: trailerType,
      date: jobListItem.collectionDate,
      timeSlot: timeSlot,
      assignedStaff: assignedStaff ?? [],
      staffCount: (jobListItem.manDays * 1)
          .round()
          .clamp(1, 10), // Estimate staff from man-days
      jobType: jobListItem.jobType.displayName,
      statusId: jobListItem.jobStatusId,
      clients: [jobListItem.client],
      notes: jobListItem.specialInstructions,
    );
  }

  /// Get suggested vehicle type based on job type and details
  static VehicleType getSuggestedVehicleType(JobListItem jobListItem) {
    final client = jobListItem.client.toLowerCase();
    final instructions = jobListItem.specialInstructions.toLowerCase();
    final combined = '$client $instructions';

    // Simple heuristics for vehicle suggestion
    if (combined.contains('large') ||
        combined.contains('big') ||
        combined.contains('furniture') ||
        jobListItem.manDays > 2.0) {
      return VehicleType.mahindra; // Larger vehicle for big jobs
    } else if (combined.contains('small') ||
        combined.contains('light') ||
        jobListItem.manDays < 1.0) {
      return VehicleType.nissan; // Smaller vehicle for light jobs
    } else {
      return VehicleType.hyundai; // Default middle option
    }
  }

  /// Get suggested trailer type based on job details
  static TrailerType getSuggestedTrailerType(JobListItem jobListItem) {
    final client = jobListItem.client.toLowerCase();
    final instructions = jobListItem.specialInstructions.toLowerCase();
    final combined = '$client $instructions';

    if (combined.contains('furniture') ||
        combined.contains('large items') ||
        jobListItem.manDays > 2.0) {
      return TrailerType.bigTrailer;
    } else if (combined.contains('junk') ||
        combined.contains('small items') ||
        jobListItem.manDays < 1.5) {
      return TrailerType.smallTrailer;
    } else {
      return TrailerType.noTrailer;
    }
  }

  /// Get suggested time slot based on job priority and type
  static int getSuggestedTimeSlot(JobListItem jobListItem) {
    final client = jobListItem.client.toLowerCase();

    // Morning slots (8-11) for residential/priority jobs
    if (client.contains('residential') ||
        client.contains('priority') ||
        client.contains('urgent')) {
      return 8; // 08:00
    }

    // Afternoon slots (12-16) for commercial/large jobs
    if (client.contains('commercial') ||
        client.contains('office') ||
        jobListItem.jobType == JobType.furnitureMove) {
      return 13; // 13:00
    }

    // Default to mid-morning
    return 10; // 10:00
  }

  /// Show a dialog to configure collection job details when creating from a regular job
  static Future<CollectionJob?> showCollectionJobConfigDialog(
    BuildContext context,
    JobListItem jobListItem,
  ) async {
    return await showDialog<CollectionJob>(
      context: context,
      builder: (context) =>
          _CollectionJobConfigDialog(jobListItem: jobListItem),
    );
  }
}

class _CollectionJobConfigDialog extends StatefulWidget {
  final JobListItem jobListItem;

  const _CollectionJobConfigDialog({required this.jobListItem});

  @override
  State<_CollectionJobConfigDialog> createState() =>
      _CollectionJobConfigDialogState();
}

class _CollectionJobConfigDialogState
    extends State<_CollectionJobConfigDialog> {
  late VehicleType _selectedVehicleType;
  late TrailerType _selectedTrailerType;
  late int _selectedTimeSlot;
  final _staffController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Initialize with suggested values
    _selectedVehicleType =
        CollectionJobIntegrationHelper.getSuggestedVehicleType(
            widget.jobListItem);
    _selectedTrailerType =
        CollectionJobIntegrationHelper.getSuggestedTrailerType(
            widget.jobListItem);
    _selectedTimeSlot =
        CollectionJobIntegrationHelper.getSuggestedTimeSlot(widget.jobListItem);
  }

  @override
  void dispose() {
    _staffController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Configure Collection Job'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Job: ${widget.jobListItem.client}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Text(
              'Collection Date: ${widget.jobListItem.collectionDate.day}/${widget.jobListItem.collectionDate.month}/${widget.jobListItem.collectionDate.year}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<VehicleType>(
              initialValue: _selectedVehicleType,
              decoration: const InputDecoration(
                labelText: 'Vehicle Type',
                border: OutlineInputBorder(),
              ),
              items: VehicleType.values.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(type.name.replaceFirstMapped(RegExp(r'^(\w)'),
                      (match) => match.group(1)!.toUpperCase())),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedVehicleType = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<TrailerType>(
              initialValue: _selectedTrailerType,
              decoration: const InputDecoration(
                labelText: 'Trailer Type',
                border: OutlineInputBorder(),
              ),
              items: TrailerType.values.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(type.name.replaceFirstMapped(RegExp(r'^(\w)'),
                      (match) => match.group(1)!.toUpperCase())),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedTrailerType = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _selectedTimeSlot,
              decoration: const InputDecoration(
                labelText: 'Time Slot',
                border: OutlineInputBorder(),
              ),
              items: List.generate(9, (index) => 8 + index).map((hour) {
                return DropdownMenuItem(
                  value: hour,
                  child: Text('${hour.toString().padLeft(2, '0')}:00'),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedTimeSlot = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _staffController,
              decoration: const InputDecoration(
                labelText: 'Assigned Staff (optional)',
                border: OutlineInputBorder(),
                hintText: 'John, Mary, Pete',
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final staff = _staffController.text
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();

            final collectionJob =
                CollectionJobIntegrationHelper.convertToCollectionJob(
              widget.jobListItem,
              vehicleType: _selectedVehicleType,
              trailerType: _selectedTrailerType,
              timeSlot: _selectedTimeSlot,
              assignedStaff: staff,
            );

            Navigator.of(context).pop(collectionJob);
          },
          child: const Text('Create Collection Job'),
        ),
      ],
    );
  }
}
