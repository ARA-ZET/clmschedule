import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/work_suburb.dart';
import '../../shareable_maps/services/suburb_data_service.dart';
import '../../track_editor/services/point_in_polygon.dart';
import '../models/letterbox_suburb.dart';
import '../services/letterbox_area_write_service.dart';
import '../services/letterbox_codec.dart';
import '../services/letterbox_count_service.dart';
import '../services/letterbox_firestore_service.dart';
import '../services/letterbox_folder_service.dart';
import '../services/letterbox_seed_service.dart';
import '../services/letterbox_storage_service.dart';
import '../utils/letterbox_clusters.dart';

/// What the curation map is currently doing with taps.
enum LetterboxTool {
  /// Taps do nothing; the map pans normally.
  browse,

  /// Each tap adds a letterbox.
  add,

  /// Each tap removes the nearest letterbox within a small radius.
  remove,

  /// Tap out a polygon; everything inside it is deleted on close.
  lassoDelete,

  /// Tap out a polygon and see how many curated letterboxes fall inside it,
  /// without changing anything. This is the question the whole index exists to
  /// answer — quoting a client, sizing a work area, checking a distributor.
  measure,
}

/// Editor state for curating one suburb's letterbox set.
///
/// Deliberately its own provider rather than an extension of
/// `ShareableMapProvider`: that class is 3 600 lines and its lasso selects
/// *work areas and suburbs*, not map points, so bulk point curation there
/// would mean surgery on the busiest file in the app. Keeping this separate is
/// what makes the letterbox work safe to build alongside a live editor.
class LetterboxProvider extends ChangeNotifier {
  final SuburbDataService _suburbData;
  final LetterboxFirestoreService _firestore;
  final LetterboxStorageService _storage;
  final LetterboxSeedService _seeder;
  final LetterboxCountService _counter;
  final LetterboxFolderService _folderService;

  /// Every write into the index inside a drawn area goes through this, shared
  /// with the track editor's update action so both obey the same rules.
  late final LetterboxAreaWriteService _areaWriter;

  LetterboxProvider({
    SuburbDataService? suburbData,
    LetterboxFirestoreService? firestore,
    LetterboxStorageService? storage,
    LetterboxSeedService? seeder,
    LetterboxCountService? counter,
    LetterboxFolderService? folderService,
  })  : _suburbData = suburbData ?? SuburbDataService(),
        _firestore = firestore ?? LetterboxFirestoreService(),
        _storage = storage ?? LetterboxStorageService(),
        _seeder = seeder ?? LetterboxSeedService(),
        _counter = counter ?? LetterboxCountService(),
        _folderService = folderService ?? LetterboxFolderService() {
    _areaWriter = LetterboxAreaWriteService(
      suburbData: _suburbData,
      firestore: _firestore,
      storage: _storage,
      // The provider's own counter, so a replace invalidates the very cache
      // the measure tool reads.
      counter: _counter,
    );
  }

  // ── Suburb catalogue ─────────────────────────────────────────────────

  List<WorkSuburb> _suburbs = [];
  Map<String, LetterboxSuburb> _meta = {};
  bool _loadingCatalogue = false;
  String? _error;

  List<WorkSuburb> get suburbs => List.unmodifiable(_suburbs);
  Map<String, LetterboxSuburb> get meta => Map.unmodifiable(_meta);
  bool get isLoadingCatalogue => _loadingCatalogue;
  String? get error => _error;

  /// Suburbs already curated and signed off.
  int get verifiedCount => _meta.values
      .where((m) => m.status == LetterboxSuburbStatus.verified)
      .length;

  /// Total letterboxes across every verified suburb — the trustworthy
  /// city-wide number.
  int get verifiedLetterboxTotal => _meta.values
      .where((m) => m.status == LetterboxSuburbStatus.verified)
      .fold(0, (total, m) => total + m.count);

  LetterboxSuburb? metaFor(String suburbId) => _meta[suburbId];

  // ── Selected suburb ──────────────────────────────────────────────────

  WorkSuburb? _selected;
  List<LatLng> _points = [];
  bool _dirty = false;
  bool _busy = false;
  String? _status;

  /// Raw drops that fell inside the suburb on the last seed, before dedup.
  int _lastRawInside = 0;

  WorkSuburb? get selected => _selected;
  List<LatLng> get points => List.unmodifiable(_points);
  int get count => _points.length;

  /// Bumped whenever the working point set changes. Lets the map cache its
  /// marker set instead of rebuilding thousands of Marker objects on every
  /// rebuild — and a rebuild happens on every provider notify, including a
  /// mouse moving over a panel.
  int _pointsVersion = 0;
  int get pointsVersion => _pointsVersion;

  /// Bumped whenever suburb metadata changes, for the same reason: the map
  /// shades 613 polygons by curation status.
  int _metaVersion = 0;
  int get metaVersion => _metaVersion;

  LetterboxGroups? _groupsCache;
  int _groupsVersion = -1;

  void _setPoints(List<LatLng> next) {
    _points = next;
    _pointsVersion++;
  }

  void _setMeta(Map<String, LetterboxSuburb> next) {
    _meta = next;
    _metaVersion++;
  }

  /// Houses and located apartment blocks for the open suburb.
  ///
  /// Cached against [_pointsVersion]: clustering is a grid build plus a pass
  /// over every point, and this is read from both the toolbar and the map on
  /// every build. Recomputing it per build was making the map crawl.
  LetterboxGroups get groups {
    if (_groupsCache == null || _groupsVersion != _pointsVersion) {
      _groupsCache = LetterboxClusters.group(_points);
      _groupsVersion = _pointsVersion;
    }
    return _groupsCache!;
  }

  LetterboxBreakdown get breakdown => groups.breakdown;

  /// Draw freestanding houses. Independent of [showApartments] so either can
  /// be isolated — useful when planning a round that only covers one or the
  /// other.
  bool _showHouses = true;
  bool get showHouses => _showHouses;

  bool _showApartments = true;
  bool get showApartments => _showApartments;

