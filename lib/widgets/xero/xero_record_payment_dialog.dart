import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/xero_invoice.dart';
import '../../models/xero_org.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/schedule_time.dart';

/// Record a payment against a Xero invoice.
///
/// Like Zoho, Xero has no "mark as paid" action — the status follows from the
/// payment. The account chosen here is the **bank account the money arrived
/// in**, not the revenue account the invoice was raised against; Xero rejects a
/// payment made against a revenue account.
class XeroRecordPaymentDialog extends riverpod.ConsumerStatefulWidget {
  final XeroInvoice invoice;

  const XeroRecordPaymentDialog({super.key, required this.invoice});

  @override
  riverpod.ConsumerState<XeroRecordPaymentDialog> createState() =>
      _XeroRecordPaymentDialogState();
}

class _XeroRecordPaymentDialogState
    extends riverpod.ConsumerState<XeroRecordPaymentDialog> {
  late final TextEditingController _amountController;
  late final TextEditingController _referenceController;
  DateTime _paidOn = scheduleToday();

  List<XeroAccount> _bankAccounts = const [];
  String? _accountCode;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Defaults to settling the invoice in full, which is the common case.
    _amountController = TextEditingController(
        text: widget.invoice.amountDue.toStringAsFixed(2));
    _referenceController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAccounts());
  }

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts =
          await ref.read(xeroAccountingServiceRiverpod).listBankAccounts();
      if (!mounted) return;
      setState(() {
        _bankAccounts = accounts;
        _accountCode = accounts.isNotEmpty ? accounts.first.code : null;
        _isLoading = false;
      });
    } on XeroException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    }
  }

  double get _amount => double.tryParse(_amountController.text.trim()) ?? 0;

  Future<void> _save() async {
    if (_amount <= 0) {
      setState(() => _error = 'Enter an amount greater than zero.');
      return;
    }
    if (_amount > widget.invoice.amountDue) {
      setState(() => _error =
          'That is more than the ${widget.invoice.amountDue.toStringAsFixed(2)} '
              'still owing on this invoice.');
      return;
    }
    if (_accountCode == null) {
      setState(() => _error = 'Choose the bank account the money arrived in.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      await ref.read(xeroAccountingServiceRiverpod).createPayment(
            invoiceId: widget.invoice.invoiceId,
            accountCode: _accountCode!,
            amount: _amount,
            date: _paidOn,
            reference: _referenceController.text.trim(),
            // Keyed on the invoice, date and amount so a retry after a dropped
            // response cannot record the same money twice.
            idempotencyKey: 'clm-payment-${widget.invoice.invoiceId}-'
                '${XeroInvoice.formatDate(_paidOn)}-'
                '${_amount.toStringAsFixed(2)}',
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
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
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    return AlertDialog(
      title: const Text('Record payment'),
      content: SizedBox(
        width: 420,
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.invoice.invoiceNumber} · '
                    '${widget.invoice.contactName}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text('${currency.format(widget.invoice.amountDue)} owing',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Amount',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_bankAccounts.isEmpty)
                    const Text(
                      'This Xero organisation has no bank accounts, so a '
                      'payment cannot be recorded. Add one in Xero first.',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    )
                  else
                    DropdownButtonFormField<String>(
                      initialValue: _accountCode,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Paid into',
                        helperText: 'The bank account the money arrived in',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: _bankAccounts
                          .map((a) => DropdownMenuItem(
                                value: a.code,
                                child: Text(a.displayLabel,
                                    overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _accountCode = v),
                    ),
                  const SizedBox(height: 10),
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
                              initialDate: _paidOn,
                              firstDate: DateTime(_paidOn.year - 2),
                              lastDate: DateTime(_paidOn.year + 1),
                            );
                            if (picked != null) {
                              setState(() => _paidOn = picked);
                            }
                          },
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'Date',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            child: Text(dateFormat.format(_paidOn)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!,
                          style:
                              const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _isSaving || _isLoading || _bankAccounts.isEmpty ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Record payment'),
        ),
      ],
    );
  }
}
