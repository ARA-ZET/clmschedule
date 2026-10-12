import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/erf_property.dart';

/// Serialises a whole area's parcels into one compact, gzipped payload.
///
/// The Firestore document shape ([ErfProperty.toMap]) spells out every key on
/// every parcel and stores each polygon vertex as a `{latitude, longitude}`
/// map — roughly 40 bytes per point before the field names. An area of 10 000
/// parcels ran to tens of megabytes across 10 000 documents.
///
/// This format instead uses:
///  - one-or-two character keys,
///  - a flat `[lng, lat, lng, lat, …]` vertex array,
///  - coordinates rounded to 6 decimals (~11 cm, far finer than cadastral
///    survey accuracy),
///  - gzip over the lot.
///
/// The result is a single Storage object, read and written once per area.
class ErfAreaCodec {
  /// Bumped whenever the payload shape changes. [decode] refuses anything it
  /// does not recognise rather than silently misreading old files.
  static const int formatVersion = 1;

  /// ~11 cm at South African latitudes.
  static const int _coordinatePrecision = 6;

  /// Encode [properties] to gzipped UTF-8 JSON.
  static Uint8List encode({
    required String areaId,
    required String name,
    required List<ErfProperty> properties,
  }) {
    final payload = <String, dynamic>{
      'v': formatVersion,
      'areaId': areaId,
      'name': name,
      'count': properties.length,
      'parcels': properties.map(_encodeParcel).toList(),
    };

    final json = utf8.encode(jsonEncode(payload));
    return Uint8List.fromList(const GZipEncoder().encode(json));
  }

  /// Decode a payload produced by [encode].
  ///
  /// Throws [FormatException] on an unreadable or future-versioned file.
  static List<ErfProperty> decode(Uint8List bytes, {String? areaId}) {
    final List<int> json;
    try {
      json = const GZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('ERF area file is not valid gzip: $e');
    }

    final decoded = jsonDecode(utf8.decode(json));
    if (decoded is! Map) {
      throw const FormatException('ERF area file is not an object.');
    }

    final version = (decoded['v'] as num?)?.toInt() ?? 0;
    if (version != formatVersion) {
      throw FormatException(
        'ERF area file is format v$version; this build reads '
        'v$formatVersion. Re-download the area.',
      );
    }

    final parcels = decoded['parcels'] as List<dynamic>? ?? const [];
    final resolvedAreaId = areaId ?? decoded['areaId'] as String?;

    return parcels
        .map((p) => _decodeParcel(
            Map<String, dynamic>.from(p as Map), resolvedAreaId))
        .toList();
  }

  // ── Parcel ──────────────────────────────────────────────────────────

  static Map<String, dynamic> _encodeParcel(ErfProperty p) {
    return <String, dynamic>{
      'i': p.id,
      'e': p.erfNumber,
      't': p.tagValue,
      'l': p.lpiCode,
      'mr': p.minRegion,
      'mc': p.minCode,
      'Mr': p.majRegion,
      'Mc': p.majCode,
      'pr': p.province,
      'a': _round(p.area, 2),
      'c': [_round6(p.centroid.longitude), _round6(p.centroid.latitude)],
      'g': _encodeRing(p.polygon),
      if (p.streetAddress != null && p.streetAddress!.isNotEmpty)
        'sa': p.streetAddress,
      if (p.suburb != null && p.suburb!.isNotEmpty) 'sb': p.suburb,
    };
  }

  static ErfProperty _decodeParcel(Map<String, dynamic> p, String? areaId) {
    final centroid = (p['c'] as List<dynamic>?) ?? const [0, 0];
    return ErfProperty(
      id: p['i'] as String? ?? '',
      erfNumber: (p['e'] as num?)?.toInt() ?? 0,
      tagValue: p['t'] as String? ?? '',
      lpiCode: p['l'] as String? ?? '',
      minRegion: p['mr'] as String? ?? '',
      minCode: p['mc'] as String? ?? '',
      majRegion: p['Mr'] as String? ?? '',
      majCode: p['Mc'] as String? ?? '',
      province: p['pr'] as String? ?? '',
      area: (p['a'] as num?)?.toDouble() ?? 0,
      centroid: LatLng(
        (centroid.length > 1 ? centroid[1] as num : 0).toDouble(),
        (centroid.isNotEmpty ? centroid[0] as num : 0).toDouble(),
      ),
      polygon: _decodeRing(p['g'] as List<dynamic>?),
      streetAddress: p['sa'] as String?,
      suburb: p['sb'] as String?,
      areaId: areaId,
    );
  }

  /// Vertices go out flat as lng,lat pairs — half the JSON of a list of
  /// objects, and it matches the order KML and GeoJSON already use.
  static List<double> _encodeRing(List<LatLng> points) {
    final flat = <double>[];
    for (final point in points) {
      flat.add(_round6(point.longitude));
      flat.add(_round6(point.latitude));
    }
    return flat;
  }

  static List<LatLng> _decodeRing(List<dynamic>? flat) {
    if (flat == null || flat.length < 2) return const [];
    final points = <LatLng>[];
    for (var i = 0; i + 1 < flat.length; i += 2) {
      points.add(LatLng(
        (flat[i + 1] as num).toDouble(),
        (flat[i] as num).toDouble(),
      ));
    }
    return points;
  }

  static double _round6(double value) => _round(value, _coordinatePrecision);

  static double _round(double value, int places) {
    final factor = _pow10(places);
    return (value * factor).roundToDouble() / factor;
  }

  static double _pow10(int places) {
    var result = 1.0;
    for (var i = 0; i < places; i++) {
      result *= 10;
    }
    return result;
  }
}
