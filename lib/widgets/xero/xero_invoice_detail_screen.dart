import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/invoice_message_subject.dart';
import '../../models/xero_invoice.dart';
import '../../services/job_list_service.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/accounting_error.dart';
import '../../utils/save_with_picker.dart';
import '../zoho/invoice_share.dart';
import '../zoho/zoho_table.dart';
import 'xero_edit_invoice_dialog.dart';
import 'xero_record_payment_dialog.dart';
import 'xero_status_chip.dart';
import 'xero_ui.dart';

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
  FriendlyError? _error;
  FriendlyError? _actionError;

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeAccountingError(e, action: 'load the invoice');
        _isLoading = false;
      });
    }
  }

  /// Run [action], explaining any failure in plain language. [what]
  /// completes "Couldn't …".
  Future<void> _run(String what, Future<void> Function() action) async {
    // The buttons disable while busy, but two clicks can land before that
    // repaint — and a second Save dialog would fail and download a stray
    // copy.
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _actionError = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => _actionError = describeAccountingError(e, action: what));
      }
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
  Future<void> _pdf({required bool download}) => _run(
      download ? 'download the PDF' : 'open the PDF for printing', () async {
        final service = ref.read(xeroAccountingServiceRiverpod);
        if (download) {
          // Save dialog first — it must open straight after the click; the
          // PDF loads while the user picks a folder.
          await savePdfWithFeedback(
            ScaffoldMessenger.of(context),
            fileName: _fileName,
            load: () => service.getInvoicePdf(widget.invoiceId),
          );
          return;
        }
        final bytes = await service.getInvoicePdf(widget.invoiceId);
        if (!mounted) return;
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: _fileName);
      });

  Future<void> _copyOnlineLink() => _run('copy the pay link', () async {
        final url = _onlineUrl.isNotEmpty
            ? _onlineUrl
            : await ref
                .read(xeroAccountingServiceRiverpod)
                .getOnlineInvoiceUrl(widget.invoiceId);
        if (!mounted) return;
        if (url.isEmpty) {
          setState(() => _actionError = const FriendlyError(
                title: "Couldn't copy the pay link — Xero didn't return one.",
                advice: 'Voided and deleted invoices have no pay link. Open '
                    'the invoice in Xero to check its status.',
                detail: 'getOnlineInvoiceUrl returned an empty URL',
              ));
          return;
        }
        setState(() => _onlineUrl = url);
        await Clipboard.setData(ClipboardData(text: url));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showToast(
          const SnackBar(content: Text('Payment link copied')),
        );
      });

  Future<void> _openOnlineLink() => _run('open the pay link', () async {
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
  Future<void> _share(XeroInvoice invoice) =>
      _run('get the invoice ready to share', () async {
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

    await _run('email the invoice', () async {
      await ref
          .read(xeroAccountingServiceRiverpod)
          .emailInvoice(widget.invoiceId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showToast(
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

    await _run('void the invoice', () async {
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

  /// Xero's own screen for this invoice, for anything this app does not do —
  /// credit notes, history, attachments.
  Future<void> _openInXero() => launchUrl(
        Uri.parse('https://go.xero.com/AccountsReceivable/View.aspx'
            '?InvoiceID=${widget.invoiceId}'),
        mode: LaunchMode.externalApplication,
      );

  static ButtonStyle _primaryStyle(Color background) {
    return FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
  }

  /// Secondary actions are neutral: colour is kept for the one thing the
  /// screen most wants done, and for the destructive one.
  static final ButtonStyle _secondaryStyle = OutlinedButton.styleFrom(
    foregroundColor: ZohoPalette.textPrimary,
    backgroundColor: ZohoPalette.surface,
    side: const BorderSide(color: ZohoPalette.border),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
  );

  static const _paymentGreen = Color(0xFF2E9E4F);

  @override
  Widget build(BuildContext context) {
    final invoice = _invoice;

    return Scaffold(
      backgroundColor: ZohoPalette.pageBackground,
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(invoice?.invoiceNumber.isNotEmpty == true
                ? invoice!.invoiceNumber
                : 'Invoice'),
            if (invoice != null && invoice.contactName.isNotEmpty)
              Text(
                invoice.contactName,
                style:
                    const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
              ),
          ],
        ),
        backgroundColor: ZohoPalette.surface,
        foregroundColor: ZohoPalette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(bottom: BorderSide(color: ZohoPalette.border)),
        // Work in flight shows as a thin bar under the app bar instead of a
        // veil over the page, so the invoice stays readable while it runs.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _isBusy || (_isLoading && invoice != null)
                ? const LinearProgressIndicator(minHeight: 2)
                : null,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            color: ZohoPalette.textMuted,
            tooltip: 'Reload from Xero',
            onPressed: _isLoading || _isBusy ? null : _load,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _isLoading && invoice == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: XeroNotice.error(
                        _error!,
                        actionLabel: 'Retry',
                        onAction: _load,
                      ),
                    ),
                  ),
                )
              : invoice == null
                  ? const SizedBox.shrink()
                  : LayoutBuilder(builder: (context, constraints) {
                      final narrow = constraints.maxWidth < 640;
                      final gutter = narrow ? 16.0 : 24.0;
                      return Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          // Wide enough for the line-items table, narrow
                          // enough to read like a document on a desktop.
                          constraints: const BoxConstraints(maxWidth: 920),
                          child: ListView(
                            padding:
                                EdgeInsets.fromLTRB(gutter, gutter, gutter, 48),
                            children: [
                              _standing(invoice, narrow: narrow),
                              const SizedBox(height: 12),
                              _actions(invoice),
                              if (_actionError != null) ...[
                                const SizedBox(height: 12),
                                XeroNotice.error(
                                  _actionError!,
                                  onDismiss: () =>
                                      setState(() => _actionError = null),
                                ),
                              ],
                              const SizedBox(height: 16),
                              _document(invoice, narrow: narrow),
                            ],
                          ),
                        ),
                      );
                    }),
    );
  }

  /// Where the invoice stands, and the one thing to do about it.
  Widget _standing(XeroInvoice invoice, {required bool narrow}) {
    final s = xeroStanding(invoice);
    final color = s.tone.color;

    // The accent is a clipped strip rather than a coloured left border:
    // Flutter refuses a border radius on borders of mixed colours.
    final payButton = _canTakePayment(invoice)
        ? FilledButton.icon(
            style: _primaryStyle(_paymentGreen),
            onPressed: _isBusy ? null : () => _recordPayment(invoice),
            icon: const Icon(Icons.payments_outlined, size: 18),
            label: const Text('Record payment'),
          )
        : null;

    final summary = Row(
      children: [
        Icon(s.icon, color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.headline,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (s.detail != null) ...[
                const SizedBox(height: 2),
                Text(
                  s.detail!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: ZohoPalette.textPrimary,
                    fontFeatures: xeroTabular,
                  ),
                ),
              ],
            ],
          ),
        ),
        // Beside the summary on a desktop; below it on a phone, where
        // sharing the row squeezed the sentence to a word per line.
        if (payButton != null && !narrow) ...[
          const SizedBox(width: 12),
          payButton,
        ],
      ],
    );

    final content = Padding(
      padding: const EdgeInsets.all(14),
      child: payButton != null && narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: 12), payButton],
            )
          : summary,
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZohoPalette.surface,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: ZohoPalette.accentWidth, color: color),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  static bool _canTakePayment(XeroInvoice invoice) =>
      invoice.amountDue > 0 &&
      (invoice.status == XeroInvoiceStatus.authorised ||
          invoice.status == XeroInvoiceStatus.submitted);

  /// Nothing paid and not annulled — Xero accepts amendments in this state.
  static bool _isAmendable(XeroInvoice invoice) =>
      invoice.amountPaid == 0 &&
      !invoice.status.isStruckThrough &&
      invoice.status != XeroInvoiceStatus.unknown;

  /// Sending first, then the document, then the rarer and riskier actions
  /// tucked behind More — nine equal buttons in five colours gave no clue
  /// which one mattered.
  Widget _actions(XeroInvoice invoice) {
    final struck = invoice.status.isStruckThrough;
    final amendable = _isAmendable(invoice);
    final canVoid = invoice.status.canBeVoided && invoice.amountPaid == 0;
    final busy = _isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Shares a covering message for the user to attach the PDF to,
            // unlike "Email from Xero" which sends Xero's own template
            // immediately and cannot be recalled.
            if (!struck)
              FilledButton.icon(
                style: _primaryStyle(ZohoPalette.link),
                onPressed: busy ? null : () => _share(invoice),
                icon: const Icon(Icons.send_outlined, size: 16),
                label: const Text('Share'),
              ),
            if (invoice.status.hasOnlineInvoice)
              OutlinedButton.icon(
                style: _secondaryStyle,
                onPressed: busy ? null : _copyOnlineLink,
                icon: const Icon(Icons.link, size: 16),
                label: const Text('Copy pay link'),
              ),
            // Available whatever the status — you can always reprint. Separate
            // from Print because only this path can set the filename on web.
            OutlinedButton.icon(
              style: _secondaryStyle,
              onPressed: busy ? null : () => _pdf(download: true),
              icon: const Icon(Icons.download, size: 16),
              label: const Text('PDF'),
            ),
            OutlinedButton.icon(
              style: _secondaryStyle,
              onPressed: busy ? null : () => _pdf(download: false),
              icon: const Icon(Icons.print_outlined, size: 16),
              label: const Text('Print'),
            ),
            if (amendable)
              OutlinedButton.icon(
                style: _secondaryStyle,
                onPressed: busy ? null : () => _edit(invoice),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit'),
              ),
            MenuAnchor(
              alignmentOffset: const Offset(0, 4),
              menuChildren: [
                if (invoice.status.hasOnlineInvoice)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.open_in_new, size: 18),
                    onPressed: busy ? null : _openOnlineLink,
                    child: const Text('Open pay link'),
                  ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.email_outlined, size: 18),
                  onPressed: busy || struck ? null : _email,
                  child: const Text('Email from Xero…'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.launch, size: 18),
                  onPressed: _openInXero,
                  child: const Text('Open in Xero'),
                ),
                // Xero permits a void only from AUTHORISED with nothing paid,
                // so this is hidden rather than offered and then rejected.
                if (canVoid) ...[
                  const Divider(height: 1),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.block,
                        size: 18, color: Color(0xFFE03E3E)),
                    onPressed: busy ? null : _void,
                    child: const Text('Void invoice…',
                        style: TextStyle(color: Color(0xFFE03E3E))),
                  ),
                ],
              ],
              builder: (context, controller, _) => OutlinedButton.icon(
                style: _secondaryStyle,
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.more_horiz, size: 16),
                label: const Text('More'),
              ),
            ),
          ],
        ),
        if (!amendable && !struck)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              invoice.amountPaid > 0
                  ? 'Paid invoices cannot be edited — Xero needs a credit note '
                      'for a change at this point.'
                  : 'This invoice cannot be edited in its current state.',
              style:
                  const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
            ),
          ),
      ],
    );
  }

  /// The invoice as a document panel, the way Xero and Zoho both present it.
  Widget _document(XeroInvoice invoice, {required bool narrow}) {
    final struck = invoice.status.isStruckThrough;

    final facts = <(String, String)>[
      ('Customer', invoice.contactName),
      if (invoice.reference.isNotEmpty) ('Reference', invoice.reference),
      if (invoice.date != null)
        ('Invoice date', xeroDate.format(invoice.date!)),
      if (invoice.dueDate != null)
        ('Due date', xeroDate.format(invoice.dueDate!)),
      (
        'Amounts are',
        switch (invoice.lineAmountTypes) {
          XeroLineAmountType.inclusive => 'Including VAT',
          XeroLineAmountType.noTax => 'No VAT',
          XeroLineAmountType.exclusive => 'Excluding VAT',
        }
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: ZohoPalette.surface,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: EdgeInsets.all(narrow ? 16 : 24),
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
                  Text(
                    invoice.amountPaid > 0 && invoice.amountDue > 0
                        ? 'AMOUNT DUE'
                        : 'TOTAL',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: ZohoPalette.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    xeroCurrency.format(
                        invoice.amountPaid > 0 && invoice.amountDue > 0
                            ? invoice.amountDue
                            : invoice.total),
                    style: TextStyle(
                      fontSize: narrow ? 20 : 24,
                      fontWeight: FontWeight.w700,
                      color: ZohoPalette.textPrimary,
                      fontFeatures: xeroTabular,
                      decoration: struck ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(height: 1, color: ZohoPalette.border),
          const SizedBox(height: 16),
          // Two columns of facts on a desktop, one on a phone.
          Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              for (final (label, value) in facts)
                SizedBox(
                  width: narrow ? double.infinity : 250,
                  child: _DetailRow(label: label, value: value),
                ),
            ],
          ),
          if (invoice.lineItems.isNotEmpty) ...[
            const SizedBox(height: 24),
            _XeroLineItemsTable(lineItems: invoice.lineItems, narrow: narrow),
            const SizedBox(height: 16),
            _totalsBlock(invoice),
          ],
        ],
      ),
    );
  }

  /// Subtotal / VAT / total, aligned under the line-item amounts.
  Widget _totalsBlock(XeroInvoice invoice) {
    Widget row(String label, String value, {bool bold = false, Color? color}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 13,
                        color: bold
                            ? ZohoPalette.textPrimary
                            : ZohoPalette.textMuted,
                        fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
              ),
              Text(
                value,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: bold ? 15 : 13,
                  color: color ?? ZohoPalette.textPrimary,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  fontFeatures: xeroTabular,
                ),
              ),
            ],
          ),
        );

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          children: [
            row('Subtotal', xeroCurrency.format(invoice.subTotal)),
            if (invoice.lineAmountTypes != XeroLineAmountType.noTax)
              row('VAT', xeroCurrency.format(invoice.totalTax)),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Divider(height: 1, color: ZohoPalette.border),
            ),
            row('Total', xeroCurrency.format(invoice.total), bold: true),
            if (invoice.amountPaid > 0) ...[
              row('Less paid', '− ${xeroCurrency.format(invoice.amountPaid)}',
                  color: _paymentGreen),
              row('Amount due', xeroCurrency.format(invoice.amountDue),
                  bold: true,
                  color: invoice.isOverdue ? const Color(0xFFE03E3E) : null),
            ],
          ],
        ),
      ),
    );
  }
}

