import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/collection_job.dart';
import '../../models/zoho_invoice.dart';
import '../../providers/collection_schedule_provider.dart';
import '../../utils/zoho_org.dart';
import '../job_invoices_sheet.dart';
import 'create_invoice_dialog.dart';
import 'zoho_invoice_detail_screen.dart';
import 'zoho_status_chip.dart';

/// Invoice actions for a scheduled collection job, shown when its cell is
/// tapped on the Collection Schedule.
Future<void> showJobInvoiceActions(
  BuildContext context,
  CollectionJob job,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _JobInvoiceActionsSheet(job: job),
  );
}

class _JobInvoiceActionsSheet extends riverpod.ConsumerWidget {
  final CollectionJob job;

  const _JobInvoiceActionsSheet({required this.job});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    // Commercial fields live on the backing JobListItem — the CollectionJob
    // the grid renders is only a projection of it.
    final item = ref.watch(collectionScheduleRiverpod).jobListItemFor(job.id);
    final cachedStatus = item?.zohoInvoiceStatus ?? '';
    final status =
        ZohoInvoiceStatus.parse(cachedStatus.isEmpty ? null : cachedStatus);

    return SafeArea(
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
                  job.location.isNotEmpty ? job.location : 'Collection job',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${job.jobType} · ${job.timeRangeDisplay} · '
                  '${job.vehicleDisplayName}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                if (item != null && item.client.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.client,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          if (item == null)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'This job has no backing job list record, so it cannot be '
                'invoiced.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else if (item.hasZohoInvoice) ...[
            ListTile(
              leading: const Icon(Icons.receipt_long),
              title: Text('Invoice ${item.zohoInvoiceNumber}'),
              subtitle: item.zohoSyncedAt == null
                  ? null
                  : Text('Last synced ${_ago(item.zohoSyncedAt!)}'),
              trailing: ZohoStatusChip(status: status, dense: true),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ZohoInvoiceDetailScreen(
                        orgId: ZohoOrg.forJob(item),
                        invoiceId: item.zohoInvoiceId),
                  ),
                );
              },
            ),
            // Split invoices — other clients' shares of the same job.
            for (final split in item.splitInvoices)
              ListTile(
                leading: const Icon(Icons.call_split),
                title: Text('Invoice ${split.invoiceNumber}'),
                subtitle:
                    split.contactName.isEmpty ? null : Text(split.contactName),
                trailing: jobInvoiceStatusChip(split),
                onTap: () {
                  Navigator.of(context).pop();
                  openJobInvoice(context, split, orgId: ZohoOrg.forJob(item));
                },
              ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('Create another invoice'),
              subtitle: const Text('Replaces the invoice linked to this job'),
              onTap: () {
                Navigator.of(context).pop();
                showDialog(
                  context: context,
                  builder: (_) => CreateInvoiceDialog(job: job),
                );
              },
            ),
          ] else
            ListTile(
              leading: const Icon(Icons.note_add),
              title: const Text('Create invoice'),
              subtitle: const Text('Raise a new invoice in Zoho Books'),
              onTap: () {
                Navigator.of(context).pop();
                showDialog(
                  context: context,
                  builder: (_) => CreateInvoiceDialog(job: job),
                );
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  static String _ago(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
