// widgets/job_list_status_views.dart
//
// What the Job List tab shows when loading or saving goes wrong, worded for
// non-technical users. The raw Firebase error sits behind "Technical
// details" for whoever has to debug it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen state for when there is no Job List data to show at all:
/// either reconnecting ([reconnecting]) or failed ([message]).
class JobListLoadProblem extends StatelessWidget {
  final bool reconnecting;
  final String? message;
  final String? detail;
  final VoidCallback onRetry;

  const JobListLoadProblem({
    super.key,
    required this.reconnecting,
    required this.message,
    required this.detail,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (reconnecting)
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              else
                Icon(Icons.cloud_off, size: 56, color: Colors.orange.shade700),
              const SizedBox(height: 16),
              Text(
                reconnecting
                    ? 'Reconnecting to the Job List…'
                    : "Couldn't load the Job List",
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                reconnecting
                    ? 'The connection dropped for a moment. This usually '
                        'takes a few seconds — no need to do anything.'
                    : message ?? '',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (!reconnecting) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Try again'),
                ),
              ],
              if (!reconnecting && detail != null) ...[
                const SizedBox(height: 16),
                TechnicalDetails(detail: detail!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A strip above the Job List grid for problems that leave the list usable:
/// the connection dropping (the last loaded data stays on screen), loading
/// failing after data was already shown, or a save failing.
class JobListStatusBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String message;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;
  final bool busy;

  const JobListStatusBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
    this.detail,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Color.alphaBlend(color.withAlpha(28), Colors.white),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: color.withAlpha(90))),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            if (busy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 13)),
            ),
            if (detail != null)
              IconButton(
                tooltip: 'Technical details',
                icon: const Icon(Icons.info_outline, size: 18),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Technical details'),
                    content: TechnicalDetails(detail: detail!, expanded: true),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
            if (actionLabel != null && onAction != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            if (onDismiss != null)
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close, size: 18),
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }
}

/// The raw error, collapsed by default, with a copy button — for passing on
/// to whoever maintains the app.
class TechnicalDetails extends StatelessWidget {
  final String detail;
  final bool expanded;

  const TechnicalDetails({
    super.key,
    required this.detail,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SelectableText(
            detail,
            style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: Colors.grey.shade700),
          ),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy, size: 16),
          onPressed: () => Clipboard.setData(ClipboardData(text: detail)),
        ),
      ],
    );
    if (expanded) return body;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        title: Text('Technical details',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        children: [body],
      ),
    );
  }
}
