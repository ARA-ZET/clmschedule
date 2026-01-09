import 'package:flutter/material.dart';
import 'dart:html' as html;

/// Dialog to notify users about a new version and reload the app
class NewVersionDialog extends StatelessWidget {
  final String newVersion;

  const NewVersionDialog({Key? key, required this.newVersion}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update, color: Theme.of(context).primaryColor),
          const SizedBox(width: 8),
          const Text('Update Available'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'A new version ($newVersion) is available.',
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            'Please reload the page to get the latest features and bug fixes.',
            style: TextStyle(fontSize: 14),
          ),
        ],
      ),
      actions: [
        ElevatedButton.icon(
          onPressed: () {
            // Force reload the page and clear cache
            html.window.location.reload();
          },
          icon: const Icon(Icons.refresh),
          label: const Text('Reload Now'),
        ),
      ],
    );
  }
}
