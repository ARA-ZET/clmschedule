import 'package:flutter/material.dart';

import '../../models/zoho_invoice.dart';

/// Colour-coded chip for a Zoho invoice status.
/// Void is shown struck through rather than colour-coded, since it is an
/// annulled invoice rather than a stage in the normal lifecycle.
class ZohoStatusChip extends StatelessWidget {
  final ZohoInvoiceStatus status;
  final bool dense;

  const ZohoStatusChip({
    super.key,
    required this.status,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 10,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: color,
          fontSize: dense ? 11 : 12,
          fontWeight: FontWeight.w600,
          decoration:
              status.isStruckThrough ? TextDecoration.lineThrough : null,
        ),
      ),
    );
  }
}

/// Shared empty/error/loading scaffolding for the Zoho screens, so every async
/// call surfaces its failure instead of rendering a blank list.
class ZohoAsyncBody extends StatelessWidget {
  final bool isLoading;
  final String? error;
  final bool isEmpty;
  final String emptyMessage;
  final Future<void> Function() onRetry;
  final Widget child;

  const ZohoAsyncBody({
    super.key,
    required this.isLoading,
    required this.error,
    required this.isEmpty,
    required this.emptyMessage,
    required this.onRetry,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: Colors.red.shade400),
              const SizedBox(height: 12),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Show the spinner only on the first load; later refreshes keep the list
    // visible underneath the app bar's progress indicator.
    if (isLoading && isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    return child;
  }
}
