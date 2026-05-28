import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/address.dart';
import '../models/dropsheet_day.dart';
import '../models/dropsheet_task.dart';
import '../models/dropsheet_task_type_config.dart';
import '../providers/dropsheet_task_config_provider.dart';
import 'day_planner_cloud_functions.dart';
import 'distance_matrix_service.dart';

/// Routing point belonging to a single task.
///
/// Most task types contribute a single stop. `furnitureMove` contributes
/// two stops (loading then offload) sharing the same `taskId` — the
/// optimiser enforces that the loading stop is always visited before
/// its offload counterpart.
class RouteStop {
  final String taskId;
  final DropsheetTaskType taskType;
  final DropsheetTaskRole role;
  final String label;
  final double lat;
  final double lng;
  final int serviceMinutes;

  RouteStop({
    required this.taskId,
    required this.taskType,
    required this.role,
    required this.label,
    required this.lat,
    required this.lng,
    required this.serviceMinutes,
  });

  String get stopKey => '${taskId}__${role.name}';

  LatLng get latLng => LatLng(lat, lng);
}

enum DropsheetTaskRole {
  /// Default: the task has a single stop.
  single,

  /// Furniture move loading address.
  loading,

  /// Furniture move offload address.
  offload,
}

/// One travelling segment between two routing points (or from depot to
/// the first stop). `fromStopKey` is `null` when the leg starts at the
/// depot.
class RouteLeg {
  final String? fromStopKey;
  final String toStopKey;
  final double distanceMeters;
  final int durationSeconds;
  final List<LatLng> polyline;

  RouteLeg({
    required this.fromStopKey,
    required this.toStopKey,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.polyline,
  });
}

/// Output of [DropsheetRoutePlanner.optimizeSection].
///
/// `taskOrder` lists each visited task once in the order it should
/// appear on the dropsheet. `arrivalTimes[stopKey]` is the
/// `HH:mm` arrival at that routing point — for furniture-move tasks the
/// arrival at the offload address is the one shown to the driver as the
/// task ETA.
class OptimizedRoute {
  final String sectionId;
  final List<String> taskOrder;
  final Map<String, String> arrivalTimes; // stopKey -> HH:mm
  final Map<String, RouteLeg> legBeforeStop; // stopKey -> incoming leg
  final List<LatLng> fullPolyline;
  final double totalDistanceMeters;
  final int totalDurationSeconds;
  final List<String> skippedTaskIds; // tasks without coordinates
  final DateTime computedAt;

  OptimizedRoute({
    required this.sectionId,
    required this.taskOrder,
    required this.arrivalTimes,
    required this.legBeforeStop,
    required this.fullPolyline,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.skippedTaskIds,
    required this.computedAt,
  });
}

/// Hybrid route planner: nearest-neighbour ordering on real road
/// durations from the Google Directions API.
///
/// Strategy:
/// 1. Extract one or two routing points per task (skipping tasks that
///    are not yet geocoded or are mandatory in-depot tasks).
/// 2. Greedy nearest-neighbour starting at the depot, where the
///    neighbour distance is the actual road duration from
///    [DistanceMatrixService.getRouteSegment]. We respect the
///    constraint that a furniture-move offload cannot be visited
///    before its loading.
/// 3. Compute ETAs by adding each leg duration plus per-stop service
///    minutes (default per task type, optional per-task override).
class DropsheetRoutePlanner {
  final DistanceMatrixService _matrix;
  final DropsheetTaskConfigProvider _config;
  final DayPlannerCloudFunctions? _cloud;

  /// When true, [optimizeSection] delegates to the
  /// `optimizeDropsheetRoute` Cloud Function instead of running the
  /// greedy nearest-neighbour locally. The cloud variant uses the
  /// shared org-wide `routeCache`, so repeated planning runs cost
  /// nothing in Directions API quota.
  final bool useCloud;

