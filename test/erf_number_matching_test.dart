import 'package:clmschedule/erf_property/services/csg_property_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('erfNumberVariants', () {
    test('looks for the remainder spelling as well as the plain number', () {
      // 13.6% of sampled Cape Town parcels carry a "RE/" prefix, so a pasted
      // bare number must search both.
      expect(CsgPropertyService.erfNumberVariants('4673'), {'4673', 'RE/4673'});
    });

    test('leaves a number already written as a remainder alone', () {
      expect(CsgPropertyService.erfNumberVariants('RE/4673'), {'RE/4673'});
      expect(CsgPropertyService.erfNumberVariants('re/4673'), {'RE/4673'});
    });

    test('keeps portion notation intact', () {
      expect(CsgPropertyService.erfNumberVariants('1234/2'),
          {'1234/2', 'RE/1234/2'});
    });

    test('ignores blank input', () {
      expect(CsgPropertyService.erfNumberVariants('   '), isEmpty);
    });
  });

  group('normaliseErfNumber', () {
    test('gives a remainder and its plain number the same key', () {
      expect(CsgPropertyService.normaliseErfNumber('RE/4673'),
          CsgPropertyService.normaliseErfNumber('4673'));
    });

    test('is case- and whitespace-insensitive', () {
      expect(CsgPropertyService.normaliseErfNumber(' re/957 '), '957');
    });

    test('leaves portions distinguishable from their parent erf', () {
      expect(CsgPropertyService.normaliseErfNumber('1234/2'), '1234/2');
      expect(CsgPropertyService.normaliseErfNumber('1234'), '1234');
      expect(CsgPropertyService.normaliseErfNumber('1234/2'),
          isNot(CsgPropertyService.normaliseErfNumber('1234')));
    });
  });
}
