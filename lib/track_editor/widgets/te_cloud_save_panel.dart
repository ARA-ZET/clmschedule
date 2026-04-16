// track_editor/widgets/te_cloud_save_panel.dart
//
// Processing-mode panel for saving tracks & waypoints to client cloud folders.
// Two workflows per client:
//   1. Save As-Is — upload full tracks + waypoints to the client folder.
//   2. Trim & Save — select polygons, trim tracks/waypoints to polygon
//      boundaries, then upload trimmed data to the client folder.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';
import '../../providers/cloud_file_manager_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../services/gpx_storage_service.dart';
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';
import '../providers/te_tabs_provider.dart';
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
  bool _loading = false;
  List<_ClientEntry> _clients = [];
  String? _error;
  int _lastTabIndex = -1;

  TETabItem get _tab {
    final tabs = ref.read(teTabsRiverpod);
    return tabs.tabs[tabs.currentTab];
  }

  @override
  Widget build(BuildContext context) {
    final tabsProvider = ref.watch(teTabsRiverpod);
    final currentIndex = tabsProvider.currentTab;

    // Re-resolve clients whenever the active tab changes.
    if (currentIndex != _lastTabIndex) {
      _lastTabIndex = currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveClients();
      });
    }

    final tab = tabsProvider.tabs[currentIndex];
    final hasTracks = tab.tracks.isNotEmpty;
    final hasWaypoints = tab.waypoints.isNotEmpty;

    if (!hasTracks && !hasWaypoints) return const SizedBox.shrink();

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
          const Row(
            spacing: 8,
            children: [
              Icon(Icons.cloud_upload, color: Colors.blue, size: 20),
              Text(
                'Save to Cloud',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const Divider(height: 16),
          if (_loading)
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
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                spacing: 8,
                children: [
                  Icon(Icons.warning_amber,
                      color: Colors.orange.shade700, size: 18),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(
                            fontSize: 12, color: Colors.orange.shade800)),
                  ),
                  IconButton(
                    onPressed: _resolveClients,
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: 'Retry',
                  ),
                ],
              ),
            )
          else ...[
            if (_clients.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('No clients found.',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              )
            else
              ..._clients.map((entry) => _ClientTile(
                    entry: entry,
                    tracks: tab.tracks,
                    waypoints: tab.waypoints,
                  )),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _addClient,
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
  Future<void> _addClient() async {
    // Start the picker at the year/month level for the current date if known.
    final date = _extractDate() ?? DateTime.now();
    final year = date.year.toString();
    final monthLabel = DateFormat('MMM yyyy').format(date);
    final monthPath = 'Distribution/$year/$monthLabel';

    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _FolderPickerDialog(initialPath: monthPath),
    );
    if (picked == null || !mounted) return;

    // Derive client name and distributor from the picked path.
    final segments = picked.split('/').where((s) => s.isNotEmpty).toList();
    // Expect: Distribution / year / month / client / [round]
    final clientName = segments.length >= 4 ? segments[3] : segments.last;

    // Check if already in the list.
    if (_clients
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

    // Get distributor name from existing entries or tab title.
    final distributorName = _clients.isNotEmpty
        ? _clients.first.distributorName
        : _matchDistributor(ref.read(scheduleRiverpod))?.name ?? '';

    setState(() {
      _clients.add(_ClientEntry(
        clientName: clientName,
        distributorName: distributorName,
        folderPath: picked,
        date: date,
        polygons: const [],
      ));
    });
  }

  /// Extract date from the first timestamped track point.
  DateTime? _extractDate() {
    for (final trk in _tab.tracks) {
      for (final seg in trk.trksegs) {
        for (final pt in seg.trkpts) {
          if (pt.time != null) return pt.time!.toLocal();
        }
      }
    }
    return null;
  }

  /// Best-match a distributor from the tab title. Returns (id, name) or null.
  ({String id, String name})? _matchDistributor(ScheduleProvider schedule) {
    if (schedule.distributors.isEmpty) return null;
    final keyTokens = _tab.title
        .replaceAll(RegExp(r'\.(gpx|kml|kmz)$', caseSensitive: false), '')
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

  Future<void> _resolveClients() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final schedule = ref.read(scheduleRiverpod);
      final date = _extractDate();
      final match = _matchDistributor(schedule);

      if (date == null || match == null) {
        setState(() {
          _loading = false;
          _error = date == null
              ? 'No timestamp found in tracks'
              : 'Could not match distributor';
        });
        return;
      }

      final jobs =
          await schedule.fetchJobsForDistributorAndDate(match.id, date);
      if (jobs.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No jobs found for this date & distributor';
        });
        return;
      }

      // Group by client — one entry per unique client name.
      final gpxStorage = GpxStorageService();
      final seen = <String>{};
      final entries = <_ClientEntry>[];

      for (final job in jobs) {
        for (final client in job.clients) {
          if (client.isEmpty || !seen.add(client)) continue;
          // Resolve next round number for folder suggestion.
          final nextRound = await gpxStorage.nextRoundNumber(date, client);
          final round = nextRound > 1 ? nextRound - 1 : 1;
          final folderPath = gpxStorage.roundFolderPath(date, client, round);

          // Collect polygons from ALL jobs referencing this client.
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

          entries.add(_ClientEntry(
            clientName: client,
            distributorName: match.name,
            folderPath: folderPath,
            date: date,
            polygons: polys,
          ));
        }
      }

      setState(() {
        _clients = entries;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Error: $e';
      });
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// DATA MODEL
// ═══════════════════════════════════════════════════════════════════════════════

class _ClientEntry {
  final String clientName;
  final String distributorName;
  final String folderPath;
  final DateTime date;
  final List<TEStyledPolygon> polygons;

  _ClientEntry({
    required this.clientName,
    required this.distributorName,
    required this.folderPath,
    required this.date,
    required this.polygons,
  });
}

// ═══════════════════════════════════════════════════════════════════════════════
// CLIENT TILE — one per client with "Save As-Is" and "Trim & Save" sections
// ═══════════════════════════════════════════════════════════════════════════════

class _ClientTile extends StatefulWidget {
  final _ClientEntry entry;
  final List<Trk> tracks;
  final List<Wpt> waypoints;

  const _ClientTile({
    required this.entry,
    required this.tracks,
    required this.waypoints,
  });

  @override
  State<_ClientTile> createState() => _ClientTileState();
}

class _ClientTileState extends State<_ClientTile> {
  bool _saving = false;
  bool _trimming = false;
  bool _expanded = false;
  final Set<int> _selectedPolyIndices = {};
  late String _folderPath;

  @override
  void initState() {
    super.initState();
    _folderPath = widget.entry.folderPath;
  }

  String get _dateStr => DateFormat('dd MMM yyyy').format(widget.entry.date);

  /// Polygon/work-area names joined with 3 spaces.
  String get _polyNames {
    final names = widget.entry.polygons
        .map((p) => p.name.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();
    return names.join('   ');
  }

  /// Build filename: Type   DD MMM YYYY   Distributor   Client   WorkAreas   WptCount.gpx
  String _fileName(String type, int wptCount) {
    final parts = <String>[
      type,
      _dateStr,
      widget.entry.distributorName,
      widget.entry.clientName,
    ];
    if (_polyNames.isNotEmpty) parts.add(_polyNames);
    parts.add(wptCount.toString());
    return '${parts.join('   ')}.gpx';
  }

  // ── Save As-Is ──────────────────────────────────────────────────────────

  Future<void> _saveAsIs() async {
    setState(() => _saving = true);
    try {
      final gpxStorage = GpxStorageService();
      final fm = TEFileManager();
      final wptCount = widget.waypoints.length;

      // Check existing files to avoid duplicates.
      final existing = await gpxStorage.listFolderContents(_folderPath);
      final existingNames = existing.files.map((f) => f.name).toSet();

      int uploaded = 0;
      int skipped = 0;

      if (widget.tracks.isNotEmpty) {
        final trackFile = _fileName('Track', wptCount);
        if (existingNames.contains(trackFile)) {
          skipped++;
        } else {
          final trackContent = await fm.toGpxTracksString(widget.tracks);
          await gpxStorage.uploadGpxFile(_folderPath, trackFile, trackContent);
          uploaded++;
        }
      }
      if (widget.waypoints.isNotEmpty) {
        final wptFile = _fileName('Waypoints', wptCount);
        if (existingNames.contains(wptFile)) {
          skipped++;
        } else {
          final wptContent = await fm.toGpxWaypointsString(widget.waypoints);
          await gpxStorage.uploadGpxFile(_folderPath, wptFile, wptContent);
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
    if (_selectedPolyIndices.isEmpty) return;
    setState(() => _trimming = true);
    try {
      final selectedPolys =
          _selectedPolyIndices.map((i) => widget.entry.polygons[i]).toList();

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

      if (trimmedTracks.isNotEmpty) {
        final trackFile = _fileName('Track Trimmed', trimmedWptCount);
        if (existingNames.contains(trackFile)) {
          skipped++;
        } else {
          final trackContent = await fm.toGpxTracksString(trimmedTracks);
          await gpxStorage.uploadGpxFile(_folderPath, trackFile, trackContent);
          uploaded++;
        }
      }
      if (trimmedWpts.isNotEmpty) {
        final wptFile = _fileName('Waypoints Trimmed', trimmedWptCount);
        if (existingNames.contains(wptFile)) {
          skipped++;
        } else {
          final wptContent = await fm.toGpxWaypointsString(trimmedWpts);
          await gpxStorage.uploadGpxFile(_folderPath, wptFile, wptContent);
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
      builder: (ctx) => _FolderPickerDialog(initialPath: _folderPath),
    );
    if (picked != null && picked != _folderPath && mounted) {
      setState(() => _folderPath = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPolygons = widget.entry.polygons.isNotEmpty;
    final busy = _saving || _trimming;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Client header ─────────────────────────────────────────────
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.business,
                      size: 18, color: Colors.blueGrey.shade600),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.entry.clientName,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          _folderPath,
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade600),
                          overflow: TextOverflow.ellipsis,
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
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.grey.shade500,
                  ),
                ],
              ),
            ),
          ),

          if (_expanded) ...[
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
                          : const Icon(Icons.cloud_upload, size: 16),
                      label: const Text('Save As-Is'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
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
                    ...List.generate(widget.entry.polygons.length, (i) {
                      final poly = widget.entry.polygons[i];
                      final isSelected = _selectedPolyIndices.contains(i);
                      return InkWell(
                        onTap: busy
                            ? null
                            : () {
                                setState(() {
                                  if (isSelected) {
                                    _selectedPolyIndices.remove(i);
                                  } else {
                                    _selectedPolyIndices.add(i);
                                  }
                                });
                              },
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
                                      : (v) {
                                          setState(() {
                                            if (v == true) {
                                              _selectedPolyIndices.add(i);
                                            } else {
                                              _selectedPolyIndices.remove(i);
                                            }
                                          });
                                        },
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
                              : () {
                                  setState(() {
                                    _selectedPolyIndices.addAll(List.generate(
                                        widget.entry.polygons.length,
                                        (i) => i));
                                  });
                                },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(fontSize: 11),
                          ),
                          child: const Text('Select All'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () {
                                  setState(() => _selectedPolyIndices.clear());
                                },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(fontSize: 11),
                          ),
                          child: const Text('Deselect All'),
                        ),
                        const Spacer(),
                        Text(
                          '${_selectedPolyIndices.length} selected',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: (busy || _selectedPolyIndices.isEmpty)
                            ? null
                            : _trimAndSave,
                        icon: _trimming
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.content_cut, size: 16),
                        label: const Text('Trim & Save to Cloud'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _selectedPolyIndices.isNotEmpty
                              ? Colors.deepOrange.shade700
                              : Colors.grey.shade500,
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
  const _FolderPickerDialog({required this.initialPath});

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  final CloudFileManagerProvider _provider = CloudFileManagerProvider();

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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Title bar ──────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: Colors.grey.shade100,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (int i = 0; i < _provider.breadcrumbs.length; i++) ...[
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
                              fontWeight: i == _provider.breadcrumbs.length - 1
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

            // ── Folder list ────────────────────────────────────────────
            Expanded(
              child: _provider.isLoading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2))
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
                              child: Text('No sub-folders',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade500)),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: _provider.folders.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final folder = _provider.folders[i];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(Icons.folder,
                                      color: Colors.amber.shade700, size: 22),
                                  title: Text(folder.name,
                                      style: const TextStyle(fontSize: 13)),
                                  trailing:
                                      const Icon(Icons.chevron_right, size: 18),
                                  onTap: () => _provider.openFolder(folder),
                                );
                              },
                            ),
            ),

            const Divider(height: 1),

            // ── Action buttons ─────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _provider.currentPath,
                      style:
                          TextStyle(fontSize: 10, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
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
            ),
          ],
        ),
      ),
    );
  }
}