  void setShowHouses(bool value) {
    if (_showHouses == value) return;
    _showHouses = value;
    notifyListeners();
  }

  void setShowApartments(bool value) {
    if (_showApartments == value) return;
    _showApartments = value;
    notifyListeners();
  }

  bool get isDirty => _dirty;
  bool get isBusy => _busy;
  String? get statusMessage => _status;
  int get lastRawInsideCount => _lastRawInside;

  LetterboxTool _tool = LetterboxTool.browse;
  LetterboxTool get tool => _tool;

  /// Draw every suburb boundary, shaded by curation status, not just the one
  /// being edited. Gives the surrounding context while curating and doubles as
  /// a progress view over all 613. Cheap to render: the whole set is 14 787
  /// vertices.
  bool _showAllSuburbs = true;
  bool get showAllSuburbs => _showAllSuburbs;

  void setShowAllSuburbs(bool value) {
    if (_showAllSuburbs == value) return;
    _showAllSuburbs = value;
    notifyListeners();
  }

  /// Draw the individual letterboxes on the map.
  ///
  /// Each one is a marker, and on web every marker is a DOM node pushed across
  /// the JS bridge — a few thousand of them is what makes the map heavy. The
  /// boundaries, the test-area tool and every count work fine without them.
  ///
  /// **Off by default**, so opening a dense suburb never drops you into a
  /// sluggish map. Switching to the Add or Remove tool turns it back on, since
  /// editing letterboxes you cannot see is nonsense, and a notice on the map
  /// says how many are hidden so an empty-looking suburb is never mistaken for
  /// an empty one.
  bool _showLetterboxes = false;
  bool get showLetterboxes => _showLetterboxes;

  void setShowLetterboxes(bool value) {
    if (_showLetterboxes == value) return;
    _showLetterboxes = value;
    notifyListeners();
  }

  /// Drops from the last seed that fell outside every suburb boundary.
  ///
  /// Kept so they can be drawn: a count alone tells you letterboxes went
  /// missing but not where, and the where is the whole diagnosis — a hole in
  /// the suburb layer, a boundary drawn short, or a file covering somewhere
  /// else entirely.
  List<LatLng> _unmatched = const [];
  List<LatLng> get unmatchedPoints => List.unmodifiable(_unmatched);

  int _unmatchedVersion = 0;
  int get unmatchedVersion => _unmatchedVersion;

  /// Total unmatched from the last seed, which can exceed the kept sample.
  int _unmatchedTotal = 0;
  int get unmatchedTotal => _unmatchedTotal;

  bool _showUnmatched = true;
  bool get showUnmatched => _showUnmatched;

  void setShowUnmatched(bool value) {
    if (_showUnmatched == value) return;
    _showUnmatched = value;
    notifyListeners();
  }

  void clearUnmatched() {
    if (_unmatched.isEmpty && _unmatchedTotal == 0) return;
    _unmatched = const [];
    _unmatchedTotal = 0;
    _unmatchedVersion++;
    notifyListeners();
  }

  void _setUnmatched(List<LatLng> points, int total) {
    _unmatched = points;
    _unmatchedTotal = total;
    _unmatchedVersion++;
  }

  /// Curation status of [suburbId], defaulting to unseeded when it has no
  /// metadata document yet.
  LetterboxSuburbStatus statusOf(String suburbId) =>
      _meta[suburbId]?.status ?? LetterboxSuburbStatus.unseeded;

  Map<LetterboxSuburbStatus, int>? _statusCountsCache;
  int _statusCountsVersion = -1;

  /// How many suburbs sit at each curation status.
  ///
  /// Cached against [_metaVersion]. The sidebar's filter chips and the map
  /// legend both want all four numbers, and computing them inline meant
  /// scanning 613 suburbs eight times on every rebuild.
  Map<LetterboxSuburbStatus, int> get statusCounts {
    if (_statusCountsCache == null ||
        _statusCountsVersion != _metaVersion ||
        _statusCountsCache!.values.fold(0, (a, b) => a + b) !=
            _suburbs.length) {
      final counts = {for (final s in LetterboxSuburbStatus.values) s: 0};
      for (final suburb in _suburbs) {
        final status = statusOf(suburb.id);
        counts[status] = counts[status]! + 1;
      }
      _statusCountsCache = counts;
      _statusCountsVersion = _metaVersion;
    }
    return _statusCountsCache!;
  }

  final List<LatLng> _lasso = [];
  List<LatLng> get lassoPoints => List.unmodifiable(_lasso);

  // ── Measure tool ─────────────────────────────────────────────────────

  final List<LatLng> _measure = [];
  LetterboxCount? _measureResult;
  bool _measuring = false;

  List<LatLng> get measurePoints => List.unmodifiable(_measure);

  /// Result of the last measurement, or null while under three points.
  LetterboxCount? get measureResult => _measureResult;

  /// True while a count is in flight, so the panel can show it is working
  /// rather than appearing to show a stale number.
  bool get isMeasuring => _measuring;

  void undoMeasurePoint() {
    if (_measure.isEmpty) return;
    _measure.removeLast();
    _recountMeasure();
    notifyListeners();
  }

  void clearMeasure() {
    _measure.clear();
    _measureResult = null;
    notifyListeners();
  }

  /// Recount the drawn area.
  ///
  /// Counts the SAVED letterboxes, because that is what a quote or a review
  /// would be based on. Unsaved edits in the open suburb are deliberately not
  /// included — the panel says so.
  Future<void> _recountMeasure() async {
    if (_measure.length < 3) {
      _measureResult = null;
      return;
    }
    _measuring = true;
    notifyListeners();
    try {
      _measureResult = await _counter.countIn(List<LatLng>.from(_measure));
    } catch (e) {
      _measureResult = null;
      _status = 'Could not count that area: $e';
      debugPrint('[LetterboxProvider] measure failed: $e');
    }
    _measuring = false;
    notifyListeners();
  }

  // Undo/redo over whole point-list snapshots. A suburb is a few thousand
  // positions, so a snapshot is cheap and far simpler to reason about than
  // a command log — and correctness matters more than bytes here.
  final List<List<LatLng>> _undo = [];
  final List<List<LatLng>> _redo = [];
  static const int _maxHistory = 50;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  // ── Folder catalogue (seed source) ───────────────────────────────────

