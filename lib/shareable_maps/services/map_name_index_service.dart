import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The searchable part of one shareable map: names and the bits a gallery
/// tile shows, never its layers.
class MapIndexEntry {
  final String docId;
  final String monthKey;
  final String name;
  final String description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double centerLat;
  final double centerLng;
  final String? thumbnailUrl;
  final int waypointCount;

  const MapIndexEntry({
    required this.docId,
    required this.monthKey,
    required this.name,
    required this.description,
    required this.createdAt,
    required this.updatedAt,
    required this.centerLat,
    required this.centerLng,
    this.thumbnailUrl,
    this.waypointCount = 0,
  });
}

/// What has arrived so far while the index loads month by month.
class MapIndexProgress {
  /// Maps loaded so far, newest first.
  final List<MapIndexEntry> entries;
  final int monthsLoaded;
  final int monthsTotal;
  final bool done;

  const MapIndexProgress(
      this.entries, this.monthsLoaded, this.monthsTotal, this.done);
}

/// Every shareable map's name and description, across all months, without
/// downloading any map data.
///
/// Map documents carry their full layers inline (every polygon point and
/// track), so listing them through the SDK pulls megabytes just to show
/// names. The Dart SDK has no field mask, so this asks the Firestore REST API
/// for the handful of fields searching needs — the same approach as
/// LetterboxFolderService. Falls back to full SDK reads only if REST fails,
/// so a token/CORS problem degrades to "slow", not "broken".
///
/// **Lazy:** months are fetched newest first, a few at a time, and [progress]
/// is updated as each one lands, so a picker can show (and search) this
/// month's maps while older months are still arriving.
///
/// Results are cached briefly so reopening a picker or retyping a search does
/// not refetch; [invalidate] after creating, renaming or deleting a map. A
/// refresh keeps showing the previous list until the new one is complete.
class MapNameIndexService {
  MapNameIndexService._();
  static final MapNameIndexService instance = MapNameIndexService._();

  static const Duration _ttl = Duration(minutes: 2);
  static const int _parallelMonths = 4;
  static final RegExp _monthKey = RegExp(r'^\d{2}-\d{4}$');

  /// The only fields fetched. `layers` — nearly all of each document — is
  /// deliberately absent.
  static const List<String> _fields = [
    'name',
    'description',
    'monthKey',
    'createdAt',
    'updatedAt',
    'defaultCenterLat',
    'defaultCenterLng',
    'thumbnailUrl',
    'cloudWaypointCount',
  ];

  final http.Client _http = http.Client();
  List<MapIndexEntry>? _cache;
  DateTime? _cachedAt;
  Future<List<MapIndexEntry>>? _inFlight;

  /// Live view of the load: partial while months arrive, then complete.
  /// Null until the first load starts.
  final ValueNotifier<MapIndexProgress?> progress = ValueNotifier(null);

  void invalidate() {
    _cachedAt = null; // keep _cache so a refresh can show it meanwhile
  }

  /// All maps, newest first. Watch [progress] to show results before this
  /// completes.
  Future<List<MapIndexEntry>> fetchAll({bool force = false}) {
    final cachedAt = _cachedAt;
    final cache = _cache;
    if (!force &&
        cache != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _ttl) {
      return Future.value(cache);
    }
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<List<MapIndexEntry>> _load() async {
    final sw = Stopwatch()..start();
    final previous = _cache;
    final months = await _listMonths();
    final entries = <MapIndexEntry>[];
    var loaded = 0;
    var failed = false;

    void publish({bool done = false}) {
      // A refresh with an old list to show only swaps in the finished one,
      // so maps don't vanish and reappear while months reload.
      if (previous != null && !done) return;
      progress.value =
          MapIndexProgress(List.unmodifiable(entries), loaded, months.length,
              done);
    }

    publish();
    var next = 0;
    Future<void> worker() async {
      while (next < months.length) {
        final mk = months[next++];
        try {
          entries.addAll(await _month(mk));
        } catch (e) {
          failed = true;
          debugPrint('[MapNameIndex] month $mk failed: $e');
        }
        loaded++;
        entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        publish();
      }
    }

    await Future.wait([
      for (var i = 0; i < _parallelMonths; i++) worker(),
    ]);
    publish(done: true);
    debugPrint('[MapNameIndex] ${entries.length} maps from ${months.length} '
        'months in ${sw.elapsedMilliseconds}ms');
    if (!failed) {
      _cache = entries;
      _cachedAt = DateTime.now();
    }
    return entries;
  }

  /// Month keys, newest first.
  Future<List<String>> _listMonths() async {
    List<String>? ids;
    try {
      ids = await _monthIdsViaRest();
    } catch (e) {
      debugPrint('[MapNameIndex] REST month list failed: $e');
    }
    ids ??= (await FirebaseFirestore.instance.collection('shareableMaps').get())
        .docs
        .map((d) => d.id)
        .toList();
    String sortable(String mk) => '${mk.substring(3)}-${mk.substring(0, 2)}';
    return ids.where(_monthKey.hasMatch).toList()
      ..sort((a, b) => sortable(b).compareTo(sortable(a)));
  }

  Future<List<MapIndexEntry>> _month(String mk) async {
    final viaRest = await _monthViaRest(mk).catchError((Object e) {
      debugPrint('[MapNameIndex] REST $mk failed, using SDK: $e');
      return null;
    });
    if (viaRest != null) return viaRest;
    // Fallback: whole documents, layers and all.
    final snap = await FirebaseFirestore.instance
        .collection('shareableMaps')
        .doc(mk)
        .collection('maps')
        .get();
    return [
      for (final doc in snap.docs)
        if (_entry(doc.id, mk, doc.data()) case final e?) e,
    ];
  }

  Future<String?> _token() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final token = await user.getIdToken();
    return (token == null || token.isEmpty) ? null : token;
  }

