import 'package:clmschedule/utils/text_search.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../shareable_maps/services/map_name_index_service.dart';

/// Result from the map picker dialog.
class MapPickerResult {
  final String mapId;
  final String monthKey;
  final String mapName;
  final String? storageFolderPath;

  const MapPickerResult({
    required this.mapId,
    required this.monthKey,
    required this.mapName,
    this.storageFolderPath,
  });
}

/// Dialog that lets the user pick an existing shareable map.
/// Returns a [MapPickerResult] or null if cancelled.
///
/// Lists every month's maps from [MapNameIndexService] — names and
/// descriptions only — so opening and searching never downloads map layers.
/// Months arrive newest first and are shown (and searchable) as they land;
/// a bar at the top shows older months are still coming.
class MapPickerDialog extends StatefulWidget {
  const MapPickerDialog({super.key});

  @override
  State<MapPickerDialog> createState() => _MapPickerDialogState();
}

class _MapPickerDialogState extends State<MapPickerDialog> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _error;

  ValueNotifier<MapIndexProgress?> get _progress =>
      MapNameIndexService.instance.progress;

  @override
  void initState() {
    super.initState();
    _progress.addListener(_onProgress);
    _load();
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool force = false}) async {
    setState(() => _error = null);
    try {
      await MapNameIndexService.instance.fetchAll(force: force);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _progress.removeListener(_onProgress);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.map, color: Colors.green.shade700),
                  const SizedBox(width: 8),
                  const Text(
                    'Link Existing Map',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                    onPressed: () => _load(force: true),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search maps...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
            _loadingBar(),
            // Map list
            Expanded(child: _buildMapList()),
          ],
        ),
      ),
    );
  }

  /// Thin bar + "n of m months" while older months are still arriving.
  Widget _loadingBar() {
    final p = _progress.value;
    if (p == null || p.done) return const Divider(height: 1);
    return Column(
      children: [
        LinearProgressIndicator(
          minHeight: 2,
          value: p.monthsTotal == 0 ? null : p.monthsLoaded / p.monthsTotal,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Loading older months… ${p.monthsLoaded} of ${p.monthsTotal}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMapList() {
    final p = _progress.value;
    final maps = p?.entries;
    final stillLoading = p == null || !p.done;
    if (maps == null || (maps.isEmpty && stillLoading)) {
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load maps: $_error',
                style: TextStyle(color: Colors.red.shade700)),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final search = TextSearch(_searchQuery);
    if (!search.isEmpty) {
      // Searching: one list, best match first, month on each row.
      final hits = search.rank(maps, (m) => [m.name, m.description]);
      if (hits.isEmpty) {
        return _empty(stillLoading
            ? 'No matches yet — still loading older months…'
            : 'No maps match "$_searchQuery"');
      }
      return ListView.builder(
        itemCount: hits.length,
        itemBuilder: (context, i) => _tile(hits[i], showMonth: true),
      );
    }

    if (maps.isEmpty) return _empty('No maps found');

    // Browsing: grouped by month, newest month first.
    final grouped = <String, List<MapIndexEntry>>{};
    for (final m in maps) {
      grouped.putIfAbsent(m.monthKey, () => []).add(m);
    }
    final months = grouped.keys.toList()
      ..sort((a, b) => _sortable(b).compareTo(_sortable(a)));
    return ListView.builder(
      itemCount: months.length,
      itemBuilder: (context, i) =>
          _buildMonthSection(months[i], grouped[months[i]]!),
    );
  }

  Widget _empty(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, style: const TextStyle(color: Colors.grey)),
        ),
      );

  /// '03-2026' → '2026-03', so string order is date order.
  static String _sortable(String mk) {
    final p = mk.split('-');
    return p.length == 2 ? '${p[1]}-${p[0]}' : mk;
  }

  static String _monthLabel(String mk) {
    try {
      final parts = mk.split('-');
      return DateFormat('MMMM yyyy')
          .format(DateTime(int.parse(parts[1]), int.parse(parts[0])));
    } catch (_) {
      return mk;
    }
  }

  Widget _buildMonthSection(String mk, List<MapIndexEntry> maps) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            _monthLabel(mk),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
            ),
          ),
        ),
        for (final m in maps) _tile(m),
      ],
    );
  }

  Widget _tile(MapIndexEntry m, {bool showMonth = false}) {
    final updated = DateFormat('d MMM yyyy').format(m.updatedAt);
    final detail = m.description.trim().isNotEmpty
        ? m.description.trim().replaceAll('\n', ' · ')
        : 'Updated $updated';
    return ListTile(
      leading: const Icon(Icons.map_outlined),
      title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        showMonth ? '${_monthLabel(m.monthKey)} · $detail' : detail,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.pop(
          context,
          MapPickerResult(
            mapId: m.docId,
            monthKey: m.monthKey,
            mapName: m.name,
          ),
        );
      },
    );
  }
}
