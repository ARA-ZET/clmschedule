import 'package:flutter_test/flutter_test.dart';
import 'package:clmschedule/erf_property/services/erf_list_parser.dart';

void main() {
  group('ErfListParser', () {
    test('reads an address-only line', () {
      final entries = ErfListParser.parse('12 Main Road, Kensington');
      expect(entries, hasLength(1));
      expect(entries.first.address, '12 Main Road, Kensington');
      expect(entries.first.erfNumber, isNull);
    });

    test('reads a bare ERF number', () {
      final entries = ErfListParser.parse('1234');
      expect(entries.first.erfNumber, '1234');
      expect(entries.first.address, isNull);
    });

    test('reads an explicit ERF keyword anywhere on the line', () {
      final entries = ErfListParser.parse(
          '12 Main Road, Kensington - ERF 1234/2\nerf no. 987');
      expect(entries[0].erfNumber, '1234/2');
      expect(entries[0].address, '12 Main Road, Kensington');
      expect(entries[1].erfNumber, '987');
      expect(entries[1].address, isNull);
    });

    test('takes the trailing numeric column as the ERF', () {
      final entries = ErfListParser.parse('8 Fifth Avenue, Kensington, 5678');
      expect(entries.first.erfNumber, '5678');
      expect(entries.first.address, '8 Fifth Avenue, Kensington');
    });

    test('handles tab-separated spreadsheet rows', () {
      final entries = ErfListParser.parse('1234\t12 Main Road');
      expect(entries.first.erfNumber, '1234');
      expect(entries.first.address, '12 Main Road');
    });

    test('drops a header row', () {
      final entries = ErfListParser.parse('Address, ERF\n12 Main Rd, 99');
      expect(entries, hasLength(1));
      expect(entries.first.erfNumber, '99');
    });

    test('strips bullets and list numbering', () {
      final entries =
          ErfListParser.parse('- 12 Main Road\n2. 44 Oak Ave\n3. 771');
      expect(entries[0].address, '12 Main Road');
      expect(entries[1].address, '44 Oak Ave');
      expect(entries[2].erfNumber, '771');
    });

    test('keeps a street number that opens an address', () {
      final entries = ErfListParser.parse('12 Main Road');
      expect(entries.first.address, '12 Main Road');
      expect(entries.first.erfNumber, isNull);
    });

    test('normalises spaces around a portion slash', () {
      final entries = ErfListParser.parse('ERF 1234 / 2');
      expect(entries.first.erfNumber, '1234/2');
    });

    test('skips blank lines and flags unusable ones', () {
      final entries = ErfListParser.parse('12 Main Rd\n\n   \n***');
      expect(entries, hasLength(2));
      expect(entries[1].isUsable, isFalse);
    });

    test('numbers lines in paste order', () {
      final entries = ErfListParser.parse('a street\nb street');
      expect(entries.map((e) => e.lineNumber), [1, 2]);
    });
  });
}
