import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../env.dart';
import '../models/address.dart';
import '../models/route_data.dart';
import '../utils/polyline_codec.dart';
import 'directions_web_stub.dart'
    if (dart.library.js_interop) 'directions_web.dart' as web_directions;
import 'route_optimization_service.dart';

/// How the stop order is decided.
enum RouteAlgorithm {
  /// Keep the list exactly as the user arranged it; only fetch the roads.
  keepOrder,

  /// Greedy nearest-neighbour on straight-line distance. Fast, no API cost.
  nearestNeighbour,

  /// Nearest-neighbour seed improved by 2-opt. Still straight-line, but
  /// removes the crossings the greedy pass leaves behind.
  twoOpt,

  /// 2-opt seed, then hand each chunk to Google's own waypoint optimiser
  /// so the final order is decided on real road distances.
  googleOptimized;

  String get label => switch (this) {
        RouteAlgorithm.keepOrder => 'Manual order',
        RouteAlgorithm.nearestNeighbour => 'Nearest neighbour',
        RouteAlgorithm.twoOpt => '2-opt',
        RouteAlgorithm.googleOptimized => 'Google road-optimised',
      };

  String get description => switch (this) {
        RouteAlgorithm.keepOrder =>
          'Drive the stops in the order shown and just measure the roads.',
        RouteAlgorithm.nearestNeighbour =>
          'Always hop to the closest unvisited stop. Instant, no API cost.',
        RouteAlgorithm.twoOpt =>
          'Untangles crossing legs after the greedy pass. Still instant.',
        RouteAlgorithm.googleOptimized =>
          'Best results: Google reorders using real driving distances.',
      };

  /// Whether the ordering step itself needs the Directions API.
  bool get needsNetwork => this == RouteAlgorithm.googleOptimized;
}

/// Sentinel for [RoutePlanOptions.copyWith] — distinguishes "leave this
/// alone" from "set it to null".
const Object _keep = Object();

/// Everything the planner needs beyond the stop list itself.
class RoutePlanOptions {
  /// Where the run starts. When null the first delivery is the start.
  final Address? depot;

  /// Finish back at [depot] (or the first stop) after the last delivery.
  final bool returnToStart;

  /// When the vehicle rolls out. Drives both the traffic model and the
  /// per-stop ETAs.
  final DateTime? departAt;

  /// Time spent at each delivery before moving on.
  final Duration serviceTimePerStop;

  final RouteAlgorithm algorithm;

  /// Ask Google for traffic-aware durations at [departAt].
  final bool useTraffic;

  const RoutePlanOptions({
    this.depot,
    this.returnToStart = false,
    this.departAt,
    this.serviceTimePerStop = const Duration(minutes: 5),
    this.algorithm = RouteAlgorithm.googleOptimized,
    this.useTraffic = true,
  });

  /// Omitted fields are preserved; pass an explicit `null` to clear
  /// [depot] or [departAt].
  RoutePlanOptions copyWith({
    Object? depot = _keep,
    bool? returnToStart,
    Object? departAt = _keep,
    Duration? serviceTimePerStop,
    RouteAlgorithm? algorithm,
    bool? useTraffic,
  }) {
    return RoutePlanOptions(
      depot: identical(depot, _keep) ? this.depot : depot as Address?,
      returnToStart: returnToStart ?? this.returnToStart,
      departAt: identical(departAt, _keep) ? this.departAt : departAt as DateTime?,
      serviceTimePerStop: serviceTimePerStop ?? this.serviceTimePerStop,
      algorithm: algorithm ?? this.algorithm,
      useTraffic: useTraffic ?? this.useTraffic,
    );
  }
}

/// One stop in a planned route, with the leg that reaches it.
class PlannedStop {
  final Address address;

  /// 1-based position in the run. The depot, when present, is stop 0.
  final int sequence;

  /// True for the start point when it is not itself a delivery.
  final bool isDepot;

  final double legDistanceMeters;
  final int legDurationSeconds;
  final int legDurationInTrafficSeconds;

  /// Road geometry from the previous stop to this one.
  final List<LatLng> pathFromPrevious;

  final double cumulativeDistanceMeters;
  final int cumulativeDrivingSeconds;

  final DateTime? arrival;
  final DateTime? departure;

