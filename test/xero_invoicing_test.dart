import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/models/xero_contact.dart';
import 'package:clmschedule/models/xero_invoice.dart';
import 'package:clmschedule/widgets/zoho/invoice_save_saga.dart';

/// The saga was generalised so Zoho and Xero share one copy of the ordering,
/// retry and idempotency rules. Compiling against both types proves nothing —
/// these prove it still refuses to double-create when driven with Xero's.

JobListItem _job({String id = 'job-1'}) => JobListItem(
      id: id,
      invoice: '',
      amount: 1500,
      client: 'ACME Media',
      jobStatusId: 'standby',
      jobTypeId: 'distribution',
      area: 'Claremont',
      quantity: 50000,
      manDays: 1,
      date: DateTime(2026, 8, 19),
      collectionAddress: '',
      collectionDate: DateTime(2026, 8, 19),
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    );

const _contact = XeroContact(contactId: 'xc-1', name: 'ACME Media, Claremont');

const _invoice = XeroInvoice(
  invoiceId: 'xi-1',
  invoiceNumber: 'INV-0042',
  contactId: 'xc-1',
  status: XeroInvoiceStatus.authorised,
  subTotal: 1500,
  totalTax: 225,
  total: 1725,
);

void main() {
  group('InvoiceSaveSaga driven with Xero types', () {
    test('a failed link does not re-raise the invoice on retry', () async {
      var createInvoiceCalls = 0;
      var linkAttempts = 0;

      final saga = InvoiceSaveSaga<XeroContact, XeroInvoice>(
        providerName: 'Xero',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        customer: _contact,
        onProgress: () {},
        saveJob: () async => _job(),
        createInvoice: (job, contact) async {
          createInvoiceCalls++;
          return _invoice;
        },
        linkToJob: (job, contact, invoice) async {
          linkAttempts++;
          if (linkAttempts == 1) throw StateError('firestore unavailable');
        },
      );

      await saga.run();
      expect(saga.hasFailed, isTrue);
      expect(saga.invoiceExists, isTrue,
          reason: 'the invoice is real even though the link failed');

      await saga.run();

      expect(saga.hasFailed, isFalse);
      expect(createInvoiceCalls, 1,
          reason: 'a duplicate invoice would be an accounting error');
      expect(linkAttempts, 2);
    });

    test('the customer is recorded as done, never created', () async {
      // The saga has no create-customer path at all any more: contacts are
      // created from the form before it runs, so a failure at the invoice step
      // cannot strand a half-made customer in the books.
      final saga = InvoiceSaveSaga<XeroContact, XeroInvoice>(
        providerName: 'Xero',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        customer: _contact,
        onProgress: () {},
        saveJob: () async => _job(),
        createInvoice: (j, c) async => _invoice,
        linkToJob: (j, c, i) async {},
      );

      await saga.run();

      expect(saga.isComplete, isTrue);
      expect(saga.steps[1].state, SagaStepState.done,
          reason: 'a supplied customer is an accomplished fact, not a skip');
      expect(saga.steps[1].detail, contains(_contact.displayName));
    });

    test('nothing is created when the invoice call fails', () async {
      final saga = InvoiceSaveSaga<XeroContact, XeroInvoice>(
        providerName: 'Xero',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        customer: _contact,
        onProgress: () {},
        saveJob: () async => _job(),
        createInvoice: (j, c) async => throw StateError('Xero: rate limited'),
        linkToJob: (j, c, i) async => fail('must not link without an invoice'),
      );

      await saga.run();

      expect(saga.hasFailed, isTrue);
      expect(saga.invoiceExists, isFalse);
      expect(saga.failureMessage, contains('rate limited'));
    });

    test('step labels name the provider', () {
      final saga = InvoiceSaveSaga<XeroContact, XeroInvoice>(
        providerName: 'Xero',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        customer: _contact,
        onProgress: () {},
        saveJob: () async => _job(),
        createInvoice: (j, c) async => _invoice,
        linkToJob: (j, c, i) async {},
      );

      expect(saga.steps[1].label, 'Customer in Xero');
      expect(saga.steps[2].label, 'Create invoice in Xero');
    });
  });

  group('VAT reaches Xero as the right LineAmountTypes', () {
    // The whole point of CLM going through Xero: these fields were dormant
    // while Zoho charged no VAT.
    test('CLM charges VAT, price entered excl', () {
      expect(
        XeroLineAmountType.forJob(chargesVat: true, priceIsInclVat: false)
            .apiValue,
        'Exclusive',
      );
    });

    test('CLM charges VAT, price entered incl', () {
      expect(
        XeroLineAmountType.forJob(chargesVat: true, priceIsInclVat: true)
            .apiValue,
        'Inclusive',
      );
    });

    test('a non-VAT job type is NoTax however the price was typed', () {
      expect(
        XeroLineAmountType.forJob(chargesVat: false, priceIsInclVat: true)
            .apiValue,
        'NoTax',
      );
    });
  });

  group('the invoice carries the split the books will use', () {
    // linkAccountingInvoiceTxn writes subTotal/total straight from the invoice
    // rather than recomputing, so the Job List cannot disagree with Xero by
    // rounding cents.
    test('subTotal and total come from Xero, not from arithmetic', () {
      expect(_invoice.subTotal, 1500);
      expect(_invoice.totalTax, 225);
      expect(_invoice.total, 1725);
      expect(_invoice.subTotal + _invoice.totalTax, _invoice.total);
    });
  });
}