  DropsheetRoutePlanner({
    DistanceMatrixService? matrix,
    DayPlannerCloudFunctions? cloud,
    required DropsheetTaskConfigProvider config,
    this.useCloud = false,
  })  : _matrix = matrix ?? DistanceMatrixService(),
        _cloud = cloud,
        _config = config;

  /// Optimise the route for a single driver section.
  ///
  /// [baseDate] is the calendar date this dropsheet belongs to (year /
  /// month / day are taken from it). Combined with [startTime] (or
  /// `depot.startTime` if omitted) this gives every leg a realistic
  /// departure timestamp, which is passed to the Directions API so
  /// durations and ETAs reflect expected traffic conditions for that
  /// time of day.
  ///
  /// Pass [startTime] as the Leave task's `startTime` value so the
  /// planner uses the actual scheduled departure rather than the
  /// stored depot default.
  ///
  /// Returns `null` if the section has no routable stops.
  Future<OptimizedRoute?> optimizeSection({
    required DropsheetDriverSection section,
    required DepotConfig depot,
    required DateTime baseDate,
    String? startTime,
  }) async {
    final stops = <RouteStop>[];
    final skipped = <String>[];
    // Accumulate service minutes for unrouted tasks (no coordinates) so the
    // total route duration and ETA remain realistic.
    var unroutedServiceMinutes = 0;

    for (final task in section.tasks) {
      // The 3 mandatory tasks happen at the depot before leaving — they
      // do not count as routing stops.
      if (task.isMandatory) continue;
      final taskStops = _stopsForTask(task);
      if (taskStops.isEmpty) {
        unroutedServiceMinutes += _config.serviceMinutesFor(task);
        skipped.add(task.id);
        continue;
      }
      stops.addAll(taskStops);
    }

    debugPrint(
        '[DropsheetRoute] section=${section.id} stops=${stops.length} '
        'skipped=${skipped.length} unroutedMin=$unroutedServiceMinutes');

    if (stops.isEmpty) return null;
    if (depot.lat == null || depot.lng == null) {
      debugPrint('[DropsheetRoute] depot not geocoded — aborting');
      return null;
    }

    // Cloud path: delegate the entire greedy nearest-neighbour to the
    // server, which already has access to the shared org-wide
    // routeCache. Falls back to the local path on any failure so the
    // user is never left without a result.
    if (useCloud) {
      final cloudResult = await _runOnCloud(
        section: section,
        depot: depot,
        baseDate: baseDate,
        startTime: startTime,
        stops: stops,
        clientSkipped: skipped,
      );
      if (cloudResult != null) return cloudResult;
      debugPrint(
          '[DropsheetRoute] cloud optimiser failed — falling back to local');
    }

    final depotAddr = _addressFor(
      id: '__depot',
      lat: depot.lat!,
      lng: depot.lng!,
    );

    // Real-clock DateTime starting at startTime (or depot.startTime) on
    // baseDate. As we step through the route this gets advanced by each
    // leg's traffic-aware duration plus the previous stop's service minutes,
    // and is used as `departure_time` for the next Directions query.
    final effectiveStartTime = startTime ?? depot.startTime;
    final start = _parseStartTime(effectiveStartTime);
    var clock = DateTime(
      baseDate.year,
      baseDate.month,
      baseDate.day,
      start.hour,
      start.minute,
    );

    // Greedy nearest-neighbour over real road durations.
    final remaining = [...stops];
    final ordered = <RouteStop>[];
    final legs = <RouteLeg>[];
    final arrivalTimes = <String, String>{};

    String? currentId; // null at depot
    double currentLat = depot.lat!;
    double currentLng = depot.lng!;

    while (remaining.isNotEmpty) {
      // Determine whether any non-pickUp stops are still unvisited.
      // Pick-up stops are deferred until all drops and other tasks are
      // done — the car visits them on the way back to the office.
      final hasNonPickUp =
          remaining.any((s) => s.taskType != DropsheetTaskType.pickUp);

      // Filter to stops whose dependency (if any) has been satisfied,
      // and enforce the pickUp-last constraint.
      final eligible = remaining.where((s) {
        // Defer pickUp stops until all other stops are exhausted.
        if (s.taskType == DropsheetTaskType.pickUp && hasNonPickUp) {
          return false;
        }
        // Furniture-move offload requires its loading stop to come first.
        if (s.role != DropsheetTaskRole.offload) return true;
        return ordered.any(
            (o) => o.taskId == s.taskId && o.role == DropsheetTaskRole.loading);
      }).toList();
      // Should never happen given how stops are constructed, but guard
      // against an infinite loop.
      if (eligible.isEmpty) break;

      RouteStop? best;
      RouteLeg? bestLeg;
      var bestDuration = 1 << 30;

      // Query Directions for every eligible candidate in parallel rather
      // than sequentially. With N candidates this collapses N×latency
      // into one round-trip's worth of wall time. Cached results in
      // DistanceMatrixService make repeat lookups free.
      final fromAddr = currentId == null
          ? depotAddr
          : _addressFor(
              id: currentId,
              lat: currentLat,
              lng: currentLng,
            );
      final segments = await Future.wait(eligible.map((cand) {
        final candAddr = _addressFor(
          id: cand.stopKey,
          lat: cand.lat,
          lng: cand.lng,
        );
        return _matrix.getRouteSegment(
          fromAddr,
          candAddr,
          departureTime: clock,
        );
      }));

      for (var i = 0; i < eligible.length; i++) {
        final cand = eligible[i];
        final seg = segments[i];
        if (seg == null) {
          debugPrint(
              '[DropsheetRoute] no segment ${fromAddr.id} -> ${cand.stopKey}');
          continue;
        }
        // Prefer traffic-aware seconds when available so the optimiser
        // routes around predicted congestion at this time of day.
        final candDuration = seg.durationInTrafficSeconds;
        if (candDuration < bestDuration) {
          bestDuration = candDuration;
          best = cand;
          bestLeg = RouteLeg(
            fromStopKey: currentId,
            toStopKey: cand.stopKey,
            distanceMeters: seg.distanceMeters,
            durationSeconds: candDuration,
            polyline: seg.polylinePoints,
          );
        }
      }

      if (best == null || bestLeg == null) {
        debugPrint(
            '[DropsheetRoute] could not find next stop — aborting with ${ordered.length} visited');
        break;
      }

      ordered.add(best);
      legs.add(bestLeg);
      // Advance the clock by this leg's travel + service time.
      clock = clock.add(Duration(seconds: bestLeg.durationSeconds));
      arrivalTimes[best.stopKey] = _fmtHHmm(clock);
      clock = clock.add(Duration(minutes: best.serviceMinutes));

      remaining.removeWhere((s) => s.stopKey == best!.stopKey);
      currentId = best.stopKey;
      currentLat = best.lat;
      currentLng = best.lng;
    }

    // Stops we never reached (e.g. Directions API failures) become
    // skipped so the UI can flag them.
    skipped.addAll(remaining.map((s) => s.taskId).toSet());

    // Add accumulated service time for tasks that had no coordinates (and
    // therefore no routing stop). We apply this before the return leg so it
    // inflates both the total duration and the final depot arrival ETA.
    if (unroutedServiceMinutes > 0) {
      clock = clock.add(Duration(minutes: unroutedServiceMinutes));
      debugPrint(
          '[DropsheetRoute] applied ${unroutedServiceMinutes}min unrouted overhead');
    }

    // Return leg: last stop → depot so the total is a full round trip.
    if (ordered.isNotEmpty) {
      final lastAddr =
          _addressFor(id: currentId!, lat: currentLat, lng: currentLng);
      final returnSeg = await _matrix.getRouteSegment(
        lastAddr,
        depotAddr,
        departureTime: clock,
      );
      if (returnSeg != null) {
        legs.add(RouteLeg(
          fromStopKey: currentId,
          toStopKey: '__depot',
          distanceMeters: returnSeg.distanceMeters,
          durationSeconds: returnSeg.durationInTrafficSeconds,
          polyline: returnSeg.polylinePoints,
        ));
        clock =
            clock.add(Duration(seconds: returnSeg.durationInTrafficSeconds));
        arrivalTimes['__depot'] = _fmtHHmm(clock);
      }
    }

    // Deduplicate task order (furniture-move contributes 2 stops).
    final taskOrder = <String>[];
    for (final s in ordered) {
      if (taskOrder.isEmpty || taskOrder.last != s.taskId) {
        taskOrder.add(s.taskId);
      }
    }

    final fullPolyline = <LatLng>[];
    for (final leg in legs) {
      if (leg.polyline.isEmpty) continue;
      if (fullPolyline.isEmpty) {
        fullPolyline.addAll(leg.polyline);
      } else {
        // Avoid duplicating the join point.
        fullPolyline.addAll(leg.polyline.skip(1));
      }
    }

    final legBeforeStop = <String, RouteLeg>{
      for (var i = 0; i < ordered.length; i++) ordered[i].stopKey: legs[i],
    };

    final totalDistance =
        legs.fold<double>(0, (sum, l) => sum + l.distanceMeters);
    final totalDuration =
        legs.fold<int>(0, (sum, l) => sum + l.durationSeconds);

    debugPrint(
        '[DropsheetRoute] section=${section.id} ordered=${taskOrder.length} '
        'distance=${(totalDistance / 1000).toStringAsFixed(1)}km '
        'duration=${(totalDuration / 60).round()}min');

    return OptimizedRoute(
      sectionId: section.id,
      taskOrder: taskOrder,
      arrivalTimes: arrivalTimes,
      legBeforeStop: legBeforeStop,
      fullPolyline: fullPolyline,
      totalDistanceMeters: totalDistance,
      totalDurationSeconds: totalDuration,
      skippedTaskIds: skipped,
      computedAt: DateTime.now(),
    );
  }