  const PlannedStop({
    required this.address,
    required this.sequence,
    required this.isDepot,
    required this.legDistanceMeters,
    required this.legDurationSeconds,
    required this.legDurationInTrafficSeconds,
    required this.pathFromPrevious,
    required this.cumulativeDistanceMeters,
    required this.cumulativeDrivingSeconds,
    this.arrival,
    this.departure,
  });

  double get legDistanceKm => legDistanceMeters / 1000;
  double get cumulativeDistanceKm => cumulativeDistanceMeters / 1000;

  String get legDurationFormatted => formatDuration(legDurationSeconds);
  String get cumulativeDurationFormatted =>
      formatDuration(cumulativeDrivingSeconds);
}

/// A fully costed route: order, road geometry, distances and ETAs.
class PlannedRoute {
  final List<PlannedStop> stops;

  /// The leg back to the start when [RoutePlanOptions.returnToStart] is on.
  final PlannedStop? returnLeg;

  final double totalDistanceMeters;
  final int totalDrivingSeconds;
  final int totalServiceSeconds;

  /// False when the Directions API was unreachable and the numbers are
  /// straight-line estimates. Surfaced in the UI so nobody plans a day
  /// around a crow-flies figure by mistake.
  final bool usedRealRoads;

  final RouteAlgorithm algorithm;
  final RoutePlanOptions options;
  final DateTime plannedAt;

  /// Human-readable note about any degradation (fallbacks, truncation).
  final String? warning;

  const PlannedRoute({
    required this.stops,
    required this.totalDistanceMeters,
    required this.totalDrivingSeconds,
    required this.totalServiceSeconds,
    required this.usedRealRoads,
    required this.algorithm,
    required this.options,
    required this.plannedAt,
    this.returnLeg,
    this.warning,
  });

  /// Delivery stops only — the depot is excluded.
  List<PlannedStop> get deliveryStops =>
      stops.where((s) => !s.isDepot).toList(growable: false);

  List<Address> get orderedAddresses =>
      stops.map((s) => s.address).toList(growable: false);

  double get totalDistanceKm => totalDistanceMeters / 1000;

  int get totalElapsedSeconds => totalDrivingSeconds + totalServiceSeconds;

  String get totalDistanceFormatted =>
      '${totalDistanceKm.toStringAsFixed(1)} km';
  String get totalDrivingFormatted => formatDuration(totalDrivingSeconds);
  String get totalElapsedFormatted => formatDuration(totalElapsedSeconds);

  DateTime? get finishTime {
    final last = returnLeg ?? (stops.isEmpty ? null : stops.last);
    return last?.arrival ?? last?.departure;
  }

  /// Every leg's geometry, start to finish, as one continuous path.
  List<LatLng> get fullPath => [
        for (final s in stops) ...s.pathFromPrevious,
        if (returnLeg != null) ...returnLeg!.pathFromPrevious,
      ];

