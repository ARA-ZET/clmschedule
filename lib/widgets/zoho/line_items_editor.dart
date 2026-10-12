import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/zoho_invoice.dart';
import '../../models/zoho_item.dart';
import '../../models/zoho_item_autofill.dart';
import '../../providers/zoho_item_autofill_provider.dart';
import 'zoho_item_picker.dart';
import 'zoho_table.dart';

/// Editable invoice line items — item name, description, quantity and rate,
/// laid out like Zoho's own item table.
///
/// Holds a controller per row so typing does not rebuild the whole list, and
/// reports edits upward via [onChanged]. Existing rows keep their
/// `line_item_id`, so an update amends them rather than replacing them.
class LineItemsEditor extends riverpod.ConsumerStatefulWidget {
  final List<ZohoLineItem> lineItems;
  final ValueChanged<List<ZohoLineItem>> onChanged;
  final bool enabled;

  /// Items the job type may bill as. Empty means the whole catalogue.
  final List<String> allowedItemIds;

  /// Job values substituted into an item's autofill templates.
  ///
  /// Supplied by the caller because only it knows the job — the editor is also
  /// used from the invoice screens, where there is no job and the templates
  /// simply render with empty values.
  final Map<ItemAutofillToken, String> tokens;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const LineItemsEditor({
    super.key,
    required this.orgId,
    required this.lineItems,
    required this.onChanged,
    this.enabled = true,
    this.allowedItemIds = const [],
    this.tokens = const {},
  });

  @override
  riverpod.ConsumerState<LineItemsEditor> createState() =>
      _LineItemsEditorState();
}

class _LineItemsEditorState extends riverpod.ConsumerState<LineItemsEditor> {
  late List<_RowControllers> _rows;

