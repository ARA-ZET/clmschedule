// track_editor/services/te_folder_photos.dart
//
// The traffic-light photos dropped into a job's folder beside the tracks,
// loaded for the Flyer Handout Report. Each is put under the date it was
// taken — from its file name (clmgpx's `Name_What_yyyy-MM-dd_HH-mm-ss.jpg`,
// a phone camera's `IMG_20261022_123456.jpg`), else the camera's own EXIF
// date, else the report's only date when it has just one. A photo that
// can't be placed is handed back as undated for the user to assign.
//
// Photos are scaled down as they load (te_report_images.dart), after the
// date is read — the scaled JPEG has no EXIF left — so a folder of phone
// originals isn't held in memory at full size.
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as im;

import '../models/te_promoter_day.dart';
import 'te_report_images.dart';

/// Phone originals run past Storage's 10 MB default download cap.
const int _maxPhotoBytes = 40 * 1024 * 1024;

/// What [loadFolderPhotos] found.
class TEFolderPhotos {
  /// Photos under their date (midnight), oldest first within each.
  final Map<DateTime, List<TEProofPhoto>> byDate;

  /// Photos with no date, or dated on a day nobody in the report worked.
  final List<TEProofPhoto> undated;

  /// Photos that failed to download.
  final List<String> failed;

  const TEFolderPhotos({
    this.byDate = const {},
    this.undated = const [],
    this.failed = const [],
  });

  static const empty = TEFolderPhotos();
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime? _civil(String y, String mo, String d,
    [String h = '0', String mi = '0', String s = '0']) {
  final year = int.parse(y), month = int.parse(mo), day = int.parse(d);
  final hour = int.parse(h), minute = int.parse(mi), second = int.parse(s);
  if (year < 2000 || month < 1 || month > 12 || day < 1 || day > 31) {
    return null;
  }
  if (hour > 23 || minute > 59 || second > 59) return null;
  final out = DateTime(year, month, day, hour, minute, second);
  // DateTime rolls 31 Feb over into March; that is not a real date.
  return out.month == month && out.day == day ? out : null;
}

/// clmgpx: `…_2026-10-22_12-37-26.jpg`, or just the date.
final _dashed = RegExp(
    r'(\d{4})-(\d{2})-(\d{2})(?:[_ T](\d{2})[-.:](\d{2})[-.:](\d{2}))?');

/// Phone cameras: `IMG_20261022_123456`, `PXL_20261022_123456789`,
/// `20261022_123456`, `Screenshot_20261022-123456`, WhatsApp's
/// `IMG-20261022-WA0001`.
final _compact =
    RegExp(r'(?<!\d)(20\d{2})(\d{2})(\d{2})(?:[_-](\d{2})(\d{2})(\d{2}))?');

/// When a photo was taken, from its file name alone.
DateTime? tePhotoTimeFromName(String fileName) {
  for (final re in [_dashed, _compact]) {
    final m = re.firstMatch(fileName);
    if (m == null) continue;
    final at = m.group(4) == null
        ? _civil(m.group(1)!, m.group(2)!, m.group(3)!)
        : _civil(m.group(1)!, m.group(2)!, m.group(3)!, m.group(4)!,
            m.group(5)!, m.group(6)!);
    if (at != null) return at;
  }
  return null;
}

/// When a JPEG was taken, by the camera's clock (`2026:10:22 12:37:26`).
DateTime? tePhotoTimeFromExif(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  try {
    final exif = im.decodeJpgExif(bytes);
    if (exif == null) return null;
    final text = (exif.exifIfd['DateTimeOriginal'] ??
            exif.imageIfd['DateTime'])
        ?.toString()
        .trim();
    if (text == null) return null;
    final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
        .firstMatch(text);
    if (m == null) return null;
    return _civil(m.group(1)!, m.group(2)!, m.group(3)!, m.group(4)!,
        m.group(5)!, m.group(6)!);
  } catch (_) {
    return null;
  }
}

/// [tePhotoTimeFromName], else [tePhotoTimeFromExif].
DateTime? tePhotoTakenAt(String fileName, Uint8List bytes) =>
    tePhotoTimeFromName(fileName) ?? tePhotoTimeFromExif(bytes);

/// Puts each of [photos] under one of [dates] (the days the report covers).
///
/// A photo with no [TEProofPhoto.takenAt] goes on the only date when there
/// is just one; otherwise, and when it was taken on a day not in [dates],
/// it comes back undated.
TEFolderPhotos sortFolderPhotos(
    List<TEProofPhoto> photos, Set<DateTime> dates) {
  final days = dates.map(_dateOnly).toSet();
  final byDate = <DateTime, List<TEProofPhoto>>{};
  final undated = <TEProofPhoto>[];
  for (final p in photos) {
    final taken = p.takenAt == null ? null : _dateOnly(p.takenAt!);
    final date = taken != null
        ? (days.contains(taken) ? taken : null)
        : (days.length == 1 ? days.first : null);
    if (date == null) {
      undated.add(p);
    } else {
      (byDate[date] ??= []).add(p);
    }
  }
  int byTime(TEProofPhoto a, TEProofPhoto b) {
    final ta = a.takenAt, tb = b.takenAt;
    if (ta != null && tb != null) return ta.compareTo(tb);
    if (ta != null) return -1;
    if (tb != null) return 1;
    return a.fileName.compareTo(b.fileName);
  }

  for (final list in byDate.values) {
    list.sort(byTime);
  }
  undated.sort(byTime);
  return TEFolderPhotos(byDate: byDate, undated: undated);
}

/// Downloads every photo at [paths], 6 at a time, and sorts them with
/// [sortFolderPhotos].
Future<TEFolderPhotos> loadFolderPhotos(
  List<String> paths, {
  required Set<DateTime> dates,
  void Function(int done, int total)? onProgress,
}) async {
  if (paths.isEmpty) return TEFolderPhotos.empty;
  final storage = FirebaseStorage.instance;
  final loaded = List<TEProofPhoto?>.filled(paths.length, null);
  final failed = <String>[];
  var next = 0, done = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= paths.length) return;
      final path = paths[i];
      final name = path.split('/').last;
      try {
        final original = await storage.ref(path).getData(_maxPhotoBytes);
        if (original == null) throw StateError('empty file');
        final takenAt = tePhotoTakenAt(name, original);
        loaded[i] = TEProofPhoto(
          bytes: await teCompressPhoto(original),
          fileName: name,
          storagePath: path,
          takenAt: takenAt,
        );
      } catch (e) {
        debugPrint('loadFolderPhotos: $path failed: $e');
        failed.add(path);
      } finally {
        onProgress?.call(++done, paths.length);
      }
    }
  }

  await Future.wait(List.generate(6, (_) => worker()));
  final sorted = sortFolderPhotos(loaded.whereType<TEProofPhoto>().toList(),
      dates);
  return TEFolderPhotos(
      byDate: sorted.byDate, undated: sorted.undated, failed: failed);
}
