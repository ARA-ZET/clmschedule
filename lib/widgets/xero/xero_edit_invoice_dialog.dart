import 'package:flutter/material.dart';

import '../../models/xero_invoice.dart';
import '../zoho/zoho_table.dart';
import 'xero_invoice_editor.dart';
import 'xero_ui.dart';

/// Amend an existing Xero invoice in place.
///
/// The original plan specced void-and-reissue here, on the strength of docs
/// saying Xero only allows updates to draft invoices. Measurement against the
/// live API disproved that: an AUTHORISED invoice's line items were amended and
/// the change persisted. So editing an unpaid invoice is an ordinary update —
/// no voided numbers left behind in the books.
///
/// The caller must only offer this for [XeroInvoice] with nothing paid; Xero
/// rejects an amendment once a payment or credit note is allocated.
class XeroEditInvoiceDialog extends StatelessWidget {
  final XeroInvoice invoice;

  const XeroEditInvoiceDialog({super.key, required this.invoice});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: xeroDialogInset(context),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Edit ${invoice.invoiceNumber}'),
          const SizedBox(height: 2),
          Text(
            invoice.contactName,
            style: const TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          // The editor is shared with the distribution report page.
          child: XeroInvoiceEditor(
            invoice: invoice,
            onSaved: (updated) => Navigator.of(context).pop(updated),
            onCancel: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}