  /// POSTs a runQuery under [parent] (e.g. `shareableMaps/03-2026`, or ''
  /// for the root). Null when not signed in or the call fails.
  Future<List<Map>?> _runQuery(
      String parent, Map<String, dynamic> structuredQuery) async {
    final token = await _token();
    if (token == null) return null;
    final projectId = Firebase.app().options.projectId;
    final base = 'https://firestore.googleapis.com/v1/projects/$projectId/'
        'databases/(default)/documents';
    final response = await _http.post(
      Uri.parse(parent.isEmpty ? '$base:runQuery' : '$base/$parent:runQuery'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'structuredQuery': structuredQuery}),
    );
    if (response.statusCode != 200) {
      debugPrint('[MapNameIndex] REST HTTP ${response.statusCode}: '
          '${response.body.substring(0, response.body.length.clamp(0, 300))}');
      return null;
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return null;
    return [
      for (final row in decoded)
        if (row is Map && row['document'] is Map) row['document'] as Map,
    ];
  }

  Future<List<String>?> _monthIdsViaRest() async {
    final docs = await _runQuery('', {
      'from': [
        {'collectionId': 'shareableMaps'}
      ],
      'select': {
        'fields': [
          {'fieldPath': '__name__'}
        ]
      },
    });
    return docs?.map((d) => (d['name'] as String).split('/').last).toList();
  }

  Future<List<MapIndexEntry>?> _monthViaRest(String mk) async {
    final docs = await _runQuery('shareableMaps/$mk', {
      'from': [
        {'collectionId': 'maps'}
      ],
      'select': {
        'fields': [
          for (final f in _fields) {'fieldPath': f}
        ]
      },
    });
    if (docs == null) return null;
    final entries = <MapIndexEntry>[];
    for (final doc in docs) {
      final id = (doc['name'] as String? ?? '').split('/').last;
      final fields = (doc['fields'] as Map?)?.cast<String, dynamic>() ?? {};
      final data = {
        for (final e in fields.entries) e.key: _restValue(e.value),
      };
      final entry = _entry(id, mk, data);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  MapIndexEntry? _entry(
      String docId, String pathMonth, Map<String, dynamic> data) {
    final monthKey = data['monthKey'] as String? ?? pathMonth;
    if (!_monthKey.hasMatch(monthKey)) return null;
    DateTime time(Object? v) => v is num
        ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
        : DateTime.fromMillisecondsSinceEpoch(0);
    return MapIndexEntry(
      docId: docId,
      monthKey: monthKey,
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      createdAt: time(data['createdAt']),
      updatedAt: time(data['updatedAt']),
      centerLat: (data['defaultCenterLat'] as num?)?.toDouble() ?? -33.925,
      centerLng: (data['defaultCenterLng'] as num?)?.toDouble() ?? 18.425,
      thumbnailUrl: data['thumbnailUrl'] as String?,
      waypointCount: (data['cloudWaypointCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// A REST `Value` as a plain Dart value (only the scalar kinds used here).
  static Object? _restValue(Object? v) {
    if (v is! Map) return null;
    if (v.containsKey('stringValue')) return v['stringValue'];
    if (v.containsKey('integerValue')) {
      return int.tryParse('${v['integerValue']}');
    }
    if (v.containsKey('doubleValue')) return (v['doubleValue'] as num?);
    return null;
  }
}