  final List<WaypointFolder> _folders = [];
  bool _loadingFolders = false;

  /// GPX counts, filled in only for folders the user actually selects. The
  /// listing deliberately does not carry them — see LetterboxFolderService.
  final Map<String, int> _gpxCounts = {};
  final Set<String> _countsInFlight = {};

  List<WaypointFolder> get folders => List.unmodifiable(_folders);
  bool get isLoadingFolders => _loadingFolders;

  /// GPX count for [folderPath], or null if not fetched yet.
  int? gpxCountFor(String folderPath) => _gpxCounts[folderPath];

  /// Fetch a folder's GPX count on demand — one document read, triggered when
  /// the user selects it rather than for all ~340 up front.
  Future<void> fetchGpxCount(String folderPath) async {
    if (_gpxCounts.containsKey(folderPath) ||
        _countsInFlight.contains(folderPath)) {
      return;
    }
    _countsInFlight.add(folderPath);
    final count = await _folderService.gpxCountFor(folderPath);
    _countsInFlight.remove(folderPath);
    if (count != null) {
      _gpxCounts[folderPath] = count;
      notifyListeners();
    }
  }

  // ── Loading ──────────────────────────────────────────────────────────

  Future<void> loadCatalogue() async {
    _loadingCatalogue = true;
    _error = null;
    notifyListeners();
    // Loaded independently, not with Future.wait: the two come from different
    // collections with different rules, and a failure in one must not hide the
    // other or get reported under the other's name. Before this, a denied read
    // on letterboxSuburbs surfaced as "Could not load suburbs", which pointed
    // at entirely the wrong collection.
    try {
      _suburbs = (await _suburbData.loadSuburbs())
          .where((s) => s.polygonPoints.length >= 3)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } catch (e) {
      _error = 'Could not load suburb boundaries (workSuburbs/main): $e';
      debugPrint('[LetterboxProvider] loadSuburbs failed: $e');
      _loadingCatalogue = false;
      notifyListeners();
      return;
    }

    // Curation metadata is optional on a cold start — before the first seed
    // the collection does not exist at all, and every suburb is simply
    // "not seeded". Only report a real failure.
    try {
      _setMeta({for (final m in await _firestore.getAll()) m.suburbId: m});
    } catch (e) {
      _setMeta({});
      _error = 'Loaded ${_suburbs.length} suburbs, but could not read '
          'curation status (letterboxSuburbs): $e';
      debugPrint('[LetterboxProvider] letterbox metadata failed: $e');
    }
    _loadingCatalogue = false;
    notifyListeners();
  }

  /// Folder paths for the seed picker.
  ///
  /// Names only: the listing is a field-masked query that returns just the
  /// paths, not the filename maps that make up almost all of each document.
  /// Anything else a folder needs is fetched when it is selected, because a
  /// user typically picks one or two folders out of hundreds.
  Future<void> loadFolders() async {
    if (_folders.isNotEmpty || _loadingFolders) return;
    _loadingFolders = true;
    notifyListeners();
    try {
      _folders
        ..clear()
        ..addAll(await _folderService.listFolderPaths());
    } catch (e) {
      _error = 'Could not list cloud folders: $e';
      debugPrint('[LetterboxProvider] loadFolders failed: $e');
    }
    _loadingFolders = false;
    notifyListeners();
  }

  /// Open [suburb] for curation, loading its saved payload if one exists.
  Future<void> selectSuburb(WorkSuburb suburb) async {
    _selected = suburb;
    _setPoints([]);
    _undo.clear();
    _redo.clear();
    _lasso.clear();
    _tool = LetterboxTool.browse;
    _dirty = false;
    _lastRawInside = 0;
    _busy = true;
    _status = null;
    notifyListeners();

    try {
      final bytes = await _storage.load(suburb.id);
      if (bytes != null) {
        _setPoints(await LetterboxCodec.decodeAsync(bytes));
        _status = 'Loaded ${_points.length} saved letterboxes.';
      } else {
        _status = 'No saved letterboxes yet — seed this suburb to start.';
      }
    } catch (e) {
      _status = 'Could not load saved letterboxes: $e';
      debugPrint('[LetterboxProvider] selectSuburb failed: $e');
    }

    _busy = false;
    notifyListeners();
  }

  // ── Seeding ──────────────────────────────────────────────────────────

  /// Replace the working set with candidates seeded from [folderPaths].
  ///
  /// Destructive by design: seeding is the *starting point* for curation, so
  /// it discards unsaved edits. The UI confirms before calling this.
  Future<void> seedFrom(List<String> folderPaths) async {
    final suburb = _selected;
    if (suburb == null || folderPaths.isEmpty) return;

    _busy = true;
    _status = 'Seeding from ${folderPaths.length} folder(s)…';
    notifyListeners();

    try {
      final result = await _seeder.seedFromFolders(
        folderPaths: folderPaths,
        suburbPolygon: suburb.polygonPoints,
        onProgress: (done, total) {
          _status = 'Reading folder $done of $total…';
          notifyListeners();
        },
      );

      _pushUndo();
      _setPoints(result.points);
      _lastRawInside = result.rawInsideCount;
      _dirty = true;

      final skipped = result.skippedFolders.length;
      if (result.points.isEmpty) {
        // Silence here is what made this confusing: say which of the two
        // reasons it was, because they need opposite fixes.
        _status = skipped == folderPaths.length
            ? 'None of the ${folderPaths.length} folder(s) had a compiled '
                'waypoints file, so there was nothing to seed from.'
            : 'Read ${folderPaths.length - skipped} folder(s), but none of '
                'their waypoints fell inside ${suburb.name}. Those folders '
                'likely cover a different area.'
                '${skipped > 0 ? ' ($skipped folder(s) had no waypoints file.)' : ''}';
      } else {
        _status = 'Seeded ${result.points.length} candidates from '
            '${result.rawInsideCount} drops inside ${suburb.name}'
            '${skipped > 0 ? ' ($skipped folder(s) had no waypoints file)' : ''}. '
            'Review, correct, then save.';
      }
    } catch (e) {
      _status = 'Seed failed: $e';
      debugPrint('[LetterboxProvider] seedFrom failed: $e');
    }

    _busy = false;
    notifyListeners();
  }

