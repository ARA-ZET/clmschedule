import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/collection_job.dart';
import '../../models/job_list_item.dart';
import '../../models/zoho_customer.dart';
import '../../models/zoho_invoice.dart';
import '../../providers/collection_schedule_provider.dart';
import '../../providers/zoho_customers_provider.dart';
import '../../providers/zoho_invoices_provider.dart';
import 'zoho_invoice_detail_screen.dart';

/// Raise a Zoho invoice for a scheduled collection job.
///
/// Pre-fills the customer from the job's client name and a line item from the
/// job description, and lets the invoice number be confirmed or overridden.
/// On success the Zoho ids are written back onto the backing JobListItem, so
/// the job carries its invoice link on both the schedule and the Job List.
class CreateInvoiceDialog extends riverpod.ConsumerStatefulWidget {
  final CollectionJob job;

  const CreateInvoiceDialog({super.key, required this.job});

  @override
  riverpod.ConsumerState<CreateInvoiceDialog> createState() =>
      _CreateInvoiceDialogState();
}

class _CreateInvoiceDialogState
    extends riverpod.ConsumerState<CreateInvoiceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _invoiceNumberController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _amountController;

  ZohoCustomer? _selectedCustomer;
  JobListItem? _backingItem;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();

    // The schedule's CollectionJob is a projection — the commercial fields
    // (invoice number, amount, client) live on the backing JobListItem.
    _backingItem =
        ref.read(collectionScheduleRiverpod).jobListItemFor(widget.job.id);

    final amount = _backingItem == null
        ? 0.0
        : (_backingItem!.amountExclVat > 0
            ? _backingItem!.amountExclVat
            : _backingItem!.amount);

    _invoiceNumberController =
        TextEditingController(text: _backingItem?.invoice ?? '');
    _descriptionController = TextEditingController(text: _defaultDescription());
    _amountController = TextEditingController(
      text: amount > 0 ? amount.toStringAsFixed(2) : '',
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final customers = ref.read(zohoCustomersRiverpod);
      await customers.initialize();
      if (!mounted) return;
      // Best-effort match of the free-text client name against Zoho contacts.
      final clientName = _backingItem?.client ??
          (widget.job.clients.isNotEmpty ? widget.job.clients.first : '');
      final match = customers.findByName(clientName);
      if (match != null) setState(() => _selectedCustomer = match);
    });
  }

  String _defaultDescription() {
    final parts = <String>[];
    if (widget.job.location.isNotEmpty) parts.add(widget.job.location);
    if (widget.job.notes.isNotEmpty) parts.add(widget.job.notes);
    final detail = parts.join(' — ');
    return detail.isEmpty ? 'Junk collection' : 'Junk collection – $detail';
  }

  @override
  void dispose() {
    _invoiceNumberController.dispose();
    _descriptionController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCustomer == null) {
      setState(() => _error = 'Choose a customer first.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    final amount = double.parse(_amountController.text.trim());
    final invoiceNumber = _invoiceNumberController.text.trim();

    final draft = ZohoInvoice(
      invoiceId: '',
      // Empty lets Zoho auto-number; non-empty is preserved via
      // ignore_auto_number_generation.
      invoiceNumber: invoiceNumber,
      customerId: _selectedCustomer!.contactId,
      date: widget.job.date,
      lineItems: [
        ZohoLineItem(
          name: _descriptionController.text.trim(),
          rate: amount,
          quantity: 1,
        ),
      ],
    );

    try {
      final created =
          await ref.read(zohoInvoicesRiverpod).createInvoice(draft);

      // Write the link back to the JobListItem. If this fails the invoice
      // still exists in Zoho, so say so rather than implying nothing happened.
      try {
        await ref.read(collectionScheduleRiverpod).linkZohoInvoice(
              jobId: widget.job.id,
              contactId: _selectedCustomer!.contactId,
              invoiceId: created.invoiceId,
              invoiceNumber: created.invoiceNumber,
              status: created.status.apiValue,
            );
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
                builder: (_) =>
                    ZohoInvoiceDetailScreen(invoiceId: created.invoiceId),
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
    final customersProvider = ref.watch(zohoCustomersRiverpod);
    final alreadyInvoiced = _backingItem?.hasZohoInvoice ?? false;

    return AlertDialog(
      title: const Text('Create invoice'),
      content: SizedBox(
        width: 460,
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
                  widget.job.location,
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
                    validator: (v) =>
                        v == null ? 'Choose a customer' : null,
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
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Line item description *',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'A description is required'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amountController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Amount *',
                    prefixText: 'R ',
                    border: OutlineInputBorder(),
                    // No VAT is charged at present, so this is the invoiced
                    // total with no tax applied.
                    helperText: 'No VAT applied',
                  ),
                  validator: (v) {
                    final parsed = double.tryParse((v ?? '').trim());
                    if (parsed == null || parsed <= 0) {
                      return 'Enter an amount greater than zero';
                    }
                    return null;
                  },
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
