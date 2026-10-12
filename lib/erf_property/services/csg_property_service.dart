import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/csg_region.dart';
import '../models/csg_township.dart';
import '../models/erf_search_scope.dart';
import '../models/erf_property.dart';

/// A CSG request that could not be completed.
///
/// Distinct from "the query ran and matched nothing", which comes back as an
/// empty list — callers need to tell a dead server apart from a genuine
/// no-match so they can say so.
class CsgException implements Exception {
  final String message;
  const CsgException(this.message);

  @override
  String toString() => message;
}

/// Service for querying the CSG (Chief Surveyor-General) Property Viewer
/// ArcGIS REST API to retrieve ERF property data with polygon boundaries.
///
/// API base: https://csggis.drdlr.gov.za/server/rest/services/Property_Viewer/MapServer
/// Layer 2 = Erven (property parcels with polygons)
///
/// **Transport**: the CSG server is self-hosted by DALRRD and returns no
/// `Access-Control-Allow-Origin` header, so a browser blocks every direct
/// response ("Failed to fetch") no matter how the request is formed. On web
/// the query therefore goes through the `csgQuery` callable, which fetches
/// server-side where CORS does not apply. Native builds call CSG directly.
///
/// **Latency**: this server is slow and does not cache — every query, large
/// or small, measures at roughly 35-45 seconds. Callers must show progress
/// and must not fire queries on keystroke.
class CsgPropertyService {
  static const String _baseUrl =
      'https://csggis.dlrrd.gov.za/server/rest/services/Property_Viewer/MapServer';

  /// Layer 2 — cadastral parcels with polygon geometry.
  static const int _ervenLayerId = 2;

  /// Layer 1 — "Allotment Township", the suburb/township layer. Searching
  /// suburbs here rather than by DISTINCT over the national Erven table is
  /// the difference between querying a small lookup layer and scanning every
  /// parcel in the country.
  static const int _townshipLayerId = 1;
  static const int _maxRecords = 2000;

  /// Parcels requested per page.
  ///
  /// A full 2000-parcel page of polygons is several megabytes of JSON, which
  /// is fine over a direct connection but has to fit in a callable's response
  /// when proxied — so the proxied path pages in smaller bites.
  int get _pageSize => useProxy ? 1000 : _maxRecords;

  /// Whether the last feature query hit the server's page limit. ArcGIS
  /// reports this explicitly, which is more reliable than inferring "a full
  /// page means there is more".
  bool _lastExceededTransferLimit = false;

  /// Overridable so tests and native builds can bypass the proxy.
  final bool useProxy;
  final FirebaseFunctions _functions;

  CsgPropertyService({
    bool? useProxy,
    FirebaseFunctions? functions,
  })  : useProxy = useProxy ?? kIsWeb,
        _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

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
      'resultRecordCount': '$_pageSize',
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
      'resultRecordCount': '$_pageSize',
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
    bool Function()? shouldStop,
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
      hasMore = _lastExceededTransferLimit && batch.isNotEmpty;

      onProgress?.call(allProperties.length, hasMore);

      // Let the caller stop between pages. A download runs for minutes, so
      // abandoning it must not mean waiting for the whole thing.
      if (shouldStop?.call() ?? false) break;