  /// Seed **every** suburb from [folderPaths] in one folder-major pass, then
  /// save each result.
  ///
  /// Verified suburbs are never overwritten — they get `hasNewCandidates` so a
  /// human decides. That rule is the whole reason the curated set stays
  /// trustworthy, and it is enforced here as well as in the Cloud Function.
  Future<void> seedAllSuburbs(List<String> folderPaths) async {
    if (folderPaths.isEmpty || _suburbs.isEmpty) return;

    _busy = true;
    _status = 'Reading ${folderPaths.length} folder(s)…';
    notifyListeners();

    try {
      final result = await _seeder.seedAllFromFolders(
        folderPaths: folderPaths,
        suburbs: [
          for (final s in _suburbs)
            SeedSuburb(id: s.id, name: s.name, polygon: s.polygonPoints),
        ],
        onProgress: (done, total) {
          _status = 'Reading folder $done of $total…';
          notifyListeners();
        },
      );

      await _persistSeedAll(result);
    } catch (e) {
      _status = 'Seed-all failed: $e';
      debugPrint('[LetterboxProvider] seedAllSuburbs failed: $e');
    }

    _busy = false;
    notifyListeners();
  }

  /// Save the results of a whole-city seed, whatever the source was.
  ///
  /// Shared by the cloud-folder and device-file paths so the rule that matters
  /// most — a verified suburb is flagged, never overwritten — is written once
  /// and cannot drift between them.
  ///
  /// The work is I/O-bound, not compute-bound: classifying 100 000 waypoints
  /// takes about a second, but saving 613 suburbs one at a time is 1 226
  /// sequential round trips and takes minutes. So uploads run concurrently and
  /// the metadata goes up in batches.
  Future<void> _persistSeedAll(LetterboxSeedAllResult result) async {
    final byId = {for (final s in _suburbs) s.id: s};

    // ── Split verified suburbs off; they are flagged, never overwritten ──
    final toWrite = <MapEntry<WorkSuburb, List<LatLng>>>[];
    final flagged = <LetterboxSuburb>[];

    for (final entry in result.bySuburb.entries) {
      final suburb = byId[entry.key];
      if (suburb == null) continue;
      final existing = _meta[entry.key];
      if (existing?.status == LetterboxSuburbStatus.verified) {
        flagged.add(existing!.copyWith(hasNewCandidates: true));
      } else {
        toWrite.add(MapEntry(suburb, entry.value));
      }
    }

    // ── Encode everything up front: pure CPU, ~250 ms for the whole city ──
    final payloads = <String, Uint8List>{
      for (final e in toWrite)
        e.key.id: LetterboxCodec.encode(
          suburbId: e.key.id,
          suburbName: e.key.name,
          points: e.value,
        ),
    };

    // ── Upload concurrently. Each upload is a round trip; serialising them is
    //    what made this take minutes. Eight at a time keeps the browser's
    //    connection pool busy without swamping it. ──
    final sizes = <String, int>{};
    var done = 0;
    await _forEachConcurrently(toWrite, 8, (entry) async {
      final bytes = payloads[entry.key.id]!;
      try {
        sizes[entry.key.id] = await _storage.save(entry.key.id, bytes);
      } catch (e) {
        debugPrint('[LetterboxProvider] ${entry.key.name} upload failed: $e');
      }
      done++;
      if (done % 20 == 0 || done == toWrite.length) {
        _status = 'Uploading $done of ${toWrite.length} suburbs…';
        notifyListeners();
      }
    });

    // ── One batched metadata write instead of 613 round trips ──
    final metas = <LetterboxSuburb>[...flagged];
    for (final entry in toWrite) {
      final size = sizes[entry.key.id];
      if (size == null) continue; // its upload failed; do not claim it saved
      metas.add(LetterboxSuburb(
        suburbId: entry.key.id,
        suburbName: entry.key.name,
        count: entry.value.length,
        status: LetterboxSuburbStatus.seeded,
        seededCount: entry.value.length,
        hasNewCandidates: false,
        storagePath: LetterboxStorageService.pathFor(entry.key.id),
        storageBytes: size,
        bounds: LetterboxBounds.fromPoints(entry.value),
        formatVersion: LetterboxCodec.formatVersion,
      ));
    }

    _status = 'Saving ${metas.length} suburb records…';
    notifyListeners();
    await _firestore.saveAll(metas);

    final nextMeta = {..._meta};
    for (final m in metas) {
      nextMeta[m.suburbId] = m;
      _counter.invalidate(m.suburbId);
    }
    _setMeta(nextMeta);

    _setUnmatched(result.unmatchedSample, result.unmatchedDrops);

    final saved = metas.length - flagged.length;
    final failed = toWrite.length - saved;

    // Full reconciliation, because "28 000 in, 27 000 out" with no explanation
    // is the kind of gap that quietly undermines trust in every later number.
    final inFile = result.scan?.waypointCount ?? 0;
    final routePts = result.scan?.routePointCount ?? 0;
    final trackPts = result.scan?.trackPointCount ?? 0;
    final declared = inFile + routePts;
    final malformed = declared > 0 ? declared - result.totalDrops : 0;
    final storedTotal =
        result.bySuburb.values.fold(0, (sum, list) => sum + list.length);

    final parts = <String>[
      if (declared > 0) '$declared waypoint(s) in the file',
      '${result.totalDrops} with usable coordinates',
      '${result.insideDrops} inside a suburb',
      '$storedTotal stored',
    ];

    final lost = <String>[
      if (malformed > 0) '$malformed had no usable coordinates',
      if (result.snappedDrops > 0)
        '${result.snappedDrops} sat just outside a boundary and were placed in '
            'the nearest suburb',
      if (result.unmatchedDrops > 0)
        '${result.unmatchedDrops} fell outside every suburb boundary',
      if (trackPts > 0 && (result.scan?.onlyTrackPoints ?? false) == false)
        '$trackPts track point(s) ignored (walked path, not drops)',
      if (result.insideDrops > storedTotal)
        '${result.insideDrops - storedTotal} merged as repeat visits to the '
            'same address',
      if (flagged.isNotEmpty)
        '${flagged.length} verified suburb(s) left untouched',
      if (failed > 0) '$failed upload(s) FAILED — re-run to retry',
    ];

    _status = '${parts.join(' → ')}.'
        '${lost.isEmpty ? '' : ' Difference: ${lost.join('; ')}.'}'
        '${result.unmatchedDrops > 0 ? ' The unmatched ones are drawn on the map in red.' : ''}';

    final open = _selected;
    if (open != null) await selectSuburb(open);
  }

