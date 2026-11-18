import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/xero_invoice.dart';
import '../../models/xero_org.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/accounting_error.dart';
import '../../utils/schedule_time.dart';
import '../zoho/zoho_table.dart';
import 'xero_ui.dart';

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
  /// A form problem the user can fix here ("Enter an amount …").
  String? _error;

  /// A Xero call that failed, explained.
  FriendlyError? _failure;

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = describeAccountingError(e,
            action: "load the organisation's bank accounts");
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
          'That is more than the ${xeroCurrency.format(widget.invoice.amountDue)} '
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
      _failure = null;
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _failure = describeAccountingError(e, action: 'record the payment');
          _isSaving = false;
        });
      }
    }
  }

  /// Checked as the amount is typed, so a mistake shows on the field itself
  /// rather than only after pressing Record.
  String? get _amountProblem {
    if (_amountController.text.trim().isEmpty) return null;
    if (_amount <= 0) return 'Enter an amount greater than zero';
    if (_amount > widget.invoice.amountDue + 0.005) {
      return 'More than the ${xeroCurrency.format(widget.invoice.amountDue)} '
          'owing';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final invoice = widget.invoice;
    final owing = invoice.amountDue;
    final remaining = owing - _amount;
    final settles = _amount > 0 && remaining.abs() < 0.005;

    return AlertDialog(
      insetPadding: xeroDialogInset(context),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Record payment'),
          const SizedBox(height: 2),
          Text(
            '${invoice.invoiceNumber} · ${invoice.contactName}',
            style: const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: ZohoPalette.headerBackground,
                        border: Border.all(color: ZohoPalette.border),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text('Owing',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: ZohoPalette.textMuted)),
                          ),
                          Text(
                            xeroCurrency.format(owing),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: ZohoPalette.textPrimary,
                              fontFeatures: xeroTabular,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _amountController,
                      autofocus: true,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() => _error = null),
                      style: const TextStyle(fontFeatures: xeroTabular),
                      decoration: InputDecoration(
                        labelText: 'Amount received',
                        prefixText: 'R ',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        errorText: _amountProblem,
                        helperText: _amountProblem != null || _amount <= 0
                            ? null
                            : settles
                                ? 'Settles the invoice in full'
                                : '${xeroCurrency.format(remaining)} will '
                                    'still be owing',
                        suffixIcon: settles
                            ? null
                            : TextButton(
                                onPressed: () => setState(() {
                                  _amountController.text =
                                      owing.toStringAsFixed(2);
                                  _error = null;
                                }),
                                child: const Text('Full amount'),
                              ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (_bankAccounts.isEmpty)
                      const XeroNotice(
                        tone: XeroNoticeTone.warning,
                        message: 'This Xero organisation has no bank '
                            'accounts, so a payment cannot be recorded. Add '
                            'one in Xero first.',
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
                    const SizedBox(height: 14),
                    XeroFieldPair(
                      first: XeroDateField(
                        label: 'Date received',
                        value: _paidOn,
                        // Money cannot arrive tomorrow.
                        lastDate: scheduleToday(),
                        onChanged: (d) => setState(() => _paidOn = d),
                      ),
                      second: TextField(
                        controller: _referenceController,
                        decoration: const InputDecoration(
                          labelText: 'Reference',
                          hintText: 'e.g. EFT ref',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
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
          style:
              FilledButton.styleFrom(backgroundColor: const Color(0xFF2E9E4F)),
          onPressed: _isSaving ||
                  _isLoading ||
                  _bankAccounts.isEmpty ||
                  _amount <= 0 ||
                  _amountProblem != null
              ? null
              : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_amount > 0 && _amountProblem == null
                  ? 'Record ${xeroCurrency.format(_amount)}'
                  : 'Record payment'),
        ),
      ],
    );
  }
}
