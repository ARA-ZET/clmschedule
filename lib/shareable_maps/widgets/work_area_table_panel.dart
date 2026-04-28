// shareable_maps/widgets/work_area_table_panel.dart
//
// Left-side panel for the work-areas editor showing a table of all polygons
// with editable name and letter-box estimate fields.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../../models/custom_polygon.dart';
import '../providers/shareable_map_provider.dart';
import '../providers/map_gesture_provider.dart';

/// A sidebar table that lists all work-area polygons with inline editing
/// for name and letter-box estimate.
class WorkAreaTablePanel extends riverpod.ConsumerStatefulWidget {
  const WorkAreaTablePanel({super.key});

  @override
  riverpod.ConsumerState<WorkAreaTablePanel> createState() =>
      _WorkAreaTablePanelState();
}

class _WorkAreaTablePanelState
    extends riverpod.ConsumerState<WorkAreaTablePanel> {
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
    for (final e in entries) {
      totalEstimate += e.poly.letterBoxEstimate;
    }

    // Filter by search query (case-insensitive substring match on name).
    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? List<_PolyEntry>.from(entries)
        : entries
            .where((e) => e.poly.name.toLowerCase().contains(query))
            .toList();

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
              const Expanded(
                child: Text('Work Areas',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
          child: MouseRegion(
            onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
            onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
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
                      prefixIcon:
                          const Icon(Icons.search, size: 16, color: Colors.grey),
                      prefixIconConstraints: const BoxConstraints(
                          minWidth: 28, minHeight: 28),
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
                    _ascending
                        ? Icons.arrow_downward
                        : Icons.arrow_upward,
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
                          ? 'No work areas'
                          : 'No matches for "$query"',
                      style:
                          TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _PolyRow(
                    key: ValueKey(
                        '${filtered[i].layerId}_${filtered[i].index}'),
                    entry: filtered[i],
                  ),
                ),
        ),

        // ── Total footer ──────────────────────────────────────────────
        const Divider(height: 1),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Colors.blueGrey.shade50,
          child: Row(
            children: [
              const Expanded(
                flex: 3,
                child: Text('Total',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
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
  const _PolyRow({super.key, required this.entry});

  @override
  riverpod.ConsumerState<_PolyRow> createState() => _PolyRowState();
}

class _PolyRowState extends riverpod.ConsumerState<_PolyRow> {
  late TextEditingController _nameCtrl;
  late TextEditingController _estimateCtrl;
  late FocusNode _nameFocus;
  late FocusNode _estimateFocus;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.entry.poly.name);
    _estimateCtrl = TextEditingController(
        text: widget.entry.poly.letterBoxEstimate > 0
            ? widget.entry.poly.letterBoxEstimate.toString()
            : '');
    _nameFocus = FocusNode()..addListener(_onNameFocusChanged);
    _estimateFocus = FocusNode()..addListener(_onEstimateFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _PolyRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.poly.name != widget.entry.poly.name &&
        !_nameFocus.hasFocus) {
      _nameCtrl.text = widget.entry.poly.name;
    }
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
    _nameFocus.removeListener(_onNameFocusChanged);
    _estimateFocus.removeListener(_onEstimateFocusChanged);
    _nameFocus.dispose();
    _estimateFocus.dispose();
    _nameCtrl.dispose();
    _estimateCtrl.dispose();
    super.dispose();
  }

  void _onNameFocusChanged() {
    if (!_nameFocus.hasFocus) _commitName();
  }

  void _onEstimateFocusChanged() {
    if (!_estimateFocus.hasFocus) _commitEstimate();
  }

  void _commitName() {
    final newName = _nameCtrl.text.trim();
    if (newName.isEmpty || newName == widget.entry.poly.name) return;
    _updatePoly(widget.entry.poly.copyWith(name: newName));
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

  void _focusOnPolygon() {
    ref
        .read(shareableMapRiverpod)
        .focusOnPolygon(widget.entry.layerId, widget.entry.index);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
      onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
      child: InkWell(
        onTap: _focusOnPolygon,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              // Name field
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _nameCtrl,
                  focusNode: _nameFocus,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    border: InputBorder.none,
                    hintText: 'Name',
                    hintStyle: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  maxLines: 1,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _commitName(),
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
