// services/client_map_allocation_service.dart
//
// Allocating a Job List job's client-map areas to distributors on the
// schedule, by link (`JobAreaLink`) rather than by copy.
//
// Rules (agreed with the user):
//  * Targets are schedule jobs that already carry the Job List client, from
//    [kSlackBefore] before the Job List date onwards. The flow never creates
//    schedule jobs — a distributor gets the client on the schedule first.
//  * An area normally has one current owner. Allocating it again asks to
//    MOVE it (unlinked from the old job in the same transaction) or SPLIT it
//    (both keep it, e.g. a big area over two days).
//  * A job whose day has passed, or whose link is frozen, is history, not a
//    current owner: it is shown, but a move never takes the area off it.
//  * An area COPIED onto a job (a regular-client round, or the older "add
//    linked map polygons") counts as held too. Moving or re-allocating it
//    converts it: the copy comes off and a link goes on, in one transaction.
//
// Who holds which area is read straight off the schedule jobs in the window
// — nothing is stored on the map — so the two sides cannot drift apart.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../models/job_area_link.dart';
import '../models/job_list_item.dart';
import '../models/regular_client.dart' show kRegularClientSlotPalette;
import '../shareable_maps/models/shareable_map.dart';
import '../shareable_maps/utils/linked_map_polygons.dart'
    show polygonGeometryKey;
import '../utils/schedule_time.dart';
import 'firestore_service.dart';
import 'job_list_service.dart';

/// How far before the Job List date a schedule job still counts as a target.
const Duration kSlackBefore = Duration(days: 3);

/// How far after the Job List date the schedule is searched.
const Duration kSearchAfter = Duration(days: 60);

/// Colour of an area no distributor holds.
const Color kUnallocatedAreaColor = Color(0xFF9E9E9E);

/// One job's hold on one area: by [link], by a [copy] in its `workMaps`, or
/// both (allocated before an old copy was converted).
class AreaHolding {
  final Job job;
  final String polygonId;
  final JobAreaLink? link;
  final CustomPolygon? copy;

  const AreaHolding(this.job, this.polygonId, {this.link, this.copy})
      : assert(link != null || copy != null);

  /// Held only through a copy, not a link.
  bool get isCopy => link == null;

  /// Worked already: frozen, or its day is before today. History — never
  /// counted as the current owner and never unlinked by a move.
  bool get isHistory =>
      (link?.isFrozen ?? false) || job.date.isBefore(scheduleToday());

  String get name => link?.name.isNotEmpty == true
      ? link!.name
      : (copy?.name ?? link?.name ?? '');

  /// The change that takes this area off [job]: the link, the copy, or both.
  AreaLinkChange removal() => AreaLinkChange(
        jobId: job.id,
        date: job.date,
        removeKeys: {if (link != null) link!.key},
        removeCopyIds: {if (copy?.id != null) copy!.id!},
        removeCopyGeometryKeys: {if (copy != null) polygonGeometryKey(copy!)},
      );
}

/// One scheduled day of one distributor and the map's areas it holds.
class AllocationDay {
  final Job job;
  final List<AreaHolding> holdings;
  const AllocationDay(this.job, this.holdings);
}

/// A distributor's days on this client, in date order.
class AllocationGroup {
  final String distributorId;
  final Color color;
  final List<AllocationDay> days;
  const AllocationGroup(this.distributorId, this.color, this.days);
}

class ClientMapAllocationService {
  final FirestoreService _schedule;
  final JobListService _jobList;

  ClientMapAllocationService({
    FirestoreService? schedule,
    JobListService? jobList,
  })  : _schedule = schedule ?? FirestoreService(),
        _jobList = jobList ?? JobListService(FirebaseFirestore.instance);

  // ── Job List side ──────────────────────────────────────────────────────

