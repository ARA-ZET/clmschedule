import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/zoho_invoice.dart';
import '../../providers/zoho_invoices_provider.dart';
import 'line_items_editor.dart';
import 'zoho_table.dart';

/// Edit an existing Zoho invoice's line items, notes and reference.
///
/// Zoho rejects edits to paid and void invoices, so the caller should only
/// offer this for editable ones.
class EditInvoiceDialog extends riverpod.ConsumerStatefulWidget {
  final ZohoInvoice invoice;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const EditInvoiceDialog({
    super.key,
    required this.orgId,
    required this.invoice,
  });

  @override
  riverpod.ConsumerState<EditInvoiceDialog> createState() =>
      _EditInvoiceDialogState();
}

class _EditInvoiceDialogState
    extends riverpod.ConsumerState<EditInvoiceDialog> {
  late List<ZohoLineItem> _lineItems;
  late final TextEditingController _referenceController;
  late final TextEditingController _notesController;

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
      await ref.read(zohoInvoicesRiverpod(widget.orgId)).updateInvoice(
            widget.invoice.invoiceId,
            updated.toUpdateJson(),
          );
      if (mounted) Navigator.of(context).pop(true);
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
    return AlertDialog(
      backgroundColor: ZohoPalette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      title: Text(
        'Edit ${widget.invoice.invoiceNumber}',
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ZohoPalette.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.invoice.customerName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ZohoPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              LineItemsEditor(
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
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ZohoNewButton(
          label: _isSaving ? 'Saving…' : 'Save',
          icon: null,
          onPressed: _isSaving ? null : _save,
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
