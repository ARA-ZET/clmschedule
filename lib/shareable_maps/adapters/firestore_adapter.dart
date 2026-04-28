import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/custom_polygon.dart';
import '../../providers/unfinished_work_areas_provider.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';
import '../services/shareable_maps_firestore_service.dart';
import 'map_data_adapter.dart';
import 'schedule_job_adapter.dart' show kUnfinishedAreasLayerId;

/// Adapter that bridges the ShareableMapEditor to Firestore persistence.
///
/// Every map lives under a monthly sub-collection:
///   `/shareableMaps/{MM-YYYY}/maps/{mapId}`
///
/// The adapter carries both the [monthKey] and [docId] so it can read/write
/// to the correct location. For new maps the first [save] call creates the
/// document and stores the generated ID for subsequent saves.
///
/// Supports **real-time sync**: after the first save (docId is known), call
/// [startListening] to receive a [Stream<ShareableMap?>] that emits whenever
/// the Firestore document is updated by anyone.
class FirestoreMapAdapter extends MapDataAdapter {
  final ShareableMapsFirestoreService _service;

  /// Monthly document key, e.g. '03-2026'.
  final String monthKey;

  /// Firestore document ID. Null for brand-new maps that haven't been saved yet.
  String? _docId;

  /// In-memory seed used when creating a brand-new map.
  final ShareableMap? _seed;

  /// Optional provider used to inject a read/write "Unfinished Areas" layer
  /// composed of polygons whose source item's `clients` match the map name.
  /// Only passed in schedule flavors.
  final UnfinishedWorkAreasProvider? _unfinishedProvider;

  /// Maps polygon name → source unfinished item id. Populated during [load]
  /// so we can route edits back to the right Firestore doc on [save].
  final Map<String, String> _polygonNameToUnfinishedId = {};

  /// Active snapshot subscription for real-time updates.
  StreamSubscription<ShareableMap?>? _subscription;

  /// Stream controller that re-broadcasts Firestore snapshots.
  StreamController<ShareableMap?>? _streamController;

  /// Create an adapter for an *existing* map.
  FirestoreMapAdapter.existing({
    required String docId,
    required this.monthKey,
    required ShareableMapsFirestoreService service,
    UnfinishedWorkAreasProvider? unfinishedProvider,
  })  : _docId = docId,
        _seed = null,
        _unfinishedProvider = unfinishedProvider,
        _service = service;

  /// Create an adapter for a *new* map that will be persisted on first save.
  FirestoreMapAdapter.create({
    required ShareableMap seed,
    required this.monthKey,
    required ShareableMapsFirestoreService service,
    UnfinishedWorkAreasProvider? unfinishedProvider,
  })  : _docId = null,
        _seed = seed,
        _unfinishedProvider = unfinishedProvider,
        _service = service;

  @override
  String get adapterId => 'firestore';

  @override
  String get displayName => _seed?.name ?? 'Shareable Map';

  /// The resolved Firestore document ID (available after first save).
  String? get docId => _docId;

  /// Whether a real-time listener is active.
  bool get isListening => _subscription != null;

  @override
  MapEditorCapabilities get capabilities => const MapEditorCapabilities(
        canDrawPolygons: true,
        canDrawPolylines: true,
        canDrawPoints: true,
        canImportKml: true,
        canImportGpx: true,
        canExport: true,
        canManageLayers: true,
        canEditStyle: true,
        canDelete: true,
        showSaveButton: true,
        readOnly: false,
      );

  @override
  Future<ShareableMap> load() async {
    final sw = Stopwatch()..start();
    debugPrint('[adapter.load] START (docId=$_docId, monthKey=$monthKey)');

    ShareableMap map;
    if (_docId != null) {
      final loaded = await _service.getMap(monthKey, _docId!);
      debugPrint(
          '[adapter.load] Firestore getMap done in ${sw.elapsedMilliseconds}ms');
      map = loaded ??
          _seed ??
          ShareableMap.createWithDefaultLayer(
            name: 'Untitled Map',
            description: '',
          );
    } else {
      map = _seed ??
          ShareableMap.createWithDefaultLayer(
            name: 'Untitled Map',
            description: '',
          );
    }

    // GPX layers from Cloud Storage are loaded by the provider's cloud
    // overlay system (deferred until the map controller is ready), so we
    // no longer block here.

    final unfinishedLayers = _buildUnfinishedLayers(map);
    if (unfinishedLayers.isNotEmpty) {
      map = map.copyWith(layers: [...map.layers, ...unfinishedLayers]);
    }

    debugPrint(
        '[adapter.load] TOTAL: ${sw.elapsedMilliseconds}ms (layers=${map.layers.length})');
    return map;
  }

