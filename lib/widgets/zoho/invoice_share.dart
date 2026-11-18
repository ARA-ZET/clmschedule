import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/invoice_message_subject.dart';
import '../../models/invoice_message_template.dart';
import '../../providers/invoice_message_template_provider.dart';
import 'zoho_table.dart';

/// Filename offered when the print dialog saves the invoice as a PDF.
///
/// "Nicola Gnodde - INV-002641" so the file is identifiable without retyping
/// anything. Characters that are illegal in filenames on macOS/Windows are
/// stripped rather than escaped, since this is a suggestion the user can edit.
String invoiceFileName(InvoiceMessageSubject invoice) {
  String clean(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final customer = clean(invoice.clientName);
  final number = clean(invoice.invoiceNumber);

  if (customer.isEmpty && number.isEmpty) return 'Invoice';
  if (customer.isEmpty) return number;
  if (number.isEmpty) return customer;
  return '$customer - $number';
}

/// Covering message for the invoice.
///
/// Deliberately carries **no link** — the PDF is attached by hand, so a
/// payment URL alongside it would be a second, divergent copy of the same
/// invoice.
String _shareMessage(InvoiceMessageSubject invoice) {
  final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
  final number =
      invoice.invoiceNumber.isEmpty ? '' : ' ${invoice.invoiceNumber}';
  return [
    if (invoice.clientName.isNotEmpty) 'Hi ${invoice.clientName},',
    '',
    'Please find attached your invoice$number for '
        '${currency.format(invoice.total)}.',
  ].join('\n');
}

/// Share sheet offering WhatsApp and Gmail.
///
/// Opens either with a covering message pre-filled; the user attaches the
/// printed PDF themselves. Neither `wa.me` nor Gmail's compose URL can carry
/// an attachment, so the file cannot be sent programmatically from a browser.
Future<void> showInvoiceShareSheet(
  BuildContext context,
  InvoiceMessageSubject invoice, {
  String? customerEmail,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _ShareSheet(
      invoice: invoice,
      customerEmail: customerEmail,
    ),
  );
}

class _ShareSheet extends riverpod.ConsumerStatefulWidget {
  final InvoiceMessageSubject invoice;
  final String? customerEmail;

  const _ShareSheet({required this.invoice, this.customerEmail});

  @override
  riverpod.ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends riverpod.ConsumerState<_ShareSheet> {
  /// Selected template's **id**, not the object.
  ///
  /// The provider replaces its whole list on any reload, and
  /// [InvoiceMessageTemplate] has no value equality — holding the instance
  /// would leave the dropdown with a value matching none of its items, which
  /// makes DropdownButtonFormField assert.
  String? _templateId;

  InvoiceMessageSubject get invoice => widget.invoice;
  String? get customerEmail => widget.customerEmail;

  InvoiceMessageTemplate? _resolve(List<InvoiceMessageTemplate> available) {
    if (_templateId == null) return null;
    for (final t in available) {
      if (t.id == _templateId) return t;
    }
    // The template was deleted or re-tagged while the sheet was open.
    return null;
  }

  /// The message actually sent: the chosen template rendered with this
  /// invoice's values, or the built-in covering note when there is none.
  String _bodyFor(InvoiceMessageTemplate? chosen) {
    final provider = ref.read(invoiceMessageTemplateRiverpod);
    if (chosen == null) return _shareMessage(invoice);
    return chosen.render(invoice, bankingDetails: provider.bankingDetails);
  }

  Future<void> _open(BuildContext context, Uri uri, String failureLabel) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showToast(
          SnackBar(
            content: Text('Could not open $failureLabel.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      messenger.showToast(
        SnackBar(
          content: Text('Could not open $failureLabel: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(invoiceMessageTemplateRiverpod);
    final available = provider.templatesFor(invoice);

    // Deliberately no auto-selection: when templates exist the user must pick
    // one before sharing. Defaulting to "the first match" invites sending the
    // wrong wording to a customer, which cannot be taken back.
    final chosen = _resolve(available);
    final mustPick = available.isNotEmpty && chosen == null;
    final message = _bodyFor(chosen);
    final subject = invoice.invoiceNumber.isEmpty
        ? 'Invoice'
        : 'Invoice ${invoice.invoiceNumber}';

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              'Share $subject',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: ZohoPalette.textPrimary,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Opens the message ready to send. Attach the PDF yourself — '
              'use Download PDF first to save it.',
              style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
            ),
          ),
          if (available.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: DropdownButtonFormField<String>(
                initialValue: chosen?.id,
                isExpanded: true,
                hint: const Text('Choose a message…',
                    style: TextStyle(fontSize: 13)),
                decoration: InputDecoration(
                  labelText: 'Message *',
                  labelStyle: const TextStyle(fontSize: 12),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(
                      // Highlighted until chosen, so it reads as required.
                      color: mustPick
                          ? const Color(0xFFE8912D)
                          : ZohoPalette.border,
                    ),
                  ),
                ),
                style: const TextStyle(
                    fontSize: 13, color: ZohoPalette.textPrimary),
                items: available
                    .map((t) => DropdownMenuItem(
                          value: t.id,
                          child: Text('${t.name}  ·  ${t.category.label}',
                              overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (id) => setState(() => _templateId = id),
              ),
            ),
            // Preview, because a wrong template sent to a customer is not
            // something you can take back.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 120),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ZohoPalette.pageBackground,
                  border: Border.all(color: ZohoPalette.border),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    message,
                    style: const TextStyle(
                        fontSize: 11, color: ZohoPalette.textPrimary),
                  ),
                ),
              ),
            ),
          ],
          if (mustPick)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: Colors.orange.shade800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Pick a message before sharing.',
                      style: TextStyle(
                          fontSize: 11, color: Colors.orange.shade900),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),

          // Both actions stay disabled until a message is chosen, so the
          // wrong wording cannot go out by a mis-tap.
          ListTile(
            enabled: !mustPick,
            leading: Icon(Icons.chat,
                color:
                    mustPick ? ZohoPalette.textMuted : const Color(0xFF25D366)),
            title: const Text('WhatsApp'),
            subtitle: const Text('Opens WhatsApp to pick a contact'),
            onTap: mustPick
                ? null
                : () => _open(
                      context,
                      // wa.me with no number opens WhatsApp with the message
                      // ready and lets the user choose the recipient.
                      Uri.parse(
                          'https://wa.me/?text=${Uri.encodeComponent(message)}'),
                      'WhatsApp',
                    ),
          ),
          ListTile(
            enabled: !mustPick,
            leading: Icon(Icons.mail_outline,
                color:
                    mustPick ? ZohoPalette.textMuted : const Color(0xFFEA4335)),
            title: const Text('Gmail'),
            subtitle: Text(
              (customerEmail != null && customerEmail!.isNotEmpty)
                  ? 'Opens a draft to $customerEmail'
                  : 'Opens a Gmail draft in the browser',
            ),
            onTap: mustPick
                ? null
                : () => _open(
                      context,
                      Uri.parse(
                        'https://mail.google.com/mail/?view=cm&fs=1'
                        '${(customerEmail != null && customerEmail!.isNotEmpty) ? '&to=${Uri.encodeComponent(customerEmail!)}' : ''}'
                        '&su=${Uri.encodeComponent(subject)}'
                        '&body=${Uri.encodeComponent(message)}',
                      ),
                      'Gmail',
                    ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
