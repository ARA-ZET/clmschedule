/// How far a schedule job sits from the date its Job List item asked for.
///
/// Schedule jobs carry no Job List id. One that holds areas from (or links)
/// a Job List item's client map belongs to that item; otherwise it is tied
/// back to the Job List by client name. Per client, each Job
/// List item claims `ceil(manDays)` schedule days, nearest to its date first:
/// a day on or after the date, or up to [maxEarlyDays] before it (work done
/// early is on time, not the previous item's overflow). Measuring only
/// forward made a job done two days early count as the *next* item's days
/// and painted it as days late.
library;

import 'dart:math' as math;

import '../models/job.dart';
import '../models/job_list_item.dart';

enum DistributionLag {
  /// Scheduled on the Job List date.
  onTime,

  /// 1–2 days after the Job List date.
  late,

  /// 3+ days after — an old job that still needs doing.
  overdue,
}

DistributionLag lagForDays(int days) {
  if (days <= 0) return DistributionLag.onTime;
  if (days < 3) return DistributionLag.late;
  return DistributionLag.overdue;
}

/// How a client name is compared between the schedule and the Job List.
/// Also what makes two Job List jobs "the same name" — see
/// `JobListProvider.findJobsWithClientName`.
String jobListClientKey(String client) =>
    client.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// How far before its Job List date a schedule day can still belong to it.
const int maxEarlyDays = 7;

/// One schedule job's lag: [days] past [listDate] (negative when early) for
/// [client], the client in the job furthest behind.
typedef JobLag = ({int days, String client, DateTime listDate});

/// Client maps a schedule job is explicitly tied to — by an allocated area
/// or a linked map.
Set<String> _linkedMapIds(Job job) => {
      for (final l in job.areaLinks)
        if (l.mapId.isNotEmpty) l.mapId,
      for (final m in job.effectiveLinkedMaps)
        if (m.mapId.isNotEmpty) m.mapId,
    };