  /// Rebuild a route from the Firestore cache.
  ///
  /// Reopening a suburb should show the run exactly as it was last
  /// planned, without spending another Directions request. [ordered] must
  /// already be in drive order (sorted by `routeIndex`); segments are
  /// matched to it positionally, and a trailing extra segment is read as
  /// the leg home.
  ///
  /// Returns null when the cache and the address list have drifted apart
  /// — better to show no route than a route whose legs belong to stops
  /// that are no longer there.
  static PlannedRoute? fromCache(
    List<Address> ordered,
    SuburbRouteData? cached, {
    Address? depot,
    Duration serviceTimePerStop = const Duration(minutes: 5),
  }) {
    if (ordered.length < 2) return null;

    final segments = cached?.segments ?? const <RouteSegmentData>[];

    // Whether the cached legs still describe *this* list of stops.
    //
    // The stop order and the road measurements are stored separately and
    // age separately: the order lives on each address as `routeIndex` and
    // survives anything, while the segments go stale the moment a stop is
    // added or removed. When they disagree the order is still good, so the
    // run is restored without distances rather than discarded — throwing
    // away a confirmed delivery order because its mileage is stale would
    // force a re-optimise, which is the one thing that must not happen
    // silently.
    final straightRun = segments.length == ordered.length - 1;
    // A round trip is identified by its closing leg landing back on the
    // first stop, not by the count alone — after a deletion the counts
    // coincidentally line up and a one-way run would be misread as
    // returning home, inventing a leg nobody planned.
    final roundTrip = segments.length == ordered.length &&
        segments.isNotEmpty &&
        segments.last.toAddressId == ordered.first.id;
    final legsUsable = straightRun || roundTrip;
    final hasReturnLeg = roundTrip;

    if (!legsUsable && segments.isNotEmpty) {
      debugPrint('Route cache for ${cached?.suburb} has ${segments.length} '
          'legs for ${ordered.length} stops — keeping the saved order and '
          'dropping the stale distances');
    }

    final hasDepot = depot != null && ordered.first.id == depot.id;
    final stops = <PlannedStop>[];
    var cumulativeDistance = 0.0;
    var cumulativeDriving = 0;

    for (var i = 0; i < ordered.length; i++) {
      final segment = (i == 0 || !legsUsable) ? null : segments[i - 1];
      cumulativeDistance += segment?.distanceMeters ?? 0;
      cumulativeDriving += segment?.durationSeconds ?? 0;

      stops.add(PlannedStop(
        address: ordered[i],
        sequence: hasDepot ? i : i + 1,
        isDepot: hasDepot && i == 0,
        legDistanceMeters: segment?.distanceMeters ?? 0,
        legDurationSeconds: segment?.durationSeconds ?? 0,
        legDurationInTrafficSeconds:
            segment?.durationInTrafficSeconds ?? segment?.durationSeconds ?? 0,
        pathFromPrevious: segment?.polylinePoints ?? const [],
        cumulativeDistanceMeters: cumulativeDistance,
        cumulativeDrivingSeconds: cumulativeDriving,
      ));
    }

    PlannedStop? returnLeg;
    if (hasReturnLeg) {
      final segment = segments.last;
      cumulativeDistance += segment.distanceMeters;
      cumulativeDriving += segment.durationSeconds;
      returnLeg = PlannedStop(
        address: ordered.first,
        sequence: stops.length,
        isDepot: hasDepot,
        legDistanceMeters: segment.distanceMeters,
        legDurationSeconds: segment.durationSeconds,
        legDurationInTrafficSeconds: segment.durationInTrafficSeconds,
        pathFromPrevious: segment.polylinePoints,
        cumulativeDistanceMeters: cumulativeDistance,
        cumulativeDrivingSeconds: cumulativeDriving,
      );
    }

    final algorithm = RouteAlgorithm.values.firstWhere(
      (a) => cached != null && cached.algorithm.startsWith(a.name),
      orElse: () => RouteAlgorithm.keepOrder,
    );
    final deliveryCount = stops.where((s) => !s.isDepot).length;

    return PlannedRoute(
      stops: stops,
      returnLeg: returnLeg,
      totalDistanceMeters: cumulativeDistance,
      totalDrivingSeconds: cumulativeDriving,
      totalServiceSeconds: serviceTimePerStop.inSeconds * deliveryCount,
      usedRealRoads:
          legsUsable && !(cached?.algorithm.endsWith('_estimated') ?? true),
      algorithm: algorithm,
      options: RoutePlanOptions(
        depot: hasDepot ? depot : null,
        returnToStart: hasReturnLeg,
        serviceTimePerStop: serviceTimePerStop,
        algorithm: algorithm,
      ),
      plannedAt: cached?.optimizedAt ?? DateTime.now(),
      warning: legsUsable
          ? null
          : 'Saved delivery order restored. The distances and ETAs are '
              'missing because the list changed since it was measured — '
              're-measure to fill them in without changing the order.',
    );
  }

  /// True when this route carries a stop order but no road measurements —
  /// restored from a saved order whose distances had gone stale.
  bool get needsRemeasure =>
      stops.length > 1 && stops.every((s) => s.legDistanceMeters == 0);

  /// Convert to the legacy [SuburbRouteData] shape for the Firestore cache.
  SuburbRouteData toSuburbRouteData(String suburb) {
    final segments = <RouteSegmentData>[];
    for (var i = 1; i < stops.length; i++) {
      segments.add(RouteSegmentData(
        fromAddressId: stops[i - 1].address.id,
        toAddressId: stops[i].address.id,
        distanceMeters: stops[i].legDistanceMeters,
        durationSeconds: stops[i].legDurationSeconds,
        durationInTrafficSeconds: stops[i].legDurationInTrafficSeconds,
        polylinePoints: stops[i].pathFromPrevious,
      ));
    }
    if (returnLeg != null && stops.isNotEmpty) {
      segments.add(RouteSegmentData(
        fromAddressId: stops.last.address.id,
        toAddressId: stops.first.address.id,
        distanceMeters: returnLeg!.legDistanceMeters,
        durationSeconds: returnLeg!.legDurationSeconds,
        durationInTrafficSeconds: returnLeg!.legDurationInTrafficSeconds,
        polylinePoints: returnLeg!.pathFromPrevious,
      ));
    }

    return SuburbRouteData(
      suburb: suburb,
      algorithm: '${algorithm.name}${usedRealRoads ? '_actual' : '_estimated'}',
      optimizedAt: plannedAt,
      segments: segments,
      totalDistanceMeters: totalDistanceMeters,
      totalDurationSeconds: totalDrivingSeconds,
    );
  }
}

