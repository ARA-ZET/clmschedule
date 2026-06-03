// track_editor/widgets/te_cloud_save_panel.dart
//
// Processing-mode panel for saving tracks & waypoints to client cloud folders.
// Two workflows per client:
//   1. Save As-Is — upload full tracks + waypoints to the client folder.
//   2. Trim & Save — select polygons, trim tracks/waypoints to polygon
//      boundaries, then upload trimmed data to the client folder.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';
import '../../providers/cloud_file_manager_provider.dart';
import '../../providers/job_list_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../services/gpx_storage_service.dart';
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';
import '../providers/te_cloud_save_state_provider.dart';
import '../providers/te_processing_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../../shareable_maps/providers/map_gesture_provider.dart';
import '../services/file_manager.dart';
import '../services/point_in_polygon.dart';

/// A panel that lists clients derived from the active tab's schedule jobs,
/// allowing the user to save or trim-and-save GPX data to their cloud folders.
class TECloudSavePanel extends riverpod.ConsumerStatefulWidget {
  const TECloudSavePanel({super.key});

  @override
  riverpod.ConsumerState<TECloudSavePanel> createState() =>
      _TECloudSavePanelState();
}

class _TECloudSavePanelState extends riverpod.ConsumerState<TECloudSavePanel> {
  TETabItem get _tab {
    final tabs = ref.read(teTabsRiverpod);
    return tabs.tabs[tabs.currentTab];
  }

