import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import '../shareable_maps/providers/shareable_maps_gallery_provider.dart';

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
class MapPickerDialog extends riverpod.ConsumerStatefulWidget {
  const MapPickerDialog({super.key});

  @override
  riverpod.ConsumerState<MapPickerDialog> createState() =>
      _MapPickerDialogState();
}

class _MapPickerDialogState extends riverpod.ConsumerState<MapPickerDialog> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final gallery = ref.read(shareableMapsGalleryRiverpod);
      gallery.startListening();
      // Auto-load all available months so the picker shows everything
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        final g = ref.read(shareableMapsGalleryRiverpod);
        for (final mk in g.unloadedMonths) {
          g.loadMonth(mk);
        }
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gallery = ref.watch(shareableMapsGalleryRiverpod);

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
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search maps...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (v) =>
                    setState(() => _searchQuery = v.toLowerCase()),
              ),
            ),
            const Divider(height: 1),
            // Map list
            Expanded(
              child: _buildMapList(gallery),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapList(ShareableMapsGalleryProvider gallery) {
    if (gallery.isLoading && gallery.allMaps.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final allItems = gallery.allMaps;
    final filtered = _searchQuery.isEmpty
        ? allItems
        : allItems
            .where((m) =>
                m.name.toLowerCase().contains(_searchQuery) ||
                m.description.toLowerCase().contains(_searchQuery))
            .toList();

    // Group loaded maps by month
    final grouped = <String, List<MapGalleryItem>>{};
    for (final item in filtered) {
      grouped.putIfAbsent(item.monthKey, () => []).add(item);
    }

    final loadedMonthKeys = grouped.keys.toList()
      ..sort((a, b) => b.compareTo(a)); // newest first

    // Unloaded months that can still be fetched
    final unloaded = gallery.unloadedMonths;

    if (filtered.isEmpty && unloaded.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('No maps found', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    // Total sections = loaded month groups + unloaded months
    final totalSections = loadedMonthKeys.length + unloaded.length;

    return ListView.builder(
      itemCount: totalSections,
      itemBuilder: (context, index) {
        // Loaded month sections first
        if (index < loadedMonthKeys.length) {
          final mk = loadedMonthKeys[index];
          final maps = grouped[mk]!;
          return _buildMonthSection(mk, maps);
        }

        // Unloaded month sections
        final unloadedIndex = index - loadedMonthKeys.length;
        final mk = unloaded[unloadedIndex];
        final isLoading = gallery.isMonthLoading(mk);

        String monthLabel = mk;
        try {
          final parts = mk.split('-');
          final dt = DateTime(int.parse(parts[1]), int.parse(parts[0]));
          monthLabel = DateFormat('MMMM yyyy').format(dt);
        } catch (_) {}

        return ListTile(
          leading: isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.calendar_month, color: Colors.grey.shade400),
          title: Text(monthLabel),
          subtitle: const Text('Tap to load maps'),
          onTap: isLoading ? null : () => gallery.loadMonth(mk),
        );
      },
    );
  }

  Widget _buildMonthSection(String mk, List<MapGalleryItem> maps) {
    String monthLabel = mk;
    try {
      final parts = mk.split('-');
      final dt = DateTime(int.parse(parts[1]), int.parse(parts[0]));
      monthLabel = DateFormat('MMMM yyyy').format(dt);
    } catch (_) {}

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            monthLabel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
            ),
          ),
        ),
        ...maps.map((m) => ListTile(
              leading: const Icon(Icons.map_outlined),
              title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                m.description.isNotEmpty
                    ? m.description
                    : '${m.layerCount} layer${m.layerCount == 1 ? '' : 's'}, '
                        '${m.elementCount} element${m.elementCount == 1 ? '' : 's'}',
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
            )),
      ],
    );
  }
}