/// The Job List item each schedule job's client belongs to, as
/// `jobId → client key → item` (keys from [jobListClientKey]).
///
/// An explicit link wins: a job holding areas from, or linked to, an item's
/// client map ([JobListItem.shareableMapId]) belongs to that item whatever
/// its date. The rest pair by name as the header describes — each item
/// claims `ceil(manDays)` days (at least one), nearest first, from
/// [maxEarlyDays] before its date onwards; days beyond that go to the
/// nearest item in range.
///
/// A client missing from the result has no item near enough to match.
Map<String, Map<String, JobListItem>> pairJobsWithJobListItems({
  required Iterable<Job> jobs,
  required Iterable<JobListItem> items,
}) {
  final itemsByClient = <String, List<JobListItem>>{};
  for (final item in items) {
    final key = jobListClientKey(item.client);
    if (key.isEmpty) continue;
    final list = itemsByClient.putIfAbsent(key, () => []);
    if (!list.any((i) => i.id == item.id)) list.add(item);
  }

  final jobsByClient = <String, List<Job>>{};
  final seenJobs = <String>{};
  for (final job in jobs) {
    if (job.id.isEmpty || !seenJobs.add(job.id)) continue;
    for (final key in job.clients.map(jobListClientKey).toSet()) {
      if (key.isEmpty || !itemsByClient.containsKey(key)) continue;
      jobsByClient.putIfAbsent(key, () => []).add(job);
    }
  }

  final pairing = <String, Map<String, JobListItem>>{};
  void pair(Job job, String key, JobListItem item) =>
      pairing.putIfAbsent(job.id, () => {})[key] = item;

  for (final entry in jobsByClient.entries) {
    final clientItems = itemsByClient[entry.key]!;
    final clientJobs = entry.value;
    final slots = [
      for (final item in clientItems) math.max(1, item.manDays.ceil()),
    ];
    final claimed = List<bool>.filled(clientJobs.length, false);

    // Explicit links first, nearest item when a job links several.
    for (var j = 0; j < clientJobs.length; j++) {
      final linked = _linkedMapIds(clientJobs[j]);
      if (linked.isEmpty) continue;
      int? best;
      for (var i = 0; i < clientItems.length; i++) {
        final mapId = clientItems[i].shareableMapId;
        if (mapId.isEmpty || !linked.contains(mapId)) continue;
        if (best == null ||
            _distance(clientJobs[j], clientItems[i]) <
                _distance(clientJobs[j], clientItems[best])) {
          best = i;
        }
      }
      if (best == null) continue;
      claimed[j] = true;
      if (slots[best] > 0) slots[best]--;
      pair(clientJobs[j], entry.key, clientItems[best]);
    }

    // Every (item, day) pairing in range, best first: nearest, then late
    // before early on a tie (overflow runs forward), then by date and id so
    // the result is stable.
    final pairs = <(int, int, int)>[]; // (item, job, signed days)
    for (var i = 0; i < clientItems.length; i++) {
      final itemDay = _day(clientItems[i].date);
      for (var j = 0; j < clientJobs.length; j++) {
        if (claimed[j]) continue;
        final diff = _day(clientJobs[j].date).difference(itemDay).inDays;
        if (diff >= -maxEarlyDays) pairs.add((i, j, diff));
      }
    }
    pairs.sort((a, b) {
      final byDistance = a.$3.abs().compareTo(b.$3.abs());
      if (byDistance != 0) return byDistance;
      if ((a.$3 < 0) != (b.$3 < 0)) return a.$3 < 0 ? 1 : -1;
      final ia = clientItems[a.$1], ib = clientItems[b.$1];
      final byItem = _day(ia.date).compareTo(_day(ib.date));
      if (byItem != 0) return byItem;
      final byItemId = ia.id.compareTo(ib.id);
      if (byItemId != 0) return byItemId;
      final ja = clientJobs[a.$2], jb = clientJobs[b.$2];
      final byJob = _day(ja.date).compareTo(_day(jb.date));
      return byJob != 0 ? byJob : ja.id.compareTo(jb.id);
    });

    for (final (i, j, _) in pairs) {
      if (claimed[j] || slots[i] == 0) continue;
      claimed[j] = true;
      slots[i]--;
      pair(clientJobs[j], entry.key, clientItems[i]);
    }

    // Extra days: the best pairing regardless of slots.
    for (final (i, j, _) in pairs) {
      if (claimed[j]) continue;
      claimed[j] = true;
      pair(clientJobs[j], entry.key, clientItems[i]);
    }
  }

  return pairing;
}

int _distance(Job job, JobListItem item) =>
    _day(job.date).difference(_day(item.date)).inDays.abs();

/// Lag for each schedule job, keyed by job id — the largest over the job's
/// clients. Jobs with no client near a Job List item are left out (nothing
/// to measure against). Items with no man-days are not measured against.
///
/// Days a client holds beyond what its items' man-days account for (extra
/// days added by hand) are measured against the nearest item in range.
Map<String, JobLag> computeDistributionLag({
  required Iterable<Job> jobs,
  required Iterable<JobListItem> items,
}) {
  final byId = {for (final job in jobs) job.id: job};
  final pairing = pairJobsWithJobListItems(
    jobs: byId.values,
    items: items.where((i) => i.manDays > 0),
  );

  final lagByJob = <String, JobLag>{};
  for (final entry in pairing.entries) {
    final job = byId[entry.key]!;
    for (final item in entry.value.values) {
      final days = _day(job.date).difference(_day(item.date)).inDays;
      final prev = lagByJob[job.id];
      if (prev == null || days > prev.days) {
        lagByJob[job.id] =
            (days: days, client: item.client.trim(), listDate: _day(item.date));
      }
    }
  }
  return lagByJob;
}

/// Days each schedule job lies past its Job List date (see
/// [computeDistributionLag]).
Map<String, int> computeDistributionLagDays({
  required Iterable<Job> jobs,
  required Iterable<JobListItem> items,
}) =>
    computeDistributionLag(jobs: jobs, items: items)
        .map((id, lag) => MapEntry(id, lag.days));
