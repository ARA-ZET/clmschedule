// Stub for non-web platforms. The web implementation lives in
// geocoding_web.dart and is selected via conditional import. On mobile and
// desktop the REST Geocoding API works directly, so this always defers.

import '../models/geocode_detail.dart';

class WebGeocodeOutcome {
  final GeocodeDetail? detail;
  final String? status;

  const WebGeocodeOutcome({this.detail, this.status});

  bool get helperUnavailable => status == null;
}

Future<WebGeocodeOutcome> geocodeDetailedWeb(
  String address, {
  String regionCode = '',
  Map<String, double>? bounds,
}) async =>
    const WebGeocodeOutcome();

Future<Map<String, double>?> geocodeAddressWeb(String address) async => null;

Future<({String? suburb, bool helperUnavailable})> reverseSuburbWeb(
  double lat,
  double lng,
) async =>
    (suburb: null, helperUnavailable: true);
