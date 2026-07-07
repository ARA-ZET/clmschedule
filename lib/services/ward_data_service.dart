import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../models/custom_polygon.dart';
import '../shareable_maps/models/map_point.dart';
import '../shareable_maps/utils/geo_containment.dart';

class WardDataResult {
  final List<CustomPolygon> wardBoundaries;
  final List<CustomPolygon> votingDistricts;
  final List<MapPoint> votingStations;
  final String mapName;
  final LatLng center;

  const WardDataResult({
    required this.wardBoundaries,
    required this.votingDistricts,
    required this.votingStations,
    required this.mapName,
    required this.center,
  });
}

/// Fetches SA ward data from the Municipal Demarcation Board ArcGIS REST services.
///
/// Data sources (both updated 2026-05-05, most recent available):
///   Wards:    Wards2026             FeatureServer/0
///   VDs:      VotingDistricts2026   FeatureServer/0
///   Stations: VotingStations_March2026 FeatureServer/0  (no newer version exists)
///
/// Station matching uses spatial point-in-polygon, not field joins:
///   1. Compute the bounding box of the fetched VD polygons.
///   2. Query ALL stations within that bbox from the API.
///   3. Keep only stations whose coordinates fall inside at least one VD ring.
/// This eliminates any field-value mismatches between VOTINGDIST / WARD / WardID.
class WardDataService {
  static const _wardsUrl =
      "https://services7.arcgis.com/oeoyTUJC8HEeYsRB/ArcGIS/rest/services/Wards2026_02April2026/FeatureServer/0/query";
  // 'https://services7.arcgis.com/oeoyTUJC8HEeYsRB/arcgis/rest/services/Wards2026/FeatureServer/0/query';
  static const _vdUrl =
      'https://services7.arcgis.com/oeoyTUJC8HEeYsRB/arcgis/rest/services/VotingDistricts2026/FeatureServer/0/query';
  static const _vsUrl =
      'https://services7.arcgis.com/oeoyTUJC8HEeYsRB/arcgis/rest/services/VotingStations_March2026/FeatureServer/0/query';

  // Buffer added to the VD bounding box when fetching stations (degrees).
  // ~0.02° ≈ 2 km — large enough to catch stations on VD edges.
  static const double _bboxBufferDeg = 0.02;

  final http.Client _client;

  WardDataService({http.Client? client}) : _client = client ?? http.Client();

  Future<WardDataResult> fetchWardData(
    List<int> wardNumbers, {
    void Function(String status)? onStatus,
  }) async {
    final wardNums = wardNumbers.join(',');

    onStatus?.call('Downloading ward boundaries...');
    final wardsFeatures = await _queryWhere(
      _wardsUrl,
      "WardNo IN ($wardNums) AND Province LIKE '%Western%'",
    );

    onStatus?.call('Downloading voting districts...');
    final vdFeatures = await _queryWhere(
      _vdUrl,
      "WardNo IN ($wardNums) AND Province LIKE '%Western%'",
    );

    // Extract every polygon ring from the VD geometries for point-in-polygon.
    final vdRings = _extractRings(vdFeatures);

    List<Map<String, dynamic>> vsFeatures = [];
    if (vdRings.isNotEmpty) {
      // Compute a bounding box that encloses all VD rings + a small buffer.
      final bbox = _bbox(vdRings.expand((r) => r).toList());

      onStatus?.call('Downloading all stations within ward area...');
      vsFeatures = await _queryBbox(_vsUrl, bbox);

      onStatus?.call(
          'Filtering ${vsFeatures.length} stations by polygon containment...');
      // Keep only stations that fall inside at least one VD polygon ring.
      vsFeatures = vsFeatures.where((feat) {
        final pt = _pointFromFeature(feat);
        if (pt == null) return false;
        return vdRings.any((ring) => isPointInPolygon(pt, ring));
      }).toList();
    }

    final baseTs = DateTime.now().millisecondsSinceEpoch;

    final wardBoundaries =
        _toPolygons(wardsFeatures, 'WardNo', Colors.blue, baseTs, 0);
    final votingDistricts =
        _toVdPolygons(vdFeatures, Colors.orange, baseTs, wardBoundaries.length);
    final votingStations = _toPoints(vsFeatures, 'VOTING_STA');

    final center = _computeCenter(wardBoundaries);

    return WardDataResult(
      wardBoundaries: wardBoundaries,
      votingDistricts: votingDistricts,
      votingStations: votingStations,
      mapName: 'Ward ${wardNumbers.join(', ')}',
      center: center,
    );
  }

