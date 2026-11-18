// track_editor/services/te_report_map_links.dart
//
// The client map each promoter's route map links to in the report. A
// promoter day knows the Cloud Storage files it was read from; the Job List
// item whose folder holds those files is the job, and the job's linked map
// (found the way the Job List's distribution report finds it) is the map the
// client was sent. Rounds file into their own folders, so the deepest
// matching folder wins.
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../models/job_list_item.dart';
import '../../services/distribution_report_service.dart';
import '../../services/job_list_service.dart';
import '../models/te_promoter_day.dart';

final _labelDayFmt = DateFormat('d MMM yyyy');

/// One client map the report links to, and the promoter days it covers.
class TEMapLinkGroup {
  /// The Job List item's id, or '' for days no job was found for.
  final String key;

  /// What the check dialog calls it — the client, or "Client map".
  final String label;
  final List<TEPromoterDay> days;

  /// The share link, or '' when none was found.
  final String url;

  const TEMapLinkGroup({
    required this.key,
    required this.label,
    required this.days,
    required this.url,
  });
}

/// The folders a file at [path] sits in, deepest first, down to the client
/// folder (`Distribution/{yyyy}/{MMM yyyy}/{client}`) — month and year
/// folders never belong to a single job.
@visibleForTesting
List<String> teJobFolderCandidates(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return [
    for (var n = parts.length - 1; n >= 4; n--) parts.take(n).join('/'),
  ];
}

/// The item among [items] whose folder holds [day]'s files — the deepest
/// one, so a Round 2 folder beats its parent client folder.
@visibleForTesting
JobListItem? teJobForDay(TEPromoterDay day, Iterable<JobListItem> items) {
  JobListItem? best;
  var bestDepth = -1;
  for (final item in items) {
    final folder = _trimSlash(item.storageFolderPath);
    if (folder.isEmpty) continue;
    final holds = day.sourcePaths.any((p) => p.startsWith('$folder/'));
    final depth = '/'.allMatches(folder).length;
    if (holds && depth > bestDepth) {
      best = item;
      bestDepth = depth;
    }
  }
  return best;
}

/// Groups [days] by the client map they belong to. Best effort: anything
/// that can't be looked up lands in a group with no link, which the user can
/// fill in by hand.
Future<List<TEMapLinkGroup>> resolveReportMapLinks(
  List<TEPromoterDay> days, {
  required JobListService jobs,
  DistributionReportService? reports,
}) async {
  var items = const <JobListItem>[];
  try {
    items = await jobs.getJobListItemsForFolders(
      {
        for (final d in days)
          for (final p in d.sourcePaths) ...teJobFolderCandidates(p),
      },
      {
        for (final d in days) ...[
          DateTime(d.date.year, d.date.month - 1),
          DateTime(d.date.year, d.date.month),
          DateTime(d.date.year, d.date.month + 1),
        ],
      },
    );
  } catch (e) {
    debugPrint('Report map links: Job List lookup failed: $e');
  }

  final byItem = <String, (JobListItem?, List<TEPromoterDay>)>{};
  for (final d in days) {
    final item = teJobForDay(d, items);
    byItem.putIfAbsent(item?.id ?? '', () => (item, []));
    byItem[item?.id ?? '']!.$2.add(d);
  }

  final service = reports ?? DistributionReportService();
  final clients = <String, int>{};
  for (final (item, _) in byItem.values) {
    if (item != null) clients[item.client] = (clients[item.client] ?? 0) + 1;
  }
  return Future.wait([
    for (final MapEntry(key: key, value: (item, groupDays)) in byItem.entries)
      () async {
        var url = '';
        if (item != null) {
          try {
            url = await service.shareUrlFor(item) ?? '';
          } catch (e) {
            debugPrint('Report map links: map lookup failed: $e');
          }
        }
        return TEMapLinkGroup(
          key: key,
          // Two rounds of one client tell apart by date.
          label: item == null
              ? 'Client map'
              : (clients[item.client]! > 1
                  ? '${item.client} · ${_labelDayFmt.format(item.date)}'
                  : item.client),
          days: groupDays,
          url: url,
        );
      }(),
  ]);
}

String _trimSlash(String path) {
  var p = path.trim();
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}
