import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/invoice_message_subject.dart';
import 'package:clmschedule/models/invoice_message_template.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/models/zoho_customer.dart';
import 'package:clmschedule/models/zoho_invoice.dart';
import 'package:clmschedule/models/zoho_item.dart';
import 'package:clmschedule/models/zoho_item_autofill.dart';
import 'package:clmschedule/widgets/zoho/invoice_save_saga.dart';

/// Guards the invoicing data path. Invoice data is financial: a dropped field
/// or a duplicated write is a real accounting error, not a cosmetic bug.

JobListItem _job({
  String id = 'job-1',
  String invoice = 'INV-001',
  double amount = 1500,
  String zohoInvoiceId = 'zi-1',
}) {
  return JobListItem(
    id: id,
    invoice: invoice,
    amount: amount,
    client: 'ACME Waste',
    jobStatusId: 'standby',
    jobTypeId: 'junkCollection',
    area: 'Claremont',
    quantity: 1,
    manDays: 1,
    date: DateTime(2026, 8, 12),
    collectionAddress: '1 Main Rd',
    collectionDate: DateTime(2026, 8, 12),
    specialInstructions: '',
    quantityDistributed: 0,
    invoiceDetails: 'Two skips',
    reportAddresses: '',
    whoToInvoice: 'Accounts',
    // Fields the Add/Edit form does not render — the ones at risk.
    shareableMapId: 'map-9',
    storageFolderPath: 'Distribution/2026',
    timeSlot: '09:30',
    timeSlots: 4,
    assignedStaff: const ['John', 'Mary'],
    staffCount: 2,
    zohoContactId: 'zc-1',
    zohoInvoiceId: zohoInvoiceId,
    zohoInvoiceNumber: 'INV-001',
    zohoInvoiceStatus: 'sent',
    zohoSyncedAt: DateTime(2026, 8, 12, 10),
  );
}

