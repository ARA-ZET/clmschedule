import 'package:clmschedule/utils/text_search.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../services/map_name_index_service.dart';
import '../services/shareable_maps_firestore_service.dart';

/// Riverpod provider for ShareableMapsGalleryProvider.
final shareableMapsGalleryRiverpod =
    riverpod.ChangeNotifierProvider<ShareableMapsGalleryProvider>(
        (ref) => ShareableMapsGalleryProvider());

/// Lightweight metadata for gallery display.
/// Avoids holding full layer data in memory for every card.
class MapGalleryItem {
  final String docId;
  final String name;
  final String description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String monthKey; // e.g. '03-2026'
  final int layerCount;
  final int elementCount;
  final int waypointCount;
  final double centerLat;
  final double centerLng;
  final String? thumbnailUrl;

  const MapGalleryItem({
    required this.docId,
    required this.name,
    required this.description,
    required this.createdAt,
    required this.updatedAt,
    required this.monthKey,
    required this.layerCount,
    required this.elementCount,
    required this.waypointCount,
    required this.centerLat,
    required this.centerLng,
    this.thumbnailUrl,
  });

  factory MapGalleryItem.fromMapWithMonth(MapWithMonth mwm) {
    final map = mwm.map;
    return MapGalleryItem(
      docId: map.id,
      name: map.name,
      description: map.description,
      createdAt: map.createdAt,
      updatedAt: map.updatedAt,
      monthKey: mwm.monthKey,
      layerCount: map.layers.length,
      elementCount: map.totalElementCount,
      waypointCount: map.cloudWaypointCount ?? 0,
      centerLat: map.defaultCenter.latitude,
      centerLng: map.defaultCenter.longitude,
      thumbnailUrl: map.thumbnailUrl,
    );
  }

  /// From the names-only index: no layers were fetched, so the layer and
  /// element counts are unknown (0 hides their badges on the tile).
  factory MapGalleryItem.fromIndex(MapIndexEntry e) => MapGalleryItem(
        docId: e.docId,
        name: e.name,
        description: e.description,
        createdAt: e.createdAt,
        updatedAt: e.updatedAt,
        monthKey: e.monthKey,
        layerCount: 0,
        elementCount: 0,
        waypointCount: e.waypointCount,
        centerLat: e.centerLat,
        centerLng: e.centerLng,
        thumbnailUrl: e.thumbnailUrl,
      );
}

/// Groups maps by month for the gallery view.
class MonthGroup {
  final String monthKey; // '03-2026'
  final String label; // 'March 2026'
  final List<MapGalleryItem> maps;

  const MonthGroup({
    required this.monthKey,
    required this.label,
    required this.maps,
  });
}

/// Provider that manages the gallery / tile view of all shareable maps.
class ShareableMapsGalleryProvider extends ChangeNotifier {
  final ShareableMapsFirestoreService _service;

  List<MapGalleryItem> _allMaps = [];
  List<MonthGroup> _monthGroups = [];
  bool _isLoading = false;
  String? _error;
  String _filterTab = 'all'; // 'all', 'recent'
  String _searchQuery = '';

  // Names-only index of every month's maps, fetched the first time the user
  // searches, so a search covers months that were never loaded without
  // downloading their layers (see MapNameIndexService).
  List<MapGalleryItem>? _index;
  bool _indexLoading = false;

  // Lazy month loading
  List<String> _availableMonths = []; // all months from Firestore, newest first
  final Set<String> _loadedMonths = {};
  final Set<String> _loadingMonths = {};
  StreamSubscription? _currentMonthSubscription;

  ShareableMapsGalleryProvider({ShareableMapsFirestoreService? service})
      : _service = service ?? ShareableMapsFirestoreService();

  // Getters
  List<MapGalleryItem> get allMaps => _allMaps;
  List<MonthGroup> get monthGroups => _monthGroups;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get filterTab => _filterTab;
  String get searchQuery => _searchQuery;