  /// Run [task] over [items] with at most [limit] in flight.
  static Future<void> _forEachConcurrently<T>(
    List<T> items,
    int limit,
    Future<void> Function(T) task,
  ) async {
    var cursor = 0;
    await Future.wait(
      List.generate(limit.clamp(1, items.length), (_) async {
        while (cursor < items.length) {
          final item = items[cursor++];
          await task(item);
        }
      }),
    );
  }

  /// True when the last upload found only track points. The UI uses this to
  /// offer a retry that includes them, rather than leaving the user staring at
  /// an empty map with no explanation.
  bool _lastUploadWasTracksOnly = false;
  bool get lastUploadWasTracksOnly => _lastUploadWasTracksOnly;

  /// Describe what an uploaded set of GPX files actually contained.
  String _describeScan(GpxScanResult scan, String suburbName) {
    if (scan.failedFiles > 0 &&
        scan.waypointCount == 0 &&
        scan.routePointCount == 0 &&
        scan.trackPointCount == 0) {
      return 'None of those files could be read as GPX '
          '(${scan.failedFiles} failed).';
    }
    if (scan.onlyTrackPoints) {
      return 'Those files contain no waypoints — only '
          '${scan.trackPointCount} track points, which is the path that was '
          'walked rather than the drops. If your device records each delivery '
          'as a track point, re-run with "Include track points" turned on.';
    }
    if (scan.waypointCount == 0 && scan.routePointCount == 0) {
      return 'Those files contain no waypoints at all.';
    }
    return 'Found ${scan.waypointCount} waypoint(s) and '
        '${scan.routePointCount} route point(s), but none fell inside '
        '$suburbName. Check you have the right suburb open.';
  }

  /// Seed the open suburb from GPX files on the user's device.
  Future<void> seedFromDeviceFiles(
    List<Uint8List> gpxFiles, {
    bool includeTrackPoints = false,
  }) async {
    final suburb = _selected;
    if (suburb == null || gpxFiles.isEmpty) return;

    _busy = true;
    _lastUploadWasTracksOnly = false;
    _status = 'Parsing ${gpxFiles.length} file(s)…';
    notifyListeners();

    try {
      final result = await _seeder.seedFromGpxFiles(
        gpxFiles: gpxFiles,
        suburbPolygon: suburb.polygonPoints,
        includeTrackPoints: includeTrackPoints,
      );

      if (result.points.isEmpty) {
        final scan = result.scan;
        _lastUploadWasTracksOnly = scan?.onlyTrackPoints ?? false;
        _status = scan == null
            ? 'Nothing was found in those files.'
            : _describeScan(scan, suburb.name);
      } else {
        _pushUndo();
        _setPoints(result.points);
        _lastRawInside = result.rawInsideCount;
        _dirty = true;
        _status = 'Seeded ${result.points.length} candidates from '
            '${result.rawInsideCount} drops inside ${suburb.name}. '
            'Review, correct, then save.';
      }
    } catch (e) {
      _status = 'Could not read those files: $e';
      debugPrint('[LetterboxProvider] seedFromDeviceFiles failed: $e');
    }

    _busy = false;
    notifyListeners();
  }

  /// Seed every suburb from GPX files on the user's device, saving each.
  /// Verified suburbs are flagged, never overwritten.
  Future<void> seedAllFromDeviceFiles(
    List<Uint8List> gpxFiles, {
    bool includeTrackPoints = false,
  }) async {
    if (gpxFiles.isEmpty || _suburbs.isEmpty) return;

    _busy = true;
    _lastUploadWasTracksOnly = false;
    _status = 'Parsing ${gpxFiles.length} file(s)…';
    notifyListeners();

    try {
      final result = await _seeder.seedAllFromGpxFiles(
        gpxFiles: gpxFiles,
        suburbs: [
          for (final s in _suburbs)
            SeedSuburb(id: s.id, name: s.name, polygon: s.polygonPoints),
        ],
        includeTrackPoints: includeTrackPoints,
      );

      if (result.bySuburb.isEmpty && result.scan != null) {
        _lastUploadWasTracksOnly = result.scan!.onlyTrackPoints;
        _status = _describeScan(result.scan!, 'any suburb');
        _busy = false;
        notifyListeners();
        return;
      }
      await _persistSeedAll(result);
    } catch (e) {
      _status = 'Could not read those files: $e';
      debugPrint('[LetterboxProvider] seedAllFromDeviceFiles failed: $e');
    }

    _busy = false;
    notifyListeners();
  }

  // ── Editing ──────────────────────────────────────────────────────────

  void setTool(LetterboxTool tool) {
    if (_tool == tool) return;
    _tool = tool;
    // Placing or deleting letterboxes you cannot see is nonsense, so these
    // tools turn them back on rather than silently doing nothing visible.
    if (tool == LetterboxTool.add || tool == LetterboxTool.remove) {
      _showLetterboxes = true;
    }
    _lasso.clear();
    if (tool != LetterboxTool.measure) {
      _measure.clear();
      _measureResult = null;
    }
    notifyListeners();
  }

