import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/collection_job.dart';
import '../../models/job_list_item.dart';
import '../../models/zoho_customer.dart';
import '../../models/zoho_invoice.dart';
import '../../providers/collection_schedule_provider.dart';
import '../../providers/zoho_customers_provider.dart';
import '../../providers/zoho_invoices_provider.dart';
import '../../services/job_list_service.dart';
import '../../providers/job_type_provider.dart';
import '../../utils/schedule_time.dart';
import '../../utils/zoho_org.dart';
import 'line_items_editor.dart';
import 'zoho_invoice_detail_screen.dart';
import 'zoho_table.dart';

/// Raise a Zoho invoice for a Junk & Stuff job.
///
/// Reachable from two places, hence the two entry points:
///  * [job] — a scheduled collection job, from the Collection Schedule. The
///    commercial fields live on the backing JobListItem, which is looked up.
///  * [item] — a Job List row directly, where there is nothing to look up.
///
/// Exactly one must be supplied. Pre-fills the customer from the client name
/// and a line item from the job description, and lets the invoice number be
/// confirmed or overridden. On success the Zoho ids are written back onto the
/// JobListItem, so the job carries its invoice link in both places.
class CreateInvoiceDialog extends riverpod.ConsumerStatefulWidget {
  final CollectionJob? job;

  /// Supplied when invoicing straight from the Job List.
  final JobListItem? item;

  const CreateInvoiceDialog({super.key, this.job, this.item})
      : assert(job != null || item != null,
            'CreateInvoiceDialog needs either a collection job or a job list item');

  @override
  riverpod.ConsumerState<CreateInvoiceDialog> createState() =>
      _CreateInvoiceDialogState();
}

