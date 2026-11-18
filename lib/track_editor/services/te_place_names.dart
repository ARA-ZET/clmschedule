// track_editor/services/te_place_names.dart
//
// Names the places a distributor worked, for the client report: the two
// roads crossing at the intersection ("Voortrekker Rd & Durban Rd").
//
// Intersections come from OpenStreetMap through the Overpass API — Google
// reverse geocoding answers with the nearest street address and has no
// reliable "intersection" result. Points go into one query per batch rather
// than one request each: the public Overpass servers are shared and
// rate-limited, and regularly answer 504 under load, so the query falls
// through a list of mirrors.
//
// Every lookup is best-effort. A name that can't be found is left null and
// the report prints what it has; a report is never blocked on a map server.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class TEPlaceName {
  /// "Voortrekker Rd & Durban Rd", or a single road name when the spot isn't
  /// near a junction.
  final String? intersection;

  const TEPlaceName({this.intersection});
}

/// How far a [resolvePlaceNames] run has got, for a progress display.
class TEPlaceProgress {
  /// Points finished so far (named or not) out of [total] needing a lookup.
  final int done;
  final int total;

  /// [tePlaceKey]s of the points being looked up right now; empty once the
  /// run is over.
  final List<String> current;

  /// 1, or 2 when no server answered the first ask and it is asking again.
  final int round;

  const TEPlaceProgress({
    required this.done,
    required this.total,
    this.current = const [],
    this.round = 1,
  });

  bool get finished => current.isEmpty && done >= total;
}

/// Map key for a coordinate: 4 decimals is about 11 m, well inside one
/// intersection, so the report and the resolver agree on the same spot.
String tePlaceKey(double lat, double lon) =>
    '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';

