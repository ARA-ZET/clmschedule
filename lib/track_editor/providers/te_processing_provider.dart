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
import '../models/styled_polygon.dart';
import '../models/te_gpx_file_entry.dart';
import '../models/tab_item.dart';
import '../../models/custom_polygon.dart';
import '../../providers/schedule_provider.dart';
import '../../services/gpx_storage_service.dart';
import '../services/point_in_polygon.dart';
import '../services/te_gpx_matching.dart';
import '../services/te_track_clients.dart';
import '../utils/te_track_gaps.dart';
import '../../models/job_list_item.dart';
import '../../providers/job_list_provider.dart';
import '../../providers/job_type_provider.dart';
import 'te_tabs_provider.dart';

final teProcessingRiverpod =
    riverpod.ChangeNotifierProvider<TEProcessingProvider>(
        (ref) => TEProcessingProvider(
              jobListItems: () => loadedJobListItems(ref.read(jobListRiverpod)),
            ));

class TEProcessingProvider extends ChangeNotifier {
  TEProcessingProvider({this.jobListItems});

  /// The Job List held in memory, used to tell distribution clients from
  /// collection / cleaning work. Null in tests: nothing is hidden then.
  final Future<List<JobListItem>> Function()? jobListItems;

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

  /// Distance, in metres, that newly opened tabs have their tracks split at.
  /// The Tracks panel writes the tab's chosen distance back here, so once the
  /// user has found the right number for a day's driving rounds the rest of
  /// the batch opens the same way.
  double _gapSplitM = kTrackGapSplitM;
  double get gapSplitM => _gapSplitM;

  void setDefaultGapSplit(double meters) {
    final clamped =
        meters.clamp(kTrackGapSplitMinM, kTrackGapSplitMaxM).toDouble();
    if (clamped == _gapSplitM) return;
    _gapSplitM = clamped;
    _safeNotify();
  }

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

  /// Unmatched files that already carry BOTH tracks and waypoints inside a
  /// single file (the new combined Track-file export). These have no pair,
  /// but they are complete on their own, so they can be opened automatically
  /// as-is without asking the user to confirm.
  List<TEGpxFileEntry> get selfContainedFiles => unmatchedFiles
      .where((f) => f.tracks.isNotEmpty && f.waypoints.isNotEmpty)
      .toList();

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

  /// Auto-open every unmatched file that already contains both tracks and
  /// waypoints (the new combined Track-file format) as its own tab, without
  /// asking the user to confirm. Each opened file is removed from the staged
  /// list. Returns the number of tabs opened.
  Future<int> openSelfContainedTabs(
    TETabsProvider tabsProvider,
    ScheduleProvider scheduleProvider,
  ) async {
    final files = selfContainedFiles;
    if (files.isEmpty) return 0;

    _openingTabs = true;
    _openProgress = 0;
    _progressMessage = 'Opening combined files...';
    _safeNotify();

    final newTabs = <TETabItem>[];
    final opened = <TEGpxFileEntry>[];
    try {
      for (var i = 0; i < files.length; i++) {
        if (_disposed) return opened.length;
        _openProgress = (i + 1) / files.length;
        _progressMessage = 'Loading ${i + 1} of ${files.length}...';
        _safeNotify();
        final entry = files[i];
        // A combined file is its own track AND waypoints source.
        final key = entry.matchKey.isEmpty
            ? '_single_${entry.filename}'
            : entry.matchKey;
        try {
          final tab = await _buildTabForPair(
            TEGpxMatchedPair(
              trackFile: entry,
              waypointsFile: entry,
              matchKey: key,
            ),
            scheduleProvider,
          );
          if (_disposed) return opened.length;
          newTabs.add(tab);
          opened.add(entry);
        } catch (e) {
          debugPrint('⚠️ Failed to open combined file "${entry.filename}": $e');
        }
      }

      if (newTabs.isNotEmpty && !_disposed) {
        tabsProvider.addTabsBatch(newTabs);
        for (final entry in opened) {
          _files.remove(entry);
        }
      }
    } finally {
      _openingTabs = false;
      _openProgress = 0;
      _progressMessage = '';
      _tabsOpened = true;
      _safeNotify();
    }
    return opened.length;
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
        // Only real areas — a job's map points and lines aren't areas and
        // would clutter the list and the saved file name.
        for (final wm in job.workMaps.where((wm) => wm.isPolygon)) {
          newPolys.add(customPolygonToStyled(wm));
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

    final trackDate = resolveDate(
        pair.trackFile.tracks, pair.matchKey, pair.trackFile.filename);
    final distributor =
        matchDistributor(pair.matchKey, scheduleProvider.distributors);

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
        // Only real areas — a job's map points and lines aren't areas and
        // would clutter the list and the saved file name.
        for (final wm in job.workMaps.where((wm) => wm.isPolygon)) {
          workMapPolygons.add(customPolygonToStyled(wm));
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
      // The primary client is the first one whose work records waypoints —
      // a collection or window-cleaning job has no track folder to point at.
      var hidden = const <String>{};
      try {
        hidden = findClientsWithoutTracks(
          clients: jobs.expand((j) => j.clients),
          jobListItems: await jobListItems?.call() ?? const [],
          jobTypes: JobTypeProvider.instance?.jobTypes ?? const [],
        );
      } catch (e) {
        debugPrint('⚠️ Could not check client job types: $e');
      }
      final primaryClient = jobs
          .expand((j) => j.clients)
          .where((c) => c.isNotEmpty && !hidden.contains(c))
          .firstOrNull;
      if (primaryClient != null) {
        try {
          final gpxStorage = GpxStorageService();
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

    // GPS spikes and signal drops would otherwise draw as long straight
    // lines across town. The unsplit tracks are kept on the tab so the user
    // can re-cut them at a different distance — a driven round leaves wide
    // steps between points that the default 50 m chops into scraps.
    final sourceTracks = [...pair.trackFile.tracks];
    final tab = TETabItem(
      title: pair.tabTitle,
      polygons: workMapPolygons,
      tracks: splitTracksAtGapsDetached(sourceTracks, _gapSplitM),
      sourceTracks: sourceTracks,
      gapSplitM: _gapSplitM,
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
  // Date/distributor matching itself lives in te_gpx_matching.dart, shared
  // with the client Report feature so a file matches the same way in both.

  /// Convert a [CustomPolygon] (from a job's workMaps) to a [TEStyledPolygon].
  static TEStyledPolygon customPolygonToStyled(CustomPolygon cp) {
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
