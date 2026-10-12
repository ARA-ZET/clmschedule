// track_editor/services/te_report_scanner.dart
//
// Turns a picked Storage folder into the promoter days the Report panel
// lists: recursively finds every GPX file under it, pairs Track/Waypoints
// files, resolves each pair's distributor + date (te_gpx_matching.dart —
// the exact same logic Processing mode uses), and merges pairs that share
// a distributor and a date into one TEPromoterDay each.
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:gpx/gpx.dart';

import '../../models/distributor.dart';
import '../models/te_gpx_file_entry.dart';
import '../models/te_promoter_day.dart';
import 'te_gpx_matching.dart';

/// One matched pair the scan could not place — either its filename/track
/// carried no date, or its name didn't overlap any known distributor. Shown
/// to the user rather than silently dropped, so a missing promoter day has
/// an obvious reason.
class TEUnresolvedReportFile {
  final String matchKey;
  final List<String> paths;
  final bool missingDate;
  final bool missingDistributor;

  const TEUnresolvedReportFile({
    required this.matchKey,
    required this.paths,
    required this.missingDate,
    required this.missingDistributor,
  });
}

class TEReportScanResult {
  final List<TEPromoterDay> promoterDays;
  final List<TEUnresolvedReportFile> unresolved;

  const TEReportScanResult({
    required this.promoterDays,
    required this.unresolved,
  });

  static const empty = TEReportScanResult(promoterDays: [], unresolved: []);
}

/// Recursively scans [folderPath] for every promoter day it contains.
///
/// Deliberately does NOT touch schedule jobs, work-area polygons, or
/// drop-off points — Processing mode's per-pair Firestore lookup exists for
/// that, and a report only needs a distributor identity and a date, both
/// resolved for free from [distributors] (already loaded in memory) and the
/// GPX content itself. That keeps a folder of 50–100 files fast: everything
/// past the initial download is pure, synchronous matching.
Future<TEReportScanResult> scanFolderForPromoterDays(
  String folderPath, {
  required List<Distributor> distributors,
  void Function(int done, int total)? onProgress,
}) async {
  final storage = FirebaseStorage.instance;

  // ── 1. Recursively collect every .gpx file ref under folderPath ─────────
  final refs = <Reference>[];
  Future<void> walk(String path) async {
    final result = await storage.ref(path).listAll();
    for (final item in result.items) {
      if (item.name.toLowerCase().endsWith('.gpx')) refs.add(item);
    }
    for (final prefix in result.prefixes) {
      await walk(prefix.fullPath);
    }
  }

  try {
    await walk(folderPath);
  } catch (e) {
    debugPrint('scanFolderForPromoterDays: failed to list $folderPath: $e');
    return TEReportScanResult.empty;
  }
  if (refs.isEmpty) return TEReportScanResult.empty;

  // ── 2. Download bytes, bounded to 6 concurrent (same cap downloadFolder-
  //      AsZip uses) so a big folder doesn't open 100 sockets at once ──────
  final total = refs.length;
  var done = 0;
  final bytesByIndex = List<Uint8List?>.filled(total, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final idx = next++;
      if (idx >= total) return;
      try {
        bytesByIndex[idx] = await refs[idx].getData();
      } catch (e) {
        debugPrint('scanFolderForPromoterDays: download failed '
            '${refs[idx].fullPath}: $e');
      } finally {
        done++;
        onProgress?.call(done, total);
      }
    }
  }

  await Future.wait(List.generate(6, (_) => worker()));

  // ── 3. Parse every successfully-downloaded file ──────────────────────────
  final entries = <TEGpxFileEntry>[];
  final pathByName = <String, String>{};
  for (var i = 0; i < total; i++) {
    final bytes = bytesByIndex[i];
    if (bytes == null) continue;
    entries.add(TEGpxFileEntry.parse(refs[i].name, bytes));
    pathByName[refs[i].name] = refs[i].fullPath;
  }

  // Pairing, distributor/date resolution and grouping are all pure — kept in
  // their own function so they can run against synthetic entries in a test
  // with no Storage/Firebase involved at all.
  return groupIntoPromoterDays(entries, distributors, pathByName: pathByName);
}

/// Pairs, resolves and groups already-downloaded GPX entries into promoter
/// days. Split out from [scanFolderForPromoterDays] so this — the part with
/// actual logic in it — is unit-testable without Firebase. [pathByName]
/// is optional; when omitted (as in a test), promoter days simply carry no
/// [TEPromoterDay.sourcePaths].
TEReportScanResult groupIntoPromoterDays(
  List<TEGpxFileEntry> entries,
  List<Distributor> distributors, {
  Map<String, String> pathByName = const {},
}) {
  final (:pairs, :unmatched) = pairGpxFiles(entries);

  final grouped = <String, _Group>{};
  final unresolved = <TEUnresolvedReportFile>[];

  void resolve({
    required String matchKey,
    required List<Trk> tracks,
    required List<Wpt> waypoints,
    required List<String> filenames,
  }) {
    final resolved = resolveDate(tracks, matchKey, filenames.first);
    // A GPX timestamp resolves to a real instant (e.g. 10:00 local) — trim
    // it to the calendar day. The grouping key already only looks at
    // year/month/day; storing the full instant on the promoter day would
    // just be whichever pair happened to resolve the group first, which is
    // meaningless once two rounds have merged into it.
    final date =
        resolved == null ? null : DateTime(resolved.year, resolved.month, resolved.day);
    final distributor = matchDistributor(matchKey, distributors);
    final paths = [
      for (final name in filenames)
        if (pathByName[name] case final p?) p,
    ];

    if (date == null || distributor == null) {
      unresolved.add(TEUnresolvedReportFile(
        matchKey: matchKey,
        paths: paths,
        missingDate: date == null,
        missingDistributor: distributor == null,
      ));
      return;
    }

    final key = '${distributor.id}|${date.year}-${date.month}-${date.day}';
    final group = grouped.putIfAbsent(
      key,
      () => _Group(distributor: distributor, date: date),
    );
    group.tracks.addAll(tracks);
    group.waypoints.addAll(waypoints);
    group.paths.addAll(paths);
  }

  for (final pair in pairs) {
    resolve(
      matchKey: pair.matchKey,
      tracks: pair.trackFile.tracks,
      waypoints: pair.waypointsFile.waypoints,
      filenames: [pair.trackFile.filename, pair.waypointsFile.filename],
    );
  }

  // A lone track or lone waypoints file (no pairing partner) still carries
  // useful data on its own — Processing mode falls back to it too — so it
  // is worth resolving rather than only reporting it as unmatched.
  for (final f in unmatched) {
    if (f.type == TEGpxFileType.unknown) continue;
    resolve(
      matchKey: f.matchKey,
      tracks: f.tracks,
      waypoints: f.waypoints,
      filenames: [f.filename],
    );
  }

  final promoterDays = grouped.values
      .map((g) => TEPromoterDay(
            distributor: g.distributor,
            date: g.date,
            tracks: g.tracks,
            waypoints: g.waypoints,
            sourcePaths: g.paths,
          ))
      .toList()
    ..sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      return byDate != 0
          ? byDate
          : a.distributor.name.compareTo(b.distributor.name);
    });

  return TEReportScanResult(promoterDays: promoterDays, unresolved: unresolved);
}

/// Mutable accumulator while grouping — becomes an immutable [TEPromoterDay]
/// once every contributing pair has been folded in.
class _Group {
  final Distributor distributor;
  final DateTime date;
  final List<Trk> tracks = [];
  final List<Wpt> waypoints = [];
  final List<String> paths = [];
  _Group({required this.distributor, required this.date});
}
