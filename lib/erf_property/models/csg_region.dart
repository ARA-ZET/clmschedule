import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A cadastral region as published by the CSG Property Viewer.
///
/// The CSG data model nests parcels under a major region (typically the
/// administrative district, e.g. "CAPE TOWN RD") and a minor region, which
/// is what most people call the suburb (e.g. "KENSINGTON"). [minCode] is the
/// stable key used to pull every parcel in that suburb.
class CsgRegion {
  final String minRegion;
  final String minCode;
  final String majRegion;
  final String majCode;
  final String province;

  const CsgRegion({
    required this.minRegion,
    required this.minCode,
    required this.majRegion,
    required this.majCode,
    required this.province,
  });

  factory CsgRegion.fromAttributes(Map<String, dynamic> attrs) {
    return CsgRegion(
      minRegion: (attrs['MIN_REGION'] as String? ?? '').trim(),
      minCode: (attrs['MIN_CODE'] as String? ?? '').trim(),
      majRegion: (attrs['MAJ_REGION'] as String? ?? '').trim(),
      majCode: (attrs['MAJ_CODE'] as String? ?? '').trim(),
      province: (attrs['PROVINCE'] as String? ?? '').trim(),
    );
  }

  /// Human label, e.g. "KENSINGTON — CAPE TOWN RD (WESTERN CAPE)".
  String get label {
    final parts = <String>[
      if (minRegion.isNotEmpty) minRegion,
      if (majRegion.isNotEmpty) majRegion,
    ];
    final head = parts.join(' — ');
    return province.isEmpty ? head : '$head ($province)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CsgRegion &&
          runtimeType == other.runtimeType &&
          minCode == other.minCode &&
          minRegion == other.minRegion;

  @override
  int get hashCode => Object.hash(minCode, minRegion);
}

/// A rectangular geographic area, used when downloading ERFs by map extent
/// rather than by cadastral region.
class ErfBounds {
  final double minLat;
  final double minLng;
  final double maxLat;
  final double maxLng;

  const ErfBounds({
    required this.minLat,
    required this.minLng,
    required this.maxLat,
    required this.maxLng,
  });

  /// A square-ish box of roughly [radiusKm] around [center].
  factory ErfBounds.aroundPoint(LatLng center, double radiusKm) {
    // 1 degree of latitude ≈ 111 km; longitude shrinks toward the poles, but
    // at South African latitudes a fixed 0.85 factor is close enough for a
    // download window and avoids pulling in trigonometry.
    final latDelta = radiusKm / 111.0;
    final lngDelta = radiusKm / (111.0 * 0.85);
    return ErfBounds(
      minLat: center.latitude - latDelta,
      minLng: center.longitude - lngDelta,
      maxLat: center.latitude + latDelta,
      maxLng: center.longitude + lngDelta,
    );
  }

  /// The bounding box that contains every point in [points].
  static ErfBounds? fromPoints(List<LatLng> points) {
    if (points.isEmpty) return null;
    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return ErfBounds(
      minLat: minLat,
      minLng: minLng,
      maxLat: maxLat,
      maxLng: maxLng,
    );
  }

  LatLng get center => LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);

  Map<String, dynamic> toMap() => {
        'minLat': minLat,
        'minLng': minLng,
        'maxLat': maxLat,
        'maxLng': maxLng,
      };

  static ErfBounds? fromMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    final minLat = (data['minLat'] as num?)?.toDouble();
    final minLng = (data['minLng'] as num?)?.toDouble();
    final maxLat = (data['maxLat'] as num?)?.toDouble();
    final maxLng = (data['maxLng'] as num?)?.toDouble();
    if (minLat == null || minLng == null || maxLat == null || maxLng == null) {
      return null;
    }
    return ErfBounds(
      minLat: minLat,
      minLng: minLng,
      maxLat: maxLat,
      maxLng: maxLng,
    );
  }
}
