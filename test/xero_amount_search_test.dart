import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/xero_invoice.dart';
import 'package:clmschedule/services/xero_amount_search.dart';

/// Guards finding an invoice from an unreferenced payment. A wrong match here
/// means a payment allocated to the wrong client.
void main() {
  group('parseCents', () {
    test('reads the ways amounts get typed or pasted', () {
      expect(XeroAmountSearch.parseCents('1250'), 125000);
      expect(XeroAmountSearch.parseCents('1250.5'), 125050);
      expect(XeroAmountSearch.parseCents('R 1 250,50'), 125050);
      expect(XeroAmountSearch.parseCents('r1,250.00'), 125000);
      expect(XeroAmountSearch.parseCents('1,250'), 125000);
      expect(XeroAmountSearch.parseCents('12 345.67'), 1234567);
    });

    test('is not fooled by names and invoice numbers', () {
      expect(XeroAmountSearch.parseCents('INV-9431'), isNull);
      expect(XeroAmountSearch.parseCents('Spar'), isNull);
      expect(XeroAmountSearch.parseCents('1st Choice'), isNull);
      expect(XeroAmountSearch.parseCents(''), isNull);
      expect(XeroAmountSearch.parseCents('0'), isNull);
    });
  });

  test('whereClause uses decimal literals', () {
    expect(XeroAmountSearch.whereClause(125050),
        '(Total == 1250.50 OR AmountDue == 1250.50 OR AmountPaid == 1250.50)');
  });

  group('match', () {
    // Two lines, VAT exclusive: 1000 + 150 VAT, 500 + 75 VAT = 1725 total.
    const twoLines = XeroInvoice(
      contactId: 'c',
      total: 1725,
      amountDue: 1725,
      lineItems: [
        XeroLineItem(
            description: 'Flyer drop', unitAmount: 1000,
            lineAmount: 1000, taxAmount: 150),
        XeroLineItem(
            description: 'Printing', unitAmount: 500,
            lineAmount: 500, taxAmount: 75),
      ],
    );

    test('a client paying one line finds that line, VAT included', () {
      final m = XeroAmountSearch.match(twoLines, 57500);
      expect(m?.label, 'Line 2 · Printing');
    });

    test('whole-invoice figures win over lines', () {
      expect(XeroAmountSearch.match(twoLines, 172500)?.label, 'Invoice total');
    });

    test('amount still due after a part payment', () {
      const partPaid = XeroInvoice(
          contactId: 'c', total: 1725, amountDue: 575, amountPaid: 1150);
      expect(XeroAmountSearch.match(partPaid, 57500)?.label, 'Amount due');
      expect(XeroAmountSearch.match(partPaid, 115000)?.label, 'Already paid');
    });

    test('combinations of lines', () {
      const three = XeroInvoice(
        contactId: 'c',
        lineAmountTypes: XeroLineAmountType.noTax,
        total: 600,
        lineItems: [
          XeroLineItem(description: 'A', unitAmount: 100, lineAmount: 100),
          XeroLineItem(description: 'B', unitAmount: 200, lineAmount: 200),
          XeroLineItem(description: 'C', unitAmount: 300, lineAmount: 300),
        ],
      );
      // 400 is only lines 1 + 3.
      expect(XeroAmountSearch.match(three, 40000)?.label, 'Lines 1 + 3');
      // 300 is line 3 alone *and* lines 1 + 2 — the single line wins.
      expect(XeroAmountSearch.match(three, 30000)?.label, 'Line 3 · C');
    });

    test('excl. VAT figures match, labelled as such', () {
      expect(XeroAmountSearch.match(twoLines, 100000)?.label,
          'Line 1 excl. VAT · Flyer drop');
      expect(XeroAmountSearch.match(twoLines, 150000)?.label,
          'Subtotal excl. VAT');
    });

    test('inclusive lines already carry their VAT', () {
      const incl = XeroInvoice(
        contactId: 'c',
        lineAmountTypes: XeroLineAmountType.inclusive,
        total: 1725,
        lineItems: [
          XeroLineItem(
              description: 'X', unitAmount: 1150,
              lineAmount: 1150, taxAmount: 150),
          XeroLineItem(
              description: 'Y', unitAmount: 575,
              lineAmount: 575, taxAmount: 75),
        ],
      );
      expect(XeroAmountSearch.match(incl, 115000)?.label, 'Line 1 · X');
      expect(XeroAmountSearch.match(incl, 50000)?.label,
          'Line 2 excl. VAT · Y');
    });

    test('a cent of rounding is tolerated, two cents is not', () {
      expect(XeroAmountSearch.match(twoLines, 57501), isNotNull);
      expect(XeroAmountSearch.match(twoLines, 57502), isNull);
    });

    test('no match', () {
      expect(XeroAmountSearch.match(twoLines, 99900), isNull);
    });

    test('a combination explains its sum line by line', () {
      const three = XeroInvoice(
        contactId: 'c',
        lineAmountTypes: XeroLineAmountType.noTax,
        total: 600,
        amountDue: 600,
        lineItems: [
          XeroLineItem(description: 'A', unitAmount: 100, lineAmount: 100),
          XeroLineItem(description: 'B', unitAmount: 200, lineAmount: 200),
          XeroLineItem(description: 'C', unitAmount: 300, lineAmount: 300),
        ],
      );
      final detail = XeroAmountSearch.match(three, 40000)!.detail;
      expect(detail, contains('Line 1 · A: R 100.00'));
      expect(detail, contains('Line 3 · C: R 300.00'));
      expect(detail, contains('= R 400.00 incl. VAT'));
    });

    test('long invoices still match singles and pairs', () {
      final long = XeroInvoice(
        contactId: 'c',
        lineAmountTypes: XeroLineAmountType.noTax,
        lineItems: [
          for (var i = 1; i <= 40; i++)
            XeroLineItem(
                description: 'L$i', unitAmount: i * 1000.0,
                lineAmount: i * 1000.0),
        ],
      );
      expect(XeroAmountSearch.match(long, 3500000)?.label, 'Line 35 · L35');
      expect(XeroAmountSearch.match(long, 7900000)?.label, 'Lines 39 + 40');
    });
  });

  group('nearMisses', () {
    XeroInvoice inv(String id, double total) => XeroInvoice(
          invoiceId: id,
          contactId: 'c',
          total: total,
          amountDue: total,
        );

    test('closest first, signed, and only when close', () {
      final misses = XeroAmountSearch.nearMisses(
        [inv('far', 3000), inv('near', 1671), inv('nearer', 1670.50)],
        167070,
      );
      expect(misses.map((m) => m.invoice.invoiceId), ['nearer', 'near']);
      expect(misses.first.diffCents, -20);
      expect(misses.last.diffCents, 30);
    });

    test('a line can be the closest figure', () {
      const invoice = XeroInvoice(
        invoiceId: 'x',
        contactId: 'c',
        lineAmountTypes: XeroLineAmountType.noTax,
        total: 5000,
        amountDue: 5000,
        lineItems: [
          XeroLineItem(description: 'Drop', unitAmount: 1675, lineAmount: 1675),
          XeroLineItem(description: 'Print', unitAmount: 3325, lineAmount: 3325),
        ],
      );
      final m = XeroAmountSearch.nearMisses([invoice], 167070).single;
      expect(m.label, 'Line 1 · Drop');
      expect(m.diffCents, 430);
    });
  });
}
