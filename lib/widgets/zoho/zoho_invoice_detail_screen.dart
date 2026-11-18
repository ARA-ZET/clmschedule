import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../models/invoice_message_subject.dart';
import '../../models/zoho_invoice.dart';
import '../../providers/zoho_customers_provider.dart';
import '../../providers/zoho_invoices_provider.dart';
import '../../utils/accounting_error.dart';
import '../../utils/save_with_picker.dart';
import '../xero/xero_ui.dart' show XeroNotice;
import 'edit_invoice_dialog.dart';
import 'invoice_share.dart';
import 'zoho_status_chip.dart';
import 'zoho_table.dart';
import '../slow_action_hint.dart';

/// Invoice detail with the three write actions: mark sent, void, record
/// payment. Each re-reads the invoice from Zoho afterwards rather than
/// assuming the resulting status.
class ZohoInvoiceDetailScreen extends riverpod.ConsumerStatefulWidget {
  final String invoiceId;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const ZohoInvoiceDetailScreen(
      {super.key, required this.orgId, required this.invoiceId});

  @override
  riverpod.ConsumerState<ZohoInvoiceDetailScreen> createState() =>
      _ZohoInvoiceDetailScreenState();
}

class _ZohoInvoiceDetailScreenState
    extends riverpod.ConsumerState<ZohoInvoiceDetailScreen> {
  bool _isBusy = false;
  FriendlyError? _actionError;

  /// The one-off fetch used when this screen is opened without the invoice list
  /// having been loaded — from the Job List, say.
  ///
  /// Held in state rather than created in `build()`. Calling `reloadInvoice()`
  /// inline in a `FutureBuilder`'s `future:` starts a fresh request on every
  /// rebuild, and since that call notifies listeners, each response triggers
  /// the next rebuild: an endless spinner and an endless stream of requests
  /// against a rate-limited API.
  Future<ZohoInvoice>? _coldLoad;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = ref.read(zohoInvoicesRiverpod(widget.orgId));
      if (provider.getById(widget.invoiceId) == null) {
        setState(() => _coldLoad = provider.reloadInvoice(widget.invoiceId));
      }
    });
  }

  /// Zoho's flat, square-cornered primary action styling.
  static ButtonStyle _actionStyle(Color background) {
    return FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
  }

  /// Run a write action, surfacing both progress and failure.
  /// [what] completes "Couldn't …" when the action fails.
  Future<void> _run(Future<void> Function() action, String successMessage,
      {required String what}) async {
    // The buttons disable while busy, but two clicks can land before that
    // repaint.
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _actionError = null;
    });

    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(
          SnackBar(
            content: Text(successMessage),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _actionError = describeAccountingError(e, action: what));
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// Open Zoho's own rendering of the invoice in the system print/preview
  /// sheet — same template Zoho Books prints, so what you see here is what
  /// the customer receives.
  /// [download] saves the file directly with the correct name; otherwise the
  /// print dialog opens.
  Future<void> _printInvoice(ZohoInvoice invoice,
      {bool download = false}) async {
    // The buttons disable while busy, but two clicks can land before that
    // repaint — and a second Save dialog would fail and download a stray
    // copy.
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _actionError = null;
    });
    try {
      final provider = ref.read(zohoInvoicesRiverpod(widget.orgId));
      final fileName = invoiceFileName(InvoiceMessageSubject.fromZoho(invoice));
      if (download) {
        // OS Save-As dialog first (it must open straight after the click),
        // fetching the PDF while the user picks a folder. Falls back to an
        // ordinary download where the dialog is unavailable (Firefox,
        // Safari). Every outcome is shown as a toast.
        //
        // Either way the filename is set explicitly — unlike layoutPdf, which
        // prints a blob in an iframe and lets Chrome name the output after the
        // page title ("CLM Schedule").
        await savePdfWithFeedback(
          ScaffoldMessenger.of(context),
          fileName: fileName,
          load: () => provider.getInvoicePdf(invoice.invoiceId),
        );
      } else {
        final bytes = await provider.getInvoicePdf(invoice.invoiceId);
        if (!mounted) return;
        await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: fileName, // honoured on native; ignored on web
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _actionError = describeAccountingError(e,
            action: download ? 'download the PDF' : 'open the PDF for printing'));
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _editInvoice(ZohoInvoice invoice) async {
    // The list response carries line items, but re-read first so the editor
    // starts from Zoho's current state rather than a possibly stale copy.
    setState(() {
      _isBusy = true;
      _actionError = null;
    });
    ZohoInvoice fresh;
    try {
      fresh = await ref
          .read(zohoInvoicesRiverpod(widget.orgId))
          .reloadInvoice(invoice.invoiceId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _actionError = describeAccountingError(e,
              action: 'open the invoice for editing');
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _isBusy = false);

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => EditInvoiceDialog(orgId: widget.orgId, invoice: fresh),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(
          content: Text('Invoice updated'),
          backgroundColor: Colors.green,
        ),
      );
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
      () => ref
          .read(zohoInvoicesRiverpod(widget.orgId))
          .voidInvoice(invoice.invoiceId),
      'Invoice voided',
      what: 'void the invoice',
    );
  }

  Future<void> _recordPayment(ZohoInvoice invoice) async {
    final amount = await showDialog<double>(
      context: context,
      builder: (_) => _RecordPaymentDialog(invoice: invoice),
    );
    if (amount == null) return;

    await _run(
      () => ref.read(zohoInvoicesRiverpod(widget.orgId)).recordPayment(
            invoiceId: invoice.invoiceId,
            customerId: invoice.customerId,
            amount: amount,
            // Same money against the same outstanding balance is one payment:
            // a retry after a lost reply replays it instead of recording it
            // twice, while a real second payment (balance already reduced)
            // gets a new key.
            idempotencyKey: 'clm-payment-${invoice.invoiceId}-'
                '${ZohoInvoice.formatDate(DateTime.now())}-'
                '${amount.toStringAsFixed(2)}-'
                'bal${invoice.balance.toStringAsFixed(2)}',
          ),
      'Payment recorded',
      what: 'record the payment',
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(zohoInvoicesRiverpod(widget.orgId));
    final invoice = provider.getById(widget.invoiceId);
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    if (invoice == null) {
      // Reached via a deep link or after the list was filtered out from under
      // us — fetch it on its own rather than showing an empty screen.
      return Scaffold(
        backgroundColor: ZohoPalette.pageBackground,
        appBar: AppBar(
          title: const Text('Invoice'),
          backgroundColor: ZohoPalette.surface,
          foregroundColor: ZohoPalette.textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          shape: const Border(bottom: BorderSide(color: ZohoPalette.border)),
        ),
        body: FutureBuilder<ZohoInvoice>(
          future: _coldLoad,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Could not load invoice: ${snapshot.error}',
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => setState(() {
                          _coldLoad = ref
                              .read(zohoInvoicesRiverpod(widget.orgId))
                              .reloadInvoice(widget.invoiceId);
                        }),
                        child: const Text('Retry'),
                      ),
                    ],
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
    // Zoho rejects edits to void invoices, and editing a settled one would
    // desync the recorded payment from the total.
    final canEdit = invoice.status != ZohoInvoiceStatus.isVoid &&
        invoice.status != ZohoInvoiceStatus.paid;

    return Scaffold(
      backgroundColor: ZohoPalette.pageBackground,
      appBar: AppBar(
        title: Text(invoice.invoiceNumber.isNotEmpty
            ? invoice.invoiceNumber
            : 'Invoice'),
        backgroundColor: ZohoPalette.surface,
        foregroundColor: ZohoPalette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(bottom: BorderSide(color: ZohoPalette.border)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            color: ZohoPalette.textMuted,
            tooltip: 'Reload from Zoho',
            onPressed: _isBusy
                ? null
                : () => _run(
                      () => provider.reloadInvoice(invoice.invoiceId),
                      'Invoice reloaded',
                      what: 'reload the invoice',
                    ),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // The invoice itself, presented as a document panel the way
              // Zoho Books shows it.
              Container(
                decoration: BoxDecoration(
                  color: ZohoPalette.surface,
                  border: Border.all(color: ZohoPalette.border),
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                invoice.invoiceNumber.isNotEmpty
                                    ? invoice.invoiceNumber
                                    : 'Invoice',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: ZohoPalette.textPrimary,
                                  decoration: invoice.status.isStruckThrough
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 8),
                              ZohoStatusChip(status: invoice.status),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                              'TOTAL',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                                color: ZohoPalette.textMuted,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              currency.format(invoice.total),
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: ZohoPalette.textPrimary,
                                decoration: invoice.status.isStruckThrough
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Divider(height: 1, color: ZohoPalette.border),
                    const SizedBox(height: 12),
                    _DetailRow(label: 'Customer', value: invoice.customerName),
                    if (invoice.referenceNumber.isNotEmpty)
                      _DetailRow(
                          label: 'Reference', value: invoice.referenceNumber),
                    if (invoice.date != null)
                      _DetailRow(
                          label: 'Invoice Date',
                          value: dateFormat.format(invoice.date!)),
                    if (invoice.dueDate != null)
                      _DetailRow(
                          label: 'Due Date',
                          value: dateFormat.format(invoice.dueDate!)),
                    _DetailRow(
                      label: 'Balance Due',
                      value: currency.format(invoice.balance),
                      emphasise: invoice.balance > 0,
                    ),
                    if (invoice.lineItems.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _LineItemsTable(
                          lineItems: invoice.lineItems, currency: currency),
                    ],
                  ],
                ),
              ),

              if (_actionError != null) ...[
                const SizedBox(height: 16),
                XeroNotice.error(
                  _actionError!,
                  onDismiss: () => setState(() => _actionError = null),
                ),
              ],

              SlowActionHint(busy: _isBusy, action: 'Working with Zoho'),

              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  // Available whatever the status — you can always reprint.
                  // Saves as "Customer - INV-001234.pdf". Separate from Print
                  // because only this path can set the filename on web.
                  FilledButton.icon(
                    style: _actionStyle(const Color(0xFF5C6BC0)),
                    onPressed: _isBusy
                        ? null
                        : () => _printInvoice(invoice, download: true),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download PDF'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF5C6BC0),
                      side: const BorderSide(color: ZohoPalette.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    onPressed: _isBusy ? null : () => _printInvoice(invoice),
                    icon: const Icon(Icons.print, size: 16),
                    label: const Text('Print / Preview'),
                  ),
                  FilledButton.icon(
                    style: _actionStyle(const Color(0xFF25D366)),
                    onPressed: _isBusy
                        ? null
                        : () => showInvoiceShareSheet(
                              context,
                              InvoiceMessageSubject.fromZoho(invoice),
                              customerEmail: ref
                                  .read(zohoCustomersRiverpod(widget.orgId))
                                  .getById(invoice.customerId)
                                  ?.email,
                            ),
                    icon: const Icon(Icons.share, size: 16),
                    label: const Text('Share'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ZohoPalette.link,
                      side: const BorderSide(color: ZohoPalette.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    onPressed: (_isBusy || !canEdit)
                        ? null
                        : () => _editInvoice(invoice),
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit items'),
                  ),
                  FilledButton.icon(
                    style: _actionStyle(ZohoPalette.link),
                    onPressed: (_isBusy || !canMarkSent)
                        ? null
                        : () => _run(
                              () => provider.markSent(invoice.invoiceId),
                              'Invoice marked as sent',
                              what: 'mark the invoice as sent',
                            ),
                    icon: const Icon(Icons.send, size: 16),
                    label: const Text('Mark as Sent'),
                  ),
                  FilledButton.icon(
                    style: _actionStyle(const Color(0xFF2E9E4F)),
                    onPressed: (_isBusy || !canPay)
                        ? null
                        : () => _recordPayment(invoice),
                    icon: const Icon(Icons.payments, size: 16),
                    label: const Text('Record Payment'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE03E3E),
                      side: const BorderSide(color: ZohoPalette.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    onPressed: (_isBusy || !canVoid)
                        ? null
                        : () => _confirmVoid(invoice),
                    icon: const Icon(Icons.block, size: 16),
                    label: const Text('Void'),
                  ),
                ],
              ),
              if (!canMarkSent && invoice.status != ZohoInvoiceStatus.isVoid)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Only draft invoices can be marked sent.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
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
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: ZohoPalette.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: emphasise ? FontWeight.w700 : FontWeight.w500,
                color: emphasise
                    ? const Color(0xFFE03E3E)
                    : ZohoPalette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Line items rendered as a compact Zoho-style table rather than Material
/// cards, matching the list screens.
class _LineItemsTable extends StatelessWidget {
  final List<ZohoLineItem> lineItems;
  final NumberFormat currency;

  const _LineItemsTable({required this.lineItems, required this.currency});

  static String _qty(double q) =>
      q.toStringAsFixed(q == q.roundToDouble() ? 0 : 2);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: ZohoPalette.headerHeight,
          color: ZohoPalette.headerBackground,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: const Row(
            children: [
              Expanded(child: _HeaderCell('Item')),
              SizedBox(width: 70, child: _HeaderCell('Qty', right: true)),
              SizedBox(width: 110, child: _HeaderCell('Rate', right: true)),
              SizedBox(width: 110, child: _HeaderCell('Amount', right: true)),
            ],
          ),
        ),
        ...lineItems.map(
          (li) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                      Text(
                        li.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: ZohoPalette.textPrimary,
                        ),
                      ),
                      if (li.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          li.description,
                          style: const TextStyle(
                            fontSize: 12,
                            color: ZohoPalette.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(
                  width: 70,
                  child: Text(_qty(li.quantity),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, color: ZohoPalette.textPrimary)),
                ),
                SizedBox(
                  width: 110,
                  child: Text(currency.format(li.rate),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, color: ZohoPalette.textPrimary)),
                ),
                SizedBox(
                  width: 110,
                  child: Text(currency.format(li.rate * li.quantity),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ZohoPalette.textPrimary,
                      )),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final bool right;

  const _HeaderCell(this.label, {this.right = false});

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
      setState(() => _error = 'Amount exceeds the outstanding balance of '
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
