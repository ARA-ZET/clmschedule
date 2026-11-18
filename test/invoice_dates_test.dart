import 'package:clmschedule/utils/invoice_dates.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String text) => datesInInvoiceText(text)
    .map((d) => '${d.year ?? '?'}-${d.month}-${d.day ?? '?'}')
    .join(', ');

void main() {
  group('datesInInvoiceText', () {
    test('day, month name and year in the usual spellings', () {
      expect(_read('Leaflets delivered 20 October 2026'), '2026-10-20');
      expect(_read('Distribution on 20th Oct 2026'), '2026-10-20');
      expect(_read('Delivered 3 Sept, 2026'), '2026-9-3');
      expect(_read('on the 20th of October'), '?-10-20');
      expect(_read('October 20, 2026'), '2026-10-20');
    });

    test('several days before one month', () {
      expect(_read('20 - 22 October 2026'), '2026-10-20, 2026-10-22');
      expect(_read('20, 21 and 22 Oct'), '?-10-20, ?-10-21, ?-10-22');
      expect(_read('20 & 21 November 2026'), '2026-11-20, 2026-11-21');
    });

    test('numbers, day first, and ISO', () {
      expect(_read('Date: 20/10/2026'), '2026-10-20');
      expect(_read('Date: 5-11-26'), '2026-11-5');
      expect(_read('Date: 2026-10-20'), '2026-10-20');
    });

    test('a month on its own', () {
      expect(_read('Flyer drop — October 2026'), '2026-10-?');
    });

    test('a full date is not also read as its month', () {
      expect(datesInInvoiceText('20 October 2026'), hasLength(1));
    });

    test('ID numbers, amounts and plain words are not dates', () {
      expect(
          _read('Personnel:\nPetros Mokoena — ID/Passport: 8001015009087\n'
              '5 000 leaflets at R0.45 — Claremont, Kenilworth'),
          '');
      expect(_read('Posters may be removed after 14 days'), '');
    });
  });

  group('invoiceDatesOutside', () {
    final work = [DateTime(2026, 10, 20), DateTime(2026, 10, 22)];

    test('a date from the work, or between its days, is fine', () {
      expect(invoiceDatesOutside('Delivered 20 October 2026', work), isEmpty);
      expect(invoiceDatesOutside('Delivered 21 Oct', work), isEmpty);
      expect(invoiceDatesOutside('October 2026', work), isEmpty);
    });

    test('a date left over from an earlier invoice is caught', () {
      final out =
          invoiceDatesOutside('Leaflets delivered 15 September 2026', work);
      expect(out.map((d) => d.text), ['15 September 2026']);
      expect(invoiceDatesOutside('September 2026', work), hasLength(1));
      expect(invoiceDatesOutside('Delivered 20 October 2025', work),
          hasLength(1));
    });

    test('no work dates, nothing to compare', () {
      expect(invoiceDatesOutside('15 September 2026', const []), isEmpty);
    });
  });
}
