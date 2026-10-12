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

import '../../models/custom_job_type.dart';
import '../../models/job_list_item.dart';
import '../../providers/job_list_provider.dart';

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
