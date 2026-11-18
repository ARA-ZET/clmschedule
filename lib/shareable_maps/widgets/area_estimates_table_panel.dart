// shareable_maps/widgets/area_estimates_table_panel.dart
//
// Left-side table of every polygon in an area library, with editable
// letter-box estimate fields.
//
// One widget for both libraries — Work Areas and Client Maps — rather than a
// copy each. They are meant to behave identically, and two copies of a table
// this fiddly (focus-committed text fields, search, sort, live totals) would
// drift apart the first time only one of them was fixed. What differs between
// them is passed in: the heading, and whether a row shows the
// houses-versus-apartments split and the client the area is for.
import 'package:clmschedule/utils/text_search.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/custom_polygon.dart';
import '../providers/shareable_map_provider.dart';
import 'map_overlay.dart';

/// A sidebar table listing an area library's polygons, with inline editing of
/// the letter-box estimate.
class AreaEstimatesTablePanel extends riverpod.ConsumerStatefulWidget {
  /// Heading, e.g. 'Work Areas' or 'Client Maps'.
  final String title;

  /// Plural noun for the empty state: "No client areas".
  final String emptyLabel;

  /// Show each area's houses-versus-apartments split beneath its name, and the
  /// library's combined split in the footer. Off for libraries whose polygons
  /// carry no split.
  final bool showBreakdown;

  /// Who an area is for, by polygon id. Null — or a null result — hides the
  /// line. Supplied by the adapter rather than read off the polygon, because
  /// [CustomPolygon] has no client of its own.
  final String? Function(String? polygonId)? clientFor;

  const AreaEstimatesTablePanel({
    super.key,
    required this.title,
    required this.emptyLabel,
    this.showBreakdown = false,
    this.clientFor,
  });

  @override
  riverpod.ConsumerState<AreaEstimatesTablePanel> createState() =>
      _AreaEstimatesTablePanelState();
}

