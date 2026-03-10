import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Model representing a cadastral ERF property from the CSG Property Viewer.
///
/// Each property has an ERF number, optional street address, and polygon
/// boundary points that define the property extent.
class ErfProperty {
  final String id;
  final int erfNumber;
  final String tagValue;
  final String lpiCode;
  final String majRegion;
  final String majCode;
  final String minRegion;
  final String minCode;
  final String province;
  final double area;
  final List<LatLng> polygon;
  final LatLng centroid;

  // Address info (populated via geocoding or manual entry)
  final String? streetAddress;
  final String? suburb;

  const ErfProperty({
    required this.id,
    required this.erfNumber,
    required this.tagValue,
    required this.lpiCode,
    required this.majRegion,
    required this.majCode,
    required this.minRegion,
    required this.minCode,
    required this.province,
    required this.area,
    required this.polygon,
    required this.centroid,
    this.streetAddress,
    this.suburb,
  });

  /// Create from CSG ArcGIS REST API feature JSON.
  factory ErfProperty.fromCsgFeature(Map<String, dynamic> feature) {
    final attrs = feature['attributes'] as Map<String, dynamic>;
    final geometry = feature['geometry'] as Map<String, dynamic>?;

    // Parse polygon rings - CSG returns [[[lng, lat], ...]]
    final rings = geometry?['rings'] as List<dynamic>? ?? [];
    final points = <LatLng>[];
    if (rings.isNotEmpty) {
      final outerRing = rings[0] as List<dynamic>;
      for (final coord in outerRing) {
        final c = coord as List<dynamic>;
        points.add(LatLng(
          (c[1] as num).toDouble(),
          (c[0] as num).toDouble(),
        ));
      }
    }

    // Calculate centroid from TAG_X/TAG_Y or from polygon
    final tagX = (attrs['TAG_X'] as num?)?.toDouble();
    final tagY = (attrs['TAG_Y'] as num?)?.toDouble();
    final centroid = (tagX != null && tagY != null)
        ? LatLng(tagY, tagX)
        : _calculateCentroid(points);

    final lpi = attrs['ID'] as String? ?? '';

    return ErfProperty(
      id: lpi.isNotEmpty ? lpi : 'erf_${attrs['PARCEL_NO']}',
      erfNumber: attrs['PARCEL_NO'] as int? ?? 0,
      tagValue: attrs['TAG_VALUE'] as String? ?? '',
      lpiCode: lpi,
      majRegion: attrs['MAJ_REGION'] as String? ?? '',
      majCode: attrs['MAJ_CODE'] as String? ?? '',
      minRegion: attrs['MIN_REGION'] as String? ?? '',
      minCode: attrs['MIN_CODE'] as String? ?? '',
      province: attrs['PROVINCE'] as String? ?? '',
      area: (attrs['GEOM_AREA'] as num?)?.toDouble() ?? 0,
      polygon: points,
      centroid: centroid,
    );
  }

  /// Create from Firestore map.
  factory ErfProperty.fromMap(String id, Map<String, dynamic> data) {
    return ErfProperty(
      id: id,
      erfNumber: data['erfNumber'] as int? ?? 0,
      tagValue: data['tagValue'] as String? ?? '',
      lpiCode: data['lpiCode'] as String? ?? '',
      majRegion: data['majRegion'] as String? ?? '',
      majCode: data['majCode'] as String? ?? '',
      minRegion: data['minRegion'] as String? ?? '',
      minCode: data['minCode'] as String? ?? '',
      province: data['province'] as String? ?? '',
      area: (data['area'] as num?)?.toDouble() ?? 0,
      polygon: (data['polygon'] as List<dynamic>?)
              ?.map((p) => LatLng(
                    (p['latitude'] as num).toDouble(),
                    (p['longitude'] as num).toDouble(),
                  ))
              .toList() ??
          [],
      centroid: LatLng(
        (data['centroidLat'] as num?)?.toDouble() ?? 0,
        (data['centroidLng'] as num?)?.toDouble() ?? 0,
      ),
      streetAddress: data['streetAddress'] as String?,
      suburb: data['suburb'] as String?,
    );
  }

  /// Convert to Firestore map.
  Map<String, dynamic> toMap() {
    return {
      'erfNumber': erfNumber,
      'tagValue': tagValue,
      'lpiCode': lpiCode,
      'majRegion': majRegion,
      'majCode': majCode,
      'minRegion': minRegion,
      'minCode': minCode,
      'province': province,
      'area': area,
      'polygon': polygon
          .map((p) => {
                'latitude': p.latitude,
                'longitude': p.longitude,
              })
          .toList(),
      'centroidLat': centroid.latitude,
      'centroidLng': centroid.longitude,
      'streetAddress': streetAddress,
      'suburb': suburb,
    };
  }

  ErfProperty copyWith({
    String? streetAddress,
    String? suburb,
    List<LatLng>? polygon,
  }) {
    return ErfProperty(
      id: id,
      erfNumber: erfNumber,
      tagValue: tagValue,
      lpiCode: lpiCode,
      majRegion: majRegion,
      majCode: majCode,
      minRegion: minRegion,
      minCode: minCode,
      province: province,
      area: area,
      polygon: polygon ?? this.polygon,
      centroid: centroid,
      streetAddress: streetAddress ?? this.streetAddress,
      suburb: suburb ?? this.suburb,
    );
  }

  /// Display label for the property.
  String get displayLabel {
    if (streetAddress != null && streetAddress!.isNotEmpty) {
      return '$streetAddress (ERF $tagValue)';
    }
    return 'ERF $tagValue';
  }

  static LatLng _calculateCentroid(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(0, 0);
    double lat = 0, lng = 0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ErfProperty &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
