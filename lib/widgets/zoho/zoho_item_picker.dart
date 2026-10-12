import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/zoho_item.dart';
import '../../providers/zoho_items_provider.dart';

/// Picks an entry from Zoho Books' item catalogue.
///
/// The Zoho counterpart to `XeroItemPicker`, deliberately identical in shape
/// and behaviour. Reads through [zohoItemsRiverpod], which loads the catalogue
/// once per session.
///
/// Selecting nothing is a first-class choice: a job type or a line with no item
/// bills as free text, which is how everything worked before items existed.
/// Value used by the "show all items" row. Not a real item id, and chosen so
/// it cannot collide with Zoho's numeric ones.
const String _kShowAllSentinel = '__show_all__';

class ZohoItemPicker extends riverpod.ConsumerStatefulWidget {
  /// Currently selected Zoho `item_id`, or empty for none.
  final String value;

  final ValueChanged<ZohoItem?> onChanged;

  final String label;
  final String? helperText;

  /// Strips the label and border down for use inside a table row.
  final bool dense;

  final bool enabled;

  /// Item ids this job type may bill as. Empty means no restriction.
  ///
  /// Narrows a long price list to the handful that suit the work. Never a hard
  /// limit: the picker offers a way to see everything, because the person
  /// raising the invoice knows more about this job than the job type does.
  final List<String> allowedItemIds;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const ZohoItemPicker({
    super.key,
    required this.orgId,
    required this.value,
    required this.onChanged,
    this.label = 'Item',
    this.helperText,
    this.dense = false,
    this.enabled = true,
    this.allowedItemIds = const [],
  });

  @override
  riverpod.ConsumerState<ZohoItemPicker> createState() =>
      _ZohoItemPickerState();
}

class _ZohoItemPickerState extends riverpod.ConsumerState<ZohoItemPicker> {
  /// Set once the user asks to see the whole catalogue.
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    // Safe from every instance — ensureLoaded is idempotent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(zohoItemsRiverpod(widget.orgId)).ensureLoaded();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(zohoItemsRiverpod(widget.orgId));
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);

    final restricted = widget.allowedItemIds.isNotEmpty && !_showAll;
    final items = restricted
        ? provider.items
            .where((i) =>
                widget.allowedItemIds.contains(i.itemId) ||
                // The current selection always stays visible, or changing any
                // other field would silently drop it.
                i.itemId == widget.value)
            .toList()
        : provider.items;
    final hiddenCount = provider.items.length - items.length;

    // A stored id whose item has since been deleted must not silently become
    // "None" — DropdownButtonFormField also asserts when its value matches no
    // item. Both are handled by carrying the orphan as its own entry.
    final known = items.any((i) => i.itemId == widget.value);
    final orphaned = widget.value.isNotEmpty && !known && provider.hasLoaded;

    return DropdownButtonFormField<String>(
      initialValue: widget.value.isEmpty ? '' : widget.value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: widget.dense ? null : widget.label,
        // The provider's message, not just "unavailable". A catalogue that
        // will not load is usually a scope or configuration problem, and
        // hiding what Zoho actually said makes it unguessable.
        helperText: provider.error ??
            (orphaned
                ? 'This item no longer exists in Zoho.'
                : widget.helperText),
        helperMaxLines: 3,
        helperStyle: TextStyle(
          fontSize: 11,
          color: (provider.error != null || orphaned)
              ? Colors.orange.shade900
              : null,
        ),
        isDense: true,
        border: widget.dense ? InputBorder.none : const OutlineInputBorder(),
        contentPadding: widget.dense
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : null,
      ),
      style: const TextStyle(fontSize: 13),
      onChanged: !widget.enabled || provider.isLoading
          ? null
          : (id) {
              if (id == _kShowAllSentinel) {
                setState(() => _showAll = true);
                return;
              }
              if (id == null || id.isEmpty) {
                widget.onChanged(null);
                return;
              }
              widget.onChanged(provider.byId(id));
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
              'Missing item (${widget.value})',
              style: TextStyle(fontSize: 13, color: Colors.orange.shade900),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        for (final item in items)
          DropdownMenuItem<String>(
            value: item.itemId,
            child: Text(
              item.rate > 0
                  ? '${item.displayLabel}  ·  ${currency.format(item.rate)}'
                  : item.displayLabel,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        // An escape from the job type's shortlist. Selecting it does not change
        // the item — it widens the list and reopens.
        if (hiddenCount > 0)
          DropdownMenuItem<String>(
            value: _kShowAllSentinel,
            child: Text(
              'Show all items ($hiddenCount more)…',
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: Colors.blue.shade700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
