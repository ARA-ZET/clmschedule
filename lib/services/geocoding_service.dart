import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../env.dart';
import '../models/geocode_detail.dart';
import 'geocoding_web_stub.dart'
    if (dart.library.js_interop) 'geocoding_web.dart' as web_geocoding;

/// Progress report for a batch geocode run.
class GeocodeProgress {
  final int completed;
  final int total;
  final int succeeded;
  final int failed;

  /// The address string that just finished, for a live status line.
  final String lastAddress;

  const GeocodeProgress({
    required this.completed,
    required this.total,
    required this.succeeded,
    required this.failed,
    required this.lastAddress,
  });

  double get fraction => total == 0 ? 0 : completed / total;
}

/// One entry of a batch geocode result, keyed back to the input index.
class GeocodeBatchEntry {
  final int index;
  final String address;
  final GeocodeDetail? detail;
  final String? error;

  const GeocodeBatchEntry({
    required this.index,
    required this.address,
    this.detail,
    this.error,
  });

  bool get success => detail != null;
}

/// Cooperative cancel token — a long batch has to be abandonable without
/// leaving the caller's progress UI stranded.
class GeocodeCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Service for geocoding addresses using the Google Geocoding API.
///
/// On web the REST endpoint is blocked by CORS, so lookups go through the
/// Maps JS Geocoder (see geocoding_web.dart) and fall back to REST only if
/// the JS helper never loaded.
class GeocodingService {
  static const String _baseUrl =
      'https://maps.googleapis.com/maps/api/geocode/json';

  /// Per-process memo of address string → result. Re-running a batch after
  /// fixing three bad rows should not re-bill the other three hundred.
  static final Map<String, GeocodeDetail> _memo = {};

  /// Requests in flight at once during a batch. Google's published ceiling
  /// is ~50 QPS; 6 keeps a comfortable margin while being roughly an order
  /// of magnitude faster than the old strictly-sequential loop.
  static const int defaultConcurrency = 6;

  /// A single lookup gets this long before it is treated as failed. The
  /// JS helper has its own internal timeout; this is the belt-and-braces
  /// guard so no caller can ever await forever.
  static const Duration lookupTimeout = Duration(seconds: 25);

  /// Region bias (ccTLD) applied to web lookups.
  final String regionCode;

  /// Optional viewport bias as `{south, west, north, east}`.
  final Map<String, double>? bounds;

  GeocodingService({this.regionCode = 'za', this.bounds});

  /// Clear the in-process memo (e.g. after correcting address text).
  static void clearCache() => _memo.clear();

  /// Geocode an address string, returning the full match detail.
  Future<GeocodeDetail?> geocodeDetailed(String address) async {
    final key = address.trim().toLowerCase();
    if (key.isEmpty) return null;

    final memoed = _memo[key];
    if (memoed != null) return memoed;

    try {
      final detail = await _lookup(address).timeout(lookupTimeout);
      if (detail != null) _memo[key] = detail;
      return detail;
    } on TimeoutException {
      debugPrint('⏱️ Geocoding timed out: $address');
      return null;
    }
  }

  Future<GeocodeDetail?> _lookup(String address) async {
    if (kIsWeb) {
      final outcome = await web_geocoding.geocodeDetailedWeb(
        address,
        regionCode: regionCode,
        bounds: bounds,
      );
      if (outcome.detail != null) return outcome.detail;
      // The geocoder answered and had nothing — REST would answer the
      // same, and is CORS-blocked anyway. Only fall through when the JS
      // helper itself was missing.
      if (!outcome.helperUnavailable) return null;
    }
    return _lookupRest(address);
  }

  Future<GeocodeDetail?> _lookupRest(String address) async {
    try {
      final params = <String, String>{
        'address': address,
        'key': Env.googleMapsApiKey,
        if (regionCode.isNotEmpty) 'region': regionCode,
        if (bounds != null)
          'bounds': '${bounds!['south']},${bounds!['west']}'
              '|${bounds!['north']},${bounds!['east']}',
      };
      final url = Uri.parse(_baseUrl).replace(queryParameters: params);

      final response = await http.get(url);
      if (response.statusCode != 200) {
        debugPrint('❌ Geocoding HTTP error: ${response.statusCode}');
        return null;
      }

      final data = json.decode(response.body);
      final results = data['results'] as List?;
      if (data['status'] != 'OK' || results == null || results.isEmpty) {
        debugPrint('⚠️ Geocoding failed: ${data['status']} for $address');
        return null;
      }

      final first = results.first as Map<String, dynamic>;
      final geometry = first['geometry'] as Map<String, dynamic>;
      final location = geometry['location'] as Map<String, dynamic>;

      return GeocodeDetail(
        latitude: (location['lat'] as num).toDouble(),
        longitude: (location['lng'] as num).toDouble(),
        formattedAddress: first['formatted_address'] as String? ?? '',
        locationType: geometry['location_type'] as String? ?? '',
        partialMatch: first['partial_match'] == true,
        placeId: first['place_id'] as String? ?? '',
        types: ((first['types'] as List?) ?? const []).join(','),
      );
    } catch (e) {
      debugPrint('❌ Geocoding error: $e');
      return null;
    }
  }