const List<String> _overpassEndpoints = [
  'https://overpass-api.de/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

/// Roads are searched this far around a spot, and a junction has to be this
/// close to count as the intersection being worked.
const double _searchRadiusM = 120;

/// Without a junction in range, the nearest single road is used only if it is
/// this close.
const double _roadOnlyRadiusM = 60;

/// Points per Overpass query.
const int _batchSize = 20;

final Map<String, String?> _intersectionMemo = {};

/// When a point's intersection lookup last failed on every mirror.
final Map<String, DateTime> _intersectionFailedAt = {};
const Duration _intersectionRetryAfter = Duration(minutes: 5);

/// The intersection already known for a point, without any network call:
/// `(true, name)` when resolved (name may be null = no roads nearby),
/// `(false, null)` when not looked up yet.
(bool, String?) cachedIntersection(double lat, double lon) {
  final key = tePlaceKey(lat, lon);
  return _intersectionMemo.containsKey(key)
      ? (true, _intersectionMemo[key])
      : (false, null);
}

/// Intersection names for [points] (lat, lon), keyed by [tePlaceKey].
/// Already-resolved points come from memory, so regenerating a report costs
/// nothing. [batchSize] points go into each query — 1 gives a progress
/// update per point. [onProgress] hears before and after each batch;
/// [isCancelled] is checked between batches to stop early.
Future<Map<String, TEPlaceName>> resolvePlaceNames(
  Iterable<(double, double)> points, {
  int batchSize = _batchSize,
  void Function(TEPlaceProgress progress)? onProgress,
  bool Function()? isCancelled,
}) async {
  final unique = <String, (double, double)>{};
  for (final p in points) {
    unique[tePlaceKey(p.$1, p.$2)] = p;
  }

  final pending = unique.entries
      .where((e) => !_intersectionMemo.containsKey(e.key))
      .toList();
  var done = 0;
  for (var i = 0; i < pending.length; i += batchSize) {
    if (isCancelled?.call() ?? false) break;
    final batch = pending.sublist(i, math.min(i + batchSize, pending.length));
    final keys = [for (final e in batch) e.key];
    onProgress?.call(TEPlaceProgress(
        done: done, total: pending.length, current: keys));
    final json = await _overpass(
      _queryFor([for (final e in batch) e.value]),
      onRound: (round) => onProgress?.call(TEPlaceProgress(
          done: done, total: pending.length, current: keys, round: round)),
    );
    // A batch no server answered is left unmemoed: the next run retries it.
    if (json != null) {
      for (final e in batch) {
        _intersectionMemo[e.key] =
            intersectionNear(json, e.value.$1, e.value.$2);
      }
    }
    done += batch.length;
  }
  onProgress?.call(TEPlaceProgress(done: done, total: pending.length));

  return cachedPlaceNames(unique.values);
}

/// The road intersection for each of [points] (lat, lon), for the dropsheet
/// and schedule. Keyed by [tePlaceKey]; a value of null means
/// "looked up, no named road nearby". Points whose batch failed on every
/// Overpass mirror are left out so the caller can retry later.
Future<Map<String, String?>> resolveIntersections(
    Iterable<(double, double)> points) async {
  final unique = <String, (double, double)>{};
  for (final p in points) {
    unique[tePlaceKey(p.$1, p.$2)] = p;
  }
  // The dropsheet and schedule call this on every sync; while the Overpass
  // mirrors are down, a failed point waits out a cool-down instead of being
  // re-queried every few seconds.
  final now = DateTime.now();
  final pending = unique.entries
      .where((e) => !_intersectionMemo.containsKey(e.key))
      .where((e) {
    final failedAt = _intersectionFailedAt[e.key];
    return failedAt == null ||
        now.difference(failedAt) >= _intersectionRetryAfter;
  }).toList();
  for (var i = 0; i < pending.length; i += _batchSize) {
    final batch = pending.sublist(i, math.min(i + _batchSize, pending.length));
    final json = await _overpass(_queryFor([for (final e in batch) e.value]));
    if (json == null) {
      for (final e in batch) {
        _intersectionFailedAt[e.key] = DateTime.now();
      }
      continue;
    }
    for (final e in batch) {
      _intersectionMemo[e.key] = intersectionNear(json, e.value.$1, e.value.$2);
    }
  }
  return {
    for (final key in unique.keys)
      if (_intersectionMemo.containsKey(key)) key: _intersectionMemo[key],
  };
}

/// Forgets the lookups for [points] that came back with no name, so the
/// next [resolvePlaceNames] asks the map servers again instead of answering
/// from memory. Names that did come back are kept.
void forgetUnnamedPlaces(Iterable<(double, double)> points) {
  for (final p in points) {
    final key = tePlaceKey(p.$1, p.$2);
    if (_intersectionMemo.containsKey(key) && _intersectionMemo[key] == null) {
      _intersectionMemo.remove(key);
    }
    _intersectionFailedAt.remove(key);
  }
}

/// Whatever names are already known for [points] — used when a lookup ran
/// out of time, so the report still gets the ones that did come back.
Map<String, TEPlaceName> cachedPlaceNames(Iterable<(double, double)> points) {
  final out = <String, TEPlaceName>{};
  for (final p in points) {
    final key = tePlaceKey(p.$1, p.$2);
    final i = _intersectionMemo[key];
    if (i != null) out[key] = TEPlaceName(intersection: i);
  }
  return out;
}

String _queryFor(List<(double, double)> points) {
  final clauses = [
    for (final p in points)
      'way(around:${_searchRadiusM.toInt()},${p.$1},${p.$2})[highway][name];',
  ].join();
  return '[out:json][timeout:25];($clauses);out body;>;out skel qt;';
}

Future<Map<String, dynamic>?> _overpass(String query,
    {void Function(int round)? onRound}) async {
  // All mirrors are asked at once and the first good answer wins. Asked one
  // after another, a couple of overloaded mirrors (each slow to time out)
  // used up the report's whole time limit before a healthy one was tried.
  // Two rounds: a 504 or 429 is usually momentary.
  for (var round = 0; round < 2; round++) {
    if (round > 0) onRound?.call(round + 1);
    final answer = await _firstAnswer([
      for (final endpoint in _overpassEndpoints) _askMirror(endpoint, query),
    ]);
    if (answer != null) return answer;
  }
  return null;
}

/// The first non-null result of [attempts], or null once they all fail.
Future<T?> _firstAnswer<T>(List<Future<T?>> attempts) {
  final done = Completer<T?>();
  var left = attempts.length;
  for (final a in attempts) {
    a.then((v) {
      left--;
      if (done.isCompleted) return;
      if (v != null) {
        done.complete(v);
      } else if (left == 0) {
        done.complete(null);
      }
    });
  }
  return done.future;
}

Future<Map<String, dynamic>?> _askMirror(String endpoint, String query) async {
  try {
    final res = await http
        .post(
          Uri.parse(endpoint),
          body: {'data': query},
          // overpass-api.de refuses anonymous clients with a 406. A browser
          // always sends its own User-Agent (and won't let a page override
          // it), so this only matters off the web.
          headers: kIsWeb
              ? null
              : const {'User-Agent': 'CLM-Schedule-TrackEditor/1.0'},
        )
        // A healthy but busy mirror can take 15–30 s on a batch.
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) {
      debugPrint('Overpass $endpoint: HTTP ${res.statusCode}');
      return null;
    }
    final decoded = json.decode(res.body);
    if (decoded is Map<String, dynamic> && decoded['elements'] is List) {
      // A server that runs out of time still answers 200, with whatever it
      // had so far and a "runtime error" remark. Taken as good, every point
      // in the batch would be remembered as having no roads nearby.
      final remark = decoded['remark'];
      if (remark is String && remark.contains('error')) {
        debugPrint('Overpass $endpoint: $remark');
        return null;
      }
      return decoded;
    }
    debugPrint('Overpass $endpoint: unexpected answer');
  } catch (e) {
    debugPrint('Overpass $endpoint failed: $e');
  }
  return null;
}

