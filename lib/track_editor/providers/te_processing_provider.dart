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
  Future<void> pickFiles() async {
    _loading = true;
    notifyListeners();

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowMultiple: true,
        allowedExtensions: ['gpx'],
        withData: true,
      );
      if (result != null) {
        _tabsOpened = false;
        _progressMessage = 'Parsing files...';
        notifyListeners();
        final total = result.files.length;
        for (var i = 0; i < total; i++) {
          final pf = result.files[i];
          final bytes = pf.bytes;
          if (bytes == null) continue;
          _progressMessage = 'Parsing ${i + 1} of $total...';
          notifyListeners();
          final entry = await parseGpxFileAsync(pf.name, bytes);
          _files.add(entry);
        }
        _progressMessage = '';
      }
    } catch (e) {
      debugPrint('❌ TEProcessingProvider.pickFiles: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Remove a single staged file.
  void removeFile(TEGpxFileEntry entry) {
    _files.remove(entry);
    notifyListeners();
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
    notifyListeners();

    final newTabs = <TETabItem>[];
    try {
      for (var i = 0; i < pairs.length; i++) {
        _openProgress = (i + 1) / pairs.length;
        _progressMessage = 'Loading ${i + 1} of ${pairs.length}...';
        notifyListeners();
        try {
          final tab = await _buildTabForPair(pairs[i], scheduleProvider);
          newTabs.add(tab);
        } catch (e) {
          debugPrint('⚠️ Failed to build tab for "${pairs[i].matchKey}": $e');
        }
      }

      if (newTabs.isNotEmpty) {
        tabsProvider.addTabsBatch(newTabs);
      }
    } finally {
      _openingTabs = false;
      _openProgress = 0;
      _progressMessage = '';
      _tabsOpened = true;
      notifyListeners();
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

  /// Build a [TETabItem] from a matched pair, resolving schedule data.
  Future<TETabItem> _buildTabForPair(
    TEGpxMatchedPair pair,
    ScheduleProvider scheduleProvider,
  ) async {
    debugPrint('──────────────────────────────────────────');
    debugPrint('📂 Building tab for pair: "${pair.matchKey}"');

    final trackDate = _extractTrackDate(pair.trackFile.tracks);
    final distributor =
        _matchDistributor(pair.matchKey, scheduleProvider.distributors);

    final workMapPolygons = <TEStyledPolygon>[];
    String? storageFolderPath;
    if (trackDate != null && distributor != null) {
      debugPrint(
          '🔄 Fetching jobs for ${distributor.name} on ${trackDate.toLocal().toString().substring(0, 10)}...');
      final jobs = await scheduleProvider.fetchJobsForDistributorAndDate(
        distributor.id,
        trackDate,
      );
      for (final job in jobs) {
        for (final wm in job.workMaps) {
          workMapPolygons.add(_customPolygonToStyled(wm));
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
      storageFolderPath: storageFolderPath,
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