/// Progress from a planning run, for a determinate progress bar.
class RoutePlanProgress {
  final String stage;
  final int completed;
  final int total;

  const RoutePlanProgress(this.stage, this.completed, this.total);

  double? get fraction => total <= 0 ? null : completed / total;
}

/// Cooperative cancellation for a planning run.
class RoutePlanCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Thrown when planning is cancelled; callers treat it as a clean exit.
class RoutePlanCancelled implements Exception {
  const RoutePlanCancelled();
  @override
  String toString() => 'Route planning cancelled';
}

String formatDuration(int seconds) {
  if (seconds <= 0) return '0 min';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0) return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  return '$minutes min';
}

/// Plans a delivery run: decides the stop order, then costs it against
/// real roads.
///
/// The expensive part is the Directions API, and the shape of the calls is
/// what makes or breaks a large run. Asking for every consecutive pair
/// separately costs N−1 round trips and rate-limits into the ground past a
/// few dozen stops; this planner instead sends **chunks of up to 25 stops
/// per request**, which both collapses the call count by ~25× and lets
/// Google reorder each chunk using road distances.
///
/// Every network call is bounded by a timeout and every failure degrades
/// to a straight-line estimate, so a plan always terminates — a caller's
/// progress UI can never be left with nothing to complete it.
class RoutePlannerService {
  /// Google caps a Directions request at 25 intermediate waypoints; the
  /// origin and destination bring the usable chunk to 27. Staying at 25
  /// leaves headroom and keeps each request comfortably under the URL
  /// length limit on the REST path.
  static const int maxStopsPerRequest = 25;

  /// Any single Directions request must finish inside this or be treated
  /// as failed. Without it a dropped callback would hang the whole plan.
  static const Duration requestTimeout = Duration(seconds: 45);

  static const String _directionsBaseUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  final RouteOptimizationService _local = RouteOptimizationService();

