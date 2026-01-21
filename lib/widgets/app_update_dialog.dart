import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/app_version.dart';

class AppUpdateDialog extends StatelessWidget {
  final AppVersion newVersion;
  final String currentVersion;
  final bool forceUpdate;

  const AppUpdateDialog({
    super.key,
    required this.newVersion,
    required this.currentVersion,
    this.forceUpdate = true,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !forceUpdate,
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              forceUpdate ? Icons.system_update : Icons.info_outline,
              color: forceUpdate ? Colors.orange : Colors.blue,
              size: 32,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Update Available'),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              forceUpdate
                  ? 'A new version of the app is available and must be installed.'
                  : 'A new version of the app is available.',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            _buildInfoRow('Current Version', currentVersion),
            const SizedBox(height: 8),
            _buildInfoRow('New Version', newVersion.version),
            const SizedBox(height: 8),
            _buildInfoRow(
              'Updated',
              DateFormat('MMM d, yyyy \'at\' h:mm a')
                  .format(newVersion.lastUpdated),
            ),
            if (newVersion.updateMessage != null) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'Update Notes:',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                newVersion.updateMessage!,
                style: const TextStyle(fontSize: 14),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    forceUpdate ? Colors.orange.shade50 : Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: forceUpdate ? Colors.orange : Colors.blue,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.refresh,
                    color: forceUpdate ? Colors.orange : Colors.blue,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Click "Refresh Now" to reload the app and get the latest version.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (!forceUpdate)
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Later'),
            ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh Now'),
            style: ElevatedButton.styleFrom(
              backgroundColor: forceUpdate ? Colors.orange : Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            '$label:',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ],
    );
  }
}
