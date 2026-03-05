import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/custom_polygon.dart';
import '../../models/work_area.dart';
import '../adapters/map_data_adapter.dart';
import '../adapters/firestore_adapter.dart';
import '../models/shareable_map.dart';
import '../models/map_layer.dart';
import '../models/map_polyline.dart';
import '../models/map_point.dart';
import '../services/map_thumbnail_service.dart';
import '../services/shareable_maps_firestore_service.dart';

/// Data for the currently open info window overlay.
class InfoWindowData {
  final String elementId;
  final String layerId;
  final String title;
  final String description;
  final String subtitle; // stats: "2.87 km² · 8.37 km" or "8.37 km" or ""
  final String type; // 'polygon' | 'polyline' | 'point'
  final LatLng anchor; // geographic point reprojected to screen on each frame

  const InfoWindowData({
    required this.elementId,
    required this.layerId,
    required this.title,
    required this.description,
    required this.subtitle,
    required this.type,
    required this.anchor,
  });
}

/// Drawing mode for the map editor
enum DrawingMode {
  none,
  polygon,
  polyline,
  point,
  edit,
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

  // Editing state
  List<LatLng>? _editingPoints;
  bool _hasUnsavedChanges = false;
  bool _isEditingVertices = false;
  bool _isEditingPolygon =
      false; // true when the element being edited is a polygon
  String? _editingElementId; // Track which element is being edited

  // Real-time sync state
  StreamSubscription<ShareableMap?>? _realtimeSubscription;
  Timer? _autoSaveTimer;

  /// Timestamp of last local save — used to skip echoed Firestore snapshots.
  int _lastSaveTimestamp = 0;

  /// How long to wait after a mutation before auto-saving (debounce).
  static const _autoSaveDelay = Duration(seconds: 2);

  // UI state
  bool _isSidebarVisible = true;
  bool _isWorkAreaPickerVisible = false;
  GoogleMapController? _mapController;

  // Map type / style state
  MapType _mapType = MapType.normal;
  String? _activeMapStyleJson; // For JSON-based custom styles
  String _selectedBaseMap = 'roadmap'; // Track selected base map by key

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
  bool get ignoreNextTap => _ignoreNextTap;
  List<LatLng>? get editingPoints => _editingPoints;
  bool get hasUnsavedChanges => _hasUnsavedChanges;
  bool get isSidebarVisible => _isSidebarVisible;
  bool get isWorkAreaPickerVisible => _isWorkAreaPickerVisible;
  bool get isEditingVertices => _isEditingVertices;
  bool get isEditingPolygon => _isEditingPolygon;
  InfoWindowData? get infoWindowData => _infoWindowData;
  bool get showStylePanel => _showStylePanel;
  MapType get mapType => _mapType;
  String? get mapStyle => _activeMapStyleJson;
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

  // Get available layers
  List<MapLayer> get layers => _currentMap?.layers ?? [];

  // === ADAPTER OPERATIONS ===

  /// Load data from an adapter and prepare the editor.
  ///
  /// This replaces the current map with data from the adapter's [load] method
  /// and stores the adapter reference for subsequent [saveToAdapter] calls.
  /// For [FirestoreMapAdapter], also starts a real-time snapshot listener so
  /// remote changes are automatically reflected.
  Future<void> loadFromAdapter(MapDataAdapter adapter) async {
    _isLoading = true;
    notifyListeners();

    try {
      // Clean up previous real-time listener
      _stopRealtimeSync();
      // Dispose previous adapter if any
      await _adapter?.dispose();
      _adapter = adapter;

      // Load the map data
      final map = await adapter.load();
      loadMap(map);

      // Start real-time sync for Firestore-backed maps
      if (adapter is FirestoreMapAdapter) {
        _startRealtimeSync(adapter);
      }

      debugPrint(
          'Loaded map from adapter: ${adapter.adapterId} – ${adapter.displayName}');
    } catch (e) {
      debugPrint('Failed to load from adapter ${adapter.adapterId}: $e');
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
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

      if (url != null && _currentMap != null) {
        // Persist the Storage URL on the Firestore document.
        final firestoreService = ShareableMapsFirestoreService();
        await firestoreService.updateMapFields(
          adapter.monthKey,
          docId,
          {'thumbnailUrl': url},
        );

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
    _stopRealtimeSync();
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

    notifyListeners();
  }

  /// Stop the real-time Firestore listener.
  void _stopRealtimeSync() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
  }

  /// Schedule a debounced auto-save. Each call resets the timer.
  ///
  /// This is called after map-mutating operations so that changes
  /// propagate to Firestore (and thus to other viewers) without
  /// requiring the user to press Save manually.
  void _scheduleAutoSave() {
    if (_adapter == null || _adapter is! FirestoreMapAdapter) return;
    if (_currentMap == null) return;

    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_autoSaveDelay, () {
      saveToAdapter();
    });
  }

  /// Notify listeners AND schedule a debounced auto-save.
  ///
  /// Call this instead of plain [notifyListeners] in methods that mutate
  /// the map data (polygons, layers, etc.) so that changes propagate to
  /// Firestore and are received in real-time by other viewers.
  void _notifyMapChanged() {
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
    _notifyMapChanged();
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
    );

