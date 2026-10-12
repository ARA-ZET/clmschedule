import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/job_invoice_link.dart';
import 'package:clmschedule/models/job_list_item.dart';

/// Split invoices: the extra invoices on a job whose bill is shared between
/// clients. These guard the shape the Job List reads them through.
JobListItem _job({List<JobInvoiceLink> splits = const []}) => JobListItem(
      id: 'j1',
      invoice: 'INV-1',
      amount: 1500,
      amountExclVat: 1500,
      amountInclVat: 1725,
      client: 'Acme',
      jobStatusId: 'standby',
      jobTypeId: 'distribution',
      area: '',
      quantity: 0,
      manDays: 0,
      date: DateTime(2026, 10, 5),
      collectionAddress: '',
      collectionDate: DateTime(2026, 10, 5),
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
      invoiceProviderId: 'xero',
      accountingInvoiceId: 'xi-1',
      accountingInvoiceNumber: 'INV-1',
      accountingInvoiceStatus: 'AUTHORISED',
      splitInvoices: splits,
    );

const _split = JobInvoiceLink(
  providerId: 'xero',
  contactId: 'c2',
  contactName: 'Beta Ltd',
  invoiceId: 'xi-2',
  invoiceNumber: 'INV-2',
  status: 'AUTHORISED',
  subTotal: 500,
  total: 575,
);

void main() {
  test('split invoices survive a Firestore round trip', () {
    final map = _job(splits: [_split]).toMap();
    final back = JobListItem.fromMap('j1', map);
    expect(back.splitInvoices.single.invoiceNumber, 'INV-2');
    expect(back.splitInvoices.single.contactName, 'Beta Ltd');
    expect(back.splitInvoices.single.total, 575);
  });

  test('a job without splits writes no splitInvoices key', () {
    expect(_job().toMap().containsKey('splitInvoices'), isFalse);
  });

  test('allInvoices lists the primary first, with its share of the total', () {
    final all = _job(splits: [_split]).allInvoices;
    expect(all.map((i) => i.invoiceNumber), ['INV-1', 'INV-2']);
    expect(all.first.isPrimary, isTrue);
    expect(all.first.subTotal, 1000);
    expect(all.first.total, 1150);
  });

  test('allInvoiceNumbers lists every number', () {
    expect(_job(splits: [_split]).allInvoiceNumbers, ['INV-1', 'INV-2']);
  });

  test('a month move keeps the splits', () {
    final source = _job(splits: [_split]);
    final rebuilt = _job().withPreservedSystemFields(source);
    expect(rebuilt.splitInvoices.single.invoiceId, 'xi-2');
  });
}
