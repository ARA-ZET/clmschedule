import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/company.dart';
import 'package:clmschedule/models/job_list_item.dart';

/// Guards the provider-neutral seam on [JobListItem].
///
/// The risk this covers is silent: a job invoiced through Zoho before the
/// neutral fields existed must keep rendering, and a job invoiced through
/// either provider must survive a month move — `moveJobListItemToMonth`
/// recreates the document from `toMap()` and deletes the original, so a field
/// missed in `withPreservedSystemFields` is destroyed, not merely stale.

JobListItem _job({
  String invoiceProviderId = '',
  String accountingContactId = '',
  String accountingInvoiceId = '',
  String accountingInvoiceNumber = '',
  String accountingInvoiceStatus = '',
  DateTime? accountingSyncedAt,
  String zohoContactId = '',
  String zohoInvoiceId = '',
  String zohoInvoiceNumber = '',
  String zohoInvoiceStatus = '',
  DateTime? zohoSyncedAt,
}) {
  return JobListItem(
    id: 'job-1',
    invoice: 'INV-001',
    amount: 1500,
    client: 'ACME Media',
    jobStatusId: 'standby',
    jobTypeId: 'distribution',
    area: 'Claremont',
    quantity: 1,
    manDays: 1,
    date: DateTime(2026, 8, 19),
    collectionAddress: '1 Main Rd',
    collectionDate: DateTime(2026, 8, 19),
    specialInstructions: '',
    quantityDistributed: 0,
    invoiceDetails: '',
    reportAddresses: '',
    whoToInvoice: 'Accounts',
    invoiceProviderId: invoiceProviderId,
    accountingContactId: accountingContactId,
    accountingInvoiceId: accountingInvoiceId,
    accountingInvoiceNumber: accountingInvoiceNumber,
    accountingInvoiceStatus: accountingInvoiceStatus,
    accountingSyncedAt: accountingSyncedAt,
    zohoContactId: zohoContactId,
    zohoInvoiceId: zohoInvoiceId,
    zohoInvoiceNumber: zohoInvoiceNumber,
    zohoInvoiceStatus: zohoInvoiceStatus,
    zohoSyncedAt: zohoSyncedAt,
  );
}