  /// Months in Firestore that haven't been loaded yet (newest first).
  List<String> get unloadedMonths =>
      _availableMonths.where((mk) => !_loadedMonths.contains(mk)).toList();

  /// True while a search is answered from every month, so "tap to load"
  /// month rows are not needed.
  bool get searchCoversAllMonths => _searchQuery.isNotEmpty && _index != null;

  /// True while the all-months index is being fetched for a search.
  bool get isSearchIndexLoading => _searchQuery.isNotEmpty && _indexLoading;

  /// Whether a specific month is currently being fetched.
  bool isMonthLoading(String monthKey) => _loadingMonths.contains(monthKey);

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Discover available months and stream the current month.
  void startListening() async {
    _currentMonthSubscription?.cancel();
    _isLoading = true;
    _error = null;
    _allMaps = [];
    _monthGroups = [];
    _index = null;
    MapNameIndexService.instance.invalidate();
    _loadedMonths.clear();
    _loadingMonths.clear();
    notifyListeners();

    try {
      // 1. Discover which months exist in Firestore
      //    Filter to valid MM-YYYY keys only (skip auto-generated doc IDs)
      final allMonths = await _service.getAvailableMonths();
      _availableMonths = allMonths
          .where((mk) => RegExp(r'^\d{2}-\d{4}$').hasMatch(mk))
          .toList();

      // 2. Stream the current month for real-time updates
      final currentMK =
          ShareableMapsFirestoreService.monthKeyFor(DateTime.now());
      _loadedMonths.add(currentMK);

      _currentMonthSubscription = _service.streamMapsByMonth(currentMK).listen(
        (maps) {
          _allMaps.removeWhere((m) => m.monthKey == currentMK);
          for (final map in maps) {
            _allMaps.add(MapGalleryItem.fromMapWithMonth(
              MapWithMonth(map: map, monthKey: currentMK),
            ));
          }
          _buildMonthGroups();
          _isLoading = false;
          _error = null;
          notifyListeners();
        },
        onError: (e) {
          debugPrint('[ShareableMapsGallery] Stream error: $e');
          _error = e.toString();
          _isLoading = false;
          notifyListeners();
        },
      );
    } catch (e) {
      debugPrint('[ShareableMapsGallery] Init error: $e');
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Load a previous month's maps on demand (one-time fetch).
  Future<void> loadMonth(String monthKey) async {
    if (_loadedMonths.contains(monthKey) || _loadingMonths.contains(monthKey)) {
      return;
    }

    _loadingMonths.add(monthKey);
    notifyListeners();

    try {
      final maps = await _service.getMapsByMonth(monthKey);
      _loadedMonths.add(monthKey);
      for (final map in maps) {
        _allMaps.add(MapGalleryItem.fromMapWithMonth(
          MapWithMonth(map: map, monthKey: monthKey),
        ));
      }
      _buildMonthGroups();
    } catch (e) {
      debugPrint('[ShareableMapsGallery] Load month $monthKey error: $e');
    } finally {
      _loadingMonths.remove(monthKey);
      notifyListeners();
    }
  }

  /// Fetch all maps across all months at once (non-realtime).
  Future<void> loadMaps() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final mapsWithMonth = await _service.getAllMaps();
      _allMaps =
          mapsWithMonth.map((m) => MapGalleryItem.fromMapWithMonth(m)).toList();
      _buildMonthGroups();
      for (final m in _allMaps) {
        _loadedMonths.add(m.monthKey);
      }
    } catch (e) {
      _error = e.toString();
      debugPrint('[ShareableMapsGallery] Load error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Move a map (with its share links) to the Recycle Bin and refresh the
  /// list. Returns the bin entry id, for the "Restore" action.
  Future<String?> deleteMap(String monthKey, String docId) async {
    try {
      final entryId = await _service.deleteMapToBin(monthKey, docId);
      _index?.removeWhere((m) => m.docId == docId);
      MapNameIndexService.instance.invalidate();
      // The current month is streamed and will auto-update.
      // For older months (one-time fetch), manually remove from local list.
      final currentMK =
          ShareableMapsFirestoreService.monthKeyFor(DateTime.now());
      if (monthKey != currentMK) {
        _allMaps.removeWhere((m) => m.docId == docId && m.monthKey == monthKey);
        _buildMonthGroups();
        notifyListeners();
      }
      return entryId;
    } catch (e) {
      debugPrint('[ShareableMapsGallery] Delete error: $e');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------

  void setFilterTab(String tab) {
    _filterTab = tab;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query.trim();
    if (_searchQuery.isNotEmpty) _ensureIndex();
    notifyListeners();
  }

  Future<void> _ensureIndex() async {
    if (_index != null || _indexLoading) return;
    _indexLoading = true;
    try {
      final entries = await MapNameIndexService.instance.fetchAll();
      _index = entries.map(MapGalleryItem.fromIndex).toList();
    } catch (e) {
      // Search still covers the loaded months.
      debugPrint('[ShareableMapsGallery] Search index error: $e');
    } finally {
      _indexLoading = false;
      notifyListeners();
    }
  }

  /// What a search runs over: loaded maps (live, full detail) plus index
  /// entries for maps in months that were never loaded.
  List<MapGalleryItem> get _searchable {
    final index = _index;
    if (_searchQuery.isEmpty || index == null) return _allMaps;
    final loaded = {for (final m in _allMaps) m.docId};
    return [
      ..._allMaps,
      for (final m in index)
        if (!loaded.contains(m.docId) && !_loadedMonths.contains(m.monthKey))
          m,
    ];
  }

  /// Apply search filter to a list of maps.
  List<MapGalleryItem> _applySearch(List<MapGalleryItem> maps) {
    if (_searchQuery.isEmpty) return maps;
    final search = TextSearch(_searchQuery);
    return maps
        .where((m) => search.matches([m.name, m.description, m.monthKey]))
        .toList();
  }

  List<MapGalleryItem> get filteredMaps {
    List<MapGalleryItem> result = _searchable;
    if (_filterTab == 'recent') {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      result = result.where((m) => m.updatedAt.isAfter(cutoff)).toList();
    }
    return _applySearch(result);
  }

  /// Month groups with search applied.
  List<MonthGroup> get filteredMonthGroups {
    if (_searchQuery.isEmpty) return _monthGroups;
    return _groupByMonth(_applySearch(_searchable));
  }

  // ---------------------------------------------------------------------------
  // Grouping
  // ---------------------------------------------------------------------------

  void _buildMonthGroups() => _monthGroups = _groupByMonth(_allMaps);

  List<MonthGroup> _groupByMonth(List<MapGalleryItem> maps) {
    final grouped = <String, List<MapGalleryItem>>{};
    for (final map in maps) {
      grouped.putIfAbsent(map.monthKey, () => []).add(map);
    }

    return grouped.entries.map((entry) {
      return MonthGroup(
        monthKey: entry.key,
        label: formatMonthLabel(entry.key),
        maps: entry.value,
      );
    }).toList()
      ..sort((a, b) =>
          _sortableKey(b.monthKey).compareTo(_sortableKey(a.monthKey)));
  }

  /// Converts '03-2026' → 'March 2026'.
  static String formatMonthLabel(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final month = int.tryParse(parts[0]) ?? 1;
    final year = parts[1];
    const months = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[month]} $year';
  }

  /// Convert '03-2026' → '2026-03' for chronological sorting.
  static String _sortableKey(String mk) {
    final parts = mk.split('-');
    if (parts.length != 2) return mk;
    return '${parts[1]}-${parts[0]}';
  }

  @override
  void dispose() {
    _currentMonthSubscription?.cancel();
    super.dispose();
  }
}
