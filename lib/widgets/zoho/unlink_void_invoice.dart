import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/company.dart';
import '../../models/job_invoice_link.dart';
import '../../models/job_list_item.dart';
import '../../models/xero_invoice.dart';
import '../../models/zoho_invoice.dart';
import '../../providers/zoho_invoices_provider.dart';
import '../../providers/zoho_sync_settings_provider.dart';
import '../../utils/job_lifecycle_rules.dart';
import '../../services/job_list_service.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/zoho_org.dart';

/// Whether the job's *cached* invoice status says void. A hint for showing
/// the unlink action only — [unlinkVoidedInvoice] re-reads the live status
/// before acting, because the cache can be stale in either direction.
bool jobInvoiceLooksVoid(JobListItem job) {
  if (!job.hasAccountingInvoice) return false;
  final status = job.resolvedInvoiceStatus;
  if (job.resolvedInvoiceProviderId == AccountingProvider.xero.name) {
    final s = XeroInvoiceStatus.parse(status);
    return s == XeroInvoiceStatus.voided || s == XeroInvoiceStatus.deleted;
  }
  return ZohoInvoiceStatus.parse(status.isEmpty ? null : status) ==
      ZohoInvoiceStatus.isVoid;
}

/// Unlink a job's void invoice so the job can be invoiced afresh.
///
/// Only a void invoice (or, in Xero, a deleted draft) may be unlinked: a live
/// one would leave real billing with no job behind it, and raising a second
/// invoice next to it would bill the client twice. The status is read live
/// from the provider rather than trusted from the job's cache.
///
/// Returns true when the link was removed. Never throws — failures are shown.
Future<bool> unlinkVoidedInvoice({
  required BuildContext context,
  required riverpod.WidgetRef ref,
  required JobListItem job,
}) async {
  if (!job.hasAccountingInvoice) return false;

  final settings = ref.read(zohoSyncSettingsRiverpod);
  return _confirmVoidAndUnlink(
    context: context,
    ref: ref,
    zohoOrgId: ZohoOrg.forJob(job),
    providerId: job.resolvedInvoiceProviderId,
    invoiceId: job.resolvedInvoiceId,
    number: job.resolvedInvoiceNumber,
    amountNote: 'The job keeps its amount and details.',
    unlink: () => ref.read(jobListServiceRiverpod).unlinkVoidedInvoiceTxn(
          jobId: job.id,
          date: job.date,
          invoiceId: job.resolvedInvoiceId,
          noInvoiceStatusId: settings.noInvoiceStatusId.isNotEmpty
              ? settings.noInvoiceStatusId
              : kNoInvoiceStatusFallbackId,
          paidStatusId: settings.invoiceStatusMap[kBookPaid] ?? '',
        ),
  );
}

/// Whether a split invoice's *cached* status says void — the split
/// counterpart to [jobInvoiceLooksVoid].
bool invoiceLinkLooksVoid(JobInvoiceLink link) {
  if (link.providerId == AccountingProvider.xero.name) {
    final s = XeroInvoiceStatus.parse(link.status);
    return s == XeroInvoiceStatus.voided || s == XeroInvoiceStatus.deleted;
  }
  return ZohoInvoiceStatus.parse(link.status.isEmpty ? null : link.status) ==
      ZohoInvoiceStatus.isVoid;
}

/// Unlink one of a job's void **split** invoices. Same live-status rule as
/// [unlinkVoidedInvoice]; the split's share comes off the job's amount, so its
/// replacement can be raised from the Edit dialog without double-counting.
Future<bool> unlinkVoidedSplitInvoice({
  required BuildContext context,
  required riverpod.WidgetRef ref,
  required JobListItem job,
  required JobInvoiceLink link,
}) {
  return _confirmVoidAndUnlink(
    context: context,
    ref: ref,
    zohoOrgId: ZohoOrg.forJob(job),
    providerId: link.providerId,
    invoiceId: link.invoiceId,
    number: link.invoiceNumber,
    amountNote: 'Its amount is taken off the job total.',
    unlink: () => ref.read(jobListServiceRiverpod).unlinkSplitInvoiceTxn(
          jobId: job.id,
          date: job.date,
          invoiceId: link.invoiceId,
        ),
  );
}

Future<bool> _confirmVoidAndUnlink({
  required BuildContext context,
  required riverpod.WidgetRef ref,
  required String zohoOrgId,
  required String providerId,
  required String invoiceId,
  required String number,
  required String amountNote,
  required Future<void> Function() unlink,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void complain(String message) => messenger.showToast(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );

  final isXero = providerId == AccountingProvider.xero.name;
  final providerLabel = isXero ? 'Xero' : 'Zoho Books';

  final bool isVoid;
  try {
    if (isXero) {
      final s = await ref
          .read(xeroAccountingServiceRiverpod)
          .getInvoiceStatus(invoiceId);
      isVoid = s == XeroInvoiceStatus.voided || s == XeroInvoiceStatus.deleted;
    } else {
      final invoice = await ref
          .read(zohoInvoicesRiverpod(zohoOrgId))
          .getInvoiceForCopy(invoiceId);
      isVoid = invoice.status == ZohoInvoiceStatus.isVoid;
    }
  } catch (e) {
    complain('Could not check invoice $number in $providerLabel: $e');
    return false;
  }

  if (!isVoid) {
    complain('Invoice $number is not void in $providerLabel. Void it first — '
        'only a void invoice can be unlinked.');
    return false;
  }
  if (!context.mounted) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Unlink void invoice?'),
      content: Text(
        'Invoice $number is void in $providerLabel. Unlinking removes it from '
        'this job so a new invoice can be created and linked.\n\n'
        'The void invoice stays in $providerLabel. $amountNote',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Unlink'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  try {
    await unlink();
    messenger.showToast(
      SnackBar(
        content: Text('Invoice $number unlinked — the job can be invoiced '
            'again.'),
        backgroundColor: Colors.green,
      ),
    );
    return true;
  } catch (e) {
    complain('Could not unlink invoice $number: $e');
    return false;
  }
}
