import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute, listEquals, mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../letterbox/models/letterbox_suburb.dart';
import '../../letterbox/services/letterbox_count_service.dart';
import '../../letterbox/utils/letterbox_split.dart';
import '../../letterbox/utils/letterbox_clusters.dart';
import '../../models/custom_polygon.dart';
import '../../models/work_area.dart';
import '../../models/work_suburb.dart';
import '../../config/flavor_config.dart';
import '../../services/compiled_tracks_parser.dart';
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
import '../utils/drawn_gpx.dart';
import '../utils/gpx_track_rename.dart';
import '../utils/linked_map_polygons.dart';
import '../utils/polygon_topology.dart';
import '../utils/waypoint_spatial_index.dart';
import '../../utils/text_encoding.dart';

/// One polygon's finished letterbox count.
class LetterboxEstimateResult {
  final String? name;
  final LetterboxCount count;
  const LetterboxEstimateResult(this.name, this.count);
}

/// An area whose letterbox estimate leans on suburbs nobody has verified yet.
class UnverifiedLetterboxArea {
  final String layerId;
  final int polygonIndex;
  final CustomPolygon polygon;

  /// The contributing suburbs that are not verified, by current status.
  final List<LetterboxSuburb> suburbs;

  const UnverifiedLetterboxArea({
    required this.layerId,
    required this.polygonIndex,
    required this.polygon,
    required this.suburbs,
  });

  String get elementId => '${layerId}_polygon_$polygonIndex';
  String get displayName =>
      polygon.name.trim().isEmpty ? 'Unnamed area' : polygon.name.trim();
}

/// Every count that finished in one batch, announced together.
class LetterboxEstimateNotice {
  final List<LetterboxEstimateResult> results;
  const LetterboxEstimateNotice(this.results);

