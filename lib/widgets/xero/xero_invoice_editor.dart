import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/company.dart';
import '../../models/xero_invoice.dart';
import '../../providers/company_provider.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/accounting_error.dart';
import 'xero_line_items_editor.dart';
import 'xero_ui.dart';

/// Edit an existing Xero invoice's lines, reference and due date, and save
/// it to Xero.
///
/// The one editor for this: [XeroEditInvoiceDialog] wraps it on the invoice
/// screens, and the distribution report embeds it under its preview, so a
/// change here shows up in both.
///
/// Only for invoices with nothing paid — Xero rejects an amendment once a
/// payment or credit note is allocated.
class XeroInvoiceEditor extends riverpod.ConsumerStatefulWidget {
  final XeroInvoice invoice;

  /// Called with Xero's copy of the invoice once it is saved.
  final ValueChanged<XeroInvoice> onSaved;

  /// Shows a Cancel button when given.
  final VoidCallback? onCancel;

  const XeroInvoiceEditor({
    super.key,
    required this.invoice,
    required this.onSaved,
    this.onCancel,
  });

  @override
  riverpod.ConsumerState<XeroInvoiceEditor> createState() =>
      XeroInvoiceEditorState();
}

class XeroInvoiceEditorState extends riverpod.ConsumerState<XeroInvoiceEditor> {
  late List<XeroLineItem> _lineItems;
  late final TextEditingController _referenceController;
  late DateTime? _dueDate;

  /// Bumped when the lines are replaced from outside, so the line editor is
  /// rebuilt from them.
  int _seedGeneration = 0;

  bool _isSaving = false;
  /// A form problem the user can fix here ("Add at least one line …").
  String? _error;

  /// A Xero call that failed, explained.
  FriendlyError? _failure;

  @override
  void initState() {
    super.initState();
    // Copied, and each line keeps its LineItemID — Xero replaces the whole
    // array on save, so a line that loses its id is deleted and recreated.
    _lineItems = List.of(widget.invoice.lineItems);
    _referenceController =
        TextEditingController(text: widget.invoice.reference);
    _dueDate = widget.invoice.dueDate;
  }

  @override
  void dispose() {
    _referenceController.dispose();
    super.dispose();
  }

  /// Rewrite every line's description in the editor — nothing is saved until
  /// the user saves. Used to add the personnel to a report's invoice.
  void rewriteDescriptions(String Function(String description) rewrite) {
    setState(() {
      _lineItems = [
        for (final l in _lineItems)
          XeroLineItem(
            lineItemId: l.lineItemId,
            description: rewrite(l.description),
            quantity: l.quantity,
            unitAmount: l.unitAmount,
            accountCode: l.accountCode,
            taxType: l.taxType,
            itemCode: l.itemCode,
            lineAmount: l.lineAmount,
            taxAmount: l.taxAmount,
          ),
      ];
      _seedGeneration++;
    });
  }

  Company? get _company => ref.read(companyRiverpod).getById(Company.clmId);

  Future<void> _save() async {
    final usable = _lineItems
        .where((l) => l.description.trim().isNotEmpty && l.quantity > 0)
        .toList();

    if (usable.isEmpty) {
      setState(() =>
          _error = 'Add at least one line with a description and quantity.');
      return;
    }
    if (usable.every((l) => l.unitAmount * l.quantity <= 0)) {
      setState(() => _error = 'The invoice total must be greater than zero.');
      return;
    }
    // Xero requires an account code on every line; a line added here inherits
    // the company default, but an invoice raised elsewhere may have none.
    final missingAccount = usable.where((l) => l.accountCode.isEmpty).toList();
    if (missingAccount.isNotEmpty) {
      setState(() => _error =
          'Every line needs an account code. Set the sales account for '
              'Community Life Media in Settings → Companies.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
      _failure = null;
    });

    try {
      final amended = widget.invoice.copyWith(
        reference: _referenceController.text.trim(),
        dueDate: _dueDate,
        lineItems: usable,
      );
      final updated = await ref
          .read(xeroAccountingServiceRiverpod)
          .updateInvoice(widget.invoice.invoiceId, amended.toUpdateJson());
      if (!mounted) return;
      setState(() => _isSaving = false);
      widget.onSaved(updated);
    } catch (e) {
      if (mounted) {
        setState(() {
          _failure = describeAccountingError(e, action: 'save the invoice');
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _company?.providerConfig ?? const {};

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        XeroLineItemsEditor(
          // Keyed on the generation as well: rows of an existing invoice are
          // keyed by their LineItemID, so without this a row keeps showing its
          // old description after [rewriteDescriptions] — and typing in it
          // would write the old text back over the new.
          key: ValueKey('lines_$_seedGeneration'),
          lineItems: _lineItems,
          lineAmountType: widget.invoice.lineAmountTypes,
          defaultAccountCode: config['salesAccountCode'] ?? '',
          defaultTaxType: config['salesTaxType'] ?? '',
          seedGeneration: _seedGeneration,
          enabled: !_isSaving,
          onChanged: (l) => setState(() => _lineItems = l),
        ),
        const SizedBox(height: 14),
        XeroFieldPair(
          firstFlex: 2,
          first: TextField(
            controller: _referenceController,
            enabled: !_isSaving,
            decoration: const InputDecoration(
              labelText: 'Reference',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          second: XeroDateField(
            label: 'Due date',
            value: _dueDate,
            firstDate: widget.invoice.date,
            onChanged: (d) => setState(() => _dueDate = d),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          XeroNotice(tone: XeroNoticeTone.error, message: _error!),
        ],
        if (_failure != null) ...[
          const SizedBox(height: 14),
          XeroNotice.error(_failure!),
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
            FilledButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save to Xero'),
            ),
          ],
        ),
      ],
    );
  }
}