  // ---------------------------------------------------------------------------
  // Cloud optimiser bridge
  // ---------------------------------------------------------------------------

  /// Translate the local stop list into the JSON shape the
  /// `optimizeDropsheetRoute` Cloud Function expects, invoke it, and
  /// rebuild an [OptimizedRoute] from the response. Returns `null` on
  /// any failure so the caller can fall back to the local optimiser.
  Future<OptimizedRoute?> _runOnCloud({
    required DropsheetDriverSection section,
    required DepotConfig depot,
    required DateTime baseDate,
    required String? startTime,
    required List<RouteStop> stops,
    required List<String> clientSkipped,
  }) async {
    final cloud = _cloud ?? DayPlannerCloudFunctions();
    final stopPayload = stops
        .map((s) => {
              'taskId': s.taskId,
              'role': s.role.name,
              'stopKey': s.stopKey,
              'lat': s.lat,
              'lng': s.lng,
              'serviceMinutes': s.serviceMinutes,
            })
        .toList();
    final depotPayload = <String, dynamic>{
      'lat': depot.lat,
      'lng': depot.lng,
      'startTime': depot.startTime,
    };

    final raw = await cloud.optimizeDropsheetRoute(
      stops: stopPayload,
      depot: depotPayload,
      baseDate: baseDate,
      startTime: startTime,
    );
    if (raw == null) return null;

    final taskOrder = (raw['taskOrder'] as List?)?.cast<String>() ?? const [];
    final arrivalRaw = raw['arrivalTimes'];
    final arrivalTimes = <String, String>{};
    if (arrivalRaw is Map) {
      arrivalRaw.forEach((k, v) => arrivalTimes[k.toString()] = v.toString());
    }

    final legBeforeStop = <String, RouteLeg>{};
    final legRaw = raw['legBeforeStop'];
    if (legRaw is Map) {
      legRaw.forEach((k, v) {
        if (v is! Map) return;
        final polyRaw = v['polyline'];
        final poly = <LatLng>[];
        if (polyRaw is List) {
          for (final p in polyRaw) {
            if (p is Map && p['lat'] is num && p['lng'] is num) {
              poly.add(LatLng(
                  (p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()));
            }
          }
        }
        legBeforeStop[k.toString()] = RouteLeg(
          fromStopKey: v['fromStopKey'] as String?,
          toStopKey: (v['toStopKey'] ?? k).toString(),
          distanceMeters: (v['distanceMeters'] as num?)?.toDouble() ?? 0,
          durationSeconds: (v['durationSeconds'] as num?)?.toInt() ?? 0,
          polyline: poly,
        );
      });
    }

    final fullPolyline = <LatLng>[];
    final fullRaw = raw['fullPolyline'];
    if (fullRaw is List) {
      for (final p in fullRaw) {
        if (p is Map && p['lat'] is num && p['lng'] is num) {
          fullPolyline.add(LatLng(
              (p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()));
        }
      }
    }

    final serverSkipped =
        (raw['skippedTaskIds'] as List?)?.cast<String>() ?? const [];
    final mergedSkipped = <String>{...clientSkipped, ...serverSkipped}.toList();

    return OptimizedRoute(
      sectionId: section.id,
      taskOrder: taskOrder,
      arrivalTimes: arrivalTimes,
      legBeforeStop: legBeforeStop,
      fullPolyline: fullPolyline,
      totalDistanceMeters:
          (raw['totalDistanceMeters'] as num?)?.toDouble() ?? 0,
      totalDurationSeconds: (raw['totalDurationSeconds'] as num?)?.toInt() ?? 0,
      skippedTaskIds: mergedSkipped,
      computedAt: DateTime.now(),
    );
  }

  // ---------------------------------------------------------------------------
  // Stop extraction
  // ---------------------------------------------------------------------------

  List<RouteStop> _stopsForTask(DropsheetTask task) {
    final serviceDefault = _config.serviceMinutesFor(task);
    switch (task.type) {
      case DropsheetTaskType.dropOff:
      case DropsheetTaskType.pickUp:
        return _singleStopFromKeys(task,
            latKey: 'lat',
            lngKey: 'lng',
            serviceDefault: serviceDefault,
            label: (task.typeData['workArea'] as String?) ??
                (task.typeData['distributorName'] as String?) ??
                task.location);
      case DropsheetTaskType.collection:
      case DropsheetTaskType.jobReturn:
      case DropsheetTaskType.pickFlyers:
      case DropsheetTaskType.custom:
        return _singleStopFromKeys(task,
            latKey: 'lat',
            lngKey: 'lng',
            serviceDefault: serviceDefault,
            label: (task.typeData['address'] as String?) ?? task.location);
      case DropsheetTaskType.furnitureMove:
        final stops = <RouteStop>[];
        final loadLat = (task.typeData['loadingLat'] as num?)?.toDouble();
        final loadLng = (task.typeData['loadingLng'] as num?)?.toDouble();
        final offLat = (task.typeData['offloadLat'] as num?)?.toDouble();
        final offLng = (task.typeData['offloadLng'] as num?)?.toDouble();
        if (loadLat != null && loadLng != null) {
          stops.add(RouteStop(
            taskId: task.id,
            taskType: task.type,
            role: DropsheetTaskRole.loading,
            label:
                'Load: ${(task.typeData['loadingAddress'] as String?) ?? ''}',
            lat: loadLat,
            lng: loadLng,
            // Loading is conceptually part of the same job; charge half
            // of the type-default service minutes here, half at offload.
            serviceMinutes: serviceDefault ~/ 2,
          ));
        }
        if (offLat != null && offLng != null) {
          stops.add(RouteStop(
            taskId: task.id,
            taskType: task.type,
            role: DropsheetTaskRole.offload,
            label:
                'Offload: ${(task.typeData['offloadAddress'] as String?) ?? ''}',
            lat: offLat,
            lng: offLng,
            serviceMinutes: serviceDefault - (serviceDefault ~/ 2),
          ));
        }
        return stops;
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
      case DropsheetTaskType.leave:
      case DropsheetTaskType.arrive:
        return const [];
    }
  }

  List<RouteStop> _singleStopFromKeys(
    DropsheetTask task, {
    required String latKey,
    required String lngKey,
    required int serviceDefault,
    required String label,
  }) {
    final lat = (task.typeData[latKey] as num?)?.toDouble();
    final lng = (task.typeData[lngKey] as num?)?.toDouble();
    if (lat == null || lng == null) return const [];
    return [
      RouteStop(
        taskId: task.id,
        taskType: task.type,
        role: DropsheetTaskRole.single,
        label: label.isEmpty ? task.job : label,
        lat: lat,
        lng: lng,
        serviceMinutes: serviceDefault,
      ),
    ];
  }

  /// Calculate ETAs and leg data for the **current task order** without
  /// reordering. Equivalent to [optimizeSection] but the stop sequence is
  /// taken as-is from [section.tasks].
  ///
  /// [startTime] overrides the depot's configured start time — pass the
  /// Leave-task's `startTime` value so realistic traffic-aware ETAs are
  /// computed for the actual departure time rather than the stored default.
  Future<OptimizedRoute?> calculateInPlace({
    required DropsheetDriverSection section,
    required DepotConfig depot,
    required DateTime baseDate,
    String? startTime,
  }) async {
    if (depot.lat == null || depot.lng == null) {
      debugPrint('[DropsheetRoute] depot not geocoded — aborting');
      return null;
    }

    // Collect per-task routing data up-front (all synchronous).
    final taskData = <({DropsheetTask task, List<RouteStop> stops})>[];
    for (final task in section.tasks) {
      if (task.isMandatory) continue;
      taskData.add((task: task, stops: _stopsForTask(task)));
    }

    final routableCount = taskData.fold(0, (s, d) => s + d.stops.length);
    final unroutedCount = taskData.where((d) => d.stops.isEmpty).length;
    debugPrint(
        '[DropsheetRoute] section=${section.id} routable=$routableCount '
        'unrouted=$unroutedCount');
    if (routableCount == 0) return null;

    final depotAddr =
        _addressFor(id: '__depot', lat: depot.lat!, lng: depot.lng!);

    final effectiveStartTime = startTime ?? depot.startTime;
    final start = _parseStartTime(effectiveStartTime);
    var clock = DateTime(
        baseDate.year, baseDate.month, baseDate.day, start.hour, start.minute);

    final ordered = <RouteStop>[];
    final legs = <RouteLeg>[];
    final arrivalTimes = <String, String>{};
    final skipped = <String>[];

    String? currentId;
    double currentLat = depot.lat!;
    double currentLng = depot.lng!;

    for (final d in taskData) {
      if (d.stops.isEmpty) {
        // Task has no routing stop (no coordinates). Still advance the clock
        // by its configured service time so downstream ETAs remain realistic.
        final serviceMin = _config.serviceMinutesFor(d.task);
        if (serviceMin > 0) {
          clock = clock.add(Duration(minutes: serviceMin));
          debugPrint(
              '[DropsheetRoute] task=${d.task.id} (${d.task.type.name}) '
              'no coords — +${serviceMin}min to clock');
        }
        skipped.add(d.task.id);
        continue;
      }

      for (final stop in d.stops) {
        final candAddr =
            _addressFor(id: stop.stopKey, lat: stop.lat, lng: stop.lng);
        final fromAddr = currentId == null
            ? depotAddr
            : _addressFor(id: currentId, lat: currentLat, lng: currentLng);

        final seg = await _matrix.getRouteSegment(fromAddr, candAddr,
            departureTime: clock);
        if (seg == null) {
          debugPrint(
              '[DropsheetRoute] no segment ${fromAddr.id} -> ${candAddr.id}');
          skipped.add(stop.taskId);
          continue;
        }

        final legDuration = seg.durationInTrafficSeconds;
        final leg = RouteLeg(
          fromStopKey: currentId,
          toStopKey: stop.stopKey,
          distanceMeters: seg.distanceMeters,
          durationSeconds: legDuration,
          polyline: seg.polylinePoints,
        );

        ordered.add(stop);
        legs.add(leg);
        clock = clock.add(Duration(seconds: legDuration));
        arrivalTimes[stop.stopKey] = _fmtHHmm(clock);
        clock = clock.add(Duration(minutes: stop.serviceMinutes));

        currentId = stop.stopKey;
        currentLat = stop.lat;
        currentLng = stop.lng;
      }
    }

    // Return leg: last stop → depot so the total is a full round trip.
    if (ordered.isNotEmpty) {
      final lastAddr =
          _addressFor(id: currentId!, lat: currentLat, lng: currentLng);
      final returnSeg = await _matrix.getRouteSegment(
        lastAddr,
        depotAddr,
        departureTime: clock,
      );
      if (returnSeg != null) {
        legs.add(RouteLeg(
          fromStopKey: currentId,
          toStopKey: '__depot',
          distanceMeters: returnSeg.distanceMeters,
          durationSeconds: returnSeg.durationInTrafficSeconds,
          polyline: returnSeg.polylinePoints,
        ));
        clock =
            clock.add(Duration(seconds: returnSeg.durationInTrafficSeconds));
        arrivalTimes['__depot'] = _fmtHHmm(clock);
      }
    }

    final taskOrder = <String>[];
    for (final s in ordered) {
      if (taskOrder.isEmpty || taskOrder.last != s.taskId) {
        taskOrder.add(s.taskId);
      }
    }

    final fullPolyline = <LatLng>[];
    for (final leg in legs) {
      if (leg.polyline.isEmpty) continue;
      if (fullPolyline.isEmpty) {
        fullPolyline.addAll(leg.polyline);
      } else {
        fullPolyline.addAll(leg.polyline.skip(1));
      }
    }

    final legBeforeStop = <String, RouteLeg>{
      for (var i = 0; i < ordered.length; i++) ordered[i].stopKey: legs[i],
    };

    final totalDistance = legs.fold<double>(0, (s, l) => s + l.distanceMeters);
    final totalDuration = legs.fold<int>(0, (s, l) => s + l.durationSeconds);

    debugPrint(
        '[DropsheetRoute] section=${section.id} in-place=${taskOrder.length} '
        'distance=${(totalDistance / 1000).toStringAsFixed(1)}km '
        'duration=${(totalDuration / 60).round()}min');

    return OptimizedRoute(
      sectionId: section.id,
      taskOrder: taskOrder,
      arrivalTimes: arrivalTimes,
      legBeforeStop: legBeforeStop,
      fullPolyline: fullPolyline,
      totalDistanceMeters: totalDistance,
      totalDurationSeconds: totalDuration,
      skippedTaskIds: skipped,
      computedAt: DateTime.now(),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Address _addressFor({
    required String id,
    required double lat,
    required double lng,
  }) =>
      Address(
        id: id,
        streetAddress: '',
        suburb: '',
        city: '',
        postalCode: '',
        province: '',
        country: '',
        latitude: lat,
        longitude: lng,
        isGeocoded: true,
      );

  ({int hour, int minute}) _parseStartTime(String hhmm) {
    final parts = hhmm.split(':');
    final h = int.tryParse(parts.elementAtOrNull(0) ?? '') ?? 7;
    final m = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 30;
    return (hour: h, minute: m);
  }

  String _fmtHHmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