  /// Handle a tap on the map in the current tool's terms.
  void handleMapTap(LatLng position) {
    switch (_tool) {
      case LetterboxTool.browse:
        return;
      case LetterboxTool.add:
        _addPoint(position);
      case LetterboxTool.remove:
        _removeNearest(position);
      case LetterboxTool.lassoDelete:
        _lasso.add(position);
      case LetterboxTool.measure:
        _measure.add(position);
        _recountMeasure();
    }
    notifyListeners();
  }

  /// Add a letterbox.
  ///
  /// Deliberately no proximity check: several boxes at one entrance is exactly
  /// how a block of flats is recorded, so points close together are meaningful
  /// data, not a mistake to be prevented. [breakdown] reads those clusters back
  /// as apartment blocks.
  void _addPoint(LatLng position) {
    _pushUndo();
    _setPoints([..._points, position]);
    _dirty = true;
    _status = null;
  }

  /// Delete the nearest letterbox within roughly 25 m of [position].
  void _removeNearest(LatLng position) {
    if (_points.isEmpty) return;
    // Squared degrees is fine for "which is nearest" over a suburb.
    var bestIndex = -1;
    var bestDistance = double.infinity;
    for (var i = 0; i < _points.length; i++) {
      final dLat = _points[i].latitude - position.latitude;
      final dLng = _points[i].longitude - position.longitude;
      final d = dLat * dLat + dLng * dLng;
      if (d < bestDistance) {
        bestDistance = d;
        bestIndex = i;
      }
    }
    // ~25 m tolerance, so a stray tap on empty ground deletes nothing.
    const maxDegrees = 0.00025;
    if (bestIndex < 0 || bestDistance > maxDegrees * maxDegrees) {
      _status = 'No letterbox close enough to that tap.';
      return;
    }
    _pushUndo();
    final next = [..._points]..removeAt(bestIndex);
    _setPoints(next);
    _dirty = true;
    _status = null;
  }

  void undoLassoPoint() {
    if (_lasso.isEmpty) return;
    _lasso.removeLast();
    notifyListeners();
  }

  void cancelLasso() {
    if (_lasso.isEmpty) return;
    _lasso.clear();
    notifyListeners();
  }

  /// Delete every letterbox inside the drawn lasso. This is the operation that
  /// makes a 1 500-point suburb tractable to curate by hand.
  int applyLassoDelete() {
    if (_lasso.length < 3) return 0;
    final polygon = List<LatLng>.from(_lasso);
    final keep = _points.where((p) => !isPointInPolygon(p, polygon)).toList();
    final removed = _points.length - keep.length;
    if (removed > 0) {
      _pushUndo();
      _setPoints(keep);
      _dirty = true;
    }
    _lasso.clear();
    _status = removed == 0
        ? 'Nothing inside that lasso.'
        : 'Deleted $removed letterbox(es).';
    notifyListeners();
    return removed;
  }

  // ── Replace inside an area ───────────────────────────────────────────

  /// What a cross-suburb area replacement did, per suburb.
  ///
  /// Reported rather than just applied: the polygon can reach into suburbs you
  /// never opened, and writing to those silently would be indefensible.
  final List<LetterboxAreaOutcome> _lastAreaOutcomes = [];
  List<LetterboxAreaOutcome> get lastAreaOutcomes =>
      List.unmodifiable(_lastAreaOutcomes);

  /// Suburbs whose boundary could hold part of [area].
  ///
  /// Bounds test only — cheap, and a false positive costs nothing because the
  /// per-suburb pass finds no points to change and skips the write.
  List<WorkSuburb> suburbsOverlapping(List<LatLng> area) {
    final box = LetterboxBounds.fromPoints(area);
    if (box == null) return const [];
    return _suburbs.where((s) {
      final b = LetterboxBounds.fromPoints(s.polygonPoints);
      return b != null && b.intersects(box);
    }).toList();
  }

  /// Replace the part of every overlapping suburb that falls inside [area].
  ///
  /// A drawn polygon rarely respects suburb boundaries, so this splits the work
  /// by suburb: each suburb keeps its letterboxes outside the polygon, and
  /// gains only the fresh points that fall inside BOTH the polygon and its own
  /// boundary. A letterbox therefore always belongs to the suburb that
  /// geographically contains it — draw sloppily over a neighbour and its points
  /// still go to it, not to whichever suburb happened to be open.
  ///
  /// Writes straight to storage for every affected suburb, including the open
  /// one, so the result is consistent across all of them rather than leaving
  /// one unsaved.
  Future<void> _replaceAcrossSuburbs(
      List<LatLng> area, List<LatLng> fresh) async {
    _lastAreaOutcomes.clear();

    // The open suburb's in-memory points are the authority while it is open —
    // otherwise an unsaved edit would be overwritten by the stored copy.
    final open = _selected;
    final overrides = open == null
        ? const <String, List<LatLng>>{}
        : {open.id: List<LatLng>.from(_points)};

    final plan = await _areaWriter.plan(
      area: area,
      fresh: fresh,
      existingOverrides: overrides,
      knownMeta: _meta,
      onProgress: (done, total, name) {
        _status = 'Reading $done of $total: $name…';
        notifyListeners();
      },
    );

    if (plan.suburbs.isEmpty) {
      _status = 'That area does not overlap any suburb.';
      return;
    }

    final result = await _areaWriter.apply(
      plan,
      onProgress: (done, total, name) {
        _status = 'Updating $done of $total: $name…';
        notifyListeners();
      },
    );
    _lastAreaOutcomes.addAll(result.outcomes);
    _lastAreaUndo = result.undo;
    if (result.updatedMeta.isNotEmpty) {
      _setMeta({..._meta, ...result.updatedMeta});
    }

    // Re-read the open suburb so the map shows what was actually written.
    if (open != null) await selectSuburb(open);

    _status = result.summary;
  }

  /// Put the last area replacement back, for as long as this session lives.
  ///
  /// Held in memory only: a page reload loses it, so this is a way out of a
  /// replace you regret in the moment, not a version history.
  LetterboxAreaUndo? _lastAreaUndo;
  bool get canUndoAreaReplace => _lastAreaUndo != null;