  /// The Job List job [map] was made for. Job List items live in per-month
  /// collections and the map's month is only its creation month, so the
  /// months around it are tried too.
  Future<JobListItem?> jobListItemFor(ShareableMap map, String monthKey) async {
    final itemId = map.jobListItemId;
    if (itemId == null || itemId.isEmpty) return null;

    final months = <DateTime>[];
    void add(DateTime d) {
      final m = DateTime(d.year, d.month);
      if (!months.contains(m)) months.add(m);
    }

    final parts = monthKey.split('-');
    final mm = parts.length == 2 ? int.tryParse(parts[0]) : null;
    final yyyy = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (mm != null && yyyy != null) {
      add(DateTime(yyyy, mm));
      add(DateTime(yyyy, mm + 1));
      add(DateTime(yyyy, mm - 1));
    }
    final now = scheduleToday();
    add(now);
    add(DateTime(now.year, now.month - 1));
    add(DateTime(now.year, now.month + 1));

    for (final month in months) {
      try {
        final item = await _jobList.getJobListItemById(itemId, month);
        if (item != null) return item;
      } catch (e) {
        debugPrint('[Allocation] job-list lookup $itemId in $month: $e');
      }
    }
    return null;
  }

  // ── Schedule side ──────────────────────────────────────────────────────

  /// The first day a schedule job counts as a target for [jobListDate].
  static DateTime windowStart(DateTime jobListDate) {
    final d = DateTime(jobListDate.year, jobListDate.month, jobListDate.day);
    return d.subtract(kSlackBefore);
  }

  static DateTime windowEnd(DateTime jobListDate) {
    final d = DateTime(jobListDate.year, jobListDate.month, jobListDate.day);
    return d.add(kSearchAfter);
  }

