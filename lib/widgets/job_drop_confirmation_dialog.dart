import 'package:flutter/material.dart';
import '../models/job.dart';

enum DropAction { swap, addToExisting }

class JobDropConfirmationDialog extends StatelessWidget {
  final Job draggedJob;
  final Job? targetJob;
  final String distributorName;
  final DateTime targetDate;

  const JobDropConfirmationDialog({
    super.key,
    required this.draggedJob,
    this.targetJob,
    required this.distributorName,
    required this.targetDate,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasTargetJob = targetJob != null;

    return AlertDialog(
      title:
          Text(hasTargetJob ? 'Job Drop - Choose Action' : 'Confirm Job Move'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Dragged job info
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Moving Job:',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text('Clients: ${draggedJob.clientsDisplay}'),
                    Text('Work Areas: ${draggedJob.workingAreasDisplay}'),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Target info
            Card(
              color: Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Target:',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text('Distributor: $distributorName'),
                    Text(
                        'Date: ${targetDate.day}/${targetDate.month}/${targetDate.year}'),
                  ],
                ),
              ),
            ),

            if (hasTargetJob) ...[
              const SizedBox(height: 8),
              // Existing job info
              Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Existing Job in Target:',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text('Clients: ${targetJob!.clientsDisplay}'),
                      Text('Work Areas: ${targetJob!.workingAreasDisplay}'),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
              Text(
                'Choose an action:',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              Text(
                'This will move the job to the selected distributor and date.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ]
          ],
        ),
      ),
      actions: hasTargetJob
          ? [
              // Cancel
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel'),
              ),
              // Swap
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pop(DropAction.swap),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Swap Jobs'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
              // Add/Merge
              ElevatedButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(DropAction.addToExisting),
                icon: const Icon(Icons.add),
                label: const Text('Combine Jobs'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(DropAction.swap),
                child: const Text('Move Job'),
              ),
            ],
    );
  }
}
