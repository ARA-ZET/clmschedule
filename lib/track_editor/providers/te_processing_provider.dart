// track_editor/providers/te_processing_provider.dart
//
// Manages the "Processing" mode: picking GPX files, auto-matching
// Track/Waypoints pairs by filename key, and opening matched pairs as tabs.
// On tab creation the track date and distributor are resolved from the schedule
// so that the job's work-map polygons are pre-loaded into each tab.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:gpx/gpx.dart';
import '../models/styled_polygon.dart';
import '../models/te_gpx_file_entry.dart';
import '../models/tab_item.dart';
import '../../models/distributor.dart';
import '../../models/custom_polygon.dart';
import '../../providers/schedule_provider.dart';
import '../../services/gpx_storage_service.dart';
import '../services/point_in_polygon.dart';
import 'te_tabs_provider.dart';

final teProcessingRiverpod =
    riverpod.ChangeNotifierProvider<TEProcessingProvider>(
        (ref) => TEProcessingProvider());

class TEProcessingProvider extends ChangeNotifier {
  // ── State ──────────────────────────────────────────────────────────────────
  final List<TEGpxFileEntry> _files = [];
  List<TEGpxFileEntry> get files => List.unmodifiable(_files);

  /// Set in [dispose]; awaited code must early-out when this is true so we
  /// don't call [notifyListeners] on a disposed notifier.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Notify only when the provider is still alive. Use this everywhere we
  /// call [notifyListeners] inside or after an `await`.
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  bool _loading = false;
  bool get loading => _loading;

  bool _tabsOpened = false;
  bool get tabsOpened => _tabsOpened;

  /// Progress during batch tab opening (0.0 – 1.0).
  double _openProgress = 0;
  double get openProgress => _openProgress;

  bool _openingTabs = false;
  bool get openingTabs => _openingTabs;

  String _progressMessage = '';
  String get progressMessage => _progressMessage;

