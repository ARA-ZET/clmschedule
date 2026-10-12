import 'package:flutter/material.dart';

import '../../models/zoho_invoice.dart';
import 'zoho_table.dart';

/// Colour-coded status label.
///
/// Zoho Books shows invoice status as flat coloured text rather than a filled
/// Material chip, so [dense] (the in-table form) renders bare coloured text
/// and the non-dense form adds a soft tint for use on the detail screen.
/// Void is struck through rather than colour-coded — it is an annulled
/// invoice, not a stage in the normal lifecycle.
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
    final label = Text(
      status.label.toUpperCase(),
      style: TextStyle(
        color: color,
        fontSize: dense ? 11 : 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
        decoration: status.isStruckThrough ? TextDecoration.lineThrough : null,
      ),
    );

    if (dense) return label;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: label,
    );
  }
}

/// Zoho-style status filter: a dropdown in the toolbar (e.g. "All Invoices"),
/// rather than a row of Material chips.
class ZohoStatusFilterDropdown extends StatelessWidget {
  final ZohoInvoiceStatus? value;
  final List<ZohoInvoiceStatus?> options;
  final String allLabel;
  final ValueChanged<ZohoInvoiceStatus?>? onChanged;

  const ZohoStatusFilterDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.allLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<ZohoInvoiceStatus?>(
        value: value,
        onChanged: onChanged,
        isDense: true,
        borderRadius: BorderRadius.circular(4),
        icon: const Icon(Icons.arrow_drop_down, color: ZohoPalette.textPrimary),
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: ZohoPalette.textPrimary,
        ),
        items: options
            .map((s) => DropdownMenuItem<ZohoInvoiceStatus?>(
                  value: s,
                  child: Text(
                    s?.label ?? allLabel,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: ZohoPalette.textPrimary,
                    ),
                  ),
                ))
            .toList(),
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

  /// Icon for the empty state. Defaults to an inbox; pass something closer to
  /// the content where one fits.
  final IconData emptyIcon;

  /// Optional way out of an empty list — "New customer", "Clear filters".
  /// An empty screen with nothing to do on it is a dead end.
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  const ZohoAsyncBody({
    super.key,
    required this.isLoading,
    required this.error,
    required this.isEmpty,
    required this.emptyMessage,
    required this.onRetry,
    required this.child,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyActionLabel,
    this.onEmptyAction,
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
              Icon(Icons.error_outline, size: 44, color: Colors.red.shade300),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.red.shade800),
                ),
              ),
              const SizedBox(height: 18),
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
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(emptyIcon, size: 44, color: ZohoPalette.border),
              const SizedBox(height: 14),
              Text(
                emptyMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: ZohoPalette.textMuted,
                ),
              ),
              if (emptyActionLabel != null && onEmptyAction != null) ...[
                const SizedBox(height: 18),
                ZohoNewButton(
                  label: emptyActionLabel!,
                  onPressed: onEmptyAction,
                ),
              ],
            ],
          ),
        ),
      );
    }

    return child;
  }
}
