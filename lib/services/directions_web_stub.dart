// Stub for non-web platforms. The web implementation lives in
// directions_web.dart and is selected via conditional import.

import '../models/address.dart';
import '../models/route_data.dart';

Future<RouteSegmentData?> getRouteSegmentWeb(
  Address from,
  Address to, {
  DateTime? departureTime,
}) async =>
    null;
