import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/company.dart';
import '../models/invoice_message_subject.dart';
import '../models/job_invoice_link.dart';
import '../models/job_list_item.dart';
import '../models/xero_invoice.dart';
import '../models/zoho_invoice.dart';
import '../providers/zoho_invoices_provider.dart';
import '../services/xero_accounting_service.dart';
import '../utils/zoho_org.dart';
import '../utils/accounting_error.dart';
import '../utils/save_with_picker.dart';
import 'zoho/invoice_share.dart';
import 'xero/xero_invoice_detail_screen.dart';
import 'xero/xero_status_chip.dart';
import 'zoho/unlink_void_invoice.dart';
import 'zoho/zoho_invoice_detail_screen.dart';
import 'zoho/zoho_status_chip.dart';

/// Open one of a job's invoices in its provider's detail screen.
///
/// Routed by the invoice's own provider, never the job type's — a type moved
/// between companies after invoicing would otherwise open the wrong screen.
///
/// [orgId] is the Zoho organisation for a Zoho invoice — the job's, from
/// `ZohoOrg.forJob`. Ignored for Xero.
void openJobInvoice(
  BuildContext context,
  JobInvoiceLink invoice, {
  required String orgId,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => invoice.providerId == AccountingProvider.xero.name
          ? XeroInvoiceDetailScreen(invoiceId: invoice.invoiceId)
          : ZohoInvoiceDetailScreen(orgId: orgId, invoiceId: invoice.invoiceId),
    ),
  );
}

/// The status chip for one invoice, in its provider's colours.
Widget jobInvoiceStatusChip(JobInvoiceLink invoice) {
  if (invoice.providerId == AccountingProvider.xero.name) {
    return XeroStatusChip(
        status: XeroInvoiceStatus.parse(invoice.status), dense: true);
  }
  return ZohoStatusChip(
    status:
        ZohoInvoiceStatus.parse(invoice.status.isEmpty ? null : invoice.status),
    dense: true,
  );
}

/// Download and Share buttons for one of a job's invoices.
///
/// Works from the [JobInvoiceLink] alone, routed by the invoice's own
/// provider, so every invoice on a split job — primary or split — can be sent
/// on its own without opening its detail screen.
class JobInvoiceLinkActions extends riverpod.ConsumerStatefulWidget {
  final JobInvoiceLink invoice;

  /// Zoho organisation id for a Zoho invoice — see `ZohoOrg`.
  final String orgId;

  const JobInvoiceLinkActions({
    super.key,
    required this.invoice,
    required this.orgId,
  });

  @override
  riverpod.ConsumerState<JobInvoiceLinkActions> createState() =>
      _JobInvoiceLinkActionsState();
}

class _JobInvoiceLinkActionsState
    extends riverpod.ConsumerState<JobInvoiceLinkActions> {
  bool _busy = false;

  bool get _isXero => widget.invoice.providerId == AccountingProvider.xero.name;

  /// "Client - INV-0001", like every other invoice download, taken from the
  /// link alone. It is never fetched: the Save dialog that shows it must
  /// open straight after the click. A link without a client name gives just
  /// the invoice number, which the user can edit in the dialog.
  String get _fileName {
    final link = widget.invoice;
    return invoiceFileName(InvoiceMessageSubject(
      clientName: link.contactName,
      invoiceNumber: link.invoiceNumber,
      total: link.total,
      amountDue: link.total,
    ));
  }

  /// [what] completes "Couldn't …" when the action fails.
  Future<void> _run(Future<void> Function() action, String what) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(
          SnackBar(
            content: Text(describeAccountingError(e, action: what).message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The Save dialog opens straight after the click (Chrome refuses it a few
  /// seconds later) and the PDF loads while the user picks a folder.
  Future<void> _download() => _run(() async {
        final id = widget.invoice.invoiceId;
        final xero = ref.read(xeroAccountingServiceRiverpod);
        final zoho = ref.read(zohoInvoicesRiverpod(widget.orgId));
        await savePdfWithFeedback(
          ScaffoldMessenger.of(context),
          fileName: _fileName,
          load: () => _isXero ? xero.getInvoicePdf(id) : zoho.getInvoicePdf(id),
        );
      }, 'download the PDF');

  /// The share sheet renders `{pay_link}` when it builds, so the invoice and
  /// its pay link are fetched before it opens.
  Future<void> _share() => _run(() async {
        final id = widget.invoice.invoiceId;
        InvoiceMessageSubject subject;
        String? email;
        if (_isXero) {
          final service = ref.read(xeroAccountingServiceRiverpod);
          final invoice = await service.getInvoice(id);
          var payLink = '';
          if (invoice.status.hasOnlineInvoice) {
            try {
              payLink = await service.getOnlineInvoiceUrl(id);
            } catch (_) {
              // A missing link only costs the message its {pay_link}.
            }
          }
          if (invoice.contactId.isNotEmpty) {
            try {
              email =
                  (await service.getContact(invoice.contactId)).emailAddress;
            } catch (_) {
              // Leave the Gmail recipient blank.
            }
          }
          subject = InvoiceMessageSubject.fromXero(invoice, payLink: payLink);
        } else {
          final invoice = await ref
              .read(zohoInvoicesRiverpod(widget.orgId))
              .getInvoiceForCopy(id);
          subject = InvoiceMessageSubject.fromZoho(invoice);
        }
        if (!mounted) return;
        await showInvoiceShareSheet(context, subject, customerEmail: email);
      }, 'get the invoice ready to share');

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.download, size: 18),
          tooltip: 'Download ${widget.invoice.invoiceNumber}',
          visualDensity: VisualDensity.compact,
          onPressed: _download,
        ),
        IconButton(
          icon: const Icon(Icons.share, size: 18, color: Color(0xFF25D366)),
          tooltip: 'Share ${widget.invoice.invoiceNumber}',
          visualDensity: VisualDensity.compact,
          onPressed: _share,
        ),
      ],
    );
  }
}

