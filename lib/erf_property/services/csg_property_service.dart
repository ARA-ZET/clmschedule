import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/erf_property.dart';

/// Service for querying the CSG (Chief Surveyor-General) Property Viewer
/// ArcGIS REST API to retrieve ERF property data with polygon boundaries.
///
/// API base: https://csggis.drdlr.gov.za/server/rest/services/Property_Viewer/MapServer
/// Layer 2 = Erven (property parcels with polygons)
class CsgPropertyService {
  static const String _baseUrl =
      'https://csggis.drdlr.gov.za/server/rest/services/Property_Viewer/MapServer';
  static const int _ervenLayerId = 2;
  static const int _maxRecords = 2000;

  static const String _outFields =
      'OBJECTID,PARCEL_NO,TAG_VALUE,MAJ_REGION,MAJ_CODE,MIN_REGION,MIN_CODE,ID,PRCL_KEY,GEOM_AREA,PROVINCE,TAG_X,TAG_Y';

  /// Query ERF properties within a geographic bounding box.
  ///
  /// [minLat], [minLng], [maxLat], [maxLng] define the bounding box in WGS84.
  /// Returns a list of [ErfProperty] with polygon geometries.
  Future<List<ErfProperty>> queryByBoundingBox({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
    int resultOffset = 0,
  }) async {
    final geometry = json.encode({
      'xmin': minLng,
      'ymin': minLat,
      'xmax': maxLng,
      'ymax': maxLat,
    });

    final params = {
      'geometry': geometry,
      'geometryType': 'esriGeometryEnvelope',
      'inSR': '4326',
      'spatialRel': 'esriSpatialRelIntersects',
      'outFields': _outFields,
      'returnGeometry': 'true',
      'outSR': '4326',
      'f': 'json',
      'resultRecordCount': '$_maxRecords',
      'resultOffset': '$resultOffset',
    };

    return _executeQuery(params);
  }

  /// Query ERF properties that contain a specific point (lat/lng).
  ///
  /// Useful for finding which ERF a given address falls within.
  Future<List<ErfProperty>> queryByPoint({
    required double latitude,
    required double longitude,
  }) async {
    final geometry = json.encode({
      'x': longitude,
      'y': latitude,
    });

    final params = {
      'geometry': geometry,
      'geometryType': 'esriGeometryPoint',
      'inSR': '4326',
      'spatialRel': 'esriSpatialRelIntersects',
      'outFields': _outFields,
      'returnGeometry': 'true',
      'outSR': '4326',
      'f': 'json',
    };

    return _executeQuery(params);
  }

  /// Query by MIN_CODE (cadastral minor region code, e.g. "C0160007" for Cape Town).
  ///
  /// Returns all ERFs in that cadastral region. May require pagination
  /// if the region has more than 2000 parcels.
  Future<List<ErfProperty>> queryByMinCode({
    required String minCode,
    int resultOffset = 0,
  }) async {
    final params = {
      'where': "MIN_CODE = '$minCode'",
      'outFields': _outFields,
      'returnGeometry': 'true',
      'outSR': '4326',
      'f': 'json',
      'resultRecordCount': '$_maxRecords',
      'resultOffset': '$resultOffset',
    };

    return _executeQuery(params);
  }

  /// Query all ERFs in a bounding box, automatically paginating through
  /// all results (the API returns max 2000 per request).
  Future<List<ErfProperty>> queryAllInBoundingBox({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
    Function(int loaded, bool hasMore)? onProgress,
  }) async {
    final allProperties = <ErfProperty>[];
    int offset = 0;
    bool hasMore = true;

    while (hasMore) {
      final batch = await queryByBoundingBox(
        minLat: minLat,
        minLng: minLng,
        maxLat: maxLat,
        maxLng: maxLng,
        resultOffset: offset,
      );

      allProperties.addAll(batch);
      offset += batch.length;
      hasMore = batch.length == _maxRecords;

      onProgress?.call(allProperties.length, hasMore);

      // Small delay between paginated requests
      if (hasMore) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    return allProperties;
  }

  /// Execute a query against the Erven layer.
  Future<List<ErfProperty>> _executeQuery(Map<String, String> params) async {
    try {
      final uri = Uri.parse('$_baseUrl/$_ervenLayerId/query')
          .replace(queryParameters: params);

      debugPrint('🏠 CSG query: ${uri.toString().substring(0, 100)}...');

      final response = await http.get(uri).timeout(
            const Duration(seconds: 30),
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;

        if (data.containsKey('error')) {
          debugPrint('❌ CSG API error: ${data['error']}');
          return [];
        }

        final features = data['features'] as List<dynamic>? ?? [];
        debugPrint('✅ CSG returned ${features.length} features');

        return features
            .map((f) =>
                ErfProperty.fromCsgFeature(f as Map<String, dynamic>))
            .toList();
      } else {
        debugPrint('❌ CSG HTTP error: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      debugPrint('❌ CSG query error: $e');
      return [];
    }
  }
}
