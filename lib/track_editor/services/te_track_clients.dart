// track_editor/services/te_track_clients.dart
//
// A distributor's schedule day can mix distribution rounds with work that
// never produces GPS waypoints — junk collection, window cleaning, moves.
// Those clients have no track to file, so processing should not offer them.
//
// The schedule job carries only client names, so each client is matched to
// the Job List items already held in memory by `JobListProvider`, whose job
// type says what the work was. A job type that files tracks under
// `Distribution/{year}/{month}/{client}` has
// [CustomJobType.createsCloudFolder] set; anything else records no waypoints.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/custom_job_type.dart';
import '../../models/job.dart';
import '../../models/job_list_item.dart';
import '../../providers/job_list_provider.dart';
import '../../services/job_list_service.dart';
import '../../utils/distribution_lag.dart';

/// The subset of [clients] whose Job List entries are all for work that
/// records no waypoints. Matching is by client name, ignoring case and
/// surrounding spaces.
///
/// A client is hidden only when it has at least one entry and none of them is
/// a track-recording type — a client missing from [jobListItems] (a different
/// month, or not listed at all), or of a type not in [jobTypes], stays visible
/// rather than silently disappearing from processing.
Set<String> findClientsWithoutTracks({
  required Iterable<String> clients,
  required List<JobListItem> jobListItems,
  required List<CustomJobType> jobTypes,
}) {
  if (jobTypes.isEmpty) return const {};
  final wanted = <String, String>{}; // normalised -> as scheduled
  for (final c in clients) {
    final key = c.trim().toLowerCase();
    if (key.isNotEmpty) wanted.putIfAbsent(key, () => c);
  }
  if (wanted.isEmpty) return const {};

  final entries = <({String client, String jobTypeId})>[];
  for (final item in jobListItems) {
    final name = wanted[item.client.trim().toLowerCase()];
    if (name != null) entries.add((client: name, jobTypeId: item.jobTypeId));
  }
  return clientsWithoutTracks(entries, jobTypes);
}

/// The rule behind [findClientsWithoutTracks], given the Job List [entries]
/// already matched: clients all of whose entries are of a job type that does
/// not file tracks. An unknown job type counts as recording tracks.
Set<String> clientsWithoutTracks(
  Iterable<({String client, String jobTypeId})> entries,
  List<CustomJobType> jobTypes,
) {
  final recordsTracks = {
    for (final t in jobTypes) t.id: t.createsCloudFolder,
  };
  final hasTrackWork = <String, bool>{};
  for (final e in entries) {
    final tracks = recordsTracks[e.jobTypeId] ?? true;
    hasTrackWork[e.client] = (hasTrackWork[e.client] ?? false) || tracks;
  }
  return {
    for (final e in hasTrackWork.entries)
      if (!e.value) e.key,
  };
}

/// The Job List items [provider] holds, starting it if nothing has yet (the
/// standalone Track Editor app never opens the Job List screen that normally
/// does). Waits at most [timeout] for the first snapshot; after that the
/// caller proceeds with whatever is there — worst case nothing is hidden.
Future<List<JobListItem>> loadedJobListItems(
  JobListProvider provider, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (!provider.isInitialized) unawaited(provider.initialize());
  final deadline = DateTime.now().add(timeout);
  while (provider.allJobListItems.isEmpty &&
      provider.error == null &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return provider.allJobListItems;
}

/// The Job List item behind each client on a distributor's [dayJobs], keyed
/// by [jobListClientKey] — through the same pairing as the schedule's lag
/// borders, so a client map allocated to the day ties it to that item.
///
/// [otherJobs] are the rest of the schedule held in memory: they let the
/// other days of the same client claim their own items, so a second round
/// in the same month is not mistaken for this one.
Map<String, JobListItem> jobListItemsForDayJobs({
  required List<Job> dayJobs,
  required Iterable<Job> otherJobs,
  required Iterable<JobListItem> items,
}) {
  final pairing = pairJobsWithJobListItems(
    jobs: [...dayJobs, ...otherJobs],
    items: items,
  );
  final result = <String, JobListItem>{};
  for (final job in dayJobs) {
    pairing[job.id]
        ?.forEach((key, item) => result.putIfAbsent(key, () => item));
  }
  return result;
}

/// The folder [item]'s tracks are filed in, or null when it has none yet.
///
/// The Job List item owns this path: the server creates it, moves it when
/// the client or month changes, and Cloud Files renames re-point it — so it
/// stays right where a path rebuilt from the client name would not (a
/// `Round N` folder, a renamed folder, a job listed in the previous month).
String? jobListTrackFolder(JobListItem? item) {
  final path = item?.storageFolderPath.trim() ?? '';
  return path.isEmpty ? null : path;
}

/// Job List items for [clients] around [date]: what [provider] holds, plus
/// those listed in the months either side, which it does not load. A day's
/// work can belong to an item listed last month (late) or next month (early).
/// Best effort — a failed fetch leaves just the items in memory.
Future<List<JobListItem>> jobListItemsNear({
  required JobListProvider provider,
  required JobListService service,
  required Iterable<String> clients,
  required DateTime date,
}) async {
  final inMemory = await loadedJobListItems(provider);
  var fetched = const <JobListItem>[];
  try {
    fetched = await service.getJobListItemsForClients(clients, [
      DateTime(date.year, date.month - 1),
      date,
      DateTime(date.year, date.month + 1),
    ]).timeout(const Duration(seconds: 10));
  } catch (e) {
    debugPrint('[TETrackClients] Job List lookup failed: $e');
  }
  // In memory wins: it carries edits not yet written.
  final byId = {for (final i in fetched) i.id: i};
  for (final i in inMemory) {
    byId[i.id] = i;
  }
  return byId.values.toList();
}
