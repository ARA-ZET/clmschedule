import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/xero_org.dart';
import '../../providers/xero_items_provider.dart';

/// Picks an entry from Xero's Products & Services catalogue.
///
/// Reads through [xeroItemsRiverpod], which loads the catalogue once per
/// session — this widget appears on every invoice line, so fetching per
/// instance would be a fast way through the 1,000-call daily budget.
///
/// Selecting nothing is a first-class choice, not an error: a job type or a
/// line with no item bills as free text at the company's default account and
/// tax rate, which is how everything worked before items existed.
class XeroItemPicker extends riverpod.ConsumerStatefulWidget {
  /// Currently selected item code, or empty for none.
  final String value;

  final ValueChanged<XeroItem?> onChanged;

  final String label;

  /// Shown under the field. Null for the compact in-table variant.
  final String? helperText;

  /// Strips the label and border down for use inside a table row.
  final bool dense;

  final bool enabled;

  const XeroItemPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Item',
    this.helperText,
    this.dense = false,
    this.enabled = true,
  });

  @override
  riverpod.ConsumerState<XeroItemPicker> createState() =>
      _XeroItemPickerState();
}

class _XeroItemPickerState extends riverpod.ConsumerState<XeroItemPicker> {
  @override
  void initState() {
    super.initState();
    // Safe to call from every instance — ensureLoaded is idempotent and the
    // second caller gets the first one's result.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(xeroItemsRiverpod).ensureLoaded();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(xeroItemsRiverpod);
    final items = provider.items;
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);

    // A stored code whose item has since been deleted in Xero must not silently
    // become "None" — DropdownButtonFormField also asserts when its value
    // matches no item. Both are handled by carrying the orphan as its own entry.
    final known = items.any((i) => i.code == widget.value);
    final orphaned = widget.value.isNotEmpty && !known && provider.hasLoaded;

    return DropdownButtonFormField<String>(
      initialValue: widget.value.isEmpty ? '' : widget.value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: widget.dense ? null : widget.label,
        // The provider's message, not just "unavailable". A catalogue that
        // will not load is usually a scope or configuration problem, and
        // hiding what Xero actually said makes it unguessable.
        helperText: provider.error ??
            (orphaned
                ? 'Item "${widget.value}" no longer exists in Xero.'
                : widget.helperText),
        helperMaxLines: 3,
        helperStyle: TextStyle(
          fontSize: 11,
          color: (provider.error != null || orphaned)
              ? Colors.orange.shade900
              : null,
        ),
        isDense: true,
        border: widget.dense
            ? InputBorder.none
            : const OutlineInputBorder(),
        contentPadding: widget.dense
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : null,
      ),
      style: const TextStyle(fontSize: 13),
      onChanged: !widget.enabled || provider.isLoading
          ? null
          : (code) {
              if (code == null || code.isEmpty) {
                widget.onChanged(null);
                return;
              }
              widget.onChanged(provider.byCode(code));
            },
      items: [
        DropdownMenuItem<String>(
          value: '',
          child: Text(
            provider.isLoading
                ? 'Loading items…'
                : provider.error != null
                    ? 'Items unavailable — free text'
                    : 'None — free text',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (orphaned)
          DropdownMenuItem<String>(
            value: widget.value,
            child: Text(
              '${widget.value} (missing)',
              style: TextStyle(fontSize: 13, color: Colors.orange.shade900),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        for (final item in items)
          DropdownMenuItem<String>(
            value: item.code,
            child: Text(
              item.unitPrice > 0
                  ? '${item.displayLabel}  ·  ${currency.format(item.unitPrice)}'
                  : item.displayLabel,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