// ── Reading an Overpass answer ──────────────────────────────────────────────

/// Ways that aren't roads a car stops at — a footpath crossing Main Rd is
/// not an intersection a client would recognise.
const Set<String> _notRoads = {
  'footway',
  'path',
  'cycleway',
  'steps',
  'track',
  'bridleway',
  'pedestrian',
  'service',
  'corridor',
  'platform',
  'construction',
  'proposed',
  'elevator',
};

/// Bigger roads first, so the name a client knows leads.
const Map<String, int> _roadRank = {
  'motorway': 0,
  'trunk': 1,
  'primary': 2,
  'secondary': 3,
  'tertiary': 4,
  'motorway_link': 5,
  'trunk_link': 5,
  'primary_link': 5,
  'secondary_link': 6,
  'tertiary_link': 6,
  'unclassified': 7,
  'residential': 8,
  'living_street': 9,
};

/// The nearest junction of two differently named roads to [lat],[lon] in an
/// Overpass `out body; >; out skel` answer, as "Bigger Rd & Smaller St" —
/// or the nearest single road when no junction is in range. Null with
/// neither.
@visibleForTesting
String? intersectionNear(
    Map<String, dynamic> overpass, double lat, double lon) {
  final nodes = <int, (double, double)>{};
  final ways = <Map<String, dynamic>>[];
  for (final e in (overpass['elements'] as List? ?? const [])) {
    if (e is! Map<String, dynamic>) continue;
    if (e['type'] == 'node' && e['lat'] != null && e['lon'] != null) {
      nodes[e['id'] as int] =
          ((e['lat'] as num).toDouble(), (e['lon'] as num).toDouble());
    } else if (e['type'] == 'way') {
      final tags = e['tags'] as Map<String, dynamic>? ?? const {};
      final name = tags['name'] as String?;
      final highway = tags['highway'] as String?;
      if (name == null || highway == null || _notRoads.contains(highway)) {
        continue;
      }
      ways.add(e);
    }
  }

  // Which named roads meet at each node, with each name's best rank.
  final namesAt = <int, Map<String, int>>{};
  for (final w in ways) {
    final tags = w['tags'] as Map<String, dynamic>;
    final name = tags['name'] as String;
    final rank = _roadRank[tags['highway']] ?? 10;
    for (final id in (w['nodes'] as List? ?? const [])) {
      final names = namesAt.putIfAbsent(id as int, () => {});
      names[name] = math.min(names[name] ?? rank, rank);
    }
  }

  (double, List<String>)? best;
  namesAt.forEach((id, names) {
    if (names.length < 2) return;
    final pos = nodes[id];
    if (pos == null) return;
    final d = _metres(lat, lon, pos.$1, pos.$2);
    if (d > _searchRadiusM) return;
    if (best != null && d >= best!.$1) return;
    final ordered = names.keys.toList()
      ..sort((a, b) {
        final byRank = names[a]!.compareTo(names[b]!);
        return byRank != 0 ? byRank : a.compareTo(b);
      });
    best = (d, ordered);
  });
  if (best != null) {
    return '${_short(best!.$2[0])} & ${_short(best!.$2[1])}';
  }

  // No junction in range: the nearest road, if it is close enough.
  (double, String)? road;
  for (final w in ways) {
    for (final id in (w['nodes'] as List? ?? const [])) {
      final pos = nodes[id as int];
      if (pos == null) continue;
      final d = _metres(lat, lon, pos.$1, pos.$2);
      if (d <= _roadOnlyRadiusM && (road == null || d < road.$1)) {
        road = (d, (w['tags'] as Map<String, dynamic>)['name'] as String);
      }
    }
  }
  return road == null ? null : _short(road.$2);
}

const Map<String, String> _suffixes = {
  'Road': 'Rd',
  'Street': 'St',
  'Avenue': 'Ave',
  'Drive': 'Dr',
  'Crescent': 'Cres',
  'Boulevard': 'Blvd',
  'Lane': 'Ln',
  'Close': 'Cl',
  'Highway': 'Hwy',
  'Place': 'Pl',
  'Terrace': 'Tce',
  'Way': 'Way',
};

/// "Voortrekker Road" → "Voortrekker Rd", to keep a table cell to one line.
String _short(String name) {
  final parts = name.split(' ');
  final last = _suffixes[parts.last];
  if (parts.length > 1 && last != null) parts[parts.length - 1] = last;
  return parts.join(' ');
}

double _metres(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(x)));
}