  /// Build a complete plan for [addresses].
  ///
  /// Addresses without coordinates are dropped — they cannot be routed —
  /// and reported in [PlannedRoute.warning].
  Future<PlannedRoute> plan(
    List<Address> addresses, {
    RoutePlanOptions options = const RoutePlanOptions(),
    void Function(RoutePlanProgress progress)? onProgress,
    RoutePlanCancelToken? cancelToken,
  }) async {
    void report(String stage, int done, int total) =>
        onProgress?.call(RoutePlanProgress(stage, done, total));

    void checkCancelled() {
      if (cancelToken?.isCancelled ?? false) throw const RoutePlanCancelled();
    }

    final warnings = <String>[];

    final routable = addresses
        .where((a) => a.latitude != null && a.longitude != null)
        .toList();
    final skipped = addresses.length - routable.length;
    if (skipped > 0) {
      warnings.add('$skipped address${skipped == 1 ? '' : 'es'} '
          'skipped — not geocoded yet.');
    }

    if (routable.isEmpty) {
      throw StateError('No geocoded addresses to route.');
    }

    // The depot leads the list but is not a delivery.
    final depot = options.depot;
    final hasDepot = depot != null &&
        depot.latitude != null &&
        depot.longitude != null &&
        !routable.any((a) => a.id == depot.id);

    checkCancelled();
    report('Ordering stops', 0, 0);

    // ── Step 1: decide an order without spending a single API call ──────
    List<Address> ordered;
    switch (options.algorithm) {
      case RouteAlgorithm.keepOrder:
        ordered = List.of(routable);
      case RouteAlgorithm.nearestNeighbour:
        ordered = _local
            .optimizeRouteNearestNeighbor(routable,
                startPoint: hasDepot ? null : routable.first)
            .addresses;
      case RouteAlgorithm.twoOpt:
      case RouteAlgorithm.googleOptimized:
        ordered = _local.optimizeRoute2Opt(routable).addresses;
    }

    if (hasDepot) {
      // Re-seed the greedy order from the depot so the first delivery is
      // the one nearest the yard, not an arbitrary list head.
      if (options.algorithm != RouteAlgorithm.keepOrder) {
        ordered = _orderFrom(depot, ordered);
      }
      ordered = [depot, ...ordered];
    }

    checkCancelled();

    // ── Step 2: cost it against real roads, chunk by chunk ──────────────
    final pathStops = [
      ...ordered,
      if (options.returnToStart && ordered.length > 1) ordered.first,
    ];

    final chunkCount = chunkCountFor(pathStops.length);
    report('Fetching road data', 0, chunkCount);

    final legs = <_Leg>[];
    var usedRealRoads = true;
    var chunkIndex = 0;
    var cursor = 0;

    // Chunks overlap by one stop: the last stop of a chunk is the first
    // of the next, so the legs join up without a gap.
    while (cursor < pathStops.length - 1) {
      checkCancelled();

      final end = math.min(cursor + maxStopsPerRequest, pathStops.length);
      final chunk = pathStops.sublist(cursor, end);
      // The chunk's first and last stops are always held fixed, so the
      // depot and the closing return leg stay where they belong; only the
      // interior gets reordered, and only when there is one to reorder.
      final canOptimiseChunk =
          options.algorithm == RouteAlgorithm.googleOptimized &&
              chunk.length > 3;

      final result = await _fetchChunk(
        chunk,
        departureTime: options.useTraffic ? options.departAt : null,
        optimize: canOptimiseChunk,
      );

      if (result == null) {
        usedRealRoads = false;
        for (var i = 0; i < chunk.length - 1; i++) {
          legs.add(_straightLineLeg(chunk[i], chunk[i + 1]));
        }
      } else {
        if (result.order.isNotEmpty && canOptimiseChunk) {
          // Apply Google's reordering back onto the master list so the
          // next chunk starts from the stop this one actually ends at.
          final interior = chunk.sublist(1, chunk.length - 1);
          final reordered = [
            chunk.first,
            for (final i in result.order)
              if (i >= 0 && i < interior.length) interior[i],
            chunk.last,
          ];
          if (reordered.length == chunk.length) {
            pathStops.replaceRange(cursor, end, reordered);
          }
        }
        legs.addAll(result.legs);
      }

      chunkIndex++;
      report('Fetching road data', chunkIndex, chunkCount);
      cursor = end - 1;
    }

    if (!usedRealRoads) {
      warnings.add(
          'Some legs fell back to straight-line estimates — the Directions '
          'service did not answer.');
    }

    checkCancelled();
    report('Building itinerary', chunkCount, chunkCount);

    // Rebuild the delivery order from the (possibly reordered) path.
    final finalStops = options.returnToStart && pathStops.length > 1
        ? pathStops.sublist(0, pathStops.length - 1)
        : pathStops;

    return _assemble(
      finalStops: finalStops,
      legs: legs,
      hasDepot: hasDepot,
      options: options,
      usedRealRoads: usedRealRoads,
      warning: warnings.isEmpty ? null : warnings.join(' '),
    );
  }

  /// How many Directions requests [stopCount] stops will take.
  ///
  /// Chunks overlap by one stop — the last of a chunk is the first of the
  /// next — so the legs join without a gap. Exposed because the planning
  /// sheet quotes the same figure before the user commits to a run.
  static int chunkCountFor(int stopCount) {
    if (stopCount < 2) return 0;
    var count = 0;
    var cursor = 0;
    while (cursor < stopCount - 1) {
      count++;
      cursor = math.min(cursor + maxStopsPerRequest, stopCount) - 1;
    }
    return count;
  }

  /// Greedy re-seed so the run leaves the depot for its nearest stop.
  List<Address> _orderFrom(Address depot, List<Address> stops) {
    if (stops.length < 2) return stops;
    final remaining = List.of(stops);
    final ordered = <Address>[];
    var current = LatLng(depot.latitude!, depot.longitude!);

    while (remaining.isNotEmpty) {
      var bestIndex = 0;
      var bestDistance = double.infinity;
      for (var i = 0; i < remaining.length; i++) {
        final candidate =
            LatLng(remaining[i].latitude!, remaining[i].longitude!);
        final d = _local.calculateDistance(current, candidate);
        if (d < bestDistance) {
          bestDistance = d;
          bestIndex = i;
        }
      }
      final next = remaining.removeAt(bestIndex);
      ordered.add(next);
      current = LatLng(next.latitude!, next.longitude!);
    }
    return ordered;
  }

