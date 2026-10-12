import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/company.dart';
import '../../models/job_list_item.dart';
import '../../models/xero_invoice.dart';
import '../../models/zoho_invoice.dart';
import '../../providers/zoho_invoices_provider.dart';
import '../../services/job_list_service.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/zoho_org.dart';
import '../xero/xero_status_chip.dart';
import 'zoho_status_chip.dart';
import 'zoho_table.dart';

/// What the delete prompt needs to know about a job's invoice, whichever set
/// of books it lives in.
///
/// Junk & Stuff bills through Zoho and Community Life Media through Xero, but
/// the question the user is being asked is identical, so the dialog is shared
/// and only the loading and the void rules differ. Flattening here beats a
/// second copy of the dialog that would drift from this one.
class _InvoiceSummary {
  final String number;
  final String customerName;
  final double total;
  final Widget statusChip;

  /// Whether this app may void it. False for anything already void, and for a
  /// paid invoice — both providers refuse, and annulling a settled invoice
  /// would orphan its payment.
  final bool canVoid;

  /// Why not, when [canVoid] is false. Null when it can be voided.
  final String? blockedReason;

  /// Provider-specific wording for the checkbox, e.g. "in Xero".
  final String providerLabel;

  const _InvoiceSummary({
    required this.number,
    required this.customerName,
    required this.total,
    required this.statusChip,
    required this.canVoid,
    required this.blockedReason,
    required this.providerLabel,
  });
}

/// Read the live invoice for [job], whichever provider raised it.
///
/// Returns null when there is nothing to show — no invoice, or the books could
/// not be reached. An unreachable provider must never block deleting a job, so
/// the failure degrades to "no invoice detail, and no offer to void" rather
/// than to an error.
Future<_InvoiceSummary?> _loadInvoiceSummary(
  riverpod.WidgetRef ref,
  JobListItem job,
) async {
  if (job.resolvedInvoiceProviderId == AccountingProvider.xero.name) {
    if (job.resolvedInvoiceId.isEmpty) return null;
    try {
      final invoice = await ref
          .read(xeroAccountingServiceRiverpod)
          .getInvoice(job.resolvedInvoiceId);
      return _InvoiceSummary(
        number: invoice.invoiceNumber,
        customerName: invoice.contactName,
        total: invoice.total,
        statusChip: XeroStatusChip(
          status: invoice.status,
          isOverdue: invoice.isOverdue,
          dense: true,
        ),
        // Xero permits a void only from AUTHORISED with nothing allocated
        // against it. Offering it in any other state is an offer to fail.
        canVoid: invoice.status.canBeVoided && invoice.amountPaid == 0,
        blockedReason: invoice.status == XeroInvoiceStatus.voided ||
                invoice.status == XeroInvoiceStatus.deleted
            ? 'This invoice is already void.'
            : invoice.amountPaid > 0
                ? 'This invoice has a payment against it and cannot be voided. '
                    'Raise a credit note in Xero if the money must go back.'
                : 'Xero will not void an invoice in this state.',
        providerLabel: 'Xero',
      );
    } catch (_) {
      return null;
    }
  }

  if (!job.hasZohoInvoice) return null;
  try {
    final invoice = await ref
        .read(zohoInvoicesRiverpod(ZohoOrg.forJob(job)))
        .getInvoiceForCopy(job.zohoInvoiceId);
    return _InvoiceSummary(
      number: invoice.invoiceNumber,
      customerName: invoice.customerName,
      total: invoice.total,
      statusChip: ZohoStatusChip(status: invoice.status, dense: true),
      canVoid: invoice.status != ZohoInvoiceStatus.paid &&
          invoice.status != ZohoInvoiceStatus.isVoid,
      blockedReason: invoice.status == ZohoInvoiceStatus.isVoid
          ? 'This invoice is already void.'
          : 'This invoice is paid and cannot be voided. Credit it in Zoho if '
              'the money must go back.',
      providerLabel: 'Zoho',
    );
  } catch (_) {
    return null;
  }
}

/// Outcome of the combined delete confirmation.
typedef DeleteJobDecision = ({bool confirmed, bool voidInvoice});

/// One dialog that confirms deleting a job **and** offers to void its invoice,
/// rather than stacking two prompts.
///
/// Fetches the live invoice first so the warning can show its number, customer
/// and total — the job's cached copy may be stale if it was paid or voided in
/// the provider's books since.
///
/// Works for both providers: whichever raised the invoice, deleting the job
/// without offering to void leaves a live invoice with nothing attached to it.
Future<DeleteJobDecision> confirmDeleteJobAndInvoice({
  required BuildContext context,
  required riverpod.WidgetRef ref,
  required JobListItem job,
}) async {
  final live = await _loadInvoiceSummary(ref, job);

  if (!context.mounted) return (confirmed: false, voidInvoice: false);

  final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
  final canVoid = live != null && live.canVoid;

  // The job is linked to an invoice that could not be read back. Say so
  // loudly rather than degrading to a bare "delete this job?" — that silence
  // is indistinguishable from "this job has no invoice", and it is exactly
  // the case that strands a live invoice with no job attached.
  final unreadableInvoice = live == null && job.hasAccountingInvoice;

  var alsoVoid = canVoid;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        backgroundColor: ZohoPalette.surface,
        title: const Text('Delete Job'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to delete the job for ${job.client}?',
              style: const TextStyle(fontSize: 13),
            ),
            if (unreadableInvoice) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  border: Border.all(color: Colors.orange.shade200),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 18, color: Colors.orange.shade900),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This job has invoice '
                        '${job.resolvedInvoiceNumber.isEmpty ? '(no number)' : job.resolvedInvoiceNumber}, '
                        'but its current state could not be read from the '
                        'accounting system just now — so it cannot be voided '
                        'from here. Deleting the job will leave that invoice '
                        'live with nothing attached to it. Void it by hand, or '
                        'try again once the connection is back.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange.shade900),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (live != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ZohoPalette.pageBackground,
                  border: Border.all(color: ZohoPalette.border),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            live.number.isEmpty ? '(no number)' : live.number,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                          if (live.customerName.isNotEmpty)
                            Text(live.customerName,
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: ZohoPalette.textMuted)),
                        ],
                      ),
                    ),
                    live.statusChip,
                    const SizedBox(width: 10),
                    Text(currency.format(live.total),
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              if (canVoid)
                CheckboxListTile(
                  value: alsoVoid,
                  onChanged: (v) => setState(() => alsoVoid = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('Also void this invoice in ${live.providerLabel}',
                      style: const TextStyle(fontSize: 13)),
                  subtitle: const Text(
                    'Cannot be undone from this app. Leaving it unticked keeps '
                    'the invoice live with no job attached.',
                    style:
                        TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
                  ),
                )
              else if (live.blockedReason != null)
                Text(
                  live.blockedReason!,
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
                ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              alsoVoid ? 'Delete & Void' : 'Delete',
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    ),
  );

  return (
    confirmed: confirmed == true,
    voidInvoice: confirmed == true && alsoVoid && canVoid,
  );
}

