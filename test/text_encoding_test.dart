import 'dart:convert';

import 'package:clmschedule/utils/text_encoding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads UTF-8 files as UTF-8', () {
    expect(decodeTextBytes(utf8.encode('Tracklog – Full')), 'Tracklog – Full');
  });

  test('drops a BOM', () {
    expect(decodeTextBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('a–b')]), 'a–b');
  });

  test('falls back to Latin-1 for non-UTF-8 bytes', () {
    expect(decodeTextBytes(latin1.encode('café')), 'café');
  });

  test('repairs the escaped en dash saved by the Track Editor', () {
    expect(repairMojibake('Tracklog â&#x80;&#x93; Full Track (5)'),
        'Tracklog – Full Track (5)');
    expect(decodeTextBytes(utf8.encode('<name>a â&#x80;&#x93; b</name>')),
        '<name>a – b</name>');
  });

  test('repairs raw mis-decoded text', () {
    expect(repairMojibake('cafÃ© â\u0080\u0093'), 'café –');
  });

  test('leaves ordinary text alone', () {
    for (final s in ['café', 'Tracklog – Full', 'Ã alone', '&#x80; only']) {
      expect(repairMojibake(s), s);
    }
  });
}