/// One label/value pair in the document panel.
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          value.isEmpty ? '—' : value,
          style: const TextStyle(
            fontSize: 14,
            color: ZohoPalette.textPrimary,
            fontWeight: FontWeight.w500,
            fontFeatures: xeroTabular,
          ),
        ),
      ],
    );
  }
}

/// Line items, laid out as Xero prints them.
///
/// Carries a Tax column the Zoho table has no need for — Junk & Stuff charges
/// no VAT, so per-line tax there is always nothing.
///
/// On a phone the four figure columns would leave the description a sliver,
/// so each line stacks instead: description over "qty × rate", amount right.
class _XeroLineItemsTable extends StatelessWidget {
  final List<XeroLineItem> lineItems;
  final bool narrow;

  const _XeroLineItemsTable({required this.lineItems, required this.narrow});

  static String _qty(double q) =>
      q.toStringAsFixed(q == q.roundToDouble() ? 0 : 2);

  static const _figure = TextStyle(
    fontSize: 13,
    color: ZohoPalette.textPrimary,
    fontFeatures: xeroTabular,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: ZohoPalette.headerHeight,
            color: ZohoPalette.headerBackground,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: narrow
                ? const Row(children: [
                    Expanded(child: _HeaderCell('Item')),
                    _HeaderCell('Amount', right: true),
                  ])
                : const Row(
                    children: [
                      Expanded(child: _HeaderCell('Description')),
                      SizedBox(
                          width: 60, child: _HeaderCell('Qty', right: true)),
                      SizedBox(
                          width: 110, child: _HeaderCell('Rate', right: true)),
                      SizedBox(
                          width: 90, child: _HeaderCell('Tax', right: true)),
                      SizedBox(
                          width: 120,
                          child: _HeaderCell('Amount', right: true)),
                    ],
                  ),
          ),
          for (var i = 0; i < lineItems.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                border: i == lineItems.length - 1
                    ? null
                    : const Border(
                        bottom: BorderSide(color: ZohoPalette.border)),
              ),
              child: narrow ? _narrowRow(lineItems[i]) : _wideRow(lineItems[i]),
            ),
        ],
      ),
    );
  }

  Widget _description(XeroLineItem li, {String? extra}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            li.description.isEmpty ? '—' : li.description,
            style: const TextStyle(
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w500,
              color: ZohoPalette.textPrimary,
            ),
          ),
          if (extra != null || li.accountCode.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              [
                if (extra != null) extra,
                if (li.accountCode.isNotEmpty) 'Account ${li.accountCode}',
              ].join(' · '),
              style: const TextStyle(
                fontSize: 12,
                color: ZohoPalette.textMuted,
                fontFeatures: xeroTabular,
              ),
            ),
          ],
        ],
      );

  Widget _wideRow(XeroLineItem li) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _description(li)),
          SizedBox(
            width: 60,
            child: Text(_qty(li.quantity),
                textAlign: TextAlign.right, style: _figure),
          ),
          SizedBox(
            width: 110,
            child: Text(xeroCurrency.format(li.unitAmount),
                textAlign: TextAlign.right, style: _figure),
          ),
          SizedBox(
            width: 90,
            child: Text(
                li.taxAmount == 0 ? '—' : xeroCurrency.format(li.taxAmount),
                textAlign: TextAlign.right,
                style: _figure.copyWith(color: ZohoPalette.textMuted)),
          ),
          SizedBox(
            width: 120,
            child: Text(
              // Xero's own computed figure, not our arithmetic — it applies
              // the rounding.
              xeroCurrency.format(li.lineAmount),
              textAlign: TextAlign.right,
              style: _figure.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );

  Widget _narrowRow(XeroLineItem li) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _description(
              li,
              extra:
                  '${_qty(li.quantity)} × ${xeroCurrency.format(li.unitAmount)}'
                  '${li.taxAmount == 0 ? '' : ' · VAT ${xeroCurrency.format(li.taxAmount)}'}',
            ),
          ),
          const SizedBox(width: 12),
          Text(xeroCurrency.format(li.lineAmount),
              style: _figure.copyWith(fontWeight: FontWeight.w600)),
        ],
      );
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