class _CreateInvoiceDialogState
    extends riverpod.ConsumerState<CreateInvoiceDialog> {
  final _formKey = GlobalKey<FormState>();

  /// The books this job bills through, from its job type's company. A
  /// collection job's backing item is not loaded yet at first build, so that
  /// path resolves from the collection job's own type.
  String get _orgId {
    final item = widget.item ?? _backingItem;
    if (item != null) return ZohoOrg.forJob(item);
    return ZohoOrg.forJobTypeId(widget.job?.jobType ?? '');
  }

  late final TextEditingController _invoiceNumberController;
  late final TextEditingController _notesController;

  /// Seeded with one line from the job, then freely editable.
  late List<ZohoLineItem> _lineItems;

  ZohoCustomer? _selectedCustomer;
  JobListItem? _backingItem;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();

    // The schedule's CollectionJob is a projection — the commercial fields
    // (invoice number, amount, client) live on the backing JobListItem. From
    // the Job List we already hold that item, so there is nothing to resolve.
    _backingItem = widget.item ??
        ref.read(collectionScheduleRiverpod).jobListItemFor(widget.job!.id);

    final amount = _backingItem == null
        ? 0.0
        : (_backingItem!.amountExclVat > 0
            ? _backingItem!.amountExclVat
            : _backingItem!.amount);

    _invoiceNumberController =
        TextEditingController(text: _backingItem?.invoice ?? '');
    _notesController = TextEditingController();
    _lineItems = [
      ZohoLineItem(
        // Junk & Stuff's historical default; other books name the line after
        // the job type, since "Junk collection" means nothing on a Happy Sun
        // window-cleaning invoice.
        name: _orgId == ZohoOrg.junkAndStuff || _backingItem == null
            ? 'Junk collection'
            : (JobTypeProvider.instance
                    ?.getJobTypeById(_backingItem!.jobTypeId)
                    ?.label ??
                'Service'),
        description: _defaultDescription(),
        rate: amount,
        quantity: 1,
      ),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final customers = ref.read(zohoCustomersRiverpod(_orgId));
      await customers.initialize();
      if (!mounted) return;
      // Best-effort match of the free-text client name against Zoho contacts.
      final clientName = _backingItem?.client ??
          (widget.job != null && widget.job!.clients.isNotEmpty
              ? widget.job!.clients.first
              : '');
      final match = customers.findByName(clientName);
      if (match != null) setState(() => _selectedCustomer = match);
    });
  }

  String _defaultDescription() {
    final parts = <String>[];
    final job = widget.job;
    if (job != null) {
      if (job.location.isNotEmpty) parts.add(job.location);
      if (job.notes.isNotEmpty) parts.add(job.notes);
    } else {
      // From the Job List there is no schedule projection to read location and
      // notes off, so the item's own fields stand in.
      final item = _backingItem;
      if (item != null) {
        if (item.collectionAddress.isNotEmpty) {
          parts.add(item.collectionAddress);
        }
        if (item.area.isNotEmpty) parts.add(item.area);
      }
    }
    final detail = parts.join(' — ');
    return detail.isEmpty ? 'Junk collection' : 'Junk collection – $detail';
  }

  @override
  void dispose() {
    _invoiceNumberController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCustomer == null) {
      setState(() => _error = 'Choose a customer first.');
      return;
    }

    final usable = _lineItems
        .where((li) => li.name.isNotEmpty && li.quantity > 0)
        .toList();
    if (usable.isEmpty) {
      setState(() =>
          _error = 'Add at least one line item with a name and quantity.');
      return;
    }
    if (usable.every((li) => li.amount <= 0)) {
      setState(() => _error = 'The invoice total must be greater than zero.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    final invoiceNumber = _invoiceNumberController.text.trim();

    // Invoice date and due date are the day the invoice is *issued*, not the
    // day the job is scheduled for. Anchored to SAST via scheduleToday() so a
    // client in another timezone cannot stamp the wrong civil day. Matches
    // the Add/Edit Job invoicing path.
    final issuedOn = scheduleToday();

    final draft = ZohoInvoice(
      invoiceId: '',
      // Empty lets Zoho auto-number; non-empty is preserved via
      // ignore_auto_number_generation.
      invoiceNumber: invoiceNumber,
      customerId: _selectedCustomer!.contactId,
      date: issuedOn,
      dueDate: issuedOn,
      notes: _notesController.text.trim(),
      lineItems: usable,
    );

    try {
      final created =
          await ref.read(zohoInvoicesRiverpod(_orgId)).createInvoice(draft);

      // Write the link back to the JobListItem. If this fails the invoice
      // still exists in Zoho, so say so rather than implying nothing happened.
      try {
        final item = _backingItem;
        if (widget.job == null && item != null) {
          // Straight from the Job List: link transactionally against the
          // item's own month. Going through the collection-schedule provider
          // would resolve the job against *its* current month, which need not
          // be the one this row lives in.
          await ref.read(jobListServiceRiverpod).linkZohoInvoiceTxn(
                jobId: item.id,
                date: item.date,
                zohoContactId: _selectedCustomer!.contactId,
                zohoInvoiceId: created.invoiceId,
                zohoInvoiceNumber: created.invoiceNumber,
                zohoInvoiceStatus: created.status.apiValue,
                invoiceNumber: created.invoiceNumber,
                amount: created.total,
              );
        } else {
          await ref.read(collectionScheduleRiverpod).linkZohoInvoice(
                jobId: widget.job!.id,
                contactId: _selectedCustomer!.contactId,
                invoiceId: created.invoiceId,
                invoiceNumber: created.invoiceNumber,
                status: created.status.apiValue,
              );
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isSaving = false;
            _error = 'Invoice ${created.invoiceNumber} was created in Zoho, '
                'but linking it to this job failed: $e';
          });
        }
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invoice ${created.invoiceNumber} created'),
          backgroundColor: Colors.green,
          action: SnackBarAction(
            label: 'View',
            textColor: Colors.white,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ZohoInvoiceDetailScreen(
                    orgId: _orgId, invoiceId: created.invoiceId),
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final customersProvider = ref.watch(zohoCustomersRiverpod(_orgId));
    final alreadyInvoiced = _backingItem?.hasZohoInvoice ?? false;

    return AlertDialog(
      title: const Text('Create invoice'),
      content: SizedBox(
        // Wide enough for the line-item table's fixed qty/rate/amount columns.
        width: 760,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (alreadyInvoiced)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      border: Border.all(color: Colors.orange.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'This job is already linked to Zoho invoice '
                      '${_backingItem!.zohoInvoiceNumber}. Creating another '
                      'will replace the link on the job.',
                      style: TextStyle(color: Colors.orange.shade900),
                    ),
                  ),

                Text(
                  // The schedule shows the collection location; the Job List
                  // has no such projection, so the row identifies itself by
                  // client and area instead.
                  widget.job?.location ??
                      [
                        _backingItem?.client ?? '',
                        _backingItem?.area ?? '',
                      ].where((p) => p.isNotEmpty).join(' · '),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 12),

                // Customer picker — loads from Zoho on open.
                if (customersProvider.isLoading &&
                    customersProvider.customers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (customersProvider.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            customersProvider.error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                        TextButton(
                          onPressed: customersProvider.refresh,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                else
                  DropdownButtonFormField<ZohoCustomer>(
                    // `initialValue` seeds FormField state only on first
                    // build, so the key forces a rebuild when the async
                    // client-name match lands and pre-selects a customer.
                    key: ValueKey(_selectedCustomer?.contactId),
                    initialValue: _selectedCustomer,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Customer *',
                      border: OutlineInputBorder(),
                    ),
                    items: customersProvider.customers
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(c.displayName,
                                  overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (c) => setState(() => _selectedCustomer = c),
                    validator: (v) => v == null ? 'Choose a customer' : null,
                  ),

                const SizedBox(height: 12),
                TextFormField(
                  controller: _invoiceNumberController,
                  decoration: const InputDecoration(
                    labelText: 'Invoice number',
                    border: OutlineInputBorder(),
                    helperText: 'Leave blank to let Zoho auto-number',
                  ),
                ),
                const SizedBox(height: 16),
                LineItemsEditor(
                  orgId: _orgId,
                  lineItems: _lineItems,
                  enabled: !_isSaving,
                  onChanged: (items) => _lineItems = items,
                ),
                const SizedBox(height: 4),
                const Text(
                  'No VAT applied.',
                  style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notesController,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'Notes (printed on the invoice)',
                    border: OutlineInputBorder(),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _create,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create in Zoho'),
        ),
      ],
    );
  }
}
