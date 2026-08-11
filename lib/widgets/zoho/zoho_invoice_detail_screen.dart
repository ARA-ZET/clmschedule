import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/zoho_invoice.dart';
import '../../providers/zoho_invoices_provider.dart';
import 'zoho_status_chip.dart';

/// Invoice detail with the three write actions: mark sent, void, record
/// payment. Each re-reads the invoice from Zoho afterwards rather than
/// assuming the resulting status.
class ZohoInvoiceDetailScreen extends riverpod.ConsumerStatefulWidget {
  final String invoiceId;

  const ZohoInvoiceDetailScreen({super.key, required this.invoiceId});

  @override
  riverpod.ConsumerState<ZohoInvoiceDetailScreen> createState() =>
      _ZohoInvoiceDetailScreenState();
}

class _ZohoInvoiceDetailScreenState
    extends riverpod.ConsumerState<ZohoInvoiceDetailScreen> {
  bool _isBusy = false;
  String? _actionError;

  /// Run a write action, surfacing both progress and failure.
  Future<void> _run(Future<void> Function() action, String successMessage) async {
    setState(() {
      _isBusy = true;
      _actionError = null;
    });

    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(successMessage),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _actionError = e.toString());
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _confirmVoid(ZohoInvoice invoice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void this invoice?'),
        content: Text(
          'Invoice ${invoice.invoiceNumber} will be voided in Zoho Books. '
          'Voiding cannot be undone from this app — you would have to move it '
          'back to draft in Zoho.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Void'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _run(
      () => ref.read(zohoInvoicesRiverpod).voidInvoice(invoice.invoiceId),
      'Invoice voided',
    );
  }

  Future<void> _recordPayment(ZohoInvoice invoice) async {
    final amount = await showDialog<double>(
      context: context,
      builder: (_) => _RecordPaymentDialog(invoice: invoice),
    );
    if (amount == null) return;

    await _run(
      () => ref.read(zohoInvoicesRiverpod).recordPayment(
            invoiceId: invoice.invoiceId,
            customerId: invoice.customerId,
            amount: amount,
          ),
      'Payment recorded',
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(zohoInvoicesRiverpod);
    final invoice = provider.getById(widget.invoiceId);
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    if (invoice == null) {
      // Reached via a deep link or after the list was filtered out from under
      // us — fetch it on its own rather than showing an empty screen.
      return Scaffold(
        appBar: AppBar(title: const Text('Invoice')),
        body: FutureBuilder<ZohoInvoice>(
          future: provider.reloadInvoice(widget.invoiceId),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Could not load invoice: ${snapshot.error}',
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return const Center(child: CircularProgressIndicator());
          },
        ),
      );
    }

    final canMarkSent = invoice.status == ZohoInvoiceStatus.draft;
    final canVoid = invoice.status != ZohoInvoiceStatus.isVoid &&
        invoice.status != ZohoInvoiceStatus.paid;
    final canPay = invoice.balance > 0 &&
        invoice.status != ZohoInvoiceStatus.isVoid &&
        invoice.status != ZohoInvoiceStatus.draft;

    return Scaffold(
      appBar: AppBar(
        title: Text(invoice.invoiceNumber.isNotEmpty
            ? invoice.invoiceNumber
            : 'Invoice'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload from Zoho',
            onPressed: _isBusy
                ? null
                : () => _run(
                      () => provider.reloadInvoice(invoice.invoiceId),
                      'Invoice reloaded',
                    ),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  ZohoStatusChip(status: invoice.status),
                  const Spacer(),
                  Text(
                    currency.format(invoice.total),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          decoration: invoice.status.isStruckThrough
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _DetailRow(label: 'Customer', value: invoice.customerName),
              if (invoice.referenceNumber.isNotEmpty)
                _DetailRow(label: 'Reference', value: invoice.referenceNumber),
              if (invoice.date != null)
                _DetailRow(
                    label: 'Date', value: dateFormat.format(invoice.date!)),
              if (invoice.dueDate != null)
                _DetailRow(
                    label: 'Due', value: dateFormat.format(invoice.dueDate!)),
              _DetailRow(
                label: 'Balance',
                value: currency.format(invoice.balance),
                emphasise: invoice.balance > 0,
              ),

              if (invoice.lineItems.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('Line items',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ...invoice.lineItems.map(
                  (li) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(li.name),
                      subtitle: li.description.isEmpty
                          ? null
                          : Text(li.description),
                      trailing: Text(
                        '${li.quantity.toStringAsFixed(li.quantity == li.quantity.roundToDouble() ? 0 : 2)}'
                        ' × ${currency.format(li.rate)}',
                      ),
                    ),
                  ),
                ),
              ],

              if (_actionError != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    border: Border.all(color: Colors.red.shade200),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_actionError!,
                            style: const TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: (_isBusy || !canMarkSent)
                        ? null
                        : () => _run(
                              () => provider.markSent(invoice.invoiceId),
                              'Invoice marked as sent',
                            ),
                    icon: const Icon(Icons.send),
                    label: const Text('Mark sent'),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700),
                    onPressed: (_isBusy || !canPay)
                        ? null
                        : () => _recordPayment(invoice),
                    icon: const Icon(Icons.payments),
                    label: const Text('Record payment'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red),
                    onPressed: (_isBusy || !canVoid)
                        ? null
                        : () => _confirmVoid(invoice),
                    icon: const Icon(Icons.block),
                    label: const Text('Void'),
                  ),
                ],
              ),
              if (!canMarkSent && invoice.status != ZohoInvoiceStatus.isVoid)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Only draft invoices can be marked sent.',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
            ],
          ),
          if (_isBusy)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 3),
            ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasise;

  const _DetailRow({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                fontWeight: emphasise ? FontWeight.bold : FontWeight.normal,
                color: emphasise ? Colors.red.shade700 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Amount prompt for recording a payment. Defaults to the full outstanding
/// balance, but allows a partial payment.
class _RecordPaymentDialog extends StatefulWidget {
  final ZohoInvoice invoice;

  const _RecordPaymentDialog({required this.invoice});

  @override
  State<_RecordPaymentDialog> createState() => _RecordPaymentDialogState();
}

class _RecordPaymentDialogState extends State<_RecordPaymentDialog> {
  late final TextEditingController _amountController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: widget.invoice.balance.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount greater than zero.');
      return;
    }
    if (amount > widget.invoice.balance) {
      setState(() => _error =
          'Amount exceeds the outstanding balance of '
          '${widget.invoice.balance.toStringAsFixed(2)}.');
      return;
    }
    Navigator.of(context).pop(amount);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record payment'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Outstanding: R ${widget.invoice.balance.toStringAsFixed(2)}',
            style: TextStyle(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: 'R ',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Record')),
      ],
    );
  }
}