  /// One Directions request covering a whole chunk of stops.
  Future<_ChunkResult?> _fetchChunk(
    List<Address> chunk, {
    DateTime? departureTime,
    bool optimize = false,
  }) async {
    if (chunk.length < 2) return const _ChunkResult(order: [], legs: []);

    try {
      if (kIsWeb) {
        final result = await web_directions
            .getOptimizedRouteWeb(
              [
                for (final a in chunk) LatLng(a.latitude!, a.longitude!),
              ],
              departureTime: departureTime,
              optimize: optimize,
            )
            .timeout(requestTimeout);
        if (result == null) return null;
        return _ChunkResult(
          order: result.waypointOrder,
          legs: [
            for (final l in result.legs)
              _Leg(
                distanceMeters: l.distanceMeters,
                durationSeconds: l.durationSeconds,
                durationInTrafficSeconds: l.durationInTrafficSeconds,
                path: l.path,
              ),
          ],
        );
      }
      return await _fetchChunkRest(
        chunk,
        departureTime: departureTime,
        optimize: optimize,
      ).timeout(requestTimeout);
    } on TimeoutException {
      debugPrint('Route chunk timed out (${chunk.length} stops)');
      return null;
    } catch (e) {
      debugPrint('Route chunk failed: $e');
      return null;
    }
  }

