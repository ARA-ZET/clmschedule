import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../providers/job_list_preferences_provider.dart';

/// Dialog for managing job list column visibility preferences
class JobListColumnsDialog extends riverpod.ConsumerStatefulWidget {
  const JobListColumnsDialog({super.key});

  @override
  riverpod.ConsumerState<JobListColumnsDialog> createState() =>
      _JobListColumnsDialogState();
}

class _JobListColumnsDialogState
    extends riverpod.ConsumerState<JobListColumnsDialog> {
  final Map<String, String> _columnLabels = {
    'date': 'Date',
    'client': 'Client',
    'jobStatus': 'Job Status',
    'invoiceStatus': 'Invoice Status',
    'jobType': 'Job Type',
    'area': 'Area',
    'quantity': 'Qty / Vehicle',
    'manDays': 'Man-Days',
    'collectionAddress': 'Collection Address',
    'specialInstructions': 'Special Instructions',
    'collectionDate': 'Collection Date',
    'invoice': 'Invoice',
    'amount': 'Amount',
    'quantityDistributed': 'Qty Distributed',
    'invoiceDetails': 'Invoice Details',
    'reportAddresses': 'Report Addresses',
    'whoToInvoice': 'Who to Invoice',
    'refresh': 'Refresh',
    'actions': 'Actions',
  };

  @override
  Widget build(BuildContext context) {
    final prefsProvider = ref.watch(jobListPreferencesRiverpod);
    final preferences = prefsProvider.preferences;
    if (preferences == null) {
      return const AlertDialog(
        title: Text('Column Preferences'),
        content: Center(child: CircularProgressIndicator()),
      );
    }

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.view_column, color: Colors.blue),
          const SizedBox(width: 8),
          const Expanded(child: Text('Customize Columns')),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Required columns cannot be hidden',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Required Columns'),
                  content: const Text(
                    'The following columns are always visible and cannot be hidden:\n\n'
                    '• Date\n'
                    '• Client\n'
                    '• Job Status\n'
                    '• Refresh\n'
                    '• Actions\n\n'
                    'All other columns can be shown or hidden based on your preference.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Got it'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      content: SizedBox(
        width: 450,
        height: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Summary
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                children: [
                  const Icon(Icons.visibility, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${prefsProvider.visibleColumnCount} visible, '
                      '${prefsProvider.hiddenColumnCount} hidden',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: prefsProvider.isLoading
                        ? null
                        : () async {
                            await prefsProvider.resetToDefaults();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Reset to default columns'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('Reset'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Column list
            Expanded(
              child: ListView(
                children: preferences.columnVisibility.keys.map((columnKey) {
                  final isVisible =
                      preferences.columnVisibility[columnKey] ?? true;
                  final canToggle = preferences.canToggleColumn(columnKey);
                  final label = _columnLabels[columnKey] ?? columnKey;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    elevation: isVisible ? 2 : 0,
                    color: isVisible ? Colors.white : Colors.grey.shade100,
                    child: CheckboxListTile(
                      title: Row(
                        children: [
                          Icon(
                            isVisible ? Icons.visibility : Icons.visibility_off,
                            size: 20,
                            color: isVisible ? Colors.green : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontWeight: isVisible
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: isVisible
                                    ? Colors.black
                                    : Colors.grey.shade600,
                              ),
                            ),
                          ),
                          if (!canToggle)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade100,
                                borderRadius: BorderRadius.circular(12),
                                border:
                                    Border.all(color: Colors.orange.shade300),
                              ),
                              child: const Text(
                                'Required',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orange,
                                ),
                              ),
                            ),
                        ],
                      ),
                      value: isVisible,
                      enabled: canToggle,
                      onChanged: canToggle
                          ? (value) async {
                              await prefsProvider
                                  .toggleColumnVisibility(columnKey);
                            }
                          : null,
                      activeColor: Colors.blue,
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (prefsProvider.error != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              prefsProvider.error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
