import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/invoice_message_subject.dart';
import '../../models/xero_invoice.dart';
import '../../services/job_list_service.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/save_file.dart';
import '../zoho/invoice_share.dart';
import '../zoho/zoho_table.dart';
import 'xero_edit_invoice_dialog.dart';
import 'xero_record_payment_dialog.dart';
import 'xero_status_chip.dart';

/// One Xero invoice in full — line items, totals, and the actions Xero allows
/// on it.
///
/// The list view fetches with `summaryOnly`, which omits line items, so this
/// always re-reads the invoice rather than trusting what the row carried.
class XeroInvoiceDetailScreen extends riverpod.ConsumerStatefulWidget {
  final String invoiceId;

  const XeroInvoiceDetailScreen({super.key, required this.invoiceId});

  @override
  riverpod.ConsumerState<XeroInvoiceDetailScreen> createState() =>
      _XeroInvoiceDetailScreenState();
}

class _XeroInvoiceDetailScreenState
    extends riverpod.ConsumerState<XeroInvoiceDetailScreen> {
  XeroInvoice? _invoice;
  String _onlineUrl = '';

  /// Contact email, fetched on demand for the share sheet's Gmail draft.
  ///
  /// The Zoho screen reads this off a locally cached customer list. Xero has
  /// no such cache by design — the customer views page server-side to stay
  /// inside the daily call budget — so it costs a lookup, taken once per
  /// screen and only when Share is actually pressed.
  String? _contactEmail;
  bool _contactLookupDone = false;
  bool _isLoading = true;
  bool _isBusy = false;
  String? _error;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final invoice = await ref
          .read(xeroAccountingServiceRiverpod)
          .getInvoice(widget.invoiceId);
      if (!mounted) return;
      setState(() {
        _invoice = invoice;
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

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _isBusy = true;
      _actionError = null;
    });
    try {
      await action();
    } on XeroException catch (e) {
      if (mounted) setState(() => _actionError = e.message);
    } catch (e) {
      if (mounted) setState(() => _actionError = '$e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  String get _fileName {
    final inv = _invoice;
    if (inv == null) return 'invoice';
    // "Client - INV-0001", the same name every other invoice download uses.
    return invoiceFileName(InvoiceMessageSubject.fromXero(inv));
  }

  /// Xero's own rendering, using the organisation's branding theme — what the
  /// customer actually receives.
  Future<void> _pdf({required bool download}) => _run(() async {
        final bytes = await ref
            .read(xeroAccountingServiceRiverpod)
            .getInvoicePdf(widget.invoiceId);
        if (!mounted) return;
        if (download) {
          final saved = await saveFileWithPicker(
            suggestedName: '$_fileName.pdf',
            bytes: bytes,
          );
          if (!saved) {
            await Printing.sharePdf(bytes: bytes, filename: '$_fileName.pdf');
          }
        } else {
          await Printing.layoutPdf(
              onLayout: (_) async => bytes, name: _fileName);
        }
      });

  Future<void> _copyOnlineLink() => _run(() async {
        final url = _onlineUrl.isNotEmpty
            ? _onlineUrl
            : await ref
                .read(xeroAccountingServiceRiverpod)
                .getOnlineInvoiceUrl(widget.invoiceId);
        if (!mounted) return;
        if (url.isEmpty) {
          setState(
              () => _actionError = 'Xero returned no online invoice link.');
          return;
        }
        setState(() => _onlineUrl = url);
        await Clipboard.setData(ClipboardData(text: url));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment link copied')),
        );
      });

  Future<void> _openOnlineLink() => _run(() async {
        final url = _onlineUrl.isNotEmpty
            ? _onlineUrl
            : await ref
                .read(xeroAccountingServiceRiverpod)
                .getOnlineInvoiceUrl(widget.invoiceId);
        if (url.isEmpty) return;
        if (mounted) setState(() => _onlineUrl = url);
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      });

  /// Share sheet, with the pay link resolved *before* the sheet opens.
  ///
  /// Templates render `{pay_link}` when the sheet builds, so a lazily-fetched
  /// link would not merely be missing from the preview — it would be missing
  /// from the message the user then sends.
  Future<void> _share(XeroInvoice invoice) => _run(() async {
        final service = ref.read(xeroAccountingServiceRiverpod);

        var url = _onlineUrl;
        if (url.isEmpty && invoice.status.hasOnlineInvoice) {
          url = await service.getOnlineInvoiceUrl(widget.invoiceId);
          if (!mounted) return;
          setState(() => _onlineUrl = url);
        }

        // Non-fatal: a missing address only costs the Gmail draft its "to".
        if (!_contactLookupDone && invoice.contactId.isNotEmpty) {
          _contactLookupDone = true;
          try {
            final contact = await service.getContact(invoice.contactId);
            _contactEmail = contact.emailAddress;
          } catch (_) {
            /* leave the recipient blank */
          }
          if (!mounted) return;
        }

        if (!mounted) return;
        await showInvoiceShareSheet(
          context,
          InvoiceMessageSubject.fromXero(invoice, payLink: url),
          customerEmail: _contactEmail,
        );
      });

  Future<void> _email() async {
    final invoice = _invoice;
    if (invoice == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Email this invoice?'),
        content: Text(
          'Xero will send ${invoice.invoiceNumber} to '
          '${invoice.contactName} using the organisation\'s own template. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Send')),
        ],
      ),
    );
    if (confirmed != true) return;

    await _run(() async {
      await ref
          .read(xeroAccountingServiceRiverpod)
          .emailInvoice(widget.invoiceId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Xero is sending the invoice')),
      );
    });
  }

  /// Amend the invoice in place.
  ///
  /// Only offered while nothing is paid: Xero accepts line-item changes on an
  /// AUTHORISED invoice (measured, not assumed) but refuses once a payment or
  /// credit note is allocated.
  Future<void> _edit(XeroInvoice invoice) async {
    final updated = await showDialog<XeroInvoice>(
      context: context,
      barrierDismissible: false,
      builder: (_) => XeroEditInvoiceDialog(invoice: invoice),
    );
    if (updated != null && mounted) {
      // Re-read rather than trusting the update response: Xero recalculates the
      // VAT split and totals, and the screen should show what the books hold.
      await _load();
    }
  }

  Future<void> _recordPayment(XeroInvoice invoice) async {
    final recorded = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => XeroRecordPaymentDialog(invoice: invoice),
    );
    if (recorded == true && mounted) await _load();
  }

  Future<void> _void() async {
    final invoice = _invoice;
    if (invoice == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Void ${invoice.invoiceNumber}?'),
        content: const Text(
          'The invoice stays in the books as a voided record — its number is '
          'not reused. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Void'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _run(() async {
      final updated = await ref
          .read(xeroAccountingServiceRiverpod)
          .voidInvoice(widget.invoiceId);
      if (mounted) setState(() => _invoice = updated);
      // Best effort: the void has happened in Xero either way.
      try {
        await ref.read(jobListServiceRiverpod).syncAccountingInvoiceStatusToJob(
            invoiceId: widget.invoiceId, status: updated.status.apiValue);
      } catch (_) {}
    });
  }

  /// Flat, square-cornered primary action styling, matching the Zoho detail
  /// screen so the two providers read as one app.
  static ButtonStyle _actionStyle(Color background) {
    return FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
  }

  static ButtonStyle _outlineStyle(Color foreground) {
    return OutlinedButton.styleFrom(
      foregroundColor: foreground,
      side: const BorderSide(color: ZohoPalette.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
  }

  @override
  Widget build(BuildContext context) {
    final invoice = _invoice;
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    return Scaffold(
      backgroundColor: ZohoPalette.pageBackground,
      appBar: AppBar(
        title: Text(invoice?.invoiceNumber.isNotEmpty == true
            ? invoice!.invoiceNumber
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
            tooltip: 'Reload from Xero',
            onPressed: _isLoading || _isBusy ? null : _load,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _Message(
                  icon: Icons.error_outline,
                  color: Colors.red,
                  text: _error!,
                  onRetry: _load,
                )
              : invoice == null
                  ? const SizedBox.shrink()
                  : Stack(
                      children: [
                        ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            _document(invoice, currency, dateFormat),
                            if (_actionError != null) ...[
                              const SizedBox(height: 16),
                              _Message(
                                icon: Icons.error_outline,
                                color: Colors.red,
                                text: _actionError!,
                              ),
                            ],
                            const SizedBox(height: 24),
                            _actions(invoice),
                            const SizedBox(height: 40),
                          ],
                        ),
                        if (_isBusy)
                          const Positioned.fill(
                            child: ColoredBox(
                              color: Color(0x33FFFFFF),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ),
                      ],
                    ),
    );
  }

  /// The invoice as a document panel, the way Xero and Zoho both present it.
  Widget _document(
      XeroInvoice invoice, NumberFormat currency, DateFormat dateFormat) {
    final struck = invoice.status.isStruckThrough;

    return Container(
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
                        decoration: struck ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    const SizedBox(height: 8),
                    XeroStatusChip(
                        status: invoice.status, isOverdue: invoice.isOverdue),
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
                      decoration: struck ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(height: 1, color: ZohoPalette.border),
          const SizedBox(height: 12),
          _DetailRow(label: 'Customer', value: invoice.contactName),
          if (invoice.reference.isNotEmpty)
            _DetailRow(label: 'Reference', value: invoice.reference),
          if (invoice.date != null)
            _DetailRow(
                label: 'Invoice Date', value: dateFormat.format(invoice.date!)),
          if (invoice.dueDate != null)
            _DetailRow(
                label: 'Due Date', value: dateFormat.format(invoice.dueDate!)),
          _DetailRow(
            label: 'Amounts',
            value: switch (invoice.lineAmountTypes) {
              XeroLineAmountType.inclusive => 'Entered including VAT',
              XeroLineAmountType.noTax => 'No VAT',
              XeroLineAmountType.exclusive => 'Entered excluding VAT',
            },
          ),
          _DetailRow(
            label: 'Amount Due',
            value: currency.format(invoice.amountDue),
            emphasise: invoice.amountDue > 0,
          ),
          if (invoice.lineItems.isNotEmpty) ...[
            const SizedBox(height: 20),
            _XeroLineItemsTable(
                lineItems: invoice.lineItems, currency: currency),
            const SizedBox(height: 16),
            _totalsBlock(invoice, currency),
          ],
        ],
      ),
    );
  }

  /// Subtotal / VAT / total, aligned under the line-item amounts.
  Widget _totalsBlock(XeroInvoice invoice, NumberFormat currency) {
    Widget row(String label, double value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      color: ZohoPalette.textMuted,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
              SizedBox(
                width: 130,
                child: Text(
                  currency.format(value),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: bold ? 15 : 13,
                    color: ZohoPalette.textPrimary,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );

    return Column(
      children: [
        row('Subtotal', invoice.subTotal),
        row('VAT', invoice.totalTax),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Divider(height: 1, color: ZohoPalette.border),
        ),
        row('Total', invoice.total, bold: true),
        if (invoice.amountPaid > 0) row('Paid', invoice.amountPaid),
        if (invoice.amountPaid > 0)
          row('Amount Due', invoice.amountDue, bold: true),
      ],
    );
  }

  Widget _actions(XeroInvoice invoice) {
    // Nothing paid and not annulled — Xero accepts amendments in this state.
    final isAmendable = invoice.amountPaid == 0 &&
        !invoice.status.isStruckThrough &&
        invoice.status != XeroInvoiceStatus.unknown;
    final canTakePayment = invoice.amountDue > 0 &&
        (invoice.status == XeroInvoiceStatus.authorised ||
            invoice.status == XeroInvoiceStatus.submitted);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            // Available whatever the status — you can always reprint. Separate
            // from Print because only this path can set the filename on web.
            FilledButton.icon(
              style: _actionStyle(const Color(0xFF5C6BC0)),
              onPressed: _isBusy ? null : () => _pdf(download: true),
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Download PDF'),
            ),
            OutlinedButton.icon(
              style: _outlineStyle(const Color(0xFF5C6BC0)),
              onPressed: _isBusy ? null : () => _pdf(download: false),
              icon: const Icon(Icons.print, size: 16),
              label: const Text('Print / Preview'),
            ),
            // Shares a covering message for the user to attach the PDF to,
            // unlike "Email from Xero" which sends Xero's own template
            // immediately and cannot be recalled.
            FilledButton.icon(
              style: _actionStyle(const Color(0xFF25D366)),
              onPressed: _isBusy ? null : () => _share(invoice),
              icon: const Icon(Icons.share, size: 16),
              label: const Text('Share'),
            ),
            if (invoice.status.hasOnlineInvoice) ...[
              FilledButton.icon(
                style: _actionStyle(const Color(0xFF25D366)),
                onPressed: _isBusy ? null : _copyOnlineLink,
                icon: const Icon(Icons.link, size: 16),
                label: const Text('Copy pay link'),
              ),
              OutlinedButton.icon(
                style: _outlineStyle(ZohoPalette.link),
                onPressed: _isBusy ? null : _openOnlineLink,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open pay link'),
              ),
            ],
            OutlinedButton.icon(
              style: _outlineStyle(ZohoPalette.link),
              onPressed:
                  _isBusy || invoice.status.isStruckThrough ? null : _email,
              icon: const Icon(Icons.email_outlined, size: 16),
              label: const Text('Email from Xero'),
            ),
            if (isAmendable)
              OutlinedButton.icon(
                style: _outlineStyle(ZohoPalette.link),
                onPressed: _isBusy ? null : () => _edit(invoice),
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Edit items'),
              ),
            if (canTakePayment)
              FilledButton.icon(
                style: _actionStyle(const Color(0xFF2E9E4F)),
                onPressed: _isBusy ? null : () => _recordPayment(invoice),
                icon: const Icon(Icons.payments, size: 16),
                label: const Text('Record Payment'),
              ),
            // Xero permits a void only from AUTHORISED with nothing paid, so
            // this is hidden rather than offered and then rejected.
            if (invoice.status.canBeVoided && invoice.amountPaid == 0)
              OutlinedButton.icon(
                style: _outlineStyle(const Color(0xFFE03E3E)),
                onPressed: _isBusy ? null : _void,
                icon: const Icon(Icons.block, size: 16),
                label: const Text('Void'),
              ),
          ],
        ),
        if (!isAmendable && !invoice.status.isStruckThrough)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              invoice.amountPaid > 0
                  ? 'Paid invoices cannot be amended. Xero needs a credit note '
                      'for a change at this point.'
                  : 'This invoice cannot be amended in its current state.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
          ),
      ],
    );
  }
}

