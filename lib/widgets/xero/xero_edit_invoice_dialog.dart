import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/company.dart';
import '../../models/xero_invoice.dart';
import '../../providers/company_provider.dart';
import '../../services/xero_accounting_service.dart';
import 'xero_line_items_editor.dart';

/// Amend an existing Xero invoice in place.
///
/// The original plan specced void-and-reissue here, on the strength of docs
/// saying Xero only allows updates to draft invoices. Measurement against the
/// live API disproved that: an AUTHORISED invoice's line items were amended and
/// the change persisted. So editing an unpaid invoice is an ordinary update —
/// no voided numbers left behind in the books.
///
/// The caller must only offer this for [XeroInvoice] with nothing paid; Xero
/// rejects an amendment once a payment or credit note is allocated.
class XeroEditInvoiceDialog extends riverpod.ConsumerStatefulWidget {
  final XeroInvoice invoice;

  const XeroEditInvoiceDialog({super.key, required this.invoice});

  @override
  riverpod.ConsumerState<XeroEditInvoiceDialog> createState() =>
      _XeroEditInvoiceDialogState();
}

class _XeroEditInvoiceDialogState
    extends riverpod.ConsumerState<XeroEditInvoiceDialog> {
  late List<XeroLineItem> _lineItems;
  late final TextEditingController _referenceController;
  late DateTime? _dueDate;

  bool _isSaving = false;
  String? _error;

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
      Navigator.of(context).pop(updated);
    } on XeroException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('d MMM y');
    final config = _company?.providerConfig ?? const {};

    return AlertDialog(
      title: Text('Edit ${widget.invoice.invoiceNumber}'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.invoice.contactName,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              XeroLineItemsEditor(
                lineItems: _lineItems,
                lineAmountType: widget.invoice.lineAmountTypes,
                defaultAccountCode: config['salesAccountCode'] ?? '',
                defaultTaxType: config['salesTaxType'] ?? '',
                onChanged: (l) => setState(() => _lineItems = l),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _referenceController,
                      decoration: const InputDecoration(
                        labelText: 'Reference',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _dueDate ?? DateTime.now(),
                          firstDate: DateTime(DateTime.now().year - 2),
                          lastDate: DateTime(DateTime.now().year + 3),
                        );
                        if (picked != null) setState(() => _dueDate = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Due date',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(_dueDate == null
                            ? '—'
                            : dateFormat.format(_dueDate!)),
                      ),
                    ),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save changes'),
        ),
      ],
    );
  }
}