    final updatedLayer = layer.addPolygon(polygon);
    _currentMap = _currentMap!.updateLayer(workAreaLayerId, updatedLayer);
    debugPrint('Added work area to map: ${workArea.name}');
    _notifyMapChanged();
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
    _notifyMapChanged();
  }

  /// Check whether a work area (by name) has been imported.
  bool isWorkAreaImported(String workAreaName) {
    if (_currentMap == null) return false;
    const workAreaLayerId = 'imported_work_areas';
    final layer = _currentMap!.getLayer(workAreaLayerId);
    if (layer == null) return false;
    return layer.polygons.any((p) => p.name == workAreaName);
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
    _notifyMapChanged();
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
    _notifyMapChanged();
  }

  /// Update layer metadata
  void updateLayer({
    required String layerId,
    String? name,
    String? description,
    Color? color,
  }) {
    if (_currentMap == null) return;

    final layer = _currentMap!.getLayer(layerId);
    if (layer == null) return;

    final updatedLayer = layer.copyWith(
      name: name,
      description: description,
      defaultColor: color,
    );

    _currentMap = _currentMap!.updateLayer(layerId, updatedLayer);
    debugPrint('Updated layer: ${updatedLayer.name}');
    _notifyMapChanged();
  }

  /// Toggle layer visibility
  void toggleLayerVisibility(String layerId) {
    if (_currentMap == null) return;
    _currentMap = _currentMap!.toggleLayerVisibility(layerId);
    debugPrint('Toggled visibility for layer: $layerId');
    _notifyMapChanged();
  }

  /// Toggle layer expanded state
  void toggleLayerExpanded(String layerId) {
    if (_currentMap == null) return;
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
    _notifyMapChanged();
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

  /// Add point to current drawing
  void addDrawingPoint(LatLng point) {
    if (!_isDrawing) return;
    if (_isDialogOpen) {
      debugPrint('⛔ Blocked drawing point - dialog is open');
      return;
    }
    _drawingPoints.add(point);
    debugPrint('Added drawing point: ${_drawingPoints.length}');
    notifyListeners();
  }

  /// Set dialog open state to block drawing
  void setDialogOpen(bool isOpen) {
    _isDialogOpen = isOpen;
    debugPrint('📝 Dialog open state: $isOpen');
  }

  /// Complete drawing and create element
  void completeDrawing({
    required String name,
    String description = '',
    Color? color,
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
        final point = MapPoint.create(
          name: name,
          description: description,
          position: _drawingPoints.first,
          color: color ?? layer.defaultColor,
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
    _notifyMapChanged();
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

    return _drawingPoints.asMap().entries.map((entry) {
      final index = entry.key;
      final point = entry.value;

      return Marker(
        markerId: MarkerId('drawing_point_$index'),
        position: point,
        icon: BitmapDescriptor.defaultMarkerWithHue(
          _drawingMode == DrawingMode.polygon
              ? BitmapDescriptor.hueBlue
              : BitmapDescriptor.hueOrange,
        ),
        alpha: 0.7,
        draggable: false,
        zIndexInt: 1000, // Above regular markers
        infoWindow: InfoWindow(
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

    // For polygons, close the shape by adding first point at end
    final points =
        _drawingMode == DrawingMode.polygon && _drawingPoints.length >= 3
            ? [..._drawingPoints, _drawingPoints.first]
            : _drawingPoints;

    return Polyline(
      polylineId: const PolylineId('drawing_preview'),
      points: points,
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
    _notifyMapChanged();
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
      _notifyMapChanged();
    }
  }

  /// Delete polygon
  void deletePolygon(MapLayer layer, int polygonIndex) {
    if (_currentMap == null) return;

    final updatedLayer = layer.removePolygon(polygonIndex);
    _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
    _selectedElementId = null;
    debugPrint('Deleted polygon at index $polygonIndex');
    _notifyMapChanged();
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
      _notifyMapChanged();
    }
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
    _notifyMapChanged();
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
      _notifyMapChanged();
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
    _notifyMapChanged();
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
    _notifyMapChanged();
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
    _notifyMapChanged();
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
    _notifyMapChanged();
  }

  // === MAP CONTROLLER ===

  /// Set the Google Maps controller
  void setMapController(GoogleMapController controller) {
    _mapController = controller;
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
      key: 'roadmap',
      label: 'Roadmap',
      icon: Icons.map_outlined,
      mapType: MapType.normal,
    ),
    MapBaseOption(
      key: 'satellite',
      label: 'Satellite',
      icon: Icons.satellite_alt,
      mapType: MapType.satellite,
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
      key: 'clean',
      label: 'Clean',
      icon: Icons.print,
      mapType: MapType.normal,
      styleJson: _cleanMapStyle,
      description: 'Minimal style for printing',
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
      key: 'silver',
      label: 'Silver',
      icon: Icons.brightness_medium,
      mapType: MapType.normal,
      styleJson: _silverMapStyle,
      description: 'Subtle silver tones',
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

    if (option.styleJson != null) {
      _mapType = option.mapType;
      _activeMapStyleJson = option.styleJson;
    } else {
      _mapType = option.mapType;
      _activeMapStyleJson = null;
    }

    notifyListeners();
  }

  // === UI STATE ===

  /// Toggle sidebar visibility
  void toggleSidebar() {
    _isSidebarVisible = !_isSidebarVisible;
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
  void dispose() {
    _stopRealtimeSync();
    _adapter?.dispose();
    _mapController?.dispose();
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
  final String? description;

  const MapBaseOption({
    required this.key,
    required this.label,
    required this.icon,
    required this.mapType,
    this.styleJson,
    this.description,
  });
}