  // ── Derived ────────────────────────────────────────────────────────────────
  List<TEGpxMatchedPair> get matchedPairs {
    final tracks = <String, TEGpxFileEntry>{};
    final wpts = <String, TEGpxFileEntry>{};

    for (final f in _files) {
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
    return pairs;
  }

  List<TEGpxFileEntry> get unmatchedFiles {
    final matchedKeys = matchedPairs.map((p) => p.matchKey).toSet();
    return _files.where((f) {
      if (f.type == TEGpxFileType.unknown) return true;
      return !matchedKeys.contains(f.matchKey);
    }).toList();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  /// Open a multi-file picker, parse every .gpx file and stage them.
  /// Any previously staged files are cleared before the new pick so that
  /// re-picking never re-opens already-opened tabs.
  Future<void> pickFiles() async {
    _loading = true;
    _tabsOpened = false;
    _files.clear(); // ← always start with a clean slate
    _safeNotify();

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowMultiple: true,
        allowedExtensions: ['gpx'],
        withData: true,
      );
      if (_disposed) return;
      if (result != null) {
        _tabsOpened = false;
        _progressMessage = 'Parsing files...';
        _safeNotify();
        final total = result.files.length;
        for (var i = 0; i < total; i++) {
          if (_disposed) return;
          final pf = result.files[i];
          final bytes = pf.bytes;
          if (bytes == null) continue;
          _progressMessage = 'Parsing ${i + 1} of $total...';
          _safeNotify();
          final entry = await parseGpxFileAsync(pf.name, bytes);
          if (_disposed) return;
          _files.add(entry);
        }
        _progressMessage = '';
      }
    } catch (e) {
      debugPrint('❌ TEProcessingProvider.pickFiles: $e');
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  /// Remove a single staged file.
  void removeFile(TEGpxFileEntry entry) {
    _files.remove(entry);
    notifyListeners();
  }

  /// Remove every staged file whose `matchKey` equals [matchKey].
  /// Called by the tab bar when a processing tab is closed so that the
  /// next "Open all matched" run doesn't re-open the closed tab from
  /// stale staged files.
  void removeFilesForMatchKey(String? matchKey) {
    if (matchKey == null || matchKey.isEmpty) return;
    final before = _files.length;
    _files.removeWhere((f) => f.matchKey == matchKey);
    if (_files.length != before) {
      debugPrint(
          '🧹 removeFilesForMatchKey("$matchKey") removed ${before - _files.length} file(s)');
      notifyListeners();
    }
  }

  /// Clear all staged files.
  void clearFiles() {
    _files.clear();
    _tabsOpened = false;
    notifyListeners();
  }

  /// Create a manual pair from two unmatched files and open it as a tab.
  Future<void> addManualPair(
    TEGpxFileEntry trackEntry,
    TEGpxFileEntry waypointsEntry,
    TETabsProvider tabsProvider,
    ScheduleProvider scheduleProvider,
  ) async {
    _openPairAsTab(
      TEGpxMatchedPair(
        trackFile: trackEntry,
        waypointsFile: waypointsEntry,
        matchKey: '_manual_${trackEntry.filename}',
      ),
      tabsProvider,
      scheduleProvider,
    );
  }

  /// Open a single staged file as its own tab, using whatever tracks and
  /// waypoints are inside the file. Intended for combined GPX files or
  /// for cases where the user accepts an orphaned Track/Waypoints file
  /// without pairing it.
  Future<void> addSingleFileAsTab(
    TEGpxFileEntry entry,
    TETabsProvider tabsProvider,
    ScheduleProvider scheduleProvider,
  ) async {
    // Use the same entry on both sides — `_buildTabForPair` reads
    // `trackFile.tracks` and `waypointsFile.waypoints`, so a combined GPX
    // (or single-type file) will still surface everything it contains.
    final key =
        entry.matchKey.isEmpty ? '_single_${entry.filename}' : entry.matchKey;
    await _openPairAsTab(
      TEGpxMatchedPair(
        trackFile: entry,
        waypointsFile: entry,
        matchKey: key,
      ),
      tabsProvider,
      scheduleProvider,
    );
    if (_disposed) return;
    final removed = _files.remove(entry);
    if (removed) _safeNotify();
  }

  /// Open all auto-matched pairs as new tabs.
  Future<void> openMatchedTabs(
    TETabsProvider tabsProvider,
    ScheduleProvider scheduleProvider,
  ) async {
    final pairs = matchedPairs;
    if (pairs.isEmpty) return;

    _openingTabs = true;
    _openProgress = 0;
    _progressMessage = 'Preparing tabs...';
    _safeNotify();

    final newTabs = <TETabItem>[];
    try {
      for (var i = 0; i < pairs.length; i++) {
        if (_disposed) return;
        _openProgress = (i + 1) / pairs.length;
        _progressMessage = 'Loading ${i + 1} of ${pairs.length}...';
        _safeNotify();
        try {
          final tab = await _buildTabForPair(pairs[i], scheduleProvider);
          if (_disposed) return;
          newTabs.add(tab);
        } catch (e) {
          debugPrint('⚠️ Failed to build tab for "${pairs[i].matchKey}": $e');
        }
      }

      if (newTabs.isNotEmpty && !_disposed) {
        tabsProvider.addTabsBatch(newTabs);
        // Remove the files that were just opened so they are not re-opened
        // if the user picks additional files without closing the editor.
        for (final pair in pairs) {
          _files.removeWhere((f) => f.matchKey == pair.matchKey);
        }
      }
    } finally {
      _openingTabs = false;
      _openProgress = 0;
      _progressMessage = '';
      _tabsOpened = true;
      _safeNotify();
    }
  }

  Future<void> _openPairAsTab(
    TEGpxMatchedPair pair,
    TETabsProvider tabsProvider,
    ScheduleProvider scheduleProvider,
  ) async {
    final tab = await _buildTabForPair(pair, scheduleProvider);
    tabsProvider.addTab(tab);
    tabsProvider.selectTab(tabsProvider.tabs.length - 1);
  }

  /// Re-fetch schedule data for every currently open tab in the
  /// processing mode and refresh its work-map polygons + drop-off points.
  ///
  /// Tabs without a resolved distributor/date (manual or single-file
  /// loads) are skipped. Local edits to the polygon list are replaced
  /// — call this only when the user explicitly clicks "Refresh".
  Future<int> refreshOpenTabs(
    TETabsProvider tabsProvider,
    ScheduleProvider scheduleProvider,
  ) async {
    final tabs = tabsProvider.tabs;
    int refreshed = 0;
    _openingTabs = true;
    _openProgress = 0;
    _progressMessage = 'Refreshing tabs...';
    _safeNotify();

    try {
      for (var i = 0; i < tabs.length; i++) {
        if (_disposed) return refreshed;
        _openProgress = (i + 1) / tabs.length;
        _progressMessage = 'Refreshing ${i + 1} of ${tabs.length}...';
        _safeNotify();

        final ok = await _refreshTabAt(i, tabsProvider, scheduleProvider);
        if (_disposed) return refreshed;
        if (ok) refreshed++;
      }
    } finally {
      _openingTabs = false;
      _openProgress = 0;
      _progressMessage = '';
      _safeNotify();
    }
    return refreshed;
  }

  /// Re-fetch schedule data for a single tab by index. Returns `true`
  /// when the tab had a resolved distributor/date and the refresh
  /// completed (work-map polygons + drop-off points were replaced).
  Future<bool> refreshTab(
    int index,
    TETabsProvider tabsProvider,
    ScheduleProvider scheduleProvider,
  ) async {
    if (index < 0 || index >= tabsProvider.tabs.length) return false;
    _openingTabs = true;
    _openProgress = 1.0;
    _progressMessage = 'Refreshing tab...';
    _safeNotify();
    try {
      return await _refreshTabAt(index, tabsProvider, scheduleProvider);
    } finally {
      _openingTabs = false;
      _openProgress = 0;
      _progressMessage = '';
      notifyListeners();
    }
  }

  Future<bool> _refreshTabAt(
    int i,
    TETabsProvider tabsProvider,
    ScheduleProvider scheduleProvider,
  ) async {
    final tabs = tabsProvider.tabs;
    if (i < 0 || i >= tabs.length) return false;
    final tab = tabs[i];
    final dId = tab.distributorId;
    final tDate = tab.trackDate;
    if (dId == null || tDate == null) return false;

    try {
      final jobs =
          await scheduleProvider.fetchJobsForDistributorAndDate(dId, tDate);
      final newPolys = <TEStyledPolygon>[];
      final newDrops = <TEDropOffPoint>[];
      final newJobIds = <String>[];
      for (final job in jobs) {
        newJobIds.add(job.id);
        for (final wm in job.workMaps) {
          newPolys.add(_customPolygonToStyled(wm));
        }
        if (job.dropOffPoint != null) {
          final clientLabel = job.clients.isNotEmpty ? job.clients.first : '';
          newDrops.add(TEDropOffPoint(
            label:
                clientLabel.isNotEmpty ? 'Drop-off · $clientLabel' : 'Drop-off',
            position: job.dropOffPoint!,
            jobId: job.id,
          ));
        }
      }
      tabsProvider.replacePolygons(i, newPolys);
      tabsProvider.replaceTabMeta(
        i,
        jobIds: newJobIds,
        dropOffPoints: newDrops,
      );
      return true;
    } catch (e) {
      debugPrint('⚠️ refreshTab: tab "${tab.title}" failed: $e');
      return false;
    }
  }

  /// Build a [TETabItem] from a matched pair, resolving schedule data.
  Future<TETabItem> _buildTabForPair(
    TEGpxMatchedPair pair,
    ScheduleProvider scheduleProvider,
  ) async {
    debugPrint('──────────────────────────────────────────');
    debugPrint('📂 Building tab for pair: "${pair.matchKey}"');

    final trackDate = _extractTrackDate(pair.trackFile.tracks) ??
        _extractDateFromText(pair.matchKey) ??
        _extractDateFromText(pair.trackFile.filename);
    final distributor =
        _matchDistributor(pair.matchKey, scheduleProvider.distributors);

    final workMapPolygons = <TEStyledPolygon>[];
    final dropOffs = <TEDropOffPoint>[];
    final jobIds = <String>[];
    String? storageFolderPath;
    if (trackDate != null && distributor != null) {
      debugPrint(
          '🔄 Fetching jobs for ${distributor.name} on ${trackDate.toLocal().toString().substring(0, 10)}...');
      final jobs = await scheduleProvider.fetchJobsForDistributorAndDate(
        distributor.id,
        trackDate,
      );
      for (final job in jobs) {
        jobIds.add(job.id);
        for (final wm in job.workMaps) {
          workMapPolygons.add(_customPolygonToStyled(wm));
        }
        if (job.dropOffPoint != null) {
          final clientLabel = job.clients.isNotEmpty ? job.clients.first : '';
          dropOffs.add(TEDropOffPoint(
            label:
                clientLabel.isNotEmpty ? 'Drop-off · $clientLabel' : 'Drop-off',
            position: job.dropOffPoint!,
            jobId: job.id,
          ));
        }
      }
      // Resolve storage folder path from the first matched job's client.
      // We only set this when the client folder already exists in the cloud
      // \u2014 we never auto-create Round N folders here. If the folder is
      // missing, leave `storageFolderPath` null and let the UI prompt the
      // user to pick or create one via the save panel.
      if (jobs.isNotEmpty && jobs.first.clients.isNotEmpty) {
        try {
          final gpxStorage = GpxStorageService();
          final primaryClient = jobs.first.clients.first;
          final exists =
              await gpxStorage.clientFolderExists(trackDate, primaryClient);
          if (exists) {
            storageFolderPath =
                gpxStorage.clientFolderPath(trackDate, primaryClient);
            debugPrint('☁️ Storage folder: $storageFolderPath');
          } else {
            debugPrint(
                '☁️ No existing cloud folder for "$primaryClient" — user will pick one.');
          }
        } catch (e) {
          debugPrint('⚠️ Could not resolve storage folder: $e');
        }
      }
    }
    debugPrint('🗺  Work-map polygons loaded: ${workMapPolygons.length}');

    final tab = TETabItem(
      title: pair.tabTitle,
      polygons: workMapPolygons,
      tracks: [...pair.trackFile.tracks],
      waypoints: [...pair.waypointsFile.waypoints],
      targetPolygons: [],
      dropOffPoints: dropOffs,
      storageFolderPath: storageFolderPath,
      matchKey: pair.matchKey,
      distributorId: distributor?.id,
      trackDate: trackDate,
      jobIds: jobIds,
    );
    debugPrint(
        '✅ Tab "${pair.tabTitle}" — tracks: ${tab.tracks.length}, wpts: ${tab.waypoints.length}, polys: ${tab.polygons.length}');
    debugPrint('──────────────────────────────────────────');
    return tab;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Extract the local date from the first timestamped point in [tracks].
  static DateTime? _extractTrackDate(List<Trk> tracks) {
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
  static DateTime? _extractDateFromText(String text) {
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

  static DateTime? _checkedDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }

  static int? _monthNumber(String raw) {
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
  static Distributor? _matchDistributor(
    String matchKey,
    List<Distributor> distributors,
  ) {
    if (distributors.isEmpty) return null;
    final keyTokens = matchKey
        .toLowerCase()
        .split(RegExp(r'[\s_\-]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    debugPrint('🔍 Matching key tokens: $keyTokens');

    Distributor? best;
    int bestScore = 0;

    for (final d in distributors) {
      final nameTokens = d.name
          .toLowerCase()
          .split(RegExp(r'[\s_\-]+'))
          .where((t) => t.isNotEmpty)
          .toSet();
      final score = keyTokens.intersection(nameTokens).length;
      debugPrint('   "${d.name}" tokens=$nameTokens → score=$score');
      if (score > bestScore) {
        bestScore = score;
        best = d;
      }
    }
    return best;
  }

  /// Convert a [CustomPolygon] (from a job's workMaps) to a [TEStyledPolygon].
  static TEStyledPolygon _customPolygonToStyled(CustomPolygon cp) {
    return TEStyledPolygon(
      id: 'workmap_${cp.name.hashCode}_${cp.points.hashCode}',
      name: cp.name,
      points: cp.points,
      style: TEKmlStyle(
        strokeColor: cp.color,
        strokeWidth: 2.5,
        fillColor: cp.color.withValues(alpha: 0.2),
        fill: true,
        outline: true,
      ),
    );
  }
}
