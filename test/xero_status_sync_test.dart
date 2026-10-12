import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/company.dart';
import 'package:clmschedule/models/job_invoice_link.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/models/xero_invoice.dart';
import 'package:clmschedule/services/xero_invoice_status_sync.dart';

/// Guards the batched status refresh.
///
/// What is really being protected here is the daily API budget. The Xero
/// connection allows 1,000 calls a day; a refresh that slipped back into one
/// request per job would spend a fifth of that drawing one Job List, and would
/// do it silently — the screen would still look right. Every test below is
/// about *not* asking Xero for something.

JobListItem _job({
  String id = 'job-1',
  String providerId = 'xero',
  String invoiceNumber = 'INV-0001',
  String status = 'AUTHORISED',
  DateTime? syncedAt,
  DateTime? date,
}) {
  return JobListItem(
    id: id,
    invoice: invoiceNumber,
    amount: 1500,
    client: 'ACME Media',
    jobStatusId: 'standby',
    jobTypeId: 'distribution',
    area: 'Claremont',
    quantity: 1,
    manDays: 1,
    date: date ?? DateTime(2026, 8, 19),
    collectionAddress: '1 Main Rd',
    collectionDate: DateTime(2026, 8, 19),
    specialInstructions: '',
    quantityDistributed: 0,
    invoiceDetails: '',
    reportAddresses: '',
    whoToInvoice: 'Accounts',
    invoiceProviderId: providerId,
    accountingInvoiceId: 'xi-$id',
    accountingInvoiceNumber: invoiceNumber,
    accountingInvoiceStatus: status,
    accountingSyncedAt: syncedAt,
  );
}

XeroInvoice _invoice(String number, XeroInvoiceStatus status) => XeroInvoice(
      invoiceId: 'xi',
      invoiceNumber: number,
      contactId: 'xc',
      status: status,
    );

