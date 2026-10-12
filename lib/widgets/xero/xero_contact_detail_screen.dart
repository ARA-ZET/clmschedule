import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/xero_contact.dart';
import '../../models/xero_invoice.dart';
import '../../services/xero_accounting_service.dart';
import '../zoho/zoho_table.dart';
import 'xero_contact_form_dialog.dart';
import 'xero_invoice_detail_screen.dart';
import 'xero_status_chip.dart';

/// One Xero contact, with their invoices.
///
/// The list view's rows come from a paged search and carry no `Balances`, so
/// the contact is re-read here — the outstanding figure only appears on a
/// detail fetch.
class XeroContactDetailScreen extends riverpod.ConsumerStatefulWidget {
  final String contactId;

  /// Shown in the app bar while the detail loads, so the screen is not blank.
  final String initialName;

  const XeroContactDetailScreen({
    super.key,
    required this.contactId,
    this.initialName = '',
  });

  @override
  riverpod.ConsumerState<XeroContactDetailScreen> createState() =>
      _XeroContactDetailScreenState();
}

class _XeroContactDetailScreenState
    extends riverpod.ConsumerState<XeroContactDetailScreen> {
  XeroContact? _contact;
  List<XeroInvoice> _invoices = const [];
  bool _isLoading = true;
  String? _error;

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
    final service = ref.read(xeroAccountingServiceRiverpod);
    try {
      // Two calls, issued together rather than in sequence — the daily budget
      // is 1,000, so latency is the thing to save here, not requests.
      final results = await Future.wait([
        service.getContact(widget.contactId),
        service.listInvoices(
          contactIds: [widget.contactId],
          summaryOnly: true,
          order: 'Date DESC',
          pageSize: 100,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _contact = results[0] as XeroContact;
        _invoices = (results[1] as XeroPage<XeroInvoice>).items;
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

  /// Amend the customer in Xero.
  ///
  /// Re-reads afterwards rather than trusting the response: the detail view
  /// shows `Balances.AccountsReceivable.Outstanding`, which Xero only returns
  /// on a detail fetch and never on a write response.
  Future<void> _edit() async {
    final contact = _contact;
    if (contact == null) return;

    final saved = await showXeroContactFormDialog(context, existing: contact);
    if (saved == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Updated ${saved.displayName} in Xero'),
        backgroundColor: Colors.green,
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final contact = _contact;
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    return Scaffold(
      backgroundColor: ZohoPalette.pageBackground,
      appBar: AppBar(
        title: Text(contact?.displayName ?? widget.initialName),
        backgroundColor: ZohoPalette.surface,
        foregroundColor: ZohoPalette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(bottom: BorderSide(color: ZohoPalette.border)),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit customer',
            onPressed: (_isLoading || contact == null) ? null : _edit,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload from Xero',
            onPressed: _isLoading ? null : _load,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _details(contact!, currency),
                    const SizedBox(height: 16),
                    _invoiceList(currency, dateFormat),
                    const SizedBox(height: 30),
                  ],
                ),
    );
  }

  Widget _details(XeroContact contact, NumberFormat currency) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZohoPalette.surface,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(contact.displayName,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              if (!contact.isActive)
                const Text('ARCHIVED',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: ZohoPalette.textMuted)),
            ],
          ),
          const SizedBox(height: 12),
          _kv(
              'Contact',
              [contact.firstName, contact.lastName]
                  .where((p) => p.isNotEmpty)
                  .join(' ')),
          _kv('Email', contact.emailAddress),
          _kv('Phone', contact.phone),
          _kv('Mobile', contact.mobile),
          _kv('Outstanding', currency.format(contact.outstandingReceivable)),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: ZohoPalette.textMuted)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _invoiceList(NumberFormat currency, DateFormat dateFormat) {
    return Container(
      decoration: BoxDecoration(
        color: ZohoPalette.surface,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
            child:
                Text('Invoices', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (_invoices.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('No invoices for this customer',
                  style: TextStyle(fontSize: 12, color: ZohoPalette.textMuted)),
            )
          else
            ..._invoices.map((inv) => ListTile(
                  dense: true,
                  // Same status tint as the invoices table.
                  tileColor: inv.rowColor.withValues(alpha: 0.12),
                  shape: Border(
                    left: BorderSide(
                        color: inv.rowColor, width: ZohoPalette.accentWidth),
                  ),
                  title: Text(inv.invoiceNumber),
                  subtitle: Text(
                      inv.date == null ? '' : dateFormat.format(inv.date!)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      XeroStatusChip(
                          status: inv.status,
                          isOverdue: inv.isOverdue,
                          dense: true),
                      const SizedBox(width: 12),
                      Text(currency.format(inv.total),
                          style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          XeroInvoiceDetailScreen(invoiceId: inv.invoiceId),
                    ),
                  ),
                )),
        ],
      ),
    );
  }
}
