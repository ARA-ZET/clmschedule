import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/invoice_message_subject.dart';
import 'package:clmschedule/models/invoice_message_template.dart';
import 'package:clmschedule/models/xero_contact.dart';
import 'package:clmschedule/models/xero_invoice.dart';
import 'package:clmschedule/models/xero_org.dart';
import 'package:clmschedule/widgets/xero/xero_line_items_editor.dart';
import 'package:clmschedule/services/xero_accounting_service.dart';

/// Guards the Xero data path. Invoice data is financial: a dropped field or a
/// mis-parsed date is a real accounting error, not a cosmetic bug.
void main() {
  group('parseXeroDate', () {
    // Xero mixes both representations in the same response — the .NET epoch
    // form on Date/DueDate/UpdatedDateUTC, ISO on the parallel *String fields.
    test('parses the .NET epoch form', () {
      final parsed = XeroInvoice.parseXeroDate('/Date(1552262400000+0000)/');
      expect(parsed, isNotNull);
      expect(parsed!.toUtc(), DateTime.utc(2019, 3, 11));
    });

    test('parses the .NET epoch form without an offset', () {
      final parsed = XeroInvoice.parseXeroDate('/Date(1552262400000)/');
      expect(parsed!.toUtc(), DateTime.utc(2019, 3, 11));
    });

    test('parses a plain ISO string', () {
      expect(XeroInvoice.parseXeroDate('2026-08-19T00:00:00'),
          DateTime(2026, 8, 19));
    });

    test('returns null for empty, null and junk', () {
      expect(XeroInvoice.parseXeroDate(null), isNull);
      expect(XeroInvoice.parseXeroDate(''), isNull);
      expect(XeroInvoice.parseXeroDate('not a date'), isNull);
      expect(XeroInvoice.parseXeroDate('/Date(nonsense)/'), isNull);
    });
  });

  group('XeroInvoiceStatus', () {
    test('parses Xero\'s uppercase wire values', () {
      expect(
          XeroInvoiceStatus.parse('AUTHORISED'), XeroInvoiceStatus.authorised);
      expect(XeroInvoiceStatus.parse('VOIDED'), XeroInvoiceStatus.voided);
      expect(XeroInvoiceStatus.parse('OVERDUE'), XeroInvoiceStatus.unknown);
      expect(XeroInvoiceStatus.parse(null), XeroInvoiceStatus.unknown);
    });

    test('round-trips through apiValue', () {
      for (final s in XeroInvoiceStatus.values) {
        if (s == XeroInvoiceStatus.unknown) continue;
        expect(XeroInvoiceStatus.parse(s.apiValue), s);
      }
    });

    // This is what forces the void-and-reissue edit flow.
    test('line items are editable only on DRAFT and SUBMITTED', () {
      expect(XeroInvoiceStatus.draft.lineItemsAreEditable, isTrue);
      expect(XeroInvoiceStatus.submitted.lineItemsAreEditable, isTrue);
      expect(XeroInvoiceStatus.authorised.lineItemsAreEditable, isFalse);
      expect(XeroInvoiceStatus.paid.lineItemsAreEditable, isFalse);
    });
  });

  group('VAT mapping', () {
    test('maps the app\'s flags onto LineAmountTypes', () {
      expect(
        XeroLineAmountType.forJob(chargesVat: true, priceIsInclVat: false),
        XeroLineAmountType.exclusive,
      );
      expect(
        XeroLineAmountType.forJob(chargesVat: true, priceIsInclVat: true),
        XeroLineAmountType.inclusive,
      );
      // chargesVat wins: a no-VAT job type is NoTax regardless of how the
      // price was entered.
      expect(
        XeroLineAmountType.forJob(chargesVat: false, priceIsInclVat: true),
        XeroLineAmountType.noTax,
      );
    });

    test('wire values match Xero\'s spelling exactly', () {
      expect(XeroLineAmountType.exclusive.apiValue, 'Exclusive');
      expect(XeroLineAmountType.inclusive.apiValue, 'Inclusive');
      expect(XeroLineAmountType.noTax.apiValue, 'NoTax');
    });
  });

  group('XeroLineItem', () {
    const line = XeroLineItem(
      lineItemId: 'li-1',
      description: '50 000 flyers, Claremont',
      quantity: 50,
      unitAmount: 12.5375,
      accountCode: '200',
      taxType: 'OUTPUT2',
    );

    test('omits LineItemID on create', () {
      expect(line.toJson().containsKey('LineItemID'), isFalse);
    });

    // Without the id Xero drops the line and creates a replacement, losing its
    // identity on the invoice.
    test('carries LineItemID on update', () {
      expect(line.toJson(forUpdate: true)['LineItemID'], 'li-1');
    });

    test('keeps 4dp unit amounts intact', () {
      expect(line.toJson()['UnitAmount'], 12.5375);
    });

    test('reads Xero-computed amounts back', () {
      final parsed = XeroLineItem.fromJson(const {
        'LineItemID': 'li-9',
        'Description': 'Distribution',
        'Quantity': 2.0,
        'UnitAmount': 100.0,
        'LineAmount': 200.0,
        'TaxAmount': 30.0,
        'AccountCode': '200',
      });
      expect(parsed.lineAmount, 200.0);
      expect(parsed.taxAmount, 30.0);
      expect(parsed.amount, 200.0);
    });
  });

  group('XeroInvoice payloads', () {
    final invoice = XeroInvoice(
      invoiceId: 'inv-1',
      contactId: 'c-1',
      date: DateTime(2026, 8, 19),
      dueDate: DateTime(2026, 9, 18),
      reference: 'job-42',
      lineAmountTypes: XeroLineAmountType.exclusive,
      lineItems: const [
        XeroLineItem(
          lineItemId: 'li-1',
          description: 'Distribution',
          unitAmount: 1500,
          accountCode: '200',
        ),
      ],
    );

    test('create is ACCREC and AUTHORISED by default', () {
      final json = invoice.toCreateJson();
      expect(json['Type'], 'ACCREC');
      expect(json['Status'], 'AUTHORISED');
      expect(json['LineAmountTypes'], 'Exclusive');
      expect(json['Date'], '2026-08-19');
      expect(json['DueDate'], '2026-09-18');
      expect((json['Contact'] as Map)['ContactID'], 'c-1');
    });

    test('create can be asked for a draft instead', () {
      expect(
        invoice.toCreateJson(status: XeroInvoiceStatus.draft)['Status'],
        'DRAFT',
      );
    });

    // Sending LineItems to an AUTHORISED invoice is rejected by Xero, so the
    // soft-update payload must not contain them at all.
    test('soft update carries no line items', () {
      final json = invoice.toSoftUpdateJson();
      expect(json.containsKey('LineItems'), isFalse);
      expect(json['InvoiceID'], 'inv-1');
      expect(json['Reference'], 'job-42');
      expect(json['DueDate'], '2026-09-18');
    });

    test('full update carries line items with their ids', () {
      final lines = invoice.toUpdateJson()['LineItems'] as List;
      expect((lines.first as Map)['LineItemID'], 'li-1');
    });
  });

  group('XeroInvoice.isOverdue', () {
    XeroInvoice at({
      required XeroInvoiceStatus status,
      required DateTime? dueDate,
      required double amountDue,
    }) {
      return XeroInvoice(
        contactId: 'c-1',
        status: status,
        dueDate: dueDate,
        amountDue: amountDue,
      );
    }

    final past = DateTime.now().subtract(const Duration(days: 5));
    final future = DateTime.now().add(const Duration(days: 5));

    // Xero has no OVERDUE status — it has to be derived or it is never shown.
    test('authorised, past due, still owing is overdue', () {
      expect(
        at(status: XeroInvoiceStatus.authorised, dueDate: past, amountDue: 100)
            .isOverdue,
        isTrue,
      );
    });

    test('not overdue when nothing is owed', () {
      expect(
        at(status: XeroInvoiceStatus.authorised, dueDate: past, amountDue: 0)
            .isOverdue,
        isFalse,
      );
    });

    test('not overdue before the due date', () {
      expect(
        at(
                status: XeroInvoiceStatus.authorised,
                dueDate: future,
                amountDue: 100)
            .isOverdue,
        isFalse,
      );
    });

    test('paid and voided are never overdue', () {
      expect(
        at(status: XeroInvoiceStatus.paid, dueDate: past, amountDue: 0)
            .isOverdue,
        isFalse,
      );
      expect(
        at(status: XeroInvoiceStatus.voided, dueDate: past, amountDue: 100)
            .isOverdue,
        isFalse,
      );
    });

    test('no due date is not overdue', () {
      expect(
        at(status: XeroInvoiceStatus.authorised, dueDate: null, amountDue: 100)
            .isOverdue,
        isFalse,
      );
    });
  });

  group('XeroContact', () {
    test('flattens the Phones array into phone and mobile', () {
      final contact = XeroContact.fromJson(const {
        'ContactID': 'c-1',
        'Name': 'ACME Media, Claremont',
        'EmailAddress': 'accounts@acme.test',
        'Phones': [
          {'PhoneType': 'DEFAULT', 'PhoneNumber': '021 555 0100'},
          {
            'PhoneType': 'MOBILE',
            'PhoneNumber': '555 0199',
            'PhoneCountryCode': '27'
          },
          {'PhoneType': 'FAX', 'PhoneNumber': ''},
        ],
      });
      expect(contact.phone, '021 555 0100');
      expect(contact.mobile, '+27 555 0199');
      // CLM's contact data is mostly mobile.
      expect(contact.bestPhone, '+27 555 0199');
    });

    test('ignores empty phone entries Xero pads the array with', () {
      final contact = XeroContact.fromJson(const {
        'Name': 'Empty',
        'Phones': [
          {'PhoneType': 'DEFAULT', 'PhoneNumber': ''},
          {'PhoneType': 'MOBILE', 'PhoneNumber': ''},
        ],
      });
      expect(contact.phone, '');
      expect(contact.mobile, '');
      expect(contact.bestPhone, '');
    });

    test('rebuilds the Phones array on write', () {
      const contact = XeroContact(
        name: 'ACME',
        phone: '021 555 0100',
        mobile: '082 555 0199',
      );
      final phones = contact.toCreateJson()['Phones'] as List;
      expect(phones, hasLength(2));
      expect((phones.first as Map)['PhoneType'], 'DEFAULT');
      expect((phones.last as Map)['PhoneType'], 'MOBILE');
    });

    test('omits Phones entirely when there are none', () {
      const contact = XeroContact(name: 'ACME');
      expect(contact.toCreateJson().containsKey('Phones'), isFalse);
    });

    // The create-vs-update decision must key on this. A name-only contact is a
    // seed for a NEW contact, not an edit of an existing one.
    test('existsInXero keys on the id, not on the object existing', () {
      expect(
          const XeroContact(name: 'Seeded, Claremont').existsInXero, isFalse);
      expect(
        const XeroContact(contactId: 'c-1', name: 'Real').existsInXero,
        isTrue,
      );
    });

    test('update carries the ContactID so Xero amends rather than creates', () {
      const contact = XeroContact(contactId: 'c-1', name: 'ACME');
      expect(contact.toUpdateJson()['ContactID'], 'c-1');
      expect(contact.toCreateJson().containsKey('ContactID'), isFalse);
    });
  });

  group('online invoice availability', () {
    // Measured against the live API: DRAFT/AUTHORISED/PAID serve a link,
    // VOIDED/DELETED return HTTP 404. The detail screen hides the button
    // accordingly rather than surfacing "resource cannot be found".
    test('live statuses have an online invoice', () {
      expect(XeroInvoiceStatus.draft.hasOnlineInvoice, isTrue);
      expect(XeroInvoiceStatus.authorised.hasOnlineInvoice, isTrue);
      expect(XeroInvoiceStatus.paid.hasOnlineInvoice, isTrue);
    });

    test('annulled statuses do not', () {
      expect(XeroInvoiceStatus.voided.hasOnlineInvoice, isFalse);
      expect(XeroInvoiceStatus.deleted.hasOnlineInvoice, isFalse);
    });
  });

  group('XeroPage', () {
    test('derives hasMore from Xero\'s pagination block', () {
      final page = XeroPage.from(
        const {
          'Contacts': [
            {'ContactID': 'c-1', 'Name': 'One'},
          ],
          'pagination': {
            'page': 1,
            'pageSize': 100,
            'pageCount': 3,
            'itemCount': 250
          },
        },
        'Contacts',
        XeroContact.fromJson,
      );
      expect(page.items, hasLength(1));
      expect(page.hasMore, isTrue);
      expect(page.itemCount, 250);
    });

    test('a single unpaginated page has no more', () {
      final page = XeroPage.from(
        const {
          'Contacts': [
            {'ContactID': 'c-1', 'Name': 'One'},
          ],
        },
        'Contacts',
        XeroContact.fromJson,
      );
      expect(page.hasMore, isFalse);
      expect(page.itemCount, 1);
    });

    test('an empty response is an empty page, not a crash', () {
      final page = XeroPage.from(const {}, 'Contacts', XeroContact.fromJson);
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    // Xero omits the pagination block entirely on summaryOnly invoice reads —
    // verified live, the same request with and without summaryOnly returns
    // pageCount 16 and no block respectively. Trusting the block alone made
    // hasMore permanently false, so the invoice list silently showed page 1
    // and nothing else.
    group('when Xero omits the pagination block', () {
      Map<String, dynamic> rows(int n) => {
            'Invoices': List.generate(
                n,
                (i) => {
                      'InvoiceID': 'i-$i',
                      'Contact': {'ContactID': 'c'}
                    }),
          };

      test('a full page is assumed to have more', () {
        final page = XeroPage.from(rows(100), 'Invoices', XeroInvoice.fromJson,
            requestedPageSize: 100);
        expect(page.hasPagination, isFalse);
        expect(page.hasMore, isTrue);
      });

      test('a short page is the last one', () {
        final page = XeroPage.from(rows(37), 'Invoices', XeroInvoice.fromJson,
            requestedPageSize: 100);
        expect(page.hasMore, isFalse);
      });

      test('no requested page size means no guessing', () {
        final page = XeroPage.from(rows(100), 'Invoices', XeroInvoice.fromJson);
        expect(page.hasMore, isFalse);
      });
    });

    test('a real pagination block always wins over the heuristic', () {
      // A full page that Xero says is the last one must not offer "load more".
      final page = XeroPage.from(
        {
          'Invoices': List.generate(
              5,
              (i) => {
                    'InvoiceID': 'i-$i',
                    'Contact': {'ContactID': 'c'}
                  }),
          'pagination': {
            'page': 3,
            'pageSize': 5,
            'pageCount': 3,
            'itemCount': 15
          },
        },
        'Invoices',
        XeroInvoice.fromJson,
        requestedPageSize: 5,
      );
      expect(page.hasPagination, isTrue);
      expect(page.hasMore, isFalse);
    });
  });

  group('InvoiceMessageSubject.fromXero', () {
    XeroInvoice invoice({
      XeroInvoiceStatus status = XeroInvoiceStatus.authorised,
      double amountDue = 500,
      DateTime? dueDate,
    }) {
      return XeroInvoice(
        invoiceId: 'xi-1',
        invoiceNumber: 'INV-0042',
        contactId: 'xc-1',
        contactName: 'Blue Route Mall',
        status: status,
        date: DateTime(2026, 8, 1),
        dueDate: dueDate ?? DateTime(2026, 8, 15),
        total: 500,
        amountDue: amountDue,
      );
    }

    test('field names are translated, not just copied', () {
      final subject = InvoiceMessageSubject.fromXero(invoice());

      // contactName -> clientName and amountDue -> amountDue are the two
      // renames that would silently render an empty template line if missed.
      expect(subject.clientName, 'Blue Route Mall');
      expect(subject.invoiceNumber, 'INV-0042');
      expect(subject.total, 500);
      expect(subject.amountDue, 500);
      expect(subject.date, DateTime(2026, 8, 1));
      expect(subject.dueDate, DateTime(2026, 8, 15));
    });

    test('paid keys on the status alone, so a DRAFT is not read as settled',
        () {
      // A draft reports AmountDue 0. Reusing Zoho's "zero balance means paid"
      // rule here would file every draft under the paid templates.
      final draft = InvoiceMessageSubject.fromXero(
        invoice(status: XeroInvoiceStatus.draft, amountDue: 0),
      );
      expect(draft.isPaid, isFalse);
      expect(InvoiceMessageCategory.forInvoice(draft),
          InvoiceMessageCategory.unpaid);

      final paid = InvoiceMessageSubject.fromXero(
        invoice(status: XeroInvoiceStatus.paid, amountDue: 0),
      );
      expect(paid.isPaid, isTrue);
      expect(
          InvoiceMessageCategory.forInvoice(paid), InvoiceMessageCategory.paid);
    });

    test('overdue survives the flattening, though Xero has no such status', () {
      final overdue = InvoiceMessageSubject.fromXero(
        invoice(dueDate: DateTime(2020, 1, 1)),
      );
      expect(overdue.isOverdue, isTrue);
      expect(InvoiceMessageCategory.forInvoice(overdue),
          InvoiceMessageCategory.overdue);

      // Still owing but not yet due reads as unpaid, not overdue.
      final notYetDue = InvoiceMessageSubject.fromXero(
        invoice(dueDate: DateTime(2099, 1, 1)),
      );
      expect(notYetDue.isOverdue, isFalse);
      expect(InvoiceMessageCategory.forInvoice(notYetDue),
          InvoiceMessageCategory.unpaid);
    });

    test('the pay link is injected, because Xero does not carry one', () {
      // OnlineInvoiceUrl needs its own API call, so an un-fetched link must
      // render as empty rather than as the literal {pay_link} token.
      expect(InvoiceMessageSubject.fromXero(invoice()).payLink, '');

      final withLink = InvoiceMessageSubject.fromXero(
        invoice(),
        payLink: 'https://in.xero.com/abc123',
      );
      const template = InvoiceMessageTemplate(
        id: 't1',
        name: 'Pay please',
        body: 'Hi {client_name}, pay {invoice_number} here: {pay_link}',
      );
      expect(
        template.render(withLink),
        'Hi Blue Route Mall, pay INV-0042 here: https://in.xero.com/abc123',
      );
    });
  });

  group('XeroItem', () {
    test('sales price, account and tax come from the nested SalesDetails', () {
      // Xero does NOT put these on the item itself. Reading Code/Name from the
      // top level and expecting UnitPrice there too yields a priceless item.
      final item = XeroItem.fromJson({
        'ItemID': 'i-1',
        'Code': 'DIST-1000',
        'Name': 'Distribution per 1000',
        'Description': 'Flyer distribution, per 1000 units',
        'IsSold': true,
        'SalesDetails': {
          'UnitPrice': 450.0,
          'AccountCode': '200',
          'TaxType': 'OUTPUT3',
        },
      });

      expect(item.code, 'DIST-1000');
      expect(item.unitPrice, 450.0);
      expect(item.accountCode, '200');
      expect(item.taxType, 'OUTPUT3');
    });

    test('a purchase-only item degrades instead of throwing', () {
      // The proxy filters on IsSold==true, but a caller must not blow up if one
      // arrives — SalesDetails is simply absent.
      final item = XeroItem.fromJson({
        'Code': 'BUY-ONLY',
        'Name': 'Paper stock',
        'IsSold': false,
      });

      expect(item.unitPrice, 0);
      expect(item.accountCode, '');
      expect(item.taxType, '');
      expect(item.isSold, isFalse);
    });

    test('PurchaseDescription never reaches an invoice line', () {
      // Xero keeps a separate buying-side description. Putting it on a sales
      // invoice would show the customer an internal note.
      final item = XeroItem.fromJson({
        'Code': 'X',
        'Name': 'Service',
        'Description': 'What the customer sees',
        'PurchaseDescription': 'Internal buying note',
      });
      expect(item.lineDescription, 'What the customer sees');
      expect(item.description, isNot(contains('Internal')));
    });

    test('labels fall back so a picker never renders a blank row', () {
      final unnamed = XeroItem.fromJson({'Code': 'NO-NAME'});
      expect(unnamed.displayName, 'NO-NAME');
      expect(unnamed.lineDescription, 'NO-NAME');

      final named = XeroItem.fromJson({'Code': 'C1', 'Name': 'Thing'});
      expect(named.displayLabel, 'C1 — Thing');
    });
  });

  group('XeroLineTotals', () {
    // The excl/incl split shown while quoting. Indicative only — Xero rounds
    // per line and confirms on save — but wrong arithmetic here would have
    // someone quote a price they did not mean.

    test('exclusive adds VAT on top', () {
      final t = XeroLineTotals.forLine(
        amount: 1000,
        lineAmountType: XeroLineAmountType.exclusive,
        ratePercent: 15,
      );
      expect(t.exclVat, closeTo(1000, 0.001));
      expect(t.vat, closeTo(150, 0.001));
      expect(t.inclVat, closeTo(1150, 0.001));
    });

    test('inclusive divides VAT out, it does not multiply it', () {
      // The trap: 1150 * 0.15 = 172.50, which overstates VAT on every
      // inclusive invoice. The right answer is 1150 - 1150/1.15 = 150.
      final t = XeroLineTotals.forLine(
        amount: 1150,
        lineAmountType: XeroLineAmountType.inclusive,
        ratePercent: 15,
      );
      expect(t.inclVat, closeTo(1150, 0.001));
      expect(t.exclVat, closeTo(1000, 0.001));
      expect(t.vat, closeTo(150, 0.001));
      expect(t.vat, isNot(closeTo(172.5, 0.001)));
    });

    test('no-tax lines are the same figure both ways', () {
      final t = XeroLineTotals.forLine(
        amount: 500,
        lineAmountType: XeroLineAmountType.noTax,
        ratePercent: 15,
      );
      expect(t.exclVat, 500);
      expect(t.vat, 0);
      expect(t.inclVat, 500);
    });

    test('an unknown rate reports no VAT rather than assuming 15%', () {
      // Rates not loaded, or a code this organisation does not have. Guessing
      // would put a fabricated figure on an accounting screen.
      final t = XeroLineTotals.forLine(
        amount: 1000,
        lineAmountType: XeroLineAmountType.exclusive,
        ratePercent: null,
      );
      expect(t.vat, 0);
      expect(t.exclVat, 1000);
      expect(t.inclVat, 1000);
    });

    test('invoice totals resolve each line\'s own tax type', () {
      // A catalogue item can override the company default, so the rate is
      // looked up per line rather than applied once to the total.
      final lines = [
        const XeroLineItem(
            description: 'Standard', quantity: 2, unitAmount: 500),
        const XeroLineItem(
            description: 'Zero rated',
            quantity: 1,
            unitAmount: 300,
            taxType: 'ZERO'),
      ];

      final totals = XeroLineTotals.of(
        lines,
        lineAmountType: XeroLineAmountType.exclusive,
        defaultTaxType: 'OUTPUT3',
        rateFor: (t) => switch (t) {
          'OUTPUT3' => 15.0,
          'ZERO' => 0.0,
          _ => null,
        },
      );

      expect(totals.exclVat, closeTo(1300, 0.001));
      // Only the 1000 attracts VAT; the zero-rated 300 does not.
      expect(totals.vat, closeTo(150, 0.001));
      expect(totals.inclVat, closeTo(1450, 0.001));
    });

    test('quantity is part of the line amount', () {
      final totals = XeroLineTotals.of(
        [const XeroLineItem(description: 'x', quantity: 3, unitAmount: 100)],
        lineAmountType: XeroLineAmountType.exclusive,
        defaultTaxType: 'OUTPUT3',
        rateFor: (_) => 15.0,
      );
      expect(totals.exclVat, closeTo(300, 0.001));
      expect(totals.inclVat, closeTo(345, 0.001));
    });
  });

  group('XeroLineItem.lineFigures', () {
    // jobQuantity is the unit the business SELLS by — man-days for CLM, not
    // the flyer count. A job's Amount is a TOTAL; a catalogue item's price is a
    // RATE PER UNIT. Xero multiplies quantity by unit amount, so carrying units
    // onto a line priced with a total would invoice a fortune. These pin that.

    test('a catalogue rate is multiplied by the job units', () {
      // 5 man-days at R685 a day.
      final f = XeroLineItem.lineFigures(
        jobQuantity: 5,
        jobAmount: 0,
        itemUnitPrice: 685,
      );
      expect(f.quantity, 5);
      expect(f.unitAmount, 685);
      expect(f.quantity * f.unitAmount, closeTo(3425, 0.001));
    });

    test('fractional man-days survive', () {
      // Half a day is a real booking, so this must not be rounded to an int.
      final f = XeroLineItem.lineFigures(
        jobQuantity: 1.5,
        jobAmount: 0,
        itemUnitPrice: 685,
      );
      expect(f.quantity, 1.5);
      expect(f.quantity * f.unitAmount, closeTo(1027.5, 0.001));
    });

    test('a job total is NEVER multiplied by the job units', () {
      // The bug this exists to prevent: 5 × 3425 = R17,125 for a R3,425 job.
      final f = XeroLineItem.lineFigures(
        jobQuantity: 5,
        jobAmount: 3425,
        itemUnitPrice: 0,
      );
      expect(f.quantity, 1, reason: 'the amount is a total, not a rate');
      expect(f.unitAmount, 3425);
      expect(f.quantity * f.unitAmount, 3425);
    });

    test('the catalogue rate wins over a job total', () {
      // With a rate available the quantity is meaningful, so it is used — and
      // the total is left out rather than being multiplied.
      final f = XeroLineItem.lineFigures(
        jobQuantity: 3,
        jobAmount: 999,
        itemUnitPrice: 685,
      );
      expect(f.quantity, 3);
      expect(f.unitAmount, 685);
    });

    test('no quantity on the job falls back to one', () {
      final f = XeroLineItem.lineFigures(
        jobQuantity: 0,
        jobAmount: 0,
        itemUnitPrice: 685,
      );
      expect(f.quantity, 1);
      expect(f.unitAmount, 685);
    });

    test('nothing priced yet still carries the units', () {
      // Neither a rate nor a total: the line is priced by hand afterwards, and
      // the man-days are still worth having.
      final f = XeroLineItem.lineFigures(
        jobQuantity: 2.5,
        jobAmount: 0,
        itemUnitPrice: 0,
      );
      expect(f.quantity, 2.5);
      expect(f.unitAmount, 0);
    });
  });
}