      // Small delay between paginated requests
      if (hasMore) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    return allProperties;
  }

  /// Every TAG_VALUE spelling a pasted ERF number could appear under.
  ///
  /// The register writes the remainder of a subdivided erf as "RE/1234", so
  /// a bare "1234" has to look for both. Anything already carrying the
  /// prefix is searched as written.
  static Set<String> erfNumberVariants(String erfNumber) {
    final value = erfNumber.trim();
    if (value.isEmpty) return const {};
    if (value.toUpperCase().startsWith('RE/')) return {value.toUpperCase()};
    return {value, 'RE/$value'};
  }

  /// The numeric core of a TAG_VALUE, so "RE/1234" and "1234" share a key.
  static String normaliseErfNumber(String tagValue) {
    var value = tagValue.trim().toUpperCase();
    if (value.startsWith('RE/')) value = value.substring(3);
    return value;
  }

  /// Search for suburbs/townships whose name starts with or contains
  /// [query] (e.g. "constantia").
  ///
  /// This is what makes any South African suburb downloadable rather than
  /// only the handful with hard-coded bounding boxes: the township layer's
  /// TOWN_CODE is the same value as a parcel's MIN_CODE, which is the key
  /// [queryAllByMinCode] downloads by.
  ///
  /// A prefix match is tried first because it can use an index; only if that
  /// finds nothing does it fall back to the slower contains-match. Expect
  /// tens of seconds either way.
  Future<List<CsgRegion>> searchRegions(String query) async {
    final term = query.trim().toUpperCase().replaceAll("'", "''");
    if (term.isEmpty) return [];

    var regions = await _queryTownships("TAG_VALUE LIKE '$term%'");
    if (regions.isEmpty) {
      regions = await _queryTownships("TAG_VALUE LIKE '%$term%'");
    }
    return regions;
  }

  Future<List<CsgRegion>> _queryTownships(String where) async {
    final attrs = await _executeAttributeQuery(
      {
        'where': where,
        'outFields': 'TAG_VALUE,TOWN_CODE',
        'returnGeometry': 'false',
        'resultRecordCount': '200',
        'f': 'json',
      },
      layerId: _townshipLayerId,
    );
    if (attrs == null) return [];

    // The layer holds one row per township polygon, so a suburb split across
    // several polygons repeats. Collapse on the code that identifies it.
    final seen = <String>{};
    final regions = <CsgRegion>[];
    for (final a in attrs) {
      final name = (a['TAG_VALUE'] as String? ?? '').trim();
      final code = (a['TOWN_CODE'] as String? ?? '').trim();
      if (name.isEmpty || code.isEmpty) continue;
      if (!seen.add('$code|$name')) continue;

      // MAJ_REGION and PROVINCE are not on this layer; they arrive with the
      // parcels themselves and are filled in once a download completes.
      regions.add(CsgRegion(
        minRegion: name,
        minCode: code,
        majRegion: '',
        majCode: '',
        province: '',
      ));
    }
    regions.sort((a, b) => a.minRegion.compareTo(b.minRegion));
    return regions;
  }

  /// Suburb/township boundaries intersecting a map view.
  ///
  /// Fast — this layer is small compared with the parcel table — so it can be
  /// refreshed as the user pans. Parts of the same suburb are merged, since
  /// the layer stores one row per polygon.
  Future<List<CsgTownship>> queryTownshipsInBounds({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
  }) async {
    final data = await _requestJson({
      'geometry': json.encode({
        'xmin': minLng,
        'ymin': minLat,
        'xmax': maxLng,
        'ymax': maxLat,
      }),
      'geometryType': 'esriGeometryEnvelope',
      'inSR': '4326',
      'spatialRel': 'esriSpatialRelIntersects',
      'outFields': 'TAG_VALUE,TOWN_CODE',
      'returnGeometry': 'true',
      'outSR': '4326',
      'resultRecordCount': '$_pageSize',
      'f': 'json',
    }, layerId: _townshipLayerId);

    if (data.containsKey('error')) {
      throw CsgException('CSG rejected the suburb query: ${data['error']}');
    }

    final merged = <String, CsgTownship>{};
    for (final feature in (data['features'] as List<dynamic>? ?? const [])) {
      final township =
          CsgTownship.fromFeature(Map<String, dynamic>.from(feature as Map));
      if (township.name.isEmpty || !township.hasGeometry) continue;

      final key = '${township.code}|${township.name}';
      final existing = merged[key];
      merged[key] = existing == null ? township : existing.mergedWith(township);
    }

    final townships = merged.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return townships;
  }

  /// Fetch a suburb's complete boundary by its code.
  ///
  /// [queryTownshipsInBounds] only returns the parts that intersect the map
  /// view, and a suburb is often several polygons — Constantia is two. Using
  /// the visible parts alone would silently scope a download to a fraction
  /// of the suburb, so the picker re-fetches the whole boundary by code
  /// before counting or downloading.
  Future<CsgTownship?> fetchTownshipByCode({
    required String code,
    required String name,
  }) async {
    final clauses = <String>[];
    if (code.isNotEmpty) {
      clauses.add("TOWN_CODE = '${code.replaceAll("'", "''")}'");
    }
    if (name.isNotEmpty) {
      clauses.add("TAG_VALUE = '${name.replaceAll("'", "''")}'");
    }
    if (clauses.isEmpty) return null;

    final data = await _requestJson({
      'where': clauses.join(' AND '),
      'outFields': 'TAG_VALUE,TOWN_CODE',
      'returnGeometry': 'true',
      'outSR': '4326',
      'resultRecordCount': '$_pageSize',
      'f': 'json',
    }, layerId: _townshipLayerId);

    if (data.containsKey('error')) {
      throw CsgException('CSG rejected the suburb query: ${data['error']}');
    }

    CsgTownship? merged;
    for (final feature in (data['features'] as List<dynamic>? ?? const [])) {
      final part =
          CsgTownship.fromFeature(Map<String, dynamic>.from(feature as Map));
      if (!part.hasGeometry) continue;
      merged = merged == null ? part : merged.mergedWith(part);
    }
    return merged;
  }

  /// How many parcels fall inside a suburb boundary.
  Future<int> countByPolygon(CsgTownship township) {
    return _count(_polygonFilter(township));
  }

  /// Fetch every parcel inside a suburb boundary, paginating until done.
  ///
  /// This is the download path that actually works for Cape Town: the
  /// suburb's own polygon, not its cadastral minor region, which there
  /// covers the entire metro.
  Future<List<ErfProperty>> queryAllByPolygon({
    required CsgTownship township,
    void Function(int loaded, bool hasMore)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final all = <ErfProperty>[];
    var offset = 0;
    var hasMore = true;
    final filter = _polygonFilter(township);

    while (hasMore) {
      final batch = await _executeQuery({
        ...filter,
        'outFields': _outFields,
        'returnGeometry': 'true',
        'outSR': '4326',
        'f': 'json',
        'resultRecordCount': '$_pageSize',
        'resultOffset': '$offset',
      });

      all.addAll(batch);
      offset += batch.length;
      hasMore = _lastExceededTransferLimit && batch.isNotEmpty;

      onProgress?.call(all.length, hasMore);

      if (shouldStop?.call() ?? false) break;

      if (hasMore) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    return all;
  }

  /// Spatial filter for a suburb boundary.
  ///
  /// `Intersects` rather than `Contains`: a parcel straddling the boundary is
  /// still a property in that street, and missing it would be worse than
  /// including a neighbour's. Measured on Tamboerskloof, the difference is
  /// 941 parcels versus 910.
  Map<String, String> _polygonFilter(CsgTownship township) => {
        'geometry': township.toEsriPolygonJson(),
        'geometryType': 'esriGeometryPolygon',
        'inSR': '4326',
        'spatialRel': 'esriSpatialRelIntersects',
      };

  /// How many parcels a cadastral region holds.
  ///
  /// Cheap and fast even where the download is enormous, so callers can warn
  /// before committing. This matters more than it looks: cadastral minor
  /// regions are suburbs in some provinces but whole metros in others —
  /// "CAPE TOWN" is a single minor region of about 120,000 parcels.
  Future<int> countByMinCode(String minCode) async {
    return _count({
      'where': "MIN_CODE = '${minCode.replaceAll("'", "''")}'",
    });
  }

  /// How many parcels intersect a bounding box.
  Future<int> countByBoundingBox({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
  }) async {
    return _count({
      'geometry': json.encode({
        'xmin': minLng,
        'ymin': minLat,
        'xmax': maxLng,
        'ymax': maxLat,
      }),
      'geometryType': 'esriGeometryEnvelope',
      'inSR': '4326',
      'spatialRel': 'esriSpatialRelIntersects',
    });
  }

  Future<int> _count(Map<String, String> where) async {
    final data = await _requestJson({
      ...where,
      'returnCountOnly': 'true',
      'returnGeometry': 'false',
      'f': 'json',
    });
    if (data.containsKey('error')) {
      throw CsgException('CSG rejected the count query: ${data['error']}');
    }
    return (data['count'] as num?)?.toInt() ?? 0;
  }

  /// Fetch every parcel in a cadastral region, paginating until the server
  /// stops returning full pages.
  Future<List<ErfProperty>> queryAllByMinCode({
    required String minCode,
    void Function(int loaded, bool hasMore)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final all = <ErfProperty>[];
    var offset = 0;
    var hasMore = true;

    while (hasMore) {
      final batch = await queryByMinCode(minCode: minCode, resultOffset: offset);
      all.addAll(batch);
      offset += batch.length;
      hasMore = _lastExceededTransferLimit && batch.isNotEmpty;

      onProgress?.call(all.length, hasMore);

      if (shouldStop?.call() ?? false) break;

      if (hasMore) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    return all;
  }

  /// Look up parcels by their ERF number (TAG_VALUE).
  ///
  /// ERF numbers repeat across suburbs, so pass [minCode] whenever the
  /// suburb is known — without it a number like "1234" matches parcels all
  /// over the country and the caller has to disambiguate.
  ///
  /// [erfNumbers] is chunked so the generated `IN (...)` clause stays within
  /// the server's URL and expression limits.
  Future<List<ErfProperty>> queryByErfNumbers({
    required List<String> erfNumbers,
    String? minCode,
    String? majCode,
    ErfSearchScope scope = ErfSearchScope.southAfrica,
    void Function(int loaded, int total)? onProgress,
  }) async {
    final unique = erfNumbers
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (unique.isEmpty) return [];

    const chunkSize = 100;
    final results = <ErfProperty>[];

    for (var i = 0; i < unique.length; i += chunkSize) {
      final end =
          (i + chunkSize < unique.length) ? i + chunkSize : unique.length;
      final chunk = unique.sublist(i, end);
      // A pasted "4673" must also find "RE/4673" — about one in seven Cape
      // Town parcels is a Remainder, whose TAG_VALUE carries that prefix.
      final variants = <String>{
        for (final value in chunk) ...erfNumberVariants(value),
      };
      final inList =
          variants.map((e) => "'${e.replaceAll("'", "''")}'").join(',');

      final clauses = <String>["TAG_VALUE IN ($inList)"];
      if (minCode != null && minCode.isNotEmpty) {
        clauses.add("MIN_CODE = '${minCode.replaceAll("'", "''")}'");
      }
      if (majCode != null && majCode.isNotEmpty) {
        clauses.add("MAJ_CODE = '${majCode.replaceAll("'", "''")}'");
      }

      // Keep the register from offering an ERF 1234 in Gauteng when the work
      // is in Cape Town. Skipped when the caller already pinned a region.
      if (minCode == null || minCode.isEmpty) {
        final scopeMajCode = scope.majCode;
        final scopeProvince = scope.province;
        if (scopeMajCode != null && (majCode == null || majCode.isEmpty)) {
          clauses.add("MAJ_CODE = '$scopeMajCode'");
        } else if (scopeProvince != null) {
          clauses.add("PROVINCE = '$scopeProvince'");
        }
      }

      results.addAll(await _executeQuery({
        'where': clauses.join(' AND '),
        'outFields': _outFields,
        'returnGeometry': 'true',
        'outSR': '4326',
        'f': 'json',
        'resultRecordCount': '$_pageSize',
      }));

      onProgress?.call(end, unique.length);

      if (end < unique.length) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    return results;
  }

  /// Run a query that wants attributes only, returning null when the server
  /// *rejects the query itself* so the caller can retry with a simpler form.
  ///
  /// Transport failures are not swallowed — those rethrow, because retrying a
  /// simpler query against an unreachable server is pointless and would hide
  /// the real problem.
  Future<List<Map<String, dynamic>>?> _executeAttributeQuery(
    Map<String, String> params, {
    int layerId = _ervenLayerId,
  }) async {
    final data = await _requestJson(params, layerId: layerId);

    if (data.containsKey('error')) {
      debugPrint('⚠️ CSG rejected attribute query: ${data['error']}');
      return null;
    }

    final features = data['features'] as List<dynamic>? ?? [];
    return features
        .map((f) => Map<String, dynamic>.from(
            (f as Map)['attributes'] as Map? ?? const {}))
        .toList();
  }

  /// Execute a feature query against the Erven layer.
  Future<List<ErfProperty>> _executeQuery(Map<String, String> params) async {
    final data = await _requestJson(params);
    _lastExceededTransferLimit = data['exceededTransferLimit'] == true;

    if (data.containsKey('error')) {
      final error = data['error'];
      final message = (error is Map ? error['message'] : null) ?? '$error';
      throw CsgException('CSG rejected the query: $message');
    }

    final features = data['features'] as List<dynamic>? ?? [];
    debugPrint('✅ CSG returned ${features.length} features');

    return features
        .map((f) =>
            ErfProperty.fromCsgFeature(Map<String, dynamic>.from(f as Map)))
        .toList();
  }

  /// Fetch one ArcGIS query response, over whichever transport this platform
  /// can actually use.
  ///
  /// Throws [CsgException] when the response cannot be retrieved or parsed.
  /// An ArcGIS-level `error` object is returned intact for the caller to
  /// interpret — a rejected query is not the same failure as a dead server.
  Future<Map<String, dynamic>> _requestJson(
    Map<String, String> params, {
    int layerId = _ervenLayerId,
  }) async {
    if (useProxy) return _requestViaProxy(params, layerId);
    return _requestDirect(params, layerId);
  }

  Future<Map<String, dynamic>> _requestViaProxy(
      Map<String, String> params, int layerId) async {
    try {
      final result = await _functions
          .httpsCallable(
            'csgQuery',
            // The SDK default is 70 seconds, which a 40-second upstream query
            // plus cold start can exceed.
            options: HttpsCallableOptions(timeout: const Duration(minutes: 5)),
          )
          .call<dynamic>({
        'layerId': layerId,
        'params': params,
      });
      final data = result.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const CsgException('CSG proxy returned an unexpected response.');
    } on FirebaseFunctionsException catch (e) {
      debugPrint('❌ CSG proxy error [${e.code}]: ${e.message}');
      throw CsgException(
        e.code == 'unavailable'
            ? 'The CSG cadastral server is not responding. '
                'It is often down for short periods — try again shortly.'
            : 'CSG lookup failed: ${e.message ?? e.code}',
      );
    } catch (e) {
      debugPrint('❌ CSG proxy call failed: $e');
      throw CsgException('CSG lookup failed: $e');
    }
  }

  Future<Map<String, dynamic>> _requestDirect(
      Map<String, String> params, int layerId) async {
    final uri = Uri.parse('$_baseUrl/$layerId/query');

    try {
      // POSTed rather than sent as a query string: a suburb boundary used as
      // a spatial filter runs to hundreds of vertices and overflows the URL
      // length limit, which shows up as a dropped connection.
      final response = await http.post(
        uri,
        headers: const {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {...params, 'f': 'json'},
      ).timeout(const Duration(minutes: 3));

      if (response.statusCode != 200) {
        throw CsgException(
            'CSG server returned HTTP ${response.statusCode}.');
      }

      final decoded = json.decode(response.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const CsgException('CSG returned an unexpected response.');
    } on CsgException {
      rethrow;
    } catch (e) {
      debugPrint('❌ CSG direct request failed: $e');
      throw CsgException('Could not reach the CSG server: $e');
    }
  }
}