/// One label/value line in the document panel.
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
              style:
                  const TextStyle(fontSize: 13, color: ZohoPalette.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: ZohoPalette.textPrimary,
                fontWeight: emphasise ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Line items, laid out as Xero prints them.
///
/// Carries a Tax column the Zoho table has no need for — Junk & Stuff charges
/// no VAT, so per-line tax there is always nothing.
class _XeroLineItemsTable extends StatelessWidget {
  final List<XeroLineItem> lineItems;
  final NumberFormat currency;

  const _XeroLineItemsTable({required this.lineItems, required this.currency});

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
              Expanded(child: _HeaderCell('Description')),
              SizedBox(width: 60, child: _HeaderCell('Qty', right: true)),
              SizedBox(width: 100, child: _HeaderCell('Rate', right: true)),
              SizedBox(width: 90, child: _HeaderCell('Tax', right: true)),
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
                        li.description.isEmpty ? '—' : li.description,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: ZohoPalette.textPrimary,
                        ),
                      ),
                      if (li.accountCode.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Account ${li.accountCode}',
                          style: const TextStyle(
                              fontSize: 12, color: ZohoPalette.textMuted),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(
                  width: 60,
                  child: Text(_qty(li.quantity),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, color: ZohoPalette.textPrimary)),
                ),
                SizedBox(
                  width: 100,
                  child: Text(currency.format(li.unitAmount),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, color: ZohoPalette.textPrimary)),
                ),
                SizedBox(
                  width: 90,
                  child: Text(
                      li.taxAmount == 0 ? '—' : currency.format(li.taxAmount),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, color: ZohoPalette.textMuted)),
                ),
                SizedBox(
                  width: 110,
                  child: Text(
                    // Xero's own computed figure, not our arithmetic — it
                    // applies the rounding.
                    currency.format(li.lineAmount),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ZohoPalette.textPrimary,
                    ),
                  ),
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

class _Message extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onRetry;

  const _Message({
    required this.icon,
    required this.color,
    required this.text,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
