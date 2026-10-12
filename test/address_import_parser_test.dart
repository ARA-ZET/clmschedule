import 'package:flutter_test/flutter_test.dart';
import 'package:clmschedule/services/address_import_parser.dart';

void main() {
  const parser = AddressImportParser(defaultSuburb: 'pinelands');

  group('single-line pastes', () {
    test('keeps a whole address in the street field', () {
      final result = parser.parse('30 Riverside Road, Pinelands, Cape Town');

      expect(result.modeUsed, AddressParseMode.singleLine);
      expect(result.addresses, hasLength(1));
      expect(
        result.addresses.first.streetAddress,
        '30 Riverside Road, Pinelands, Cape Town',
      );
      expect(result.addresses.first.suburb, 'pinelands');
    });

    test('lifts a trailing postal code and country out', () {
      final result = parser.parse(
        '19 Morningside Street, Pinelands, Cape Town, 7405, South Africa',
      );

      final address = result.addresses.single;
      expect(result.modeUsed, AddressParseMode.singleLine);
      expect(address.postalCode, '7405');
      expect(address.country, 'South Africa');
      expect(address.streetAddress, isNot(contains('7405')));
      expect(address.streetAddress, isNot(contains('South Africa')));
    });

    test('strips list numbering and bullets', () {
      final result = parser.parse('''
1. 30 Riverside Road
2) 12 Central Square
- 8 Forest Drive
• 4 Oak Avenue
''');

      expect(
        result.addresses.map((a) => a.streetAddress),
        [
          '30 Riverside Road',
          '12 Central Square',
          '8 Forest Drive',
          '4 Oak Avenue'
        ],
      );
    });
  });

  group('column pastes', () {
    test('reads tab-separated columns positionally', () {
      final result = parser.parse(
        '30 Riverside Road\tPinelands\tCape Town\t7405\n'
        '12 Central Square\tPinelands\tCape Town\t7405',
      );

      expect(result.modeUsed, AddressParseMode.columns);
      expect(result.addresses, hasLength(2));
      expect(result.addresses.first.city, 'Cape Town');
      expect(result.addresses.first.postalCode, '7405');
    });

    test('maps columns by name when a header row is present', () {
      final result = parser.parse(
        'Postal Code,Street Address,Suburb\n'
        '7405,30 Riverside Road,Pinelands',
      );

      expect(result.headerDetected, isTrue);
      final address = result.addresses.single;
      expect(address.streetAddress, '30 Riverside Road');
      expect(address.postalCode, '7405');
      expect(address.suburb, 'Pinelands');
    });

    test('respects quoted commas inside a cell', () {
      final result = parser.parse(
        'Street Address,Suburb,Notes\n'
        '"Unit 4, Culemborg",Pinelands,"Ring bell, then wait"',
      );

      final address = result.addresses.single;
      expect(address.streetAddress, 'Unit 4, Culemborg');
      expect(address.notes, 'Ring bell, then wait');
    });
  });

  group('cleanup', () {
    test('drops repeated addresses and reports them', () {
      final result = parser.parse('''
30 Riverside Road
30 riverside road
12 Central Square
''');

      expect(result.addresses, hasLength(2));
      expect(result.duplicates, hasLength(1));
    });

    test('keeps duplicates when asked to', () {
      final result = parser.parse(
        '30 Riverside Road\n30 Riverside Road',
        dropDuplicates: false,
      );

      expect(result.addresses, hasLength(2));
      expect(result.duplicates, isEmpty);
    });

    test('ignores blank lines rather than importing empty rows', () {
      final result = parser.parse('\n\n30 Riverside Road\n\n   \n');
      expect(result.addresses, hasLength(1));
    });
  });

  test('forcing single-line mode overrides delimiter detection', () {
    final result = parser.parse(
      '30 Riverside Road, Pinelands, Cape Town\n'
      '12 Central Square, Pinelands, Cape Town',
      mode: AddressParseMode.singleLine,
    );

    expect(result.modeUsed, AddressParseMode.singleLine);
    expect(
      result.addresses.first.streetAddress,
      '30 Riverside Road, Pinelands, Cape Town',
    );
  });

  group('ragged column widths', () {
    test('recognises postal code, province and country by shape', () {
      final result = parser.parse(
        '30 Riverside Road,Pinelands,Cape Town,7405,Western Cape,South Africa\n'
        '12 Central Square,Pinelands,Cape Town,7405,Western Cape,South Africa',
      );

      expect(result.modeUsed, AddressParseMode.columns);
      final address = result.addresses.first;
      expect(address.streetAddress, '30 Riverside Road');
      expect(address.suburb, 'Pinelands');
      expect(address.city, 'Cape Town');
      expect(address.postalCode, '7405');
      expect(address.province, 'Western Cape');
      expect(address.country, 'South Africa');
    });

    test('a missing country does not shift every later field along', () {
      // Five cells, not six: the old fixed-position reading put
      // "South Africa" into the province column here.
      final result = parser.parse(
        '30 Riverside Road,Pinelands,Cape Town,7405,South Africa\n'
        '12 Central Square,Pinelands,Cape Town,7405,South Africa',
      );

      final address = result.addresses.first;
      expect(address.postalCode, '7405');
      expect(address.country, 'South Africa');
      expect(address.province, 'Western Cape'); // the configured default
      expect(address.city, 'Cape Town');
    });

    test('a postal code out of its usual column is still found', () {
      final result = parser.parse(
        '30 Riverside Road\t7405\tPinelands\tCape Town',
      );

      final address = result.addresses.single;
      expect(address.postalCode, '7405');
      expect(address.streetAddress, '30 Riverside Road');
      expect(address.suburb, 'Pinelands');
      expect(address.city, 'Cape Town');
    });
  });
}
