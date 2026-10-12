import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/custom_invoice_status.dart';
import 'package:clmschedule/models/custom_job_list_status.dart';
import 'package:clmschedule/models/job_invoice_link.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/models/xero_invoice.dart';
import 'package:clmschedule/utils/job_lifecycle_rules.dart';

/// The live `customJobListStatuses` documents, as they actually are in the
/// clmschedule project. Hard-coding the real shape is the point: these rules
/// resolve against user-editable status documents, and a test built on tidy
/// invented data would not catch the two things that bite — a legacy snake_case
/// id whose label no longer matches it ('order_confirmed_not_paid' is labelled
/// 'Order Confirmed'), and labels that carry a company prefix.
List<CustomJobListStatus> liveJobStatuses() => const [
      CustomJobListStatus(
          id: 'Vn2oduXqJml9Iqr5w3KG', label: 'Scheduled', color: Colors.grey),
      CustomJobListStatus(
          id: 'WSJWywakCsaqy0q6XEfm',
          label: 'HS - Job Done',
          color: Colors.grey),
      CustomJobListStatus(
          id: 'aBBm7UdUNVHdZqs8yHtl',
          label: 'CLM - Report Ready',
          color: Colors.grey),
      CustomJobListStatus(
          id: 'c73qWVcWWrxdOugq8oN2', label: 'Cancelled', color: Colors.grey),
      CustomJobListStatus(
          id: 'job_done', label: 'CLM - Job Done', color: Colors.grey),
      // The label says "Order Confirmed"; the id is a legacy slug for the
      // long-gone "Order Confirmed Not Paid".
      CustomJobListStatus(
          id: 'order_confirmed_not_paid',
          label: 'Order Confirmed',
          color: Colors.grey),
      CustomJobListStatus(
          id: 'report_sent', label: 'CLM - Report Sent', color: Colors.grey),
      CustomJobListStatus(id: 'standby', label: 'Standby', color: Colors.grey),
    ];

/// The live `customInvoiceStatuses` documents.
List<CustomInvoiceStatus> liveInvoiceStatuses() => const [
      CustomInvoiceStatus(
          id: 'YSC9nhMCmx3uohJmlwfX', label: 'PAY_OVERDUE', color: Colors.grey),
      CustomInvoiceStatus(
          id: 'g3SCqCO6VptMVoafC8zB', label: 'INV_PAID', color: Colors.grey),
      CustomInvoiceStatus(
          id: 'ntsQLSaFsYtzifeQNXO1',
          label: 'PAY_OUTSTANDING',
          color: Colors.grey),
      CustomInvoiceStatus(
          id: 'pending', label: 'INV_NOT CREATED', color: Colors.grey),
    ];

JobListItem job({
  String jobStatusId = 'standby',
  String zohoInvoiceId = '',
  String accountingInvoiceId = '',
  String invoiceProviderId = '',
}) =>
    JobListItem(
      id: 'j1',
      invoice: '',
      amount: 0,
      client: 'Acme',
      jobStatusId: jobStatusId,
      jobTypeId: 'distribution',
      area: '',
      quantity: 0,
      manDays: 0,
      date: DateTime(2026, 9, 23),
      collectionAddress: '',
      collectionDate: DateTime(2026, 9, 23),
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
      zohoInvoiceId: zohoInvoiceId,
      accountingInvoiceId: accountingInvoiceId,
      invoiceProviderId: invoiceProviderId,
    );