void main() {
  group('JobListItem serialisation round-trip', () {
    test('every invoicing and schedule field survives toMap -> fromMap', () {
      final original = _job();
      final restored = JobListItem.fromMap(original.id, original.toMap());

      expect(restored.zohoContactId, 'zc-1');
      expect(restored.zohoInvoiceId, 'zi-1');
      expect(restored.zohoInvoiceNumber, 'INV-001');
      expect(restored.zohoInvoiceStatus, 'sent');
      expect(restored.zohoSyncedAt, isNotNull);
      expect(restored.hasZohoInvoice, isTrue);

      expect(restored.timeSlot, '09:30');
      expect(restored.timeSlots, 4);
      expect(restored.assignedStaff, ['John', 'Mary']);
      expect(restored.staffCount, 2);

      expect(restored.amount, 1500);
      expect(restored.invoice, 'INV-001');
    });

    test('a job with no Zoho link writes no Zoho keys at all', () {
      final plain = _job().copyWith(
        zohoContactId: '',
        zohoInvoiceId: '',
        zohoInvoiceNumber: '',
        zohoInvoiceStatus: '',
      );
      final map = plain.toMap();

      // Conditional writes keep untouched documents byte-identical to before
      // the Zoho fields existed.
      expect(map.containsKey('zohoInvoiceId'), isFalse);
      expect(map.containsKey('zohoContactId'), isFalse);
      expect(JobListItem.fromMap('x', map).hasZohoInvoice, isFalse);
    });

    test('legacy documents fall back rather than losing schedule data', () {
      // A record written before timeSlot/timeSlots/staffCount existed.
      final legacy = <String, dynamic>{
        'invoice': 'OLD-1',
        'amount': 500.0,
        'client': 'Legacy',
        'jobStatusId': 'standby',
        'jobType': 'junkCollection',
        'area': 'Wynberg',
        'quantity': 1,
        'manDays': 3.0,
        'quantityDistributed': 6,
        'invoiceDetails': '',
        'reportAddresses': '',
        'whoToInvoice': '',
        'collectionAddress': '',
        'specialInstructions': '',
      };
      final item = JobListItem.fromMap('legacy-1', legacy);

      // Duration falls back to the old quantityDistributed overload...
      expect(item.resolvedTimeSlots, 6);
      // ...and staffing to manDays.ceil().
      expect(item.resolvedStaffCount, 3);
      // Start time derives from the date's time component.
      expect(item.resolvedTimeSlot, matches(RegExp(r'^\d{2}:\d{2}$')));
    });
  });

  group('Copying a job must not clone the invoice link', () {
    test('a copy carries content but never the Zoho identifiers', () {
      final source = _job();

      // Mirrors _showCopyJobDialog's copiedJob construction.
      final copy = source.copyWith(
        id: '',
        invoice: '',
        invoiceStatusId: 'INV_NOT CREATED',
        collectionJobId: '',
        shareableMapId: '',
        storageFolderPath: '',
        updates: const [],
        zohoContactId: '',
        zohoInvoiceId: '',
        zohoInvoiceNumber: '',
        zohoInvoiceStatus: '',
      );

      // Two jobs pointing at one invoice would make paying one appear to
      // settle both.
      expect(copy.zohoInvoiceId, isEmpty);
      expect(copy.zohoInvoiceNumber, isEmpty);
      expect(copy.zohoContactId, isEmpty);
      expect(copy.hasZohoInvoice, isFalse,
          reason: 'a copy must be able to raise its own invoice');

      // The invoice number must not be reused either.
      expect(copy.invoice, isEmpty);

      // But the reusable job content is retained.
      expect(copy.client, 'ACME Waste');
      expect(copy.amount, 1500);
      expect(copy.assignedStaff, ['John', 'Mary']);
    });
  });

  group('Editing must not destroy fields the form does not render', () {
    /// What the Add/Edit dialog produces from its controllers alone: every
    /// non-form field comes back empty.
    JobListItem formRebuild(JobListItem source) {
      return JobListItem(
        id: source.id,
        invoice: source.invoice,
        amount: source.amount,
        client: source.client,
        jobStatusId: source.jobStatusId,
        jobTypeId: source.jobTypeId,
        area: source.area,
        quantity: source.quantity,
        manDays: source.manDays,
        date: source.date,
        collectionAddress: source.collectionAddress,
        collectionDate: source.collectionDate,
        specialInstructions: source.specialInstructions,
        quantityDistributed: source.quantityDistributed,
        invoiceDetails: source.invoiceDetails,
        reportAddresses: source.reportAddresses,
        whoToInvoice: source.whoToInvoice,
      );
    }

    test('the raw form rebuild would lose the invoice link', () {
      // Documents why withPreservedSystemFields has to exist.
      final naked = formRebuild(_job());
      expect(naked.hasZohoInvoice, isFalse);
      expect(naked.timeSlot, isEmpty);
      expect(naked.shareableMapId, isEmpty);
    });

    test('withPreservedSystemFields restores every non-form field', () {
      final source = _job();
      final rebuilt = formRebuild(source).withPreservedSystemFields(source);

      expect(rebuilt.zohoInvoiceId, 'zi-1');
      expect(rebuilt.zohoContactId, 'zc-1');
      expect(rebuilt.zohoInvoiceNumber, 'INV-001');
      expect(rebuilt.zohoInvoiceStatus, 'sent');
      expect(rebuilt.zohoSyncedAt, source.zohoSyncedAt);
      expect(rebuilt.timeSlot, '09:30');
      expect(rebuilt.timeSlots, 4);
      expect(rebuilt.assignedStaff, ['John', 'Mary']);
      expect(rebuilt.staffCount, 2);
      expect(rebuilt.shareableMapId, 'map-9');
      expect(rebuilt.storageFolderPath, 'Distribution/2026');
    });

    test('a month move (set + delete) preserves everything after the fix', () {
      final source = _job();
      final rebuilt = formRebuild(source).withPreservedSystemFields(source);

      // moveJobListItemToMonth does batch.set(newDoc, toMap()) then deletes
      // the old doc — a full overwrite, with no old values to fall back on.
      final moved = JobListItem.fromMap(source.id, rebuilt.toMap());

      expect(moved.hasZohoInvoice, isTrue,
          reason: 'moving a job to another month must not unlink its invoice');
      expect(moved.zohoInvoiceNumber, 'INV-001');
      expect(moved.assignedStaff, ['John', 'Mary']);
      expect(moved.shareableMapId, 'map-9');
    });

    test('a new job (null source) keeps its defaults', () {
      final fresh = formRebuild(_job(id: '')).withPreservedSystemFields(null);
      expect(fresh.hasZohoInvoice, isFalse);
      expect(fresh.assignedStaff, isEmpty);
    });
  });

  group('ZohoLineItem create vs update payloads', () {
    const line = ZohoLineItem(
      lineItemId: 'li-99',
      itemId: 'item-7',
      name: 'Junk collection',
      description: 'Two skips, Claremont',
      rate: 750,
      quantity: 2,
    );

    test('create omits line_item_id so a new invoice owns its own lines', () {
      final json = line.toJson();
      expect(json.containsKey('line_item_id'), isFalse);
      expect(json['item_id'], 'item-7');
      expect(json['description'], 'Two skips, Claremont');
    });

    test('update includes line_item_id so Zoho amends instead of replacing',
        () {
      final json = line.toJson(forUpdate: true);
      expect(json['line_item_id'], 'li-99');
    });

    test('no tax is sent — VAT is not charged', () {
      expect(line.toJson().containsKey('tax_id'), isFalse);
    });

    test('amount is rate x quantity', () {
      expect(line.amount, 1500);
    });
  });

  group('Editing a job amends its invoice rather than replacing it', () {
    /// An invoice as read back from Zoho: every line carries a line_item_id.
    final fromZoho = ZohoInvoice.fromJson({
      'invoice_id': 'zi-1',
      'invoice_number': 'INV-000123',
      'customer_id': 'zc-1',
      'status': 'sent',
      'date': '2026-08-01',
      'due_date': '2026-08-01',
      'reference_number': 'REF-9',
      'line_items': [
        {
          'line_item_id': 'li-1',
          'item_id': 'item-7',
          'name': 'Junk collection',
          'description': 'Two skips',
          'rate': 750.0,
          'quantity': 2.0,
        },
      ],
    });

    test('the loaded invoice keeps its line ids for amendment', () {
      expect(fromZoho.lineItems.single.lineItemId, 'li-1');
      expect(fromZoho.lineItems.single.description, 'Two skips');
    });

    test('an edited line is amended in place, not recreated', () {
      // User changes the rate on the existing line.
      final edited = fromZoho.lineItems.single.copyWith(rate: 900);

      final amended = ZohoInvoice(
        invoiceId: fromZoho.invoiceId,
        invoiceNumber: fromZoho.invoiceNumber,
        customerId: fromZoho.customerId,
        date: fromZoho.date,
        dueDate: fromZoho.dueDate,
        referenceNumber: fromZoho.referenceNumber,
        notes: 'Updated note',
        lineItems: [edited],
      );

      final json = amended.toUpdateJson();

      // Identity preserved — no new invoice, no renumbering.
      expect(json['invoice_number'], 'INV-000123');
      expect(json['date'], '2026-08-01');

      final line = (json['line_items'] as List).single as Map<String, dynamic>;
      expect(line['line_item_id'], 'li-1',
          reason: 'without the id Zoho drops the line and creates a new one');
      expect(line['rate'], 900);
      expect(line['item_id'], 'item-7');
    });

    test('a newly added line carries no line_item_id', () {
      final amended = ZohoInvoice(
        invoiceId: fromZoho.invoiceId,
        invoiceNumber: fromZoho.invoiceNumber,
        customerId: fromZoho.customerId,
        lineItems: [
          fromZoho.lineItems.single,
          const ZohoLineItem(name: 'Extra load', rate: 300, quantity: 1),
        ],
      );

      final lines = (amended.toUpdateJson()['line_items'] as List)
          .cast<Map<String, dynamic>>();
      expect(lines, hasLength(2));
      expect(lines[0]['line_item_id'], 'li-1');
      expect(lines[1].containsKey('line_item_id'), isFalse,
          reason: 'a new line must not borrow another line\'s id');
    });

    test('paid and void invoices are not editable', () {
      // Mirrors the dialog's guard: Zoho rejects void edits, and amending a
      // settled invoice desyncs the recorded payment from the total.
      bool editable(ZohoInvoiceStatus s) =>
          s != ZohoInvoiceStatus.isVoid && s != ZohoInvoiceStatus.paid;

      expect(editable(ZohoInvoiceStatus.sent), isTrue);
      expect(editable(ZohoInvoiceStatus.draft), isTrue);
      expect(editable(ZohoInvoiceStatus.overdue), isTrue);
      expect(editable(ZohoInvoiceStatus.partiallyPaid), isTrue);
      expect(editable(ZohoInvoiceStatus.paid), isFalse);
      expect(editable(ZohoInvoiceStatus.isVoid), isFalse);
    });
  });

  group('ZohoCustomer writes contact details via contact_persons', () {
    test('create nests details under contact_persons, not the top level', () {
      const c = ZohoCustomer(
        contactId: '',
        contactName: 'ACME Waste',
        email: 'ops@acme.test',
        mobile: '0821234567',
      );
      final json = c.toCreateJson();

      // Zoho ignores top-level email/phone on write; sending them there would
      // silently create a customer with no contact details.
      expect(json.containsKey('email'), isFalse);
      expect(json.containsKey('mobile'), isFalse);

      final persons = json['contact_persons'] as List;
      expect(persons, hasLength(1));
      final p = persons.first as Map<String, dynamic>;
      expect(p['email'], 'ops@acme.test');
      expect(p['mobile'], '0821234567');
      expect(p['is_primary_contact'], isTrue);
      expect(p.containsKey('contact_person_id'), isFalse);
    });

    test('update carries contact_person_id so no duplicate person is added',
        () {
      const c = ZohoCustomer(
        contactId: 'zc-1',
        contactName: 'ACME Waste',
        mobile: '0821234567',
        primaryContactPersonId: 'cp-5',
      );
      final persons = c.toUpdateJson()['contact_persons'] as List;
      expect((persons.first as Map)['contact_person_id'], 'cp-5');
    });

    test('phone and mobile stay distinct', () {
      const c = ZohoCustomer(
        contactId: 'x',
        contactName: 'N',
        phone: '0211112222',
        mobile: '0821234567',
      );
      final p = (c.toCreateJson()['contact_persons'] as List).first as Map;
      expect(p['phone'], '0211112222');
      expect(p['mobile'], '0821234567');
      // Display prefers work phone, falling back to mobile.
      expect(c.bestPhone, '0211112222');
      expect(
          const ZohoCustomer(contactId: 'x', contactName: 'N', mobile: '082')
              .bestPhone,
          '082');
    });

    test('a name-only seed is a create, not an update', () {
      // The job dialog's picker seeds the form with just the job's client
      // name so a new contact is pre-filled. Deciding create-vs-update on
      // "was an object passed" treated that as an edit and called
      // updateCustomer, which Zoho rejects for a missing contactId.
      const seed = ZohoCustomer(contactId: '', contactName: 'New Client');
      expect(seed.existsInZoho, isFalse);

      const real = ZohoCustomer(contactId: 'zc-1', contactName: 'ACME');
      expect(real.existsInZoho, isTrue);
    });

    test('reads prefer the primary contact person over top-level mirrors', () {
      final c = ZohoCustomer.fromJson({
        'contact_id': 'zc-1',
        'contact_name': 'ACME',
        'email': '',
        'mobile': '',
        'contact_persons': [
          {
            'contact_person_id': 'cp-5',
            'is_primary_contact': true,
            'email': 'real@acme.test',
            'mobile': '0829998888',
          }
        ],
      });
      expect(c.email, 'real@acme.test');
      expect(c.mobile, '0829998888');
      expect(c.primaryContactPersonId, 'cp-5');
    });
  });

  group('InvoiceSaveSaga never double-creates on retry', () {
    late int saveJobCalls;
    late int createInvoiceCalls;
    late int linkCalls;

    const customer = ZohoCustomer(contactId: 'zc-1', contactName: 'ACME');

    InvoiceSaveSaga<ZohoCustomer, ZohoInvoice> build(
        {required bool linkFailsFirstTime}) {
      saveJobCalls = 0;
      createInvoiceCalls = 0;
      linkCalls = 0;
      var linkAttempts = 0;

      return InvoiceSaveSaga<ZohoCustomer, ZohoInvoice>(
        customer: customer,
        onProgress: () {},
        providerName: 'Zoho',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        saveJob: () async {
          saveJobCalls++;
          return _job(id: 'saved-1');
        },
        createInvoice: (job, c) async {
          createInvoiceCalls++;
          return const ZohoInvoice(
            invoiceId: 'zi-new',
            invoiceNumber: 'INV-777',
            customerId: 'zc-1',
          );
        },
        linkToJob: (job, c, invoice) async {
          linkAttempts++;
          linkCalls++;
          if (linkFailsFirstTime && linkAttempts == 1) {
            throw StateError('network down');
          }
        },
      );
    }

    test('a clean run performs each step exactly once', () async {
      final saga = build(linkFailsFirstTime: false);
      await saga.run();

      expect(saga.isComplete, isTrue);
      expect(saga.hasFailed, isFalse);
      expect(saveJobCalls, 1);
      expect(createInvoiceCalls, 1);
      expect(linkCalls, 1);
    });

    test('retry after a link failure re-runs only the link step', () async {
      final saga = build(linkFailsFirstTime: true);

      await saga.run();
      expect(saga.hasFailed, isTrue);
      expect(saga.invoiceExists, isTrue,
          reason: 'the invoice is real and must not be recreated');
      expect(saveJobCalls, 1);
      expect(createInvoiceCalls, 1);

      await saga.run();

      expect(saga.hasFailed, isFalse);
      expect(saga.isComplete, isTrue);
      // The critical assertion: no second job, no second invoice.
      expect(saveJobCalls, 1, reason: 'job must not be saved twice');
      expect(createInvoiceCalls, 1,
          reason: 'a duplicate invoice would be an accounting error');
      expect(linkCalls, 2);
    });

    test('a failure before the invoice reports nothing was created', () async {
      final saga = InvoiceSaveSaga<ZohoCustomer, ZohoInvoice>(
        customer: customer,
        onProgress: () {},
        providerName: 'Zoho',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        saveJob: () async => throw StateError('firestore unavailable'),
        createInvoice: (j, c) async =>
            fail('must not be reached when the job save fails'),
        linkToJob: (j, c, i) async =>
            fail('must not be reached when the job save fails'),
      );

      await saga.run();

      expect(saga.hasFailed, isTrue);
      expect(saga.invoiceExists, isFalse);
      expect(saga.failureMessage, contains('firestore unavailable'));
    });

    test('the customer is recorded as done, never created', () async {
      // The saga has no create-customer path any more — customers are created
      // from the form before it runs, on both providers.
      final saga = InvoiceSaveSaga<ZohoCustomer, ZohoInvoice>(
        customer: customer,
        onProgress: () {},
        providerName: 'Zoho',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        saveJob: () async => _job(id: 'saved-1'),
        createInvoice: (j, c) async => const ZohoInvoice(
          invoiceId: 'zi',
          invoiceNumber: 'INV-1',
          customerId: 'zc-1',
        ),
        linkToJob: (j, c, i) async {},
      );

      await saga.run();
      expect(saga.customer.contactId, 'zc-1');
      expect(saga.steps[1].state, SagaStepState.done,
          reason: 'a supplied customer is an accomplished fact, not a skip');
    });
  });

  group('Invoice message templates', () {
    // Templates render the provider-neutral subject, so the Zoho invoice is
    // flattened first — which exercises the flattening as well as the render.
    final invoice = InvoiceMessageSubject.fromZoho(ZohoInvoice(
      invoiceId: 'zi-1',
      invoiceNumber: 'INV-000123',
      customerId: 'zc-1',
      customerName: 'ACME Waste',
      status: ZohoInvoiceStatus.overdue,
      date: DateTime(2026, 8, 1),
      dueDate: DateTime(2026, 8, 15),
      total: 1500,
      balance: 1500,
      invoiceUrl: 'https://zoho.example/pay/abc',
    ));

    test('every token is substituted', () {
      const template = InvoiceMessageTemplate(
        id: 't1',
        name: 'Reminder',
        body: '{client_name}|{invoice_number}|{total}|{amount_due}|'
            '{invoice_date}|{due_date}|{banking_details}|{pay_link}',
      );

      final out = template.render(invoice, bankingDetails: 'Bank: Test');

      expect(out, contains('ACME Waste'));
      expect(out, contains('INV-000123'));
      expect(out, contains('15 Aug 2026'));
      expect(out, contains('Bank: Test'));
      expect(out, contains('https://zoho.example/pay/abc'));
      // No token markers should survive.
      expect(out, isNot(contains('{client_name}')));
      expect(out, isNot(contains('{banking_details}')));
    });

    test('unknown braces are left alone rather than deleted', () {
      const template = InvoiceMessageTemplate(
        id: 't1',
        name: 'X',
        body: 'Ref {not_a_token} end',
      );
      expect(template.render(invoice), 'Ref {not_a_token} end');
    });

    test('category is derived from the invoice state', () {
      expect(InvoiceMessageCategory.forInvoice(invoice),
          InvoiceMessageCategory.overdue);

      final paid = InvoiceMessageSubject.fromZoho(const ZohoInvoice(
        invoiceId: 'x',
        invoiceNumber: 'y',
        customerId: 'z',
        status: ZohoInvoiceStatus.paid,
        balance: 0,
      ));
      expect(
          InvoiceMessageCategory.forInvoice(paid), InvoiceMessageCategory.paid);

      // Partially paid still owes money, so it reads as unpaid.
      final partial = InvoiceMessageSubject.fromZoho(const ZohoInvoice(
        invoiceId: 'x',
        invoiceNumber: 'y',
        customerId: 'z',
        status: ZohoInvoiceStatus.partiallyPaid,
        balance: 500,
      ));
      expect(InvoiceMessageCategory.forInvoice(partial),
          InvoiceMessageCategory.unpaid);
    });

    test('only matching templates are offered', () {
      const overdueOnly = InvoiceMessageTemplate(
        id: 'a',
        name: 'Chase',
        body: '',
        category: InvoiceMessageCategory.overdue,
      );
      const paidOnly = InvoiceMessageTemplate(
        id: 'b',
        name: 'Thanks',
        body: '',
        category: InvoiceMessageCategory.paid,
      );
      const anyInvoice = InvoiceMessageTemplate(
        id: 'c',
        name: 'General',
        body: '',
        category: InvoiceMessageCategory.any,
      );

      expect(overdueOnly.appliesTo(invoice), isTrue);
      expect(paidOnly.appliesTo(invoice), isFalse);
      expect(anyInvoice.appliesTo(invoice), isTrue,
          reason: '"any" is a wildcard and always applies');
    });

    test('round-trips through Firestore mapping', () {
      const original = InvoiceMessageTemplate(
        id: 't1',
        name: 'Reminder',
        body: 'Hi {client_name}',
        category: InvoiceMessageCategory.overdue,
        order: 3,
      );
      final restored =
          InvoiceMessageTemplate.fromMap({...original.toMap(), 'id': 't1'});

      expect(restored.name, 'Reminder');
      expect(restored.body, 'Hi {client_name}');
      expect(restored.category, InvoiceMessageCategory.overdue);
      expect(restored.order, 3);
    });
  });

  group('ZohoInvoice status mapping', () {
    test('wire values round-trip, including the two irregular ones', () {
      for (final s in ZohoInvoiceStatus.values) {
        if (s == ZohoInvoiceStatus.unknown) continue;
        expect(ZohoInvoiceStatus.parse(s.apiValue), s,
            reason: '${s.name} must survive parse(apiValue)');
      }
      expect(ZohoInvoiceStatus.partiallyPaid.apiValue, 'partially_paid');
      expect(ZohoInvoiceStatus.isVoid.apiValue, 'void');
    });

    test('an unrecognised status degrades instead of throwing', () {
      expect(
          ZohoInvoiceStatus.parse('something_new'), ZohoInvoiceStatus.unknown);
      expect(ZohoInvoiceStatus.parse(null), ZohoInvoiceStatus.unknown);
    });

    test('only void is struck through', () {
      expect(ZohoInvoiceStatus.isVoid.isStruckThrough, isTrue);
      expect(ZohoInvoiceStatus.paid.isStruckThrough, isFalse);
    });
  });

  group('ZohoItem', () {
    test('item_id survives a numeric JSON value', () {
      // Zoho returns ids as strings, but has been seen to send numbers. A
      // silent null here would unbind every line from its catalogue item.
      final numeric = ZohoItem.fromJson({'item_id': 12345, 'name': 'Skip'});
      expect(numeric.itemId, '12345');

      final str = ZohoItem.fromJson({'item_id': '999', 'name': 'Skip'});
      expect(str.itemId, '999');
    });

    test('rate and description carry through to the line', () {
      final item = ZohoItem.fromJson({
        'item_id': '1',
        'name': '6m Skip',
        'description': '6 cubic metre skip, 3 day hire',
        'rate': 1850.0,
        'unit': 'qty',
        'sku': 'SKIP-6',
      });

      expect(item.rate, 1850.0);
      expect(item.lineDescription, '6 cubic metre skip, 3 day hire');
      expect(item.displayLabel, 'SKIP-6 — 6m Skip');
    });

    test('labels fall back so a picker never renders a blank row', () {
      final bare = ZohoItem.fromJson({'item_id': 'abc'});
      expect(bare.displayName, 'abc');
      expect(bare.lineDescription, 'abc');
      expect(bare.displayLabel, 'abc', reason: 'no sku, so no prefix');
    });

    test('description falls back to the name, not to empty', () {
      // An invoice line with a blank description reads as a mistake.
      final noDesc = ZohoItem.fromJson({'item_id': '1', 'name': 'Skip hire'});
      expect(noDesc.lineDescription, 'Skip hire');
    });
  });

  group('ZohoItemAutofill templates', () {
    Map<ItemAutofillToken, String> tokens({
      String client = 'ACME Waste',
      String area = 'Claremont',
      String quantity = '5000',
      String jobType = 'Distribution',
      String date = '26 Aug 2026',
    }) =>
        {
          ItemAutofillToken.client: client,
          ItemAutofillToken.area: area,
          ItemAutofillToken.quantity: quantity,
          ItemAutofillToken.jobType: jobType,
          ItemAutofillToken.date: date,
        };

    test('every token is substituted', () {
      final out = ZohoItemAutofill.render(
        '{quantity} flyers in {area} for {client} on {date} ({job_type})',
        tokens(),
      );
      expect(out,
          '5000 flyers in Claremont for ACME Waste on 26 Aug 2026 (Distribution)');
    });

    test('an empty token takes its separator with it', () {
      // The whole reason for the tidy-up: a job with no area must not produce
      // "5000 flyers — " with a dangling dash on a customer's invoice.
      final out = ZohoItemAutofill.render(
        '{quantity} flyers — {area}',
        tokens(area: ''),
      );
      expect(out, '5000 flyers');
    });

    test('a gap in the middle collapses to one separator', () {
      final out = ZohoItemAutofill.render(
        '{quantity} — {area} — {client}',
        tokens(area: ''),
      );
      expect(out, '5000 — ACME Waste');
    });

    test('a leading empty token does not leave punctuation behind', () {
      final out = ZohoItemAutofill.render(
          '{area} — {quantity} flyers', tokens(area: ''));
      expect(out, '5000 flyers');
    });

    test('unknown braces are left alone rather than deleted', () {
      final out = ZohoItemAutofill.render('Ref {not_a_token}', tokens());
      expect(out, 'Ref {not_a_token}');
    });

    test('an empty template renders as empty, not as stray punctuation', () {
      // Empty means "fall back to what Zoho stores", so it must not become a
      // blank-but-present string that overrides the catalogue text.
      expect(ZohoItemAutofill.render('', tokens()), '');
    });

    test('blank templates are stored as nothing', () {
      const blank = ZohoItemAutofill(itemId: '1');
      expect(blank.isEmpty, isTrue);

      const set = ZohoItemAutofill(itemId: '1', descriptionTemplate: '{area}');
      expect(set.isEmpty, isFalse);
    });

    test('round-trips through Firestore mapping', () {
      const original = ZohoItemAutofill(
        itemId: '42',
        nameTemplate: 'Distribution',
        descriptionTemplate: '{quantity} flyers — {area}',
      );
      final restored = ZohoItemAutofill.fromMap('42', original.toMap());

      expect(restored.itemId, '42');
      expect(restored.nameTemplate, 'Distribution');
      expect(restored.descriptionTemplate, '{quantity} flyers — {area}');
    });
  });
}