  @override
  void initState() {
    super.initState();
    _rows = widget.lineItems.map(_RowControllers.fromItem).toList();
    if (_rows.isEmpty) _rows.add(_RowControllers.empty());

    // Idempotent, so it does not matter that other editors may also ask.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(zohoItemAutofillRiverpod).ensureLoaded();
    });
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _emit() {
    widget.onChanged(_rows.map((r) => r.toItem()).toList());
  }

  void _addRow() {
    setState(() => _rows.add(_RowControllers.empty()));
    _emit();
  }

  void _removeRow(int index) {
    setState(() {
      _rows[index].dispose();
      _rows.removeAt(index);
      if (_rows.isEmpty) _rows.add(_RowControllers.empty());
    });
    _emit();
  }

  double get _subTotal => _rows.fold(0.0, (sum, r) => sum + r.toItem().amount);

  /// Fill a row from a catalogue item.
  ///
  /// Writes the controllers as well as the row's own fields — they were seeded
  /// when the row was built and would otherwise keep showing the previous text
  /// over the new values.
  ///
  /// Clearing the item unbinds the row but leaves what was typed: the wording
  /// is usually still wanted, and silently blanking three fields because a
  /// dropdown was reset to "None" would be its own surprise.
  void _applyItem(_RowControllers row, ZohoItem? item) {
    setState(() {
      if (item == null) {
        row.itemId = '';
        return;
      }
      row.itemId = item.itemId;
      row.unit = item.unit;

      // An item's configured template wins over the catalogue text — that is
      // the whole point of it. An empty template falls back, so an item nobody
      // has configured behaves exactly as before.
      final autofill = ref.read(zohoItemAutofillRiverpod).forItem(item.itemId);
      final name =
          ZohoItemAutofill.render(autofill?.nameTemplate ?? '', widget.tokens);
      final description = ZohoItemAutofill.render(
          autofill?.descriptionTemplate ?? '', widget.tokens);

      row.name.text = name.isNotEmpty ? name : item.displayName;
      row.description.text =
          description.isNotEmpty ? description : item.lineDescription;
      if (item.rate > 0) row.rate.text = item.rate.toStringAsFixed(2);
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: ZohoPalette.headerHeight,
          color: ZohoPalette.headerBackground,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: const Row(
            children: [
              Expanded(child: _Hdr('Item & description')),
              SizedBox(width: 70, child: _Hdr('Qty', right: true)),
              SizedBox(width: 110, child: _Hdr('Rate', right: true)),
              SizedBox(width: 110, child: _Hdr('Amount', right: true)),
              SizedBox(width: 36),
            ],
          ),
        ),
        for (var i = 0; i < _rows.length; i++) _buildRow(i, _rows[i], currency),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed: widget.enabled ? _addRow : null,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add line'),
              style: TextButton.styleFrom(
                foregroundColor: ZohoPalette.link,
                textStyle:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            const Spacer(),
            const Text('Sub total',
                style: TextStyle(fontSize: 12, color: ZohoPalette.textMuted)),
            const SizedBox(width: 12),
            Text(
              currency.format(_subTotal),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: ZohoPalette.textPrimary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRow(int index, _RowControllers row, NumberFormat currency) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: ZohoPalette.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Pulls the name, description and rate straight from Zoho's
                // item catalogue, so a standard service is not retyped — and
                // reads the same on the invoice as it does in the books.
                ZohoItemPicker(
                  orgId: widget.orgId,
                  value: row.itemId,
                  dense: true,
                  enabled: widget.enabled,
                  allowedItemIds: widget.allowedItemIds,
                  onChanged: (item) => _applyItem(row, item),
                ),
                _field(
                  controller: row.name,
                  hint: 'Item name',
                  weight: FontWeight.w500,
                ),
                const SizedBox(height: 2),
                _field(
                  controller: row.description,
                  hint: 'Description',
                  muted: true,
                  maxLines: 2,
                ),
              ],
            ),
          ),
          SizedBox(
            width: 70,
            child: _field(
              controller: row.quantity,
              hint: '1',
              align: TextAlign.right,
              numeric: true,
            ),
          ),
          SizedBox(
            width: 110,
            child: _field(
              controller: row.rate,
              hint: '0.00',
              align: TextAlign.right,
              numeric: true,
            ),
          ),
          SizedBox(
            width: 110,
            child: Padding(
              padding: const EdgeInsets.only(top: 8, right: 4),
              child: Text(
                currency.format(row.toItem().amount),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ZohoPalette.textPrimary,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 36,
            child: IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: ZohoPalette.textMuted,
              tooltip: 'Remove line',
              onPressed: widget.enabled ? () => _removeRow(index) : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    TextAlign align = TextAlign.left,
    bool numeric = false,
    bool muted = false,
    FontWeight? weight,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      enabled: widget.enabled,
      textAlign: align,
      maxLines: maxLines,
      keyboardType:
          numeric ? const TextInputType.numberWithOptions(decimal: true) : null,
      // Amount and sub total are derived, so they must follow every keystroke.
      onChanged: (_) {
        setState(() {});
        _emit();
      },
      style: TextStyle(
        fontSize: 13,
        fontWeight: weight,
        color: muted ? ZohoPalette.textMuted : ZohoPalette.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: muted ? 12 : 13,
          color: ZohoPalette.textMuted.withValues(alpha: 0.7),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 6),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: UnderlineInputBorder(
          borderSide:
              BorderSide(color: ZohoPalette.link.withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}

class _Hdr extends StatelessWidget {
  final String label;
  final bool right;

  const _Hdr(this.label, {this.right = false});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: right ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: ZohoPalette.textMuted,
        ),
      ),
    );
  }
}

/// Text controllers for one editable line, plus the Zoho ids that must
/// survive a round trip.
class _RowControllers {
  final String lineItemId;

  /// Not final: picking from the catalogue rebinds the row to a different item,
  /// and the id is what keeps the invoice line linked to it in Zoho.
  String itemId;

  String unit;
  final TextEditingController name;
  final TextEditingController description;
  final TextEditingController quantity;
  final TextEditingController rate;

  _RowControllers({
    required this.lineItemId,
    required this.itemId,
    required this.unit,
    required this.name,
    required this.description,
    required this.quantity,
    required this.rate,
  });

  factory _RowControllers.fromItem(ZohoLineItem item) {
    return _RowControllers(
      lineItemId: item.lineItemId,
      itemId: item.itemId,
      unit: item.unit,
      name: TextEditingController(text: item.name),
      description: TextEditingController(text: item.description),
      quantity: TextEditingController(text: _trimNumber(item.quantity)),
      rate: TextEditingController(text: item.rate.toStringAsFixed(2)),
    );
  }

  factory _RowControllers.empty() {
    return _RowControllers(
      lineItemId: '',
      itemId: '',
      unit: '',
      name: TextEditingController(),
      description: TextEditingController(),
      quantity: TextEditingController(text: '1'),
      rate: TextEditingController(),
    );
  }

  static String _trimNumber(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  ZohoLineItem toItem() {
    return ZohoLineItem(
      lineItemId: lineItemId,
      itemId: itemId,
      unit: unit,
      name: name.text.trim(),
      description: description.text.trim(),
      quantity: double.tryParse(quantity.text.trim()) ?? 0,
      rate: double.tryParse(rate.text.trim()) ?? 0,
    );
  }

  void dispose() {
    name.dispose();
    description.dispose();
    quantity.dispose();
    rate.dispose();
  }
}
