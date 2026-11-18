import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/zoho_invoice.dart';
import '../../providers/zoho_invoices_provider.dart';
import 'line_items_editor.dart';
import 'zoho_table.dart';

/// Edit an existing Zoho invoice's line items, notes and reference, and save
/// it to Zoho.
///
/// The one editor for this: [EditInvoiceDialog] wraps it on the invoice
/// screens, and the distribution report embeds it under its preview, so a
/// change here shows up in both.
///
/// Zoho rejects edits to paid and void invoices, so callers only offer it
/// for editable ones.
class ZohoInvoiceEditor extends riverpod.ConsumerStatefulWidget {
  final ZohoInvoice invoice;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  /// Called with Zoho's copy of the invoice once it is saved.
  final ValueChanged<ZohoInvoice> onSaved;

  /// Shows a Cancel button when given.
  final VoidCallback? onCancel;

  const ZohoInvoiceEditor({
    super.key,
    required this.orgId,
    required this.invoice,
    required this.onSaved,
    this.onCancel,
  });

  @override
  riverpod.ConsumerState<ZohoInvoiceEditor> createState() =>
      ZohoInvoiceEditorState();
}

class ZohoInvoiceEditorState extends riverpod.ConsumerState<ZohoInvoiceEditor> {
  late List<ZohoLineItem> _lineItems;
  late final TextEditingController _referenceController;
  late final TextEditingController _notesController;

  /// Bumped when the lines are replaced from outside. [LineItemsEditor]
  /// seeds its fields once, so it is rebuilt under a new key.
  int _seedGeneration = 0;

  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lineItems = List.of(widget.invoice.lineItems);
    _referenceController =
        TextEditingController(text: widget.invoice.referenceNumber);
    _notesController = TextEditingController(text: widget.invoice.notes);
  }

  @override
  void dispose() {
    _referenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Rewrite every line's description in the editor — nothing is saved until
  /// the user saves. Given the line's item name and description. Used to add
  /// the personnel to a report's invoice.
  void rewriteDescriptions(
      String Function(String itemName, String description) rewrite) {
    setState(() {
      _lineItems = [
        for (final l in _lineItems)
          l.copyWith(description: rewrite(l.name, l.description)),
      ];
      _seedGeneration++;
    });
  }

  Future<void> _save() async {
    final usable = _lineItems
        .where((li) => li.name.isNotEmpty && li.quantity > 0)
        .toList();

    if (usable.isEmpty) {
      setState(
          () => _error = 'Add at least one line item with a name and qty.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    // Rebuilt from the original so customer, number and dates are unchanged;
    // line items keep their line_item_id so Zoho amends rather than replaces.
    final updated = ZohoInvoice(
      invoiceId: widget.invoice.invoiceId,
      invoiceNumber: widget.invoice.invoiceNumber,
      customerId: widget.invoice.customerId,
      date: widget.invoice.date,
      dueDate: widget.invoice.dueDate,
      referenceNumber: _referenceController.text.trim(),
      notes: _notesController.text.trim(),
      lineItems: usable,
    );

    try {
      final saved = await ref
          .read(zohoInvoicesRiverpod(widget.orgId))
          .updateInvoice(widget.invoice.invoiceId, updated.toUpdateJson());
      if (!mounted) return;
      setState(() => _isSaving = false);
      widget.onSaved(saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LineItemsEditor(
          key: ValueKey('lines_$_seedGeneration'),
          orgId: widget.orgId,
          lineItems: _lineItems,
          enabled: !_isSaving,
          onChanged: (items) => _lineItems = items,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _referenceController,
          enabled: !_isSaving,
          style: const TextStyle(fontSize: 13),
          decoration: _decoration('Reference number'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notesController,
          enabled: !_isSaving,
          maxLines: 3,
          style: const TextStyle(fontSize: 13),
          decoration: _decoration('Notes (printed on the invoice)'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.onCancel != null)
              TextButton(
                onPressed: _isSaving ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            const SizedBox(width: 8),
            ZohoNewButton(
              label: _isSaving ? 'Saving…' : 'Save to Zoho',
              icon: null,
              onPressed: _isSaving ? null : _save,
            ),
          ],
        ),
      ],
    );
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 13),
      isDense: true,
      filled: true,
      fillColor: ZohoPalette.surface,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.link),
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
    );
  }
}