  /// Native path: the REST Directions endpoint, same chunk shape.
  Future<_ChunkResult?> _fetchChunkRest(
    List<Address> chunk, {
    DateTime? departureTime,
    bool optimize = false,
  }) async {
    final origin = chunk.first;
    final destination = chunk.last;
    final middle = chunk.sublist(1, chunk.length - 1);

    final waypoints = [
      if (optimize) 'optimize:true',
      for (final a in middle) '${a.latitude},${a.longitude}',
    ].join('|');

    // Google needs a future departure to return duration_in_traffic.
    var effectiveDeparture = departureTime;
    if (effectiveDeparture != null) {
      final now = DateTime.now();
      while (effectiveDeparture!.isBefore(now)) {
        effectiveDeparture = effectiveDeparture.add(const Duration(days: 1));
      }
    }

    final params = <String, String>{
      'origin': '${origin.latitude},${origin.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
      if (waypoints.isNotEmpty) 'waypoints': waypoints,
      'mode': 'driving',
      'key': Env.googleMapsApiKey,
      if (effectiveDeparture != null)
        'departure_time':
            (effectiveDeparture.millisecondsSinceEpoch ~/ 1000).toString(),
      if (effectiveDeparture != null) 'traffic_model': 'best_guess',
    };

    final response =
        await http.get(Uri.parse(_directionsBaseUrl).replace(queryParameters: params));
    if (response.statusCode != 200) {
      debugPrint('Directions HTTP ${response.statusCode}');
      return null;
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List?;
    if (data['status'] != 'OK' || routes == null || routes.isEmpty) {
      debugPrint('Directions status ${data['status']}');
      return null;
    }

    final route = routes.first as Map<String, dynamic>;
    final order = [
      for (final i in (route['waypoint_order'] as List? ?? const []))
        (i as num).toInt(),
    ];

    final legs = <_Leg>[];
    for (final rawLeg in (route['legs'] as List? ?? const [])) {
      final leg = rawLeg as Map<String, dynamic>;
      final duration = ((leg['duration']?['value']) as num?)?.toInt() ?? 0;
      final path = <LatLng>[];
      for (final rawStep in (leg['steps'] as List? ?? const [])) {
        final encoded = (rawStep as Map)['polyline']?['points'] as String?;
        if (encoded != null) path.addAll(decodePolyline(encoded));
      }
      legs.add(_Leg(
        distanceMeters: ((leg['distance']?['value']) as num?)?.toDouble() ?? 0,
        durationSeconds: duration,
        durationInTrafficSeconds:
            ((leg['duration_in_traffic']?['value']) as num?)?.toInt() ??
                duration,
        path: path,
      ));
    }

    return _ChunkResult(order: order, legs: legs);
  }

  _Leg _straightLineLeg(Address from, Address to) {
    final a = LatLng(from.latitude!, from.longitude!);
    final b = LatLng(to.latitude!, to.longitude!);
    final km = _local.calculateDistance(a, b);
    // 40 km/h is a realistic urban average once stops and lights are in.
    final seconds = ((km / 40) * 3600).round();
    return _Leg(
      distanceMeters: km * 1000,
      durationSeconds: seconds,
      durationInTrafficSeconds: seconds,
      path: [a, b],
    );
  }

  PlannedRoute _assemble({
    required List<Address> finalStops,
    required List<_Leg> legs,
    required bool hasDepot,
    required RoutePlanOptions options,
    required bool usedRealRoads,
    String? warning,
  }) {
    final stops = <PlannedStop>[];
    var cumulativeDistance = 0.0;
    var cumulativeDriving = 0;
    var clock = options.departAt;
    final service = options.serviceTimePerStop;
    final useTraffic = options.useTraffic;

    for (var i = 0; i < finalStops.length; i++) {
      final leg = i == 0 ? null : (i - 1 < legs.length ? legs[i - 1] : null);
      final legDistance = leg?.distanceMeters ?? 0;
      final legDuration = leg == null
          ? 0
          : (useTraffic ? leg.durationInTrafficSeconds : leg.durationSeconds);

      cumulativeDistance += legDistance;
      cumulativeDriving += legDuration;

      final isDepot = hasDepot && i == 0;
      DateTime? arrival;
      DateTime? departure;
      if (clock != null) {
        arrival = i == 0 ? clock : clock.add(Duration(seconds: legDuration));
        departure = isDepot ? arrival : arrival.add(service);
        clock = departure;
      }

      stops.add(PlannedStop(
        address: finalStops[i],
        sequence: hasDepot ? i : i + 1,
        isDepot: isDepot,
        legDistanceMeters: legDistance,
        legDurationSeconds: leg?.durationSeconds ?? 0,
        legDurationInTrafficSeconds: leg?.durationInTrafficSeconds ?? 0,
        pathFromPrevious: leg?.path ?? const [],
        cumulativeDistanceMeters: cumulativeDistance,
        cumulativeDrivingSeconds: cumulativeDriving,
        arrival: arrival,
        departure: departure,
      ));
    }

    PlannedStop? returnLeg;
    if (options.returnToStart && finalStops.length > 1) {
      final leg = legs.length >= finalStops.length
          ? legs[finalStops.length - 1]
          : _straightLineLeg(finalStops.last, finalStops.first);
      final legDuration =
          useTraffic ? leg.durationInTrafficSeconds : leg.durationSeconds;
      cumulativeDistance += leg.distanceMeters;
      cumulativeDriving += legDuration;

      returnLeg = PlannedStop(
        address: finalStops.first,
        sequence: stops.length,
        isDepot: hasDepot,
        legDistanceMeters: leg.distanceMeters,
        legDurationSeconds: leg.durationSeconds,
        legDurationInTrafficSeconds: leg.durationInTrafficSeconds,
        pathFromPrevious: leg.path,
        cumulativeDistanceMeters: cumulativeDistance,
        cumulativeDrivingSeconds: cumulativeDriving,
        arrival: clock?.add(Duration(seconds: legDuration)),
      );
    }

    final deliveryCount = stops.where((s) => !s.isDepot).length;

    return PlannedRoute(
      stops: stops,
      returnLeg: returnLeg,
      totalDistanceMeters: cumulativeDistance,
      totalDrivingSeconds: cumulativeDriving,
      totalServiceSeconds: service.inSeconds * deliveryCount,
      usedRealRoads: usedRealRoads,
      algorithm: options.algorithm,
      options: options,
      plannedAt: DateTime.now(),
      warning: warning,
    );
  }
}

/// Internal: one leg's cost and geometry.
class _Leg {
  final double distanceMeters;
  final int durationSeconds;
  final int durationInTrafficSeconds;
  final List<LatLng> path;

  const _Leg({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.durationInTrafficSeconds,
    required this.path,
  });
}

/// Internal: one chunk's reordering plus its legs.
class _ChunkResult {
  final List<int> order;
  final List<_Leg> legs;

  const _ChunkResult({required this.order, required this.legs});
}
