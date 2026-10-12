/// How far a schedule job sits from the date its Job List item asked for.
///
/// Schedule jobs carry no Job List id — like [ScheduleReallocationService],
/// they are tied back to the Job List by client name. Per client, each Job
/// List item claims `ceil(manDays)` schedule days, nearest to its date first:
/// a day on or after the date, or up to [maxEarlyDays] before it (work done
/// early is on time, not the previous item's overflow). Measuring only
/// forward made a job done two days early count as the *next* item's days
/// and painted it as days late.
library;

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

String _clientKey(String client) => client.trim().toLowerCase();

DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// How far before its Job List date a schedule day can still belong to it.
const int maxEarlyDays = 7;

/// One schedule job's lag: [days] past [listDate] (negative when early) for
/// [client], the client in the job furthest behind.
typedef JobLag = ({int days, String client, DateTime listDate});

/// Lag for each schedule job, keyed by job id — the largest over the job's
/// clients. Jobs with no client near a Job List item are left out (nothing
/// to measure against).
///
/// Days a client holds beyond what its items' man-days account for (extra
/// days added by hand) are measured against the nearest item in range.
Map<String, JobLag> computeDistributionLag({
  required Iterable<Job> jobs,
  required Iterable<JobListItem> items,
}) {
  final itemsByClient = <String, List<JobListItem>>{};
  for (final item in items) {
    final key = _clientKey(item.client);
    if (key.isEmpty || item.manDays <= 0) continue;
    itemsByClient.putIfAbsent(key, () => []).add(item);
  }

  final jobsByClient = <String, List<Job>>{};
  for (final job in jobs) {
    if (job.id.isEmpty) continue;
    for (final key in job.clients.map(_clientKey).toSet()) {
      if (key.isEmpty || !itemsByClient.containsKey(key)) continue;
      jobsByClient.putIfAbsent(key, () => []).add(job);
    }
  }

  final lagByJob = <String, JobLag>{};
  void record(Job job, JobListItem item, int days) {
    final prev = lagByJob[job.id];
    if (prev == null || days > prev.days) {
      lagByJob[job.id] =
          (days: days, client: item.client.trim(), listDate: _day(item.date));
    }
  }

  for (final entry in jobsByClient.entries) {
    final clientItems = itemsByClient[entry.key]!;
    final clientJobs = entry.value;

    // Every (item, day) pairing in range, best first: nearest, then late
    // before early on a tie (overflow runs forward), then by date and id so
    // the result is stable.
    final pairs = <(int, int, int)>[]; // (item, job, signed days)
    for (var i = 0; i < clientItems.length; i++) {
      final itemDay = _day(clientItems[i].date);
      for (var j = 0; j < clientJobs.length; j++) {
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

    final slots = [for (final item in clientItems) item.manDays.ceil()];
    final claimed = List<bool>.filled(clientJobs.length, false);
    for (final (i, j, diff) in pairs) {
      if (claimed[j] || slots[i] == 0) continue;
      claimed[j] = true;
      slots[i]--;
      record(clientJobs[j], clientItems[i], diff);
    }

    // Extra days: the best pairing regardless of slots.
    for (final (i, j, diff) in pairs) {
      if (claimed[j]) continue;
      claimed[j] = true;
      record(clientJobs[j], clientItems[i], diff);
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
