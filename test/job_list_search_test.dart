import 'package:clmschedule/models/job_invoice_link.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/utils/job_list_search.dart';
import 'package:flutter_test/flutter_test.dart';

JobListItem _job({
  String client = 'Pick n Pay Claremont',
  String invoice = 'INV-004512',
  String area = 'Rondebosch East',
  DateTime? date,
  DateTime? collectionDate,
  double amount = 4250,
  String invoiceDetails = '',
  String whoToInvoice = '',
  String specialInstructions = '',
  String zohoInvoiceNumber = '',
  List<JobInvoiceLink> splitInvoices = const [],
}) =>
    JobListItem(
      id: 'j1',
      invoice: invoice,
      amount: amount,
      client: client,
      jobStatusId: 'underway',
      jobTypeId: 'flyers',
      area: area,
      quantity: 5000,
      manDays: 2.5,
      date: date ?? DateTime(2026, 10, 12),
      collectionAddress: '12 Main Road, Wynberg',
      collectionDate: collectionDate ?? DateTime(2026, 10, 9),
      specialInstructions: specialInstructions,
      quantityDistributed: 4800,
      invoiceDetails: invoiceDetails,
      reportAddresses: 'ops@pnp.co.za',
      whoToInvoice: whoToInvoice,
      zohoInvoiceNumber: zohoInvoiceNumber,
      splitInvoices: splitInvoices,
    );

void main() {
  bool m(String q, JobListItem job,
          {Iterable<String?> Function(JobListItem)? labels}) =>
      JobListSearch(q, labels: labels).matches(job);

  test('original fields and any word order', () {
    final job = _job();
    expect(m('claremont pick', job), isTrue);
    expect(m('004512', job), isTrue);
    expect(m('rondebsoch', job), isTrue); // typo
    expect(m('claremont xyz', job), isFalse);
  });

  test('numeric dates match the job date or collection date', () {
    final job = _job();
    expect(m('12/10', job), isTrue);
    expect(m('12-10-2026', job), isTrue);
    expect(m('12/10/26', job), isTrue);
    expect(m('2026-10-12', job), isTrue);
    expect(m('9/10', job), isTrue); // collection date
    expect(m('10/2026', job), isTrue); // month + year
    expect(m('13/10', job), isFalse);
    expect(m('12/11', job), isFalse);
    expect(m('12/10/2025', job), isFalse);
  });

  test('month and weekday names', () {
    final job = _job(); // 12 Oct 2026 is a Monday
    expect(m('october', job), isTrue);
    expect(m('12 oct', job), isTrue);
    expect(m('monday claremont', job), isTrue);
    expect(m('november', job), isFalse);
  });

  test('date text that is really an invoice number still matches', () {
    final job = _job(invoice: 'INV 3/11', date: DateTime(2026, 1, 1));
    expect(m('3/11', job), isTrue);
    // ...but not as loose numbers scattered across fields.
    final loose = _job(invoice: '11', date: DateTime(2026, 1, 1));
    expect(m('12/11', loose), isFalse); // "12" is in the address
  });

  test('date combined with words', () {
    expect(m('12/10 claremont', _job()), isTrue);
    expect(m('12/10 wynberg', _job()), isTrue); // collection address
    expect(m('13/10 claremont', _job()), isFalse);
  });

  test('every column and invoice detail is searchable', () {
    final job = _job(
      invoiceDetails: 'Attention accounts, PO 7781',
      whoToInvoice: 'Head office Cape Town',
      specialInstructions: 'Avoid flats',
      zohoInvoiceNumber: 'ZB-0099',
      splitInvoices: const [
        JobInvoiceLink(
          providerId: 'zoho',
          invoiceId: 'z2',
          invoiceNumber: 'ZB-0100',
          contactName: 'Franchise Owner',
          total: 1500,
        ),
      ],
    );
    expect(m('po 7781', job), isTrue);
    expect(m('head office', job), isTrue);
    expect(m('flats', job), isTrue);
    expect(m('zb-0099', job), isTrue);
    expect(m('zb-0100', job), isTrue);
    expect(m('franchise', job), isTrue);
    expect(m('wynberg', job), isTrue);
    expect(m('ops@pnp', job), isTrue);
    expect(m('5000', job), isTrue); // quantity
    expect(m('4800', job), isTrue); // distributed
    expect(m('2.5', job), isTrue); // man-days
    expect(m('4250', job), isTrue); // amount
    expect(m('r 4250.00', job), isTrue);
    expect(m('1500', job), isTrue); // split invoice total
  });

  test('status and job type labels via resolver', () {
    labels(JobListItem _) => ['Job underway', 'Awaiting payment', 'Flyers'];
    expect(m('awaiting', _job(), labels: labels), isTrue);
    expect(m('flyers underway', _job(), labels: labels), isTrue);
    expect(m('paid in full', _job(), labels: labels), isFalse);
  });

  test('empty query', () {
    expect(JobListSearch('  ').isEmpty, isTrue);
    expect(m('', _job()), isTrue);
  });
}
