import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/company.dart';
import '../../models/job_list_item.dart';
import '../../models/xero_contact.dart';
import '../../models/xero_invoice.dart';
import '../../providers/company_provider.dart';
import '../../providers/job_type_provider.dart';
import '../../providers/xero_tax_rates_provider.dart';
import '../../services/job_list_service.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/schedule_time.dart';
import '../zoho/invoice_save_saga.dart';
import '../zoho/saga_progress_panel.dart';
import '../zoho/zoho_table.dart';
import 'xero_contact_picker.dart';
import 'xero_invoice_detail_screen.dart';
import 'xero_line_items_editor.dart';
import 'xero_ui.dart';

/// Raise a Xero invoice for an existing Job List item.
///
/// Reuses [InvoiceSaveSaga] — the job already exists here, so its first step is
/// a no-op, but the ordering, resume-after-failure and never-create-twice rules
/// are the same ones the Zoho flow relies on, and worth not reimplementing.
///
/// When the dialog closes on "View invoice", the new invoice opens on the
/// caller's navigator rather than the dialog's root one, so Back returns to the
/// Job List as it does when an invoice is opened from its row.
Future<void> showCreateXeroInvoiceDialog(
  BuildContext context,
  JobListItem job,
) async {
  final openInvoiceId = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => CreateXeroInvoiceDialog(job: job),
  );
  if (openInvoiceId == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => XeroInvoiceDetailScreen(invoiceId: openInvoiceId),
  ));
}

/// Payment terms offered beside the due date. Days after the invoice date.
const _dueTerms = <int, String>{0: 'On receipt', 7: '7 days', 30: '30 days'};

class CreateXeroInvoiceDialog extends riverpod.ConsumerStatefulWidget {
  final JobListItem job;

  const CreateXeroInvoiceDialog({super.key, required this.job});

  @override
  riverpod.ConsumerState<CreateXeroInvoiceDialog> createState() =>
      _CreateXeroInvoiceDialogState();
}

