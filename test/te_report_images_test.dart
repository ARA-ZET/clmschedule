// Proof photos are scaled to what print needs and re-encoded as JPEG, so a
// report full of phone photos stays a sensible size.
import 'dart:typed_data';

import 'package:clmschedule/track_editor/services/te_report_images.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a big PNG comes back as a small JPEG no wider than print needs',
      () async {
    // A 2400×1600 picture of smooth shading with grain, like a photo.
    final src = im.Image(width: 2400, height: 1600);
    var seed = 1;
    for (final p in src) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final grain = seed % 9;
      p
        ..r = (p.x / 2400 * 200 + grain).round()
        ..g = (p.y / 1600 * 180 + grain).round()
        ..b = (120 + grain).round();
    }
    final png = Uint8List.fromList(im.encodePng(src));

    final out = await teCompressPhoto(png);
    expect(out[0], 0xFF);
    expect(out[1], 0xD8, reason: 'a JPEG');
    final back = im.decodeJpg(out)!;
    expect(back.width, tePhotoMaxSide);
    expect(back.height, (tePhotoMaxSide * 1600 / 2400).round());
    expect(out.length, lessThan(png.length ~/ 4));

    // Asked again, the same bytes come back without redoing the work.
    expect(identical(await teCompressPhoto(png), out), isTrue);
  });

  test('something that is not an image is kept as it is', () async {
    final junk = Uint8List.fromList(List.filled(64, 7));
    expect(identical(await teCompressPhoto(junk), junk), isTrue);
  });
}