void main() {
  group('legacy Zoho records still resolve', () {
    final legacy = _job(
      zohoContactId: 'zc-1',
      zohoInvoiceId: 'zi-1',
      zohoInvoiceNumber: 'INV-001',
      zohoInvoiceStatus: 'sent',
      zohoSyncedAt: DateTime(2026, 8, 12, 10),
    );

    test('reads through to the Zoho fields', () {
      expect(legacy.resolvedContactId, 'zc-1');
      expect(legacy.resolvedInvoiceId, 'zi-1');
      expect(legacy.resolvedInvoiceNumber, 'INV-001');
      expect(legacy.resolvedInvoiceStatus, 'sent');
      expect(legacy.resolvedSyncedAt, DateTime(2026, 8, 12, 10));
      expect(legacy.hasAccountingInvoice, isTrue);
    });

    test('infers the provider from the Zoho link', () {
      expect(legacy.resolvedInvoiceProviderId, 'zoho');
    });
  });

  group('new records use the neutral fields', () {
    final xeroJob = _job(
      invoiceProviderId: 'xero',
      accountingContactId: 'xc-1',
      accountingInvoiceId: 'xi-1',
      accountingInvoiceNumber: 'INV-0042',
      accountingInvoiceStatus: 'AUTHORISED',
      accountingSyncedAt: DateTime(2026, 8, 19, 9),
    );

    test('resolves to the neutral values', () {
      expect(xeroJob.resolvedInvoiceProviderId, 'xero');
      expect(xeroJob.resolvedInvoiceId, 'xi-1');
      expect(xeroJob.resolvedInvoiceNumber, 'INV-0042');
      expect(xeroJob.resolvedInvoiceStatus, 'AUTHORISED');
      expect(xeroJob.hasAccountingInvoice, isTrue);
    });

    // A Xero job must not read as a Zoho job, or the Zoho UI would try to open
    // an invoice id that means nothing to Zoho Books.
    test('does not masquerade as a Zoho job', () {
      expect(xeroJob.hasZohoInvoice, isFalse);
      expect(xeroJob.zohoInvoiceId, '');
    });
  });

  test('an uninvoiced job resolves to nothing', () {
    final job = _job();
    expect(job.resolvedInvoiceProviderId, '');
    expect(job.resolvedInvoiceId, '');
    expect(job.hasAccountingInvoice, isFalse);
  });

  test('neutral fields win when both are present', () {
    // The Zoho path writes both sets, so this is the normal case for a
    // Zoho-invoiced job created from here on.
    final both = _job(
      invoiceProviderId: 'zoho',
      accountingInvoiceId: 'zi-1',
      zohoInvoiceId: 'zi-1',
    );
    expect(both.resolvedInvoiceId, 'zi-1');
    expect(both.resolvedInvoiceProviderId, 'zoho');
  });

  group('month move preserves the links', () {
    // withPreservedSystemFields is what stands between a date change and
    // permanently losing a job's invoice link.
    test('carries every neutral field across a form rebuild', () {
      final source = _job(
        invoiceProviderId: 'xero',
        accountingContactId: 'xc-1',
        accountingInvoiceId: 'xi-1',
        accountingInvoiceNumber: 'INV-0042',
        accountingInvoiceStatus: 'AUTHORISED',
        accountingSyncedAt: DateTime(2026, 8, 19, 9),
      );
      // What the Add/Edit form produces: no invoice fields at all.
      final rebuilt = _job().withPreservedSystemFields(source);

      expect(rebuilt.invoiceProviderId, 'xero');
      expect(rebuilt.accountingContactId, 'xc-1');
      expect(rebuilt.accountingInvoiceId, 'xi-1');
      expect(rebuilt.accountingInvoiceNumber, 'INV-0042');
      expect(rebuilt.accountingInvoiceStatus, 'AUTHORISED');
      expect(rebuilt.accountingSyncedAt, DateTime(2026, 8, 19, 9));
    });

    test('still carries the legacy Zoho fields', () {
      final source = _job(zohoInvoiceId: 'zi-1', zohoInvoiceNumber: 'INV-001');
      final rebuilt = _job().withPreservedSystemFields(source);
      expect(rebuilt.zohoInvoiceId, 'zi-1');
      expect(rebuilt.zohoInvoiceNumber, 'INV-001');
    });
  });

  group('toMap', () {
    test('omits neutral keys entirely when uninvoiced', () {
      final map = _job().toMap();
      expect(map.containsKey('invoiceProviderId'), isFalse);
      expect(map.containsKey('accountingInvoiceId'), isFalse);
      expect(map.containsKey('accountingSyncedAt'), isFalse);
    });

    test('writes them once invoiced', () {
      final map = _job(
        invoiceProviderId: 'xero',
        accountingInvoiceId: 'xi-1',
        accountingInvoiceNumber: 'INV-0042',
        accountingInvoiceStatus: 'AUTHORISED',
      ).toMap();
      expect(map['invoiceProviderId'], 'xero');
      expect(map['accountingInvoiceId'], 'xi-1');
      expect(map['accountingInvoiceNumber'], 'INV-0042');
      expect(map['accountingInvoiceStatus'], 'AUTHORISED');
    });
  });

  group('the Job List row action routes by the right provider', () {
    // Which provider opens an EXISTING invoice must come from the invoice, not
    // from the job type's current company — a job type reassigned between
    // companies would otherwise open the wrong provider's screen with an id it
    // does not recognise.
    test('a legacy Zoho job routes to Zoho even with no provider field', () {
      final job = _job(zohoInvoiceId: 'zi-1', zohoInvoiceNumber: 'INV-001');
      expect(job.resolvedInvoiceProviderId, AccountingProvider.zoho.name);
      expect(job.resolvedInvoiceId, 'zi-1');
    });

    test('a Xero job routes to Xero', () {
      final job = _job(
        invoiceProviderId: 'xero',
        accountingInvoiceId: 'xi-1',
        accountingInvoiceNumber: 'INV-0042',
      );
      expect(job.resolvedInvoiceProviderId, AccountingProvider.xero.name);
      expect(job.resolvedInvoiceId, 'xi-1');
    });

    test('the stored provider survives a company reassignment', () {
      // The company link may change; the invoice already raised does not.
      final job = _job(
        invoiceProviderId: 'zoho',
        accountingInvoiceId: 'zi-9',
      );
      expect(job.resolvedInvoiceProviderId, AccountingProvider.zoho.name);
    });
  });

  test('Xero is now an implemented accounting provider', () {
    expect(AccountingProvider.xero.isImplemented, isTrue);
    expect(AccountingProvider.zoho.isImplemented, isTrue);
    expect(AccountingProvider.none.isImplemented, isTrue);
    expect(AccountingProvider.sage.isImplemented, isFalse);
  });

  test('CLM is seeded to invoice through Xero', () {
    final clm = Company.seed.firstWhere((c) => c.id == Company.clmId);
    expect(clm.accountingProvider, AccountingProvider.xero);
    expect(clm.accountingProvider.isImplemented, isTrue);
  });
}
