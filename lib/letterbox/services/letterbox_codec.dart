import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Serialises one suburb's letterbox positions into a single gzipped payload.
///
/// Deliberately mirrors `ErfAreaCodec` (`lib/erf_property/services/`), which
/// measured >10x smaller than the equivalent Firestore document shape. The
/// same reasoning applies here and more so: a letterbox is *only* a position,
/// so anything beyond two numbers per point is overhead.
///
/// The format is:
///  - a flat `[lng, lat, lng, lat, …]` array rather than a list of
///    `{latitude, longitude}` maps (which cost ~40 bytes per point before
///    field names),
///  - coordinates rounded to 6 decimals (~11 cm — far finer than the GPS that
///    produced them),
///  - gzip over the lot.
///
/// At Cape Town scale this is roughly 8 KB per suburb and ~5 MB for the metro,
/// so a suburb loads in one request and the whole city fits in memory.
///
/// This is a copy, not a shared abstraction. The letterbox module is
/// deliberately isolated from `lib/erf_property/` so that changing one format
/// cannot break the other; they answer to different data and different
/// versioning pressure.
class LetterboxCodec {
  /// Bumped whenever the payload shape changes. [decode] refuses anything it
  /// does not recognise rather than silently misreading an old file.
  static const int formatVersion = 1;

  /// ~11 cm at South African latitudes.
  static const int _coordinatePrecision = 6;

  /// Encode [points] to gzipped UTF-8 JSON.
  static Uint8List encode({
    required String suburbId,
    required String suburbName,
    required List<LatLng> points,
  }) {
    // Flat [lng, lat, …] — half the JSON of an array of objects, and it
    // decodes with no per-point map allocation.
    final flat = <double>[];
    for (final p in points) {
      flat.add(_round(p.longitude));
      flat.add(_round(p.latitude));
    }

    final payload = <String, dynamic>{
      'v': formatVersion,
      'suburbId': suburbId,
      'name': suburbName,
      'count': points.length,
      'pts': flat,
    };

    final json = utf8.encode(jsonEncode(payload));
    return Uint8List.fromList(const GZipEncoder().encode(json));
  }

  /// Decode a payload produced by [encode].
  ///
  /// Throws [FormatException] on an unreadable or unknown-version file, so a
  /// stale payload surfaces loudly instead of being read as zero letterboxes —
  /// which would silently understate a quote.
  static List<LatLng> decode(Uint8List bytes) {
    final List<int> json;
    try {
      json = const GZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('Letterbox file is not valid gzip: $e');
    }

    final decoded = jsonDecode(utf8.decode(json));
    if (decoded is! Map) {
      throw const FormatException('Letterbox file is not an object.');
    }

    final version = (decoded['v'] as num?)?.toInt() ?? 0;
    if (version != formatVersion) {
      throw FormatException(
        'Letterbox file is format v$version; this build reads '
        'v$formatVersion.',
      );
    }

    final flat = decoded['pts'] as List<dynamic>? ?? const [];
    if (flat.length.isOdd) {
      throw FormatException(
        'Letterbox file has ${flat.length} coordinates — expected an even '
        'number of [lng, lat] pairs.',
      );
    }

    final points = <LatLng>[];
    for (var i = 0; i < flat.length; i += 2) {
      final lng = (flat[i] as num).toDouble();
      final lat = (flat[i + 1] as num).toDouble();
      points.add(LatLng(lat, lng));
    }
    return points;
  }

  /// Decode off the UI isolate. Use this everywhere in the app — the ERF
  /// module's equivalent runs on the main isolate and stalls for hundreds of
  /// milliseconds on a large area; don't repeat that here.
  static Future<List<LatLng>> decodeAsync(Uint8List bytes) =>
      compute(decode, bytes);

  static double _round(double v) {
    final factor = _pow10(_coordinatePrecision);
    return (v * factor).roundToDouble() / factor;
  }

  static double _pow10(int exp) {
    var result = 1.0;
    for (var i = 0; i < exp; i++) {
      result *= 10;
    }
    return result;
  }
}
