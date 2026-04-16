import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/shareable_map.dart';
import '../services/shareable_maps_firestore_service.dart';
import 'map_data_adapter.dart';

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

  /// Active snapshot subscription for real-time updates.
  StreamSubscription<ShareableMap?>? _subscription;

  /// Stream controller that re-broadcasts Firestore snapshots.
  StreamController<ShareableMap?>? _streamController;

  /// Create an adapter for an *existing* map.
  FirestoreMapAdapter.existing({
    required String docId,
    required this.monthKey,
    required ShareableMapsFirestoreService service,
  })  : _docId = docId,
        _seed = null,
        _service = service;

  /// Create an adapter for a *new* map that will be persisted on first save.
  FirestoreMapAdapter.create({
    required ShareableMap seed,
    required this.monthKey,
    required ShareableMapsFirestoreService service,
  })  : _docId = null,
        _seed = seed,
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

    debugPrint(
        '[adapter.load] TOTAL: ${sw.elapsedMilliseconds}ms (layers=${map.layers.length})');
    return map;
  }

  @override
  Future<void> save(ShareableMap map) async {
    if (_docId != null) {
      await _service.saveMap(monthKey, _docId!, map);
    } else {
      // First save – create the document.
      _docId = await _service.createMap(map, monthKey: monthKey);
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
