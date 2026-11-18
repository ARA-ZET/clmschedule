// services/area_link_resolver.dart
//
// Turns a schedule job's `JobAreaLink`s back into polygons.
//
// Every read of schedule jobs (`FirestoreService` streams and fetches) goes
// through here, so each job arrives with its linked client-map areas already
// in `Job.workMaps`. That is what lets the print map, map PDF, day planner,
// track editor and unfinished-areas matching work on linked areas without
// knowing links exist.
//
// Each referenced client map is watched once, however many jobs point at it.
// When one changes, [changes] fires with its key and the job streams re-emit,
// so an edit on the client map reaches every job allocated from it.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../models/job_area_link.dart';
import '../shareable_maps/models/shareable_map.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import '../shareable_maps/utils/linked_map_polygons.dart';

/// What the resolver currently knows about one client map.
class _MapEntry {
  /// Polygons — and points, as point-type polygons — by stable id. Null
  /// until the first snapshot arrives.
  Map<String, CustomPolygon>? polygons;

  /// Map name, for naming unnamed polygons.
  String name = '';

  /// False once the map document is known not to exist.
  bool exists = true;

  StreamSubscription<ShareableMap?>? sub;

  /// Completes on the first snapshot (or error), for one-off reads.
  final Completer<void> ready = Completer<void>();
}

class AreaLinkResolver {
  AreaLinkResolver._();
  static final AreaLinkResolver instance = AreaLinkResolver._();

  final ShareableMapsFirestoreService _maps = ShareableMapsFirestoreService();
  final Map<String, _MapEntry> _entries = {};
  final StreamController<Set<String>> _changes = StreamController.broadcast();

  /// Map keys changed since the last [_changes] flush.
  final Set<String> _changedKeys = {};
  Timer? _flushTimer;

  /// How long changes are gathered before job streams re-emit. A month with
  /// many linked maps loads them one by one; without this each arrival
  /// re-hydrated and re-emitted the whole month (and rebuilt the grid).
  static const Duration _flushDelay = Duration(milliseconds: 150);

  /// Fires with the map keys (`monthKey/mapId`) whose polygons changed, or
  /// first arrived, gathered over [_flushDelay].
  Stream<Set<String>> get changes => _changes.stream;

  static String mapKeyOf(JobAreaLink l) => '${l.monthKey}/${l.mapId}';

  void _markChanged(String key) {
    _changedKeys.add(key);
    _flushTimer ??= Timer(_flushDelay, () {
      _flushTimer = null;
      final keys = Set<String>.of(_changedKeys);
      _changedKeys.clear();
      if (keys.isNotEmpty) _changes.add(keys);
    });
  }

  /// Whether two snapshots of a map look the same to the jobs linked to it:
  /// existence, name, and every polygon/point by id ([CustomPolygon]
  /// compares by value). A snapshot that changes nothing they use (layer
  /// styling, metadata, other fields) then doesn't re-hydrate every month.
  @visibleForTesting
  static bool sameLinkedContent(
    ({bool exists, String name, Map<String, CustomPolygon> polygons}) a,
    ({bool exists, String name, Map<String, CustomPolygon> polygons}) b,
  ) =>
      a.exists == b.exists &&
      a.name == b.name &&
      mapEquals(a.polygons, b.polygons);

  _MapEntry _watch(String monthKey, String mapId) {
    final key = '$monthKey/$mapId';
    return _entries.putIfAbsent(key, () {
      final entry = _MapEntry();
      entry.sub = _maps.streamMap(monthKey, mapId).listen((map) {
        final bool exists;
        final String name;
        final Map<String, CustomPolygon> polygons;
        if (map == null) {
          exists = false;
          name = entry.name;
          polygons = const {};
        } else {
          exists = true;
          name = map.name;
          polygons = {
            for (final layer in map.layers) ...{
              for (final p in layer.polygons)
                if (p.id != null && p.isPolygon) p.id!: p,
              // Allocated points (traffic lights, handout spots).
              for (final pt in layer.points)
                if (pt.id.isNotEmpty) pt.id: mapPointAsWorkMap(pt),
            },
          };
        }
        final previous = entry.polygons;
        final unchanged = previous != null &&
            sameLinkedContent(
              (exists: entry.exists, name: entry.name, polygons: previous),
              (exists: exists, name: name, polygons: polygons),
            );
        entry
          ..exists = exists
          ..name = name
          ..polygons = polygons;
        if (!entry.ready.isCompleted) entry.ready.complete();
        if (!unchanged) _markChanged(key);
      }, onError: (Object e) {
        debugPrint('[AreaLinkResolver] watching $key failed: $e');
        if (!entry.ready.isCompleted) entry.ready.complete();
      });
      return entry;
    });
  }