  /// Build the "Unfinished Areas" layer by scanning [_unfinishedProvider]
  /// for items whose `clients` are referenced by the map's [name] (case
  /// insensitive substring match). Also populates
  /// [_polygonNameToUnfinishedId] for routing edits back on save.
  List<MapLayer> _buildUnfinishedLayers(ShareableMap map) {
    final provider = _unfinishedProvider;
    _polygonNameToUnfinishedId.clear();
    if (provider == null) {
      debugPrint('[UnfinishedLayer/Firestore] skipped: provider is null');
      return const [];
    }
    final mapNameLower = map.name.trim().toLowerCase();
    if (mapNameLower.isEmpty) {
      debugPrint('[UnfinishedLayer/Firestore] skipped: map name is empty');
      return const [];
    }
    debugPrint(
        '[UnfinishedLayer/Firestore] mapName="${map.name}" (norm="$mapNameLower") '
        'scanning ${provider.items.length} unfinished item(s)');

    final matchedPolygons = <CustomPolygon>[];
    for (final item in provider.items) {
      final hits = <String>[];
      for (final c in item.clients) {
        final cl = c.trim().toLowerCase();
        if (cl.isEmpty) continue;
        if (mapNameLower.contains(cl) || cl.contains(mapNameLower)) {
          hits.add(c);
        }
      }
      final hasMatch = hits.isNotEmpty;
      debugPrint(
          '[UnfinishedLayer/Firestore]  item "${item.id}" clients=${item.clients} '
          'polygons=${item.workMaps.where((p) => p.isPolygon).length} '
          'match=$hasMatch hits=$hits');
      if (!hasMatch) continue;

      for (final wm in item.workMaps.where((p) => p.isPolygon)) {
        if (wm.name.isEmpty) continue;
        matchedPolygons.add(CustomPolygon(
          name: wm.name,
          description: wm.description,
          points: List<LatLng>.from(wm.points),
          color: wm.color,
          fillOpacity: wm.fillOpacity,
          strokeWidth: wm.strokeWidth,
          type: wm.type,
        ));
        _polygonNameToUnfinishedId[wm.name] = item.id;
      }
    }

    debugPrint(
        '[UnfinishedLayer/Firestore] total matched polygons: ${matchedPolygons.length}');
    if (matchedPolygons.isEmpty) return const [];

    final now = DateTime.now();
    return [
      MapLayer(
        id: kUnfinishedAreasLayerId,
        name: 'Unfinished Areas',
        description: 'Matched from unfinished work areas by client name',
        order: map.layers.length,
        defaultColor: Colors.indigo.shade600,
        polygons: matchedPolygons,
        polylines: const [],
        points: const [],
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }

  @override
  Future<void> save(ShareableMap map) async {
    // Route polygons from the unfinished-areas layer back to their source
    // unfinished items, and strip that layer before persisting on the map.
    final unfinishedLayers = map.layers
        .where((l) => l.id == kUnfinishedAreasLayerId)
        .toList();
    final persistMap = unfinishedLayers.isEmpty
        ? map
        : map.copyWith(
            layers:
                map.layers.where((l) => l.id != kUnfinishedAreasLayerId).toList(),
          );

    if (_unfinishedProvider != null && unfinishedLayers.isNotEmpty) {
      final provider = _unfinishedProvider;
      final polysByItemId = <String, List<CustomPolygon>>{};
      for (final layer in unfinishedLayers) {
        for (final p in layer.polygons) {
          final itemId = _polygonNameToUnfinishedId[p.name];
          if (itemId == null) continue;
          polysByItemId.putIfAbsent(itemId, () => []).add(p);
        }
      }
      for (final entry in polysByItemId.entries) {
        try {
          await provider.updateItemWorkMaps(entry.key, entry.value);
        } catch (e) {
          debugPrint(
              '[UnfinishedLayer/Firestore] failed to update item ${entry.key}: $e');
        }
      }
    }

    if (_docId != null) {
      await _service.saveMap(monthKey, _docId!, persistMap);
    } else {
      // First save – create the document.
      _docId = await _service.createMap(persistMap, monthKey: monthKey);
      // Auto-start listening now that we have a docId.
      startListening();
    }
  }

  // ---------------------------------------------------------------------------
  // Real-time sync
  // ---------------------------------------------------------------------------

  /// Start listening for real-time Firestore changes on this map document.
  ///
  /// Returns a broadcast stream of [ShareableMap?] (null if deleted).
  /// Safe to call multiple times — subsequent calls return the existing stream.
  Stream<ShareableMap?>? startListening() {
    if (_docId == null) return null;
    if (_streamController != null) return _streamController!.stream;

    _streamController = StreamController<ShareableMap?>.broadcast();
    _subscription = _service.streamMap(monthKey, _docId!).listen(
      (map) {
        if (!_streamController!.isClosed) {
          _streamController!.add(map);
        }
      },
      onError: (e) {
        if (!_streamController!.isClosed) {
          _streamController!.addError(e);
        }
      },
    );

    return _streamController!.stream;
  }

  /// Stop the real-time listener.
  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
    _streamController?.close();
    _streamController = null;
  }

  /// Access the current stream (null if not listening).
  Stream<ShareableMap?>? get mapStream => _streamController?.stream;

  @override
  Future<void> dispose() async {
    stopListening();
  }
}
