// Web implementation calling the Google Maps JS Geocoder via JS interop.
// The REST Geocoding API sends no CORS headers, so a browser request to it is
// blocked outright — mirroring directions_web.dart, we go through the JS API
// instead so geocoding works on web.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import '../models/geocode_detail.dart';

@JS('reverseGeocodeSuburbJs')
external JSPromise<JSObject?> _reverseGeocodeSuburbJs(JSNumber lat, JSNumber lng);

/// Suburb at a coordinate through the Maps JS API. `helperUnavailable` means
/// the JS helper never answered and a REST lookup is worth trying instead.
Future<({String? suburb, bool helperUnavailable})> reverseSuburbWeb(
  double lat,
  double lng,
) async {
  try {
    final result = await _reverseGeocodeSuburbJs(lat.toJS, lng.toJS).toDart;
    if (result == null) return (suburb: null, helperUnavailable: true);
    final ok = (result.getProperty('ok'.toJS) as JSBoolean?)?.toDart ?? false;
    if (!ok) return (suburb: null, helperUnavailable: false);
    return (
      suburb: (result.getProperty('suburb'.toJS) as JSString?)?.toDart,
      helperUnavailable: false,
    );
  } catch (e) {
    debugPrint('Web reverse geocode failed: $e');
    return (suburb: null, helperUnavailable: true);
  }
}

@JS('geocodeAddressJs')
external JSPromise<JSObject?> _geocodeAddressJs(
  JSString address,
  JSString regionCode,
  JSString boundsJson,
);

/// Outcome of a web geocode call, distinguishing "the geocoder answered
/// and found nothing" from "the geocoder was not reachable" — only the
/// latter is worth retrying through the REST path.
class WebGeocodeOutcome {
  final GeocodeDetail? detail;

  /// Raw Google geocoder status (ZERO_RESULTS, OVER_QUERY_LIMIT, …), or
  /// null when the JS helper itself was unavailable.
  final String? status;

  const WebGeocodeOutcome({this.detail, this.status});

  bool get helperUnavailable => status == null;
}

/// Geocode [address] through the Maps JS API.
///
/// [regionCode] is an ccTLD bias (e.g. `za`) and [bounds] a viewport bias
/// as `{south, west, north, east}` — both narrow an ambiguous street name
/// to the area actually being delivered to.
Future<WebGeocodeOutcome> geocodeDetailedWeb(
  String address, {
  String regionCode = '',
  Map<String, double>? bounds,
}) async {
  try {
    final boundsJson = bounds == null ? '' : jsonEncode(bounds);
    final result = await _geocodeAddressJs(
      address.toJS,
      regionCode.toJS,
      boundsJson.toJS,
    ).toDart;

    if (result == null) {
      debugPrint('Web geocode: helper unavailable for "$address"');
      return const WebGeocodeOutcome();
    }

    final status =
        (result.getProperty('status'.toJS) as JSString?)?.toDart ?? 'UNKNOWN';
    final ok = (result.getProperty('ok'.toJS) as JSBoolean?)?.toDart ?? false;
    if (!ok) {
      debugPrint('Web geocode: $status for "$address"');
      return WebGeocodeOutcome(status: status);
    }

    return WebGeocodeOutcome(
      status: status,
      detail: GeocodeDetail(
        latitude: (result.getProperty('lat'.toJS) as JSNumber).toDartDouble,
        longitude: (result.getProperty('lng'.toJS) as JSNumber).toDartDouble,
        formattedAddress:
            (result.getProperty('formattedAddress'.toJS) as JSString?)?.toDart ??
                '',
        locationType:
            (result.getProperty('locationType'.toJS) as JSString?)?.toDart ?? '',
        partialMatch:
            (result.getProperty('partialMatch'.toJS) as JSBoolean?)?.toDart ??
                false,
        placeId: (result.getProperty('placeId'.toJS) as JSString?)?.toDart ?? '',
        types: (result.getProperty('types'.toJS) as JSString?)?.toDart ?? '',
      ),
    );
  } catch (e) {
    // Thrown when places_helper.js hasn't loaded yet (window.geocodeAddressJs
    // undefined) — the caller falls back to the REST path.
    debugPrint('Web geocode failed for "$address": $e');
    return const WebGeocodeOutcome();
  }
}

/// Returns `{'lat': …, 'lng': …}` for [address], or null if the lookup fails.
Future<Map<String, double>?> geocodeAddressWeb(String address) async {
  final outcome = await geocodeDetailedWeb(address);
  return outcome.detail?.latLng;
}
