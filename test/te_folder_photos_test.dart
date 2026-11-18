// Dating the traffic-light photos found in a job folder, so each lands under
// the day it was taken in the Flyer Handout Report.
import 'dart:typed_data';

import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/services/te_folder_photos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;

TEProofPhoto _photo(String name, [DateTime? takenAt]) => TEProofPhoto(
      bytes: Uint8List(0),
      fileName: name,
      storagePath: 'Distribution/2026/Oct 2026/Pick n Pay/$name',
      takenAt: takenAt,
    );

void main() {
  group('date from the file name', () {
    test('clmgpx photo names', () {
      expect(tePhotoTimeFromName('Petros_Traffic light 3_2026-10-22_12-37-26.jpg'),
          DateTime(2026, 10, 22, 12, 37, 26));
      expect(tePhotoTimeFromName('Petros_2026-10-22.jpg'), DateTime(2026, 10, 22));
    });

    test('phone camera names', () {
      expect(tePhotoTimeFromName('IMG_20261022_093015.jpg'),
          DateTime(2026, 10, 22, 9, 30, 15));
      expect(tePhotoTimeFromName('PXL_20261022_093015123.jpg'),
          DateTime(2026, 10, 22, 9, 30, 15));
      expect(tePhotoTimeFromName('IMG-20261022-WA0004.jpg'),
          DateTime(2026, 10, 22));
      expect(tePhotoTimeFromName('Screenshot_20261022-093015.png'),
          DateTime(2026, 10, 22, 9, 30, 15));
    });

    test('no date, or not a real one', () {
      expect(tePhotoTimeFromName('IMG_4411.jpg'), isNull);
      expect(tePhotoTimeFromName('proof_1792345678901_0.jpg'), isNull);
      expect(tePhotoTimeFromName('photo_2026-02-31.jpg'), isNull);
    });
  });

  test('date from the camera when the name has none', () {
    final image = im.Image(width: 8, height: 8);
    image.exif.exifIfd['DateTimeOriginal'] = '2026:10:23 07:45:10';
    final jpeg = im.encodeJpg(image);
    expect(tePhotoTimeFromExif(jpeg), DateTime(2026, 10, 23, 7, 45, 10));
    expect(tePhotoTakenAt('IMG_4411.jpg', jpeg),
        DateTime(2026, 10, 23, 7, 45, 10));
    // The name wins over the camera.
    expect(tePhotoTakenAt('IMG_20261022_093015.jpg', jpeg),
        DateTime(2026, 10, 22, 9, 30, 15));
    expect(tePhotoTimeFromExif(im.encodeJpg(im.Image(width: 8, height: 8))),
        isNull);
    expect(tePhotoTimeFromExif(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });

  group('sorting onto the report days', () {
    final d22 = DateTime(2026, 10, 22), d23 = DateTime(2026, 10, 23);

    test('each photo goes on the day it was taken, oldest first', () {
      final sorted = sortFolderPhotos([
        _photo('b', DateTime(2026, 10, 22, 14)),
        _photo('a', DateTime(2026, 10, 22, 9)),
        _photo('c', DateTime(2026, 10, 23, 8)),
      ], {d22, d23});
      expect(sorted.byDate[d22]!.map((p) => p.fileName), ['a', 'b']);
      expect(sorted.byDate[d23]!.map((p) => p.fileName), ['c']);
      expect(sorted.undated, isEmpty);
    });

    test('an undated photo goes on the only day of a one-day report', () {
      final sorted = sortFolderPhotos([_photo('x')], {d22});
      expect(sorted.byDate[d22]!.single.fileName, 'x');
    });

    test('undated with several days, or taken on another day, waits to be '
        'assigned', () {
      final sorted = sortFolderPhotos([
        _photo('x'),
        _photo('y', DateTime(2026, 10, 25, 10)),
      ], {d22, d23});
      expect(sorted.byDate, isEmpty);
      expect(sorted.undated.map((p) => p.fileName), ['y', 'x']);
    });
  });
}
