import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../services/shareable_maps_firestore_service.dart';
import '../services/map_link_service.dart';
import '../services/map_thumbnail_service.dart';

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

  /// Delete a map, its share links, thumbnail, and refresh the list.
  Future<void> deleteMap(String monthKey, String docId) async {
    try {
      // Clean up associated share links first
      final linkService = MapLinkService();
      await linkService.deleteLinksForMap(monthKey, docId);

      // Clean up thumbnail from Storage
      final thumbnailService = MapThumbnailService();
      await thumbnailService.deleteThumbnail(
        monthKey: monthKey,
        docId: docId,
      );

      await _service.deleteMap(monthKey, docId);
      // The current month is streamed and will auto-update.
      // For older months (one-time fetch), manually remove from local list.
      final currentMK =
          ShareableMapsFirestoreService.monthKeyFor(DateTime.now());
      if (monthKey != currentMK) {
        _allMaps.removeWhere((m) => m.docId == docId && m.monthKey == monthKey);
        _buildMonthGroups();
        notifyListeners();
      }
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
    notifyListeners();
  }

  /// Apply search filter to a list of maps.
  List<MapGalleryItem> _applySearch(List<MapGalleryItem> maps) {
    if (_searchQuery.isEmpty) return maps;
    final q = _searchQuery.toLowerCase();
    return maps.where((m) {
      return m.name.toLowerCase().contains(q) ||
          m.description.toLowerCase().contains(q) ||
          m.monthKey.contains(q);
    }).toList();
  }

  List<MapGalleryItem> get filteredMaps {
    List<MapGalleryItem> result;
    switch (_filterTab) {
      case 'recent':
        final cutoff = DateTime.now().subtract(const Duration(days: 7));
        result = _allMaps.where((m) => m.updatedAt.isAfter(cutoff)).toList();
        break;
      default:
        result = _allMaps;
    }
    return _applySearch(result);
  }

  /// Month groups with search applied.
  List<MonthGroup> get filteredMonthGroups {
    if (_searchQuery.isEmpty) return _monthGroups;
    final q = _searchQuery.toLowerCase();
    return _monthGroups
        .map((group) {
          final filtered = group.maps.where((m) {
            return m.name.toLowerCase().contains(q) ||
                m.description.toLowerCase().contains(q) ||
                m.monthKey.contains(q);
          }).toList();
          return MonthGroup(
            monthKey: group.monthKey,
            label: group.label,
            maps: filtered,
          );
        })
        .where((g) => g.maps.isNotEmpty)
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Grouping
  // ---------------------------------------------------------------------------

  void _buildMonthGroups() {
    final grouped = <String, List<MapGalleryItem>>{};
    for (final map in _allMaps) {
      grouped.putIfAbsent(map.monthKey, () => []).add(map);
    }

    _monthGroups = grouped.entries.map((entry) {
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