  Future<void> undoAreaReplace() async {
    final undo = _lastAreaUndo;
    if (undo == null || _busy) return;

    _busy = true;
    _status = 'Restoring ${undo.suburbCount} suburb(s)…';
    notifyListeners();

    final result = await _areaWriter.restore(
      undo,
      onProgress: (done, total, name) {
        _status = 'Restoring $done of $total: $name…';
        notifyListeners();
      },
    );
    if (result.updatedMeta.isNotEmpty) {
      _setMeta({..._meta, ...result.updatedMeta});
    }
    _lastAreaUndo = null;
    _lastAreaOutcomes.clear();

    final open = _selected;
    if (open != null) await selectSuburb(open);

    final failed = result.failures;
    _status = failed.isEmpty
        ? 'Restored ${undo.suburbCount} suburb(s) to how they were before the '
            'replacement.'
        : 'Restored with errors — could not restore '
            '${failed.map((o) => o.suburbName).join(', ')}.';

    _busy = false;
    notifyListeners();
  }

  /// Replace the letterboxes inside [area] with data from cloud folders.
  Future<void> replaceAreaFromFolders(
      List<LatLng> area, List<String> folderPaths) async {
    if (area.length < 3 || folderPaths.isEmpty) return;

    _busy = true;
    _status = 'Reading ${folderPaths.length} folder(s)…';
    notifyListeners();

    try {
      // Seeded against the drawn area, not the suburb, so only the re-surveyed
      // streets are considered.
      final result = await _seeder.seedFromFolders(
        folderPaths: folderPaths,
        suburbPolygon: area,
        onProgress: (done, total) {
          _status = 'Reading folder $done of $total…';
          notifyListeners();
        },
      );
      await _replaceAcrossSuburbs(area, result.points);
    } catch (e) {
      _status = 'Could not replace that area: $e';
      debugPrint('[LetterboxProvider] replaceAreaFromFolders failed: $e');
    }

    _busy = false;
    notifyListeners();
  }

  /// Replace the letterboxes inside [area] with data from device GPX files.
  Future<void> replaceAreaFromDeviceFiles(
    List<LatLng> area,
    List<Uint8List> gpxFiles, {
    bool includeTrackPoints = false,
  }) async {
    if (area.length < 3 || gpxFiles.isEmpty) return;

    _busy = true;
    _lastUploadWasTracksOnly = false;
    _status = 'Parsing ${gpxFiles.length} file(s)…';
    notifyListeners();

    try {
      final result = await _seeder.seedFromGpxFiles(
        gpxFiles: gpxFiles,
        suburbPolygon: area,
        includeTrackPoints: includeTrackPoints,
      );

      if (result.points.isEmpty) {
        final scan = result.scan;
        _lastUploadWasTracksOnly = scan?.onlyTrackPoints ?? false;
        // Nothing usable: leave the existing letterboxes alone rather than
        // emptying the area on the strength of a file that gave us nothing.
        _status = scan == null
            ? 'Nothing was found in those files — the area is unchanged.'
            : '${_describeScan(scan, 'the drawn area')} '
                'The area is unchanged.';
      } else {
        await _replaceAcrossSuburbs(area, result.points);
      }
    } catch (e) {
      _status = 'Could not replace that area: $e';
      debugPrint('[LetterboxProvider] replaceAreaFromDeviceFiles failed: $e');
    }

    _busy = false;
    notifyListeners();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(List<LatLng>.from(_points));
    _setPoints(_undo.removeLast());
    _dirty = true;
    _status = null;
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(List<LatLng>.from(_points));
    _setPoints(_redo.removeLast());
    _dirty = true;
    _status = null;
    notifyListeners();
  }

  void _pushUndo() {
    _undo.add(List<LatLng>.from(_points));
    if (_undo.length > _maxHistory) _undo.removeAt(0);
    _redo.clear();
  }

  // ── Saving ───────────────────────────────────────────────────────────

  /// Persist the working set: one gzipped Storage object plus one metadata
  /// document. [markVerified] flips the suburb into the trusted state.
  Future<bool> save({bool markVerified = false}) async {
    final suburb = _selected;
    if (suburb == null) return false;

    _busy = true;
    _status = 'Saving…';
    notifyListeners();

    try {
      final bytes = LetterboxCodec.encode(
        suburbId: suburb.id,
        suburbName: suburb.name,
        points: _points,
      );
      final size = await _storage.save(suburb.id, bytes);

      final previous = _meta[suburb.id];
      final status = markVerified
          ? LetterboxSuburbStatus.verified
          : (_points.isEmpty
              ? LetterboxSuburbStatus.unseeded
              : LetterboxSuburbStatus.inProgress);

      final updated = LetterboxSuburb(
        suburbId: suburb.id,
        suburbName: suburb.name,
        count: _points.length,
        status: status,
        seededCount: _lastRawInside > 0
            ? _points.length
            : (previous?.seededCount ?? _points.length),
        // Saving is the human review, so any pending-candidates flag is
        // answered by the act of saving.
        hasNewCandidates: false,
        verifiedAt: markVerified ? DateTime.now() : previous?.verifiedAt,
        verifiedBy: markVerified
            ? (FirebaseAuth.instance.currentUser?.email ??
                FirebaseAuth.instance.currentUser?.uid)
            : previous?.verifiedBy,
        storagePath: LetterboxStorageService.pathFor(suburb.id),
        storageBytes: size,
        bounds: LetterboxBounds.fromPoints(_points),
        formatVersion: LetterboxCodec.formatVersion,
      );

      await _firestore.save(updated);
      _setMeta({..._meta, suburb.id: updated});

      // The count service caches payloads per session; without this the map
      // and any live quote would keep answering from the pre-save data.
      _counter.invalidate(suburb.id);

      _dirty = false;
      final split = breakdown;
      final detail = split.apartmentBlocks == 0
          ? ''
          : ' ${split.houses} house(s), ${split.apartmentBoxes} box(es) '
              'across ${split.apartmentBlocks} block(s).';
      _status = markVerified
          ? 'Saved and marked verified — ${_points.length} letterboxes.$detail'
          : 'Saved ${_points.length} letterboxes.$detail';
      _busy = false;
      notifyListeners();
      return true;
    } catch (e) {
      _status = 'Save failed: $e';
      debugPrint('[LetterboxProvider] save failed: $e');
      _busy = false;
      notifyListeners();
      return false;
    }
  }

