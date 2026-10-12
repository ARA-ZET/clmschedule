import 'package:clmschedule/erf_property/models/erf_search_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErfSearchScope', () {
    test('Cape Town filters on the cadastral major region', () {
      const scope = ErfSearchScope.capeTown;

      // Constantia, Langa and the CBD all share MAJ_CODE C0160000.
      expect(
          scope.allows(majCode: 'C0160000', province: 'WESTERN CAPE'), isTrue);
      // A Gauteng parcel, which is what an unscoped "ERF 1234" returns.
      expect(scope.allows(majCode: 'T0IR0000', province: 'GAUTENG'), isFalse);
      // Western Cape but outside the Cape Town region.
      expect(
          scope.allows(majCode: 'C0230000', province: 'WESTERN CAPE'), isFalse);
      expect(scope.majCode, 'C0160000');
      expect(scope.province, isNull);
    });

    test('Western Cape filters on province instead', () {
      const scope = ErfSearchScope.westernCape;

      expect(
          scope.allows(majCode: 'C0230000', province: 'WESTERN CAPE'), isTrue);
      expect(scope.allows(majCode: 'T0IR0000', province: 'GAUTENG'), isFalse);
      expect(scope.province, 'WESTERN CAPE');
      expect(scope.majCode, isNull);
    });

    test('province matching ignores case', () {
      expect(
        ErfSearchScope.westernCape
            .allows(majCode: 'x', province: 'Western Cape'),
        isTrue,
      );
    });

    test('South Africa allows everything and applies no filter', () {
      const scope = ErfSearchScope.southAfrica;

      expect(scope.allows(majCode: 'anything', province: 'LIMPOPO'), isTrue);
      expect(scope.majCode, isNull);
      expect(scope.province, isNull);
      expect(scope.isRestricted, isFalse);
    });

    test('restricted scopes are flagged so the UI can offer to widen', () {
      expect(ErfSearchScope.capeTown.isRestricted, isTrue);
      expect(ErfSearchScope.westernCape.isRestricted, isTrue);
    });

    test('every scope has a label and description', () {
      for (final scope in ErfSearchScope.values) {
        expect(scope.label, isNotEmpty);
        expect(scope.description, isNotEmpty);
      }
    });
  });
}
