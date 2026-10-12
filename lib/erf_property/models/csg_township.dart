import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'csg_region.dart';

/// A township/suburb boundary from the CSG "Allotment Township" layer.
///
/// This is the layer that makes visual suburb picking possible, and it is the
/// only reliable way to scope a download to one Cape Town suburb: in the
/// Western Cape the cadastral *minor region* is the whole metro
/// ("CAPE TOWN" = ~120 000 parcels), so filtering parcels by the township
/// polygon is what actually yields "the properties in this suburb".
class CsgTownship {
  final String name;

  /// Same value as a parcel's MIN_CODE where the suburb is its own cadastral
  /// region. In the Western Cape it usually is not, which is why downloads
  /// go by polygon rather than by this code.
  final String code;

  /// Outer rings. A suburb split by a road or river arrives as several.
  final List<List<LatLng>> rings;

  const CsgTownship({
    required this.name,
    required this.code,
    required this.rings,
  });

  /// Build from an ArcGIS feature. The layer returns one row per polygon
  /// part, so several features can share a code.
  factory CsgTownship.fromFeature(Map<String, dynamic> feature) {
    final attrs = Map<String, dynamic>.from(feature['attributes'] as Map);
    final geometry = feature['geometry'] == null
        ? null
        : Map<String, dynamic>.from(feature['geometry'] as Map);

    final rings = <List<LatLng>>[];
    for (final ring in (geometry?['rings'] as List<dynamic>? ?? const [])) {
      final points = <LatLng>[];
      for (final coord in ring as List<dynamic>) {
        final c = coord as List<dynamic>;
        points.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
      }
      if (points.length >= 3) rings.add(points);
    }

    return CsgTownship(
      name: (attrs['TAG_VALUE'] as String? ?? '').trim(),
      code: (attrs['TOWN_CODE'] as String? ?? '').trim(),
      rings: rings,
    );
  }

  /// Merge another part of the same suburb into this one.
  CsgTownship mergedWith(CsgTownship other) => CsgTownship(
        name: name,
        code: code,
        rings: [...rings, ...other.rings],
      );

  bool get hasGeometry => rings.isNotEmpty;

  int get vertexCount => rings.fold(0, (sum, r) => sum + r.length);

  ErfBounds? get bounds =>
      ErfBounds.fromPoints([for (final ring in rings) ...ring]);

  LatLng? get centroid => bounds?.center;

  /// The ArcGIS `geometry` parameter for a spatial query, as JSON.
  ///
  /// Rings go out as `[lng, lat]` pairs, which is the order ArcGIS uses.
  String toEsriPolygonJson() => json.encode({
        'rings': [
          for (final ring in rings)
            [
              for (final point in ring) [point.longitude, point.latitude],
            ],
        ],
        'spatialReference': {'wkid': 4326},
      });

  /// Treat this suburb as a cadastral region, for the code paths that want
  /// one. Only meaningful where the suburb really is its own minor region.
  CsgRegion toRegion() => CsgRegion(
        minRegion: name,
        minCode: code,
        majRegion: '',
        majCode: '',
        province: '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CsgTownship &&
          runtimeType == other.runtimeType &&
          code == other.code &&
          name == other.name;

  @override
  int get hashCode => Object.hash(code, name);
}
