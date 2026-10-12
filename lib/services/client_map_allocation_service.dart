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
//
// Who holds which area is read straight off the schedule jobs in the window
// — nothing is stored on the map — so the two sides cannot drift apart.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../models/job_area_link.dart';
import '../models/job_list_item.dart';
import '../shareable_maps/models/shareable_map.dart';
import '../utils/schedule_time.dart';
import 'firestore_service.dart';
import 'job_list_service.dart';

/// How far before the Job List date a schedule job still counts as a target.
const Duration kSlackBefore = Duration(days: 3);

/// How far after the Job List date the schedule is searched.
const Duration kSearchAfter = Duration(days: 60);

/// One job's hold on one area.
class AreaHolding {
  final Job job;
  final JobAreaLink link;
  const AreaHolding(this.job, this.link);

  /// Worked already: frozen, or its day is before today. History — never
  /// counted as the current owner and never unlinked by a move.
  bool get isHistory => link.isFrozen || job.date.isBefore(scheduleToday());
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
  static Map<String, List<AreaHolding>> holdingsByPolygon(
      List<Job> jobs, String mapId) {
    final out = <String, List<AreaHolding>>{};
    for (final job in jobs) {
      for (final link in job.areaLinks) {
        if (link.mapId != mapId) continue;
        out.putIfAbsent(link.polygonId, () => []).add(AreaHolding(job, link));
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
    final removals = <String, (Job, Set<String>)>{};
    if (move) {
      for (final link in add) {
        for (final h in currentOwners(holdings[link.polygonId])) {
          if (h.job.id == target.id) continue;
          removals.putIfAbsent(h.job.id, () => (h.job, <String>{})).$2.add(
                link.key,
              );
        }
      }
    }
    return [
      AreaLinkChange(jobId: target.id, date: target.date, add: add),
      for (final r in removals.values)
        AreaLinkChange(jobId: r.$1.id, date: r.$1.date, removeKeys: r.$2),
    ];
  }

  Future<void> apply(List<AreaLinkChange> changes, {required String action}) =>
      _schedule.applyAreaLinkChanges(changes, action: action);

  /// Takes [link] off [job].
  Future<void> unallocate(Job job, JobAreaLink link) => apply([
        AreaLinkChange(jobId: job.id, date: job.date, removeKeys: {link.key}),
      ], action: 'unallocateArea');
}