  static final Map<String, String?> _suburbMemo = {};

  /// The suburb at a coordinate — the most specific place name Google gives
  /// ("Bellville Central", "Retreat"), falling back through neighbourhood and
  /// broader sublocality to the city. Null when nothing usable came back.
  Future<String?> suburbAt(double lat, double lng) async {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    if (_suburbMemo.containsKey(key)) return _suburbMemo[key];
    try {
      String? suburb;
      var tryRest = true;
      if (kIsWeb) {
        final web = await web_geocoding
            .reverseSuburbWeb(lat, lng)
            .timeout(lookupTimeout);
        suburb = web.suburb;
        tryRest = web.helperUnavailable;
      }
      if (tryRest && suburb == null) suburb = await _suburbRest(lat, lng);
      _suburbMemo[key] = suburb;
      return suburb;
    } on TimeoutException {
      return null;
    }
  }

  Future<String?> _suburbRest(double lat, double lng) async {
    try {
      final url = Uri.parse(_baseUrl).replace(queryParameters: {
        'latlng': '$lat,$lng',
        'key': Env.googleMapsApiKey,
      });
      final response = await http.get(url);
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List?;
      if (data['status'] != 'OK' || results == null || results.isEmpty) {
        return null;
      }
      final comps = ((results.first as Map)['address_components'] as List?) ??
          const [];
      for (final type in const [
        'sublocality_level_2',
        'neighborhood',
        'sublocality_level_1',
        'locality',
      ]) {
        for (final c in comps) {
          if (((c as Map)['types'] as List).contains(type)) {
            return c['long_name'] as String?;
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('❌ Reverse geocoding error: $e');
      return null;
    }
  }

  /// Geocode an address to bare coordinates.
  ///
  /// Kept for the existing dropsheet/ERF call sites; new code should
  /// prefer [geocodeDetailed] so precision can be surfaced.
  Future<Map<String, double>?> geocodeAddress(String address) async {
    final detail = await geocodeDetailed(address);
    return detail?.latLng;
  }

  /// Geocode many addresses with bounded concurrency.
  ///
  /// Results come back in input order regardless of completion order, so
  /// the caller can zip them straight back onto its own list. [onProgress]
  /// fires after every lookup; [cancelToken] stops the run at the next
  /// slot boundary and returns whatever finished.
  Future<List<GeocodeBatchEntry>> batchGeocodeDetailed(
    List<String> addresses, {
    int concurrency = defaultConcurrency,
    void Function(GeocodeProgress progress)? onProgress,
    GeocodeCancelToken? cancelToken,
  }) async {
    final results = List<GeocodeBatchEntry?>.filled(addresses.length, null);
    var next = 0;
    var completed = 0;
    var succeeded = 0;
    var failed = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken?.isCancelled ?? false) return;
        final i = next;
        if (i >= addresses.length) return;
        next++;

        final address = addresses[i];
        GeocodeDetail? detail;
        String? error;
        if (address.trim().isEmpty) {
          error = 'Empty address';
        } else {
          detail = await geocodeDetailed(address);
          if (detail == null) error = 'No match found';
        }

        results[i] = GeocodeBatchEntry(
          index: i,
          address: address,
          detail: detail,
          error: error,
        );

        completed++;
        if (detail != null) {
          succeeded++;
        } else {
          failed++;
        }
        onProgress?.call(GeocodeProgress(
          completed: completed,
          total: addresses.length,
          succeeded: succeeded,
          failed: failed,
          lastAddress: address,
        ));
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, addresses.isEmpty ? 1 : addresses.length),
      (_) => worker(),
    );
    await Future.wait(workers);

    return [
      for (var i = 0; i < results.length; i++)
        results[i] ??
            GeocodeBatchEntry(
              index: i,
              address: addresses[i],
              error: 'Cancelled',
            ),
    ];
  }

  /// Batch geocode returning the legacy `{address, index, result, success}`
  /// shape used by older call sites.
  Future<List<Map<String, dynamic>>> batchGeocode(
    List<String> addresses, {
    Duration delay = const Duration(milliseconds: 200),
    Function(int current, int total)? onProgress,
  }) async {
    final entries = await batchGeocodeDetailed(
      addresses,
      onProgress: (p) => onProgress?.call(p.completed, p.total),
    );
    return entries
        .map((e) => {
              'address': e.address,
              'index': e.index,
              'result': e.detail?.latLng,
              'success': e.success,
            })
        .toList();
  }
}
