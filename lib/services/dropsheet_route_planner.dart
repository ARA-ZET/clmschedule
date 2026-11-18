import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/address.dart';
import '../models/dropsheet_day.dart';
import '../models/dropsheet_task.dart';
import '../models/dropsheet_task_type_config.dart';
import '../providers/dropsheet_task_config_provider.dart';
import 'appointment_timing.dart';
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

  /// The booked time (minutes after midnight) work here must start at —
  /// a time-slot job-list job's appointment. Null for most stops.
  final int? appointmentMinutes;

  RouteStop({
    required this.taskId,
    required this.taskType,
    required this.role,
    required this.label,
    required this.lat,
    required this.lng,
    required this.serviceMinutes,
    this.appointmentMinutes,
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

  /// stopKey → minutes waited for a booked time / minutes late for it.
  final Map<String, int> waitMinutes;
  final Map<String, int> lateMinutes;

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
    this.waitMinutes = const {},
    this.lateMinutes = const {},
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

  /// Provisional clock used **only** as the Directions API traffic-departure
  /// hint for the afternoon pick-up leg. Pick-ups typically begin mid-afternoon
  /// (~15:00–16:00, depending on how far the stops are from the office), so
  /// this lands the traffic estimates in a realistic window rather than the
  /// evening peak implied by the Arrive target. The absolute ETAs are
  /// re-anchored backwards to the Arrive task's target time afterwards, so this
  /// value affects traffic estimation only — never the times shown to drivers.
  static const String _afternoonStartEstimate = '15:00';

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
    // Locate the pickup-separator divider — if present, tasks after it form
    // the "afternoon leg" routed sequentially from the depot.
    final separatorTask = section.tasks
        .where((t) =>
            t.type == DropsheetTaskType.leave &&
            t.typeData['isPickupDivider'] == true)
        .firstOrNull;
    final separatorIdx =
        separatorTask == null ? -1 : section.tasks.indexOf(separatorTask);
    final hasSeparator = separatorIdx != -1;

    final morningStops = <RouteStop>[];
    final afternoonStops = <RouteStop>[];
    // All non-mandatory task IDs after the separator (including no-geo) kept
    // in original section order so their positions are preserved in taskOrder.
    final afternoonAllTaskIds = <String>[];
    final skipped = <String>[];
    // Accumulate service minutes for unrouted tasks (no coordinates) so the
    // total route duration and ETA remain realistic.
    var unroutedServiceMinutes = 0;

    for (var i = 0; i < section.tasks.length; i++) {
      final task = section.tasks[i];
      // The mandatory tasks happen at the depot before leaving — they
      // do not count as routing stops.
      if (task.isMandatory) continue;
      if (task.typeData['isPickupDivider'] == true) continue;

      final isAfternoon = hasSeparator && i > separatorIdx;

      if (isAfternoon && !afternoonAllTaskIds.contains(task.id)) {
        afternoonAllTaskIds.add(task.id);
      }

      final taskStops = _stopsForTask(task);
      if (taskStops.isEmpty) {
        if (!isAfternoon) {
          unroutedServiceMinutes += _config.serviceMinutesFor(task);
          skipped.add(task.id);
        }
        // Afternoon no-geo tasks: kept in taskOrder via afternoonAllTaskIds.
        continue;
      }

      if (isAfternoon) {
        afternoonStops.addAll(taskStops);
      } else {
        morningStops.addAll(taskStops);
      }
    }

    // Use morning stops for the greedy NN; when no separator exists fall back
    // to all stops (existing behaviour).
    final stops = hasSeparator
        ? morningStops
        : <RouteStop>[...morningStops, ...afternoonStops];

    debugPrint('[DropsheetRoute] section=${section.id} stops=${stops.length} '
        'afternoonStops=${afternoonStops.length} '
        'skipped=${skipped.length} unroutedMin=$unroutedServiceMinutes');

    if (stops.isEmpty && afternoonStops.isEmpty) return null;
    if (depot.lat == null || depot.lng == null) {
      debugPrint('[DropsheetRoute] depot not geocoded — aborting');
      return null;
    }

    // Cloud path: delegate the entire greedy nearest-neighbour to the
    // server, which already has access to the shared org-wide
    // routeCache. Falls back to the local path on any failure so the
    // user is never left without a result.
    // Cloud path is bypassed when a separator is present (two-leg routing
    // is handled locally).
    // Booked stops need time-aware ordering, which the cloud optimiser
    // doesn't do.
    final hasBookings = [...stops, ...afternoonStops]
        .any((s) => s.appointmentMinutes != null);
    if (useCloud && !hasSeparator && !hasBookings) {
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
    final legBeforeStopMap = <String, RouteLeg>{};
    final waits = <String, int>{};
    final lates = <String, int>{};

    String? currentId; // null at depot
    double currentLat = depot.lat!;
    double currentLng = depot.lng!;

    while (remaining.isNotEmpty) {
      // Determine whether any non-pickUp stops are still unvisited.
      // Pick-up stops are deferred until all drops and other tasks are
      // done — the car visits them on the way back to the office.
      // This constraint is skipped when a separator is present because
      // pick-ups are handled in the afternoon leg instead.
      final hasNonPickUp = !hasSeparator &&
          remaining.any((s) => s.taskType != DropsheetTaskType.pickUp);

      // A loaded truck drives straight to the offload: once a loading stop
      // is visited, its offload is the only candidate. The ETA replay
      // (DropsheetProvider) also assumes the two are back to back.
      final last = ordered.isEmpty ? null : ordered.last;
      final pendingOffload = last?.role == DropsheetTaskRole.loading
          ? remaining
              .where((s) =>
                  s.taskId == last!.taskId &&
                  s.role == DropsheetTaskRole.offload)
              .firstOrNull
          : null;

      // Filter to stops whose dependency (if any) has been satisfied,
      // and enforce the pickUp-last constraint.
      final eligible = pendingOffload != null
          ? [pendingOffload]
          : remaining.where((s) {
              // Defer pickUp stops until all other stops are exhausted.
              if (s.taskType == DropsheetTaskType.pickUp && hasNonPickUp) {
                return false;
              }
              // Furniture-move offload requires its loading stop to come first.
              if (s.role != DropsheetTaskRole.offload) return true;
              return ordered.any((o) =>
                  o.taskId == s.taskId && o.role == DropsheetTaskRole.loading);
            }).toList();
      // Should never happen given how stops are constructed, but guard
      // against an infinite loop.
      if (eligible.isEmpty) break;

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

      // Nearest stop, but never at the cost of a booking: see
      // [chooseNextStop].
      final reachable = <int>[
        for (var i = 0; i < eligible.length; i++)
          if (segments[i] != null) i,
      ];
      for (var i = 0; i < eligible.length; i++) {
        if (segments[i] == null) {
          debugPrint('[DropsheetRoute] no segment ${fromAddr.id} -> '
              '${eligible[i].stopKey}');
        }
      }
      final pick = chooseNextStop([
        for (final i in reachable)
          (
            // Traffic-aware seconds so the optimiser routes around
            // predicted congestion at this time of day.
            travelSeconds: segments[i]!.durationInTrafficSeconds,
            serviceMinutes: eligible[i].serviceMinutes,
            appointmentMinutes: eligible[i].appointmentMinutes,
            position: eligible[i].latLng,
          ),
      ], clock);
      final RouteStop? best = pick == null ? null : eligible[reachable[pick]];
      final bestSeg = pick == null ? null : segments[reachable[pick]]!;
      final RouteLeg? bestLeg = best == null
          ? null
          : RouteLeg(
              fromStopKey: currentId,
              toStopKey: best.stopKey,
              distanceMeters: bestSeg!.distanceMeters,
              durationSeconds: bestSeg.durationInTrafficSeconds,
              polyline: bestSeg.polylinePoints,
            );

      if (best == null || bestLeg == null) {
        debugPrint(
            '[DropsheetRoute] could not find next stop — aborting with ${ordered.length} visited');
        break;
      }

      ordered.add(best);
      legs.add(bestLeg);
      legBeforeStopMap[best.stopKey] = bestLeg;
      // Advance the clock by this leg's travel (and any wait for a booked
      // time) + service time.
      clock = _arrive(best, clock.add(Duration(seconds: bestLeg.durationSeconds)),
          arrivalTimes, waits, lates);
      clock = clock.add(Duration(minutes: best.serviceMinutes));

      remaining.removeWhere((s) => s.stopKey == best.stopKey);
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

    // Return leg: last morning stop → depot so the arrive task ETA is set.
    // Skipped when pick-ups follow (separator + routable afternoon stops): the
    // driver does NOT return to the office between drops and pick-ups — he
    // continues straight from his last drop-off, and the afternoon leg ends
    // with the real return-to-office leg instead.
    final continuesToPickups = hasSeparator && afternoonStops.isNotEmpty;
    if (ordered.isNotEmpty && !continuesToPickups) {
      final lastAddr =
          _addressFor(id: currentId!, lat: currentLat, lng: currentLng);
      final returnSeg = await _matrix.getRouteSegment(
        lastAddr,
        depotAddr,
        departureTime: clock,
      );
      if (returnSeg != null) {
        final returnLeg = RouteLeg(
          fromStopKey: currentId,
          toStopKey: '__depot',
          distanceMeters: returnSeg.distanceMeters,
          durationSeconds: returnSeg.durationInTrafficSeconds,
          polyline: returnSeg.polylinePoints,
        );
        legs.add(returnLeg);
        legBeforeStopMap['__depot'] = returnLeg;
        clock =
            clock.add(Duration(seconds: returnSeg.durationInTrafficSeconds));
        arrivalTimes['__depot'] = _fmtHHmm(clock);
      }
    }

    // ── Afternoon sequential leg ──────────────────────────────────────────
    // When a pickup separator exists, process afternoon tasks in their
    // original section order. The driver continues from his last morning
    // drop-off (not the office), so the first afternoon leg starts there;
    // tasks without geolocation are kept in taskOrder but receive no ETA.
    if (continuesToPickups) {
      // The afternoon leg is routed forward purely to obtain real leg
      // durations and relative spacing; the absolute ETAs are then shifted so
      // the final depot arrival lands on the Arrive task's target time. The
      // provisional forward start is a mid-afternoon estimate (used only as the
      // traffic departure hint); the shift re-anchors everything to the target.
      final targetArrive = _arriveTargetTime(section);
      final sepStart = _parseStartTime(_afternoonStartEstimate);
      var afClock = DateTime(
        baseDate.year,
        baseDate.month,
        baseDate.day,
        sepStart.hour,
        sepStart.minute,
      );
      // Continue from the last morning stop; fall back to the depot only if
      // there were no routable morning stops.
      var afLat = ordered.isNotEmpty ? currentLat : depot.lat!;
      var afLng = ordered.isNotEmpty ? currentLng : depot.lng!;
      String? afCurrentId = ordered.isNotEmpty ? currentId : null;
      final afRouted = <RouteStop>[];

      for (final stop in afternoonStops) {
        final fromAddr = afCurrentId == null
            ? depotAddr
            : _addressFor(id: afCurrentId, lat: afLat, lng: afLng);
        final toAddr =
            _addressFor(id: stop.stopKey, lat: stop.lat, lng: stop.lng);
        final seg = await _matrix.getRouteSegment(
          fromAddr,
          toAddr,
          departureTime: afClock,
        );
        if (seg == null) {
          debugPrint(
              '[DropsheetRoute] afternoon: no segment ${fromAddr.id} -> ${stop.stopKey}');
          continue;
        }
        final afLeg = RouteLeg(
          fromStopKey: afCurrentId,
          toStopKey: stop.stopKey,
          distanceMeters: seg.distanceMeters,
          durationSeconds: seg.durationInTrafficSeconds,
          polyline: seg.polylinePoints,
        );
        legs.add(afLeg);
        legBeforeStopMap[stop.stopKey] = afLeg;
        afRouted.add(stop);
        afClock = afClock.add(Duration(seconds: seg.durationInTrafficSeconds));
        arrivalTimes[stop.stopKey] = _fmtHHmm(afClock);
        afClock = afClock.add(Duration(minutes: stop.serviceMinutes));
        afCurrentId = stop.stopKey;
        afLat = stop.lat;
        afLng = stop.lng;
      }

      // Return leg: last afternoon stop → depot, so we know the provisional
      // depot arrival used to re-anchor the whole leg to the target time.
      if (afCurrentId != null) {
        final lastAddr = _addressFor(id: afCurrentId, lat: afLat, lng: afLng);
        final returnSeg = await _matrix.getRouteSegment(lastAddr, depotAddr,
            departureTime: afClock);
        if (returnSeg != null) {
          final returnLeg = RouteLeg(
            fromStopKey: afCurrentId,
            toStopKey: '__depot',
            distanceMeters: returnSeg.distanceMeters,
            durationSeconds: returnSeg.durationInTrafficSeconds,
            polyline: returnSeg.polylinePoints,
          );
          legs.add(returnLeg);
          legBeforeStopMap['__depot'] = returnLeg;
          afClock = afClock
              .add(Duration(seconds: returnSeg.durationInTrafficSeconds));
          arrivalTimes['__depot'] = _fmtHHmm(afClock);
        }
      }

      // Re-anchor so the driver is back at the target arrive time (later
      // only when a booking makes him wait).
      _timeAfternoon(
        routed: afRouted,
        legs: legBeforeStopMap,
        targetArrive: targetArrive,
        arrivalTimes: arrivalTimes,
        waits: waits,
        lates: lates,
      );

      debugPrint('[DropsheetRoute] afternoon leg: ${afternoonStops.length} '
          'stops, anchored to arrive=$targetArrive');
    }

    // Deduplicate morning task order (furniture-move contributes 2 stops).
    final taskOrder = <String>[];
    for (final s in ordered) {
      if (taskOrder.isEmpty || taskOrder.last != s.taskId) {
        taskOrder.add(s.taskId);
      }
    }

    // Append separator and ALL afternoon task IDs in original section order
    // (including no-geo tasks so their positions are preserved).
    if (hasSeparator && separatorTask != null) {
      taskOrder.add(separatorTask.id);
      for (final id in afternoonAllTaskIds) {
        if (!taskOrder.contains(id)) taskOrder.add(id);
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
      legBeforeStop: legBeforeStopMap,
      fullPolyline: fullPolyline,
      totalDistanceMeters: totalDistance,
      totalDurationSeconds: totalDuration,
      skippedTaskIds: skipped,
      computedAt: DateTime.now(),
      waitMinutes: waits,
      lateMinutes: lates,
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
      case DropsheetTaskType.distribute:
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
            // A booked move starts with the loading.
            appointmentMinutes: hhmmToMinutes(task.appointmentTime),
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
        appointmentMinutes: hhmmToMinutes(task.appointmentTime),
      ),
    ];
  }

  /// Calculate ETAs and leg data for the **current task order** without
  /// reordering. Equivalent to [optimizeSection] but the stop sequence is
  /// taken as-is from [section.tasks].
  ///
  /// When a pickup-separator is present the tasks are processed in two legs:
  ///   • **Morning leg** — tasks before the separator, starting at [startTime].
  ///   • **Afternoon leg** — tasks after the separator, starting at the
  ///     separator's departure time (default 17:30) with position reset to
  ///     the depot.  Afternoon tasks without coordinates are kept in
  ///     [taskOrder] so their position relative to the separator is preserved.
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

    // ── Locate pickup separator ─────────────────────────────────────────────
    final separatorTask = section.tasks
        .where((t) =>
            t.type == DropsheetTaskType.leave &&
            t.typeData['isPickupDivider'] == true)
        .firstOrNull;
    final separatorIdx =
        separatorTask == null ? -1 : section.tasks.indexOf(separatorTask);
    final hasSeparator = separatorIdx != -1;

    // Collect per-task routing data up-front (all synchronous).
    // Tag each datum as morning or afternoon so we can split the legs.
    final taskData =
        <({DropsheetTask task, List<RouteStop> stops, bool isAfternoon})>[];
    for (var i = 0; i < section.tasks.length; i++) {
      final task = section.tasks[i];
      if (task.isMandatory) continue;
      if (task.typeData['isPickupDivider'] == true) continue;
      taskData.add((
        task: task,
        stops: _stopsForTask(task),
        isAfternoon: hasSeparator && i > separatorIdx,
      ));
    }

    final morningData = taskData.where((d) => !d.isAfternoon).toList();
    final afternoonData = taskData.where((d) => d.isAfternoon).toList();

    final morningRoutable = morningData.fold(0, (s, d) => s + d.stops.length);
    final afternoonRoutable =
        afternoonData.fold(0, (s, d) => s + d.stops.length);
    final unroutedCount = taskData.where((d) => d.stops.isEmpty).length;
    debugPrint('[DropsheetRoute] section=${section.id} '
        'morningRoutable=$morningRoutable '
        'afternoonRoutable=$afternoonRoutable '
        'unrouted=$unroutedCount');
    if (morningRoutable == 0 && afternoonRoutable == 0) return null;

    final depotAddr =
        _addressFor(id: '__depot', lat: depot.lat!, lng: depot.lng!);

    final effectiveStartTime = startTime ?? depot.startTime;
    final start = _parseStartTime(effectiveStartTime);
    var clock = DateTime(
        baseDate.year, baseDate.month, baseDate.day, start.hour, start.minute);

    // Shared accumulators across both legs.
    final allOrdered = <RouteStop>[];
    final allLegs = <RouteLeg>[];
    final legBeforeStopMap = <String, RouteLeg>{};
    final arrivalTimes = <String, String>{};
    final skipped = <String>[];
    final taskOrder = <String>[];
    final waits = <String, int>{};
    final lates = <String, int>{};

    String? currentId;
    double currentLat = depot.lat!;
    double currentLng = depot.lng!;

    // ── Morning leg ─────────────────────────────────────────────────────────
    for (final d in morningData) {
      if (d.stops.isEmpty) {
        final serviceMin = _config.serviceMinutesFor(d.task);
        if (serviceMin > 0) {
          clock = clock.add(Duration(minutes: serviceMin));
          debugPrint('[DropsheetRoute] task=${d.task.id} (${d.task.type.name}) '
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
        allOrdered.add(stop);
        allLegs.add(leg);
        legBeforeStopMap[stop.stopKey] = leg;
        clock = _arrive(stop, clock.add(Duration(seconds: legDuration)),
            arrivalTimes, waits, lates);
        clock = clock.add(Duration(minutes: stop.serviceMinutes));
        currentId = stop.stopKey;
        currentLat = stop.lat;
        currentLng = stop.lng;
      }
    }

    // Build morning task order in original section order, including skipped
    // tasks (those without geocoded coordinates) so they stay in their
    // original position rather than being moved to the end of the section.
    for (final d in morningData) {
      if (!taskOrder.contains(d.task.id)) {
        taskOrder.add(d.task.id);
      }
    }

    // Return leg after morning so the arrive task gets an ETA even if no
    // afternoon leg follows. Skipped when pick-ups follow: the driver does NOT
    // return to the office between drops and pick-ups — he continues straight
    // from his last drop-off, and the afternoon leg ends with the real
    // return-to-office leg instead.
    final continuesToPickups = hasSeparator && afternoonRoutable > 0;
    if (currentId != null && !continuesToPickups) {
      final lastAddr =
          _addressFor(id: currentId, lat: currentLat, lng: currentLng);
      final returnSeg = await _matrix.getRouteSegment(lastAddr, depotAddr,
          departureTime: clock);
      if (returnSeg != null) {
        final returnLeg = RouteLeg(
          fromStopKey: currentId,
          toStopKey: '__depot',
          distanceMeters: returnSeg.distanceMeters,
          durationSeconds: returnSeg.durationInTrafficSeconds,
          polyline: returnSeg.polylinePoints,
        );
        allLegs.add(returnLeg);
        legBeforeStopMap['__depot'] = returnLeg;
        clock =
            clock.add(Duration(seconds: returnSeg.durationInTrafficSeconds));
        arrivalTimes['__depot'] = _fmtHHmm(clock);
      }
    }

    // ── Afternoon leg ────────────────────────────────────────────────────────
    if (hasSeparator) {
      taskOrder.add(separatorTask!.id);

      if (afternoonData.isNotEmpty) {
        // The driver continues from his last morning drop-off (not the office),
        // so the afternoon leg starts there. We only reset the clock to a
        // mid-afternoon estimate (traffic hint only); the absolute ETAs are
        // re-anchored afterwards so the final depot arrival equals the Arrive
        // task's target time. currentId/currentLat/currentLng are intentionally
        // carried over from the morning leg — fall back to the depot only when
        // there were no routable morning stops.
        final targetArrive = _arriveTargetTime(section);
        final sepStart = _parseStartTime(_afternoonStartEstimate);
        clock = DateTime(baseDate.year, baseDate.month, baseDate.day,
            sepStart.hour, sepStart.minute);

        final afOrdered = <RouteStop>[];

        for (final d in afternoonData) {
          if (d.stops.isEmpty) {
            // No coordinates: preserve position in taskOrder, skip routing.
            if (!taskOrder.contains(d.task.id)) taskOrder.add(d.task.id);
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
              debugPrint('[DropsheetRoute] afternoon: no segment '
                  '${fromAddr.id} -> ${candAddr.id}');
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
            afOrdered.add(stop);
            allLegs.add(leg);
            legBeforeStopMap[stop.stopKey] = leg;
            clock = clock.add(Duration(seconds: legDuration));
            arrivalTimes[stop.stopKey] = _fmtHHmm(clock);
            clock = clock.add(Duration(minutes: stop.serviceMinutes));
            currentId = stop.stopKey;
            currentLat = stop.lat;
            currentLng = stop.lng;
          }
          if (!taskOrder.contains(d.task.id)) taskOrder.add(d.task.id);
        }

        // Return leg after afternoon — sets the final arrive task ETA.
        if (afOrdered.isNotEmpty && currentId != null) {
          final lastAddr =
              _addressFor(id: currentId, lat: currentLat, lng: currentLng);
          final returnSeg = await _matrix.getRouteSegment(lastAddr, depotAddr,
              departureTime: clock);
          if (returnSeg != null) {
            final returnLeg = RouteLeg(
              fromStopKey: currentId,
              toStopKey: '__depot',
              distanceMeters: returnSeg.distanceMeters,
              durationSeconds: returnSeg.durationInTrafficSeconds,
              polyline: returnSeg.polylinePoints,
            );
            allLegs.add(returnLeg);
            legBeforeStopMap['__depot'] = returnLeg;
            clock = clock
                .add(Duration(seconds: returnSeg.durationInTrafficSeconds));
            arrivalTimes['__depot'] = _fmtHHmm(clock);
          }
        }

        // Re-anchor so the driver is back at the target arrive time (later
        // only when a booking makes him wait).
        _timeAfternoon(
          routed: afOrdered,
          legs: legBeforeStopMap,
          targetArrive: targetArrive,
          arrivalTimes: arrivalTimes,
          waits: waits,
          lates: lates,
        );

        debugPrint('[DropsheetRoute] afternoon in-place: ${afOrdered.length} '
            'stops, anchored to arrive=$targetArrive');
      }
    }

    final fullPolyline = <LatLng>[];
    for (final leg in allLegs) {
      if (leg.polyline.isEmpty) continue;
      if (fullPolyline.isEmpty) {
        fullPolyline.addAll(leg.polyline);
      } else {
        fullPolyline.addAll(leg.polyline.skip(1));
      }
    }

    final totalDistance =
        allLegs.fold<double>(0, (s, l) => s + l.distanceMeters);
    final totalDuration = allLegs.fold<int>(0, (s, l) => s + l.durationSeconds);

    debugPrint(
        '[DropsheetRoute] section=${section.id} in-place=${taskOrder.length} '
        'distance=${(totalDistance / 1000).toStringAsFixed(1)}km '
        'duration=${(totalDuration / 60).round()}min');

    return OptimizedRoute(
      sectionId: section.id,
      taskOrder: taskOrder,
      arrivalTimes: arrivalTimes,
      legBeforeStop: legBeforeStopMap,
      fullPolyline: fullPolyline,
      totalDistanceMeters: totalDistance,
      totalDurationSeconds: totalDuration,
      skippedTaskIds: skipped,
      computedAt: DateTime.now(),
      waitMinutes: waits,
      lateMinutes: lates,
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

  /// The target time the driver should arrive back at the office, taken from
  /// the Arrive task's `startTime`. Defaults to `17:30` when unset. Afternoon
  /// pick-up ETAs are anchored to this value and computed backwards.
  String _arriveTargetTime(DropsheetDriverSection section) {
    final arrive = section.tasks
        .where(
            (t) => t.type == DropsheetTaskType.arrive && t.startTime.isNotEmpty)
        .firstOrNull;
    return arrive?.startTime ?? '17:30';
  }

  int _minutesOfHHmm(String hhmm) {
    final p = _parseStartTime(hhmm);
    return p.hour * 60 + p.minute;
  }


  /// Reaching [stop] at [arrival]: work starts then, or at its booked time
  /// if that is later. Records the start in [arrivalTimes] and any wait /
  /// lateness; returns the start.
  DateTime _arrive(
    RouteStop stop,
    DateTime arrival,
    Map<String, String> arrivalTimes,
    Map<String, int> waits,
    Map<String, int> lates,
  ) {
    final met = meetAppointment(arrival, stop.appointmentMinutes);
    arrivalTimes[stop.stopKey] = _fmtHHmm(met.start);
    if (met.waitMinutes > 0) waits[stop.stopKey] = met.waitMinutes;
    if (met.lateMinutes > 0) lates[stop.stopKey] = met.lateMinutes;
    return met.start;
  }

  /// Times the afternoon (post-separator) run [routed] — legs in [legs] —
  /// so the final depot arrival equals [targetArrive]. The run is routed
  /// forward first only to get real leg durations; this works the times
  /// back from the target, starts earlier if that would miss a booking, and
  /// lets an unavoidable wait for a booking bring the driver back later
  /// (see [timeRunToArrive]). Mutates [arrivalTimes], [waits], [lates].
  void _timeAfternoon({
    required List<RouteStop> routed,
    required Map<String, RouteLeg> legs,
    required String targetArrive,
    required Map<String, String> arrivalTimes,
    required Map<String, int> waits,
    required Map<String, int> lates,
  }) {
    final target = _minutesOfHHmm(targetArrive) * 60;
    if (routed.isEmpty) {
      arrivalTimes['__depot'] = targetArrive;
      return;
    }
    final returnLeg = legs['__depot'];
    final times = timeRunToArrive(
      [
        for (final s in routed)
          (
            legSeconds: legs[s.stopKey]?.durationSeconds ?? 0,
            serviceMinutes: s.serviceMinutes,
            appointment: s.appointmentMinutes,
          ),
      ],
      target,
      returnLeg?.durationSeconds ?? 0,
    );
    for (var i = 0; i < routed.length; i++) {
      final key = routed[i].stopKey;
      arrivalTimes[key] = secondsToHHmm(times.startSeconds[i]);
      if (times.waitMinutes[i] > 0) waits[key] = times.waitMinutes[i];
      if (times.lateMinutes[i] > 0) lates[key] = times.lateMinutes[i];
    }
    arrivalTimes['__depot'] =
        returnLeg == null ? targetArrive : secondsToHHmm(times.endSeconds);
  }
}
