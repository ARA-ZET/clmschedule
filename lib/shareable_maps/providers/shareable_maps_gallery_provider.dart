import 'dart:async';
import 'package:flutter/material.dart';
import '../services/shareable_maps_firestore_service.dart';
import '../services/map_link_service.dart';
import '../services/map_thumbnail_service.dart';

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
  StreamSubscription? _subscription;

  ShareableMapsGalleryProvider({ShareableMapsFirestoreService? service})
      : _service = service ?? ShareableMapsFirestoreService();

  // Getters
  List<MapGalleryItem> get allMaps => _allMaps;
  List<MonthGroup> get monthGroups => _monthGroups;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get filterTab => _filterTab;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Start listening for realtime updates across all months.
  void startListening() {
    _isLoading = true;
    _error = null;
    notifyListeners();

    _subscription?.cancel();
    _subscription = _service.streamAllMaps().listen(
      (mapsWithMonth) {
        _allMaps = mapsWithMonth
            .map((m) => MapGalleryItem.fromMapWithMonth(m))
            .toList();
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
  }

  /// Fetch once (non-realtime).
  Future<void> loadMaps() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final mapsWithMonth = await _service.getAllMaps();
      _allMaps =
          mapsWithMonth.map((m) => MapGalleryItem.fromMapWithMonth(m)).toList();
      _buildMonthGroups();
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
      // If we're not streaming, manually remove from local list.
      if (_subscription == null) {
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

  List<MapGalleryItem> get filteredMaps {
    switch (_filterTab) {
      case 'recent':
        // Maps updated in the last 7 days
        final cutoff = DateTime.now().subtract(const Duration(days: 7));
        return _allMaps.where((m) => m.updatedAt.isAfter(cutoff)).toList();
      default:
        return _allMaps;
    }
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
        label: _formatMonthLabel(entry.key),
        maps: entry.value,
      );
    }).toList()
      ..sort((a, b) =>
          _sortableKey(b.monthKey).compareTo(_sortableKey(a.monthKey)));
  }

  /// Converts '03-2026' → 'March 2026'.
  String _formatMonthLabel(String monthKey) {
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
    _subscription?.cancel();
    super.dispose();
  }
}