class _CreateXeroInvoiceDialogState
    extends riverpod.ConsumerState<CreateXeroInvoiceDialog> {
  late final TextEditingController _descriptionController;
  late final TextEditingController _amountController;
  late final TextEditingController _quantityController;
  late final TextEditingController _referenceController;

  XeroContact? _contact;
  DateTime _issuedOn = scheduleToday();
  DateTime _dueOn = scheduleToday();

  InvoiceSaveSaga<XeroContact, XeroInvoice>? _saga;
  String? _configError;

  @override
  void initState() {
    super.initState();
    final job = widget.job;
    final typeLabel =
        JobTypeProvider.instance?.getJobTypeLabel(job.jobTypeId) ?? '';

    _descriptionController = TextEditingController(
      text: [
        if (typeLabel.isNotEmpty) typeLabel,
        if (job.area.isNotEmpty) job.area,
      ].join(' — '),
    );
    _quantityController = TextEditingController(
      text: job.quantity > 0 ? job.quantity.toString() : '1',
    );
    // The job's own figure is the starting point; Xero recomputes the totals.
    _amountController = TextEditingController(
      text: job.amount > 0 ? job.amount.toStringAsFixed(2) : '',
    );
    _referenceController = TextEditingController(text: job.invoice);
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _amountController.dispose();
    _quantityController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  Company? get _company => ref.read(companyRiverpod).getById(Company.clmId);

  String get _salesAccountCode =>
      _company?.providerConfig['salesAccountCode'] ?? '';

  String get _salesTaxType => _company?.providerConfig['salesTaxType'] ?? '';

  /// Whether this job's type charges VAT. Amounts are always excl VAT.
  XeroLineAmountType get _lineAmountType {
    final chargesVat =
        JobTypeProvider.instance?.chargesVat(widget.job.jobTypeId) ?? false;
    return XeroLineAmountType.forJob(
      chargesVat: chargesVat,
      priceIsInclVat: false,
    );
  }

  double get _unitAmount => double.tryParse(_amountController.text.trim()) ?? 0;
  double get _quantity => double.tryParse(_quantityController.text.trim()) ?? 1;

  bool get _canSubmit => _saga == null && _missing.isEmpty;

  /// What still stands between the form and the Create button, in words, so a
  /// disabled button never leaves anyone guessing.
  List<String> get _missing => [
        // Must exist in Xero: the saga no longer creates contacts.
        if (!(_contact?.existsInXero ?? false)) 'choose a customer',
        if (_descriptionController.text.trim().isEmpty) 'add a description',
        if (_unitAmount <= 0) 'enter a price',
        if (_salesAccountCode.isEmpty) 'set the Xero sales account',
      ];

  /// The due date never sits before the invoice date — Xero would accept it,
  /// and the invoice would be overdue the moment it was raised.
  void _setIssuedOn(DateTime d) {
    setState(() {
      final term = _dueOn.difference(_issuedOn).inDays;
      _issuedOn = d;
      _dueOn = d.add(Duration(days: term < 0 ? 0 : term));
    });
  }

  int? get _selectedTerm {
    final days = _dueOn.difference(_issuedOn).inDays;
    return _dueTerms.containsKey(days) ? days : null;
  }

  /// A stable Idempotency-Key. Xero caps these at 128 characters and they must
  /// be identical across retries of the *same* logical request, so the parts are
  /// normalised rather than passed through raw.
  static String _idempotencyKey(String kind, String jobId, [String? extra]) {
    final slug = (extra ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final key = ['clm', kind, jobId, if (slug.isNotEmpty) slug].join('-');
    return key.length <= 128 ? key : key.substring(0, 128);
  }

  XeroInvoice _buildInvoice(String contactId) {
    return XeroInvoice(
      contactId: contactId,
      date: _issuedOn,
      dueDate: _dueOn,
      reference: _referenceController.text.trim(),
      lineAmountTypes: _lineAmountType,
      lineItems: [
        XeroLineItem(
          description: _descriptionController.text.trim(),
          quantity: _quantity,
          unitAmount: _unitAmount,
          accountCode: _salesAccountCode,
          // Empty means "use the account's default", which is right for a
          // NoTax invoice and harmless otherwise.
          taxType:
              _lineAmountType == XeroLineAmountType.noTax ? '' : _salesTaxType,
        ),
      ],
    );
  }

  void _start() {
    if (_salesAccountCode.isEmpty) {
      setState(() => _configError =
          'No Xero sales account is configured for Community Life Media. '
              'Set it in Settings → Companies before invoicing.');
      return;
    }

    final service = ref.read(xeroAccountingServiceRiverpod);
    final jobListService = ref.read(jobListServiceRiverpod);
    final job = widget.job;
    final seed = _contact!;

    setState(() {
      _configError = null;
      _saga = InvoiceSaveSaga<XeroContact, XeroInvoice>(
        providerName: 'Xero',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        // Created up front by the picker, so the saga only records it.
        customer: seed,
        onProgress: () {
          if (mounted) setState(() {});
        },
        saveJob: () async => job,
        // Keyed on the job alone, deliberately. If a previous attempt raised
        // the invoice but failed to link it, this replays that invoice instead
        // of raising a second one for the same job — which is exactly what
        // should happen. Including the amount here would let a corrected figure
        // produce a duplicate invoice in the books.
        createInvoice: (savedJob, contact) => service.createInvoice(
          _buildInvoice(contact.contactId),
          // A job whose earlier invoice was voided and unlinked is a new
          // request: without the revision Xero would replay the void one.
          idempotencyKey: _idempotencyKey(
              'invoice',
              savedJob.id,
              savedJob.voidedInvoiceIds.isEmpty
                  ? null
                  : 'r${savedJob.voidedInvoiceIds.length}'),
        ),
        linkToJob: (savedJob, contact, invoice) =>
            jobListService.linkAccountingInvoiceTxn(
          jobId: savedJob.id,
          date: savedJob.date,
          providerId: 'xero',
          contactId: contact.contactId,
          invoiceId: invoice.invoiceId,
          invoiceNumber: invoice.invoiceNumber,
          invoiceStatus: invoice.status.apiValue,
          // Xero's own split, rounding included — recomputing it here would
          // risk the Job List disagreeing with the books by cents.
          subTotal: invoice.subTotal,
          total: invoice.total,
        ),
      );
    });

    _saga!.run();
  }

  @override
  Widget build(BuildContext context) {
    final saga = _saga;
    final job = widget.job;

    // Tax rates feed the indicative VAT line only. Loaded once per session and
    // shared with the line-items editor, so this costs at most one call.
    final taxRates = ref.watch(xeroTaxRatesRiverpod);
    if (!taxRates.hasLoaded && !taxRates.isLoading && taxRates.error == null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => taxRates.ensureLoaded());
    }
    final totals = XeroLineTotals.forLine(
      amount: _unitAmount * _quantity,
      lineAmountType: _lineAmountType,
      ratePercent: taxRates.percentFor(_salesTaxType),
    );

    return AlertDialog(
      insetPadding: xeroDialogInset(context),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(saga == null ? 'New invoice' : 'Creating invoice'),
          const SizedBox(height: 2),
          // Named so nobody has to wonder whose books this lands in.
          const Text(
            'Community Life Media · Xero',
            style: TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _JobSummary(job: job),
              const SizedBox(height: 18),
              if (saga == null) ...[
                const XeroSectionLabel('Bill to'),
                XeroContactPicker(
                  value: _contact,
                  seedName: [
                    job.client.trim(),
                    job.area.trim(),
                  ].where((p) => p.isNotEmpty).join(', '),
                  onChanged: (c) => setState(() => _contact = c),
                ),
                const SizedBox(height: 20),
                const XeroSectionLabel('Line item'),
                TextField(
                  controller: _descriptionController,
                  onChanged: (_) => setState(() {}),
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _quantityController,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontFeatures: xeroTabular),
                        decoration: const InputDecoration(
                          labelText: 'Quantity',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontFeatures: xeroTabular),
                        decoration: InputDecoration(
                          labelText: 'Unit price',
                          prefixText: 'R ',
                          suffixText: switch (_lineAmountType) {
                            XeroLineAmountType.inclusive => 'incl VAT',
                            XeroLineAmountType.noTax => 'no VAT',
                            XeroLineAmountType.exclusive => 'excl VAT',
                          },
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const XeroSectionLabel('Details'),
                TextField(
                  controller: _referenceController,
                  decoration: const InputDecoration(
                    labelText: 'Reference',
                    helperText: 'Shown to the customer on the invoice',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                XeroFieldPair(
                  first: XeroDateField(
                    label: 'Invoice date',
                    value: _issuedOn,
                    onChanged: _setIssuedOn,
                  ),
                  second: XeroDateField(
                    label: 'Due date',
                    value: _dueOn,
                    firstDate: _issuedOn,
                    onChanged: (d) => setState(() => _dueOn = d),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Due',
                        style: TextStyle(
                            fontSize: 12, color: ZohoPalette.textMuted)),
                    for (final term in _dueTerms.entries)
                      ChoiceChip(
                        label: Text(term.value),
                        selected: _selectedTerm == term.key,
                        visualDensity: VisualDensity.compact,
                        labelStyle: const TextStyle(fontSize: 12),
                        onSelected: (_) => setState(() =>
                            _dueOn = _issuedOn.add(Duration(days: term.key))),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                _TotalsPreview(
                  totals: totals,
                  lineAmountType: _lineAmountType,
                  vatKnown: taxRates.percentFor(_salesTaxType) != null,
                ),
                if (_salesAccountCode.isEmpty || _configError != null) ...[
                  const SizedBox(height: 14),
                  XeroNotice(
                    tone: _configError != null
                        ? XeroNoticeTone.error
                        : XeroNoticeTone.warning,
                    message: _configError ??
                        'No Xero sales account is configured for Community '
                            'Life Media. Set it in Settings → Companies first.',
                  ),
                ],
              ] else
                // onRetry matters here: the saga resumes from the failed
                // step, so a link failure after the invoice was raised is
                // recoverable without billing the customer twice.
                SagaProgressPanel(saga: saga, onRetry: () => _saga!.run()),
              if (saga != null && saga.isFinished && !saga.hasFailed) ...[
                const SizedBox(height: 12),
                XeroNotice(
                  tone: XeroNoticeTone.success,
                  message: 'Invoice ${saga.invoice?.invoiceNumber ?? ''} is in '
                      'Xero and linked to this job.',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (saga == null) ...[
          if (_missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'To continue, ${_missing.join(', ')}.',
                style:
                    const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: _canSubmit ? _start : null,
            icon: const Icon(Icons.receipt_long, size: 16),
            label: Text(totals.inclVat > 0
                ? 'Create · ${xeroCurrency.format(totals.inclVat)}'
                : 'Create invoice'),
          ),
        ] else ...[
          if (saga.hasFailed && !saga.isRunning)
            TextButton(
              onPressed: () => saga.run(),
              child: const Text('Retry'),
            ),
          TextButton(
            onPressed:
                saga.isRunning ? null : () => Navigator.of(context).pop(),
            // Once the invoice exists, closing leaves a real invoice behind —
            // say so rather than offering a neutral "Cancel".
            child: Text(saga.invoiceExists ? 'Done' : 'Close'),
          ),
          if (saga.invoiceExists && !saga.isRunning)
            FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(saga.invoice!.invoiceId),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('View invoice'),
            ),
        ],
      ],
    );
  }
}

/// The job being invoiced, at a glance — so the figures below can be checked
/// against it without closing the dialog.
class _JobSummary extends StatelessWidget {
  final JobListItem job;

  const _JobSummary({required this.job});

  @override
  Widget build(BuildContext context) {
    final typeLabel =
        JobTypeProvider.instance?.getJobTypeLabel(job.jobTypeId) ?? '';
    final facts = [
      xeroDate.format(job.date),
      if (typeLabel.isNotEmpty) typeLabel,
      if (job.quantity > 0)
        '${NumberFormat.decimalPattern().format(job.quantity)} qty',
      if (job.amount > 0) '${xeroCurrency.format(job.amount)} on the Job List',
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ZohoPalette.headerBackground,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.work_outline,
              size: 18, color: ZohoPalette.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [job.client, job.area]
                      .where((p) => p.trim().isNotEmpty)
                      .join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: ZohoPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  facts.join(' · '),
                  style: const TextStyle(
                    fontSize: 12,
                    color: ZohoPalette.textMuted,
                    fontFeatures: xeroTabular,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Subtotal, VAT and total for the one line being raised.
///
/// Indicative, like the line-items editor's: Xero rounds per line and its own
/// split is what gets written back to the job.
class _TotalsPreview extends StatelessWidget {
  final XeroLineTotals totals;
  final XeroLineAmountType lineAmountType;
  final bool vatKnown;

  const _TotalsPreview({
    required this.totals,
    required this.lineAmountType,
    required this.vatKnown,
  });

  @override
  Widget build(BuildContext context) {
    final noTax = lineAmountType == XeroLineAmountType.noTax;

    Widget row(String label, double value, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: strong ? 14 : 13,
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
                    color: strong
                        ? ZohoPalette.textPrimary
                        : ZohoPalette.textMuted,
                  ),
                ),
              ),
              Text(
                xeroCurrency.format(value),
                style: TextStyle(
                  fontSize: strong ? 17 : 13,
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                  color: ZohoPalette.textPrimary,
                  fontFeatures: xeroTabular,
                ),
              ),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!noTax) ...[
            row('Subtotal (excl VAT)', totals.exclVat),
            row(vatKnown ? 'VAT' : 'VAT (rate not loaded)', totals.vat),
            const Divider(height: 14, color: ZohoPalette.border),
          ],
          row(noTax ? 'Total' : 'Total (incl VAT)', totals.inclVat,
              strong: true),
          const SizedBox(height: 4),
          const Text(
            'Xero issues the invoice number and confirms the final total.',
            style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
          ),
        ],
      ),
    );
  }
}
