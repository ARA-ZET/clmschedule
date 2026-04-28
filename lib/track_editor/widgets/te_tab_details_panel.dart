// track_editor/widgets/te_tab_details_panel.dart
//
// Left-panel info card for the active tab.
//   ─ Tracks section: one card per track with name, distance, duration, speed,
//     start time and end time.
//   ─ Waypoints section: count + scrollable name list, with a visibility toggle
//     that also hides/shows the markers on the map.
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import '../../models/work_area.dart';
import '../models/styled_polygon.dart';
import '../providers/te_map_layer_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../services/file_manager.dart';
import '../services/point_in_polygon.dart';
import '../utils/te_track_stats.dart';
import '../../services/gpx_storage_service.dart';
import '../../providers/schedule_provider.dart';

class TETabDetailsPanel extends riverpod.ConsumerWidget {
  const TETabDetailsPanel({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(teTabsRiverpod);
    final tabIdx = provider.currentTab;
    final tab = provider.tabs[tabIdx];

    final hasTracks = tab.tracks.isNotEmpty;
    final hasWaypoints = tab.waypoints.isNotEmpty;

    if (!hasTracks && !hasWaypoints && tab.polygons.isEmpty) {
      return _PolygonsSection(
          polygons: const [], tabIndex: tabIdx, waypoints: tab.waypoints);
    }

    return Column(
      spacing: 12,
      children: [
        _PolygonsSection(
            polygons: tab.polygons, tabIndex: tabIdx, waypoints: tab.waypoints),
        if (hasTracks) _TracksSection(tracks: tab.tracks),
        if (hasWaypoints)
          _WaypointsSection(
            waypoints: tab.waypoints,
            tabIndex: tabIdx,
          ),
        if (hasTracks || hasWaypoints)
          _SaveTrimSection(
            tabTitle: tab.title,
            tracks: tab.tracks,
            waypoints: tab.waypoints,
            polygons: tab.polygons,
            storageFolderPath: tab.storageFolderPath,
            sourceStoragePath: tab.sourceStoragePath,
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// POLYGONS SECTION  (target / work-map areas)
// ════════════════════════════════════════════════════════════════════════════
class _PolygonsSection extends riverpod.ConsumerStatefulWidget {
  final List<TEStyledPolygon> polygons;
  final int tabIndex;
  final List<Wpt> waypoints;
  const _PolygonsSection(
      {required this.polygons,
      required this.tabIndex,
      required this.waypoints});

  @override
  riverpod.ConsumerState<_PolygonsSection> createState() =>
      _PolygonsSectionState();
}

class _PolygonsSectionState extends riverpod.ConsumerState<_PolygonsSection> {
  bool _searchOpen = false;
  bool _loading = false;
  List<WorkArea> _allWorkAreas = [];
  final Set<String> _selected = {};
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadWorkAreas() async {
    setState(() {
      _loading = true;
      _allWorkAreas = [];
      _selected.clear();
      _searchCtrl.clear();
    });
    final areas = await ref.read(scheduleRiverpod).fetchWorkAreas();
    if (mounted) {
      setState(() {
        _allWorkAreas = areas..sort((a, b) => a.name.compareTo(b.name));
        _loading = false;
      });
    }
  }

  List<WorkArea> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _allWorkAreas;
    return _allWorkAreas
        .where((w) =>
            w.name.toLowerCase().contains(q) ||
            w.description.toLowerCase().contains(q))
        .toList();
  }

  void _addSelected() {
    if (_selected.isEmpty) return;
    final toAdd = _allWorkAreas.where((w) => _selected.contains(w.id)).toList();
    final newPolygons = toAdd.map((w) {
      return TEStyledPolygon(
        id: 'wa_${w.id}',
        name: w.name,
        points: w.polygonPoints,
        style: TEKmlStyle(
          strokeColor: Colors.teal.shade700,
          strokeWidth: 2.0,
          fillColor: Colors.teal.shade300,
          fill: true,
          outline: true,
        ),
      );
    }).toList();
    ref.read(teTabsRiverpod).addPolygonsToCurrentTab(newPolygons);
    setState(() {
      _searchOpen = false;
      _allWorkAreas = [];
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final layerProvider = ref.watch(teMapLayerRiverpod);
    final visible = layerProvider.polygonsVisible(widget.tabIndex);
    final filtered = _filtered;

    return Container(
      width: 420,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              children: [
                const Icon(Icons.layers_outlined,
                    color: Colors.deepPurple, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Target Areas  (${widget.polygons.length})',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
                // Visibility toggle
                Tooltip(
                  message:
                      visible ? 'Hide polygons on map' : 'Show polygons on map',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => ref
                        .read(teMapLayerRiverpod)
                        .togglePolygons(widget.tabIndex),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: visible
                            ? Colors.deepPurple.shade50
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: visible
                              ? Colors.deepPurple.shade200
                              : Colors.grey.shade300,
                        ),
                      ),
                      child: Row(
                        spacing: 4,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            visible ? Icons.visibility : Icons.visibility_off,
                            size: 14,
                            color: visible
                                ? Colors.deepPurple.shade600
                                : Colors.grey,
                          ),
                          Text(
                            visible ? 'Visible' : 'Hidden',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: visible
                                  ? Colors.deepPurple.shade600
                                  : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ── Polygon list ────────────────────────────────────────────────
          if (widget.polygons.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.separated(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                shrinkWrap: true,
                itemCount: widget.polygons.length,
                separatorBuilder: (_, __) => const SizedBox(height: 2),
                itemBuilder: (context, i) {
                  final poly = widget.polygons[i];
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.shade50,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          spacing: 8,
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color:
                                    poly.style.fillColor.withValues(alpha: 0.7),
                                border: Border.all(
                                    color: poly.style.strokeColor, width: 1.5),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                poly.name.isNotEmpty
                                    ? poly.name
                                    : 'Area ${i + 1}',
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Builder(builder: (_) {
                              final wptCount = widget.waypoints.where((wpt) {
                                if (wpt.lat == null || wpt.lon == null) {
                                  return false;
                                }
                                return isPointInPolygon(
                                  LatLng(wpt.lat!, wpt.lon!),
                                  poly.points,
                                );
                              }).length;
                              return Text(
                                '$wptCount wpts',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.grey.shade500),
                              );
                            }),
                          ],
                        ),
                        if (poly.clientName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 20, top: 2),
                            child: Text(
                              poly.clientName,
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.blueGrey.shade600,
                                fontStyle: FontStyle.italic,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                'No target areas matched from schedule.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ),
          // ── Outside count ───────────────────────────────────────────────
          if (widget.polygons.isNotEmpty && widget.waypoints.isNotEmpty)
            Builder(builder: (_) {
              final insideCount = widget.waypoints.where((wpt) {
                if (wpt.lat == null || wpt.lon == null) return false;
                final ll = LatLng(wpt.lat!, wpt.lon!);
                return widget.polygons
                    .any((p) => isPointInPolygon(ll, p.points));
              }).length;
              final outsideCount = widget.waypoints.length - insideCount;
              if (outsideCount <= 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    spacing: 6,
                    children: [
                      Icon(Icons.info_outline,
                          size: 13, color: Colors.orange.shade700),
                      Text(
                        '$outsideCount waypoint${outsideCount == 1 ? '' : 's'} outside all polygons',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange.shade800),
                      ),
                    ],
                  ),
                ),
              );
            }),
          // ── Search button ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: _searchOpen
                ? const SizedBox.shrink()
                : SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() => _searchOpen = true);
                        _loadWorkAreas();
                      },
                      icon: const Icon(Icons.search, size: 16),
                      label: const Text('Search work areas'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.teal.shade700,
                        side: BorderSide(color: Colors.teal.shade300),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
          ),
          // ── Search panel ─────────────────────────────────────────────────
          if (_searchOpen) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: Row(
                spacing: 6,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Filter by name…',
                        hintStyle: TextStyle(
                            fontSize: 12, color: Colors.grey.shade400),
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 16),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                      ),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _searchOpen = false;
                      _allWorkAreas = [];
                      _selected.clear();
                    }),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (_allWorkAreas.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('No work areas found.',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              )
            else ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final w = filtered[i];
                    final checked = _selected.contains(w.id);
                    return InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() {
                        if (checked) {
                          _selected.remove(w.id);
                        } else {
                          _selected.add(w.id);
                        }
                      }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Row(
                          spacing: 6,
                          children: [
                            Checkbox(
                              value: checked,
                              onChanged: (v) => setState(() {
                                if (v == true) {
                                  _selected.add(w.id);
                                } else {
                                  _selected.remove(w.id);
                                }
                              }),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              activeColor: Colors.teal.shade700,
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(w.name,
                                      style: const TextStyle(fontSize: 12),
                                      overflow: TextOverflow.ellipsis),
                                  if (w.description.isNotEmpty)
                                    Text(
                                      w.description,
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey.shade500),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                            Text(
                              '${w.polygonPoints.length} pts',
                              style: TextStyle(
                                  fontSize: 10, color: Colors.grey.shade400),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _selected.isEmpty
                          ? 'Select areas to add'
                          : '${_selected.length} selected',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    FilledButton.icon(
                      onPressed: _selected.isEmpty ? null : _addSelected,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add selected'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.teal.shade700,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SHARED CONFIRM DIALOG
// ════════════════════════════════════════════════════════════════════════════
Future<bool> _confirmDelete(
    BuildContext context, String type, String name) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete $type?', style: const TextStyle(fontSize: 15)),
      content: Text('Are you sure you want to delete "$name"?',
          style: const TextStyle(fontSize: 13)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}

// ════════════════════════════════════════════════════════════════════════════
// TRACKS SECTION
// ════════════════════════════════════════════════════════════════════════════
class _TracksSection extends riverpod.ConsumerWidget {
  final List<Trk> tracks;
  const _TracksSection({required this.tracks});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final tabIdx = ref.watch(teTabsRiverpod).currentTab;
    return Container(
      width: 420,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              spacing: 8,
              children: [
                const Icon(Icons.timeline, color: Colors.blueGrey, size: 18),
                Text(
                  'Tracks  (${tracks.length})',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  () {
                    final totalKm = tracks
                        .map((t) => TETrackStats.fromTrack(t).distanceKm)
                        .fold(0.0, (a, b) => a + b);
                    return totalKm >= 1
                        ? '${totalKm.toStringAsFixed(2)} km'
                        : '${(totalKm * 1000).toStringAsFixed(0)} m';
                  }(),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.blueGrey.shade600),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...tracks.asMap().entries.map(
            (e) {
              final rawName = e.value.name?.trim() ?? '';
              final trackName =
                  rawName.isNotEmpty ? rawName : 'Track ${e.key + 1}';
              return _TrackCard(
                index: e.key,
                track: e.value,
                onDelete: () async {
                  final confirm =
                      await _confirmDelete(context, 'track', trackName);
                  if (!confirm) return;
                  ref.read(teTabsRiverpod).removeTrack(tabIdx, e.key);
                },
                onRename: (newName) {
                  ref.read(teTabsRiverpod).renameTrack(tabIdx, e.key, newName);
                },
              );
            },
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _TrackCard extends StatefulWidget {
  final int index;
  final Trk track;
  final VoidCallback? onDelete;
  final ValueChanged<String>? onRename;
  const _TrackCard({
    required this.index,
    required this.track,
    this.onDelete,
    this.onRename,
  });

  @override
  State<_TrackCard> createState() => _TrackCardState();
}

class _TrackCardState extends State<_TrackCard> {
  late final TextEditingController _nameCtrl;
  late final FocusNode _nameFocus;
  bool _editing = false;

  String get _fallbackName => 'Track ${widget.index + 1}';
  String get _displayName {
    final raw = widget.track.name?.trim() ?? '';
    return raw.isNotEmpty ? raw : _fallbackName;
  }

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: _displayName);
    _nameFocus = FocusNode();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus && _editing) {
        _commitRename();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _TrackCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync the field when the underlying track was renamed from elsewhere
    // (e.g. an undo/redo) and we're not mid-edit.
    if (!_editing && _nameCtrl.text != _displayName) {
      _nameCtrl.text = _displayName;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _beginEdit() {
    if (widget.onRename == null) return;
    setState(() => _editing = true);
    _nameCtrl.text = _displayName;
    // Defer focus to next frame so the field is mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocus.requestFocus();
      _nameCtrl.selection =
          TextSelection(baseOffset: 0, extentOffset: _nameCtrl.text.length);
    });
  }

  void _commitRename() {
    if (!_editing) return;
    final newName = _nameCtrl.text.trim();
    final currentRaw = widget.track.name?.trim() ?? '';
    if (newName != currentRaw) {
      widget.onRename?.call(newName);
    }
    setState(() => _editing = false);
  }

  void _cancelEdit() {
    setState(() {
      _editing = false;
      _nameCtrl.text = _displayName;
    });
  }

  @override
  Widget build(BuildContext context) {
    final stats = TETrackStats.fromTrack(widget.track);

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blueGrey.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Track name header ────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade700,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              spacing: 6,
              children: [
                const Icon(Icons.route, color: Colors.white, size: 14),
                Expanded(
                  child: _editing
                      ? TextField(
                          controller: _nameCtrl,
                          focusNode: _nameFocus,
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _commitRename(),
                          onEditingComplete: _commitRename,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                          cursorColor: Colors.white,
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.15),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                              borderSide: BorderSide.none,
                            ),
                            suffixIcon: IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 24, minHeight: 24),
                              icon: const Icon(Icons.close,
                                  color: Colors.white70, size: 14),
                              tooltip: 'Cancel',
                              onPressed: _cancelEdit,
                            ),
                          ),
                        )
                      : InkWell(
                          onTap: widget.onRename == null ? null : _beginEdit,
                          borderRadius: BorderRadius.circular(3),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 2, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    _displayName,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (widget.onRename != null) ...[
                                  const SizedBox(width: 4),
                                  const Icon(Icons.edit,
                                      size: 11, color: Colors.white54),
                                ],
                              ],
                            ),
                          ),
                        ),
                ),
                Text(stats.distanceLabel,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                if (widget.onDelete != null) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: widget.onDelete,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.delete_outline,
                          color: Colors.red.shade300, size: 18),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // ── Stats grid ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              spacing: 6,
              children: [
                Row(spacing: 6, children: [
                  Expanded(
                      child: _StatCell(
                          icon: Icons.speed,
                          label: 'Avg Speed',
                          value: stats.speedLabel)),
                  Expanded(
                      child: _StatCell(
                          icon: Icons.timer_outlined,
                          label: 'Duration',
                          value: stats.durationLabel)),
                  Expanded(
                    child: _StatCell(
                      icon: Icons.play_circle_outline,
                      label: 'Start',
                      value: stats.startTimeLabel,
                    ),
                  ),
                  Expanded(
                    child: _StatCell(
                      icon: Icons.stop_circle_outlined,
                      label: 'End',
                      value: stats.endTimeLabel,
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatCell({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Row(spacing: 4, children: [
            Icon(icon, size: 11, color: Colors.blueGrey.shade400),
            Text(label,
                style:
                    TextStyle(fontSize: 10, color: Colors.blueGrey.shade400)),
          ]),
          Text(
            value,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.blueGrey),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// WAYPOINTS SECTION
// ════════════════════════════════════════════════════════════════════════════
class _WaypointsSection extends riverpod.ConsumerStatefulWidget {
  final List<Wpt> waypoints;
  final int tabIndex;

  const _WaypointsSection({required this.waypoints, required this.tabIndex});

  @override
  riverpod.ConsumerState<_WaypointsSection> createState() =>
      _WaypointsSectionState();
}

class _WaypointsSectionState extends riverpod.ConsumerState<_WaypointsSection> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value.toLowerCase().trim());
    ref
        .read(teMapLayerRiverpod)
        .setWaypointFilter(widget.tabIndex, value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final layerProvider = ref.watch(teMapLayerRiverpod);
    final visible = layerProvider.waypointsVisible(widget.tabIndex);
    final selectedWptIdx = layerProvider.selectedWaypoint(widget.tabIndex);

    final allWaypoints = widget.waypoints;
    final filtered = _query.isEmpty
        ? allWaypoints
        : allWaypoints
            .where((w) => (w.name ?? '').toLowerCase().contains(_query))
            .toList();

    return Container(
      width: 420,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Section header with toggle ──────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              children: [
                const Icon(Icons.place_outlined, color: Colors.teal, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _query.isEmpty
                        ? 'Waypoints  (${allWaypoints.length})'
                        : 'Waypoints  (${filtered.length} / ${allWaypoints.length})',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
                Tooltip(
                  message: visible
                      ? 'Hide waypoints on map'
                      : 'Show waypoints on map',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => ref
                        .read(teMapLayerRiverpod)
                        .toggleWaypoints(widget.tabIndex),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: visible
                            ? Colors.teal.shade50
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: visible
                              ? Colors.teal.shade200
                              : Colors.grey.shade300,
                        ),
                      ),
                      child: Row(
                        spacing: 4,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            visible ? Icons.visibility : Icons.visibility_off,
                            size: 14,
                            color: visible ? Colors.teal.shade600 : Colors.grey,
                          ),
                          Text(
                            visible ? 'Visible' : 'Hidden',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color:
                                  visible ? Colors.teal.shade600 : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── Search bar ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onQueryChanged,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search waypoints…',
                hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                prefixIcon:
                    const Icon(Icons.search, size: 16, color: Colors.teal),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 14),
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                        },
                        padding: EdgeInsets.zero,
                        color: Colors.grey,
                      )
                    : null,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                filled: true,
                fillColor: Colors.teal.shade50,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.teal.shade100),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.teal.shade100),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: Colors.teal.shade400, width: 1.5),
                ),
              ),
            ),
          ),
          const Divider(height: 1),

          // ── Scrollable waypoint list ────────────────────────────────────
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      'No waypoints match "$_query"',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                  )
                : ListView.separated(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 2),
                    itemBuilder: (context, i) {
                      final wpt = filtered[i];
                      final realIdx = widget.waypoints.indexOf(wpt);
                      final name = (wpt.name?.trim().isNotEmpty ?? false)
                          ? wpt.name!
                          : 'Waypoint ${realIdx + 1}';
                      final isSelected = realIdx == selectedWptIdx;
                      return GestureDetector(
                          onTap: () {
                            ref.read(teMapLayerRiverpod).selectWaypoint(
                                widget.tabIndex, isSelected ? null : realIdx);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.orange.shade100
                                  : Colors.teal.shade50,
                              borderRadius: BorderRadius.circular(6),
                              border: isSelected
                                  ? Border.all(
                                      color: Colors.orange.shade400, width: 1.5)
                                  : null,
                            ),
                            child: Row(
                              spacing: 8,
                              children: [
                                Icon(Icons.place,
                                    size: 14,
                                    color: isSelected
                                        ? Colors.orange.shade700
                                        : Colors.teal.shade600),
                                Expanded(
                                  child: Text(name,
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal),
                                      overflow: TextOverflow.ellipsis),
                                ),
                                GestureDetector(
                                  onTap: () async {
                                    if (realIdx < 0) return;
                                    final confirm = await _confirmDelete(
                                        context, 'waypoint', name);
                                    if (!confirm) return;
                                    ref.read(teTabsRiverpod).removeWaypoint(
                                        widget.tabIndex, realIdx);
                                    ref
                                        .read(teMapLayerRiverpod)
                                        .selectWaypoint(widget.tabIndex, null);
                                  },
                                  child: Icon(Icons.delete_outline,
                                      size: 14, color: Colors.red.shade300),
                                ),
                              ],
                            ),
                          ));
                    },
                  ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}
// ════════════════════════════════════════════════════════════════════════════
// SAVE / TRIM SECTION
// ════════════════════════════════════════════════════════════════════════════

class _SaveTrimSection extends StatefulWidget {
  final String tabTitle;
  final List<Trk> tracks;
  final List<Wpt> waypoints;
  final List<TEStyledPolygon> polygons;
  final String? storageFolderPath;
  final String? sourceStoragePath;

  const _SaveTrimSection({
    required this.tabTitle,
    required this.tracks,
    required this.waypoints,
    required this.polygons,
    this.storageFolderPath,
    this.sourceStoragePath,
  });

  @override
  State<_SaveTrimSection> createState() => _SaveTrimSectionState();
}

class _SaveTrimSectionState extends State<_SaveTrimSection> {
  bool _saveBusy = false;
  bool _trimBusy = false;
  bool _cloudBusy = false;
  bool _overwriteBusy = false;

  /// Client name derived from the tab title (original filename minus extension).
  String get _clientName {
    var name = widget.tabTitle;
    name =
        name.replaceAll(RegExp(r'\.(gpx|kml|kmz)$', caseSensitive: false), '');
    return name.trim().isEmpty ? 'Export' : name.trim();
  }

  /// Work area names from polygons, joined with 3 spaces.
  String get _workAreas {
    final names = widget.polygons
        .map((p) => p.name.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();
    return names.join('   ');
  }

  /// Today's date formatted as "09 Mar 2026".
  String get _dateStr => DateFormat('dd MMM yyyy').format(DateTime.now());

  /// Build filename: Type   DD MMM YYYY   Client   WorkAreas  Count.gpx
  String _buildFileName(String type, int count) {
    final parts = <String>[type, _dateStr, _clientName];
    if (_workAreas.isNotEmpty) parts.add(_workAreas);
    parts.add(count.toString());
    return '${parts.join('   ')}.gpx';
  }

  Future<void> _onSaveTracks(BuildContext context) async {
    if (widget.tracks.isEmpty) return;
    setState(() => _saveBusy = true);
    try {
      final fm = TEFileManager();
      final fileName = _buildFileName('Track', widget.waypoints.length);
      await fm.saveGpxTracksFile(fileName, widget.tracks);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved as $fileName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Save failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _saveBusy = false);
  }

  Future<void> _onSaveWaypoints(BuildContext context) async {
    if (widget.waypoints.isEmpty) return;
    setState(() => _saveBusy = true);
    try {
      final fm = TEFileManager();
      final fileName = _buildFileName('Waypoints', widget.waypoints.length);
      await fm.saveGpxWaypointsFile(fileName, widget.waypoints);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved as $fileName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Save failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _saveBusy = false);
  }

  Future<void> _onSaveTracksToCloud(BuildContext context) async {
    if (widget.tracks.isEmpty) return;
    setState(() => _cloudBusy = true);
    try {
      final fm = TEFileManager();
      final gpxStorage = GpxStorageService();
      final fileName = _buildFileName('Track', widget.waypoints.length);
      final gpxContent = await fm.toGpxTracksString(widget.tracks);

      final folderPath = widget.storageFolderPath;
      if (folderPath == null || folderPath.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'No cloud folder selected — pick a client folder via the processing panel first.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        if (mounted) setState(() => _cloudBusy = false);
        return;
      }

      await gpxStorage.uploadGpxFile(folderPath, fileName, gpxContent);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded tracks to cloud: $fileName'),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Cloud upload failed: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _cloudBusy = false);
  }

  Future<void> _onSaveWaypointsToCloud(BuildContext context) async {
    if (widget.waypoints.isEmpty) return;
    setState(() => _cloudBusy = true);
    try {
      final fm = TEFileManager();
      final gpxStorage = GpxStorageService();
      final fileName = _buildFileName('Waypoints', widget.waypoints.length);
      final gpxContent = await fm.toGpxWaypointsString(widget.waypoints);

      final folderPath = widget.storageFolderPath;
      if (folderPath == null || folderPath.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'No cloud folder selected — pick a client folder via the processing panel first.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        if (mounted) setState(() => _cloudBusy = false);
        return;
      }

      await gpxStorage.uploadGpxFile(folderPath, fileName, gpxContent);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded waypoints to cloud: $fileName'),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Cloud upload failed: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _cloudBusy = false);
  }

  /// Overwrite the original cloud file this tab was opened from with the
  /// current tracks/waypoints, then rebuild `_compiled_waypoints.json`
  /// if the file's waypoints changed.
  Future<void> _onOverwriteSource(BuildContext context) async {
    final sourcePath = widget.sourceStoragePath;
    if (sourcePath == null || sourcePath.isEmpty) return;

    final fileName = sourcePath.split('/').last;
    final folderPath = sourcePath.contains('/')
        ? sourcePath.substring(0, sourcePath.lastIndexOf('/'))
        : '';
    final isWaypointFile = fileName.toLowerCase().contains('waypoint') ||
        widget.waypoints.isNotEmpty;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Overwrite cloud file?'),
        content: Text(
          'This will replace "$fileName" in cloud storage with the edits '
          'from this tab.\n\nThe previous version cannot be recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _overwriteBusy = true);
    try {
      final fm = TEFileManager();
      final gpxStorage = GpxStorageService();

      // Pick serializer: waypoint-named file → waypoints, else tracks.
      final String gpxContent;
      if (isWaypointFile && widget.waypoints.isNotEmpty) {
        gpxContent = await fm.toGpxWaypointsString(widget.waypoints);
      } else if (widget.tracks.isNotEmpty) {
        gpxContent = await fm.toGpxTracksString(widget.tracks);
      } else if (widget.waypoints.isNotEmpty) {
        gpxContent = await fm.toGpxWaypointsString(widget.waypoints);
      } else {
        throw StateError('Nothing to save: no tracks or waypoints.');
      }

      // Delete old, upload new (same filename).
      await gpxStorage.deleteFile(sourcePath);
      await gpxStorage.uploadGpxFile(folderPath, fileName, gpxContent);

      // If the file carried waypoints, rebuild the compiled aggregate.
      int? rebuiltCount;
      if (isWaypointFile && folderPath.isNotEmpty) {
        rebuiltCount = await gpxStorage.regenerateCompiledWaypoints(folderPath);
      }

      if (mounted) {
        final suffix =
            rebuiltCount != null ? ' · compiled waypoints: $rebuiltCount' : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Overwrote $fileName$suffix'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Overwrite failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    if (mounted) setState(() => _overwriteBusy = false);
  }

  Future<void> _onTrim(BuildContext context) async {
    setState(() => _trimBusy = true);
    final fm = TEFileManager();
    try {
      final trimmedTracks =
          trimTracksToPolygons(widget.tracks, widget.polygons);
      final trimmedWpts =
          filterWaypointsByPolygons(widget.waypoints, widget.polygons);

      String? trackFileName;
      String? trackGpxContent;
      String? wptsFileName;
      String? wptsGpxContent;

      if (trimmedTracks.isNotEmpty) {
        final trimTrackPts = trimmedTracks.fold<int>(
            0,
            (s, t) =>
                s + t.trksegs.fold<int>(0, (ss, sg) => ss + sg.trkpts.length));
        trackFileName = _buildFileName('Track Trimmed', trimTrackPts);
        trackGpxContent = await fm.toGpxTracksString(trimmedTracks);
        await fm.saveGpxTracksFile(trackFileName, trimmedTracks);
      }
      if (trimmedWpts.isNotEmpty) {
        wptsFileName = _buildFileName('Waypoints Trimmed', trimmedWpts.length);
        wptsGpxContent = await fm.toGpxWaypointsString(trimmedWpts);
        await fm.saveGpxWaypointsFile(wptsFileName, trimmedWpts);
      }

      // ── Upload to Cloud Storage ──────────────────────────────────────
      // Only upload when the tab already has an explicit cloud folder.
      // We never auto-create Round N folders here — that must come from a
      // deliberate user folder choice in the processing panel.
      int cloudUploaded = 0;
      final folderPath = widget.storageFolderPath;
      if (folderPath != null && folderPath.isNotEmpty) {
        try {
          final gpxStorage = GpxStorageService();
          if (trackFileName != null && trackGpxContent != null) {
            await gpxStorage.uploadGpxFile(
                folderPath, trackFileName, trackGpxContent);
            cloudUploaded++;
          }
          if (wptsFileName != null && wptsGpxContent != null) {
            await gpxStorage.uploadGpxFile(
                folderPath, wptsFileName, wptsGpxContent);
            cloudUploaded++;
          }
        } catch (e) {
          debugPrint('⚠️ Cloud upload failed: $e');
        }
      } else {
        debugPrint(
            '⚠️ Skipping cloud upload — no storageFolderPath set for this tab.');
      }

      final trackPts = trimmedTracks.fold<int>(
          0,
          (s, t) =>
              s + t.trksegs.fold<int>(0, (ss, sg) => ss + sg.trkpts.length));
      final msg = '$trackPts track pts, ${trimmedWpts.length} waypoints kept'
          '${cloudUploaded > 0 ? ' · $cloudUploaded uploaded' : ''}';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Trimmed: $msg'),
            backgroundColor: Colors.deepOrange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Trim failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    if (mounted) setState(() => _trimBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasTracks = widget.tracks.isNotEmpty;
    final hasWaypoints = widget.waypoints.isNotEmpty;
    final hasPolygons = widget.polygons.isNotEmpty;
    final hasSource = (widget.sourceStoragePath ?? '').isNotEmpty;
    final busy = _saveBusy || _trimBusy || _cloudBusy || _overwriteBusy;

    final trimButton = ElevatedButton.icon(
      onPressed: (busy || !hasPolygons) ? null : () => _onTrim(context),
      icon: _trimBusy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.content_cut, size: 16),
      label: const Text('Trim GPX'),
      style: ElevatedButton.styleFrom(
        backgroundColor:
            hasPolygons ? Colors.deepOrange[700] : Colors.grey[600],
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        textStyle: const TextStyle(fontSize: 12),
      ),
    );

    final spinnerIcon = SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(
          strokeWidth: 2, color: Colors.white.withAlpha(180)),
    );

    return Container(
      width: 420,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Save row: separate tracks / waypoints ──────────────────
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (busy || !hasTracks)
                      ? null
                      : () => _onSaveTracks(context),
                  icon: _saveBusy
                      ? spinnerIcon
                      : const Icon(Icons.route, size: 15),
                  label: const Text('Save Tracks'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        hasTracks ? Colors.blueGrey[700] : Colors.grey[500],
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (busy || !hasWaypoints)
                      ? null
                      : () => _onSaveWaypoints(context),
                  icon: _saveBusy
                      ? spinnerIcon
                      : const Icon(Icons.place, size: 15),
                  label: const Text('Save Waypoints'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        hasWaypoints ? Colors.teal[700] : Colors.grey[500],
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // ── Save to Cloud row ──────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (busy || !hasTracks)
                      ? null
                      : () => _onSaveTracksToCloud(context),
                  icon: _cloudBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload, size: 15),
                  label: const Text('Tracks → Cloud'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        hasTracks ? Colors.blue[700] : Colors.grey[500],
                    side: BorderSide(
                        color:
                            hasTracks ? Colors.blue[300]! : Colors.grey[300]!),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (busy || !hasWaypoints)
                      ? null
                      : () => _onSaveWaypointsToCloud(context),
                  icon: _cloudBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload, size: 15),
                  label: const Text('Waypoints → Cloud'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        hasWaypoints ? Colors.blue[700] : Colors.grey[500],
                    side: BorderSide(
                        color: hasWaypoints
                            ? Colors.blue[300]!
                            : Colors.grey[300]!),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // ── Overwrite original cloud file (only when opened from cloud) ──
          if (hasSource) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: (busy || (!hasTracks && !hasWaypoints))
                    ? null
                    : () => _onOverwriteSource(context),
                icon: _overwriteBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.save_as, size: 16),
                label: Text(
                  'Save to ${widget.sourceStoragePath!.split('/').last}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo[700],
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
          // ── Trim row ───────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: hasPolygons
                ? trimButton
                : Tooltip(
                    message: 'Load polygons first',
                    child: trimButton,
                  ),
          ),
        ],
      ),
    );
  }
}