/// Void a job's invoice directly, with no further prompting.
///
/// Used after [confirmDeleteJobAndInvoice] has already taken the decision, and
/// routed by the job's own provider — voiding through the wrong service would
/// at best fail and at worst hit an unrelated invoice with the same id shape.
///
/// Never throws — the job operation must not appear to fail because the
/// accounting system did.
Future<void> voidInvoiceForJob({
  required BuildContext context,
  required riverpod.WidgetRef ref,
  required JobListItem job,
}) async {
  final isXero = job.resolvedInvoiceProviderId == AccountingProvider.xero.name;
  if (!isXero && !job.hasZohoInvoice) return;
  if (isXero && job.resolvedInvoiceId.isEmpty) return;

  final number = isXero ? job.resolvedInvoiceNumber : job.zohoInvoiceNumber;
  final messenger = ScaffoldMessenger.of(context);

  try {
    if (isXero) {
      final voided = await ref
          .read(xeroAccountingServiceRiverpod)
          .voidInvoice(job.resolvedInvoiceId);
      // Zoho's provider writes the status back itself; Xero's service does
      // not, and the Job List keys its unlink action off this cached status.
      try {
        await ref.read(jobListServiceRiverpod).updateAccountingInvoiceStatuses([
          (
            jobId: job.id,
            date: job.date,
            status: voided.status.apiValue,
            invoiceStatusId: null,
          )
        ]);
      } catch (_) {/* the job may be mid-delete */}
    } else {
      await ref
          .read(zohoInvoicesRiverpod(ZohoOrg.forJob(job)))
          .voidInvoice(job.zohoInvoiceId);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text('Invoice $number voided'),
        backgroundColor: Colors.green,
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Could not void $number: $e'),
        backgroundColor: Colors.red,
      ),
    );
  }
}

/// Offer to void a job's Zoho invoice when the job is cancelled or deleted.
///
/// Voiding cannot be undone from this app, so it is always confirmed and the
/// invoice's number, total and current status are shown first.
///
/// Returns quietly when there is nothing to do — no invoice, or the invoice is
/// already void. Never throws: the job change has usually already been saved
/// by the time this runs, so a Zoho failure must not present as the job
/// operation failing.
Future<void> maybeVoidInvoiceForJob({
  required BuildContext context,
  required riverpod.WidgetRef ref,
  required JobListItem job,
  required String reason,
}) async {
  if (!job.hasAccountingInvoice) return;

  // Read the live invoice: the job's cached status may be stale if it was paid
  // or voided in the books since.
  final invoice = await _loadInvoiceSummary(ref, job);

  // Nothing to offer — no invoice, or the books could not be reached. A job
  // status change must not fail because the accounting system was down.
  if (invoice == null) return;
  if (!context.mounted) return;

  final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
  // Neither provider will void an already-void invoice, and annulling a
  // settled one would orphan its recorded payment.
  final isPaid = !invoice.canVoid;

  final shouldVoid = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: ZohoPalette.surface,
      title:
          Text(isPaid ? 'Invoice cannot be voided' : 'Void this invoice too?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This job $reason.', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: ZohoPalette.pageBackground,
              border: Border.all(color: ZohoPalette.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        invoice.number.isEmpty ? '(no number)' : invoice.number,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      if (invoice.customerName.isNotEmpty)
                        Text(invoice.customerName,
                            style: const TextStyle(
                                fontSize: 11, color: ZohoPalette.textMuted)),
                    ],
                  ),
                ),
                Text(currency.format(invoice.total),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isPaid
                ? (invoice.blockedReason ??
                    'This invoice cannot be voided in its current state.')
                : 'Voiding cannot be undone from this app. The invoice stays '
                    'in ${invoice.providerLabel} marked void, keeping the '
                    'number sequence intact.',
            style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(isPaid ? 'OK' : 'Keep invoice'),
        ),
        if (!isPaid)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Void invoice'),
          ),
      ],
    ),
  );

  if (shouldVoid != true) return;
  if (!context.mounted) return;

  // Routed by provider, and reporting its own outcome — never throwing, since
  // the job change has already been saved by the time this runs.
  await voidInvoiceForJob(context: context, ref: ref, job: job);
}