  /// The client map's current version of [link]'s polygon, styled as an
  /// allocated area. Null while the map is still loading or when the polygon
  /// no longer exists (see [isMissing]).
  CustomPolygon? resolve(JobAreaLink link) {
    final frozen = link.frozen;
    if (frozen != null) {
      return frozen.copyWith(
        id: link.resolvedId,
        name: frozen.name.trim().isNotEmpty ? frozen.name : link.name,
      );
    }
    final entry = _watch(link.monthKey, link.mapId);
    final p = entry.polygons?[link.polygonId];
    if (p == null) return null;
    final name = p.name.trim().isNotEmpty
        ? p.name
        : (link.name.trim().isNotEmpty ? link.name : entry.name);
    // A point keeps its own look (its category colour and icon).
    return (p.isPoint ? p : allocatedPolygonStyle(p))
        .copyWith(id: link.resolvedId, name: name);
  }

  /// True once the map has loaded and [link]'s polygon is not on it.
  bool isMissing(JobAreaLink link) {
    if (link.isFrozen) return false;
    final entry = _watch(link.monthKey, link.mapId);
    final polys = entry.polygons;
    return polys != null && !polys.containsKey(link.polygonId);
  }

  /// [job] with its linked areas resolved from what is loaded right now.
  /// Starts watching any map not seen before; [changes] fires when it
  /// arrives. Jobs without links are returned as they are.
  Job hydrate(Job job) {
    if (job.areaLinks.isEmpty && job.resolvedAreaNames.isEmpty) return job;
    final resolved = <CustomPolygon>[];
    final missing = <String>{};
    final seen = <String>{};
    for (final link in job.areaLinks) {
      if (!seen.add(link.key)) continue;
      final p = resolve(link);
      if (p != null) {
        resolved.add(p);
      } else if (isMissing(link)) {
        missing.add(link.key);
      }
    }
    return job.withResolvedAreas(resolved, missingKeys: missing);
  }

  List<Job> hydrateAll(List<Job> jobs) => [for (final j in jobs) hydrate(j)];

  /// Like [hydrateAll], but first waits (up to [timeout]) for every map the
  /// jobs link to — for one-off reads that have no later emission to catch
  /// up with, such as track-editor processing.
  Future<List<Job>> hydrateAllLoaded(
    List<Job> jobs, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final waits = <Future<void>>[];
    for (final job in jobs) {
      for (final link in job.areaLinks) {
        if (link.isFrozen) continue;
        waits.add(_watch(link.monthKey, link.mapId).ready.future);
      }
    }
    if (waits.isNotEmpty) {
      try {
        await Future.wait(waits).timeout(timeout);
      } on TimeoutException {
        debugPrint('[AreaLinkResolver] timed out waiting for linked maps');
      }
    }
    return hydrateAll(jobs);
  }

  /// [source] with every emission hydrated, re-emitted whenever a map one of
  /// its jobs links to changes.
  Stream<List<Job>> hydrateStream(Stream<List<Job>> source) {
    late StreamController<List<Job>> controller;
    StreamSubscription<List<Job>>? sourceSub;
    StreamSubscription<Set<String>>? changeSub;
    List<Job>? last;

    controller = StreamController<List<Job>>(
      onListen: () {
        changeSub = changes.listen((mapKeys) {
          final jobs = last;
          if (jobs == null || controller.isClosed) return;
          final affected = jobs.any(
              (j) => j.areaLinks.any((l) => mapKeys.contains(mapKeyOf(l))));
          if (affected) controller.add(hydrateAll(jobs));
        });
        sourceSub = source.listen(
          (jobs) {
            last = jobs;
            if (!controller.isClosed) controller.add(hydrateAll(jobs));
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () async {
        await changeSub?.cancel();
        await sourceSub?.cancel();
      },
    );
    return controller.stream;
  }
}
