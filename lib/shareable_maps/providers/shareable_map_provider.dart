import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/custom_polygon.dart';
import '../../models/work_area.dart';
import '../../models/work_suburb.dart';
import '../../config/flavor_config.dart';
import '../../services/gpx_storage_service.dart';
import '../../services/kml_parser_service.dart';
import '../adapters/map_data_adapter.dart';
import '../adapters/firestore_adapter.dart';
import '../models/shareable_map.dart';
import '../models/map_layer.dart';
import '../models/map_polyline.dart';
import '../models/map_point.dart';
import '../services/map_thumbnail_service.dart';
import '../services/shareable_maps_firestore_service.dart';

/// Riverpod provider for ShareableMapProvider.
final shareableMapRiverpod =
    riverpod.ChangeNotifierProvider<ShareableMapProvider>(
        (ref) => ShareableMapProvider());

// ── Isolate helper for GPX parsing ──────────────────────────────────────
/// Top-level function so it can be used with [compute].
/// Accepts a list of (bytes, fileName) pairs and returns parsed results.
ParsedMapResult _parseGpxInIsolate(_IsolateParseInput input) {
  final allPolylines = <MapPolyline>[];
  final allPoints = <MapPoint>[];
  final allPolygons = <CustomPolygon>[];

  for (final entry in input.files) {
    try {
      final result = KmlParserService.parseKmlDataSync(entry.bytes, entry.name);
      allPolylines.addAll(result.polylines);
      allPoints.addAll(result.points);
      allPolygons.addAll(result.polygons);
    } catch (_) {
      // Skip files that fail to parse
    }
  }

  return ParsedMapResult(
    polygons: allPolygons,
    polylines: allPolylines,
    points: allPoints,
  );
}

class _IsolateParseInput {
  final List<_IsolateFileEntry> files;
  const _IsolateParseInput(this.files);
}

class _IsolateFileEntry {
  final Uint8List bytes;
  final String name;
  const _IsolateFileEntry(this.bytes, this.name);
}

// ── Compiled JSON parsers ───────────────────────────────────────────────

/// Parse a `_compiled_tracks.json` file produced by the Cloud Function.
/// Returns a list of [MapPolyline] with metadata (distance, times, duration).
List<MapPolyline> _parseCompiledTracks(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final tracks = json['tracks'] as List<dynamic>? ?? [];
  final now = DateTime.now();
  final results = <MapPolyline>[];
  int seq = 0;

  for (final t in tracks) {
    final rawPoints = t['points'] as List<dynamic>? ?? [];
    if (rawPoints.length < 2) continue;
    final points = rawPoints
        .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList();

    final name = (t['name'] as String?) ?? 'Track ${seq + 1}';
    final desc = (t['desc'] as String?) ?? '';
    final distM = (t['distanceMeters'] as num?)?.toDouble();
    final startMs = (t['startTime'] as num?)?.toInt();
    final endMs = (t['endTime'] as num?)?.toInt();
    final durMs = (t['durationMs'] as num?)?.toInt();

    results.add(MapPolyline(
      id: 'compiled_trk_${now.millisecondsSinceEpoch}_${seq++}',
      name: name,
      description: desc,
      points: points,
      color: Colors.blue,
      strokeWidth: 3.0,
      createdAt: now,
      updatedAt: now,
      distanceMeters: distM,
      startTime:
          startMs != null ? DateTime.fromMillisecondsSinceEpoch(startMs) : null,
      endTime:
          endMs != null ? DateTime.fromMillisecondsSinceEpoch(endMs) : null,
      duration: durMs != null ? Duration(milliseconds: durMs) : null,
    ));
  }
  return results;
}