  int get total => results.fold(0, (sum, r) => sum + r.count.count);
  bool get isTrusted => results.every((r) => r.count.isTrusted);
}

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
      allPolylines.addAll(
          result.polylines.map((p) => p.copyWith(sourceFile: entry.name)));
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
// `_compiled_tracks.json` parsing lives in compiled_tracks_parser.dart
// (parseCompiledTracksBytes) so it can be shared with the print-map flow.

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

    final rawName = w['name'] as String?;
    final name =
        rawName != null ? repairMojibake(rawName) : 'Waypoint ${seq + 1}';
    final desc = repairMojibake((w['desc'] as String?) ?? '');

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

  /// Houses-versus-apartments split for a polygon info window. Read straight
  /// off the polygon, which stores it from the moment the shape was drawn,
  /// edited or imported — so opening an info window costs no fetch. Null only
  /// for non-polygons, or for a polygon whose split was never computed (drawn
  /// before the split existed, or estimated by hand).
  final LetterBoxSplit? letterboxBreakdown;

  /// The estimate the polygon was imported with, when a curated count has
  /// since replaced it. Shown beside the counted number rather than instead
  /// of it — see [CustomPolygon.importedLetterBoxEstimate].
  final int? importedLetterBoxEstimate;

  const InfoWindowData({
    required this.elementId,
    required this.layerId,
    required this.title,
    required this.description,
    required this.subtitle,
    required this.type,
    required this.anchor,
    this.letterBoxEstimate = 0,
    this.letterboxBreakdown,
    this.importedLetterBoxEstimate,
  });

  /// Same info window, with the breakdown filled in once a fallback compute
  /// resolves for a polygon that had none stored.
  InfoWindowData withLetterboxBreakdown(LetterBoxSplit breakdown) {
    return InfoWindowData(
      elementId: elementId,
      layerId: layerId,
      title: title,
      description: description,
      subtitle: subtitle,
      type: type,
      anchor: anchor,
      letterBoxEstimate: letterBoxEstimate,
      letterboxBreakdown: breakdown,
      importedLetterBoxEstimate: importedLetterBoxEstimate,
    );
  }
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
  // ── Automatic letterbox estimates ───────────────────────────────────
  // Same curated primitive the standalone Letterbox Index and the "Letter
  // Box Estimates" table both use. Constructed lazily and shared across
  // calls in this provider instance so its per-session suburb cache and
  // per-suburb payload cache are not rebuilt on every polygon.
  LetterboxCountService? _letterboxCounter;
  LetterboxCountService get _counter =>
      _letterboxCounter ??= LetterboxCountService();

  // ── Letterbox estimate notice ─────────────────────────────────────────
  //
  // Every finished count used to bump a version that each mounted editor
  // turned into its own SnackBar. ScaffoldMessenger queues SnackBars, so
  // importing 20 areas played 20 five-second notices back to back (long after
  // the counting had finished), and a second editor route still mounted
  // underneath — or one opened later — doubled or replayed them.
  //
  // Now counts are batched: results collect while any count is in flight and
  // ONE notice is published when the last one lands. The notice is taken, not
  // read ([takeEstimateNotice]), so however many widgets listen, it shows once.
  int _estimatesInFlight = 0;
  final List<LetterboxEstimateResult> _estimateBatch = [];
  LetterboxEstimateNotice? _estimateNotice;

  /// Letterbox counts still running — drives the "Counting…" indicator.
  int get estimatesInFlight => _estimatesInFlight;

  /// Whether a finished batch is waiting to be announced.
  bool get hasEstimateNotice => _estimateNotice != null;

  // ── Letterbox provenance (unverified suburbs) ─────────────────────────
  //
  // Each counted polygon stores the suburb ids its number came from. Whether
  // those suburbs are verified is looked up LIVE, never stored, so an area's
  // warning clears as soon as an admin verifies the suburb.
  Map<String, LetterboxSuburb>? _letterboxSuburbs;
  bool _loadingLetterboxSuburbs = false;

  /// Load (or, with [force], reload) suburb curation statuses. [force] drops
  /// the counter's session cache — for after an admin has verified suburbs
  /// elsewhere and this map should reflect it without a page reload.
  Future<void> refreshLetterboxStatuses({bool force = false}) async {
    if (_loadingLetterboxSuburbs) return;
    _loadingLetterboxSuburbs = true;
    try {
      if (force) _counter.invalidateAll();
      _letterboxSuburbs = await _counter.suburbsById();
    } catch (e) {
      debugPrint('[LetterboxEstimate] could not load suburb statuses: $e');
    } finally {
      _loadingLetterboxSuburbs = false;
      if (!_isDisposed) notifyListeners();
    }
  }

  /// The unverified suburbs behind [polygon]'s estimate, by current status.
  /// Empty when all are verified, or when statuses are not loaded yet.
  List<LetterboxSuburb> unverifiedSuburbsFor(CustomPolygon polygon) {
    if (polygon.letterBoxLocked) return const [];
    final ids = polygon.letterboxSuburbIds;
    final lookup = _letterboxSuburbs;
    if (ids == null || ids.isEmpty || lookup == null) return const [];
    return [
      for (final id in ids)
        if (lookup[id] case final suburb? when !suburb.isTrusted) suburb,
    ];
  }

  /// Every saved area on this map whose estimate uses unverified suburbs.
  List<UnverifiedLetterboxArea> get unverifiedLetterboxAreas {
    final map = _currentMap;
    if (map == null || _letterboxSuburbs == null) return const [];
    final out = <UnverifiedLetterboxArea>[];
    for (final layer in map.layers) {
      for (var i = 0; i < layer.polygons.length; i++) {
        final polygon = layer.polygons[i];
        if (!polygon.isPolygon) continue;
        final suburbs = unverifiedSuburbsFor(polygon);
        if (suburbs.isEmpty) continue;
        out.add(UnverifiedLetterboxArea(
          layerId: layer.id,
          polygonIndex: i,
          polygon: polygon,
          suburbs: suburbs,
        ));
      }
    }
    return out;
  }

  /// Areas with an index-style estimate (it has a houses/flats split) but no
  /// recorded suburbs — counted before provenance was stored, so whether they
  /// are verified is unknown until recounted.
  int get uncheckedLetterboxAreaCount {
    final map = _currentMap;
    if (map == null) return 0;
    var n = 0;
    for (final layer in map.layers) {
      for (final p in layer.polygons) {
        if (p.isPolygon &&
            !p.letterBoxLocked &&
            p.letterBoxSplit != null &&
            p.letterboxSuburbIds == null &&
            p.points.length >= 3) {
          n++;
        }
      }
    }
    return n;
  }

  /// Recount every area whose provenance is unknown, so its suburbs are
  /// recorded and any unverified ones are flagged.
  void recheckUncheckedLetterboxAreas() {
    final map = _currentMap;
    if (map == null || capabilities.readOnly) return;
    for (final layer in map.layers) {
      for (var i = 0; i < layer.polygons.length; i++) {
        final p = layer.polygons[i];
        if (p.isPolygon &&
            !p.letterBoxLocked &&
            p.letterBoxSplit != null &&
            p.letterboxSuburbIds == null &&
            p.points.length >= 3) {
          // ignore: unawaited_futures
          _autoEstimateLetterboxes(
            layerId: layer.id,
            polygonIndex: i,
            expectedPointCount: p.points.length,
          );
        }
      }
    }
  }

  /// Set an area's letterbox number by hand and lock it.
  ///
  /// This is how an admin resolves an area counted from unverified data: the
  /// typed number replaces the count, the houses/flats split and suburb
  /// provenance are dropped (they describe a number that is no longer shown),
  /// and no later edit recounts it until [unlockLetterboxEstimate].
  void setManualLetterboxEstimate(
    String layerId,
    int polygonIndex,
    int value, {
    required String setBy,
  }) {
    if (_currentMap == null || capabilities.readOnly) return;
    final layer = _currentMap!.getLayer(layerId);
    if (layer == null || polygonIndex >= layer.polygons.length) return;
    final current = layer.polygons[polygonIndex];
    updatePolygon(
      layer,
      polygonIndex,
      current.copyWith(
        letterBoxEstimate: value,
        clearLetterBoxSplit: true,
        letterBoxLocked: true,
        letterBoxLockedBy: setBy.isEmpty ? null : setBy,
        // Keep whatever figure it arrived with, like a recount would.
        importedLetterBoxEstimate: current.importedLetterBoxEstimate ??
            (current.letterBoxEstimate > 0 && !current.letterBoxLocked
                ? current.letterBoxEstimate
                : null),
      ),
    );
  }

  /// Release a hand-set number and count the area from the index again.
  void unlockLetterboxEstimate(String layerId, int polygonIndex) {
    if (_currentMap == null || capabilities.readOnly) return;
    final layer = _currentMap!.getLayer(layerId);
    if (layer == null || polygonIndex >= layer.polygons.length) return;
    final current = layer.polygons[polygonIndex];
    if (!current.letterBoxLocked) return;
    updatePolygon(
        layer, polygonIndex, current.copyWith(letterBoxLocked: false));
    // ignore: unawaited_futures
    _autoEstimateLetterboxes(
      layerId: layerId,
      polygonIndex: polygonIndex,
      expectedPointCount: current.points.length,
    );
  }

  /// Hand the pending notice to exactly one caller and clear it.
  LetterboxEstimateNotice? takeEstimateNotice() {
    final notice = _estimateNotice;
    _estimateNotice = null;
    return notice;
  }

  /// The letterbox module's breakdown, as the model type that gets stored on
  /// the polygon. Delegates to the module's own mapper so this and the track
  /// editor's Client Maps write cannot drift apart.
  static LetterBoxSplit _toSplit(LetterboxBreakdown b) => b.toLetterBoxSplit();

  /// Apply a curated count to [polygon], preserving whatever estimate it
  /// already carried.
  ///
  /// Every path that replaces an estimate with a counted one goes through
  /// here, so the rule lives in one place: the FIRST count to land on a
  /// polygon that already had a non-zero number stashes that number in
  /// [CustomPolygon.importedLetterBoxEstimate], and later recounts leave the
  /// stash alone. Without it, importing a "Target Areas" polygon into Client
  /// Maps silently destroys the figure the client was quoted on — the two
  /// numbers are both wanted, and only one of them can be recomputed.
  ///
  /// A locked polygon (a number someone set by hand) is returned unchanged —
  /// this is the single choke point that keeps every recount off it.
  static CustomPolygon _applyCount(
      CustomPolygon polygon, LetterboxCount count) {
    if (polygon.letterBoxLocked) return polygon;
    return polygon.copyWith(
      letterBoxEstimate: count.count,
      letterBoxSplit: _toSplit(count.breakdown),
      letterboxSuburbIds: List.unmodifiable(count.suburbIds),
      importedLetterBoxEstimate: polygon.importedLetterBoxEstimate ??
          (polygon.letterBoxEstimate > 0 ? polygon.letterBoxEstimate : null),
    );
  }

  /// Estimate the letterboxes in the polygon at [layerId]/[polygonIndex] and
  /// write the total back, without blocking whatever just finished (drawing
  /// or vertex editing) — this always runs after the polygon already exists
  /// on the map.
  ///
  /// [CustomPolygon] has no stable id once drawn (`completeDrawing` never
  /// sets one), so — matching this file's own existing convention for
  /// addressing a polygon transiently (see `startVertexEditing`'s
  /// `'${layerId}_polygon_$index'`) — this identifies the target positionally
  /// by layer id and index, captured at the moment the polygon was created or
  /// finished editing.
  ///
  /// That index can only drift if an EARLIER polygon in the same layer is
  /// deleted while this count is still in flight — a narrow window, but
  /// guarded anyway: the vertex count of whatever now sits at that index is
  /// compared against [expectedPointCount], and the write is skipped rather
  /// than risking the wrong polygon's estimate.
  Future<void> _autoEstimateLetterboxes({
    required String layerId,
    required int polygonIndex,
    required int expectedPointCount,
  }) async {
    final mapId = _currentMap?.id;
    if (mapId == null) return;

    MapLayer? findLayer() =>
        _currentMap?.layers.where((l) => l.id == layerId).firstOrNull;

    final layer = findLayer();
    if (layer == null || polygonIndex >= layer.polygons.length) return;
    final polygon = layer.polygons[polygonIndex];
    if (polygon.points.length < 3) return;
    if (polygon.letterBoxLocked) return;

    _estimatesInFlight++;
    if (_estimatesInFlight == 1) notifyListeners();
    try {
      final LetterboxCount result;
      try {
        result = await _counter.countIn(polygon.points);
      } catch (e) {
        debugPrint('[LetterboxEstimate] auto-calculate failed: $e');
        return;
      }

      // The map, or this layer's polygon list, may have changed while the
      // count ran — re-validate everything rather than trusting the captured
      // index blindly.
      if (_currentMap?.id != mapId) return;
      final freshLayer = findLayer();
      if (freshLayer == null || polygonIndex >= freshLayer.polygons.length) {
        return;
      }
      final current = freshLayer.polygons[polygonIndex];
      if (current.points.length != expectedPointCount) {
        debugPrint('[LetterboxEstimate] skipped — polygon at index '
            '$polygonIndex changed while counting');
        return;
      }
      // Locked by hand while the count was running.
      if (current.letterBoxLocked) return;

      updatePolygon(freshLayer, polygonIndex, _applyCount(current, result));
      _estimateBatch.add(LetterboxEstimateResult(current.name, result));
      // The count loaded the suburb list; share it with the provenance check.
      _letterboxSuburbs ??= await _counter.suburbsById();
    } finally {
      _estimatesInFlight--;
      if (_estimatesInFlight == 0) {
        // A notice for a map that has since been closed is stale.
        if (_estimateBatch.isNotEmpty && _currentMap?.id == mapId) {
          _estimateNotice =
              LetterboxEstimateNotice(List.unmodifiable(_estimateBatch));
        }
        _estimateBatch.clear();
        notifyListeners();
      }
    }
  }

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
  int _editingPointsVersion =
      0; // Monotonically incremented on every vertex mutation

  // ── Cloud overlay layers (ephemeral — never persisted to Firestore) ───
  final Map<String, MapLayer> _cloudTracksLayers = {};
  final Map<String, MapLayer> _cloudWaypointsLayers = {};
  final Set<String> _loadingCloudTrackFolders = {};
  final Set<String> _loadingCloudWaypointFolders = {};
  final Set<String> _loadedCloudTrackFolders = {};
  final Set<String> _loadedCloudWaypointFolders = {};

  // ── Waypoint spatial indexes (keyed by folder path) ──────────────────
  // Lets the editor viewport-cull waypoint markers and hit-test a tap
  // without holding a Marker object per waypoint.
  final Map<String, WaypointSpatialIndex> _cloudWaypointIndexes = {};

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

  /// Leave layers with nothing in them out of the sidebar. On by default:
  /// imports and folder links each leave a layer behind, and a map that has
  /// been worked on for a while ends up with more empty rows than real ones.
  /// Session-wide rather than per map — it is a viewing preference.
  bool _hideEmptyLayers = true;

  /// Layers added through "Add layer" (or the draw dialog) on this map in
  /// this session. They stay listed while still empty — a layer that
  /// vanishes the moment it is created looks like the create failed.
  final Set<String> _layersCreatedThisSession = {};
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
  int get editingPointsVersion => _editingPointsVersion;
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

  bool get hideEmptyLayers => _hideEmptyLayers;

  void setHideEmptyLayers(bool hide) {
    if (_hideEmptyLayers == hide) return;
    _hideEmptyLayers = hide;
    notifyListeners();
  }

  /// [layers] as the sidebar lists them.
  ///
  /// Cloud track and waypoint layers are never hidden here, empty or not:
  /// they are views of a linked folder, and an empty one still says which
  /// folder is linked and is where "Load waypoints" lives.
  List<MapLayer> get sidebarLayers {
    final all = layers;
    if (!_hideEmptyLayers) return all;
    return all
        .where((l) =>
            l.isNotEmpty ||
            isCloudOverlayLayer(l.id) ||
            _layersCreatedThisSession.contains(l.id))
        .toList();
  }

  /// Saved layers with nothing in them. Cloud overlays are not saved layers
  /// and are never included — see [sidebarLayers].
  List<MapLayer> get emptyLayers => (_currentMap?.layers ?? const <MapLayer>[])
      .where((l) => l.isEmpty)
      .toList();

  /// How many empty layers the sidebar is currently leaving out.
  int get hiddenEmptyLayerCount {
    if (!_hideEmptyLayers) return 0;
    return emptyLayers
        .where((l) => !_layersCreatedThisSession.contains(l.id))
        .length;
  }

  /// Delete every saved layer that holds nothing, and return how many went.
  ///
  /// Cloud track and waypoint layers are untouched: they are not stored on
  /// the map, so "removing" one could only mean unlinking its folder, which
  /// is a different decision from tidying up.
  int removeEmptyLayers() {
    final map = _currentMap;
    if (map == null) return 0;
    // Filter by content, not by id: layer ids are millisecond timestamps, so
    // two layers made in the same millisecond share one, and removing "the
    // empty one" by id would take its non-empty twin with it.
    final kept = map.layers.where((l) => l.isNotEmpty).toList();
    final removed = map.layers.length - kept.length;
    if (removed == 0) return 0;

    final next = map.copyWith(layers: kept);
    _currentMap = next;
    _layersCreatedThisSession.removeWhere((id) => next.getLayer(id) == null);
    if (_selectedLayerId != null && next.getLayer(_selectedLayerId!) == null) {
      _selectedLayerId = kept.isNotEmpty ? kept.first.id : null;
    }
    debugPrint('Removed $removed empty layer(s)');
    _notifyAndSave();
    return removed;
  }

  /// The layers a just-drawn element of [mode] can be added to: every saved
  /// layer, plus the cloud layers whose files can hold that kind of element —
  /// waypoint layers for a point, track layers for a line. A polygon has no
  /// GPX form, so it only ever goes into a saved layer.
  ///
  /// Every linked folder's cloud layer is offered, loaded or not and empty
  /// or not: which folder a drop belongs to does not depend on what has been
  /// downloaded this session.
  List<MapLayer> drawTargetsFor(DrawingMode mode) {
    final saved = _currentMap?.layers ?? const <MapLayer>[];
    final Iterable<MapLayer> cloud = switch (mode) {
      DrawingMode.point => _cloudWaypointsLayers.values,
      DrawingMode.polyline => _cloudTracksLayers.values,
      _ => const <MapLayer>[],
    };
    final sortedCloud = cloud.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return [...saved, ...sortedCloud];
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
    if (_mapController != null && latestFolder != null) {
      if (autoLoadLatestCloudFolder) {
        Future.microtask(() {
          if (_isDisposed) return;
          loadCloudFolderTracks(folderPath: latestFolder);
        });
      }
      if (autoLoadCloudWaypoints) {
        Future.microtask(() {
          if (_isDisposed) return;
          loadCloudFolderWaypoints(folderPath: latestFolder);
        });
      }
    }
    debugPrint('[loadFromAdapter] TOTAL: ${sw.elapsedMilliseconds}ms');
  }

  // ── Cloud folder loading (ephemeral — never saved to Firestore) ────────

  bool get isLoadingCloudTracks => _loadingCloudTrackFolders.isNotEmpty;
  bool get isLoadingCloudWaypoints => _loadingCloudWaypointFolders.isNotEmpty;
  bool get cloudTracksLoaded => _loadedCloudTrackFolders.isNotEmpty;
  bool get cloudWaypointsLoaded => _loadedCloudWaypointFolders.isNotEmpty;

  /// Spatial indexes for viewport hit-testing, keyed by folder path.
  Map<String, WaypointSpatialIndex> get cloudWaypointIndexes =>
      Map.unmodifiable(_cloudWaypointIndexes);

  /// Returns the cloud waypoint [MapLayer] shell for [folderPath], or null.
  MapLayer? cloudWaypointLayerForFolder(String folderPath) {
    final layerId = _cloudLayerId('waypoints', folderPath.trim());
    return _cloudWaypointsLayers[layerId];
  }

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

  bool get autoLoadCloudWaypoints =>
      _currentMap?.autoLoadCloudWaypoints ?? false;

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

    final bounds = _latLngBoundsFromPoints(polygon.points);

    final linkedFolders = folders.toSet();
    var reached = 0;
    for (final folderPath in linkedFolders) {
      // Prefer spatial index (dataset-backed layers have empty layer.points)
      final index = _cloudWaypointIndexes[folderPath];
      if (index != null) {
        final candidates = index.query(bounds, limit: 200000);
        for (final wpt in candidates) {
          if (_pointInPolygon(wpt.position, polygon.points)) reached++;
        }
      } else {
        final waypointLayerId = _cloudLayerId('waypoints', folderPath);
        final waypointLayer = _cloudWaypointsLayers[waypointLayerId];
        if (waypointLayer == null) continue;
        for (final point in waypointLayer.points) {
          if (_pointInPolygon(point.position, polygon.points)) reached++;
        }
      }
    }
    return reached;
  }

  /// Actual waypoint count for a cloud waypoint layer — uses the spatial
  /// index when available (dataset-backed, layer.points is empty).
  int cloudWaypointCountForLayer(String layerId) {
    final folderPath = cloudFolderForLayer(layerId)?.trim();
    if (folderPath == null) return 0;
    return _cloudWaypointIndexes[folderPath]?.count ??
        _cloudWaypointsLayers[layerId]?.points.length ??
        0;
  }

  static LatLngBounds _latLngBoundsFromPoints(List<LatLng> pts) {
    var minLat = pts[0].latitude;
    var maxLat = pts[0].latitude;
    var minLng = pts[0].longitude;
    var maxLng = pts[0].longitude;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
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
  static const String _targetAreasLayerName = MapLayer.targetAreasName;

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
      // Names are re-derived every time: linking a second folder must turn
      // the single-folder default names into per-month ones, and back.
      final trackLayer = _cloudTracksLayers[trackId] ??
          _cloudTrackLayerShell(folder, order: 900 + i * 2);
      _cloudTracksLayers[trackId] = _applyCloudTrackColor(
        folder,
        trackLayer.copyWith(
          order: 900 + i * 2,
          name: _cloudTrackLayerName(folder),
        ),
      );
      final waypointLayer = _cloudWaypointsLayers[waypointId] ??
          _cloudWaypointLayerShell(folder, order: 901 + i * 2);
      _cloudWaypointsLayers[waypointId] =
          waypointLayer.copyWith(name: _cloudWaypointLayerName(folder));
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

  /// A user rename always wins. Otherwise a map with one linked folder gets
  /// the plain [tracksLayerName]; with several, each layer is labelled by its
  /// month so they can be told apart until the user renames them.
  String _cloudTrackLayerName(String folderPath) {
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');
    final customName = _currentMap?.cloudLayerNames[cleanPath];
    if (customName != null) return customName;
    if (linkedCloudFolders.length <= 1) return tracksLayerName;
    return '${cloudFolderMonthLabel(folderPath)} Movements';
  }

  /// Same rule as [_cloudTrackLayerName], for the waypoints layer.
  String _cloudWaypointLayerName(String folderPath) {
    final cleanPath = folderPath.trim().replaceAll(RegExp(r'/+$'), '');
    final customName = _currentMap?.cloudLayerNames['wpt:$cleanPath'];
    if (customName != null) return customName;
    if (linkedCloudFolders.length <= 1) return waypointsLayerName;
    return '${cloudFolderMonthLabel(folderPath)} Letter Boxes';
  }

  MapLayer _cloudTrackLayerShell(String folderPath, {required int order}) {
    final now = DateTime.now();
    return MapLayer(
      id: _cloudLayerId('tracks', folderPath),
      name: _cloudTrackLayerName(folderPath),
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
    return MapLayer(
      id: _cloudLayerId('waypoints', folderPath),
      name: _cloudWaypointLayerName(folderPath),
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
    _cloudWaypointIndexes.clear();

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
    _layersCreatedThisSession.clear();

    // A boundary-cleanup snapshot belongs to the map it was taken from —
    // restoring it into a different map would write one map's polygons over
    // another's.
    _preCleanupLayers = null;
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
        // 'Layer 1' was the default layer name on maps made before
        // "Target Areas" became the default.
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
      _cloudWaypointIndexes.clear();
    } else {
      final trackId = _cloudLayerId('tracks', cleanPath!);
      final waypointId = _cloudLayerId('waypoints', cleanPath);
      _cloudTracksLayers.remove(trackId);
      _cloudWaypointsLayers.remove(waypointId);
      _loadedCloudTrackFolders.remove(cleanPath);
      _loadedCloudWaypointFolders.remove(cleanPath);
      _cloudWaypointIndexes.remove(cleanPath);
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

  /// When enabled, the latest linked folder's waypoints load as soon as the
  /// map opens. Independent of [setAutoLoadLatestCloudFolder] so maps that
  /// only have cloud waypoints (no tracks) can still auto-load.
  void setAutoLoadCloudWaypoints(bool value) {
    if (_currentMap == null) return;
    if (_currentMap!.autoLoadCloudWaypoints == value) return;
    _currentMap = _currentMap!.copyWith(autoLoadCloudWaypoints: value);
    _notifyAndSave();
    final latest = latestLinkedCloudFolder;
    if (value && latest != null) {
      Future.microtask(() {
        if (_isDisposed) return;
        loadCloudFolderWaypoints(folderPath: latest);
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
        final polylines =
            await compute(parseCompiledTracksBytes, compiledBytes);
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

        // Build spatial index for viewport hit-testing (always, regardless of dataset).
        final index = WaypointSpatialIndex();
        index.insertAll(clippedPoints
            .map((p) => WaypointMeta(
                  id: p.id,
                  name: p.name,
                  description: p.description,
                  position: p.position,
                ))
            .toList());
        _cloudWaypointIndexes[resolvedFolderPath] = index;

        final layerId = _cloudLayerId('waypoints', resolvedFolderPath);
        var layer = _cloudWaypointsLayers[layerId] ??
            _cloudWaypointLayerShell(resolvedFolderPath, order: 901);
        layer = layer.copyWith(points: clippedPoints);
        _cloudWaypointsLayers[layerId] = layer;
        _loadedCloudWaypointFolders.add(resolvedFolderPath);
        debugPrint(
            '[CloudWaypoints] DONE (compiled) in ${sw.elapsedMilliseconds}ms — '
            '${clippedPoints.length}/${points.length} waypoints');
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

      final clippedFallback = _clipCloudPointsToPolygons(result.points);

      final index = WaypointSpatialIndex();
      index.insertAll(clippedFallback
          .map((p) => WaypointMeta(
                id: p.id,
                name: p.name,
                description: p.description,
                position: p.position,
              ))
          .toList());
      _cloudWaypointIndexes[resolvedFolderPath] = index;

      final layerId = _cloudLayerId('waypoints', resolvedFolderPath);
      var layer = _cloudWaypointsLayers[layerId] ??
          _cloudWaypointLayerShell(resolvedFolderPath, order: 901);

      layer = layer.copyWith(points: clippedFallback);

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
          sourceFile: polyline.sourceFile,
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
      // Give new polygons their stable id in memory too, so the next edit
      // of the same polygon saves under the same id (the echoed snapshot
      // that would carry it back is ignored).
      if (_adapter is FirestoreMapAdapter) {
        _currentMap = _currentMap!.withStablePolygonIds();
      }
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
        if (now - _lastSaveTimestamp < 1500) {
          _adoptRemoteFolderLinks(remoteMap);
          return;
        }
      }

      // Don't apply remote changes while the user is actively drawing
      if (_isDrawing || _isEditingVertices) {
        _adoptRemoteFolderLinks(remoteMap);
        return;
      }

      // Apply the remote update
      debugPrint(
          '[RealtimeSync] Remote update received for map ${remoteMap.id}');
      _applyRemoteMap(remoteMap);
    });

    debugPrint('[RealtimeSync] Started listening for map ${adapter.docId}');
  }

  /// Take the folder links from a remote snapshot that is otherwise being
  /// skipped (mid-draw, or right after our own save).
  ///
  /// The `onJobListItemWritten` Cloud Function re-points a map at its job's
  /// folder when the job is renamed or moved. Saves write the whole document,
  /// so dropping that snapshot would let the next auto-save put the old
  /// folder back and unlink the map from the job's GPS data.
  void _adoptRemoteFolderLinks(ShareableMap remote) {
    final local = _currentMap;
    if (local == null) return;
    final same = local.storageFolderPath == remote.storageFolderPath &&
        local.jobListItemId == remote.jobListItemId &&
        listEquals(local.cloudFolderPaths, remote.cloudFolderPaths) &&
        mapEquals(local.cloudTrackColors, remote.cloudTrackColors) &&
        mapEquals(local.cloudLayerNames, remote.cloudLayerNames);
    if (same) return;
    debugPrint('[RealtimeSync] Adopting remote folder links for map '
        '${remote.id}: ${remote.cloudFolderPaths}');
    _currentMap = local.copyWith(
      updatedAt: local.updatedAt,
      jobListItemId: remote.jobListItemId,
      storageFolderPath: remote.storageFolderPath,
      clearStorageFolderPath: remote.storageFolderPath == null,
      cloudFolderPaths: remote.cloudFolderPaths,
      cloudTrackColors: remote.cloudTrackColors,
      cloudLayerNames: remote.cloudLayerNames,
    );
    _initCloudOverlays();
    notifyListeners();
  }

  /// Swap in a map the adapter has rebuilt (e.g. restyled after a change the
  /// adapter persisted itself), keeping selection and the open info window.
  /// Does not save.
  void applyAdapterMap(ShareableMap map) => _applyRemoteMap(map);

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

  /// Stop delivering remote edits, for when the editor leaves the screen.
  ///
  /// This provider is app-scoped — the Riverpod `ChangeNotifierProvider`
  /// holds one instance for the session — so popping the editor disposes the
  /// widgets but not the provider, and nothing else cancels the Firestore
  /// listener. Left running it keeps calling [notifyListeners] into a widget
  /// tree that has been unmounted, and every remote edit then trips
  /// `_lifecycleState != defunct` in the framework. It also keeps paying for
  /// snapshots of a map nobody is looking at.
  ///
  /// Deliberately NOT [_stopRealtimeSync]: that one also cancels the pending
  /// auto-save, and a debounced auto-save is unsaved work. Leaving the screen
  /// must not throw it away, so the timers are left to fire — they already
  /// guard themselves on [_isDisposed].
  ///
  /// Safe to call on the way out: every route into the editor goes through
  /// [loadFromAdapter], which starts the listener again.
  Future<void> pauseRealtimeSync() => _cancelRealtimeSubscription();

  /// Stop the real-time Firestore listener and cancel any pending
  /// auto-save / thumbnail timers. Awaiting the returned future ensures the
  /// underlying StreamSubscription has fully closed before a new listener
  /// is attached (prevents overlapping listeners during rapid map switches).
  Future<void> _stopRealtimeSync() async {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _thumbnailTimer?.cancel();
    _thumbnailTimer = null;
    await _cancelRealtimeSubscription();
  }

  /// Drop the Firestore listener alone, leaving pending local work in place.
  Future<void> _cancelRealtimeSubscription() async {
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
    _areaImportLayerId = null;
    debugPrint('Created new map: ${_currentMap!.name}');
    notifyListeners();
  }

  /// Load an existing map
  void loadMap(ShareableMap map) {
    _currentMap = map;
    if (_letterboxSuburbs == null) {
      // ignore: unawaited_futures
      refreshLetterboxStatuses();
    }
    _areaImportLayerId = null;
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
    _areaImportLayerId = null;
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

  // === WORK AREA & SUBURB IMPORT ===
  //
  // Work areas and suburbs both land in ONE "Target Areas" layer. The layer
  // is resolved once per session and remembered, so ticking areas from both
  // pickers never grows the layer list. Maps saved before this carry
  // "Work Areas"/"Suburbs" layers under the ids below — those are still read
  // (so an old import can be unticked) but never written to.

  static const _legacyWorkAreaLayerId = 'imported_work_areas';
  static const _legacySuburbLayerId = 'imported_suburbs';

  /// The layer this session's work-area/suburb imports go into.
  String? _areaImportLayerId;

  /// Default name for a new layer: "Target Areas", numbered if taken.
  String nextTargetAreasLayerName() {
    final names = layers.map((l) => l.name).toSet();
    if (!names.contains(MapLayer.targetAreasName)) {
      return MapLayer.targetAreasName;
    }
    var n = 2;
    while (names.contains('${MapLayer.targetAreasName} $n')) {
      n++;
    }
    return '${MapLayer.targetAreasName} $n';
  }

  /// Find — or, once per session, create — the import layer.
  MapLayer _resolveAreaImportLayer() {
    final map = _currentMap!;
    final remembered =
        _areaImportLayerId == null ? null : map.getLayer(_areaImportLayerId!);
    if (remembered != null) return remembered;

    MapLayer? layer;
    for (final l in map.layers) {
      if (l.name == MapLayer.targetAreasName) {
        layer = l;
        break;
      }
    }
    if (layer == null) {
      layer = MapLayer.create(
        name: MapLayer.targetAreasName,
        description: 'Imported from work areas and suburbs',
        order: map.layers.length,
        defaultColor: WorkArea.defaultColor,
      );
      _currentMap = map.addLayer(layer);
    }
    _areaImportLayerId = layer.id;
    return layer;
  }

  /// Layers an imported area may live in: this session's import layer (or
  /// the map's Target Areas layer) plus any legacy import layers.
  Iterable<MapLayer> _areaImportLayers() sync* {
    final map = _currentMap;
    if (map == null) return;
    final ids = <String>{};
    final remembered =
        _areaImportLayerId == null ? null : map.getLayer(_areaImportLayerId!);
    if (remembered != null) {
      ids.add(remembered.id);
      yield remembered;
    } else {
      for (final l in map.layers) {
        if (l.name == MapLayer.targetAreasName) {
          ids.add(l.id);
          yield l;
          break;
        }
      }
    }
    for (final id in const [_legacyWorkAreaLayerId, _legacySuburbLayerId]) {
      final l = map.getLayer(id);
      if (l != null && ids.add(id)) yield l;
    }
  }

  /// Add or refresh one imported area in the import layer.
  void _upsertImportedArea(CustomPolygon polygon, String sourceLabel) {
    final layer = _resolveAreaImportLayer();
    final layerId = layer.id;

    final existingIndex = layer.polygons.indexWhere(
      (p) =>
          ((polygon.id?.isNotEmpty ?? false) && p.id == polygon.id) ||
          p.name == polygon.name,
    );
    final MapLayer updatedLayer;
    final int index;
    if (existingIndex != -1) {
      updatedLayer = layer.updatePolygon(existingIndex, polygon);
      index = existingIndex;
    } else {
      updatedLayer = layer.addPolygon(polygon);
      index = updatedLayer.polygons.length - 1;
    }
    _currentMap = _currentMap!.updateLayer(layerId, updatedLayer);
    // Count once, here, so the imported area carries its own number and split
    // rather than inheriting the source's hand-entered estimate.
    // ignore: unawaited_futures
    _autoEstimateLetterboxes(
      layerId: layerId,
      polygonIndex: index,
      expectedPointCount: polygon.points.length,
    );
    debugPrint('${existingIndex != -1 ? 'Updated' : 'Added'} imported '
        '$sourceLabel on map: ${polygon.name}');
    _notifyAndSave();
  }

  /// Remove an imported area by name from whichever import layer holds it.
  /// The Target Areas layer is kept when emptied (it is the map's working
  /// layer); an emptied legacy layer is dropped.
  void _removeImportedArea(String name, String sourceLabel) {
    if (_currentMap == null) return;
    for (final layer in _areaImportLayers().toList()) {
      final index = layer.polygons.indexWhere((p) => p.name == name);
      if (index == -1) continue;
      final updatedLayer = layer.removePolygon(index);
      _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
      final isLegacy = layer.id == _legacyWorkAreaLayerId ||
          layer.id == _legacySuburbLayerId;
      if (isLegacy && updatedLayer.polygons.isEmpty) {
        _currentMap = _currentMap!.removeLayer(layer.id);
      }
      debugPrint('Removed $sourceLabel from map: $name');
      _notifyAndSave();
      return;
    }
  }

  bool _isAreaImported(String name) =>
      _areaImportLayers().any((l) => l.polygons.any((p) => p.name == name));

  /// Add a work area polygon to the map's Target Areas layer.
  void addWorkAreaToMap(WorkArea workArea, {Color? color}) {
    if (_currentMap == null) return;
    _upsertImportedArea(
      CustomPolygon(
        id: workArea.id,
        name: workArea.name,
        description: workArea.description,
        points: List<LatLng>.from(workArea.polygonPoints),
        color: color ?? workArea.color,
        fillOpacity: 0.25,
        strokeWidth: 2,
        letterBoxEstimate: workArea.letterBoxEstimate,
      ),
      'work area',
    );
  }

  /// Remove a previously imported work area polygon by name.
  void removeWorkAreaFromMap(String workAreaName) =>
      _removeImportedArea(workAreaName, 'work area');

  /// Check whether a work area (by name) has been imported.
  bool isWorkAreaImported(String workAreaName) => _isAreaImported(workAreaName);

  /// Add a suburb polygon to the map's Target Areas layer.
  void addSuburbToMap(WorkSuburb suburb) {
    if (_currentMap == null) return;
    _upsertImportedArea(
      CustomPolygon(
        id: suburb.id,
        name: suburb.name,
        description: suburb.description,
        points: List<LatLng>.from(suburb.polygonPoints),
        color: suburb.color,
        fillOpacity: 0.25,
        strokeWidth: 2,
        letterBoxEstimate: suburb.letterBoxEstimate,
      ),
      'suburb',
    );
  }

  /// Remove a previously imported suburb polygon by name.
  void removeSuburbFromMap(String suburbName) =>
      _removeImportedArea(suburbName, 'suburb');

  /// Check whether a suburb (by name) has been imported.
  bool isSuburbImported(String suburbName) => _isAreaImported(suburbName);

  /// Add multiple suburbs to the map at once.
  void addSuburbsToMap(List<WorkSuburb> suburbs) {
    for (final s in suburbs) {
      addSuburbToMap(s);
    }
  }

  // === LAYER OPERATIONS ===

  /// Create a new layer, select it, and return its id (null with no map).
  String? createLayer({
    required String name,
    String description = '',
    Color? color,
  }) {
    if (_currentMap == null) return null;

    final newLayer = MapLayer.create(
      name: name,
      description: description,
      order: _currentMap!.layers.length,
      defaultColor: color ?? _getNextLayerColor(),
    );

    _currentMap = _currentMap!.addLayer(newLayer);
    _selectedLayerId = newLayer.id;
    _layersCreatedThisSession.add(newLayer.id);
    debugPrint('Created layer: $name');
    _notifyAndSave();
    return newLayer.id;
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

  /// Cloud-track groups (one distributor's segments) the sidebar has opened.
  /// Keyed by [cloudTrackGroupKey]; session-only UI state, so every group
  /// starts collapsed.
  final Set<String> _expandedTrackGroups = {};

  static String cloudTrackGroupKey(String layerId, String groupId) =>
      '$layerId|$groupId';

  bool isTrackGroupExpanded(String key) => _expandedTrackGroups.contains(key);

  void toggleTrackGroupExpanded(String key) {
    if (!_expandedTrackGroups.remove(key)) _expandedTrackGroups.add(key);
    notifyListeners();
  }

  /// Animate the camera to fit every segment of one track and open a single
  /// info window for the whole track — the collapsed-group counterpart of
  /// [focusOnPolyline]. No one segment is highlighted, since the row stands
  /// for all of them.
  Future<void> focusOnPolylineGroup(
    String layerId,
    List<String> polylineIds, {
    required String title,
  }) async {
    final layer = _cloudTracksLayers[layerId] ??
        _currentMap?.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null) return;
    final ids = polylineIds.toSet();
    final segments = layer.polylines
        .where((p) => ids.contains(p.id) && p.points.isNotEmpty)
        .toList();
    if (segments.isEmpty) return;

    final allPoints = [for (final s in segments) ...s.points];
    double minLat = allPoints.first.latitude;
    double maxLat = minLat;
    double minLng = allPoints.first.longitude;
    double maxLng = minLng;
    double sumLat = 0, sumLng = 0;
    for (final pt in allPoints) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
      sumLat += pt.latitude;
      sumLng += pt.longitude;
    }

    final meters = segments.fold<double>(
        0, (s, p) => s + (p.distanceMeters ?? p.totalDistanceMeters));
    final km = meters / 1000;
    final parts = <String>[
      km < 1 ? '${meters.round()} m' : '${km.toStringAsFixed(2)} km',
    ];
    final durations = segments.map((p) => p.duration).whereType<Duration>();
    if (durations.isNotEmpty) {
      final total = durations.fold(Duration.zero, (a, b) => a + b);
      final h = total.inHours;
      final m = total.inMinutes % 60;
      parts.add(h > 0 ? '${h}h ${m}m' : '${m}m');
    }

    _selectedLayerId = layerId;
    _selectedElementId = null;
    _ignoreNextTap = true;
    _showStylePanel = false;
    _infoWindowData = InfoWindowData(
      elementId: segments.first.id,
      layerId: layerId,
      title: title.isNotEmpty ? title : 'Unnamed Track',
      description: segments.first.description,
      subtitle: parts.join(' · '),
      type: 'polyline',
      anchor: LatLng(sumLat / allPoints.length, sumLng / allPoints.length),
    );
    notifyListeners();

    if (_mapController == null) return;
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
  // void markIgnoreNextTap() {
  //   _ignoreNextTap = true;
  //   debugPrint('⏭️ Next tap will be ignored');
  // }

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

    // Snap before storing, so the vertex the user sees is the vertex that
    // gets saved — and is literally the neighbour's coordinate where one was
    // close enough.
    _drawingPoints.add(snapPosition(point));
    debugPrint(
        '[WASM-DEBUG] Added drawing point: total=${_drawingPoints.length}');
    notifyListeners();
  }

  /// Update a drawing point position while drawing.
  void updateDrawingPoint(int index, LatLng newPosition) {
    if (!_isDrawing) return;
    if (index < 0 || index >= _drawingPoints.length) return;
    _drawingPoints[index] = snapPosition(newPosition);
    notifyListeners();
  }

  /// Insert a drawing point at [index] while drawing.
  void insertDrawingPoint(int index, LatLng position) {
    if (!_isDrawing) return;
    if (index < 0 || index > _drawingPoints.length) return;
    _drawingPoints.insert(index, snapPosition(position));
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

  /// Complete drawing and create element.
  ///
  /// The element goes into [targetLayerId] when given, into a new layer
  /// called [newLayerName] when that is given instead, and otherwise into
  /// the selected layer. The target becomes the selected layer, so the next
  /// drawing offers the same one by default.
  ///
  /// Saved layers only — a cloud layer goes through [completeDrawingToCloud].
  void completeDrawing({
    required String name,
    String description = '',
    Color? color,
    PointCategory? pointCategory,
    String? targetLayerId,
    String? newLayerName,
  }) {
    if (!_isDrawing || _drawingPoints.isEmpty) return;
    if (_currentMap == null) return;

    final trimmedNewLayer = newLayerName?.trim();
    if (trimmedNewLayer != null && trimmedNewLayer.isNotEmpty) {
      createLayer(name: trimmedNewLayer);
    } else if (targetLayerId != null &&
        _currentMap!.getLayer(targetLayerId) != null) {
      _selectedLayerId = targetLayerId;
    }
    if (_selectedLayerId == null) return;

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

    if (_drawingMode == DrawingMode.polygon) {
      final polygonIndex = updatedLayer.polygons.length - 1;

      // Marry the new shape to whatever it was drawn against BEFORE counting:
      // stitching can add a vertex to it, and the estimate below validates
      // itself against the vertex count it expects to find.
      _stitchToNeighbours(_selectedLayerId!, polygonIndex);
      final stitched = _currentMap?.getLayer(_selectedLayerId!);
      final pointCount =
          stitched != null && polygonIndex < stitched.polygons.length
              ? stitched.polygons[polygonIndex].points.length
              : _drawingPoints.length;

      // Fire-and-forget: the polygon is already on the map and saved below,
      // so the estimate fills in a moment later rather than blocking
      // completion.
      // ignore: unawaited_futures
      _autoEstimateLetterboxes(
        layerId: _selectedLayerId!,
        polygonIndex: polygonIndex,
        expectedPointCount: pointCount,
      );
    }

    _clearDrawingState();
    _drawingMode = DrawingMode.none; // Switch back to select mode
    _ignoreNextTap = true; // Ignore the next tap after completing drawing
    debugPrint('Completed drawing: $name');
    _notifyAndSave();
  }

  /// Complete drawing into a cloud waypoints or tracks layer, by writing the
  /// element to that layer's Storage folder as a GPX file.
  ///
  /// A cloud layer is rebuilt from its folder on every load, so the file IS
  /// the element — anything added only in memory would be gone next time.
  /// Uploading triggers `compileGpxOnUpload`, which folds the file into the
  /// folder's compiled JSON in the background.
  ///
  /// Throws when the upload fails, and leaves the drawing in place so it can
  /// be retried or sent to a saved layer instead. Returns whether the element
  /// is already showing: it is added on screen only when that folder's data
  /// is loaded, because a lone point in an unloaded waypoint layer would
  /// read as the folder's whole count.
  Future<bool> completeDrawingToCloud({
    required String layerId,
    required String name,
    String description = '',
    PointCategory? pointCategory,
  }) async {
    if (!_isDrawing || _drawingPoints.isEmpty) return false;
    final folder = cloudFolderForLayer(layerId)?.trim();
    if (folder == null || folder.isEmpty) {
      throw StateError('Layer $layerId is not a cloud folder layer');
    }

    final isWaypoint = isCloudWaypointsLayer(layerId);
    final mode = _drawingMode;
    if (isWaypoint && mode != DrawingMode.point) {
      throw ArgumentError('Only points can go into a waypoints layer');
    }
    if (!isWaypoint && mode != DrawingMode.polyline) {
      throw ArgumentError('Only lines can go into a tracks layer');
    }
    final points = List<LatLng>.from(_drawingPoints);
    if (!isWaypoint && points.length < 2) return false;

    final gpx = isWaypoint
        ? drawnWaypointGpx(
            name: name, description: description, position: points.first)
        : drawnTrackGpx(name: name, description: description, points: points);
    final fileName = drawnGpxFileName(
        isWaypoint: isWaypoint, name: name, at: DateTime.now());

    await GpxStorageService().uploadGpxFile(folder, fileName, gpx);
    if (_isDisposed) return false;

    var shown = false;
    if (isWaypoint) {
      final layer = _cloudWaypointsLayers[layerId];
      if (layer != null && _loadedCloudWaypointFolders.contains(folder)) {
        final cat = pointCategory ?? PointCategory.generic;
        final point = MapPoint.create(
          name: name,
          description: description,
          position: points.first,
          color: cat.color,
          pointCategory: cat,
        );
        _cloudWaypointsLayers[layerId] =
            layer.copyWith(points: [...layer.points, point]);
        _cloudWaypointIndexes[folder]?.insertAll([
          WaypointMeta(
            id: point.id,
            name: name,
            description: description,
            position: point.position,
          ),
        ]);
        shown = true;
      }
    } else {
      final layer = _cloudTracksLayers[layerId];
      if (layer != null && _loadedCloudTrackFolders.contains(folder)) {
        final line = MapPolyline.create(
          name: name,
          description: description,
          points: points,
          color: cloudTrackColorForFolder(folder),
        );
        _cloudTracksLayers[layerId] =
            layer.copyWith(polylines: [...layer.polylines, line]);
        shown = true;
      }
    }

    debugPrint('[DrawToCloud] $fileName → $folder (shown=$shown)');
    _clearDrawingState();
    _drawingMode = DrawingMode.none;
    _ignoreNextTap = true;
    notifyListeners();
    return shown;
  }

  // === CLOUD TRACK RENAME ===

  /// The GPX files in cloud tracks layer [layerId] that hold a track shown as
  /// [oldBase] (see [baseTrackName]), with how many on-screen lines each one
  /// accounts for. Lines whose file isn't known — a compiled JSON from before
  /// the compiler recorded it — are counted under the empty key.
  Map<String, int> cloudTrackFilesNamed(String layerId, String oldBase) {
    final layer = _cloudTracksLayers[layerId];
    if (layer == null) return const {};
    final byFile = <String, int>{};
    for (final p in layer.polylines) {
      if (baseTrackName(p.name) != oldBase) continue;
      final file = p.sourceFile ?? '';
      byFile[file] = (byFile[file] ?? 0) + 1;
    }
    return byFile;
  }

  /// Rename the track shown as [oldBase] to [newBase] in each of [files]
  /// (names within the layer's cloud folder), by rewriting the GPX itself.
  ///
  /// A cloud tracks layer is rebuilt from its folder on every load, so the
  /// file is the only place a rename can live. With [renameFiles], a file
  /// whose own name contains [oldBase] is re-saved under the corrected name
  /// too — the Track Editor's report scanner reads the distributor from it.
  /// The new file is written before the old one is deleted, so a failure
  /// part-way never loses a track.
  ///
  /// Returns how many files were rewritten and how many of those renamed.
  Future<({int files, int filesRenamed})> renameCloudTracks({
    required String layerId,
    required String oldBase,
    required String newBase,
    required Set<String> files,
    required bool renameFiles,
  }) async {
    final folder = cloudFolderForLayer(layerId)?.trim();
    if (folder == null || folder.isEmpty || !isCloudTracksLayer(layerId)) {
      throw StateError('Layer $layerId is not a cloud tracks layer');
    }
    final storage = GpxStorageService();
    final existing = renameFiles
        ? (await storage.listFolderContents(folder))
            .files
            .map((f) => f.name)
            .toSet()
        : const <String>{};

    // Old file name → the name it has now.
    final written = <String, String>{};
    for (final file in files) {
      final bytes = await storage.downloadFileBytes('$folder/$file');
      if (bytes == null) throw StateError('Could not download "$file"');
      final edit = renameTracksInGpx(
        decodeTextBytes(bytes),
        oldBase: oldBase,
        newBase: newBase,
      );
      if (edit.renamed == 0) continue;

      var target = file;
      if (renameFiles) {
        final candidate = renamedGpxFileName(file, oldBase, newBase);
        final safe = candidate == null
            ? null
            : GpxStorageService.sanitizeFileName(candidate);
        // Keep the old name rather than overwrite another file, or flip the
        // "waypoint in the name" rule the fallback loader sorts files by.
        if (safe != null &&
            safe.isNotEmpty &&
            !existing.contains(safe) &&
            safe.toLowerCase().contains('waypoint') ==
                file.toLowerCase().contains('waypoint')) {
          target = safe;
        }
      }

      await storage.uploadGpxFile(folder, target, edit.gpx);
      if (target != file) {
        await storage.deleteFile('$folder/$file');
        existing
          ..remove(file)
          ..add(target);
      }
      written[file] = target;
    }

    if (written.isEmpty || _isDisposed) {
      return (files: written.length, filesRenamed: 0);
    }

    // The upload triggers recompile the folder on their own; this waits for
    // one that has seen every change, so a reload straight after shows it.
    try {
      await storage.callCompileGpxFolder(folder);
    } catch (e) {
      debugPrint('[CloudTrackRename] recompile failed (triggers will): $e');
    }
    if (_isDisposed) {
      return (files: written.length, filesRenamed: 0);
    }

    final layer = _cloudTracksLayers[layerId];
    final changedIds = <String>{};
    if (layer != null) {
      final polylines = <MapPolyline>[];
      for (final p in layer.polylines) {
        final target = written[p.sourceFile];
        if (target != null && baseTrackName(p.name) == oldBase) {
          changedIds.add(p.id);
          polylines.add(p.copyWith(
            name: renamedDisplayName(p.name, newBase),
            sourceFile: target,
          ));
        } else {
          polylines.add(p);
        }
      }
      _cloudTracksLayers[layerId] = layer.copyWith(polylines: polylines);
    }

    final iw = _infoWindowData;
    if (iw != null && changedIds.contains(iw.elementId)) {
      _infoWindowData = InfoWindowData(
        elementId: iw.elementId,
        layerId: iw.layerId,
        title: renamedDisplayName(iw.title, newBase),
        description: iw.description,
        subtitle: iw.subtitle,
        type: iw.type,
        anchor: iw.anchor,
        letterBoxEstimate: iw.letterBoxEstimate,
        letterboxBreakdown: iw.letterboxBreakdown,
        importedLetterBoxEstimate: iw.importedLetterBoxEstimate,
      );
    }

    final filesRenamed = written.entries.where((e) => e.key != e.value).length;
    debugPrint('[CloudTrackRename] "$oldBase" → "$newBase" in '
        '${written.length} file(s), $filesRenamed renamed, $folder');
    notifyListeners();
    return (files: written.length, filesRenamed: filesRenamed);
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

    _editingPoints![index] =
        snapPosition(newPosition, excludeElementId: _editingElementId);
    _editingPointsVersion++;
    if (!temporary) {
      _hasUnsavedChanges = true;
    }
    notifyListeners();
  }

  /// Insert a new editing point (midpoint drag to add vertex)
  void insertEditingPoint(int index, LatLng position) {
    if (_editingPoints == null) return;

    if (index >= 0 && index <= _editingPoints!.length) {
      _editingPoints!.insert(
          index, snapPosition(position, excludeElementId: _editingElementId));
      _editingPointsVersion++;
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
      _editingPointsVersion++;
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

      // Re-share the seams this edit touched before counting, so a corner
      // dragged onto a neighbour is the neighbour's corner rather than a
      // second one beside it.
      _stitchToNeighbours(layer.id, polygonIndex);
      final stitched = _currentMap?.getLayer(layer.id);
      final pointCount =
          stitched != null && polygonIndex < stitched.polygons.length
              ? stitched.polygons[polygonIndex].points.length
              : updatedPolygon.points.length;

      // Re-estimate now that the shape has changed — the boundary the user
      // just adjusted is exactly what should be reflected in the count.
      // ignore: unawaited_futures
      _autoEstimateLetterboxes(
        layerId: layer.id,
        polygonIndex: polygonIndex,
        expectedPointCount: pointCount,
      );
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
    _editingPointsVersion = 0;
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

  // === SHARED VERTICES (SNAP WHILE DRAWING) ===

  /// Whether a click while drawing latches onto nearby existing geometry.
  ///
  /// On by default, because a boundary drawn free-hand against a neighbour is
  /// never the same line twice, and every seam drawn that way is a gap or an
  /// overlap waiting to be found. Snapping makes the two polygons hold the
  /// SAME coordinate, which is the only way a shared boundary stays shared
  /// through later edits.
  bool _snapToNeighbours = true;
  bool get snapToNeighbours => _snapToNeighbours;

  void setSnapToNeighbours(bool value) {
    if (_snapToNeighbours == value) return;
    _snapToNeighbours = value;
    notifyListeners();
  }

  /// What the last snap latched onto, for the editor's cursor feedback.
  SnapKind _lastSnapKind = SnapKind.none;
  SnapKind get lastSnapKind => _lastSnapKind;

  /// Snap [raw] onto existing geometry, unless snapping is switched off.
  ///
  /// [excludeElementId] keeps a polygon from snapping to itself while its own
  /// vertices are being dragged — without it, dragging a corner past its
  /// neighbour in the same ring would weld the shape onto itself.
  LatLng snapPosition(LatLng raw, {String? excludeElementId}) {
    if (!_snapToNeighbours) {
      _lastSnapKind = SnapKind.none;
      return raw;
    }

    final excluded = _elementRef(excludeElementId);
    final result = PolygonTopology.snapPosition(
      raw,
      topologyRings(),
      exclude: excluded == null
          ? null
          : (ring) =>
              ring.layerId == excluded.$1 && ring.polygonIndex == excluded.$2,
    );
    _lastSnapKind = result.kind;
    return result.position;
  }

  /// Split an element id of the form `<layerId>_polygon_<index>` back into its
  /// parts. Returns null for anything else (polylines, points, no selection).
  (String, int)? _elementRef(String? elementId) {
    if (elementId == null) return null;
    final marker = elementId.lastIndexOf('_polygon_');
    if (marker < 0) return null;
    final index = int.tryParse(elementId.substring(marker + 9));
    if (index == null) return null;
    return (elementId.substring(0, marker), index);
  }

  /// Marry one polygon to its neighbours: weld the corners they share and
  /// insert its vertices into any neighbouring edge it sits on, so both sides
  /// of every seam hold the same points.
  ///
  /// Runs after a polygon is drawn or vertex-edited, scoped to that polygon,
  /// so it can never rework a boundary elsewhere on the map that the user did
  /// not touch. Returns the fix so the caller can refresh the estimates of
  /// whatever else moved.
  TopologyFix? _stitchToNeighbours(String layerId, int polygonIndex) {
    if (!_snapToNeighbours || _currentMap == null) return null;

    final rings = topologyRings();
    final focus = rings.indexWhere(
        (r) => r.layerId == layerId && r.polygonIndex == polygonIndex);
    if (focus < 0) return null;

    final fix = PolygonTopology.snap(
      rings,
      toleranceMetres: PolygonTopology.defaultSnapRadiusMetres,
      focus: {focus},
    );
    if (fix.isEmpty) return null;

    var map = _currentMap!;
    for (final index in fix.changed) {
      final ring = fix.rings[index];
      final layer = map.getLayer(ring.layerId);
      if (layer == null || ring.polygonIndex >= layer.polygons.length) continue;
      final polygons = List<CustomPolygon>.from(layer.polygons);
      polygons[ring.polygonIndex] =
          polygons[ring.polygonIndex].copyWith(points: ring.points);
      map = map.updateLayer(ring.layerId, layer.copyWith(polygons: polygons));
    }
    _currentMap = map;
    debugPrint('[Topology] stitched ${fix.changed.length} polygon(s) to the '
        'one just edited: ${fix.verticesMoved} welded, '
        '${fix.verticesInserted} inserted');

    // The neighbours whose edges gained a vertex now cover slightly different
    // ground, so their stored estimates are stale. The edited polygon itself
    // is left to the caller, which runs its own estimate and drives the
    // on-screen breakdown.
    final others = fix.changed.where((i) => i != focus).toSet();
    if (others.isNotEmpty) {
      // ignore: unawaited_futures
      _recountAfterCleanup(fix, only: others);
    }
    return fix;
  }

  // === BOUNDARY CLEANUP (TOPOLOGY) ===

  /// Layers whose polygons this map owns — the persisted ones. Cloud overlay
  /// layers are ephemeral and read-only, so boundary work never touches them.
  List<MapLayer> get _persistedLayers => _currentMap?.layers ?? const [];

  /// Every polygon eligible for a boundary pass, tagged with where it lives.
  ///
  /// Points, markers and polylines are excluded — only closed areas have a
  /// boundary to share. Pass [layerId] to scope the pass to one layer, which
  /// is what you want when a map keeps unrelated area sets (say suburbs under
  /// work areas) in separate layers and they are MEANT to overlap.
  List<TopologyRing> topologyRings({String? layerId}) {
    final rings = <TopologyRing>[];
    for (final layer in _persistedLayers) {
      if (layerId != null && layer.id != layerId) continue;
      for (var i = 0; i < layer.polygons.length; i++) {
        final polygon = layer.polygons[i];
        if (!polygon.isPolygon || polygon.points.length < 3) continue;
        rings.add(TopologyRing(
          layerId: layer.id,
          polygonIndex: i,
          name: polygon.name.trim().isEmpty
              ? 'Polygon ${i + 1}'
              : polygon.name.trim(),
          points: polygon.points,
        ));
      }
    }
    return rings;
  }

  /// Report the gaps and overlaps between this map's polygons. Read-only.
  TopologyReport analyzeBoundaries({
    double toleranceMetres = PolygonTopology.defaultToleranceMetres,
    String? layerId,
  }) {
    return PolygonTopology.analyze(
      topologyRings(layerId: layerId),
      toleranceMetres: toleranceMetres,
    );
  }

  /// Geometry as it was before the last [cleanBoundaries] run, for undo.
  List<MapLayer>? _preCleanupLayers;

  /// Whether the last boundary cleanup can still be rolled back.
  bool get canUndoBoundaryCleanup => _preCleanupLayers != null;

  /// Weld and snap the map's polygons to each other so shared boundaries are
  /// literally shared, then re-measure what is left.
  ///
  /// Fixes only what the tolerance can explain: vertices within
  /// [toleranceMetres] of a neighbour's corner or edge. A wider overlap is a
  /// drawing mistake rather than rounding, and clipping it automatically
  /// would silently delete ground someone drew on purpose — those come back
  /// in [BoundaryCleanupOutcome.remainingOverlapPairs] to be redrawn by hand.
  ///
  /// Every polygon that moves has its letterbox estimate recomputed unless
  /// [recountLetterboxes] is false: the estimate is a count of boxes inside
  /// the shape, so a shape that changed carries a stale number until it is
  /// re-run. The previous geometry is kept for one [undoBoundaryCleanup].
  Future<BoundaryCleanupOutcome> cleanBoundaries({
    double toleranceMetres = PolygonTopology.defaultToleranceMetres,
    String? layerId,
    bool recountLetterboxes = true,
  }) async {
    final rings = topologyRings(layerId: layerId);
    final before =
        PolygonTopology.analyze(rings, toleranceMetres: toleranceMetres);
    final fix = PolygonTopology.snap(rings, toleranceMetres: toleranceMetres);

    if (fix.isEmpty || _currentMap == null) {
      return BoundaryCleanupOutcome(
        rings: fix.rings,
        before: before,
        after: before,
        fix: fix,
        recounted: 0,
      );
    }

    // Snapshot for undo BEFORE anything is written.
    _preCleanupLayers = List<MapLayer>.from(_currentMap!.layers);

    // Apply per layer, in one pass per layer rather than one write per
    // polygon, so a 200-polygon map does not fire 200 auto-saves.
    final byLayer = <String, List<TopologyRing>>{};
    for (final index in fix.changed) {
      final ring = fix.rings[index];
      byLayer.putIfAbsent(ring.layerId, () => <TopologyRing>[]).add(ring);
    }

    var map = _currentMap!;
    for (final entry in byLayer.entries) {
      final layer = map.getLayer(entry.key);
      if (layer == null) continue;
      final polygons = List<CustomPolygon>.from(layer.polygons);
      for (final ring in entry.value) {
        if (ring.polygonIndex >= polygons.length) continue;
        polygons[ring.polygonIndex] =
            polygons[ring.polygonIndex].copyWith(points: ring.points);
      }
      map = map.updateLayer(entry.key, layer.copyWith(polygons: polygons));
    }
    _currentMap = map;
    debugPrint('[Topology] snapped ${fix.changed.length} polygon(s): '
        '${fix.verticesMoved} moved, ${fix.verticesInserted} inserted, '
        '${fix.verticesRemoved} duplicates removed');
    _notifyAndSave();

    var recounted = 0;
    if (recountLetterboxes) {
      recounted = await _recountAfterCleanup(fix);
    }

    final after = PolygonTopology.analyze(
      topologyRings(layerId: layerId),
      toleranceMetres: toleranceMetres,
    );

    return BoundaryCleanupOutcome(
      rings: fix.rings,
      before: before,
      after: after,
      fix: fix,
      recounted: recounted,
    );
  }

  /// Re-run the letterbox count for every polygon the cleanup moved.
  ///
  /// Batched through [LetterboxCountService.countInEach] so the suburb
  /// payloads behind them are downloaded once for the whole set rather than
  /// once per polygon. Each write is re-validated against the live map first —
  /// the counts are awaited, and the map can be edited or replaced meanwhile.
  Future<int> _recountAfterCleanup(TopologyFix fix, {Set<int>? only}) async {
    final indexes = only ?? fix.changed;
    final targets = indexes.map((i) => fix.rings[i]).toList();
    if (targets.isEmpty) return 0;

    final mapId = _currentMap?.id;
    if (mapId == null) return 0;

    List<LetterboxCount> counts;
    try {
      counts =
          await _counter.countInEach(targets.map((r) => r.points).toList());
    } catch (e) {
      debugPrint('[Topology] letterbox recount failed: $e');
      return 0;
    }
    if (_isDisposed || _currentMap?.id != mapId) return 0;

    var written = 0;
    var map = _currentMap!;
    for (var i = 0; i < targets.length && i < counts.length; i++) {
      final ring = targets[i];
      final layer = map.getLayer(ring.layerId);
      if (layer == null || ring.polygonIndex >= layer.polygons.length) continue;
      final polygon = layer.polygons[ring.polygonIndex];
      // The polygon at that index may have been edited or replaced while the
      // count ran — only write back to the exact shape that was counted.
      if (polygon.points.length != ring.points.length) continue;
      final polygons = List<CustomPolygon>.from(layer.polygons);
      polygons[ring.polygonIndex] = _applyCount(polygon, counts[i]);
      map = map.updateLayer(ring.layerId, layer.copyWith(polygons: polygons));
      written++;
    }
    if (written > 0) {
      _currentMap = map;
      _notifyAndSave();
    }
    return written;
  }

  /// Roll the map back to the geometry it had before the last cleanup.
  void undoBoundaryCleanup() {
    final snapshot = _preCleanupLayers;
    if (snapshot == null || _currentMap == null) return;
    _preCleanupLayers = null;
    _currentMap = _currentMap!.copyWith(layers: snapshot);
    debugPrint('[Topology] boundary cleanup undone');
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
    // Callers (e.g. a dialog) may hold a layer from before other edits;
    // write into the current one so those edits aren't rolled back.
    layer = _currentMap!.getLayer(layer.id) ?? layer;

    final polylines = List<MapPolyline>.from(layer.polylines);
    final polylineIndex = polylines.indexWhere((p) => p.id == polylineId);

    if (polylineIndex != -1) {
      polylines[polylineIndex] = updatedPolyline;
      final updatedLayer = layer.copyWith(polylines: polylines);
      _currentMap = _currentMap!.updateLayer(layer.id, updatedLayer);
      _retitleInfoWindow(polylineId, updatedPolyline.name);
      debugPrint('Updated polyline: ${updatedPolyline.name}');
      _notifyAndSave();
    }
  }

  /// Keep an open info window's title in step with its element's name.
  void _retitleInfoWindow(String elementId, String title) {
    final iw = _infoWindowData;
    if (iw == null || iw.elementId != elementId || iw.title == title) return;
    _infoWindowData = InfoWindowData(
      elementId: iw.elementId,
      layerId: iw.layerId,
      title: title,
      description: iw.description,
      subtitle: iw.subtitle,
      type: iw.type,
      anchor: iw.anchor,
      letterBoxEstimate: iw.letterBoxEstimate,
      letterboxBreakdown: iw.letterboxBreakdown,
      importedLetterBoxEstimate: iw.importedLetterBoxEstimate,
    );
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
    // Before the update notifies, so the card rebuilds with the new title.
    _retitleInfoWindow(elementId, newName);

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
    if (latest != null) {
      if (autoLoadLatestCloudFolder &&
          !_loadedCloudTrackFolders.contains(latest)) {
        Future.microtask(() {
          if (_isDisposed) return;
          loadCloudFolderTracks(folderPath: latest);
        });
      }
      if (autoLoadCloudWaypoints &&
          !_loadedCloudWaypointFolders.contains(latest)) {
        Future.microtask(() {
          if (_isDisposed) return;
          loadCloudFolderWaypoints(folderPath: latest);
        });
      }
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

  /// Select a point, open its info window, and animate the camera to it —
  /// mirrors [focusOnPolyline] for marker elements.
  Future<void> focusOnPoint(String layerId, String pointId) async {
    if (_currentMap == null) return;

    MapPoint? found;
    String resolvedLayerId = layerId;
    for (final layer in _currentMap!.layers) {
      final match = layer.points.where((p) => p.id == pointId).firstOrNull;
      if (match != null) {
        found = match;
        resolvedLayerId = layer.id;
        break;
      }
    }
    if (found == null) return;

    _selectedLayerId = resolvedLayerId;
    _selectedElementId = pointId;
    _ignoreNextTap = true;
    _showStylePanel = false;
    notifyListeners(); // update selection highlight before animation

    if (_mapController == null) return;
    await _mapController!.animateCamera(
      CameraUpdate.newLatLng(found.position),
    );

    // Open the info window AFTER the camera has settled so _latLngToScreen
    // in the ValueListenableBuilder uses the final (centred) camera position,
    // not the pre-animation position which would place the overlay off-target.
    _infoWindowData = InfoWindowData(
      elementId: pointId,
      layerId: resolvedLayerId,
      title: found.name.isNotEmpty ? found.name : 'Unnamed Point',
      description: found.description,
      subtitle: '',
      type: 'point',
      anchor: found.position,
    );
    notifyListeners();
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
  ///
  /// For a polygon, the houses/apartments split comes straight off the stored
  /// polygon — no fetch, nothing to wait for. Only a polygon that has never
  /// had one computed falls back to [_backfillInfoWindowSplit].
  void openInfoWindow(InfoWindowData data) {
    _selectedLayerId = data.layerId;
    _selectedElementId = data.elementId;
    _showStylePanel = false;

    if (data.type == 'polygon' && data.letterboxBreakdown == null) {
      final stored = _polygonFor(data.elementId, data.layerId)?.letterBoxSplit;
      _infoWindowData =
          stored == null ? data : data.withLetterboxBreakdown(stored);
      notifyListeners();
      if (stored == null) {
        // ignore: unawaited_futures
        _backfillInfoWindowSplit(
            elementId: data.elementId, layerId: data.layerId);
      }
      return;
    }

    _infoWindowData = data;
    notifyListeners();
  }

  /// Resolve a polygon from the positional element id the map uses
  /// (`'<layerId>_polygon_<index>'`). Null when it no longer resolves.
  CustomPolygon? _polygonFor(String elementId, String layerId) {
    final match = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(elementId);
    if (match == null) return null;
    final layer = _currentMap?.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null) return null;
    final index = int.parse(match.group(2)!);
    if (index >= layer.polygons.length) return null;
    return layer.polygons[index];
  }

  /// One-time backfill for a polygon that predates stored splits: compute the
  /// split, show it, and store it so this never runs for that polygon again.
  ///
  /// Skipped entirely on a read-only map — someone merely viewing a shared
  /// link must not trigger writes. There, the split is shown for this session
  /// without being persisted.
  Future<void> _backfillInfoWindowSplit({
    required String elementId,
    required String layerId,
  }) async {
    final polygon = _polygonFor(elementId, layerId);
    if (polygon == null || polygon.points.length < 3) return;
    final expectedPointCount = polygon.points.length;

    LetterboxCount result;
    try {
      result = await _counter.countIn(polygon.points);
    } catch (e) {
      debugPrint('[InfoWindow] letterbox split backfill failed: $e');
      return;
    }
    final split = _toSplit(result.breakdown);

    // Only apply if this exact info window is still the one open — the user
    // may have tapped elsewhere, or closed it, while the fetch was running.
    if (_infoWindowData?.elementId != elementId ||
        _infoWindowData?.layerId != layerId) {
      return;
    }
    _infoWindowData = _infoWindowData!.withLetterboxBreakdown(split);
    notifyListeners();

    if (capabilities.readOnly) return;

    // Store it, so the next open is instant. Re-resolve first: the polygon
    // may have been edited or deleted while the count ran, and a stale split
    // is worse than none.
    final layer = _currentMap?.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null) return;
    final index = int.parse(
        RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(elementId)!.group(2)!);
    if (index >= layer.polygons.length) return;
    final current = layer.polygons[index];
    if (current.points.length != expectedPointCount ||
        current.letterBoxSplit != null ||
        current.letterBoxLocked) {
      return;
    }
    updatePolygon(
      layer,
      index,
      current.copyWith(
        letterBoxSplit: split,
        letterboxSuburbIds:
            current.letterboxSuburbIds ?? List.unmodifiable(result.suburbIds),
      ),
    );
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
    if (_isWorkAreaPickerVisible) {
      _pickerWorkAreasVisible = true;
    }
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

  /// Update a lasso point position (vertex drag).
  void updateLassoPoint(int index, LatLng newPosition) {
    if (!_isLassoSelectActive) return;
    if (index < 0 || index >= _lassoPoints.length) return;
    _lassoPoints[index] = newPosition;
    notifyListeners();
  }

  /// Insert a new lasso point at [index] (midpoint drag to add vertex).
  void insertLassoPoint(int index, LatLng position) {
    if (!_isLassoSelectActive) return;
    if (index < 0 || index > _lassoPoints.length) return;
    _lassoPoints.insert(index, position);
    notifyListeners();
  }

  /// Remove the lasso point at [index] (vertex delete — min 3 must remain).
  void removeLassoPointAt(int index) {
    if (_lassoPoints.length <= 3) return;
    if (index < 0 || index >= _lassoPoints.length) return;
    _lassoPoints.removeAt(index);
    notifyListeners();
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

  // === REFERENCE LAYER (adapter-supplied, never saved back) ===

  /// The adapter's reference layer — a schedule job's linked client map —
  /// or null when the adapter has none or it isn't loaded.
  MapLayer? get referenceLayer {
    final id = _adapter?.referenceLayerId;
    if (id == null) return null;
    return _currentMap?.getLayer(id);
  }

  /// Rebuild the reference layer from the adapter, leaving every other layer
  /// (and any unsaved edits in them) alone. Call after the backing entity's
  /// link changes — e.g. right after linking a client map in the editor.
  Future<void> refreshReferenceLayer() async {
    final adapter = _adapter;
    final id = adapter?.referenceLayerId;
    if (adapter == null || id == null || _currentMap == null) return;

    final layer = await adapter.loadReferenceLayer();
    if (_isDisposed || _currentMap == null) return;

    final existing = _currentMap!.getLayer(id);
    if (layer == null) {
      if (existing == null) return;
      _currentMap = _currentMap!.removeLayer(id);
    } else if (existing == null) {
      _currentMap = _currentMap!.addLayer(layer);
    } else {
      _currentMap = _currentMap!.updateLayer(id, layer);
    }
    // Deliberately no _notifyAndSave: nothing the user owns has changed.
    notifyListeners();
  }

  // ── Recorded tracks from the linked map(s), as on the print map ───────

  bool _isLoadingReferenceTracks = false;

  /// True while the tracks overlay is downloading.
  bool get isLoadingReferenceTracks => _isLoadingReferenceTracks;

  /// True when the adapter can supply a tracks overlay, so the editor knows
  /// whether to offer the toggle at all.
  bool get supportsReferenceTracks => _adapter?.hasReferenceTracks ?? false;

  /// True when the tracks overlay is loaded and currently drawn.
  bool get referenceTracksVisible {
    final id = _adapter?.referenceTracksLayerId;
    if (id == null) return false;
    return _currentMap?.getLayer(id)?.isVisible ?? false;
  }

  /// Show or hide the linked map(s)' recorded tracks. Downloaded on first
  /// use rather than at load, since most editing sessions never ask for
  /// them; after that the toggle just flips the layer's visibility.
  Future<void> toggleReferenceTracks() async {
    final adapter = _adapter;
    final id = adapter?.referenceTracksLayerId;
    if (adapter == null || id == null || _currentMap == null) return;

    final existing = _currentMap!.getLayer(id);
    if (existing != null) {
      toggleLayerVisibility(id);
      return;
    }

    _isLoadingReferenceTracks = true;
    notifyListeners();
    MapLayer? layer;
    try {
      layer = await adapter.loadReferenceTracksLayer();
    } catch (e) {
      debugPrint('[referenceTracks] load failed: $e');
    }
    if (_isDisposed) return;
    _isLoadingReferenceTracks = false;
    if (layer != null && _currentMap != null) {
      _currentMap = _currentMap!.addLayer(layer);
    }
    // Deliberately no _notifyAndSave: the overlay is never part of the map.
    notifyListeners();
  }

  /// Copy [polygons] out of the reference layer into the map's own layer, so
  /// they become the entity's ground (a schedule job's work areas) rather
  /// than a picture of someone else's. Adopted polygons leave the reference
  /// layer, so the same outline is never drawn twice.
  ///
  /// Returns how many were actually adopted — outlines the map already holds
  /// are skipped.
  int adoptReferenceLayerPolygons(List<CustomPolygon> polygons) {
    if (_currentMap == null || polygons.isEmpty) return 0;
    final refId = _adapter?.referenceLayerId;
    final tracksId = _adapter?.referenceTracksLayerId;

    MapLayer? target;
    for (final l in _currentMap!.layers) {
      if (l.id != refId && l.id != tracksId) {
        target = l;
        break;
      }
    }
    if (target == null) return 0;

    final existing = target.polygons.map(polygonGeometryKey).toSet();
    var updated = target;
    final adopted = <CustomPolygon>[];
    for (final p in polygons) {
      if (!existing.add(polygonGeometryKey(p))) continue;
      final copy = allocatedPolygonStyle(
          p.copyWith(points: List<LatLng>.from(p.points)));
      updated = updated.addPolygon(copy);
      adopted.add(copy);
    }
    if (adopted.isEmpty) return 0;
    _currentMap = _currentMap!.updateLayer(updated.id, updated);

    final ref = refId == null ? null : _currentMap!.getLayer(refId);
    if (ref != null) {
      final taken = adopted.map(polygonGeometryKey).toSet();
      final kept = ref.polygons
          .where((p) => !taken.contains(polygonGeometryKey(p)))
          .toList();
      if (kept.length != ref.polygons.length) {
        _currentMap = kept.isEmpty
            ? _currentMap!.removeLayer(refId!)
            : _currentMap!.updateLayer(refId!, ref.copyWith(polygons: kept));
      }
    }

    _notifyAndSave();
    return adopted.length;
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
    _cloudWaypointIndexes.clear();
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