  // ── API helpers ────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _queryWhere(
      String url, String where) async {
    final features = <Map<String, dynamic>>[];
    int offset = 0;

    while (true) {
      final uri = Uri.parse(url).replace(queryParameters: {
        'where': where,
        'outFields': '*',
        'outSR': '4326',
        'f': 'geojson',
        'resultOffset': '$offset',
        'resultRecordCount': '1000',
        'returnGeometry': 'true',
      });

      final batch = await _fetch(uri);
      features.addAll(batch);
      if (batch.length < 1000) break;
      offset += 1000;
    }

    return features;
  }

  /// Query a feature layer using a spatial bounding-box filter.
  /// Returns all features whose geometry intersects (or is contained by) the bbox.
  Future<List<Map<String, dynamic>>> _queryBbox(String url, _Bbox bbox) async {
    final features = <Map<String, dynamic>>[];
    int offset = 0;

    final bboxStr =
        '${bbox.minLng},${bbox.minLat},${bbox.maxLng},${bbox.maxLat}';

    while (true) {
      final uri = Uri.parse(url).replace(queryParameters: {
        'where': '1=1',
        'geometry': bboxStr,
        'geometryType': 'esriGeometryEnvelope',
        'inSR': '4326',
        'spatialRel': 'esriSpatialRelContains',
        'outFields': '*',
        'outSR': '4326',
        'f': 'geojson',
        'resultOffset': '$offset',
        'resultRecordCount': '1000',
        'returnGeometry': 'true',
      });

      final batch = await _fetch(uri);
      features.addAll(batch);
      if (batch.length < 1000) break;
      offset += 1000;
    }

    return features;
  }

  Future<List<Map<String, dynamic>>> _fetch(Uri uri) async {
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception(
          'ArcGIS query failed (${response.statusCode}): ${response.body}');
    }
    final data = json.decode(response.body) as Map<String, dynamic>;
    if (data.containsKey('error')) {
      throw Exception('ArcGIS error: ${data['error']}');
    }
    return (data['features'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }

  // ── Spatial helpers ────────────────────────────────────────────────────────

  /// Extract every outer polygon ring from a list of GeoJSON features.
  /// Both Polygon and MultiPolygon geometries are handled.
  List<List<LatLng>> _extractRings(List<Map<String, dynamic>> features) {
    final rings = <List<LatLng>>[];
    for (final feat in features) {
      final geom = feat['geometry'] as Map<String, dynamic>?;
      if (geom == null) continue;
      final type = geom['type'] as String?;
      final coords = geom['coordinates'] as List<dynamic>?;
      if (coords == null) continue;

      if (type == 'Polygon') {
        final ring = _parseRing(coords[0] as List<dynamic>);
        if (ring != null) rings.add(ring);
      } else if (type == 'MultiPolygon') {
        for (final poly in coords) {
          final ring = _parseRing((poly as List<dynamic>)[0] as List<dynamic>);
          if (ring != null) rings.add(ring);
        }
      }
    }
    return rings;
  }

  /// Compute the bounding box of a list of points and add [_bboxBufferDeg].
  _Bbox _bbox(List<LatLng> points) {
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return _Bbox(
      minLat: minLat - _bboxBufferDeg,
      maxLat: maxLat + _bboxBufferDeg,
      minLng: minLng - _bboxBufferDeg,
      maxLng: maxLng + _bboxBufferDeg,
    );
  }

  LatLng? _pointFromFeature(Map<String, dynamic> feat) {
    final geom = feat['geometry'] as Map<String, dynamic>?;
    if (geom == null || geom['type'] != 'Point') return null;
    final coords = geom['coordinates'] as List<dynamic>?;
    if (coords == null || coords.length < 2) return null;
    return LatLng(
      (coords[1] as num).toDouble(),
      (coords[0] as num).toDouble(),
    );
  }

  // ── Conversion helpers ─────────────────────────────────────────────────────

  List<CustomPolygon> _toPolygons(
    List<Map<String, dynamic>> features,
    String nameField,
    Color color,
    int baseTs,
    int seqOffset,
  ) {
    final polygons = <CustomPolygon>[];
    int seq = seqOffset;

    for (final feat in features) {
      final geom = feat['geometry'] as Map<String, dynamic>?;
      if (geom == null) continue;
      final props = feat['properties'] as Map<String, dynamic>? ?? {};
      final name = props[nameField]?.toString() ?? 'Polygon ${seq + 1}';
      final type = geom['type'] as String?;

      if (type == 'Polygon') {
        final pts = _parseRing(
            (geom['coordinates'] as List<dynamic>)[0] as List<dynamic>);
        if (pts != null) {
          polygons.add(CustomPolygon(
              name: name,
              description: '',
              points: pts,
              color: color,
              fillOpacity: 0.2,
              strokeWidth: 2));
          seq++;
        }
      } else if (type == 'MultiPolygon') {
        final rings = geom['coordinates'] as List<dynamic>;
        for (int i = 0; i < rings.length; i++) {
          final pts =
              _parseRing((rings[i] as List<dynamic>)[0] as List<dynamic>);
          if (pts != null) {
            polygons.add(CustomPolygon(
                name: rings.length > 1 ? '$name (${i + 1})' : name,
                description: '',
                points: pts,
                color: color,
                fillOpacity: 0.2,
                strokeWidth: 2));
            seq++;
          }
        }
      }
    }
    return polygons;
  }

  /// Build VD polygons with descriptions from the VotingDistricts2026 layer fields.
  List<CustomPolygon> _toVdPolygons(
    List<Map<String, dynamic>> features,
    Color color,
    int baseTs,
    int seqOffset,
  ) {
    final polygons = <CustomPolygon>[];
    int seq = seqOffset;

    for (final feat in features) {
      final geom = feat['geometry'] as Map<String, dynamic>?;
      if (geom == null) continue;
      final props = feat['properties'] as Map<String, dynamic>? ?? {};

      final vdNum = props['VDNumber']?.toString() ?? 'VD ${seq + 1}';
      final stationName = props['VotingStat']?.toString() ?? '';
      final regPop = props['REGPOP'];
      final splitVd = props['Split_VD']?.toString().trim() ?? '';

      final descParts = <String>[];
      if (stationName.isNotEmpty) descParts.add('Station: $stationName');
      if (regPop != null) descParts.add('Reg. voters: $regPop');
      if (splitVd.isNotEmpty && splitVd != ' ') {
        descParts.add('Split VD: $splitVd');
      }
      final desc = descParts.join('\n');

      final type = geom['type'] as String?;

      if (type == 'Polygon') {
        final pts = _parseRing(
            (geom['coordinates'] as List<dynamic>)[0] as List<dynamic>);
        if (pts != null) {
          polygons.add(CustomPolygon(
              name: vdNum,
              description: desc,
              points: pts,
              color: color,
              fillOpacity: 0.15,
              strokeWidth: 1));
          seq++;
        }
      } else if (type == 'MultiPolygon') {
        final rings = geom['coordinates'] as List<dynamic>;
        for (int i = 0; i < rings.length; i++) {
          final pts =
              _parseRing((rings[i] as List<dynamic>)[0] as List<dynamic>);
          if (pts != null) {
            polygons.add(CustomPolygon(
                name: rings.length > 1 ? '$vdNum (${i + 1})' : vdNum,
                description: desc,
                points: pts,
                color: color,
                fillOpacity: 0.15,
                strokeWidth: 1));
            seq++;
          }
        }
      }
    }
    return polygons;
  }

  List<MapPoint> _toPoints(
    List<Map<String, dynamic>> features,
    String nameField,
  ) {
    final points = <MapPoint>[];
    int seq = 0;
    final now = DateTime.now();
    // Deduplicate: one physical building can appear once per VD it serves,
    // but should show as a single pin on the map.
    final seen = <String>{};

    for (final feat in features) {
      final pt = _pointFromFeature(feat);
      if (pt == null) continue;

      final props = feat['properties'] as Map<String, dynamic>? ?? {};
      final name = props[nameField]?.toString() ?? 'Station ${seq + 1}';
      if (!seen.add(name)) continue;

      final vdNum = props['VOTINGDIST']?.toString() ?? '';
      final address = props['ADDRESS']?.toString() ?? '';
      final venue = props['VENUE_DESC']?.toString() ?? '';
      final vsType = props['VS_TYPE']?.toString() ?? '';

      final descParts = <String>[];
      if (vdNum.isNotEmpty) descParts.add('VD: $vdNum');
      if (address.isNotEmpty) descParts.add(address);
      if (venue.isNotEmpty && venue != address) descParts.add(venue);
      if (vsType.isNotEmpty) descParts.add('Type: $vsType');

      points.add(MapPoint(
        id: MapPoint.importId(name, pt),
        name: name,
        description: descParts.join('\n'),
        position: pt,
        color: Colors.green,
        createdAt: now,
        updatedAt: now,
      ));
      seq++;
    }
    return points;
  }

  List<LatLng>? _parseRing(List<dynamic> ring) {
    final pts = <LatLng>[];
    for (final c in ring) {
      final coord = c as List<dynamic>;
      if (coord.length < 2) continue;
      pts.add(
          LatLng((coord[1] as num).toDouble(), (coord[0] as num).toDouble()));
    }
    return pts.length >= 3 ? pts : null;
  }

  LatLng _computeCenter(List<CustomPolygon> polygons) {
    if (polygons.isEmpty) return const LatLng(-33.925, 18.425);
    double latSum = 0, lngSum = 0;
    int count = 0;
    for (final p in polygons) {
      for (final pt in p.points) {
        latSum += pt.latitude;
        lngSum += pt.longitude;
        count++;
      }
    }
    if (count == 0) return const LatLng(-33.925, 18.425);
    return LatLng(latSum / count, lngSum / count);
  }
}

class _Bbox {
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;

  const _Bbox({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });
}