/// Parse a `_compiled_waypoints.json` file produced by the Cloud Function.
List<MapPoint> _parseCompiledWaypoints(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final wpts = json['waypoints'] as List<dynamic>? ?? [];
  final now = DateTime.now();
  final results = <MapPoint>[];
  int seq = 0;

  for (final w in wpts) {
    final lat = (w['lat'] as num?)?.toDouble();
    final lon = (w['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) continue;

    final name = (w['name'] as String?) ?? 'Waypoint ${seq + 1}';
    final desc = (w['desc'] as String?) ?? '';

    results.add(MapPoint(
      id: 'compiled_wpt_${now.millisecondsSinceEpoch}_${seq++}',
      name: name,
      description: desc,
      position: LatLng(lat, lon),
      color: Colors.red,
      createdAt: now,
      updatedAt: now,
    ));
  }
  return results;
}

/// Data for the currently open info window overlay.
class InfoWindowData {
  final String elementId;
  final String layerId;
  final String title;
  final String description;
  final String subtitle; // stats: "2.87 km² · 8.37 km" or "8.37 km" or ""
  final String type; // 'polygon' | 'polyline' | 'point'
  final LatLng anchor; // geographic point reprojected to screen on each frame
  final int letterBoxEstimate;

  const InfoWindowData({
    required this.elementId,
    required this.layerId,
    required this.title,
    required this.description,
    required this.subtitle,
    required this.type,
    required this.anchor,
    this.letterBoxEstimate = 0,
  });
}

/// Drawing mode for the map editor
enum DrawingMode {
  none,
  polygon,
  polyline,
  point,
  edit,
  lassoSelect,
}

/// State management for the universal map editor.
///
/// Works in two modes:
/// 1. **Standalone** (no adapter): in-memory map, no persistence (original behavior).
/// 2. **Adapter mode**: data loaded/saved via a [MapDataAdapter].
///
/// The [capabilities] getter exposes feature flags from the active adapter
/// so that UI widgets can show/hide tools dynamically.
class ShareableMapProvider extends ChangeNotifier {
  // Adapter state
  MapDataAdapter? _adapter;
  bool _isSaving = false;
  bool _isLoading = false;

  // Current map state
  ShareableMap? _currentMap;
  String? _selectedLayerId;
  String? _selectedElementId;
  DrawingMode _drawingMode = DrawingMode.none;

  // Drawing state
  final List<LatLng> _drawingPoints = [];
  bool _isDrawing = false;
  bool _ignoreNextTap = false; // Flag to ignore first tap after mode change
  bool _isDialogOpen = false; // Flag to block drawing while dialog is open
  bool _drawingToUnfinished =
      false; // Flag: also save completed polygon to unfinished work areas

  // Editing state
  List<LatLng>? _editingPoints;
  bool _hasUnsavedChanges = false;
  bool _isEditingVertices = false;
  bool _isEditingPolygon =
      false; // true when the element being edited is a polygon
  String? _editingElementId; // Track which element is being edited

  // ── Cloud overlay layers (ephemeral — never persisted to Firestore) ───
  final Map<String, MapLayer> _cloudTracksLayers = {};
  final Map<String, MapLayer> _cloudWaypointsLayers = {};
  final Set<String> _loadingCloudTrackFolders = {};
  final Set<String> _loadingCloudWaypointFolders = {};
  final Set<String> _loadedCloudTrackFolders = {};
  final Set<String> _loadedCloudWaypointFolders = {};

  /// Layer IDs currently mid-visibility-toggle. The map widget needs a
  /// frame to push the marker-set diff across the JS bridge; ignoring
  /// rapid repeat taps avoids queueing thousands of marker diffs that
  /// would freeze the page when toggling large (15k+) waypoint layers.
  final Set<String> _togglingLayers = {};
  static const _toggleCooldown = Duration(milliseconds: 250);

  /// Returns true if [layerId] should be UI-disabled because a previous
  /// visibility toggle is still being applied.
  bool isLayerToggling(String layerId) => _togglingLayers.contains(layerId);

  // Real-time sync state
  StreamSubscription<ShareableMap?>? _realtimeSubscription;
  Timer? _autoSaveTimer;
  Timer? _thumbnailTimer;

  /// Flag set in [dispose] so any async/microtask/timer callbacks that
  /// outlive the provider become no-ops instead of touching freed state
  /// or calling [notifyListeners] on a disposed ChangeNotifier.
  bool _isDisposed = false;

  /// Timestamp of last local save — used to skip echoed Firestore snapshots.
  int _lastSaveTimestamp = 0;

  /// How long to wait after a mutation before auto-saving (debounce).
  static const _autoSaveDelay = Duration(seconds: 2);

  /// How long to wait after last auto-save before refreshing thumbnail.
  static const _thumbnailDelay = Duration(seconds: 10);

  // UI state
  bool _isSidebarVisible = true;
  bool _isWorkAreaPickerVisible = false;
  bool _isLassoSelectActive = false;
  bool _showWorkAreasOverlay = false;
  bool _showSuburbsOverlay = false;
  bool _workAreasOverlayExpanded = false;
  bool _suburbsOverlayExpanded = false;
  // Picker panel layer visibility
  bool _pickerWorkAreasVisible = true;
  bool _pickerSuburbsVisible = false;
  final List<LatLng> _lassoPoints = [];
  GoogleMapController? _mapController;
  bool _pendingFitBounds = false;

  // Map type / style state
  MapType _mapType = MapType.normal;
  String? _activeMapStyleJson; // For JSON-based custom styles
  String? _activeCloudMapId = FlavorConfig.instance.isMaps
      ? '89c628d2bb3002712797ce42'
      : null; // For cloud-based custom styles
  String _selectedBaseMap =
      FlavorConfig.instance.isMaps ? 'clm_custom' : 'roadmap';

  // Info window / style panel state
  InfoWindowData? _infoWindowData;
  bool _showStylePanel = false;

  // Getters
  ShareableMap? get currentMap => _currentMap;
  String? get selectedLayerId => _selectedLayerId;
  String? get selectedElementId => _selectedElementId;
  DrawingMode get drawingMode => _drawingMode;
  List<LatLng> get drawingPoints => List.unmodifiable(_drawingPoints);
  bool get isDrawing => _isDrawing;
  bool get isDrawingForUnfinished => _drawingToUnfinished;
  bool get ignoreNextTap => _ignoreNextTap;
  List<LatLng>? get editingPoints => _editingPoints;
  bool get hasUnsavedChanges => _hasUnsavedChanges;
  bool get isSidebarVisible => _isSidebarVisible;
  bool get isWorkAreaPickerVisible => _isWorkAreaPickerVisible;
  bool get showWorkAreasOverlay => _showWorkAreasOverlay;
  bool get showSuburbsOverlay => _showSuburbsOverlay;
  bool get workAreasOverlayExpanded => _workAreasOverlayExpanded;
  bool get suburbsOverlayExpanded => _suburbsOverlayExpanded;
  bool get pickerWorkAreasVisible => _pickerWorkAreasVisible;
  bool get pickerSuburbsVisible => _pickerSuburbsVisible;
  bool get isLassoSelectActive => _isLassoSelectActive;
  List<LatLng> get lassoPoints => List.unmodifiable(_lassoPoints);
  bool get isEditingVertices => _isEditingVertices;
  bool get isEditingPolygon => _isEditingPolygon;
  String? get editingElementId => _editingElementId;
  InfoWindowData? get infoWindowData => _infoWindowData;
  bool get showStylePanel => _showStylePanel;
  MapType get mapType => _mapType;
  String? get mapStyle => _activeMapStyleJson;
  String? get cloudMapId => _activeCloudMapId;
  String get selectedBaseMap => _selectedBaseMap;

  // Adapter getters
  MapDataAdapter? get adapter => _adapter;
  bool get hasAdapter => _adapter != null;
  bool get isSaving => _isSaving;
  bool get isLoading => _isLoading;

  /// Active capabilities — if no adapter is set, returns full capabilities.
  MapEditorCapabilities get capabilities =>
      _adapter?.capabilities ?? const MapEditorCapabilities.full();

  // Get currently selected layer
  MapLayer? get selectedLayer {
    if (_currentMap == null || _selectedLayerId == null) return null;
    return _currentMap!.getLayer(_selectedLayerId!);
  }

  // Get available layers (persisted + ephemeral cloud overlays)
  List<MapLayer> get layers {
    final base = _currentMap?.layers ?? [];
    final overlays = <MapLayer>[
      ..._cloudTracksLayers.values.where(_shouldShowCloudTrackLayer),
      ..._cloudWaypointsLayers.values.where(_shouldShowCloudWaypointLayer),
    ]..sort((a, b) => a.order.compareTo(b.order));
    if (overlays.isEmpty) return base;
    return [...base, ...overlays];
  }

  bool _shouldShowCloudTrackLayer(MapLayer layer) {
    final folderPath = layer.description.trim();
    if (folderPath.isEmpty) return false;
    return layer.polylines.isNotEmpty ||
        layer.points.isNotEmpty ||
        _loadedCloudTrackFolders.contains(folderPath) ||
        _loadingCloudTrackFolders.contains(folderPath);
  }

  bool _shouldShowCloudWaypointLayer(MapLayer layer) {
    final folderPath = layer.description.trim();
    if (folderPath.isEmpty) return false;
    final folders = linkedCloudFolders;
    final isSingleLinkedFolder =
        folders.length == 1 && folders.first == folderPath;
    return layer.points.isNotEmpty ||
        isSingleLinkedFolder ||
        _loadedCloudWaypointFolders.contains(folderPath) ||
        _loadingCloudWaypointFolders.contains(folderPath);
  }

  /// Whether the given layer is a cloud overlay (ephemeral, read-only).
  bool isCloudOverlayLayer(String layerId) {
    return _cloudTracksLayers.containsKey(layerId) ||
        _cloudWaypointsLayers.containsKey(layerId);
  }

  bool isCloudTracksLayer(String layerId) =>
      _cloudTracksLayers.containsKey(layerId);

  bool isCloudWaypointsLayer(String layerId) =>
      _cloudWaypointsLayers.containsKey(layerId);

  String? cloudFolderForLayer(String layerId) {
    final track = _cloudTracksLayers[layerId];
    if (track != null) return track.description;
    final waypoint = _cloudWaypointsLayers[layerId];
    if (waypoint != null) return waypoint.description;
    return null;
  }

  // === ADAPTER OPERATIONS ===

  /// Load data from an adapter and prepare the editor.
  ///
  /// This replaces the current map with data from the adapter's [load] method
  /// and stores the adapter reference for subsequent [saveToAdapter] calls.
  /// For [FirestoreMapAdapter], also starts a real-time snapshot listener so
  /// remote changes are automatically reflected.
  Future<void> loadFromAdapter(MapDataAdapter adapter) async {
    final sw = Stopwatch()..start();
    debugPrint('[loadFromAdapter] START');
    _isLoading = true;
    notifyListeners();

    try {
      // Clean up previous real-time listener. Await the cancel so the
      // previous Firestore listener is fully torn down before we attach a
      // new one — otherwise overlapping listeners briefly double the
      // snapshot traffic and memory footprint when rapidly switching maps.
      await _stopRealtimeSync();
      await _adapter?.dispose();
      debugPrint(
          '[loadFromAdapter] cleanup done in ${sw.elapsedMilliseconds}ms');
      _adapter = adapter;

      // Reset all per-map ephemeral state so data from the previously open
      // map (cloud overlays, selection, info window, drawing/editing flags)
      // doesn't bleed into the new map.
      _resetPerMapState();

      // Load the map data
      final map = await adapter.load();
      debugPrint(
          '[loadFromAdapter] adapter.load() done in ${sw.elapsedMilliseconds}ms');
      loadMap(map);
      debugPrint(
          '[loadFromAdapter] loadMap() done in ${sw.elapsedMilliseconds}ms');

      // Start real-time sync for Firestore-backed maps
      if (adapter is FirestoreMapAdapter) {
        _startRealtimeSync(adapter);
        debugPrint(
            '[loadFromAdapter] realtimeSync started in ${sw.elapsedMilliseconds}ms');
      }
    } catch (e) {
      debugPrint('[loadFromAdapter] FAILED at ${sw.elapsedMilliseconds}ms: $e');
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }

    // Fit camera to map bounds once layout settles.
    // If the controller already exists (widget not recreated), fit directly.
    // Otherwise set the pending flag so setMapController will trigger it.
    if (_mapController != null) {
      _pendingFitBounds = false;
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_isDisposed) return;
        fitMapToBounds();
      });
    } else {
      _pendingFitBounds = true;
    }

    // Initialise cloud overlay shells and auto-load tracks (deferred)
    _initCloudOverlays();
    final latestFolder = latestLinkedCloudFolder;
    if (_mapController != null &&
        autoLoadLatestCloudFolder &&
        latestFolder != null) {
      Future.microtask(() {
        if (_isDisposed) return;
        loadCloudFolderTracks(folderPath: latestFolder);
      });
    }
    debugPrint('[loadFromAdapter] TOTAL: ${sw.elapsedMilliseconds}ms');
  }

  // ── Cloud folder loading (ephemeral — never saved to Firestore) ────────

  bool get isLoadingCloudTracks => _loadingCloudTrackFolders.isNotEmpty;
  bool get isLoadingCloudWaypoints => _loadingCloudWaypointFolders.isNotEmpty;
  bool get cloudTracksLoaded => _loadedCloudTrackFolders.isNotEmpty;
  bool get cloudWaypointsLoaded => _loadedCloudWaypointFolders.isNotEmpty;

  List<String> get linkedCloudFolders {
    final map = _currentMap;
    if (map == null) return const [];
    final folders = <String>[];
    for (final path in map.cloudFolderPaths) {
      final clean = path.trim();
      if (clean.isNotEmpty && !folders.contains(clean)) folders.add(clean);
    }
    final legacy = map.storageFolderPath?.trim();
    if (legacy != null && legacy.isNotEmpty && !folders.contains(legacy)) {
      folders.insert(0, legacy);
    }
    return List.unmodifiable(folders);
  }

  bool get autoLoadLatestCloudFolder =>
      _currentMap?.autoLoadLatestCloudFolder ?? true;

  bool get clipCloudDataToPolygons =>
      _currentMap?.clipCloudDataToPolygons ?? false;

  String? get latestLinkedCloudFolder {
    final folders = linkedCloudFolders;
    if (folders.isEmpty) return null;
    final sorted = List<String>.from(folders)
      ..sort(
          (a, b) => _cloudFolderSortDate(b).compareTo(_cloudFolderSortDate(a)));
    return sorted.first;
  }

  int? letterBoxesReachedForPolygon(String layerId, String elementId) {
    final folders = linkedCloudFolders;
    if (folders.isEmpty || _currentMap == null) return null;

    final match = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(elementId);
    if (match == null) return null;

    final resolvedLayerId = match.group(1) ?? layerId;
    final polygonIndex = int.tryParse(match.group(2) ?? '');
    if (polygonIndex == null) return null;

    final layer = _currentMap!.getLayer(resolvedLayerId);
    if (layer == null || polygonIndex >= layer.polygons.length) return null;

    final polygon = layer.polygons[polygonIndex];
    if (!polygon.isPolygon || polygon.points.length < 3) return null;

    final linkedFolders = folders.toSet();
    var reached = 0;
    for (final waypointLayer in _cloudWaypointsLayers.values) {
      final folderPath = waypointLayer.description.trim();
      if (!linkedFolders.contains(folderPath)) continue;
      for (final point in waypointLayer.points) {
        if (_pointInPolygon(point.position, polygon.points)) reached++;
      }
    }
    return reached;
  }

  bool cloudTracksLoadedFor(String folderPath) =>
      _loadedCloudTrackFolders.contains(folderPath.trim());

  bool cloudWaypointsLoadedFor(String folderPath) =>
      _loadedCloudWaypointFolders.contains(folderPath.trim());

  bool isLoadingCloudTracksFor(String folderPath) =>
      _loadingCloudTrackFolders.contains(folderPath.trim());

  bool isLoadingCloudWaypointsFor(String folderPath) =>
      _loadingCloudWaypointFolders.contains(folderPath.trim());

  Color cloudTrackColorForFolder(String folderPath) {
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');
    final savedColor = _currentMap?.cloudTrackColors[cleanPath];
    if (savedColor != null) return Color(savedColor);
    return _defaultCloudTrackColor(cleanPath);
  }

  void setCloudTrackColor(String folderPath, Color color) {
    if (_currentMap == null) return;
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleanPath.isEmpty) return;

    final colors = Map<String, int>.from(_currentMap!.cloudTrackColors);
    colors[cleanPath] = color.toARGB32();
    _currentMap = _currentMap!.copyWith(cloudTrackColors: colors);

    final layerId = _cloudLayerId('tracks', cleanPath);
    final layer = _cloudTracksLayers[layerId];
    if (layer != null) {
      _cloudTracksLayers[layerId] = _applyCloudTrackColor(cleanPath, layer);
    }
    _notifyAndSave();
  }

  /// Rename a cloud overlay layer. The new name is persisted in
  /// [ShareableMap.cloudLayerNames] so it survives reloads and works across
  /// all flavours. The key is `"wpt:<folderPath>"` for waypoint layers and
  /// plain `"<folderPath>"` for track layers.
  void renameCloudLayer(String layerId, String newName) {
    if (_currentMap == null) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;

    final folderPath = cloudFolderForLayer(layerId);
    if (folderPath == null) return;
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');

    final isWaypoint = isCloudWaypointsLayer(layerId);
    final nameKey = isWaypoint ? 'wpt:$cleanPath' : cleanPath;

    final names = Map<String, String>.from(_currentMap!.cloudLayerNames);
    names[nameKey] = trimmed;
    _currentMap = _currentMap!.copyWith(cloudLayerNames: names);

    // Apply immediately to the in-memory layer shell.
    if (isWaypoint) {
      final layer = _cloudWaypointsLayers[layerId];
      if (layer != null) {
        _cloudWaypointsLayers[layerId] = layer.copyWith(name: trimmed);
      }
    } else {
      final layer = _cloudTracksLayers[layerId];
      if (layer != null) {
        _cloudTracksLayers[layerId] = layer.copyWith(name: trimmed);
      }
    }
    _notifyAndSave();
  }

  void unloadCloudFolderTracks(String folderPath) {
    final cleanPath = folderPath.trim();
    final layerId = _cloudLayerId('tracks', cleanPath);
    final layer = _cloudTracksLayers[layerId];
    if (layer != null) {
      _cloudTracksLayers[layerId] = layer.copyWith(
        polylines: const [],
        points: const [],
      );
    }
    _loadedCloudTrackFolders.remove(cleanPath);
    notifyListeners();
  }

  void unloadCloudFolderWaypoints(String folderPath) {
    final cleanPath = folderPath.trim();
    final layerId = _cloudLayerId('waypoints', cleanPath);
    final layer = _cloudWaypointsLayers[layerId];
    if (layer != null) {
      _cloudWaypointsLayers[layerId] = layer.copyWith(points: const []);
    }
    _loadedCloudWaypointFolders.remove(cleanPath);
    notifyListeners();
  }

  /// The layer name used for auto-loaded tracks.
  static const String tracksLayerName = 'Movements of the Distributors';

  /// The layer name used for on-demand waypoints.
  static const String waypointsLayerName = 'Letter Boxes Reached';

  /// The default user layer name.
  static const String _targetAreasLayerName = 'Target Areas';

  /// Initialise empty cloud overlay layers when a folder is linked.
  /// Tracks are auto-loaded (deferred); waypoints show as empty until
  /// the user explicitly requests them.
  void _initCloudOverlays() {
    final folders = linkedCloudFolders;
    if (folders.isEmpty) {
      _cloudTracksLayers.clear();
      _cloudWaypointsLayers.clear();
      _loadedCloudTrackFolders.clear();
      _loadedCloudWaypointFolders.clear();
      return;
    }

    final validTrackIds = <String>{};
    final validWaypointIds = <String>{};
    for (int i = 0; i < folders.length; i++) {
      final folder = folders[i];
      final trackId = _cloudLayerId('tracks', folder);
      final waypointId = _cloudLayerId('waypoints', folder);
      validTrackIds.add(trackId);
      validWaypointIds.add(waypointId);
      final trackLayer = _cloudTracksLayers[trackId] ??
          _cloudTrackLayerShell(folder, order: 900 + i * 2);
      _cloudTracksLayers[trackId] = _applyCloudTrackColor(
        folder,
        trackLayer.copyWith(order: 900 + i * 2),
      );
      _cloudWaypointsLayers.putIfAbsent(waypointId,
          () => _cloudWaypointLayerShell(folder, order: 901 + i * 2));
    }

    _cloudTracksLayers.removeWhere((id, _) => !validTrackIds.contains(id));
    _cloudWaypointsLayers
        .removeWhere((id, _) => !validWaypointIds.contains(id));
    _loadedCloudTrackFolders.removeWhere((p) => !folders.contains(p));
    _loadedCloudWaypointFolders.removeWhere((p) => !folders.contains(p));

    // Tracks will auto-load once the Google Maps controller is ready
    // (see setMapController).
  }

  String _cloudLayerId(String kind, String folderPath) =>
      'cloud_${kind}_${_stableFolderKey(folderPath)}';

  String _stableFolderKey(String folderPath) {
    var hash = 0;
    for (final unit in folderPath.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  MapLayer _cloudTrackLayerShell(String folderPath, {required int order}) {
    final now = DateTime.now();
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');
    final label = cloudFolderMonthLabel(folderPath);
    final customName = _currentMap?.cloudLayerNames[cleanPath];
    return MapLayer(
      id: _cloudLayerId('tracks', folderPath),
      name: customName ?? '$label Movements',
      description: folderPath,
      order: order,
      defaultColor: cloudTrackColorForFolder(folderPath),
      createdAt: now,
      updatedAt: now,
    );
  }

  static const List<Color> _cloudTrackPalette = [
    Color(0xFF1967D2),
    Color(0xFFD93025),
    Color(0xFF188038),
    Color(0xFFF29900),
    Color(0xFF9334E6),
    Color(0xFF0097A7),
    Color(0xFFE91E63),
    Color(0xFF795548),
  ];

  Color _defaultCloudTrackColor(String folderPath) {
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');
    final index = linkedCloudFolders.indexOf(cleanPath);
    if (index >= 0) {
      return _cloudTrackPalette[index % _cloudTrackPalette.length];
    }
    var hash = 0;
    for (final unit in cleanPath.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _cloudTrackPalette[hash % _cloudTrackPalette.length];
  }

  MapLayer _applyCloudTrackColor(String folderPath, MapLayer layer) {
    final color = cloudTrackColorForFolder(folderPath);
    return layer.copyWith(
      defaultColor: color,
      polylines: layer.polylines
          .map((polyline) => polyline.copyWith(color: color))
          .toList(),
      points:
          layer.points.map((point) => point.copyWith(color: color)).toList(),
    );
  }

  List<MapPolyline> _applyCloudTrackColorToPolylines(
    String folderPath,
    List<MapPolyline> polylines,
  ) {
    final color = cloudTrackColorForFolder(folderPath);
    return polylines
        .map((polyline) => polyline.copyWith(color: color))
        .toList();
  }

  List<MapPoint> _applyCloudTrackColorToPoints(
    String folderPath,
    List<MapPoint> points,
  ) {
    final color = cloudTrackColorForFolder(folderPath);
    return points.map((point) => point.copyWith(color: color)).toList();
  }

  MapLayer _cloudWaypointLayerShell(String folderPath, {required int order}) {
    final now = DateTime.now();
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');
    final label = cloudFolderMonthLabel(folderPath);
    final customName = _currentMap?.cloudLayerNames['wpt:$cleanPath'];
    return MapLayer(
      id: _cloudLayerId('waypoints', folderPath),
      name: customName ?? '$label Letter Boxes',
      description: folderPath,
      order: order,
      defaultColor: Colors.red,
      createdAt: now,
      updatedAt: now,
    );
  }

  String cloudFolderMonthLabel(String folderPath) {
    final parts = folderPath.split('/').where((p) => p.trim().isNotEmpty);
    for (final part in parts) {
      final trimmed = part.trim();
      if (RegExp(r'^[A-Za-z]{3}\s+\d{4}$').hasMatch(trimmed) ||
          RegExp(r'^\d{2}-\d{4}$').hasMatch(trimmed)) {
        return trimmed;
      }
    }
    return parts.isNotEmpty ? parts.last : 'Cloud';
  }

  DateTime _cloudFolderSortDate(String folderPath) {
    final label = cloudFolderMonthLabel(folderPath);
    final mm = RegExp(r'^(\d{2})-(\d{4})$').firstMatch(label);
    if (mm != null) {
      return DateTime(int.parse(mm.group(2)!), int.parse(mm.group(1)!));
    }
    final named = RegExp(r'^([A-Za-z]{3})\s+(\d{4})$').firstMatch(label);
    if (named != null) {
      const months = {
        'jan': 1,
        'feb': 2,
        'mar': 3,
        'apr': 4,
        'may': 5,
        'jun': 6,
        'jul': 7,
        'aug': 8,
        'sep': 9,
        'oct': 10,
        'nov': 11,
        'dec': 12,
      };
      final month = months[named.group(1)!.toLowerCase()] ?? 1;
      return DateTime(int.parse(named.group(2)!), month);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Reset all per-map ephemeral state. Called at the start of
  /// [loadFromAdapter] so that opening a different map does not retain
  /// cloud overlays (distributor movements, letter boxes), selection,
  /// info windows or in-progress drawing from the previously open map.
  void _resetPerMapState() {
    // Cloud overlays — discard fully so the new map fetches fresh data.
    _cloudTracksLayers.clear();
    _cloudWaypointsLayers.clear();
    _loadedCloudTrackFolders.clear();
    _loadedCloudWaypointFolders.clear();
    _loadingCloudTrackFolders.clear();
    _loadingCloudWaypointFolders.clear();

    // Selection / overlays
    _selectedElementId = null;
    _infoWindowData = null;

    // Drawing / editing
    _drawingMode = DrawingMode.none;
    _isDrawing = false;
    _drawingPoints.clear();
    _drawingToUnfinished = false;
    _isEditingVertices = false;
    _isEditingPolygon = false;
    _editingElementId = null;
    _editingPoints = null;
    _isLassoSelectActive = false;
    _lassoPoints.clear();
    _isWorkAreaPickerVisible = false;
    _hasUnsavedChanges = false;
  }

  /// Link a cloud storage folder to this map.
  /// Also ensures a "Target Areas" persisted layer exists.
  void linkCloudFolder(String folderPath) {
    addCloudFolderLink(folderPath, loadNow: true);
  }

  void addCloudFolderLink(String folderPath, {bool loadNow = false}) {
    if (_currentMap == null) return;
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleanPath.isEmpty) return;

    final folders = List<String>.from(linkedCloudFolders);
    if (!folders.contains(cleanPath)) folders.add(cleanPath);
    _currentMap = _currentMap!.copyWith(
      storageFolderPath: folders.first,
      cloudFolderPaths: List.unmodifiable(folders),
    );

    // Ensure a persisted "Target Areas" layer exists
    final hasTargetAreas =
        _currentMap!.layers.any((l) => l.name == _targetAreasLayerName);
    if (!hasTargetAreas) {
      // Rename existing first layer or create a new one
      if (_currentMap!.layers.isNotEmpty) {
        final first = _currentMap!.layers.first;
        if (first.name == 'Layer 1' && first.elementCount == 0) {
          _currentMap = _currentMap!.updateLayer(
              first.id, first.copyWith(name: _targetAreasLayerName));
        } else {
          _currentMap = _currentMap!.addLayer(MapLayer.create(
            name: _targetAreasLayerName,
            order: 0,
            defaultColor: Colors.green,
          ));
        }
      } else {
        _currentMap = _currentMap!.addLayer(MapLayer.create(
          name: _targetAreasLayerName,
          order: 0,
          defaultColor: Colors.green,
        ));
      }
    }

    _initCloudOverlays();
    _notifyAndSave();
    debugPrint('Linked cloud folder: $cleanPath');

    if (loadNow) {
      Future.microtask(() async {
        if (_isDisposed) return;
        await loadCloudFolderTracks(folderPath: cleanPath, force: true);
        if (_isDisposed) return;
        await loadCloudFolderWaypoints(folderPath: cleanPath, force: true);
      });
    }
  }

  /// Unlink one cloud storage folder, or all folders when [folderPath] is null.
  void unlinkCloudFolder([String? folderPath]) {
    if (_currentMap == null) return;
    final removeAll = folderPath == null || folderPath.trim().isEmpty;
    final cleanPath = folderPath?.trim().replaceAll(RegExp(r'/+$'), '');
    final folders = removeAll
        ? <String>[]
        : linkedCloudFolders.where((p) => p != cleanPath).toList();
    final trackColors = Map<String, int>.from(_currentMap!.cloudTrackColors);
    if (removeAll) {
      trackColors.clear();
    } else if (cleanPath != null) {
      trackColors.remove(cleanPath);
    }
    _currentMap = _currentMap!.copyWith(
      storageFolderPath: folders.isEmpty ? null : folders.first,
      clearStorageFolderPath: folders.isEmpty,
      cloudFolderPaths: List.unmodifiable(folders),
      cloudTrackColors: trackColors,
    );

    if (removeAll) {
      _cloudTracksLayers.clear();
      _cloudWaypointsLayers.clear();
      _loadedCloudTrackFolders.clear();
      _loadedCloudWaypointFolders.clear();
    } else {
      final trackId = _cloudLayerId('tracks', cleanPath!);
      final waypointId = _cloudLayerId('waypoints', cleanPath);
      _cloudTracksLayers.remove(trackId);
      _cloudWaypointsLayers.remove(waypointId);
      _loadedCloudTrackFolders.remove(cleanPath);
      _loadedCloudWaypointFolders.remove(cleanPath);
    }
    _notifyAndSave();
    debugPrint(
        removeAll ? 'Unlinked all cloud folders' : 'Unlinked $cleanPath');
  }

  void setAutoLoadLatestCloudFolder(bool value) {
    if (_currentMap == null) return;
    _currentMap = _currentMap!.copyWith(autoLoadLatestCloudFolder: value);
    _notifyAndSave();
    if (value && latestLinkedCloudFolder != null) {
      Future.microtask(() {
        if (_isDisposed) return;
        loadCloudFolderTracks(folderPath: latestLinkedCloudFolder);
      });
    }
  }

  void setClipCloudDataToPolygons(bool value) {
    if (_currentMap == null) return;
    if (_currentMap!.clipCloudDataToPolygons == value) return;
    final loadedTracks = List<String>.from(_loadedCloudTrackFolders);
    final loadedWaypoints = List<String>.from(_loadedCloudWaypointFolders);
    _currentMap = _currentMap!.copyWith(clipCloudDataToPolygons: value);
    _notifyAndSave();
    Future.microtask(() async {
      for (final folder in loadedTracks) {
        if (_isDisposed) return;
        await loadCloudFolderTracks(folderPath: folder, force: true);
      }
      for (final folder in loadedWaypoints) {
        if (_isDisposed) return;
        await loadCloudFolderWaypoints(folderPath: folder, force: true);
      }
    });
  }

  /// Download bytes for a list of [StorageFileItem]s in parallel.
  Future<List<_IsolateFileEntry>> _downloadFilesParallel(
    GpxStorageService storage,
    List<StorageFileItem> files,
  ) async {
    final futures = files.map((f) async {
      try {
        final bytes = await storage.downloadFileBytes(f.fullPath);
        if (bytes == null) return null;
        return _IsolateFileEntry(bytes, f.name);
      } catch (e) {
        debugPrint('Failed to download ${f.name}: $e');
        return null;
      }
    });
    final results = await Future.wait(futures);
    return results.whereType<_IsolateFileEntry>().toList();
  }

  /// Load all track GPX files from the linked cloud folder.
  ///
  /// Guarded so it only runs once per map-open. Cloud layers are ephemeral
  /// overlays — never written to Firestore.
  ///
  /// Tries to download a pre-compiled `_compiled_tracks.json` first (single
  /// small file produced by the Cloud Function). Falls back to downloading
  /// and parsing individual GPX files if the compiled file doesn't exist yet.
  Future<void> loadCloudFolderTracks(
      {String? folderPath, bool force = false}) async {
    final resolvedFolderPath = (folderPath ?? latestLinkedCloudFolder)
        ?.trim()
        .replaceAll(RegExp(r'/+$'), '');
    if (resolvedFolderPath == null || resolvedFolderPath.isEmpty) return;
    if (_loadingCloudTrackFolders.contains(resolvedFolderPath)) return;
    if (_loadedCloudTrackFolders.contains(resolvedFolderPath) && !force) return;
    if (force) _loadedCloudTrackFolders.remove(resolvedFolderPath);

    _loadingCloudTrackFolders.add(resolvedFolderPath);
    _initCloudOverlays();
    notifyListeners();
    final sw = Stopwatch()..start();
    debugPrint('[CloudTracks] START folder=$resolvedFolderPath');

    try {
      final storage = GpxStorageService();

      // ── Try compiled JSON first (fast path) ──
      final compiledBytes = await storage
          .downloadFileBytes('$resolvedFolderPath/_compiled_tracks.json');
      if (compiledBytes != null) {
        debugPrint(
            '[CloudTracks] compiled JSON downloaded in ${sw.elapsedMilliseconds}ms (${(compiledBytes.length / 1024).toStringAsFixed(1)}KB)');
        final polylines = await compute(_parseCompiledTracks, compiledBytes);
        debugPrint(
            '[CloudTracks] parsed ${polylines.length} tracks from compiled JSON in ${sw.elapsedMilliseconds}ms');

        final clippedPolylines = _applyCloudTrackColorToPolylines(
          resolvedFolderPath,
          _clipCloudDataToPolygons(polylines),
        );
        final layerId = _cloudLayerId('tracks', resolvedFolderPath);
        var layer = _cloudTracksLayers[layerId] ??
            _cloudTrackLayerShell(resolvedFolderPath, order: 900);
        layer = layer.copyWith(
          defaultColor: cloudTrackColorForFolder(resolvedFolderPath),
          polylines: clippedPolylines,
        );
        _cloudTracksLayers[layerId] = layer;
        _loadedCloudTrackFolders.add(resolvedFolderPath);
        debugPrint(
            '[CloudTracks] DONE (compiled) in ${sw.elapsedMilliseconds}ms — ${clippedPolylines.length}/${polylines.length} tracks');
        _loadingCloudTrackFolders.remove(resolvedFolderPath);
        notifyListeners();
        return;
      }

      debugPrint(
          '[CloudTracks] no compiled JSON, falling back to individual GPX files');

      // ── Fallback: download individual GPX files ──
      final contents = await storage.listFolderContents(resolvedFolderPath);
      debugPrint(
          '[CloudTracks] listFolderContents in ${sw.elapsedMilliseconds}ms');

      final trackFiles = contents.files
          .where((f) =>
              f.extension == 'gpx' &&
              !f.name.toLowerCase().contains('waypoint'))
          .toList();

      if (trackFiles.isEmpty) {
        debugPrint('[CloudTracks] no track files found');
        _loadedCloudTrackFolders.add(resolvedFolderPath);
        _loadingCloudTrackFolders.remove(resolvedFolderPath);
        notifyListeners();
        return;
      }

      debugPrint('[CloudTracks] downloading ${trackFiles.length} GPX files...');
      final downloaded = await _downloadFilesParallel(storage, trackFiles);
      debugPrint(
          '[CloudTracks] downloaded ${downloaded.length} files in ${sw.elapsedMilliseconds}ms');
      if (downloaded.isEmpty) {
        _loadedCloudTrackFolders.add(resolvedFolderPath);
        _loadingCloudTrackFolders.remove(resolvedFolderPath);
        notifyListeners();
        return;
      }

      final result = await compute(
        _parseGpxInIsolate,
        _IsolateParseInput(downloaded),
      );
      debugPrint(
          '[CloudTracks] parsed in isolate in ${sw.elapsedMilliseconds}ms');

      final layerId = _cloudLayerId('tracks', resolvedFolderPath);
      var layer = _cloudTracksLayers[layerId] ??
          _cloudTrackLayerShell(resolvedFolderPath, order: 900);

      layer = layer.copyWith(
        defaultColor: cloudTrackColorForFolder(resolvedFolderPath),
        polylines: _applyCloudTrackColorToPolylines(
          resolvedFolderPath,
          _clipCloudDataToPolygons(result.polylines),
        ),
        points: _applyCloudTrackColorToPoints(
          resolvedFolderPath,
          _clipCloudPointsToPolygons(result.points),
        ),
      );

      _cloudTracksLayers[layerId] = layer;
      _loadedCloudTrackFolders.add(resolvedFolderPath);
      debugPrint(
          '[CloudTracks] DONE (fallback) in ${sw.elapsedMilliseconds}ms — '
          '${result.polylines.length} polylines from ${downloaded.length} files');
    } catch (e) {
      debugPrint('[CloudTracks] FAILED at ${sw.elapsedMilliseconds}ms: $e');
    }

    _loadingCloudTrackFolders.remove(resolvedFolderPath);
    notifyListeners();
  }

  /// Load all waypoint GPX files from the linked cloud folder.
  /// Called on-demand by the user (never auto-loaded).
  ///
  /// Tries compiled `_compiled_waypoints.json` first, falls back to GPX.
  Future<void> loadCloudFolderWaypoints(
      {String? folderPath, bool force = false}) async {
    final resolvedFolderPath = (folderPath ?? latestLinkedCloudFolder)
        ?.trim()
        .replaceAll(RegExp(r'/+$'), '');
    if (resolvedFolderPath == null || resolvedFolderPath.isEmpty) return;
    if (_loadingCloudWaypointFolders.contains(resolvedFolderPath)) return;
    if (_loadedCloudWaypointFolders.contains(resolvedFolderPath) && !force) {
      return;
    }
    if (force) _loadedCloudWaypointFolders.remove(resolvedFolderPath);

    _loadingCloudWaypointFolders.add(resolvedFolderPath);
    _initCloudOverlays();
    notifyListeners();
    final sw = Stopwatch()..start();
    debugPrint('[CloudWaypoints] START folder=$resolvedFolderPath');

    try {
      final storage = GpxStorageService();

      // ── Try compiled JSON first (fast path) ──
      final compiledBytes = await storage
          .downloadFileBytes('$resolvedFolderPath/_compiled_waypoints.json');
      if (compiledBytes != null) {
        debugPrint(
            '[CloudWaypoints] compiled JSON downloaded in ${sw.elapsedMilliseconds}ms (${(compiledBytes.length / 1024).toStringAsFixed(1)}KB)');
        final points = await compute(_parseCompiledWaypoints, compiledBytes);
        debugPrint(
            '[CloudWaypoints] parsed ${points.length} waypoints from compiled JSON in ${sw.elapsedMilliseconds}ms');

        final clippedPoints = _clipCloudPointsToPolygons(points);
        final layerId = _cloudLayerId('waypoints', resolvedFolderPath);
        var layer = _cloudWaypointsLayers[layerId] ??
            _cloudWaypointLayerShell(resolvedFolderPath, order: 901);
        layer = layer.copyWith(
          points: clippedPoints,
        );
        _cloudWaypointsLayers[layerId] = layer;
        _loadedCloudWaypointFolders.add(resolvedFolderPath);
        debugPrint(
            '[CloudWaypoints] DONE (compiled) in ${sw.elapsedMilliseconds}ms — ${clippedPoints.length}/${points.length} waypoints');
        _loadingCloudWaypointFolders.remove(resolvedFolderPath);
        notifyListeners();
        return;
      }

      debugPrint(
          '[CloudWaypoints] no compiled JSON, falling back to individual GPX files');

      // ── Fallback: download individual GPX files ──
      final contents = await storage.listFolderContents(resolvedFolderPath);

      final waypointFiles = contents.files
          .where((f) =>
              f.extension == 'gpx' && f.name.toLowerCase().contains('waypoint'))
          .toList();

      if (waypointFiles.isEmpty) {
        debugPrint('[CloudWaypoints] no waypoint files found');
        _loadedCloudWaypointFolders.add(resolvedFolderPath);
        _loadingCloudWaypointFolders.remove(resolvedFolderPath);
        notifyListeners();
        return;
      }

      debugPrint(
          '[CloudWaypoints] downloading ${waypointFiles.length} GPX files...');
      final downloaded = await _downloadFilesParallel(storage, waypointFiles);
      debugPrint(
          '[CloudWaypoints] downloaded ${downloaded.length} files in ${sw.elapsedMilliseconds}ms');
      if (downloaded.isEmpty) {
        _loadedCloudWaypointFolders.add(resolvedFolderPath);
        _loadingCloudWaypointFolders.remove(resolvedFolderPath);
        notifyListeners();
        return;
      }

      final result = await compute(
        _parseGpxInIsolate,
        _IsolateParseInput(downloaded),
      );

      final layerId = _cloudLayerId('waypoints', resolvedFolderPath);
      var layer = _cloudWaypointsLayers[layerId] ??
          _cloudWaypointLayerShell(resolvedFolderPath, order: 901);

      layer = layer.copyWith(
        points: _clipCloudPointsToPolygons(result.points),
      );

      _cloudWaypointsLayers[layerId] = layer;
      _loadedCloudWaypointFolders.add(resolvedFolderPath);
      debugPrint(
          '[CloudWaypoints] DONE (fallback) in ${sw.elapsedMilliseconds}ms — '
          '${result.points.length} points from ${downloaded.length} files');
    } catch (e) {
      debugPrint('[CloudWaypoints] FAILED at ${sw.elapsedMilliseconds}ms: $e');
    }

    _loadingCloudWaypointFolders.remove(resolvedFolderPath);
    notifyListeners();
  }

  List<List<LatLng>> _cloudClipPolygons() {
    if (!clipCloudDataToPolygons || _currentMap == null) {
      return const [];
    }
    final polygons = <List<LatLng>>[];
    for (final layer in _currentMap!.layers) {
      for (final polygon in layer.polygons) {
        if (polygon.isPolygon && polygon.points.length >= 3) {
          polygons.add(polygon.points);
        }
      }
    }
    return polygons;
  }

  bool _isInsideAnyClipPolygon(LatLng point, List<List<LatLng>> polygons) {
    for (final polygon in polygons) {
      if (_pointInPolygon(point, polygon)) return true;
    }
    return false;
  }

  List<MapPoint> _clipCloudPointsToPolygons(List<MapPoint> points) {
    final polygons = _cloudClipPolygons();
    if (polygons.isEmpty) return points;
    return points
        .where((point) => _isInsideAnyClipPolygon(point.position, polygons))
        .toList();
  }

  List<MapPolyline> _clipCloudDataToPolygons(List<MapPolyline> polylines) {
    final polygons = _cloudClipPolygons();
    if (polygons.isEmpty) return polylines;

    final clipped = <MapPolyline>[];
    final now = DateTime.now();
    int segmentSeq = 0;

    for (final polyline in polylines) {
      final segment = <LatLng>[];

      void flushSegment() {
        if (segment.length < 2) {
          segment.clear();
          return;
        }
        clipped.add(MapPolyline(
          id: '${polyline.id}_clip_${segmentSeq++}',
          name: polyline.name,
          description: polyline.description,
          points: List<LatLng>.from(segment),
          color: polyline.color,
          strokeWidth: polyline.strokeWidth,
          isDashed: polyline.isDashed,
          createdAt: now,
          updatedAt: now,
        ));
        segment.clear();
      }

      for (final point in polyline.points) {
        if (_isInsideAnyClipPolygon(point, polygons)) {
          segment.add(point);
        } else {
          flushSegment();
        }
      }
      flushSegment();
    }

    return clipped;
  }

  /// Save the current map state via the active adapter.
  ///
  /// Returns true if save succeeded, false otherwise.
  /// No-op if no adapter is set.
  ///
  /// When [captureThumbnail] is true (default for explicit saves), a
  /// screenshot of the current map view is taken and uploaded as the
  /// gallery preview image. Auto-saves skip the thumbnail capture to
  /// avoid excessive uploads.
  Future<bool> saveToAdapter({bool captureThumbnail = false}) async {
    if (_adapter == null || _currentMap == null) return false;

    _isSaving = true;
    notifyListeners();

    try {
      // Mark the timestamp so we can ignore the echoed snapshot
      _lastSaveTimestamp = DateTime.now().millisecondsSinceEpoch;
      await _adapter!.save(_currentMap!);

      // If this was the first save of a new map, start listening now
      final adapter = _adapter;
      if (adapter is FirestoreMapAdapter &&
          !adapter.isListening &&
          adapter.docId != null) {
        _startRealtimeSync(adapter);
      }

      // Capture & upload thumbnail (fire-and-forget, non-blocking)
      if (captureThumbnail && adapter is FirestoreMapAdapter) {
        _captureThumbnailAsync(adapter);
      }

      debugPrint('Saved map via adapter: ${_adapter!.adapterId}');
      return true;
    } catch (e) {
      debugPrint('Failed to save via adapter ${_adapter!.adapterId}: $e');
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  /// Generate a Static Maps thumbnail image, upload it to Firebase Storage,
  /// and persist the Storage download URL on the Firestore document.
  /// Runs as fire-and-forget so it never blocks the save flow or UI.
  Future<void> _captureThumbnailAsync(FirestoreMapAdapter adapter) async {
    try {
      if (_currentMap == null) return;
      final docId = adapter.docId;
      if (docId == null) return;

      final map = _currentMap!;
      final bounds = map.getBounds();

      // Gather polygon/polyline data with actual colors from visible layers.
      final polygons = <ThumbnailPathData>[];
      final polylines = <ThumbnailPathData>[];
      for (final layer in map.visibleLayersSorted) {
        for (final polygon in layer.polygons) {
          if (polygon.points.isNotEmpty) {
            polygons.add(ThumbnailPathData(
              points: polygon.points,
              color: polygon.color,
              fillOpacity: polygon.fillOpacity,
            ));
          }
        }
        for (final polyline in layer.polylines) {
          if (polyline.points.isNotEmpty) {
            polylines.add(ThumbnailPathData(
              points: polyline.points,
              color: polyline.color,
            ));
          }
        }
      }

      // Include visible cloud tracks in the thumbnail.
      // Limit to avoid exceeding Static Maps API URL length.
      for (final cloudLayer in _cloudTracksLayers.values) {
        if (!cloudLayer.isVisible) continue;
        for (final polyline in cloudLayer.polylines) {
          if (polyline.points.isEmpty) continue;
          polylines.add(ThumbnailPathData(
            points: polyline.points,
            color: polyline.color,
          ));
        }
      }
      // Cap total polylines so the Static Maps URL stays under the limit.
      const maxPolylines = 15;
      if (polylines.length > maxPolylines) {
        polylines.removeRange(maxPolylines, polylines.length);
      }

      final thumbnailService = MapThumbnailService();
      final url = await thumbnailService.generateAndUploadThumbnail(
        monthKey: adapter.monthKey,
        docId: docId,
        center: map.defaultCenter,
        zoom: map.defaultZoom,
        bounds: bounds,
        polygons: polygons.isNotEmpty ? polygons : null,
        polylines: polylines.isNotEmpty ? polylines : null,
      );

      if (url != null && !_isDisposed && _currentMap != null) {
        // Persist the Storage URL on the Firestore document.
        final firestoreService = ShareableMapsFirestoreService();
        await firestoreService.updateMapFields(
          adapter.monthKey,
          docId,
          {'thumbnailUrl': url},
        );

        if (_isDisposed || _currentMap == null) return;
        // Update local state so the gallery picks it up.
        _currentMap = _currentMap!.copyWith(thumbnailUrl: url);
        debugPrint('[Thumbnail] Updated thumbnail for $docId');
      }
    } catch (e) {
      // Non-fatal — thumbnail is a nice-to-have.
      debugPrint('[Thumbnail] Generation failed (non-fatal): $e');
    }
  }

  /// Clear the active adapter and reset to standalone mode.
  Future<void> clearAdapter() async {
    await _stopRealtimeSync();
    await _adapter?.dispose();
    _adapter = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Real-time sync & auto-save
  // ---------------------------------------------------------------------------

  /// Start listening to Firestore snapshot changes for this map.
  void _startRealtimeSync(FirestoreMapAdapter adapter) {
    _stopRealtimeSync(); // clean up any previous listener

    final stream = adapter.startListening();
    if (stream == null) return;

    _realtimeSubscription = stream.listen((remoteMap) {
      if (remoteMap == null) return; // document deleted

      // Skip echoed snapshots from our own saves.
      // If the remote updatedAt matches what we just wrote, ignore it.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSaveTimestamp < 3000) {
        // Within 3 seconds of our last save — likely our own echo.
        // Compare updatedAt to see if it's genuinely different content.
        if (_currentMap != null &&
            remoteMap.updatedAt.millisecondsSinceEpoch ==
                _currentMap!.updatedAt.millisecondsSinceEpoch) {
          return;
        }
        // If updatedAt differs but we saved very recently, still skip
        // because the snapshot is from our own write propagating.
        if (now - _lastSaveTimestamp < 1500) return;
      }

      // Don't apply remote changes while the user is actively drawing
      if (_isDrawing || _isEditingVertices) return;

      // Apply the remote update
      debugPrint(
          '[RealtimeSync] Remote update received for map ${remoteMap.id}');
      _applyRemoteMap(remoteMap);
    });

    debugPrint('[RealtimeSync] Started listening for map ${adapter.docId}');
  }

  /// Apply a remote map update, preserving local UI state.
  void _applyRemoteMap(ShareableMap remoteMap) {
    final previousSelectedLayerId = _selectedLayerId;

    _currentMap = remoteMap;

    // Restore selected layer if it still exists
    if (previousSelectedLayerId != null &&
        remoteMap.layers.any((l) => l.id == previousSelectedLayerId)) {
      _selectedLayerId = previousSelectedLayerId;
    } else if (remoteMap.layers.isNotEmpty) {
      _selectedLayerId = remoteMap.layers.first.id;
    }

    _initCloudOverlays();

    notifyListeners();
  }

  /// Stop the real-time Firestore listener and cancel any pending
  /// auto-save / thumbnail timers. Awaiting the returned future ensures the
  /// underlying StreamSubscription has fully closed before a new listener
  /// is attached (prevents overlapping listeners during rapid map switches).
  Future<void> _stopRealtimeSync() async {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _thumbnailTimer?.cancel();
    _thumbnailTimer = null;
    final sub = _realtimeSubscription;
    _realtimeSubscription = null;
    await sub?.cancel();
  }

  /// Schedule a debounced auto-save. Each call resets the timer.
  ///
  /// This is called after map-mutating operations so that changes
  /// propagate to Firestore (and thus to other viewers) without
  /// requiring the user to press Save manually.
  void _scheduleAutoSave() {
    if (_isDisposed || _adapter == null || _currentMap == null) return;

    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_autoSaveDelay, () {
      if (_isDisposed || _adapter == null || _currentMap == null) return;
      saveToAdapter();
      _scheduleThumbnailCapture();
    });
  }

  /// Schedule a debounced thumbnail capture after auto-saves settle.
  /// Resets on each auto-save so it only captures once editing pauses.
  void _scheduleThumbnailCapture() {
    if (_isDisposed || _adapter == null || _adapter is! FirestoreMapAdapter) {
      return;
    }
    _thumbnailTimer?.cancel();
    _thumbnailTimer = Timer(_thumbnailDelay, () {
      if (_isDisposed) return;
      final adapter = _adapter;
      if (adapter is FirestoreMapAdapter) {
        _captureThumbnailAsync(adapter);
      }
    });
  }

  /// Notify listeners AND schedule a debounced auto-save.
  ///
  /// Call this instead of plain [notifyListeners] in methods that mutate
  /// the map data (polygons, layers, etc.) so that changes propagate to
  /// Firestore and are received in real-time by other viewers.
  void _notifyMapChanged() {
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  /// Notify listeners AND persist to the database.
  ///
  /// Call this only at meaningful completion points — e.g. after
  /// completing a drawing, exiting vertex editing, deleting an element,
  /// or updating properties — to minimise Firestore read/write counts.
  void _notifyAndSave() {
    _hasUnsavedChanges = true;
    notifyListeners();
    _scheduleAutoSave();
  }

  // === MAP OPERATIONS ===

  /// Initialize a new map
  void createNewMap({
    required String name,
    String description = '',
    LatLng? center,
  }) {
    _currentMap = ShareableMap.createWithDefaultLayer(
      name: name,
      description: description,
      defaultCenter: center,
    );
    _selectedLayerId = _currentMap!.layers.first.id;
    debugPrint('Created new map: ${_currentMap!.name}');
    notifyListeners();
  }

  /// Load an existing map
  void loadMap(ShareableMap map) {
    _currentMap = map;
    if (map.layers.isNotEmpty) {
      _selectedLayerId = map.layers.first.id;
    }
    _drawingMode = DrawingMode.none;
    _clearDrawingState();
    debugPrint('Loaded map: ${map.name}');
    notifyListeners();
  }

  /// Clear current map
  void clearMap() {
    _currentMap = null;
    _selectedLayerId = null;
    _selectedElementId = null;
    _drawingMode = DrawingMode.none;
    _clearDrawingState();
    debugPrint('Cleared map');
    notifyListeners();
  }

  /// Update map metadata
  void updateMapMetadata({String? name, String? description}) {
    if (_currentMap == null) return;
    _currentMap = _currentMap!.copyWith(
      name: name,
      description: description,
    );
    _notifyAndSave();
  }

  // === WORK AREA IMPORT ===

  /// Add a work area polygon to the map as a new polygon in a dedicated
  /// "Work Areas" layer. Creates the layer if it doesn't exist yet.
  void addWorkAreaToMap(WorkArea workArea, {Color? color}) {
    if (_currentMap == null) return;

    const workAreaLayerId = 'imported_work_areas';

    // Find or create the "Work Areas" import layer
    var layer = _currentMap!.getLayer(workAreaLayerId);
    if (layer == null) {
      layer = MapLayer(
        id: workAreaLayerId,
        name: 'Work Areas',
        description: 'Imported from work area collection',
        order: _currentMap!.layers.length,
        defaultColor: Colors.orange,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      _currentMap = _currentMap!.addLayer(layer);
    }

    // Check if this work area was already added (by name match)
    final alreadyExists = layer.polygons.any((p) => p.name == workArea.name);
    if (alreadyExists) return;

    // Convert WorkArea to CustomPolygon and add it
    final polygon = CustomPolygon(
      name: workArea.name,
      description: workArea.description,
      points: List<LatLng>.from(workArea.polygonPoints),
      color: color ?? Colors.orange,
      fillOpacity: 0.25,
      strokeWidth: 2,
      letterBoxEstimate: workArea.letterBoxEstimate,
    );

    final updatedLayer = layer.addPolygon(polygon);
    _currentMap = _currentMap!.updateLayer(workAreaLayerId, updatedLayer);
    debugPrint('Added work area to map: ${workArea.name}');
    _notifyAndSave();
  }

  /// Remove a previously imported work area polygon by name.
  void removeWorkAreaFromMap(String workAreaName) {
    if (_currentMap == null) return;

    const workAreaLayerId = 'imported_work_areas';
    final layer = _currentMap!.getLayer(workAreaLayerId);
    if (layer == null) return;

    final index = layer.polygons.indexWhere((p) => p.name == workAreaName);
    if (index == -1) return;

    final updatedLayer = layer.removePolygon(index);
    _currentMap = _currentMap!.updateLayer(workAreaLayerId, updatedLayer);

    // If the layer is now empty, remove it entirely
    if (updatedLayer.polygons.isEmpty) {
      _currentMap = _currentMap!.removeLayer(workAreaLayerId);
    }

    debugPrint('Removed work area from map: $workAreaName');
    _notifyAndSave();
  }

  /// Check whether a work area (by name) has been imported.
  bool isWorkAreaImported(String workAreaName) {
    if (_currentMap == null) return false;
    const workAreaLayerId = 'imported_work_areas';
    final layer = _currentMap!.getLayer(workAreaLayerId);
    if (layer == null) return false;
    return layer.polygons.any((p) => p.name == workAreaName);
  }

  // === SUBURB IMPORT ===

  static const _suburbLayerId = 'imported_suburbs';

  /// Add a suburb polygon to the map as a new polygon in a dedicated
  /// "Suburbs" layer. Creates the layer if it doesn't exist yet.
  void addSuburbToMap(WorkSuburb suburb) {
    if (_currentMap == null) return;

    var layer = _currentMap!.getLayer(_suburbLayerId);
    if (layer == null) {
      layer = MapLayer(
        id: _suburbLayerId,
        name: 'Suburbs',
        description: 'Imported from suburb collection',
        order: _currentMap!.layers.length,
        defaultColor: Colors.green,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      _currentMap = _currentMap!.addLayer(layer);
    }

    final alreadyExists = layer.polygons.any((p) => p.name == suburb.name);
    if (alreadyExists) return;

    final polygon = CustomPolygon(
      name: suburb.name,
      description: suburb.description,
      points: List<LatLng>.from(suburb.polygonPoints),
      color: Colors.green,
      fillOpacity: 0.25,
      strokeWidth: 2,
      letterBoxEstimate: suburb.letterBoxEstimate,
    );

    final updatedLayer = layer.addPolygon(polygon);
    _currentMap = _currentMap!.updateLayer(_suburbLayerId, updatedLayer);
    debugPrint('Added suburb to map: ${suburb.name}');
    _notifyAndSave();
  }

  /// Remove a previously imported suburb polygon by name.
  void removeSuburbFromMap(String suburbName) {
    if (_currentMap == null) return;

    final layer = _currentMap!.getLayer(_suburbLayerId);
    if (layer == null) return;

    final index = layer.polygons.indexWhere((p) => p.name == suburbName);
    if (index == -1) return;

    final updatedLayer = layer.removePolygon(index);
    _currentMap = _currentMap!.updateLayer(_suburbLayerId, updatedLayer);

    if (updatedLayer.polygons.isEmpty) {
      _currentMap = _currentMap!.removeLayer(_suburbLayerId);
    }

    debugPrint('Removed suburb from map: $suburbName');
    _notifyAndSave();
  }

  /// Check whether a suburb (by name) has been imported.
  bool isSuburbImported(String suburbName) {
    if (_currentMap == null) return false;
    final layer = _currentMap!.getLayer(_suburbLayerId);
    if (layer == null) return false;
    return layer.polygons.any((p) => p.name == suburbName);
  }

  /// Add multiple suburbs to the map at once.
  void addSuburbsToMap(List<WorkSuburb> suburbs) {
    for (final s in suburbs) {
      addSuburbToMap(s);
    }
  }

  // === LAYER OPERATIONS ===

  /// Create a new layer
  void createLayer({
    required String name,
    String description = '',
    Color? color,
  }) {
    if (_currentMap == null) return;

    final newLayer = MapLayer.create(
      name: name,
      description: description,
      order: _currentMap!.layers.length,
      defaultColor: color ?? _getNextLayerColor(),
    );

    _currentMap = _currentMap!.addLayer(newLayer);
    _selectedLayerId = newLayer.id;
    debugPrint('Created layer: $name');
    _notifyAndSave();
  }

  /// Delete a layer
  void deleteLayer(String layerId) {
    if (_currentMap == null) return;

    _currentMap = _currentMap!.removeLayer(layerId);

    // Select another layer if we deleted the selected one
    if (_selectedLayerId == layerId) {
      _selectedLayerId =
          _currentMap!.layers.isNotEmpty ? _currentMap!.layers.first.id : null;
    }

    debugPrint('Deleted layer: $layerId');
    _notifyAndSave();
  }

  /// Update layer metadata
  void updateLayer({
    required String layerId,
    String? name,
    String? description,
    Color? color,
    bool applyColorToPolygons = false,
    bool applyColorToPolylines = false,
    bool applyMarkerCategory = false,
    PointCategory? markerCategory,
  }) {
    if (_currentMap == null) return;

    final layer = _currentMap!.getLayer(layerId);
    if (layer == null) return;

    final shouldUpdatePolygonEntries =
        (color != null && (applyColorToPolygons || applyColorToPolylines)) ||
            (applyMarkerCategory && markerCategory != null);
    final updatedPolygonEntries = shouldUpdatePolygonEntries
        ? layer.polygons.map((polygon) {
            var updated = polygon;
            if (color != null && applyColorToPolygons && polygon.isPolygon) {
              updated = updated.copyWith(color: color);
            }
            if (color != null && applyColorToPolylines && polygon.isPolyline) {
              updated = updated.copyWith(color: color);
            }
            if (applyMarkerCategory &&
                markerCategory != null &&
                polygon.isMarker) {
              updated = updated.copyWith(
                color: markerCategory.color,
                pointCategory: markerCategory,
              );
            }
            return updated;
          }).toList()
        : null;

    final updatedPolylines = color != null && applyColorToPolylines
        ? layer.polylines
            .map((polyline) => polyline.copyWith(color: color))
            .toList()
        : null;

    final updatedPoints = applyMarkerCategory && markerCategory != null
        ? layer.points
            .map((point) => point.copyWith(
                  color: markerCategory.color,
                  pointCategory: markerCategory,
                ))
            .toList()
        : null;

    final updatedLayer = layer.copyWith(
      name: name,
      description: description,
      defaultColor: color,
      polygons: updatedPolygonEntries,
      polylines: updatedPolylines,
      points: updatedPoints,
    );

    _currentMap = _currentMap!.updateLayer(layerId, updatedLayer);
    debugPrint('Updated layer: ${updatedLayer.name}');
    _notifyAndSave();
  }

  /// Toggle layer visibility
  void toggleLayerVisibility(String layerId) {
    if (_currentMap == null) return;
    // Ignore rapid repeat taps while the previous toggle is still being
    // applied to the GoogleMap widget (the JS-side marker diff for large
    // layers can take 100-300ms).
    if (_togglingLayers.contains(layerId)) return;
    _togglingLayers.add(layerId);
    Timer(_toggleCooldown, () {
      if (_isDisposed) return;
      if (_togglingLayers.remove(layerId)) {
        notifyListeners();
      }
    });

    // Handle cloud overlay layers
    if (_cloudTracksLayers.containsKey(layerId)) {
      final layer = _cloudTracksLayers[layerId]!;
      final nowVisible = !layer.isVisible;
      _cloudTracksLayers[layerId] = layer.copyWith(
        isVisible: nowVisible,
        isExpanded: nowVisible ? layer.isExpanded : false,
      );
      notifyListeners();
      return;
    }
    if (_cloudWaypointsLayers.containsKey(layerId)) {
      final layer = _cloudWaypointsLayers[layerId]!;
      final nowVisible = !layer.isVisible;
      _cloudWaypointsLayers[layerId] = layer.copyWith(
        isVisible: nowVisible,
        isExpanded: nowVisible ? layer.isExpanded : false,
      );
      notifyListeners();
      return;
    }
    _currentMap = _currentMap!.toggleLayerVisibility(layerId);
    debugPrint('Toggled visibility for layer: $layerId');
    _notifyMapChanged();
  }

  /// Toggle layer expanded state
  void toggleLayerExpanded(String layerId) {
    if (_currentMap == null) return;
    if (_cloudTracksLayers.containsKey(layerId)) {
      final layer = _cloudTracksLayers[layerId]!;
      _cloudTracksLayers[layerId] =
          layer.copyWith(isExpanded: !layer.isExpanded);
      notifyListeners();
      return;
    }
    if (_cloudWaypointsLayers.containsKey(layerId)) {
      final layer = _cloudWaypointsLayers[layerId]!;
      _cloudWaypointsLayers[layerId] =
          layer.copyWith(isExpanded: !layer.isExpanded);
      notifyListeners();
      return;
    }
    _currentMap = _currentMap!.toggleLayerExpanded(layerId);
    notifyListeners();
  }

  /// Select a layer
  void selectLayer(String layerId) {
    _selectedLayerId = layerId;
    _selectedElementId = null;
    debugPrint('Selected layer: $layerId');
    notifyListeners();
  }

  /// Reorder layers
  void reorderLayers(int oldIndex, int newIndex) {
    if (_currentMap == null) return;
    _currentMap = _currentMap!.reorderLayers(oldIndex, newIndex);
    debugPrint('Reordered layers: $oldIndex -> $newIndex');
    _notifyAndSave();
  }

  // === DRAWING MODE ===

  /// Set drawing mode
  void setDrawingMode(DrawingMode mode) {
    _drawingMode = mode;
    if (mode != DrawingMode.edit) {
      _editingPoints = null;
      _hasUnsavedChanges = false;
    }
    if (mode != DrawingMode.none) {
      _selectedElementId = null;
    }
    // Set flag to ignore next tap when switching to a drawing mode
    if (mode == DrawingMode.polygon ||
        mode == DrawingMode.polyline ||
        mode == DrawingMode.point) {
      _ignoreNextTap = true;
    }
    debugPrint('Drawing mode: $mode');
    notifyListeners();
  }

  /// Start polygon drawing mode and flag that the completed polygon should
  /// also be saved to the unfinished work areas list.
  void startDrawingForUnfinished() {
    _drawingToUnfinished = true;
    setDrawingMode(DrawingMode.polygon);
  }

  /// Check and consume the ignore next tap flag
  bool shouldIgnoreNextTap() {
    if (_ignoreNextTap) {
      _ignoreNextTap = false;
      debugPrint('Ignoring first tap after mode change');
      return true;
    }
    return false;
  }

  /// Mark that the next tap should be ignored (e.g. after button press)
  void markIgnoreNextTap() {
    _ignoreNextTap = true;
    debugPrint('⏭️ Next tap will be ignored');
  }

  /// Start drawing
  void startDrawing() {
    _isDrawing = true;
    _drawingPoints.clear();
    debugPrint('Started drawing');
    notifyListeners();
  }

  /// Add point to current drawing.
  ///
  /// Adds a point to the current drawing. The polygon is only completed
  /// when the user taps the first marker or presses the Complete button.
  void addDrawingPoint(LatLng point) {
    debugPrint('[WASM-DEBUG] addDrawingPoint called: '
        'isDrawing=$_isDrawing isDialogOpen=$_isDialogOpen '
        'mode=$_drawingMode currentPoints=${_drawingPoints.length} '
        'point=(${point.latitude.toStringAsFixed(5)},'
        '${point.longitude.toStringAsFixed(5)})');
    if (!_isDrawing) {
      debugPrint('[WASM-DEBUG] addDrawingPoint BAIL — isDrawing=false');
      return;
    }
    if (_isDialogOpen) {
      debugPrint('⛔ Blocked drawing point - dialog is open');
      return;
    }

    _drawingPoints.add(point);
    debugPrint(
        '[WASM-DEBUG] Added drawing point: total=${_drawingPoints.length}');
    notifyListeners();
  }

  /// Set dialog open state to block drawing
  void setDialogOpen(bool isOpen) {
    if (_isDialogOpen == isOpen) return;
    _isDialogOpen = isOpen;
    debugPrint('📝 Dialog open state: $isOpen');
    // Notify so any widget gated on this flag (e.g. drawing-marker tap
    // handlers, toolbars) rebuilds. Previously omitted, which left the
    // UI subtly out-of-sync after closing the element-name dialog —
    // especially noticeable under WASM where state propagation differs
    // from the JS build.
    notifyListeners();
  }

  /// Complete drawing and create element
  void completeDrawing({
    required String name,
    String description = '',
    Color? color,
    PointCategory? pointCategory,
  }) {
    if (!_isDrawing || _drawingPoints.isEmpty) return;
    if (_currentMap == null || _selectedLayerId == null) return;

    final layer = selectedLayer;
    if (layer == null) return;

    MapLayer updatedLayer;

    switch (_drawingMode) {
      case DrawingMode.polygon:
        if (_drawingPoints.length < 3) {
          debugPrint('Need at least 3 points for polygon');
          return;
        }
        final polygon = CustomPolygon(
          name: name,
          description: description,
          points: List.from(_drawingPoints),
          color: color ?? layer.defaultColor,
        );
        updatedLayer = layer.addPolygon(polygon);
        break;

      case DrawingMode.polyline:
        if (_drawingPoints.length < 2) {
          debugPrint('Need at least 2 points for polyline');
          return;
        }
        final polyline = MapPolyline.create(
          name: name,
          description: description,
          points: List.from(_drawingPoints),
          color: color ?? layer.defaultColor,
        );
        updatedLayer = layer.addPolyline(polyline);
        break;

      case DrawingMode.point:
        if (_drawingPoints.isEmpty) return;
        final cat = pointCategory ?? PointCategory.generic;
        final point = MapPoint.create(
          name: name,
          description: description,
          position: _drawingPoints.first,
          color: color ?? cat.color,
          pointCategory: cat,
        );
        updatedLayer = layer.addPoint(point);
        break;

      default:
        return;
    }

    _currentMap = _currentMap!.updateLayer(_selectedLayerId!, updatedLayer);
    _clearDrawingState();
    _drawingMode = DrawingMode.none; // Switch back to select mode
    _ignoreNextTap = true; // Ignore the next tap after completing drawing
    debugPrint('Completed drawing: $name');
    _notifyAndSave();
  }

  /// Cancel drawing
  void cancelDrawing() {
    _clearDrawingState();
    _drawingMode = DrawingMode.none;
    debugPrint('Cancelled drawing');
    notifyListeners();
  }

  void _clearDrawingState() {
    _isDrawing = false;
    _drawingPoints.clear();
    _ignoreNextTap = false;
    _isDialogOpen = false; // Reset dialog state
    _drawingToUnfinished = false; // Reset unfinished flag
  }

  /// Remove last drawing point (undo last click)
  void removeLastDrawingPoint() {
    if (_drawingPoints.isNotEmpty) {
      _drawingPoints.removeLast();
      notifyListeners();
    }
  }

  /// Get temporary markers for current drawing points
  Set<Marker> getDrawingMarkers() {
    if (!_isDrawing || _drawingPoints.isEmpty) {
      return {};
    }

    final canClose =
        _drawingMode == DrawingMode.polygon && _drawingPoints.length >= 3;

    return _drawingPoints.asMap().entries.map((entry) {
      final index = entry.key;
      final point = entry.value;
      final isFirst = index == 0;

      // Highlight the first marker green when the polygon can be closed
      final hue = isFirst && canClose
          ? BitmapDescriptor.hueGreen
          : _drawingMode == DrawingMode.polygon
              ? BitmapDescriptor.hueBlue
              : BitmapDescriptor.hueOrange;

      return Marker(
        markerId: MarkerId('drawing_point_$index'),
        position: point,
        icon: BitmapDescriptor.defaultMarkerWithHue(hue),
        alpha: 0.7,
        draggable: false,
        zIndexInt: isFirst ? 1001 : 1000, // First marker on top
        infoWindow: isFirst && canClose
            ? const InfoWindow(
                title: 'Close polygon',
                snippet: 'Tap here to finish',
              )
            : InfoWindow(
                title: 'Point ${index + 1}',
                snippet: 'Tap to continue',
              ),
      );
    }).toSet();
  }

  /// Get temporary polyline for current drawing
  Polyline? getDrawingPolyline() {
    if (!_isDrawing || _drawingPoints.length < 2) return null;
    if (_drawingMode != DrawingMode.polygon &&
        _drawingMode != DrawingMode.polyline) {
      return null;
    }

    // Always show an open polyline — never close the shape during drawing.
    // For polygons, the shape closes only when the user completes it.
    return Polyline(
      polylineId: const PolylineId('drawing_preview'),
      points: _drawingPoints,
      color: _drawingMode == DrawingMode.polygon
          ? Colors.blue.withValues(alpha: 0.6)
          : Colors.orange.withValues(alpha: 0.6),
      width: 3,
      patterns: [PatternItem.dash(20), PatternItem.gap(10)], // Dashed line
      geodesic: true,
    );
  }

  /// Get temporary polygon fill for current drawing
  Polygon? getDrawingPolygon() {
    if (!_isDrawing || _drawingMode != DrawingMode.polygon) return null;
    if (_drawingPoints.length < 3) return null;

    return Polygon(
      polygonId: const PolygonId('drawing_preview_fill'),
      points: _drawingPoints,
      fillColor: Colors.blue.withValues(alpha: 0.1),
      strokeColor: Colors.blue.withValues(alpha: 0.6),
      strokeWidth: 3,
      geodesic: true,
    );
  }

  // === VERTEX EDITING OPERATIONS ===

  /// Start editing vertices of a polygon or polyline
  void startVertexEditing(String elementId) {
    if (_currentMap == null || _selectedLayerId == null) return;

    final layer = selectedLayer;
    if (layer == null) return;

    // Find the element and get its points
    List<LatLng>? points;

    // Check polygons
    final polygonIndex = layer.polygons.indexWhere((p) {
      final id = '${_selectedLayerId}_polygon_${layer.polygons.indexOf(p)}';
      return id == elementId;
    });

    if (polygonIndex != -1) {
      points = layer.polygons[polygonIndex].points;
      _isEditingPolygon = true;
    } else {
      // Check polylines
      final polyline =
          layer.polylines.where((p) => p.id == elementId).firstOrNull;
      if (polyline != null) {
        points = polyline.points;
        _isEditingPolygon = false;
      }
    }

    if (points != null && points.isNotEmpty) {
      _editingPoints = List<LatLng>.from(points);
      _isEditingVertices = true;
      _editingElementId = elementId;
      _hasUnsavedChanges = false;
      _ignoreNextTap =
          true; // prevent the triggering tap from immediately saving
      debugPrint(
          'Started vertex editing for element: $elementId (polygon: $_isEditingPolygon)');
      notifyListeners();
    }
  }

  /// Update a single editing point (vertex drag)
  void updateEditingPoint(int index, LatLng newPosition,
      {bool temporary = false}) {
    if (_editingPoints == null ||
        index < 0 ||
        index >= _editingPoints!.length) {
      return;
    }

    _editingPoints![index] = newPosition;
    if (!temporary) {
      _hasUnsavedChanges = true;
    }
    notifyListeners();
  }

  /// Insert a new editing point (midpoint drag to add vertex)
  void insertEditingPoint(int index, LatLng position) {
    if (_editingPoints == null) return;

    if (index >= 0 && index <= _editingPoints!.length) {
      _editingPoints!.insert(index, position);
      _hasUnsavedChanges = true;
      debugPrint('Inserted new vertex at index $index');
      notifyListeners();
    }
  }

  /// Remove an editing point (vertex)
  void removeEditingPoint(int index) {
    if (_editingPoints == null || _editingPoints!.length <= 3) {
      debugPrint('Cannot remove vertex: minimum 3 points required for polygon');
      return;
    }

    if (index >= 0 && index < _editingPoints!.length) {
      _editingPoints!.removeAt(index);
      _hasUnsavedChanges = true;
      debugPrint('Removed vertex at index $index');
      notifyListeners();
    }
  }

  /// Save vertex editing changes back to the element
  void saveVertexEditing() {
    if (_currentMap == null ||
        _selectedLayerId == null ||
        _editingElementId == null ||
        _editingPoints == null) {
      return;
    }

    final layer = selectedLayer;
    if (layer == null) return;

    // Find and update the element
    // Check polygons
    final polygonIndex = layer.polygons.indexWhere((p) {
      final id = '${_selectedLayerId}_polygon_${layer.polygons.indexOf(p)}';
      return id == _editingElementId;
    });

    if (polygonIndex != -1) {
      final polygon = layer.polygons[polygonIndex];
      final updatedPolygon = polygon.copyWith(points: _editingPoints!);
      updatePolygon(layer, polygonIndex, updatedPolygon);
    } else {
      // Check polylines
      final polyline =
          layer.polylines.where((p) => p.id == _editingElementId).firstOrNull;
      if (polyline != null) {
        final updatedPolyline = polyline.copyWith(points: _editingPoints!);
        updatePolyline(layer, polyline.id, updatedPolyline);
      }
    }

    // Clear editing state
    _stopVertexEditing();
    debugPrint('Saved vertex editing changes');
  }

  /// Cancel vertex editing without saving
  void cancelVertexEditing() {
    _stopVertexEditing();
    debugPrint('Cancelled vertex editing');
  }

  void _stopVertexEditing() {
    _isEditingVertices = false;
    _isEditingPolygon = false;
    _editingPoints = null;
    _editingElementId = null;
    _hasUnsavedChanges = false;
    notifyListeners();
  }

  /// Get preview polygon while editing vertices
  Polygon? getEditingPolygon() {
    if (!_isEditingVertices ||
        _editingPoints == null ||
        _editingPoints!.length < 3) {
      return null;
    }

    // Only return polygon if we're editing a polygon element
    if (_editingElementId != null && _editingElementId!.contains('polygon')) {
      return Polygon(
        polygonId: const PolygonId('editing_preview'),
        points: _editingPoints!,
        fillColor: Colors.blue.withValues(alpha: 0.2),
        strokeColor: Colors.blue.withValues(alpha: 0.8),
        strokeWidth: 3,
        geodesic: true,
      );
    }
    return null;
  }

  /// Get preview polyline while editing vertices
  Polyline? getEditingPolyline() {
    if (!_isEditingVertices ||
        _editingPoints == null ||
        _editingPoints!.length < 2) {
      return null;
    }

    // Return polyline for both polyline and polygon editing
    return Polyline(
      polylineId: const PolylineId('editing_preview'),
      points: _editingPoints!,
      color: Colors.blue.withValues(alpha: 0.8),
      width: 3,
      geodesic: true,
    );
  }

  // === ELEMENT OPERATIONS ===

  /// Select an element
  void selectElement(String elementId) {
    _selectedElementId = elementId;
    debugPrint('Selected element: $elementId');
    notifyListeners();
  }

  /// Delete selected element
  void deleteSelectedElement() {
    if (_currentMap == null ||
        _selectedLayerId == null ||
        _selectedElementId == null) {
      return;
    }
    deleteElement(_selectedElementId!, _selectedLayerId!);
  }

  /// Delete element directly by its IDs – does not rely on selection state.
  void deleteElement(String elementId, String layerId) {
    if (_currentMap == null) return;

    final layer = _currentMap!.getLayer(layerId);
    if (layer == null) return;

    MapLayer updatedLayer = layer;

    // Try polygons
    final polygonIndex = layer.polygons.indexWhere((p) {
      return '${layerId}_polygon_${layer.polygons.indexOf(p)}' == elementId;
    });

    if (polygonIndex != -1) {
      updatedLayer = layer.removePolygon(polygonIndex);
    } else {
      // Try polylines
      final polylineIndex =
          layer.polylines.indexWhere((p) => p.id == elementId);
      if (polylineIndex != -1) {
        updatedLayer = layer.removePolyline(elementId);
      } else {
        // Try points
        final pointIndex = layer.points.indexWhere((p) => p.id == elementId);
        if (pointIndex != -1) {
          updatedLayer = layer.removePoint(elementId);
        }
      }
    }

    _currentMap = _currentMap!.updateLayer(layerId, updatedLayer);
    if (_selectedElementId == elementId) _selectedElementId = null;
    debugPrint('Deleted element: $elementId');
    _notifyAndSave();
  }

  // === ELEMENT UPDATE METHODS ===

  /// Update polygon properties
  void updatePolygon(
      MapLayer layer, int polygonIndex, CustomPolygon updatedPolygon) {
    if (_currentMap == null) return;

    final polygons = List<CustomPolygon>.from(layer.polygons);
    if (polygonIndex >= 0 && polygonIndex < polygons.length) {
      polygons[polygonIndex] = updatedPolygon;
      final updatedLayer = layer.copyWith(polygons: polygons);
      _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
      debugPrint('Updated polygon: ${updatedPolygon.name}');
      _notifyAndSave();
    }
  }

  /// Delete polygon
  void deletePolygon(MapLayer layer, int polygonIndex) {
    if (_currentMap == null) return;

    final updatedLayer = layer.removePolygon(polygonIndex);
    _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
    _selectedElementId = null;
    debugPrint('Deleted polygon at index $polygonIndex');
    _notifyAndSave();
  }

  /// Update point properties
  void updatePoint(MapLayer layer, String pointId, MapPoint updatedPoint) {
    if (_currentMap == null) return;

    final points = List<MapPoint>.from(layer.points);
    final pointIndex = points.indexWhere((p) => p.id == pointId);

    if (pointIndex != -1) {
      points[pointIndex] = updatedPoint;
      final updatedLayer = layer.copyWith(points: points);
      _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
      debugPrint('Updated point: ${updatedPoint.name}');
      _notifyAndSave();
    }
  }

  /// Update only the [PointCategory] of a point, looked up by element/layer id.
  void updatePointCategory(
      String layerId, String elementId, PointCategory category) {
    if (_currentMap == null) return;
    final layer = _currentMap!.layers.firstWhere(
      (l) => l.id == layerId,
      orElse: () => throw StateError('Layer not found'),
    );
    final point = layer.points.firstWhere(
      (p) => p.id == elementId,
      orElse: () => throw StateError('Point not found'),
    );
    updatePoint(
      layer,
      elementId,
      point.copyWith(pointCategory: category, color: category.color),
    );
  }

  /// Delete point
  void deletePoint(MapLayer layer, String pointId) {
    if (_currentMap == null) return;

    final updatedLayer = layer.removePoint(pointId);
    _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);

    if (_selectedElementId == pointId) {
      _selectedElementId = null;
    }

    debugPrint('Deleted point: $pointId');
    _notifyAndSave();
  }

  /// Move a marker (MapPoint or marker-type CustomPolygon) to a new position.
  /// Called when a user drags a marker on the map.
  void moveMarker(String markerId, LatLng newPosition) {
    if (_currentMap == null) return;

    for (final layer in _currentMap!.layers) {
      // Check MapPoint entries
      final pointIndex = layer.points.indexWhere((p) => p.id == markerId);
      if (pointIndex != -1) {
        final point = layer.points[pointIndex];
        final updated = point.copyWith(position: newPosition);
        final newPoints = List<MapPoint>.from(layer.points);
        newPoints[pointIndex] = updated;
        final updatedLayer =
            layer.copyWith(points: newPoints, updatedAt: DateTime.now());
        _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
        debugPrint('Moved point "${point.name}" to $newPosition');
        _notifyAndSave();
        return;
      }

      // Check marker-type CustomPolygon entries
      // markerId format: "{layerId}_polygon_marker_{index}"
      if (markerId.startsWith('${layer.id}_polygon_marker_')) {
        final suffix = markerId.substring('${layer.id}_polygon_marker_'.length);
        final index = int.tryParse(suffix);
        if (index != null && index < layer.polygons.length) {
          final cp = layer.polygons[index];
          if (cp.isMarker) {
            final updatedCp = cp.copyWith(points: [newPosition]);
            final newPolygons = List<CustomPolygon>.from(layer.polygons);
            newPolygons[index] = updatedCp;
            final updatedLayer = layer.copyWith(
                polygons: newPolygons, updatedAt: DateTime.now());
            _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
            debugPrint('Moved marker polygon "${cp.name}" to $newPosition');
            _notifyAndSave();
            return;
          }
        }
      }
    }
  }

  /// Update polyline properties
  void updatePolyline(
      MapLayer layer, String polylineId, MapPolyline updatedPolyline) {
    if (_currentMap == null) return;

    final polylines = List<MapPolyline>.from(layer.polylines);
    final polylineIndex = polylines.indexWhere((p) => p.id == polylineId);

    if (polylineIndex != -1) {
      polylines[polylineIndex] = updatedPolyline;
      final updatedLayer = layer.copyWith(polylines: polylines);
      _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
      debugPrint('Updated polyline: ${updatedPolyline.name}');
      _notifyAndSave();
    }
  }

  /// Convenience: update only the style of a polygon identified by its composite id.
  /// polygonId format: "${layerId}_polygon_${index}"
  void updatePolygonStyle(
    String layerId,
    String polygonId, {
    Color? color,
    double? fillOpacity,
    int? strokeWidth,
  }) {
    final match = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(polygonId);
    if (match == null) return;
    final idx = int.parse(match.group(2)!);
    final layer = layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null || idx >= layer.polygons.length) return;
    updatePolygon(
      layer,
      idx,
      layer.polygons[idx].copyWith(
        color: color,
        fillOpacity: fillOpacity,
        strokeWidth: strokeWidth,
      ),
    );
  }

  /// Convenience: update only the style of a polyline by its id.
  void updatePolylineStyle(
    String layerId,
    String polylineId, {
    Color? color,
    double? strokeWidth,
  }) {
    final layer = layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null) return;
    final polyline =
        layer.polylines.where((p) => p.id == polylineId).firstOrNull;
    if (polyline == null) return;
    updatePolyline(
      layer,
      polylineId,
      polyline.copyWith(color: color, strokeWidth: strokeWidth),
    );
  }

  /// Rename an element (polygon, polyline, or point) by its info window data.
  void renameElement(
      String layerId, String elementId, String type, String newName) {
    final layer = layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null) return;

    if (type == 'polygon') {
      final match = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(elementId);
      if (match == null) return;
      final idx = int.parse(match.group(2)!);
      if (idx >= layer.polygons.length) return;
      updatePolygon(layer, idx, layer.polygons[idx].copyWith(name: newName));
    } else if (type == 'polyline') {
      final polyline =
          layer.polylines.where((p) => p.id == elementId).firstOrNull;
      if (polyline == null) return;
      updatePolyline(layer, elementId, polyline.copyWith(name: newName));
    } else if (type == 'point') {
      final point = layer.points.where((p) => p.id == elementId).firstOrNull;
      if (point == null) return;
      updatePoint(layer, elementId, point.copyWith(name: newName));
    }

    // Update the info window title to reflect the new name
    if (_infoWindowData != null && _infoWindowData!.elementId == elementId) {
      _infoWindowData = InfoWindowData(
        elementId: _infoWindowData!.elementId,
        layerId: _infoWindowData!.layerId,
        title: newName,
        description: _infoWindowData!.description,
        subtitle: _infoWindowData!.subtitle,
        type: _infoWindowData!.type,
        anchor: _infoWindowData!.anchor,
        letterBoxEstimate: _infoWindowData!.letterBoxEstimate,
      );
    }
  }

  /// Delete polyline
  void deletePolyline(MapLayer layer, String polylineId) {
    if (_currentMap == null) return;

    final updatedLayer = layer.removePolyline(polylineId);
    _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);

    if (_selectedElementId == polylineId) {
      _selectedElementId = null;
    }

    debugPrint('Deleted polyline: $polylineId');
    _notifyAndSave();
  }

  // === MOVE BETWEEN LAYERS ===

  /// Move a polygon from one layer to another.
  void movePolygonToLayer(
      MapLayer sourceLayer, int polygonIndex, String targetLayerId) {
    if (_currentMap == null) return;
    final targetLayer = _currentMap!.getLayer(targetLayerId);
    if (targetLayer == null || sourceLayer.id == targetLayerId) return;
    if (polygonIndex < 0 || polygonIndex >= sourceLayer.polygons.length) return;

    final polygon = sourceLayer.polygons[polygonIndex];
    final updatedSource = sourceLayer.removePolygon(polygonIndex);
    final updatedTarget = targetLayer.addPolygon(polygon);

    _currentMap = _currentMap!
        .updateLayer(sourceLayer.id, updatedSource)
        .updateLayer(targetLayerId, updatedTarget);

    _selectedElementId = null;
    debugPrint('Moved polygon "${polygon.name}" → layer "${targetLayer.name}"');
    _notifyAndSave();
  }

  /// Move a polyline from one layer to another.
  void movePolylineToLayer(
      MapLayer sourceLayer, String polylineId, String targetLayerId) {
    if (_currentMap == null) return;
    final targetLayer = _currentMap!.getLayer(targetLayerId);
    if (targetLayer == null || sourceLayer.id == targetLayerId) return;

    final polyline = sourceLayer.polylines.cast<MapPolyline?>().firstWhere(
          (p) => p!.id == polylineId,
          orElse: () => null,
        );
    if (polyline == null) return;

    final updatedSource = sourceLayer.removePolyline(polylineId);
    final updatedTarget = targetLayer.addPolyline(polyline);

    _currentMap = _currentMap!
        .updateLayer(sourceLayer.id, updatedSource)
        .updateLayer(targetLayerId, updatedTarget);

    if (_selectedElementId == polylineId) _selectedElementId = null;
    debugPrint(
        'Moved polyline "${polyline.name}" → layer "${targetLayer.name}"');
    _notifyAndSave();
  }

  /// Move a point from one layer to another.
  void movePointToLayer(
      MapLayer sourceLayer, String pointId, String targetLayerId) {
    if (_currentMap == null) return;
    final targetLayer = _currentMap!.getLayer(targetLayerId);
    if (targetLayer == null || sourceLayer.id == targetLayerId) return;

    final point = sourceLayer.points.cast<MapPoint?>().firstWhere(
          (p) => p!.id == pointId,
          orElse: () => null,
        );
    if (point == null) return;

    final updatedSource = sourceLayer.removePoint(pointId);
    final updatedTarget = targetLayer.addPoint(point);

    _currentMap = _currentMap!
        .updateLayer(sourceLayer.id, updatedSource)
        .updateLayer(targetLayerId, updatedTarget);

    if (_selectedElementId == pointId) _selectedElementId = null;
    debugPrint('Moved point "${point.name}" → layer "${targetLayer.name}"');
    _notifyAndSave();
  }

  // === MAP CONTROLLER ===

  /// Set the Google Maps controller
  void setMapController(GoogleMapController controller) {
    _mapController = controller;
    if (_pendingFitBounds) {
      _pendingFitBounds = false;
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_isDisposed) return;
        fitMapToBounds();
      });
    }

    // Auto-load the latest linked month once the map is ready to render it.
    final latest = latestLinkedCloudFolder;
    if (autoLoadLatestCloudFolder &&
        latest != null &&
        !_loadedCloudTrackFolders.contains(latest)) {
      Future.microtask(() {
        if (_isDisposed) return;
        loadCloudFolderTracks(folderPath: latest);
      });
    }
  }

  /// Request a fit-to-bounds camera animation after the next map controller
  /// is set (i.e. after [loadFromAdapter] triggers a map rebuild).
  void requestFitBoundsOnLoad() {
    _pendingFitBounds = true;
  }

  /// Fit map to bounds
  Future<void> fitMapToBounds() async {
    if (_mapController == null || _currentMap == null) return;

    final bounds = _currentMap!.getBounds();
    if (bounds == null) return;

    await _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 50),
    );
  }

  /// Animate the camera to focus on a specific polygon and open its info window.
  ///
  /// Searches all visible layers for a polygon matching the given [layerId] and
  /// [polygonIndex]. Calculates the polygon bounds, animates the camera to fit
  /// those bounds with padding, and opens the info window at the centroid.
  Future<void> focusOnPolygon(String layerId, int polygonIndex) async {
    if (_mapController == null || _currentMap == null) return;

    final layer = _currentMap!.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null || polygonIndex >= layer.polygons.length) return;

    final polygon = layer.polygons[polygonIndex];
    if (polygon.points.isEmpty) return;

    // Select the polygon so it highlights visually
    final polygonId = '${layerId}_polygon_$polygonIndex';
    _selectedLayerId = layerId;
    _selectedElementId = polygonId;
    // Ignore the next map tap so the search selection isn't immediately cleared
    _ignoreNextTap = true;
    notifyListeners();

    // Calculate bounds for the polygon
    double minLat = polygon.points.first.latitude;
    double maxLat = polygon.points.first.latitude;
    double minLng = polygon.points.first.longitude;
    double maxLng = polygon.points.first.longitude;

    for (final pt in polygon.points) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    // Animate camera to fit polygon bounds
    await _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80),
    );
  }

  /// Animate the camera to fit a polyline, select it, and open its info
  /// window — mirrors [focusOnPolygon] for track/route elements.
  Future<void> focusOnPolyline(String layerId, String polylineId) async {
    if (_currentMap == null) return;

    // Search persisted layers first, then cloud overlay layers.
    MapPolyline? found;
    String resolvedLayerId = layerId;
    final allLayers = [
      ..._currentMap!.layers,
      ..._cloudTracksLayers.values,
    ];
    for (final layer in allLayers) {
      final match =
          layer.polylines.where((p) => p.id == polylineId).firstOrNull;
      if (match != null) {
        found = match;
        resolvedLayerId = layer.id;
        break;
      }
    }
    if (found == null || found.points.isEmpty) return;

    // Select the polyline so it highlights (red + elevated zIndex) visually.
    _selectedLayerId = resolvedLayerId;
    _selectedElementId = polylineId;
    _ignoreNextTap = true;

    // Build the info-window subtitle (same logic as _handlePolylineTap in the
    // editor widget).
    String subtitle;
    if (found.hasTrackMetadata) {
      final parts = <String>[found.formattedDistance];
      if (found.formattedTimeRange.isNotEmpty) {
        parts.add(found.formattedTimeRange);
      }
      if (found.formattedDuration.isNotEmpty) {
        parts.add(found.formattedDuration);
      }
      subtitle = parts.join(' · ');
    } else {
      final km = found.totalDistanceMeters / 1000;
      subtitle =
          km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(2)} km';
    }

    // Anchor the info window at the polyline centroid.
    final avgLat = found.points.map((p) => p.latitude).reduce((a, b) => a + b) /
        found.points.length;
    final avgLng =
        found.points.map((p) => p.longitude).reduce((a, b) => a + b) /
            found.points.length;

    _showStylePanel = false;
    _infoWindowData = InfoWindowData(
      elementId: polylineId,
      layerId: resolvedLayerId,
      title: found.name.isNotEmpty ? found.name : 'Unnamed Polyline',
      description: found.description,
      subtitle: subtitle,
      type: 'polyline',
      anchor: LatLng(avgLat, avgLng),
    );
    notifyListeners();

    if (_mapController == null) return;

    // Fit camera to polyline bounds.
    double minLat = found.points.first.latitude;
    double maxLat = found.points.first.latitude;
    double minLng = found.points.first.longitude;
    double maxLng = found.points.first.longitude;
    for (final pt in found.points) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
    }
    await _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        80,
      ),
    );
  }

  /// Animate the camera to a specific position at the given zoom level.
  Future<void> animateToPosition(LatLng position, {double zoom = 16.0}) async {
    if (_mapController == null) return;
    await _mapController!.animateCamera(
      CameraUpdate.newLatLngZoom(position, zoom),
    );
  }

  /// Add a point to the selected layer from an external source (e.g. address search).
  void addPointToSelectedLayer(MapPoint point) {
    if (_currentMap == null || _selectedLayerId == null) return;
    final layer = selectedLayer;
    if (layer == null) return;

    final updatedLayer = layer.addPoint(point);
    _currentMap = _currentMap!.updateLayer(_selectedLayerId!, updatedLayer);
    _notifyAndSave();
  }

  /// Get all searchable polygons across all visible layers.
  ///
  /// Returns a list of records containing the polygon, its layer ID,
  /// and its index within the layer — used by the search overlay.
  List<({CustomPolygon polygon, String layerId, int index})>
      getSearchablePolygons() {
    if (_currentMap == null) return [];

    final results = <({CustomPolygon polygon, String layerId, int index})>[];
    for (final layer in _currentMap!.layers) {
      if (!layer.isVisible) continue;
      for (int i = 0; i < layer.polygons.length; i++) {
        results.add((polygon: layer.polygons[i], layerId: layer.id, index: i));
      }
    }
    return results;
  }

  // === INFO WINDOW / STYLE PANEL ===

  /// Open the info window for a map element.
  void openInfoWindow(InfoWindowData data) {
    _selectedLayerId = data.layerId;
    _selectedElementId = data.elementId;
    _showStylePanel = false;
    _infoWindowData = data;
    notifyListeners();
  }

  /// Dismiss the info window and style panel.
  void dismissInfoWindow() {
    if (_infoWindowData != null) {
      _infoWindowData = null;
      _showStylePanel = false;
      notifyListeners();
    }
  }

  /// Toggle style panel visibility.
  void toggleStylePanel() {
    _showStylePanel = !_showStylePanel;
    notifyListeners();
  }

  /// Close style panel without dismissing the info window.
  void closeStylePanel() {
    if (_showStylePanel) {
      _showStylePanel = false;
      notifyListeners();
    }
  }

  // === MAP TYPE / STYLE ===

  /// Available base map options.
  static const List<MapBaseOption> baseMapOptions = [
    MapBaseOption(
      key: 'clm_custom',
      label: 'CLM Custom',
      icon: Icons.palette,
      mapType: MapType.normal,
      cloudMapId: '89c628d2bb3002712797ce42',
      description: 'CLM branded cloud style',
    ),
    MapBaseOption(
      key: 'hybrid',
      label: 'Hybrid',
      icon: Icons.layers,
      mapType: MapType.hybrid,
    ),
    MapBaseOption(
      key: 'terrain',
      label: 'Terrain',
      icon: Icons.terrain,
      mapType: MapType.terrain,
    ),
    MapBaseOption(
      key: 'dark',
      label: 'Dark',
      icon: Icons.dark_mode,
      mapType: MapType.normal,
      styleJson: _darkMapStyle,
      description: 'Dark theme map',
    ),
    MapBaseOption(
      key: 'clean',
      label: 'Clean',
      icon: Icons.print,
      mapType: MapType.normal,
      styleJson: _cleanMapStyle,
      description: 'Minimal style for printing',
    ),
    MapBaseOption(
      key: 'retro',
      label: 'Retro',
      icon: Icons.auto_awesome,
      mapType: MapType.normal,
      styleJson: _retroMapStyle,
      description: 'Vintage retro colours',
    ),
  ];

  /// Change the base map type/style without reloading data.
  /// Style is passed via `GoogleMap.style` parameter on rebuild;
  /// only the tile layer changes — polygons, polylines & markers stay.
  void setBaseMap(String key) {
    final option = baseMapOptions.firstWhere(
      (o) => o.key == key,
      orElse: () => baseMapOptions.first,
    );

    _selectedBaseMap = key;
    _mapType = option.mapType;
    _activeMapStyleJson = option.styleJson;
    _activeCloudMapId = option.cloudMapId;

    notifyListeners();
  }

  // === UI STATE ===

  /// Toggle sidebar visibility
  void toggleSidebar() {
    _isSidebarVisible = !_isSidebarVisible;
    notifyListeners();
  }

  /// Explicitly set sidebar visibility — used by the editor widget to
  /// apply a screen-size-dependent initial state (e.g. hidden on mobile).
  void setSidebarVisible(bool visible) {
    if (_isSidebarVisible == visible) return;
    _isSidebarVisible = visible;
    notifyListeners();
  }

  /// Toggle the work area picker panel
  void toggleWorkAreaPicker() {
    _isWorkAreaPickerVisible = !_isWorkAreaPickerVisible;
    notifyListeners();
  }

  /// Hide the work area picker panel
  void hideWorkAreaPicker() {
    if (_isWorkAreaPickerVisible) {
      _isWorkAreaPickerVisible = false;
      notifyListeners();
    }
  }

  // === AREA OVERLAYS ===

  void toggleWorkAreasOverlay() {
    _showWorkAreasOverlay = !_showWorkAreasOverlay;
    notifyListeners();
  }

  void toggleSuburbsOverlay() {
    _showSuburbsOverlay = !_showSuburbsOverlay;
    notifyListeners();
  }

  void toggleWorkAreasOverlayExpanded() {
    _workAreasOverlayExpanded = !_workAreasOverlayExpanded;
    notifyListeners();
  }

  void toggleSuburbsOverlayExpanded() {
    _suburbsOverlayExpanded = !_suburbsOverlayExpanded;
    notifyListeners();
  }

  // === PICKER LAYER VISIBILITY ===

  void togglePickerWorkAreasVisible() {
    _pickerWorkAreasVisible = !_pickerWorkAreasVisible;
    notifyListeners();
  }

  void togglePickerSuburbsVisible() {
    _pickerSuburbsVisible = !_pickerSuburbsVisible;
    notifyListeners();
  }

  // === LASSO SELECT FOR WORK AREAS ===

  /// Start lasso selection mode — the user draws a polygon on the map
  /// and all work areas whose centroid (or any vertex) falls inside it
  /// will be added to the map.
  void startLassoSelect() {
    _isLassoSelectActive = true;
    _lassoPoints.clear();
    _drawingMode = DrawingMode.lassoSelect;
    _isDrawing = true;
    debugPrint('Started lasso select mode');
    notifyListeners();
  }

  /// Add a point to the lasso selection polygon.
  void addLassoPoint(LatLng point) {
    if (!_isLassoSelectActive) return;
    _lassoPoints.add(point);
    debugPrint('Lasso point added: ${_lassoPoints.length}');
    notifyListeners();
  }

  /// Remove last lasso point (undo).
  void removeLastLassoPoint() {
    if (_lassoPoints.isNotEmpty) {
      _lassoPoints.removeLast();
      notifyListeners();
    }
  }

  /// Complete lasso selection and return the list of work areas whose
  /// centroid falls inside the drawn polygon. Does not auto-add them
  /// — the caller should present a confirmation and call
  /// [addWorkAreasToMap] with the selected items.
  List<WorkArea> completeLassoSelect(List<WorkArea> allWorkAreas) {
    if (_lassoPoints.length < 3) {
      cancelLassoSelect();
      return [];
    }

    final matched = <WorkArea>[];
    for (final wa in allWorkAreas) {
      if (wa.polygonPoints.length < 3) continue;
      if (isWorkAreaImported(wa.name)) continue;
      if (_isWorkAreaInsideLasso(wa)) {
        matched.add(wa);
      }
    }

    debugPrint('Lasso select found ${matched.length} work areas');
    return matched;
  }

  /// Same as [completeLassoSelect] but for suburbs.
  List<WorkSuburb> completeLassoSelectSuburbs(List<WorkSuburb> allSuburbs) {
    if (_lassoPoints.length < 3) return [];

    final matched = <WorkSuburb>[];
    for (final suburb in allSuburbs) {
      if (suburb.polygonPoints.length < 3) continue;
      if (isSuburbImported(suburb.name)) continue;

      // Centroid check
      double lat = 0, lng = 0;
      for (final p in suburb.polygonPoints) {
        lat += p.latitude;
        lng += p.longitude;
      }
      final centroid = LatLng(
          lat / suburb.polygonPoints.length, lng / suburb.polygonPoints.length);
      if (_pointInPolygon(centroid, _lassoPoints)) {
        matched.add(suburb);
        continue;
      }
      // Fallback: any vertex inside
      for (final pt in suburb.polygonPoints) {
        if (_pointInPolygon(pt, _lassoPoints)) {
          matched.add(suburb);
          break;
        }
      }
    }

    debugPrint('Lasso select found ${matched.length} suburbs');
    return matched;
  }

  /// Finish lasso mode and clean up state.
  void finishLassoSelect() {
    _isLassoSelectActive = false;
    _lassoPoints.clear();
    _drawingMode = DrawingMode.none;
    _isDrawing = false;
    notifyListeners();
  }

  /// Cancel lasso selection.
  void cancelLassoSelect() {
    debugPrint('Cancelled lasso select');
    finishLassoSelect();
  }

  /// Add multiple work areas to the map at once.
  void addWorkAreasToMap(List<WorkArea> workAreas) {
    for (final wa in workAreas) {
      addWorkAreaToMap(wa);
    }
  }

  /// Check if a work area's centroid or any vertex falls inside the lasso.
  bool _isWorkAreaInsideLasso(WorkArea wa) {
    if (_lassoPoints.length < 3 || wa.polygonPoints.isEmpty) return false;

    // Check centroid first (fast path)
    double lat = 0, lng = 0;
    for (final p in wa.polygonPoints) {
      lat += p.latitude;
      lng += p.longitude;
    }
    final centroid =
        LatLng(lat / wa.polygonPoints.length, lng / wa.polygonPoints.length);
    if (_pointInPolygon(centroid, _lassoPoints)) return true;

    // Fallback: check if any vertex is inside
    for (final pt in wa.polygonPoints) {
      if (_pointInPolygon(pt, _lassoPoints)) return true;
    }
    return false;
  }

  /// Ray-casting point-in-polygon test.
  static bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final xi = polygon[i].latitude;
      final yi = polygon[i].longitude;
      final xj = polygon[j].latitude;
      final yj = polygon[j].longitude;
      final intersect = ((yi > point.longitude) != (yj > point.longitude)) &&
          (point.latitude <
              (xj - xi) * (point.longitude - yi) / (yj - yi) + xi);
      if (intersect) inside = !inside;
      j = i;
    }
    return inside;
  }

  // === HELPERS ===

  Color _getNextLayerColor() {
    const colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.brown,
    ];
    final index = (_currentMap?.layers.length ?? 0) % colors.length;
    return colors[index];
  }

  @override
  void notifyListeners() {
    // Guard against late callbacks (timers, microtasks, awaited Futures)
    // firing after the provider has been disposed — Flutter throws
    // "A ChangeNotifier was used after being disposed" otherwise.
    if (_isDisposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    // Set the disposed flag FIRST so any callback that races with dispose
    // (e.g. a Firestore snapshot arriving as we tear down, an auto-save
    // timer firing, a microtask scheduled by loadCloudFolder*) becomes a
    // no-op instead of touching freed state.
    _isDisposed = true;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _thumbnailTimer?.cancel();
    _thumbnailTimer = null;
    _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    _adapter?.dispose();
    _adapter = null;
    _mapController?.dispose();
    _mapController = null;
    // Drop heavy per-map data so the GC can reclaim it immediately —
    // important on web where the Riverpod ChangeNotifierProvider keeps
    // the provider instance alive for the app session.
    _cloudTracksLayers.clear();
    _cloudWaypointsLayers.clear();
    _loadingCloudTrackFolders.clear();
    _loadingCloudWaypointFolders.clear();
    _loadedCloudTrackFolders.clear();
    _loadedCloudWaypointFolders.clear();
    _drawingPoints.clear();
    _lassoPoints.clear();
    _editingPoints = null;
    _currentMap = null;
    super.dispose();
  }

  // ── Map style JSON constants ────────────────────────────────────────

  /// Clean / minimal style — hides POIs, transit, and landmarks for a
  /// print-friendly look (equivalent to the cloud-styled map used in
  /// PrintMapView but as a JSON style so it can be swapped at runtime).
  static const String _cleanMapStyle = '''[
    {"featureType":"poi","stylers":[{"visibility":"off"}]},
    {"featureType":"poi.park","elementType":"geometry","stylers":[{"visibility":"on"},{"color":"#c8e6c9"}]},
    {"featureType":"transit","stylers":[{"visibility":"off"}]},
    {"featureType":"road","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
    {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#ffd54f"}]},
    {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#ffca28"}]},
    {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#ffffff"}]},
    {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#f5f5f5"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#bbdefb"}]},
    {"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#f5f5f5"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#ffffff"}]}
  ]''';

  static const String _darkMapStyle = '''[
    {"elementType":"geometry","stylers":[{"color":"#212121"}]},
    {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#212121"}]},
    {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#757575"}]},
    {"featureType":"administrative.country","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},
    {"featureType":"administrative.land_parcel","stylers":[{"visibility":"off"}]},
    {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},
    {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
    {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#181818"}]},
    {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
    {"featureType":"poi.park","elementType":"labels.text.stroke","stylers":[{"color":"#1b1b1b"}]},
    {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},
    {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a8a8a"}]},
    {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#373737"}]},
    {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3c3c3c"}]},
    {"featureType":"road.highway.controlled_access","elementType":"geometry","stylers":[{"color":"#4e4e4e"}]},
    {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
    {"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#000000"}]},
    {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3d3d3d"}]}
  ]''';

  static const String _silverMapStyle = '''[
    {"elementType":"geometry","stylers":[{"color":"#f5f5f5"}]},
    {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#f5f5f5"}]},
    {"featureType":"administrative.land_parcel","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},
    {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#eeeeee"}]},
    {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
    {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#e5e5e5"}]},
    {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#ffffff"}]},
    {"featureType":"road.arterial","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
    {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#dadada"}]},
    {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
    {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},
    {"featureType":"transit.line","elementType":"geometry","stylers":[{"color":"#e5e5e5"}]},
    {"featureType":"transit.station","elementType":"geometry","stylers":[{"color":"#eeeeee"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#c9c9c9"}]},
    {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]}
  ]''';

  static const String _retroMapStyle = '''[
    {"elementType":"geometry","stylers":[{"color":"#ebe3cd"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#523735"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#f5f1e6"}]},
    {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#c9b2a6"}]},
    {"featureType":"administrative.land_parcel","elementType":"geometry.stroke","stylers":[{"color":"#dcd2be"}]},
    {"featureType":"administrative.land_parcel","elementType":"labels.text.fill","stylers":[{"color":"#ae9e90"}]},
    {"featureType":"landscape.natural","elementType":"geometry","stylers":[{"color":"#dfd2ae"}]},
    {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#dfd2ae"}]},
    {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#93817c"}]},
    {"featureType":"poi.park","elementType":"geometry.fill","stylers":[{"color":"#a5b076"}]},
    {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#447530"}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#f5f1e6"}]},
    {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#fdfcf8"}]},
    {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#f8c967"}]},
    {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#e9bc62"}]},
    {"featureType":"road.highway.controlled_access","elementType":"geometry","stylers":[{"color":"#e98d58"}]},
    {"featureType":"road.highway.controlled_access","elementType":"geometry.stroke","stylers":[{"color":"#db8555"}]},
    {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#806b63"}]},
    {"featureType":"transit.line","elementType":"geometry","stylers":[{"color":"#dfd2ae"}]},
    {"featureType":"transit.line","elementType":"labels.text.fill","stylers":[{"color":"#8f7d77"}]},
    {"featureType":"transit.line","elementType":"labels.text.stroke","stylers":[{"color":"#ebe3cd"}]},
    {"featureType":"transit.station","elementType":"geometry","stylers":[{"color":"#dfd2ae"}]},
    {"featureType":"water","elementType":"geometry.fill","stylers":[{"color":"#b9d3c2"}]},
    {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#92998d"}]}
  ]''';
}

/// Describes a base map option (type + optional custom style).
class MapBaseOption {
  final String key;
  final String label;
  final IconData icon;
  final MapType mapType;
  final String? styleJson;
  final String? cloudMapId;
  final String? description;

  const MapBaseOption({
    required this.key,
    required this.label,
    required this.icon,
    required this.mapType,
    this.styleJson,
    this.cloudMapId,
    this.description,
  });
}
