import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/schedule_provider.dart';

/// Debug widget to show schedule statistics and controls
class CacheDebugWidget extends StatelessWidget {
  const CacheDebugWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ScheduleProvider>(
      builder: (context, scheduleProvider, child) {
        return ExpansionTile(
          title: const Text('Schedule Debug Info'),
          leading: const Icon(Icons.info),
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Schedule Information:',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(
                      '  Current Month: ${scheduleProvider.currentMonthDisplay}'),
                  Text(
                      '  Current Month Jobs: ${scheduleProvider.currentMonthJobs.length}'),
                  Text(
                      '  Next Month Jobs: ${scheduleProvider.nextMonthJobs.length}'),
                  Text('  Total Jobs: ${scheduleProvider.jobs.length}'),
                  Text(
                      '  Distributors: ${scheduleProvider.distributors.length}'),
                  Text('  Work Areas: ${scheduleProvider.workAreas.length}'),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          scheduleProvider.goToCurrentMonth();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Navigated to current month')),
                          );
                        },
                        child: const Text('Go to Current Month'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () async {
                          final availableMonths =
                              await scheduleProvider.getAvailableMonths();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      'Available months: ${availableMonths.length}')),
                            );
                          }
                        },
                        child: const Text('Check Available Months'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