class _AreaEstimatesTablePanelState
    extends riverpod.ConsumerState<AreaEstimatesTablePanel> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _ascending = true;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    final layers = provider.layers;

    // Collect all polygons across all layers.
    final entries = <_PolyEntry>[];
    for (final layer in layers) {
      for (int i = 0; i < layer.polygons.length; i++) {
        entries.add(
            _PolyEntry(layerId: layer.id, index: i, poly: layer.polygons[i]));
      }
    }

    // Compute total estimate across ALL entries (pre-filter) so the footer
    // still shows the grand total regardless of search.
    int totalEstimate = 0;
    int totalHouses = 0, totalFlats = 0, totalBlocks = 0;
    for (final e in entries) {
      totalEstimate += e.poly.letterBoxEstimate;
      final split = e.poly.letterBoxSplit;
      if (split != null) {
        totalHouses += split.houses;
        totalFlats += split.apartmentBoxes;
        totalBlocks += split.apartmentBlocks;
      }
    }

    // Filter by search query (every word, any order, close spellings).
    final query = _searchQuery.trim();
    final search = TextSearch(query);
    final filtered =
        entries.where((e) => search.matches([e.poly.name])).toList();

    // Sort alphabetically A–Z or Z–A.
    filtered.sort((a, b) {
      final cmp =
          a.poly.name.toLowerCase().compareTo(b.poly.name.toLowerCase());
      return _ascending ? cmp : -cmp;
    });

    return Column(
      children: [
        // ── Header ────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade50,
            border: const Border(bottom: BorderSide(color: Color(0xFFE0E0E0))),
          ),
          child: Row(
            children: [
              const Icon(Icons.table_chart, size: 18, color: Colors.blueGrey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              Text(
                  query.isEmpty
                      ? '${entries.length}'
                      : '${filtered.length}/${entries.length}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ),

        // ── Search + sort toggle ──────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          color: Colors.white,
          child: MapOverlay(
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search name...',
                      hintStyle: const TextStyle(fontSize: 12),
                      prefixIcon: const Icon(Icons.search,
                          size: 16, color: Colors.grey),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 14),
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints.tightFor(
                                  width: 28, height: 28),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                            ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 6),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _ascending ? 'Sort Z–A' : 'Sort A–Z',
                  icon: Icon(
                    _ascending ? Icons.arrow_downward : Icons.arrow_upward,
                    size: 16,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints.tightFor(width: 32, height: 32),
                  onPressed: () => setState(() => _ascending = !_ascending),
                ),
                SizedBox(
                  width: 22,
                  child: Text(
                    _ascending ? 'A–Z' : 'Z–A',
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Column headers ────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: Colors.grey.shade100,
          child: const Row(
            children: [
              Expanded(
                flex: 3,
                child: Text('Name',
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              ),
              SizedBox(
                width: 70,
                child: Text('Est. LB',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // ── Polygon rows ──────────────────────────────────────────────
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                      query.isEmpty
                          ? 'No ${widget.emptyLabel}'
                          : 'No matches for "$query"',
                      style:
                          TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _PolyRow(
                    key:
                        ValueKey('${filtered[i].layerId}_${filtered[i].index}'),
                    entry: filtered[i],
                    showBreakdown: widget.showBreakdown,
                    client: widget.clientFor?.call(filtered[i].poly.id),
                  ),
                ),
        ),

        // ── Total footer ──────────────────────────────────────────────
        const Divider(height: 1),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Colors.blueGrey.shade50,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    flex: 3,
                    child: Text('Total',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  SizedBox(
                    width: 70,
                    child: Text(
                      totalEstimate.toString(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              if (widget.showBreakdown && (totalHouses > 0 || totalFlats > 0))
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    _splitLabel(totalHouses, totalFlats, totalBlocks),
                    style: TextStyle(
                        fontSize: 10, color: Colors.blueGrey.shade600),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Data class for a polygon entry ──────────────────────────────────────────

class _PolyEntry {
  final String layerId;
  final int index;
  final CustomPolygon poly;
  const _PolyEntry(
      {required this.layerId, required this.index, required this.poly});
}

// ── Single row widget ───────────────────────────────────────────────────────

class _PolyRow extends riverpod.ConsumerStatefulWidget {
  final _PolyEntry entry;
  final bool showBreakdown;
  final String? client;

  const _PolyRow({
    super.key,
    required this.entry,
    this.showBreakdown = false,
    this.client,
  });

  @override
  riverpod.ConsumerState<_PolyRow> createState() => _PolyRowState();
}

class _PolyRowState extends riverpod.ConsumerState<_PolyRow> {
  late TextEditingController _estimateCtrl;
  late FocusNode _estimateFocus;

  @override
  void initState() {
    super.initState();
    _estimateCtrl = TextEditingController(
        text: widget.entry.poly.letterBoxEstimate > 0
            ? widget.entry.poly.letterBoxEstimate.toString()
            : '');
    _estimateFocus = FocusNode()..addListener(_onEstimateFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _PolyRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.poly.letterBoxEstimate !=
            widget.entry.poly.letterBoxEstimate &&
        !_estimateFocus.hasFocus) {
      _estimateCtrl.text = widget.entry.poly.letterBoxEstimate > 0
          ? widget.entry.poly.letterBoxEstimate.toString()
          : '';
    }
  }

  @override
  void dispose() {
    _estimateFocus.removeListener(_onEstimateFocusChanged);
    _estimateFocus.dispose();
    _estimateCtrl.dispose();
    super.dispose();
  }

  void _onEstimateFocusChanged() {
    if (!_estimateFocus.hasFocus) _commitEstimate();
  }

  void _commitEstimate() {
    final text = _estimateCtrl.text.trim();
    final newVal = text.isEmpty ? 0 : int.tryParse(text) ?? 0;
    if (newVal == widget.entry.poly.letterBoxEstimate) return;
    _updatePoly(widget.entry.poly.copyWith(letterBoxEstimate: newVal));
  }

  void _updatePoly(CustomPolygon updated) {
    final provider = ref.read(shareableMapRiverpod);
    final layer =
        provider.layers.where((l) => l.id == widget.entry.layerId).firstOrNull;
    if (layer == null) return;
    provider.updatePolygon(layer, widget.entry.index, updated);
  }

  void _selectAndOpenInfoWindow() {
    final provider = ref.read(shareableMapRiverpod);
    final layer =
        provider.layers.where((l) => l.id == widget.entry.layerId).firstOrNull;
    if (layer == null) return;
    final polygon = widget.entry.poly;
    final polygonId = '${widget.entry.layerId}_polygon_${widget.entry.index}';
    final areaKm2 = _polygonAreaKm2(polygon.points);
    final perimeterKm = _pathLengthKm(polygon.points);
    final subtitle = '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}';
    provider.focusOnPolygon(widget.entry.layerId, widget.entry.index);
    provider.openInfoWindow(InfoWindowData(
      elementId: polygonId,
      layerId: widget.entry.layerId,
      title: polygon.name.isNotEmpty ? polygon.name : 'Unnamed Polygon',
      description: polygon.description,
      subtitle: subtitle,
      type: 'polygon',
      anchor: _centroid(polygon.points),
      letterBoxEstimate: polygon.letterBoxEstimate,
      importedLetterBoxEstimate: polygon.importedLetterBoxEstimate,
      letterboxBreakdown: polygon.letterBoxSplit,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final split = widget.entry.poly.letterBoxSplit;
    return MapOverlay(
      child: InkWell(
        onTap: _selectAndOpenInfoWindow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              // Color swatch
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: widget.entry.poly.color
                      .withAlpha((widget.entry.poly.fillOpacity * 255).round()),
                  border: Border.all(color: widget.entry.poly.color, width: 1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Name (read-only), with the client and the houses/flats split
              // beneath it — the two things that decide what an area is worth
              // quoting, which a bare total hides.
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.entry.poly.name.isNotEmpty
                          ? widget.entry.poly.name
                          : 'Unnamed',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.client != null)
                      Text(
                        widget.client!,
                        style: TextStyle(
                            fontSize: 10, color: Colors.blueGrey.shade500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (widget.showBreakdown && split != null)
                      Text(
                        _splitLabel(split.houses, split.apartmentBoxes,
                            split.apartmentBlocks),
                        style: TextStyle(
                            fontSize: 10, color: Colors.blueGrey.shade400),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              // Estimate field
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _estimateCtrl,
                  focusNode: _estimateFocus,
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    hintText: '0',
                    hintStyle:
                        TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  ),
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _commitEstimate(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Formatting helpers ──────────────────────────────────────────────────────

/// "812 houses · 388 flat boxes in 24 blocks" — blocks are named separately
/// from boxes because they are different numbers: eight boxes at one door is
/// one delivery stop, not eight.
String _splitLabel(int houses, int flatBoxes, int blocks) {
  final parts = <String>[];
  if (houses > 0) parts.add('$houses houses');
  if (flatBoxes > 0) {
    parts.add(blocks > 0
        ? '$flatBoxes flat boxes in $blocks blocks'
        : '$flatBoxes flat boxes');
  }
  return parts.isEmpty ? 'no split recorded' : parts.join('  ·  ');
}

// ── Geometry helpers ────────────────────────────────────────────────────────

LatLng _centroid(List<LatLng> points) {
  if (points.isEmpty) return const LatLng(0, 0);
  double lat = 0, lng = 0;
  for (final p in points) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / points.length, lng / points.length);
}

double _haversineKm(LatLng a, LatLng b) {
  const R = 6371.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final sinDLat = math.sin(dLat / 2);
  final sinDLng = math.sin(dLng / 2);
  final aVal = sinDLat * sinDLat +
      math.cos(a.latitude * math.pi / 180) *
          math.cos(b.latitude * math.pi / 180) *
          sinDLng *
          sinDLng;
  return R * 2 * math.atan2(math.sqrt(aVal), math.sqrt(1 - aVal));
}

double _pathLengthKm(List<LatLng> points) {
  if (points.length < 2) return 0;
  double total = 0;
  for (int i = 0; i < points.length - 1; i++) {
    total += _haversineKm(points[i], points[i + 1]);
  }
  total += _haversineKm(points.last, points.first);
  return total;
}

double _polygonAreaKm2(List<LatLng> points) {
  if (points.length < 3) return 0;
  double area = 0;
  for (int i = 0; i < points.length; i++) {
    final j = (i + 1) % points.length;
    area += points[i].longitude * points[j].latitude;
    area -= points[j].longitude * points[i].latitude;
  }
  area = area.abs() / 2;
  final lat =
      points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
  final latRad = lat * math.pi / 180;
  const metersPerDegLat = 111320.0;
  final metersPerDegLng = metersPerDegLat * math.cos(latRad);
  return area * metersPerDegLat * metersPerDegLng / 1e6;
}

String _fmtKm(double km) {
  if (km < 1) return '${(km * 1000).round()} m';
  return '${km.toStringAsFixed(2)} km';
}

String _fmtKm2(double km2) {
  if (km2 < 0.01) return '${(km2 * 1e6).round()} m²';
  return '${km2.toStringAsFixed(2)} km²';
}