void main() {
  final now = DateTime(2026, 8, 25, 12, 0);

  group('jobsDueRefresh', () {
    test('a never-synced Xero job is due', () {
      final due = XeroInvoiceStatusSync.jobsDueRefresh([_job()], now: now);
      expect(due, hasLength(1));
    });

    test('Zoho jobs are never asked about', () {
      // Junk & Stuff's rows share the Job List. Including them would both
      // waste calls and look up numbers that mean nothing in CLM's books.
      final due = XeroInvoiceStatusSync.jobsDueRefresh(
        [_job(providerId: 'zoho')],
        now: now,
      );
      expect(due, isEmpty);
      expect(AccountingProvider.zoho.name, 'zoho');
    });

    test('a job with no invoice number cannot be looked up', () {
      final due = XeroInvoiceStatusSync.jobsDueRefresh(
        [_job(invoiceNumber: '')],
        now: now,
      );
      expect(due, isEmpty);
    });

    test('a status refreshed inside the window is taken at face value', () {
      final fresh = XeroInvoiceStatusSync.jobsDueRefresh(
        [_job(syncedAt: now.subtract(const Duration(minutes: 1)))],
        now: now,
      );
      expect(fresh, isEmpty);

      final stale = XeroInvoiceStatusSync.jobsDueRefresh(
        [_job(syncedAt: now.subtract(const Duration(hours: 2)))],
        now: now,
      );
      expect(stale, hasLength(1));
    });

    test('terminal statuses are never re-read', () {
      // VOIDED and DELETED cannot change again, so asking is pure waste.
      for (final status in ['VOIDED', 'DELETED']) {
        expect(
          XeroInvoiceStatusSync.jobsDueRefresh([_job(status: status)],
              now: now),
          isEmpty,
          reason: '$status is terminal',
        );
      }

      // PAID is *not* terminal — deleting the payment in Xero reverts the
      // invoice to AUTHORISED, and the Job List must be able to follow that.
      expect(
        XeroInvoiceStatusSync.jobsDueRefresh([_job(status: 'PAID')], now: now),
        hasLength(1),
      );
    });
  });

  group('chunkNumbers', () {
    test('duplicates are asked for once', () {
      final chunks = XeroInvoiceStatusSync.chunkNumbers(
        ['INV-1', 'INV-2', 'INV-1', '', 'INV-2'],
      );
      expect(chunks, hasLength(1));
      expect(chunks.single.toSet(), {'INV-1', 'INV-2'});
    });

    test('a large month splits into whole chunks with nothing dropped', () {
      final numbers = List.generate(250, (i) => 'INV-$i');
      final chunks = XeroInvoiceStatusSync.chunkNumbers(numbers, size: 100);

      expect(chunks.map((c) => c.length).toList(), [100, 100, 50]);
      expect(chunks.expand((c) => c).toSet(), numbers.toSet());
    });

    test('nothing to ask about is no request at all', () {
      expect(XeroInvoiceStatusSync.chunkNumbers(const []), isEmpty);
      expect(XeroInvoiceStatusSync.chunkNumbers(const ['', '']), isEmpty);
    });
  });

  group('updatesFor', () {
    test('only genuine changes are written', () {
      final unchanged = _job(id: 'a', invoiceNumber: 'INV-1');
      final changed = _job(id: 'b', invoiceNumber: 'INV-2');

      final updates = XeroInvoiceStatusSync.updatesFor(
        [unchanged, changed],
        {
          'INV-1': _invoice('INV-1', XeroInvoiceStatus.authorised),
          'INV-2': _invoice('INV-2', XeroInvoiceStatus.paid),
        },
      );

      expect(updates, hasLength(1));
      expect(updates.single.jobId, 'b');
      expect(updates.single.status, 'PAID');
      expect(updates.single.date, DateTime(2026, 8, 19),
          reason: 'the write needs the month the job lives in');
    });

    test('an invoice Xero did not report is left alone, not blanked', () {
      // A number missing from the response means the filter matched nothing —
      // far likelier an invoice in another organisation than one that has
      // ceased to exist. Clearing the cached status on that basis would show
      // a live invoice as uninvoiced.
      final updates = XeroInvoiceStatusSync.updatesFor([_job()], const {});
      expect(updates, isEmpty);
    });

    test('two jobs sharing one invoice both follow it', () {
      final updates = XeroInvoiceStatusSync.updatesFor(
        [
          _job(id: 'a', invoiceNumber: 'INV-9'),
          _job(id: 'b', invoiceNumber: 'INV-9'),
        ],
        {'INV-9': _invoice('INV-9', XeroInvoiceStatus.paid)},
      );
      expect(updates.map((u) => u.jobId), ['a', 'b']);
    });
  });

  group('updatesFor with a status map', () {
    const map = {'paid': 'PAID_ID', 'sent': 'OUT_ID', 'void': 'CANCEL_ID'};

    test('moves the Invoice Status column with the books', () {
      final updates = XeroInvoiceStatusSync.updatesFor(
        [_job(id: 'a', invoiceNumber: 'INV-1')],
        {'INV-1': _invoice('INV-1', XeroInvoiceStatus.paid)},
        statusMap: map,
      );
      expect(updates.single.invoiceStatusId, 'PAID_ID');
    });

    test('fixes a contradicting column even when Xero has not changed', () {
      // Cached AUTHORISED, live AUTHORISED — but the column was set by hand
      // to something the books do not say.
      final job = _job(id: 'a', invoiceNumber: 'INV-1')
          .copyWith(invoiceStatusId: 'CANCEL_ID');
      final updates = XeroInvoiceStatusSync.updatesFor(
        [job],
        {'INV-1': _invoice('INV-1', XeroInvoiceStatus.authorised)},
        statusMap: map,
      );
      expect(updates.single.invoiceStatusId, 'OUT_ID');
    });

    test('a job marked Paid by hand keeps Paid', () {
      final job = _job(id: 'a', invoiceNumber: 'INV-1')
          .copyWith(invoiceStatusId: 'PAID_ID');
      final updates = XeroInvoiceStatusSync.updatesFor(
        [job],
        {'INV-1': _invoice('INV-1', XeroInvoiceStatus.authorised)},
        statusMap: map,
      );
      expect(updates, isEmpty);
    });
  });

  group('split invoices', () {
    JobInvoiceLink link(String number,
            {String provider = 'xero',
            String status = 'AUTHORISED',
            DateTime? syncedAt}) =>
        JobInvoiceLink(
          providerId: provider,
          invoiceId: 'xi-$number',
          invoiceNumber: number,
          status: status,
          syncedAt: syncedAt,
        );

    test('stale Xero splits are due; fresh, Zoho and void ones are not', () {
      final job = _job(syncedAt: now).copyWith(splitInvoices: [
        link('INV-2'),
        link('INV-3', syncedAt: now),
        link('INV-4', provider: 'zoho', status: 'sent'),
        link('INV-5', status: 'VOIDED'),
      ]);
      final due = XeroInvoiceStatusSync.splitsDueRefresh([job], now: now);
      expect(due.map((d) => d.link.invoiceNumber), ['INV-2']);
    });

    test('a split job never has its column set from the primary alone', () {
      const map = {'paid': 'PAID_ID', 'sent': 'OUT_ID'};
      final job = _job(id: 'a', invoiceNumber: 'INV-1')
          .copyWith(splitInvoices: [link('INV-2')]);
      final updates = XeroInvoiceStatusSync.updatesFor(
        [job],
        {'INV-1': _invoice('INV-1', XeroInvoiceStatus.paid)},
        statusMap: map,
      );
      expect(updates.single.status, 'PAID');
      expect(updates.single.invoiceStatusId, isNull);
    });
  });
}