  // ── Bulk verification ────────────────────────────────────────────────

  /// Mark several suburbs verified in one pass.
  ///
  /// "Verified" is the flag that makes a count quotable and makes a distributor
  /// review defensible, so this deliberately does not offer a blanket
  /// verify-everything: you pass the suburbs you have actually looked at.
  ///
  /// Suburbs with no letterboxes are skipped — signing off an empty suburb
  /// would assert that it genuinely has zero, which is almost never what is
  /// meant and would quietly drag the city-wide total down.
  ///
  /// Returns the number verified.
  Future<int> verifySuburbs(Iterable<String> suburbIds) async {
    final now = DateTime.now();
    final who = FirebaseAuth.instance.currentUser?.email ??
        FirebaseAuth.instance.currentUser?.uid;

    final updates = <LetterboxSuburb>[];
    var skippedEmpty = 0;

    for (final id in suburbIds) {
      final meta = _meta[id];
      if (meta == null || meta.count == 0) {
        skippedEmpty++;
        continue;
      }
      if (meta.status == LetterboxSuburbStatus.verified &&
          !meta.hasNewCandidates) {
        continue; // already signed off, nothing to change
      }
      updates.add(meta.copyWith(
        status: LetterboxSuburbStatus.verified,
        verifiedAt: now,
        verifiedBy: who,
        hasNewCandidates: false,
      ));
    }

    if (updates.isEmpty) {
      _status = skippedEmpty > 0
          ? 'Nothing to verify — $skippedEmpty suburb(s) have no letterboxes '
              'yet.'
          : 'Those suburbs are already verified.';
      notifyListeners();
      return 0;
    }

    _busy = true;
    _status = 'Verifying ${updates.length} suburb(s)…';
    notifyListeners();

    try {
      await _firestore.saveAll(updates);
      final next = {..._meta};
      for (final m in updates) {
        next[m.suburbId] = m;
      }
      _setMeta(next);

      final total = updates.fold(0, (sum, m) => sum + m.count);
      _status = 'Verified ${updates.length} suburb(s), '
          '$total letterboxes now trusted.'
          '${skippedEmpty == 0 ? '' : ' $skippedEmpty skipped for having no letterboxes.'}';
    } catch (e) {
      _status = 'Could not verify: $e';
      debugPrint('[LetterboxProvider] verifySuburbs failed: $e');
    }

    _busy = false;
    notifyListeners();
    return updates.length;
  }

  /// Undo verification for several suburbs.
  ///
  /// The counterpart to [verifySuburbs]: a suburb signed off in error, or one
  /// whose data has since changed, must be demotable — otherwise the only way
  /// back is to edit and re-save it, and a wrong "verified" would sit in quotes
  /// and distributor reviews until someone noticed.
  Future<int> unverifySuburbs(Iterable<String> suburbIds) async {
    final updates = <LetterboxSuburb>[];
    for (final id in suburbIds) {
      final meta = _meta[id];
      if (meta == null || meta.status != LetterboxSuburbStatus.verified) {
        continue;
      }
      updates.add(LetterboxSuburb(
        suburbId: meta.suburbId,
        suburbName: meta.suburbName,
        count: meta.count,
        status: LetterboxSuburbStatus.inProgress,
        seededCount: meta.seededCount,
        hasNewCandidates: meta.hasNewCandidates,
        // Cleared, not kept: leaving a stamp on a suburb that is no longer
        // signed off would misrepresent who stands behind it.
        storagePath: meta.storagePath,
        storageBytes: meta.storageBytes,
        bounds: meta.bounds,
        formatVersion: meta.formatVersion,
      ));
    }

    if (updates.isEmpty) {
      _status = 'None of those suburbs are verified.';
      notifyListeners();
      return 0;
    }

    _busy = true;
    _status = 'Unverifying ${updates.length} suburb(s)…';
    notifyListeners();

    try {
      await _firestore.saveAll(updates);
      final next = {..._meta};
      for (final m in updates) {
        next[m.suburbId] = m;
      }
      _setMeta(next);
      final total = updates.fold(0, (sum, m) => sum + m.count);
      _status = 'Unverified ${updates.length} suburb(s) — $total letterboxes '
          'are no longer counted as trusted.';
    } catch (e) {
      _status = 'Could not unverify: $e';
      debugPrint('[LetterboxProvider] unverifySuburbs failed: $e');
    }

    _busy = false;
    notifyListeners();
    return updates.length;
  }

  // ── Round-trip proof ─────────────────────────────────────────────────

  /// Count the saved letterboxes inside the suburb polygon by going all the
  /// way back out through [LetterboxCountService] — Storage fetch, gzip
  /// decode, spatial index, ray cast.
  ///
  /// This is the end-to-end check that the number a quote would show matches
  /// what was actually curated, rather than trusting the in-memory list.
  Future<LetterboxCount?> verifyRoundTrip() async {
    final suburb = _selected;
    if (suburb == null) return null;

    _busy = true;
    _status = 'Reading back through the count service…';
    notifyListeners();

    try {
      _counter.invalidate(suburb.id);
      final result = await _counter.countIn(suburb.polygonPoints);
      final matches = result.count == _points.length;
      _status = matches
          ? 'Round trip OK — countIn() returned ${result.count}, '
              'matching the ${_points.length} on screen.'
          : 'MISMATCH — countIn() returned ${result.count} but the editor '
              'holds ${_points.length}. Points may sit outside the suburb '
              'polygon, or the save did not land.';
      _busy = false;
      notifyListeners();
      return result;
    } catch (e) {
      _status = 'Round-trip check failed: $e';
      _busy = false;
      notifyListeners();
      return null;
    }
  }

  void clearStatus() {
    if (_status == null) return;
    _status = null;
    notifyListeners();
  }
}