/// Every invoice on a job, each one tappable to open it.
///
/// Shown from the invoice icon on a Job List row whose bill is split between
/// clients. A void split can be unlinked from here so a replacement can be
/// raised; the primary's void flow stays where it was, on the row's icon.
Future<void> showJobInvoicesSheet(
  BuildContext context,
  JobListItem job, {
  VoidCallback? onAddInvoice,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _JobInvoicesSheet(job: job, onAddInvoice: onAddInvoice),
  );
}

class _JobInvoicesSheet extends riverpod.ConsumerWidget {
  final JobListItem job;
  final VoidCallback? onAddInvoice;

  const _JobInvoicesSheet({required this.job, this.onAddInvoice});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final invoices = job.allInvoices;
    final total = invoices.fold<double>(0, (r, i) => r + i.total);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${invoices.length} invoices · ${job.client}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Total R ${total.toStringAsFixed(2)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final invoice in invoices)
                    ListTile(
                      leading: const Icon(Icons.receipt_long),
                      title: Text(
                        'Invoice ${invoice.invoiceNumber}'
                        '${invoice.isPrimary ? '' : ' · split'}',
                      ),
                      subtitle: Text([
                        if (invoice.contactName.isNotEmpty) invoice.contactName,
                        'R ${invoice.total.toStringAsFixed(2)}',
                        invoice.providerId == AccountingProvider.xero.name
                            ? 'Xero'
                            : 'Zoho',
                      ].join(' · ')),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!invoice.isPrimary &&
                              invoiceLinkLooksVoid(invoice))
                            IconButton(
                              icon: const Icon(Icons.link_off, size: 18),
                              tooltip: 'Unlink void invoice',
                              onPressed: () async {
                                final unlinked = await unlinkVoidedSplitInvoice(
                                  context: context,
                                  ref: ref,
                                  job: job,
                                  link: invoice,
                                );
                                if (unlinked && context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              },
                            ),
                          JobInvoiceLinkActions(
                              invoice: invoice, orgId: ZohoOrg.forJob(job)),
                          jobInvoiceStatusChip(invoice),
                        ],
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        openJobInvoice(context, invoice,
                            orgId: ZohoOrg.forJob(job));
                      },
                    ),
                  if (onAddInvoice != null)
                    ListTile(
                      leading: const Icon(Icons.add_circle_outline),
                      title: const Text('Add another invoice'),
                      subtitle: const Text(
                          'Opens the job to split the bill with another client'),
                      onTap: () {
                        Navigator.of(context).pop();
                        onAddInvoice!();
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// The Job List's Invoice cell for a job with more than one invoice: every
/// number, each one a link to its invoice.
///
/// Read-only on purpose — the numbers come from the books, and the free-text
/// edit the single-invoice cell offers would only be overwritten by the next
/// link.
class JobInvoiceNumbersCell extends StatelessWidget {
  final JobListItem job;
  final double width;

  const JobInvoiceNumbersCell({
    super.key,
    required this.job,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    final invoices = job.allInvoices;
    final linkColour = Theme.of(context).colorScheme.primary;

    return Tooltip(
      message: invoices
          .map((i) => '${i.invoiceNumber}'
              '${i.contactName.isEmpty ? '' : ' — ${i.contactName}'}')
          .join('\n'),
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var n = 0; n < invoices.length; n++) ...[
                if (n > 0)
                  Text(', ', style: TextStyle(color: Colors.grey.shade600)),
                InkWell(
                  onTap: () => openJobInvoice(context, invoices[n],
                      orgId: ZohoOrg.forJob(job)),
                  child: Text(
                    invoices[n].invoiceNumber,
                    style: TextStyle(
                      color: linkColour,
                      decoration: TextDecoration.underline,
                      decorationColor: linkColour,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
