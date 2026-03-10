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
import 'package:provider/provider.dart';
import '../../models/work_area.dart';
import '../models/styled_polygon.dart';
import '../providers/te_map_layer_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../services/file_manager.dart';
import '../services/point_in_polygon.dart';
import '../utils/te_track_stats.dart';
import '../../providers/schedule_provider.dart';

class TETabDetailsPanel extends StatelessWidget {
  const TETabDetailsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TETabsProvider>();
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
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// POLYGONS SECTION  (target / work-map areas)
// ════════════════════════════════════════════════════════════════════════════
class _PolygonsSection extends StatefulWidget {
  final List<TEStyledPolygon> polygons;
  final int tabIndex;
  final List<Wpt> waypoints;
  const _PolygonsSection(
      {required this.polygons,
      required this.tabIndex,
      required this.waypoints});

  @override
  State<_PolygonsSection> createState() => _PolygonsSectionState();
}

class _PolygonsSectionState extends State<_PolygonsSection> {
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
    final areas = await context.read<ScheduleProvider>().fetchWorkAreas();
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
    context.read<TETabsProvider>().addPolygonsToCurrentTab(newPolygons);
    setState(() {
      _searchOpen = false;
      _allWorkAreas = [];
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final layerProvider = context.watch<TEMapLayerProvider>();
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
                    onTap: () => context
                        .read<TEMapLayerProvider>()
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
              constraints: const BoxConstraints(maxHeight: 200),
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
                    child: Row(
                      spacing: 8,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: poly.style.fillColor.withValues(alpha: 0.7),
                            border: Border.all(
                                color: poly.style.strokeColor, width: 1.5),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            poly.name.isNotEmpty ? poly.name : 'Area ${i + 1}',
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
// TRACKS SECTION
// ════════════════════════════════════════════════════════════════════════════
class _TracksSection extends StatelessWidget {
  final List<Trk> tracks;
  const _TracksSection({required this.tracks});

  @override
  Widget build(BuildContext context) {
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
                (e) => _TrackCard(index: e.key, track: e.value),
              ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  final int index;
  final Trk track;
  const _TrackCard({required this.index, required this.track});

  @override
  Widget build(BuildContext context) {
    final stats = TETrackStats.fromTrack(track);
    final rawName = track.name?.trim() ?? '';
    final trackName = rawName.isNotEmpty ? rawName : 'Track ${index + 1}';

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
                Text(
                  trackName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                Spacer(),
                Text(stats.distanceLabel,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
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
class _WaypointsSection extends StatefulWidget {
  final List<Wpt> waypoints;
  final int tabIndex;

  const _WaypointsSection({required this.waypoints, required this.tabIndex});

  @override
  State<_WaypointsSection> createState() => _WaypointsSectionState();
}

class _WaypointsSectionState extends State<_WaypointsSection> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value.toLowerCase().trim());
    context
        .read<TEMapLayerProvider>()
        .setWaypointFilter(widget.tabIndex, value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final layerProvider = context.watch<TEMapLayerProvider>();
    final visible = layerProvider.waypointsVisible(widget.tabIndex);

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
                    onTap: () => context
                        .read<TEMapLayerProvider>()
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
                      final name = (wpt.name?.trim().isNotEmpty ?? false)
                          ? wpt.name!
                          : 'Waypoint ${widget.waypoints.indexOf(wpt) + 1}';
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.teal.shade50,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          spacing: 8,
                          children: [
                            Icon(Icons.place,
                                size: 14, color: Colors.teal.shade600),
                            Expanded(
                              child: Text(name,
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                      );
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

  const _SaveTrimSection({
    required this.tabTitle,
    required this.tracks,
    required this.waypoints,
    required this.polygons,
  });

  @override
  State<_SaveTrimSection> createState() => _SaveTrimSectionState();
}

class _SaveTrimSectionState extends State<_SaveTrimSection> {
  bool _saveBusy = false;
  bool _trimBusy = false;

  String get _slug => widget.tabTitle.replaceAll(RegExp(r'[^\w]'), '_');

  Future<void> _onSave(BuildContext context) async {
    setState(() => _saveBusy = true);
    final fm = TEFileManager();
    try {
      if (widget.tracks.isNotEmpty) {
        await fm.saveGpxTracksFile('${_slug}_tracks.gpx', widget.tracks);
      }
      if (widget.waypoints.isNotEmpty) {
        await fm.saveGpxWaypointsFile(
            '${_slug}_waypoints.gpx', widget.waypoints);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('GPX files saved'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    if (mounted) setState(() => _saveBusy = false);
  }

  Future<void> _onTrim(BuildContext context) async {
    setState(() => _trimBusy = true);
    final fm = TEFileManager();
    try {
      final trimmedTracks =
          trimTracksToPolygons(widget.tracks, widget.polygons);
      final trimmedWpts =
          filterWaypointsByPolygons(widget.waypoints, widget.polygons);

      if (trimmedTracks.isNotEmpty) {
        await fm.saveGpxTracksFile(
            '${_slug}_trimmed_tracks.gpx', trimmedTracks);
      }
      if (trimmedWpts.isNotEmpty) {
        await fm.saveGpxWaypointsFile(
            '${_slug}_trimmed_waypoints.gpx', trimmedWpts);
      }

      final trackPts = trimmedTracks.fold<int>(
          0,
          (s, t) =>
              s + t.trksegs.fold<int>(0, (ss, sg) => ss + sg.trkpts.length));
      final msg = '$trackPts track pts, ${trimmedWpts.length} waypoints kept';

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
    final hasPolygons = widget.polygons.isNotEmpty;
    final busy = _saveBusy || _trimBusy;

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

    return Container(
      width: 420,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: busy ? null : () => _onSave(context),
              icon: _saveBusy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save_alt, size: 16),
              label: const Text('Save GPX'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueGrey[700],
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
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