void main() {
  group('resolveCopyJobStatusId', () {
    test('a copy opens as Order Confirmed, by label not by id', () {
      expect(
        resolveCopyJobStatusId(
          statuses: liveJobStatuses(),
          sourceStatusId: 'report_sent',
        ),
        'order_confirmed_not_paid',
      );
    });

    test('the source status is never carried over, whatever it was', () {
      for (final source in liveJobStatuses()) {
        expect(
          resolveCopyJobStatusId(
            statuses: liveJobStatuses(),
            sourceStatusId: source.id,
          ),
          'order_confirmed_not_paid',
        );
      }
    });

    test('a relabelled status still resolves through the seeded id', () {
      final renamed = [
        const CustomJobListStatus(
            id: 'order_confirmed_not_paid',
            label: 'Order Placed',
            color: Colors.grey),
        const CustomJobListStatus(
            id: 'report_sent', label: 'CLM - Report Sent', color: Colors.grey),
      ];
      expect(
        resolveCopyJobStatusId(
            statuses: renamed, sourceStatusId: 'report_sent'),
        'order_confirmed_not_paid',
      );
    });

    test('with no such status at all the copy keeps the source status', () {
      final unrelated = [
        const CustomJobListStatus(
            id: 'report_sent', label: 'CLM - Report Sent', color: Colors.grey),
      ];
      expect(
        resolveCopyJobStatusId(
            statuses: unrelated, sourceStatusId: 'report_sent'),
        'report_sent',
      );
    });

    test('an empty status collection never invents an id', () {
      expect(
        resolveCopyJobStatusId(statuses: const [], sourceStatusId: 'standby'),
        'standby',
      );
    });
  });

  group('resolveCopyInvoiceStatusId', () {
    test('a copy opens as invoice not created', () {
      // A copy has no invoice link or number, so it has not been billed —
      // "outstanding" would claim an invoice nobody has sent.
      expect(
        resolveCopyInvoiceStatusId(
          statuses: liveInvoiceStatuses(),
          sourceStatusId: 'g3SCqCO6VptMVoafC8zB',
        ),
        'pending',
      );
    });

    test('never resolves to the id-shaped label it used to be given', () {
      // The bug this replaces wrote the *label* 'INV_NOT CREATED' into
      // invoiceStatusId, where the id is 'pending' — so the copy carried a
      // status id no document had.
      final resolved = resolveCopyInvoiceStatusId(
        statuses: liveInvoiceStatuses(),
        sourceStatusId: 'pending',
      );
      expect(resolved, isNot('INV_NOT CREATED'));
      expect(
        liveInvoiceStatuses().map((s) => s.id),
        contains(resolved),
        reason: 'the resolved id must belong to a real status document',
      );
    });

    test('matches the label case-insensitively after a prettifying rename', () {
      final renamed = [
        const CustomInvoiceStatus(
            id: 'abc123', label: 'Invoice not created', color: Colors.grey),
      ];
      expect(
        resolveCopyInvoiceStatusId(statuses: renamed, sourceStatusId: 'x'),
        'abc123',
      );
    });

    test('a relabelled status is still found by its seeded id', () {
      final relabelled = [
        const CustomInvoiceStatus(
            id: 'pending', label: 'Not billed', color: Colors.grey),
      ];
      expect(
        resolveCopyInvoiceStatusId(statuses: relabelled, sourceStatusId: 'x'),
        'pending',
      );
    });

    test('with nothing recognisable the copy keeps the source status', () {
      final unrelated = [
        const CustomInvoiceStatus(id: 'q', label: 'Other', color: Colors.grey),
      ];
      expect(
        resolveCopyInvoiceStatusId(statuses: unrelated, sourceStatusId: 'src'),
        'src',
      );
    });
  });

  group('shouldOfferVoidOnCancel', () {
    const cancelled = 'c73qWVcWWrxdOugq8oN2';

    test('offers on the transition into cancelled', () {
      expect(
        shouldOfferVoidOnCancel(
          before: job(jobStatusId: 'standby', zohoInvoiceId: 'inv-1'),
          after: job(jobStatusId: cancelled, zohoInvoiceId: 'inv-1'),
          cancelledStatusId: cancelled,
        ),
        isTrue,
      );
    });

    test('does not nag when the job was already cancelled', () {
      expect(
        shouldOfferVoidOnCancel(
          before: job(jobStatusId: cancelled, zohoInvoiceId: 'inv-1'),
          after: job(jobStatusId: cancelled, zohoInvoiceId: 'inv-1'),
          cancelledStatusId: cancelled,
        ),
        isFalse,
      );
    });

    test('stays silent for a status change that is not a cancel', () {
      expect(
        shouldOfferVoidOnCancel(
          before: job(jobStatusId: 'standby', zohoInvoiceId: 'inv-1'),
          after: job(jobStatusId: 'job_done', zohoInvoiceId: 'inv-1'),
          cancelledStatusId: cancelled,
        ),
        isFalse,
      );
    });

    test('stays silent when the job has no invoice', () {
      expect(
        shouldOfferVoidOnCancel(
          before: job(jobStatusId: 'standby'),
          after: job(jobStatusId: cancelled),
          cancelledStatusId: cancelled,
        ),
        isFalse,
      );
    });

    test('sees a Xero invoice through the provider-neutral fields', () {
      expect(
        shouldOfferVoidOnCancel(
          before: job(
              jobStatusId: 'standby',
              accountingInvoiceId: 'x-1',
              invoiceProviderId: 'xero'),
          after: job(
              jobStatusId: cancelled,
              accountingInvoiceId: 'x-1',
              invoiceProviderId: 'xero'),
          cancelledStatusId: cancelled,
        ),
        isTrue,
      );
    });

    test('never guesses when no cancelled status has been nominated', () {
      // An empty setting must not make every status change look like a cancel.
      expect(
        shouldOfferVoidOnCancel(
          before: job(jobStatusId: 'standby', zohoInvoiceId: 'inv-1'),
          after: job(jobStatusId: '', zohoInvoiceId: 'inv-1'),
          cancelledStatusId: '',
        ),
        isFalse,
      );
    });
  });

  // The live settings/zohoSync invoiceStatusMap.
  const statusMap = {
    'paid': 'g3SCqCO6VptMVoafC8zB',
    'overdue': 'YSC9nhMCmx3uohJmlwfX',
    'sent': 'ntsQLSaFsYtzifeQNXO1',
    'void': 'cancelled',
    'partially_paid': 'tBswxRE4xltvEZFxGp2V',
  };
  const paid = 'g3SCqCO6VptMVoafC8zB';
  const outstanding = 'ntsQLSaFsYtzifeQNXO1';
  const overdue = 'YSC9nhMCmx3uohJmlwfX';

  JobListItem invoiced({
    required String provider,
    required String status,
    String invoiceStatusId = 'pending',
  }) =>
      job(
        accountingInvoiceId: 'inv-1',
        invoiceProviderId: provider,
      ).copyWith(
        accountingInvoiceStatus: status,
        invoiceStatusId: invoiceStatusId,
      );

  group('desiredInvoiceStatusId', () {
    test('a contradicting status is moved to what the books say', () {
      expect(
        desiredInvoiceStatusId(
            currentStatusId: outstanding,
            bookKeys: const ['paid'],
            statusMap: statusMap),
        paid,
      );
    });

    test('Paid set by hand is never taken away', () {
      // Paid in cash: the books still say sent, and must not win.
      expect(
        desiredInvoiceStatusId(
            currentStatusId: paid,
            bookKeys: const ['sent'],
            statusMap: statusMap),
        isNull,
      );
    });

    test('an already-consistent status is left alone', () {
      expect(
        desiredInvoiceStatusId(
            currentStatusId: overdue,
            bookKeys: const ['sent', 'overdue'],
            statusMap: statusMap),
        isNull,
      );
    });

    test('an unmapped book status does not touch the column', () {
      expect(
        desiredInvoiceStatusId(
            currentStatusId: outstanding,
            bookKeys: const ['draft'],
            statusMap: statusMap),
        isNull,
      );
    });
  });

  group('cachedBookStatusKeys', () {
    test('a job with no invoice has no book status', () {
      expect(cachedBookStatusKeys(job()), isEmpty);
    });

    test('a cached Xero AUTHORISED may be sent, overdue or part-paid', () {
      expect(
        cachedBookStatusKeys(invoiced(provider: 'xero', status: 'AUTHORISED')),
        ['sent', 'overdue', 'partially_paid'],
      );
    });

    test('Xero VOIDED and DELETED both read as void', () {
      expect(cachedBookStatusKeys(invoiced(provider: 'xero', status: 'VOIDED')),
          ['void']);
      expect(
          cachedBookStatusKeys(invoiced(provider: 'xero', status: 'DELETED')),
          ['void']);
    });

    test('a cached Zoho sent may have gone overdue in Zoho since', () {
      expect(cachedBookStatusKeys(invoiced(provider: 'zoho', status: 'sent')),
          ['sent', 'overdue']);
    });

    group('split across invoices', () {
      JobListItem split(String primary, List<String> splits) =>
          invoiced(provider: 'xero', status: primary).copyWith(
            splitInvoices: [
              for (var n = 0; n < splits.length; n++)
                JobInvoiceLink(
                  providerId: 'xero',
                  invoiceId: 'split-$n',
                  invoiceNumber: 'INV-$n',
                  status: splits[n],
                ),
            ],
          );

      test('paid only when every invoice is paid', () {
        expect(cachedBookStatusKeys(split('PAID', ['PAID', 'PAID'])),
            ['paid']);
      });

      test('one client still owing keeps the job outstanding, part-paid', () {
        expect(cachedBookStatusKeys(split('PAID', ['AUTHORISED'])),
            ['sent', 'overdue', 'partially_paid']);
      });

      test('a void split does not hold a paid job back', () {
        expect(cachedBookStatusKeys(split('PAID', ['VOIDED'])), ['paid']);
      });

      test('void only when every invoice is void', () {
        expect(cachedBookStatusKeys(split('VOIDED', ['DELETED'])), ['void']);
      });

      test('an unreadable status leaves the column alone', () {
        expect(cachedBookStatusKeys(split('PAID', [''])), isEmpty);
      });
    });
  });

  group('xeroBookStatusKey', () {
    XeroInvoice inv(XeroInvoiceStatus status,
            {double due = 100, double paidAmount = 0, DateTime? dueDate}) =>
        XeroInvoice(
          invoiceId: 'x',
          invoiceNumber: 'INV-1',
          contactId: 'c',
          status: status,
          amountDue: due,
          amountPaid: paidAmount,
          dueDate: dueDate,
        );

    test('derives overdue and part-paid from an AUTHORISED invoice', () {
      expect(xeroBookStatusKey(inv(XeroInvoiceStatus.authorised)), 'sent');
      expect(
          xeroBookStatusKey(inv(XeroInvoiceStatus.authorised,
              dueDate: DateTime(2020, 1, 1))),
          'overdue');
      expect(
          xeroBookStatusKey(
              inv(XeroInvoiceStatus.authorised, due: 50, paidAmount: 50)),
          'partially_paid');
    });

    test('maps the terminal states', () {
      expect(xeroBookStatusKey(inv(XeroInvoiceStatus.paid)), 'paid');
      expect(xeroBookStatusKey(inv(XeroInvoiceStatus.voided)), 'void');
      expect(xeroBookStatusKey(inv(XeroInvoiceStatus.draft)), 'draft');
    });
  });

  group('isManualInvoiceStatusAllowed', () {
    test('any status may be picked for a job with no invoice', () {
      expect(
        isManualInvoiceStatusAllowed(
            job: job(), newStatusId: outstanding, statusMap: statusMap),
        isTrue,
      );
    });

    test('an invoiced job may be marked Paid by hand', () {
      expect(
        isManualInvoiceStatusAllowed(
            job: invoiced(provider: 'xero', status: 'AUTHORISED'),
            newStatusId: paid,
            statusMap: statusMap),
        isTrue,
      );
    });

    test('an invoiced job may not be set to contradict its books', () {
      expect(
        isManualInvoiceStatusAllowed(
            job: invoiced(provider: 'xero', status: 'PAID'),
            newStatusId: outstanding,
            statusMap: statusMap),
        isFalse,
      );
    });

    test('a manual Paid can be undone back to what the books say', () {
      expect(
        isManualInvoiceStatusAllowed(
            job: invoiced(
                provider: 'zoho', status: 'sent', invoiceStatusId: paid),
            newStatusId: outstanding,
            statusMap: statusMap),
        isTrue,
      );
    });
  });
}