  /// Live schedule jobs dated [from]..[to] (inclusive), with linked areas
  /// resolved. One listener per month touched.
  Stream<List<Job>> watchJobs(DateTime from, DateTime to) {
    final months = <DateTime>[];
    for (var m = DateTime(from.year, from.month);
        !m.isAfter(DateTime(to.year, to.month));
        m = DateTime(m.year, m.month + 1)) {
      months.add(m);
    }
    final last = DateTime(to.year, to.month, to.day, 23, 59, 59);

    late StreamController<List<Job>> controller;
    final subs = <StreamSubscription<List<Job>>>[];
    final byMonth = <int, List<Job>>{};

    controller = StreamController<List<Job>>(
      onListen: () {
        for (var i = 0; i < months.length; i++) {
          subs.add(_schedule.streamJobsForMonth(months[i]).listen((jobs) {
            byMonth[i] = jobs;
            if (byMonth.length < months.length || controller.isClosed) return;
            controller.add([
              for (final list in byMonth.values)
                for (final j in list)
                  if (!j.date.isBefore(from) && !j.date.isAfter(last)) j,
            ]);
          }, onError: controller.addError));
        }
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return controller.stream;
  }

  /// Client names are free text on both sides — compare them loosely.
  static String normaliseClient(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Schedule jobs [client] can be allocated to: they already carry the
  /// client and are dated on or after [from]. Sorted by date.
  static List<Job> candidates(List<Job> jobs, String client, DateTime from) {
    final want = normaliseClient(client);
    if (want.isEmpty) return const [];
    return jobs
        .where((j) =>
            !j.date.isBefore(from) &&
            j.clients.any((c) => normaliseClient(c) == want))
        .toList()
      ..sort((a, b) {
        final byDate = a.date.compareTo(b.date);
        return byDate != 0
            ? byDate
            : a.distributorId.compareTo(b.distributorId);
      });
  }

  /// Every job's hold on the polygons of map [mapId], keyed by polygon id.
  ///
  /// [mapPolygons] may include the map's points (as point-type polygons):
  /// a point is allocated just like an area.
  ///
  /// With [client] and [mapPolygons], copies of the map's polygons in the
  /// `workMaps` of jobs carrying [client] count too — matched by polygon id,
  /// else by outline. Points match by id only: a job's own address or
  /// drop-off pin can sit on the same spot as a client-map point.
  static Map<String, List<AreaHolding>> holdingsByPolygon(
    List<Job> jobs,
    String mapId, {
    String? client,
    List<CustomPolygon> mapPolygons = const [],
  }) {
    final ids = <String>{};
    final idByGeometry = <String, String>{};
    for (final p in mapPolygons) {
      final id = p.id;
      if (id == null || id.isEmpty) continue;
      ids.add(id);
      if (p.isPolygon) {
        idByGeometry.putIfAbsent(polygonGeometryKey(p), () => id);
      }
    }
    final want = client == null ? '' : normaliseClient(client);

    final out = <String, List<AreaHolding>>{};
    for (final job in jobs) {
      final links = <String, JobAreaLink>{
        for (final link in job.areaLinks)
          if (link.mapId == mapId) link.polygonId: link,
      };
      final copies = <String, CustomPolygon>{};
      if (want.isNotEmpty &&
          ids.isNotEmpty &&
          job.clients.any((c) => normaliseClient(c) == want)) {
        for (final p in job.workMaps) {
          if (JobAreaLink.isResolved(p)) continue;
          final id = (p.id != null && ids.contains(p.id))
              ? p.id!
              : (p.isPolygon ? idByGeometry[polygonGeometryKey(p)] : null);
          if (id != null) copies.putIfAbsent(id, () => p);
        }
      }
      for (final id in {...links.keys, ...copies.keys}) {
        out
            .putIfAbsent(id, () => [])
            .add(AreaHolding(job, id, link: links[id], copy: copies[id]));
      }
    }
    for (final list in out.values) {
      list.sort((a, b) => a.job.date.compareTo(b.job.date));
    }
    return out;
  }

  /// The current (non-history) owners in [holdings].
  static List<AreaHolding> currentOwners(List<AreaHolding>? holdings) =>
      holdings == null
          ? const []
          : holdings.where((h) => !h.isHistory).toList();

  /// The changes that give [polygons] of map [mapId]/[monthKey] to
  /// [target]. With [move], every other current owner loses them in the same
  /// transaction; without it they keep them too (a split).
  static List<AreaLinkChange> allocationChanges({
    required String mapId,
    required String monthKey,
    required List<CustomPolygon> polygons,
    required Job target,
    required Map<String, List<AreaHolding>> holdings,
    required bool move,
  }) {
    final add = [
      for (final p in polygons)
        if (p.id != null)
          JobAreaLink(
            mapId: mapId,
            monthKey: monthKey,
            polygonId: p.id!,
            name: p.name,
          ),
    ];
    // The target's own copies of these areas become the new links.
    final targetCopies = <AreaHolding>[
      for (final link in add)
        for (final h in holdings[link.polygonId] ?? const <AreaHolding>[])
          if (h.job.id == target.id && h.copy != null) h,
    ];
    final removals = <String, List<AreaHolding>>{};
    if (move) {
      for (final link in add) {
        for (final h in currentOwners(holdings[link.polygonId])) {
          if (h.job.id == target.id) continue;
          removals.putIfAbsent(h.job.id, () => []).add(h);
        }
      }
    }
    return [
      AreaLinkChange(
        jobId: target.id,
        date: target.date,
        add: add,
        removeCopyIds: {
          for (final h in targetCopies)
            if (h.copy!.id != null) h.copy!.id!,
        },
        removeCopyGeometryKeys: {
          for (final h in targetCopies) polygonGeometryKey(h.copy!),
        },
      ),
      for (final list in removals.values) _merge(list),
    ];
  }

  /// One change that takes every holding in [list] (all one job) off it.
  static AreaLinkChange _merge(List<AreaHolding> list) {
    final parts = list.map((h) => h.removal()).toList();
    return AreaLinkChange(
      jobId: list.first.job.id,
      date: list.first.job.date,
      removeKeys: {for (final c in parts) ...c.removeKeys},
      removeCopyIds: {for (final c in parts) ...c.removeCopyIds},
      removeCopyGeometryKeys: {
        for (final c in parts) ...c.removeCopyGeometryKeys
      },
    );
  }

  /// The changes that move [holding] to [target]: a link on the target
  /// (replacing any copy it has), and the link or copy off the old job.
  static List<AreaLinkChange> moveChanges({
    required String mapId,
    required String monthKey,
    required AreaHolding holding,
    required Job target,
    required Map<String, List<AreaHolding>> holdings,
  }) {
    final targetCopy = (holdings[holding.polygonId] ?? const <AreaHolding>[])
        .where((h) => h.job.id == target.id && h.copy != null)
        .map((h) => h.copy!)
        .firstOrNull;
    return [
      AreaLinkChange(
        jobId: target.id,
        date: target.date,
        add: [
          JobAreaLink(
            mapId: mapId,
            monthKey: monthKey,
            polygonId: holding.polygonId,
            name: holding.name,
          ),
        ],
        removeCopyIds: {if (targetCopy?.id != null) targetCopy!.id!},
        removeCopyGeometryKeys: {
          if (targetCopy != null) polygonGeometryKey(targetCopy)
        },
      ),
      holding.removal(),
    ];
  }

  // ── Colours & grouping ─────────────────────────────────────────────────

  /// A colour per distributor in [jobs], handed out by first scheduled date
  /// then [names] (falling back to id), so the same people keep the same
  /// colours as long as the schedule does.
  static Map<String, Color> distributorColours(List<Job> jobs,
      {Map<String, String> names = const {}}) {
    final first = <String, DateTime>{};
    for (final j in jobs) {
      final d = first[j.distributorId];
      if (d == null || j.date.isBefore(d)) first[j.distributorId] = j.date;
    }
    String label(String id) => (names[id] ?? id).toLowerCase();
    final order = first.keys.toList()
      ..sort((a, b) {
        final byDate = first[a]!.compareTo(first[b]!);
        return byDate != 0 ? byDate : label(a).compareTo(label(b));
      });
    return {
      for (var i = 0; i < order.length; i++)
        order[i]: kRegularClientSlotPalette[i % kRegularClientSlotPalette.length],
    };
  }

  /// [candidates] plus every other job holding one of the map's areas
  /// (history before the window), grouped per distributor, each with its
  /// days in date order and the areas held that day.
  static List<AllocationGroup> groups(
    List<Job> candidates,
    Map<String, List<AreaHolding>> holdings,
    Map<String, Color> colours,
  ) {
    final jobs = <String, Job>{for (final j in candidates) j.id: j};
    final byJob = <String, List<AreaHolding>>{};
    for (final list in holdings.values) {
      for (final h in list) {
        jobs.putIfAbsent(h.job.id, () => h.job);
        byJob.putIfAbsent(h.job.id, () => []).add(h);
      }
    }
    final byDistributor = <String, List<AllocationDay>>{};
    for (final j in jobs.values) {
      byDistributor
          .putIfAbsent(j.distributorId, () => [])
          .add(AllocationDay(j, byJob[j.id] ?? const []));
    }
    final out = [
      for (final e in byDistributor.entries)
        AllocationGroup(
          e.key,
          colours[e.key] ?? kUnallocatedAreaColor,
          e.value..sort((a, b) => a.job.date.compareTo(b.job.date)),
        ),
    ];
    // By first day; colour order where those tie.
    final rank = {
      for (final (i, id) in colours.keys.indexed) id: i,
    };
    out.sort((a, b) {
      final byDate = a.days.first.job.date.compareTo(b.days.first.job.date);
      return byDate != 0
          ? byDate
          : (rank[a.distributorId] ?? 0).compareTo(rank[b.distributorId] ?? 0);
    });
    return out;
  }

  /// The colour an allocated element is drawn in: its current owner's, or
  /// once worked its latest holder's; grey when nobody holds it.
  static Color colourFor(
      List<AreaHolding>? held, Map<String, Color> colours) {
    if (held == null || held.isEmpty) return kUnallocatedAreaColor;
    final current = currentOwners(held);
    final owner = current.isNotEmpty ? current.first : held.last;
    return colours[owner.job.distributorId] ?? kUnallocatedAreaColor;
  }

  /// [p] as the allocation view draws it: grey when nobody holds it, else
  /// the colour of its current owner (or, once worked, its latest holder),
  /// with a heavy outline when more than one distributor shares it.
  static CustomPolygon styleFor(CustomPolygon p, List<AreaHolding>? held,
      Map<String, Color> colours) {
    if (held == null || held.isEmpty) {
      return p.copyWith(
          color: kUnallocatedAreaColor, fillOpacity: 0.25, strokeWidth: 2);
    }
    final current = currentOwners(held);
    final shared = {for (final h in held) h.job.distributorId}.length > 1;
    return p.copyWith(
      color: colourFor(held, colours),
      fillOpacity: current.isEmpty ? 0.3 : 0.45,
      strokeWidth: shared ? 5 : 2,
    );
  }

  Future<void> apply(List<AreaLinkChange> changes, {required String action}) =>
      _schedule.applyAreaLinkChanges(changes, action: action);

  /// Takes [holding]'s area off its job — the link, the copy, or both.
  Future<void> unallocate(AreaHolding holding) =>
      apply([holding.removal()], action: 'unallocateArea');
}
