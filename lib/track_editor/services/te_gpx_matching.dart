// track_editor/services/te_gpx_matching.dart
//
// Pure, I/O-free matching of a GPX file to a schedule date and a distributor.
// Extracted from te_processing_provider.dart so the same logic can be reused
// wherever a GPX needs to be identified — "Processing" mode (one file at a
// time, opened as a tab) and the client Report (a whole folder at once,
// grouped into promoter days) both call these same functions, so a filename
// or a track that matches in one place matches the same way in the other.
import 'dart:math' as math;
import 'package:gpx/gpx.dart';

import '../../models/distributor.dart';
import '../models/te_gpx_file_entry.dart';

/// Extract the local date from the first timestamped point in [tracks].
DateTime? extractTrackDate(List<Trk> tracks) {
  for (final trk in tracks) {
    for (final seg in trk.trksegs) {
      for (final pt in seg.trkpts) {
        if (pt.time != null) return pt.time!.toLocal();
      }
    }
  }
  return null;
}

/// Extract a date from route filenames such as
/// `Track 11 May 2026 Distributor ...` when the GPX track points do not
/// carry timestamps. This lets single, unmatched track files resolve the
/// same schedule data as normal matched Track/Waypoints pairs.
DateTime? extractDateFromText(String text) {
  final iso =
      RegExp(r'\b(\d{4})[-_ ](\d{1,2})[-_ ](\d{1,2})\b').firstMatch(text);
  if (iso != null) {
    return _checkedDate(
      int.parse(iso.group(1)!),
      int.parse(iso.group(2)!),
      int.parse(iso.group(3)!),
    );
  }

  final dmy = RegExp(
    r'\b(\d{1,2})[\s_\-]+(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)[\s_\-]+(\d{4})\b',
    caseSensitive: false,
  ).firstMatch(text);
  if (dmy == null) return null;
  final month = _monthNumber(dmy.group(2)!);
  if (month == null) return null;
  return _checkedDate(
    int.parse(dmy.group(3)!),
    month,
    int.parse(dmy.group(1)!),
  );
}

DateTime? _checkedDate(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    return null;
  }
  return date;
}

int? _monthNumber(String raw) {
  final key = raw.toLowerCase();
  if (key.startsWith('jan')) return 1;
  if (key.startsWith('feb')) return 2;
  if (key.startsWith('mar')) return 3;
  if (key.startsWith('apr')) return 4;
  if (key == 'may') return 5;
  if (key.startsWith('jun')) return 6;
  if (key.startsWith('jul')) return 7;
  if (key.startsWith('aug')) return 8;
  if (key.startsWith('sep')) return 9;
  if (key.startsWith('oct')) return 10;
  if (key.startsWith('nov')) return 11;
  if (key.startsWith('dec')) return 12;
  return null;
}

/// Find the distributor whose name best matches [matchKey] (case-insensitive
/// token overlap). Returns null if no distributor scores at least one token.
Distributor? matchDistributor(String matchKey, List<Distributor> distributors) {
  if (distributors.isEmpty) return null;
  final keyTokens = matchKey
      .toLowerCase()
      .split(RegExp(r'[\s_\-]+'))
      .where((t) => t.isNotEmpty)
      .toSet();

  Distributor? best;
  int bestScore = 0;

  for (final d in distributors) {
    final nameTokens = d.name
        .toLowerCase()
        .split(RegExp(r'[\s_\-]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    final score = keyTokens.intersection(nameTokens).length;
    if (score > bestScore) {
      bestScore = score;
      best = d;
    }
  }
  return best;
}

/// [distributors] ordered by how closely their name resembles the name in
/// [matchKey], closest first — for picking a distributor by hand when
/// [matchDistributor] found none because the file name is misspelt
/// ("Tichona" for Tichaona, "Dixon" for Dickson).
///
/// Each distributor scores the best edit-distance similarity between any of
/// its name words and any word of the key, ignoring numbers, month names and
/// words under three letters (dates and counts in the file name). Ties keep
/// alphabetical order.
List<({Distributor distributor, double score})> rankDistributorsByName(
    String matchKey, List<Distributor> distributors) {
  List<String> words(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.length >= 3 && !_monthWords.contains(w))
      .toList();

  final keyWords = words(matchKey);
  final ranked = [
    for (final d in distributors)
      (
        distributor: d,
        score: keyWords.isEmpty
            ? 0.0
            : words(d.name).fold<double>(
                0,
                (best, n) => keyWords.fold(
                    best, (b, k) => math.max(b, _similarity(n, k)))),
      ),
  ];
  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0
        ? byScore
        : a.distributor.name
            .toLowerCase()
            .compareTo(b.distributor.name.toLowerCase());
  });
  return ranked;
}

/// Month words as they appear in file-name dates. Exact words, not prefixes,
/// so names such as Marlon or Julius are not mistaken for months.
const _monthWords = {
  'jan', 'january', 'feb', 'february', 'mar', 'march', 'apr', 'april', //
  'may', 'jun', 'june', 'jul', 'july', 'aug', 'august', 'sep', 'sept', //
  'september', 'oct', 'october', 'nov', 'november', 'dec', 'december',
};

/// 1 for identical words, falling towards 0 as more edits are needed.
double _similarity(String a, String b) {
  if (a == b) return 1;
  final longest = math.max(a.length, b.length);
  return longest == 0 ? 1 : 1 - _editDistance(a, b) / longest;
}

int _editDistance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = math.min(
          math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Pair every track file with the waypoints file sharing its matchKey — the
/// same rule `TEProcessingProvider.matchedPairs` applies to a picked file
/// list, extracted here so a bulk folder scan can use it too. Returns the
/// pairs plus whatever didn't pair (a lone track, a lone waypoints file, or
/// a file whose name didn't start with "Track "/"Waypoints " at all).
({List<TEGpxMatchedPair> pairs, List<TEGpxFileEntry> unmatched})
    pairGpxFiles(List<TEGpxFileEntry> files) {
  final tracks = <String, TEGpxFileEntry>{};
  final wpts = <String, TEGpxFileEntry>{};
  for (final f in files) {
    if (f.type == TEGpxFileType.track) {
      tracks[f.matchKey] = f;
    } else if (f.type == TEGpxFileType.waypoints) {
      wpts[f.matchKey] = f;
    }
  }

  final pairs = <TEGpxMatchedPair>[];
  for (final key in tracks.keys) {
    if (wpts.containsKey(key)) {
      pairs.add(TEGpxMatchedPair(
        trackFile: tracks[key]!,
        waypointsFile: wpts[key]!,
        matchKey: key,
      ));
    }
  }

  final matchedKeys = pairs.map((p) => p.matchKey).toSet();
  final unmatched = files.where((f) {
    if (f.type == TEGpxFileType.unknown) return true;
    return !matchedKeys.contains(f.matchKey);
  }).toList();

  return (pairs: pairs, unmatched: unmatched);
}

/// Resolve both the date and the distributor for one matched GPX pair's
/// track content + filename key, in the same priority order Processing mode
/// uses: real timestamps first, then the filename as a fallback.
DateTime? resolveDate(List<Trk> tracks, String matchKey, String filename) {
  return extractTrackDate(tracks) ??
      extractDateFromText(matchKey) ??
      extractDateFromText(filename);
}
