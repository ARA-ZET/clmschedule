import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/company.dart';
import '../../models/job_list_item.dart';
import '../../models/xero_contact.dart';
import '../../models/xero_invoice.dart';
import '../../providers/company_provider.dart';
import '../../providers/job_type_provider.dart';
import '../../services/job_list_service.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/schedule_time.dart';
import '../zoho/invoice_save_saga.dart';
import '../zoho/saga_progress_panel.dart';
import 'xero_contact_picker.dart';

/// Raise a Xero invoice for an existing Job List item.
///
/// Reuses [InvoiceSaveSaga] — the job already exists here, so its first step is
/// a no-op, but the ordering, resume-after-failure and never-create-twice rules
/// are the same ones the Zoho flow relies on, and worth not reimplementing.
Future<void> showCreateXeroInvoiceDialog(
  BuildContext context,
  JobListItem job,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => CreateXeroInvoiceDialog(job: job),
  );
}

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

  bool get _canSubmit =>
      _saga == null &&
      // Must exist in Xero: the saga no longer creates contacts.
      (_contact?.existsInXero ?? false) &&
      _descriptionController.text.trim().isNotEmpty &&
      _unitAmount > 0 &&
      _salesAccountCode.isNotEmpty;

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
          idempotencyKey: _idempotencyKey('invoice', savedJob.id,
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
    final dateFormat = DateFormat('d MMM y');
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final lineTotal = _unitAmount * _quantity;

    return AlertDialog(
      title: const Text('Create invoice in Xero'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.job.client} · ${widget.job.area}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              if (saga == null) ...[
                XeroContactPicker(
                  value: _contact,
                  seedName: [
                    widget.job.client.trim(),
                    widget.job.area.trim(),
                  ].where((p) => p.isNotEmpty).join(', '),
                  onChanged: (c) => setState(() => _contact = c),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _descriptionController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _quantityController,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Quantity',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Unit amount',
                          helperText:
                              _lineAmountType == XeroLineAmountType.inclusive
                                  ? 'Incl VAT'
                                  : _lineAmountType == XeroLineAmountType.noTax
                                      ? 'No VAT'
                                      : 'Excl VAT',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _referenceController,
                  decoration: const InputDecoration(
                    labelText: 'Reference',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _DateField(
                        label: 'Invoice date',
                        value: _issuedOn,
                        format: dateFormat,
                        onChanged: (d) => setState(() => _issuedOn = d),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DateField(
                        label: 'Due date',
                        value: _dueOn,
                        format: dateFormat,
                        onChanged: (d) => setState(() => _dueOn = d),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Line total ${currency.format(lineTotal)}'
                    '${_lineAmountType == XeroLineAmountType.exclusive ? ' excl VAT' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (_salesAccountCode.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'No Xero sales account is configured for Community Life '
                      'Media. Set it in Settings → Companies first.',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  ),
                if (_configError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_configError!,
                        style:
                            const TextStyle(fontSize: 12, color: Colors.red)),
                  ),
              ] else
                // onRetry matters here: the saga resumes from the failed
                // step, so a link failure after the invoice was raised is
                // recoverable without billing the customer twice.
                SagaProgressPanel(saga: saga, onRetry: () => _saga!.run()),
            ],
          ),
        ),
      ),
      actions: [
        if (saga == null) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _canSubmit ? _start : null,
            child: const Text('Create invoice'),
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
        ],
      ],
    );
  }
}

class _DateField extends StatelessWidget {
  final String label;
  final DateTime value;
  final DateFormat format;
  final ValueChanged<DateTime> onChanged;

  const _DateField({
    required this.label,
    required this.value,
    required this.format,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(value.year - 2),
          lastDate: DateTime(value.year + 2),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        child: Text(format.format(value)),
      ),
    );
  }
}