  @override
  Widget build(BuildContext context) {
    final tabsProvider = ref.watch(teTabsRiverpod);
    final saveState = ref.watch(teCloudSaveRiverpod);
    final currentIndex = tabsProvider.currentTab;
    final tab = tabsProvider.tabs[currentIndex];

    final hasTracks = tab.tracks.isNotEmpty;
    final hasWaypoints = tab.waypoints.isNotEmpty;

    if (!hasTracks && !hasWaypoints) return const SizedBox.shrink();

    // Kick off client resolution the first time this tab is shown.
    if (!saveState.isResolved(tab) && !saveState.isLoading(tab)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveClients(tab);
      });
    }

    final clients = saveState.clientsFor(tab);
    final loading = saveState.isLoading(tab);
    final error = saveState.errorFor(tab);

    return Container(
      width: 420,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_upload, color: Colors.blue, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Save to Cloud',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: 'Match distributor',
                padding: EdgeInsets.zero,
                icon: Icon(
                  Icons.person,
                  size: 20,
                  color:
                      tab.distributorId != null ? Colors.green : Colors.black87,
                ),
                onSelected: (distributorId) async {
                  final tabsProvider = ref.read(teTabsRiverpod);
                  tabsProvider.replaceTabMeta(currentIndex,
                      distributorId: distributorId);
                  final updatedTab = tabsProvider.tabs[currentIndex];
                  if (updatedTab.trackDate != null) {
                    final proc = ref.read(teProcessingRiverpod);
                    await proc.refreshTab(
                        currentIndex, tabsProvider, ref.read(scheduleRiverpod));
                  }
                  // Force a fresh resolve for the updated tab.
                  ref.read(teCloudSaveRiverpod).clearTab(tab);
                  if (mounted) _resolveClients(tabsProvider.tabs[currentIndex]);
                },
                itemBuilder: (context) => ref
                    .read(scheduleRiverpod)
                    .distributors
                    .map((d) => PopupMenuItem<String>(
                          value: d.id,
                          child: Text(d.name),
                        ))
                    .toList(),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh clients',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: loading ? null : () => _resolveClients(tab),
              ),
            ],
          ),
          const Divider(height: 16),
          if (loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Column(
                  spacing: 8,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    Text('Resolving clients...',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            )
          else if (error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                spacing: 8,
                children: [
                  Icon(Icons.warning_amber,
                      color: Colors.orange.shade700, size: 18),
                  Expanded(
                    child: Text(error,
                        style: TextStyle(
                            fontSize: 12, color: Colors.orange.shade800)),
                  ),
                  IconButton(
                    onPressed: () => _resolveClients(tab),
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: 'Retry',
                  ),
                ],
              ),
            )
          else ...[
            if (clients.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('No clients found.',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              )
            else
              ...clients.map((entry) => _ClientTile(
                    entry: entry,
                    tab: tab,
                    tracks: tab.tracks,
                    waypoints: tab.waypoints,
                    clientSuggestionsBuilder: _joblistClientSuggestions,
                  )),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _addClient(tab),
                icon: const Icon(Icons.person_add_alt_1, size: 16),
                label: const Text('Add Client'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blueGrey.shade700,
                  side: BorderSide(color: Colors.blueGrey.shade300),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Open the folder picker to add a client manually.
  Future<void> _addClient(TETabItem tab) async {
    final date = _extractDate() ?? DateTime.now();
    final year = date.year.toString();
    final monthLabel = DateFormat('MMM yyyy').format(date);
    final monthPath = 'Distribution/$year/$monthLabel';

    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _FolderPickerDialog(
        initialPath: monthPath,
        clientSuggestions: _joblistClientSuggestions(),
        mapGestureProvider: ref.read(mapGestureRiverpod),
      ),
    );
    if (picked == null || !mounted) return;

    final segments = picked.split('/').where((s) => s.isNotEmpty).toList();
    final clientName = segments.length >= 4 ? segments[3] : segments.last;

    final saveState = ref.read(teCloudSaveRiverpod);
    final existing = saveState.clientsFor(tab);
    if (existing
        .any((c) => c.clientName == clientName && c.folderPath == picked)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$clientName already in list'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final distributorName = existing.isNotEmpty
        ? existing.first.distributorName
        : _matchDistributor(ref.read(scheduleRiverpod))?.name ?? '';

    saveState.addClient(
      tab,
      TECloudSaveClientEntry(
        clientName: clientName,
        distributorName: distributorName,
        date: date,
        polygons: const [],
        folderPath: picked,
        folderExists: true,
      ),
    );
  }

  /// Extract the linked schedule date, falling back to the first timestamped
  /// track point for older tabs that do not carry processing metadata.
  DateTime? _extractDate() {
    if (_tab.trackDate != null) return _tab.trackDate!.toLocal();
    for (final trk in _tab.tracks) {
      for (final seg in trk.trksegs) {
        for (final pt in seg.trkpts) {
          if (pt.time != null) return pt.time!.toLocal();
        }
      }
    }
    return null;
  }

  /// Returns a de-duplicated list of client names drawn from the current
  /// joblist, to surface as suggestions when creating a client-level folder.
  List<String> _joblistClientSuggestions() {
    final seen = <String>{};
    final result = <String>[];
    try {
      final items = ref.read(jobListRiverpod).jobListItems;
      for (final item in items) {
        final name = item.client.trim();
        if (name.isEmpty) continue;
        if (seen.add(name.toLowerCase())) result.add(name);
      }
    } catch (_) {
      // Joblist not ready — silently fall back to no extra suggestions.
    }
    // Also include clients already resolved for this panel, in case the
    // joblist doesn't cover them yet.
    for (final c in ref.read(teCloudSaveRiverpod).clientsFor(_tab)) {
      final name = c.clientName.trim();
      if (name.isEmpty) continue;
      if (seen.add(name.toLowerCase())) result.add(name);
    }
    return result;
  }

  /// Resolve the linked distributor, falling back to filename/title matching.
  /// Returns (id, name) or null.
  ({String id, String name})? _matchDistributor(ScheduleProvider schedule) {
    if (schedule.distributors.isEmpty) return null;
    final linkedDistributorId = _tab.distributorId;
    if (linkedDistributorId != null && linkedDistributorId.isNotEmpty) {
      final linked = schedule.distributors
          .where((d) => d.id == linkedDistributorId)
          .firstOrNull;
      if (linked != null) return (id: linked.id, name: linked.name);
    }

    final keySource = _tab.matchKey?.isNotEmpty == true
        ? _tab.matchKey!
        : _tab.title
            .replaceAll(RegExp(r'\.(gpx|kml|kmz)$', caseSensitive: false), '');
    final keyTokens = keySource
        .toLowerCase()
        .split(RegExp(r'[\s_\-]+'))
        .where((t) => t.isNotEmpty)
        .toSet();

    String? bestId;
    String? bestName;
    int bestScore = 0;
    for (final d in schedule.distributors) {
      final nameTokens = d.name
          .toLowerCase()
          .split(RegExp(r'[\s_\-]+'))
          .where((t) => t.isNotEmpty)
          .toSet();
      final score = keyTokens.intersection(nameTokens).length;
      if (score > bestScore) {
        bestScore = score;
        bestId = d.id;
        bestName = d.name;
      }
    }
    if (bestId == null || bestName == null) return null;
    return (id: bestId, name: bestName);
  }

  Future<void> _resolveClients(TETabItem tab) async {
    final saveState = ref.read(teCloudSaveRiverpod);
    saveState.beginResolve(tab);

    try {
      final schedule = ref.read(scheduleRiverpod);
      final date = _extractDate();
      final match = _matchDistributor(schedule);

      if (date == null || match == null) {
        saveState.finishResolveError(
          tab,
          date == null
              ? 'No timestamp found in tracks'
              : 'Could not match distributor',
        );
        return;
      }

      final jobs =
          await schedule.fetchJobsForDistributorAndDate(match.id, date);
      if (jobs.isEmpty) {
        saveState.finishResolveError(
            tab, 'No jobs found for this date & distributor');
        return;
      }

      final gpxStorage = GpxStorageService();
      final seen = <String>{};
      final entries = <TECloudSaveClientEntry>[];

      final year = date.year.toString();
      final monthLabel = DateFormat('MMM yyyy').format(date);
      final monthPath = 'Distribution/$year/$monthLabel';

      for (final job in jobs) {
        for (final client in job.clients) {
          if (client.isEmpty || !seen.add(client)) continue;

          final clientFolderExists =
              await gpxStorage.clientFolderExists(date, client);
          final folderPath = clientFolderExists
              ? gpxStorage.clientFolderPath(date, client)
              : monthPath;

          final polys = <TEStyledPolygon>[];
          for (final j in jobs) {
            if (j.clients.contains(client)) {
              for (final wm in j.workMaps) {
                polys.add(TEStyledPolygon(
                  id: 'wm_${wm.name.hashCode}_${wm.points.hashCode}',
                  name: wm.name,
                  points: wm.points,
                  style: TEKmlStyle(
                    strokeColor: wm.color,
                    strokeWidth: wm.strokeWidth.toDouble(),
                    fillColor:
                        wm.color.withAlpha((wm.fillOpacity * 255).round()),
                    fill: true,
                    outline: true,
                  ),
                ));
              }
            }
          }

          entries.add(TECloudSaveClientEntry(
            clientName: client,
            distributorName: match.name,
            date: date,
            polygons: polys,
            folderPath: folderPath,
            folderExists: clientFolderExists,
          ));
        }
      }

      saveState.finishResolveSuccess(tab, entries);
    } catch (e) {
      saveState.finishResolveError(tab, 'Error: $e');
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// CLIENT TILE — one per client with "Save As-Is" and "Trim & Save" sections
// ═══════════════════════════════════════════════════════════════════════════════

class _ClientTile extends riverpod.ConsumerStatefulWidget {
  final TECloudSaveClientEntry entry;
  final TETabItem tab;
  final List<Trk> tracks;
  final List<Wpt> waypoints;
  final List<String> Function()? clientSuggestionsBuilder;

  const _ClientTile({
    required this.entry,
    required this.tab,
    required this.tracks,
    required this.waypoints,
    this.clientSuggestionsBuilder,
  });

  @override
  riverpod.ConsumerState<_ClientTile> createState() => _ClientTileState();
}

class _ClientTileState extends riverpod.ConsumerState<_ClientTile> {
  bool _saving = false;
  bool _trimming = false;
  // All save-state (savedAsIs, trimmedSaved, expanded, selectedPolyIndices,
  // folderPath, folderExists) is held in TECloudSaveStateProvider so it
  // persists when the user switches tabs and returns.

  String get _dateStr => DateFormat('dd MMM yyyy').format(widget.entry.date);
  String get _folderPath => widget.entry.folderPath;
  bool get _folderExists => widget.entry.folderExists;

  /// Extract round number from folder path (e.g. ".../Round 3" → 3).
  int? get _roundNumber {
    final match = RegExp(r'Round (\d+)$').firstMatch(_folderPath);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }

  /// Polygon/work-area names joined with 3 spaces.
  String get _polyNames {
    final names = widget.entry.polygons
        .map((p) => p.name.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();
    return names.join('   ');
  }

  /// Polygon/work-area names for the currently selected polygons only.
  String get _selectedPolyNames {
    final names = widget.entry.selectedPolyIndices
        .map((i) => widget.entry.polygons[i].name.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();
    return names.join('   ');
  }

  /// Build filename: Track   DD MMM YYYY   Distributor   Client   [WorkAreas   ]WptCount fulltrack.gpx
  String _fileName(int wptCount,
      {String type = 'Track', String? polyNamesOverride}) {
    final parts = <String>[
      if (type.isNotEmpty) type,
      _dateStr,
      widget.entry.distributorName,
      widget.entry.clientName,
    ];
    final polyNames = polyNamesOverride ?? _polyNames;
    if (polyNames.isNotEmpty) parts.add(polyNames);
    parts.add(wptCount.toString());
    return GpxStorageService.sanitizeFileName(
        '${parts.join('   ')} fulltrack.gpx');
  }

  // ── Save As-Is ──────────────────────────────────────────────────────────

  Future<void> _saveAsIs() async {
    if (!await _ensureFolderPicked()) return;
    setState(() => _saving = true);
    try {
      final gpxStorage = GpxStorageService();
      final fm = TEFileManager();
      final wptCount = widget.waypoints.length;

      final existing = await gpxStorage.listFolderContents(_folderPath);
      final existingNames = existing.files.map((f) => f.name).toSet();

      int uploaded = 0;
      int skipped = 0;

      if (widget.tracks.isNotEmpty || widget.waypoints.isNotEmpty) {
        // Prefer selected-polygon names if the user has highlighted any;
        // otherwise fall back to all entry polygon names.
        final areaOverride =
            _selectedPolyNames.isNotEmpty ? _selectedPolyNames : null;
        final gpxFile = _fileName(wptCount, polyNamesOverride: areaOverride);
        if (existingNames.contains(gpxFile)) {
          skipped++;
        } else {
          final gpxContent =
              await fm.toGpxCombinedString(widget.tracks, widget.waypoints);
          await gpxStorage.uploadGpxFile(_folderPath, gpxFile, gpxContent);
          uploaded++;
        }
      }

      if (mounted) {
        final msg = skipped > 0 && uploaded == 0
            ? 'Already saved to ${widget.entry.clientName}'
            : '$uploaded uploaded, $skipped already existed';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor:
                skipped > 0 && uploaded == 0 ? Colors.orange : Colors.green,
          ),
        );
        ref.read(teCloudSaveRiverpod).markSavedAsIs(widget.entry, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Upload failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  // ── Trim & Save ─────────────────────────────────────────────────────────

  Future<void> _trimAndSave() async {
    if (widget.entry.selectedPolyIndices.isEmpty) return;
    if (!await _ensureFolderPicked()) return;
    setState(() => _trimming = true);
    try {
      // Build a name→points lookup from the current tab polygons so that
      // any vertex edits the user made are used for trimming rather than
      // the original points fetched from the schedule.
      final tabPolyByName = <String, List<LatLng>>{
        for (final tp in widget.tab.polygons)
          if (tp.name.isNotEmpty) tp.name: tp.points,
      };
      final selectedPolys = widget.entry.selectedPolyIndices.map((i) {
        final orig = widget.entry.polygons[i];
        final editedPoints = tabPolyByName[orig.name];
        return editedPoints != null
            ? orig.copyWith(points: editedPoints)
            : orig;
      }).toList();

      final trimmedTracks = trimTracksToPolygons(widget.tracks, selectedPolys);
      final trimmedWpts =
          filterWaypointsByPolygons(widget.waypoints, selectedPolys);

      if (trimmedTracks.isEmpty && trimmedWpts.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No data inside selected polygons'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        if (mounted) setState(() => _trimming = false);
        return;
      }

      final gpxStorage = GpxStorageService();
      final fm = TEFileManager();
      final trimmedWptCount = trimmedWpts.length;

      // Check existing files to avoid duplicates.
      final existing = await gpxStorage.listFolderContents(_folderPath);
      final existingNames = existing.files.map((f) => f.name).toSet();

      int uploaded = 0;
      int skipped = 0;

      if (trimmedTracks.isNotEmpty || trimmedWpts.isNotEmpty) {
        final gpxFile = _fileName(trimmedWptCount,
            type: 'Track Trimmed', polyNamesOverride: _selectedPolyNames);
        if (existingNames.contains(gpxFile)) {
          skipped++;
        } else {
          final gpxContent =
              await fm.toGpxCombinedString(trimmedTracks, trimmedWpts);
          await gpxStorage.uploadGpxFile(_folderPath, gpxFile, gpxContent);
          uploaded++;
        }
      }

      if (mounted) {
        final msg = skipped > 0 && uploaded == 0
            ? 'Already saved to ${widget.entry.clientName}'
            : 'Trimmed: $trimmedWptCount wpts → $uploaded uploaded, $skipped already existed';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: skipped > 0 && uploaded == 0
                ? Colors.orange
                : Colors.deepOrange,
          ),
        );
        ref.read(teCloudSaveRiverpod).markTrimmedSaved(widget.entry, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Trim failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _trimming = false);
  }

  // ── Change Folder ───────────────────────────────────────────────────────

  Future<void> _changeFolder() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _FolderPickerDialog(
        initialPath: _folderPath,
        clientName: widget.entry.clientName,
        clientSuggestions: widget.clientSuggestionsBuilder?.call() ?? const [],
        mapGestureProvider: ref.read(mapGestureRiverpod),
      ),
    );
    if (picked != null && picked != _folderPath && mounted) {
      ref
          .read(teCloudSaveRiverpod)
          .setFolder(widget.entry, picked, exists: true);
    }
  }

  /// Ensures a concrete client/round folder is selected before uploading.
  /// Returns `false` if the user still has no valid target (they either
  /// cancelled the picker or left the default month-level fallback in place).
  Future<bool> _ensureFolderPicked() async {
    if (_folderExists) return true;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Choose a cloud folder for "${widget.entry.clientName}" first'),
          backgroundColor: Colors.red,
        ),
      );
    }
    await _changeFolder();
    return _folderExists;
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    ref.watch(teCloudSaveRiverpod); // rebuild when provider notifies
    final hasPolygons = entry.polygons.isNotEmpty;
    final busy = _saving || _trimming;
    final saved = entry.savedAsIs || entry.trimmedSaved;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        // Turn green when anything has been saved to cloud for this client.
        color: saved ? Colors.green.shade50 : Colors.grey.shade50,
        border: Border.all(
          color: saved ? Colors.green.shade300 : Colors.grey.shade300,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Client header ─────────────────────────────────────────────
          InkWell(
            onTap: () => ref
                .read(teCloudSaveRiverpod)
                .setExpanded(entry, !entry.expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.business,
                      size: 18,
                      color: saved
                          ? Colors.green.shade700
                          : _folderExists
                              ? Colors.blueGrey.shade600
                              : Colors.red.shade600),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                entry.clientName,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: saved
                                      ? Colors.green.shade700
                                      : _folderExists
                                          ? null
                                          : Colors.red.shade700,
                                ),
                              ),
                            ),
                            if (saved) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.cloud_done,
                                  size: 14, color: Colors.green.shade600),
                            ],
                            if (!_folderExists && !saved) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.warning_amber,
                                  size: 14, color: Colors.red.shade400),
                            ],
                            if (_roundNumber != null && _roundNumber! > 1) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: Colors.blue.shade300, width: 0.5),
                                ),
                                child: Text(
                                  'Round $_roundNumber',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.blue.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          _folderPath,
                          style: TextStyle(
                            fontSize: 10,
                            color: _folderExists
                                ? Colors.grey.shade600
                                : Colors.red.shade400,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!_folderExists)
                          Text(
                            'No matching cloud folder — select or create one',
                            style: TextStyle(
                                fontSize: 9, color: Colors.red.shade400),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.folder_open,
                        size: 18, color: Colors.blueGrey.shade400),
                    tooltip: 'Change folder',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _changeFolder,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    entry.expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.grey.shade500,
                  ),
                ],
              ),
            ),
          ),

          if (entry.expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Save As-Is ───────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: busy ? null : _saveAsIs,
                      icon: _saving
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Icon(
                              entry.savedAsIs
                                  ? Icons.cloud_done
                                  : Icons.cloud_upload,
                              size: 16,
                            ),
                      label: Text(entry.savedAsIs
                          ? 'Saved — Save Again'
                          : 'Save As-Is'),
                      style: ElevatedButton.styleFrom(
                        // Flip to orange once saved so the user can't
                        // confuse a post-save click with a pending save.
                        backgroundColor: entry.savedAsIs
                            ? Colors.orange.shade700
                            : Colors.blue.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),

                  // ── Trim & Save section ──────────────────────────────
                  if (hasPolygons) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Trim & Save',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.deepOrange.shade700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Select polygons to trim tracks & waypoints:',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 6),
                    // Polygon checkboxes
                    ...List.generate(entry.polygons.length, (i) {
                      final poly = entry.polygons[i];
                      final isSelected = entry.selectedPolyIndices.contains(i);
                      return InkWell(
                        onTap: busy
                            ? null
                            : () => ref
                                .read(teCloudSaveRiverpod)
                                .toggleSelectedPoly(entry, i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: Checkbox(
                                  value: isSelected,
                                  onChanged: busy
                                      ? null
                                      : (_) => ref
                                          .read(teCloudSaveRiverpod)
                                          .toggleSelectedPoly(entry, i),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: poly.style.fillColor.withAlpha(100),
                                  border: Border.all(
                                      color: poly.style.strokeColor, width: 1),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  poly.name.isEmpty
                                      ? 'Polygon ${i + 1}'
                                      : poly.name,
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    // Select all / deselect all
                    Row(
                      children: [
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => ref
                                  .read(teCloudSaveRiverpod)
                                  .setSelectedPolys(
                                    entry,
                                    Set<int>.from(List.generate(
                                        entry.polygons.length, (i) => i)),
                                  ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(fontSize: 11),
                          ),
                          child: const Text('Select All'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => ref
                                  .read(teCloudSaveRiverpod)
                                  .setSelectedPolys(entry, {}),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(fontSize: 11),
                          ),
                          child: const Text('Deselect All'),
                        ),
                        const Spacer(),
                        Text(
                          '${entry.selectedPolyIndices.length} selected',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: (busy || entry.selectedPolyIndices.isEmpty)
                            ? null
                            : _trimAndSave,
                        icon: _trimming
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(
                                entry.trimmedSaved
                                    ? Icons.cloud_done
                                    : Icons.content_cut,
                                size: 16,
                              ),
                        label: Text(entry.trimmedSaved
                            ? 'Saved — Trim & Save Again'
                            : 'Trim & Save to Cloud'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: entry.trimmedSaved
                              ? Colors.orange.shade700
                              : (entry.selectedPolyIndices.isNotEmpty
                                  ? Colors.deepOrange.shade700
                                  : Colors.grey.shade500),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      'No work-map polygons for this client',
                      style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: Colors.grey.shade500),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// FOLDER PICKER DIALOG — browse Cloud Storage folders and select one
// ═══════════════════════════════════════════════════════════════════════════════

class _FolderPickerDialog extends StatefulWidget {
  final String initialPath;
  final String? clientName;
  final List<String> clientSuggestions;
  final MapGestureProvider? mapGestureProvider;
  const _FolderPickerDialog({
    required this.initialPath,
    this.clientName,
    this.clientSuggestions = const [],
    this.mapGestureProvider,
  });

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  final CloudFileManagerProvider _provider = CloudFileManagerProvider();
  bool _creatingFolder = false;

  @override
  void initState() {
    super.initState();
    _provider.addListener(_onChanged);
    _provider.navigateToPath(widget.initialPath);
  }

  @override
  void dispose() {
    _provider.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Show a dialog to create a new folder at the current level.
  Future<void> _showCreateFolderDialog() async {
    final ctrl = TextEditingController();
    // Base suggestions come from the cloud provider (year / month labels /
    // "Round N"), and at the month level we ALSO want to surface client
    // names from the day's joblist so the user can one-tap to create the
    // right client folder.
    final baseSuggestions = _provider.suggestedFolderNames;
    final mergedSuggestions = <String>[];
    final seenLower = <String>{};
    for (final s in baseSuggestions) {
      if (seenLower.add(s.toLowerCase())) mergedSuggestions.add(s);
    }
    if (_provider.currentLevel == FolderLevel.month) {
      final existingLower =
          _provider.folders.map((f) => f.name.toLowerCase()).toSet();
      for (final s in widget.clientSuggestions) {
        final trimmed = s.trim();
        if (trimmed.isEmpty) continue;
        final lower = trimmed.toLowerCase();
        // Don't suggest folders that already exist at this level.
        if (existingLower.contains(lower)) continue;
        if (seenLower.add(lower)) mergedSuggestions.add(trimmed);
      }
    }
    final suggestions = mergedSuggestions;
    final levelLabel = _provider.newFolderLabel;

    final folderName = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final query = ctrl.text.toLowerCase();
          final filtered = suggestions.isEmpty
              ? <String>[]
              : query.isEmpty
                  ? suggestions
                  : suggestions
                      .where((s) => s.toLowerCase().contains(query))
                      .toList();

          return MouseRegion(
            onEnter: (_) => widget.mapGestureProvider?.disableMapGestures(),
            onExit: (_) => widget.mapGestureProvider?.enableMapGestures(),
            child: AlertDialog(
            title: Text('New $levelLabel Folder',
                style: const TextStyle(fontSize: 15)),
            content: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: 360,
                maxWidth: 360,
                minHeight: 120,
                maxHeight: 400,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: '$levelLabel name',
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                      onSubmitted: (v) {
                        if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
                      },
                    ),
                    if (filtered.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text('Suggestions:',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: filtered.map((s) {
                          return ActionChip(
                            label:
                                Text(s, style: const TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.pop(ctx, s),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final name = ctrl.text.trim();
                  if (name.isNotEmpty) Navigator.pop(ctx, name);
                },
                child: const Text('Create'),
              ),
            ],
          ),
          );
        },
      ),
    );

    if (folderName == null || !mounted) return;

    setState(() => _creatingFolder = true);
    final ok = await _provider.createFolder(folderName);
    if (mounted) {
      setState(() => _creatingFolder = false);
      if (ok) {
        // Navigate into the newly created folder.
        final newFolder =
            _provider.folders.where((f) => f.name == folderName).firstOrNull;
        if (newFolder != null) {
          await _provider.openFolder(newFolder);
        }
      }
    }
  }

  /// Whether a folder name is an exact match for the highlight client name.
  bool _isClientMatch(String folderName) {
    if (widget.clientName == null || widget.clientName!.isEmpty) return true;
    return folderName.toLowerCase() == widget.clientName!.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    // Determine if we're at the client level where matching matters.
    final atClientLevel = _provider.currentLevel == FolderLevel.month;
    final hasExactClientMatch = !atClientLevel ||
        widget.clientName == null ||
        widget.clientName!.isEmpty ||
        _provider.folders.any((f) => _isClientMatch(f.name));

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => widget.mapGestureProvider?.disableMapGestures(),
        onExit: (_) => widget.mapGestureProvider?.enableMapGestures(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Title bar ──────────────────────────────────────────────
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade50,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_open, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Choose Folder',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              // ── Breadcrumb ─────────────────────────────────────────────
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: Colors.grey.shade100,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (int i = 0;
                          i < _provider.breadcrumbs.length;
                          i++) ...[
                        if (i > 0)
                          Icon(Icons.chevron_right,
                              size: 16, color: Colors.grey.shade400),
                        InkWell(
                          onTap: () => _provider.goToBreadcrumb(i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Text(
                              _provider.breadcrumbs[i].name,
                              style: TextStyle(
                                fontSize: 11,
                                color: i == _provider.breadcrumbs.length - 1
                                    ? Colors.blueGrey.shade800
                                    : Colors.blue.shade700,
                                fontWeight:
                                    i == _provider.breadcrumbs.length - 1
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const Divider(height: 1),

              // ── No exact client match warning ──────────────────────────
              if (atClientLevel && !hasExactClientMatch)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  color: Colors.red.shade50,
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber,
                          size: 16, color: Colors.red.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'No exact match for "${widget.clientName}". '
                          'Select the right folder or create a new one.',
                          style: TextStyle(
                              fontSize: 11, color: Colors.red.shade700),
                        ),
                      ),
                    ],
                  ),
                ),

              // ── Folder list ────────────────────────────────────────────
              Expanded(
                child: _provider.isLoading || _creatingFolder
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(strokeWidth: 2),
                            if (_creatingFolder) ...[
                              const SizedBox(height: 8),
                              Text('Creating folder...',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600)),
                            ],
                          ],
                        ),
                      )
                    : _provider.error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(_provider.error!,
                                  style: const TextStyle(color: Colors.red)),
                            ),
                          )
                        : _provider.folders.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('No sub-folders',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: Colors.grey.shade500)),
                                    const SizedBox(height: 8),
                                    TextButton.icon(
                                      onPressed: _showCreateFolderDialog,
                                      icon: const Icon(Icons.create_new_folder,
                                          size: 16),
                                      label: Text(
                                          'Create ${_provider.newFolderLabel}'),
                                      style: TextButton.styleFrom(
                                          textStyle:
                                              const TextStyle(fontSize: 12)),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                itemCount: _provider.folders.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final folder = _provider.folders[i];
                                  // Show in red if at client level and name
                                  // doesn't match the expected client.
                                  final mismatch = atClientLevel &&
                                      widget.clientName != null &&
                                      widget.clientName!.isNotEmpty &&
                                      !_isClientMatch(folder.name);
                                  return ListTile(
                                    dense: true,
                                    leading: Icon(
                                      Icons.folder,
                                      color: mismatch
                                          ? Colors.red.shade400
                                          : Colors.amber.shade700,
                                      size: 22,
                                    ),
                                    title: Text(
                                      folder.name,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: mismatch
                                            ? Colors.red.shade700
                                            : null,
                                        fontWeight: (!mismatch &&
                                                atClientLevel &&
                                                _isClientMatch(folder.name) &&
                                                widget.clientName != null &&
                                                widget.clientName!.isNotEmpty)
                                            ? FontWeight.w600
                                            : null,
                                      ),
                                    ),
                                    trailing: const Icon(Icons.chevron_right,
                                        size: 18),
                                    onTap: () => _provider.openFolder(folder),
                                  );
                                },
                              ),
              ),

              const Divider(height: 1),

              // ── Action buttons ─────────────────────────────────────────
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _provider.currentPath,
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed:
                              _creatingFolder ? null : _showCreateFolderDialog,
                          icon: const Icon(Icons.create_new_folder, size: 16),
                          label: Text('New ${_provider.newFolderLabel}'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.blueGrey.shade700,
                            side: BorderSide(color: Colors.blueGrey.shade300),
                            textStyle: const TextStyle(fontSize: 12),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () =>
                              Navigator.pop(context, _provider.currentPath),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue.shade700,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Select This Folder'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
