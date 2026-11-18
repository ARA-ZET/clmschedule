import 'package:flutter/material.dart';

import '../../models/zoho_invoice.dart';
import 'zoho_invoice_editor.dart';
import 'zoho_table.dart';

/// Edit an existing Zoho invoice's line items, notes and reference.
///
/// Zoho rejects edits to paid and void invoices, so the caller should only
/// offer this for editable ones. Pops true once saved.
class EditInvoiceDialog extends StatelessWidget {
  final ZohoInvoice invoice;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const EditInvoiceDialog({
    super.key,
    required this.orgId,
    required this.invoice,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: ZohoPalette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      title: Text(
        'Edit ${invoice.invoiceNumber}',
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ZohoPalette.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                invoice.customerName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ZohoPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              // The editor is shared with the distribution report page.
              ZohoInvoiceEditor(
                orgId: orgId,
                invoice: invoice,
                onSaved: (_) => Navigator.of(context).pop(true),
                onCancel: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
