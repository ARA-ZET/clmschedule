// track_editor/services/te_report_images.dart
//
// Proof photos as they go into the client report. A phone photo straight
// from the camera is several megabytes, and a PNG goes into a PDF as raw
// pixels — a dozen of either made 13-page reports over 25 MB. The report
// prints a photo 110 pt tall, so each is scaled to what print needs and
// re-encoded as a high-quality JPEG.
//
// The platform's own decoder (the browser's on web) does the decoding and
// scaling — fast, and it applies the photo's EXIF rotation. Only the final,
// already small, JPEG encode runs in Dart.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as im;

import '../models/te_promoter_day.dart';

/// Longest side kept: about 300 dpi for a landscape photo at the size the
/// report prints it.
const int tePhotoMaxSide = 1000;

/// High enough that compression can't be seen in print.
const int _jpegQuality = 82;

/// A JPEG already this small and no bigger than [tePhotoMaxSide] goes in
/// as it is.
const int _smallEnough = 350 * 1024;

/// Compressed copies by original, so regenerating a report doesn't redo them.
final Expando<Uint8List> _memo = Expando();

/// [bytes] (any format the platform decodes) as a JPEG no bigger than print
/// needs. Falls back to the original if it can't be decoded — a photo is
/// never dropped from the report over its size.
Future<Uint8List> teCompressPhoto(Uint8List bytes) async {
  final memo = _memo[bytes];
  if (memo != null) return memo;
  try {
    final out = await _compress(bytes);
    _memo[bytes] = out;
    return out;
  } catch (e) {
    debugPrint('Report photo: kept original, could not compress: $e');
    return bytes;
  }
}

Future<Uint8List> _compress(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  var scale = 1.0;
  final codec = await ui.instantiateImageCodecWithSize(buffer,
      getTargetSize: (w, h) {
    scale = math.min(1.0, tePhotoMaxSide / math.max(w, h));
    // Both sides scaled alike, so it doesn't matter whether the codec
    // reports them before or after applying EXIF rotation.
    return ui.TargetImageSize(
        width: (w * scale).round(), height: (h * scale).round());
  });
  final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
  if (scale == 1.0 && isJpeg && bytes.length <= _smallEnough) {
    codec.dispose();
    return bytes;
  }

  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final width = image.width, height = image.height;
  image.dispose();
  codec.dispose();
  if (rgba == null) throw StateError('no pixels');

  final decoded = im.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
  );
  // JPEG has no transparency: see-through parts go white, as on the page.
  final flat = im.Image(width: width, height: height)
    ..clear(im.ColorRgb8(255, 255, 255));
  im.compositeImage(flat, decoded);
  return im.encodeJpg(flat, quality: _jpegQuality);
}

/// [photosByDate] with every photo compressed for the report — see
/// [teCompressPhoto]. [onProgress] hears each one as it finishes.
Future<Map<DateTime, List<TEProofPhoto>>> teCompressProofPhotos(
  Map<DateTime, List<TEProofPhoto>> photosByDate, {
  void Function(int done, int total)? onProgress,
}) async {
  final total = photosByDate.values.fold<int>(0, (n, l) => n + l.length);
  var done = 0;
  final out = <DateTime, List<TEProofPhoto>>{};
  for (final MapEntry(key: date, value: photos) in photosByDate.entries) {
    final compressed = <TEProofPhoto>[];
    for (final p in photos) {
      compressed.add(TEProofPhoto(
        bytes: await teCompressPhoto(p.bytes),
        fileName: p.fileName,
        url: p.url,
      ));
      onProgress?.call(++done, total);
    }
    out[date] = compressed;
  }
  return out;
}
