import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../services/geocoding_service.dart';
import '../models/csg_region.dart';
import '../models/csg_township.dart';
import '../models/erf_area.dart';
import '../models/erf_list_entry.dart';
import '../models/erf_task.dart';
import '../models/erf_property.dart';
import '../models/erf_search_scope.dart';
import '../services/csg_property_service.dart';
import '../services/erf_area_storage_service.dart';
import '../services/erf_list_parser.dart';
import '../services/erf_property_firestore_service.dart';

/// Riverpod provider for ErfPropertyProvider.
final erfPropertyRiverpod =
    riverpod.ChangeNotifierProvider<ErfPropertyProvider>(
        (ref) => ErfPropertyProvider());

/// Provider for managing ERF property data.
///
/// Responsibilities:
/// - Searching the CSG cadastral region list so any suburb can be downloaded
/// - Downloading parcels by region or map extent, cached per [ErfArea]
/// - Resolving a pasted list of addresses / ERF numbers to actual parcels
/// - Holding the resulting selection for the map and the KML export
class ErfPropertyProvider extends ChangeNotifier {
  ErfPropertyProvider({
    CsgPropertyService? csgService,
    ErfPropertyFirestoreService? firestoreService,
    ErfAreaStorageService? areaStorage,
    GeocodingService? geocodingService,
  })  : _csgService = csgService ?? CsgPropertyService(),
        _firestoreService = firestoreService ?? ErfPropertyFirestoreService(),
        _areaStorage = areaStorage ?? ErfAreaStorageService(),
        _geocodingService = geocodingService ?? GeocodingService();

  final CsgPropertyService _csgService;
  final ErfPropertyFirestoreService _firestoreService;
  final ErfAreaStorageService _areaStorage;
  final GeocodingService _geocodingService;

  /// Parcels already pulled from Storage this session, keyed by area id.
  ///
  /// An area is one file, so re-opening it (or resolving a pasted list
  /// against it) costs nothing after the first read.
  final Map<String, List<ErfProperty>> _areaCache = {};

  StreamSubscription? _areaSubscription;
  bool _initialized = false;
  bool _legacyProbeDone = false;

  /// True when Firestore holds ERF parcels that belong to no area yet — data
  /// saved before areas existed. The UI offers to import it.
  bool _hasUnimportedData = false;
  bool get hasUnimportedData => _hasUnimportedData;

  // ── Downloaded areas ────────────────────────────────────────────────

  List<ErfArea> _areas = [];
  List<ErfArea> get areas => _areas;

  ErfArea? _activeArea;
  ErfArea? get activeArea => _activeArea;

  /// Parcels of the currently active area (or of the last lookup).
  List<ErfProperty> _properties = [];
  List<ErfProperty> get properties => _properties;

  // ── Status ──────────────────────────────────────────────────────────

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  ErfTask? _task;

  /// The operation the user is currently waiting on, with its stages.
  ErfTask? get task => _task;

  bool _cancelRequested = false;

  String? _error;
  String? get error => _error;

  int get totalFetched => _task?.done ?? 0;

  /// Ask the running task to stop at the next safe point.
  void cancelTask() {
    if (_task == null || !_task!.cancellable) return;
    _cancelRequested = true;
    _task = _task!.copyWith(cancelling: true);
    notifyListeners();
  }

  bool get _stopRequested => _cancelRequested;

  void _beginTask(ErfTask task) {
    _cancelRequested = false;
    _task = task;
    _isLoading = true;
    _error = null;
    notifyListeners();
  }

  void _updateTask(ErfTask Function(ErfTask task) update) {
    final current = _task;
    if (current == null) return;
    _task = update(current);
    notifyListeners();
  }

  void _endTask() {
    _task = null;
    _isLoading = false;
    _cancelRequested = false;
    notifyListeners();
  }

  // ── Selection (the pasted list) ─────────────────────────────────────

  List<ErfMatch> _matches = [];

  /// Every pasted entry with its lookup result, in the order pasted.
  List<ErfMatch> get matches => _matches;

  /// Parcels that resolved, ready for the map and the KML export.
  List<ErfProperty> get selectedProperties => _matches
      .map((m) => m.resolvedProperty)
      .whereType<ErfProperty>()
      .toList();

  /// Pasted entries that did not resolve to a parcel.
  List<ErfListEntry> get unmatchedEntries => _matches
      .where((m) => m.status != ErfMatchStatus.matched)
      .map((m) => m.entry)
      .toList();

  bool get hasSelection => selectedProperties.isNotEmpty;

  /// Label used to name the map and the exported file.
  String _selectionLabel = 'ERF Selection';
  String get selectionLabel => _selectionLabel;

  /// Where ERF-number lookups may draw candidates from.
  ///
  /// Defaults to Cape Town because that is where the work is, and because an
  /// unscoped lookup is actively misleading: "ERF 1234" returns the server's
  /// record cap filled entirely with Gauteng parcels, so the Cape Town ones
  /// never surface at all.
  ErfSearchScope _scope = ErfSearchScope.capeTown;
  ErfSearchScope get scope => _scope;

  set scope(ErfSearchScope value) {
    if (_scope == value) return;
    _scope = value;
    notifyListeners();
  }

  // ── Lifecycle ───────────────────────────────────────────────────────

  /// Start watching the list of downloaded areas.
  ///
  /// Only the small area documents are streamed; parcels are loaded on
  /// demand by [openArea], because a single suburb can hold thousands of
  /// polygon documents.
  void initialize() {
    if (_initialized) return;

    // Rules require a signed-in user, so subscribing early would only raise
    // a permission error. Note this leaves _initialized false on purpose:
    // the next call, once sign-in has completed, subscribes for real.
    if (FirebaseAuth.instance.currentUser == null) {
      debugPrint('ℹ️ Skipping ERF area stream until the user signs in.');
      _areas = const [];
      _activeArea = null;
      _error = null;
      notifyListeners();
      return;
    }

    _initialized = true;

    _areaSubscription = _firestoreService.streamAreas().listen(
      (areas) {
        _areas = areas;
        // Keep the active area's counters fresh.
        final active = _activeArea;
        if (active != null) {
          for (final area in areas) {
            if (area.id == active.id) {
              _activeArea = area;
              break;
            }
          }
        }
        notifyListeners();
        _probeForLegacyData();
      },
      onError: (e) {
        debugPrint('❌ ErfPropertyProvider area stream error: $e');
        _error = 'Could not load downloaded areas: $e';
        notifyListeners();
      },
    );
  }

  /// Costs one document read, and only when no areas exist: if there are
  /// parcels but nothing describing them, the collection was written by an
  /// earlier version and needs importing.
  Future<void> _probeForLegacyData() async {
    if (_legacyProbeDone || _areas.isNotEmpty) return;
    _legacyProbeDone = true;

    final hasParcels = await _firestoreService.hasAnyProperties();
    if (hasParcels && _areas.isEmpty) {
      _hasUnimportedData = true;
      notifyListeners();
    }
  }

  /// Convert ERF data saved as individual Firestore documents into packed
  /// Storage files.
  ///
  /// Order matters: every area's file is uploaded and read back before any
  /// document is deleted, so an interruption can only leave duplicated data,
  /// never lost data. Re-running is safe.
  ///
  /// Returns the number of parcels converted.
  Future<int> importSavedData() async {
    _beginTask(ErfTask(
      title: 'Converting saved ERF data',
      stages: const [
        ErfStage(label: 'Scan existing documents'),
        ErfStage(label: 'Pack each area into a file'),
        ErfStage(label: 'Verify the files read back'),
        ErfStage(label: 'Free the old documents'),
      ],
    ));

    try {
      _updateTask((t) => t.activateStage(0, detail: 'Reading…'));

      final legacy = await _firestoreService.loadLegacyProperties(
        onProgress: (scanned) {
          _updateTask((t) => t
              .copyWith(done: scanned)
              .withDetail('${_formatCount(scanned)} parcels found'));
        },
      );

      if (legacy.isEmpty) {
        _hasUnimportedData = false;
        return 0;
      }

      // Group by cadastral region, falling back to the suburb tag.
      final groups = <String, List<ErfProperty>>{};
      for (final property in legacy) {
        final areaId = ErfArea.idForProperty(
          minCode: property.minCode,
          minRegion: property.minRegion,
          suburb: property.suburb,
        );
        groups.putIfAbsent(areaId, () => <ErfProperty>[]).add(property);
      }

      final converted = <ErfArea>[];
      final reclaimable = <String>[];
      var packed = 0;

      _updateTask((t) => t
          .copyWith(done: 0, total: legacy.length)
          .activateStage(1,
              detail: '${groups.length} '
                  '${groups.length == 1 ? 'area' : 'areas'} to pack'));

      for (final entry in groups.entries) {
        final areaId = entry.key;
        final parcels = entry.value;
        final sample = parcels.first;
        final name = sample.minRegion.isNotEmpty
            ? sample.minRegion
            : (sample.suburb?.isNotEmpty == true
                ? sample.suburb!
                : 'Saved ERFs');

        _updateTask((t) => t.activateStage(1,
            detail: 'Packing $name (${_formatCount(parcels.length)})'));

        final tagged =
            parcels.map((p) => p.copyWith(areaId: areaId)).toList();

        final bytes = await _areaStorage.save(
          areaId: areaId,
          name: name,
          properties: tagged,
        );

        // Read it back before trusting it with the only copy.
        _updateTask((t) => t.activateStage(2, detail: 'Checking $name'));
        final verify = await _areaStorage.load(areaId);
        if (verify == null || verify.length != tagged.length) {
          throw StateError(
            'Packed file for $name did not read back correctly '
            '(${verify?.length ?? 0} of ${tagged.length} parcels). '
            'Nothing was deleted.',
          );
        }

        final area = ErfArea(
          id: areaId,
          name: name,
          source: sample.minCode.isNotEmpty
              ? ErfAreaSource.region
              : ErfAreaSource.boundingBox,
          propertyCount: tagged.length,
          downloadedAt: DateTime.now(),
          minCode: sample.minCode.isEmpty ? null : sample.minCode,
          minRegion: sample.minRegion.isEmpty ? null : sample.minRegion,
          majRegion: sample.majRegion.isEmpty ? null : sample.majRegion,
          province: sample.province.isEmpty ? null : sample.province,
          bounds: ErfBounds.fromPoints(
            tagged
                .map((p) => p.centroid)
                .where((c) => c.latitude != 0 || c.longitude != 0)
                .toList(),
          ),
          storagePath: ErfAreaStorageService.pathFor(areaId),
          storageBytes: bytes,
        );

        await _firestoreService.saveArea(area);
        _areaCache[areaId] = tagged;
        converted.add(area);
        reclaimable.addAll(parcels.map((p) => p.id));
        packed += tagged.length;

        _updateTask((t) => t.copyWith(done: packed));
      }

      // Only now that every parcel is safely in a file it can be read from.
      _updateTask((t) => t.copyWith(done: 0, total: reclaimable.length).
          activateStage(3,
              detail: '${_formatCount(reclaimable.length)} documents'));

      await _firestoreService.deletePropertiesByIds(
        reclaimable,
        onProgress: (deleted) {
          _updateTask((t) => t.copyWith(done: deleted).withDetail(
              '${_formatCount(deleted)} of '
              '${_formatCount(reclaimable.length)} freed'));
        },
      );

      _hasUnimportedData = false;

      if (converted.isNotEmpty) {
        final largest = converted
            .reduce((a, b) => a.propertyCount >= b.propertyCount ? a : b);
        _endTask();
        await openArea(largest);
      }

      return packed;
    } catch (e) {
      _updateTask((t) => t.failActiveStage('$e'));
      _error = 'Could not import saved ERF data: $e';
      debugPrint('❌ importSavedData error: $e');
      return 0;
    } finally {
      _endTask();
    }
  }

  // ── Region search ───────────────────────────────────────────────────

  /// Search the CSG cadastral register for suburbs matching [query].
  ///
  /// Throws [CsgException] when the register cannot be reached, so the
  /// caller can tell "server down" apart from "no such suburb".
  Future<List<CsgRegion>> searchRegions(String query) async {
    if (query.trim().length < 2) return [];
    return _csgService.searchRegions(query);
  }

  // ── Suburb boundaries (the map picker) ──────────────────────────────

  List<CsgTownship> _townships = [];

  /// Suburb boundaries currently drawn on the picker map.
  List<CsgTownship> get townships => _townships;

  bool _isLoadingTownships = false;
  bool get isLoadingTownships => _isLoadingTownships;

  /// Load suburb boundaries covering a map view.
  ///
  /// Kept separate from [task] because this is a fast, incidental fetch that
  /// happens while panning — it should not raise the full progress panel.
  Future<void> loadTownships(ErfBounds bounds) async {
    _isLoadingTownships = true;
    notifyListeners();

    try {
      _townships = await _csgService.queryTownshipsInBounds(
        minLat: bounds.minLat,
        minLng: bounds.minLng,
        maxLat: bounds.maxLat,
        maxLng: bounds.maxLng,
      );
      _error = null;
    } on CsgException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Could not load suburb boundaries: $e';
    } finally {
      _isLoadingTownships = false;
      notifyListeners();
    }
  }

  /// Re-fetch a suburb's complete boundary before it is counted or
  /// downloaded, so parts that were off-screen are not left out.
  Future<CsgTownship> completeTownship(CsgTownship township) async {
    final full = await _csgService.fetchTownshipByCode(
      code: township.code,
      name: township.name,
    );
    return (full != null && full.hasGeometry) ? full : township;
  }

  /// How many parcels lie inside a suburb boundary.
  Future<int> countTownshipParcels(CsgTownship township) =>
      _csgService.countByPolygon(township);

  /// Download every parcel inside a suburb boundary.
  ///
  /// Preferred over [downloadRegion] wherever the suburb is not its own
  /// cadastral region — which in the Western Cape is nearly everywhere.
  Future<int> downloadTownship(
    CsgTownship township, {
    int? expectedTotal,
  }) {
    final areaId = ErfArea.idForTownship(township.code, township.name);

    return _runDownload(
      title: 'Downloading ${township.name}',
      areaId: areaId,
      expectedTotal: expectedTotal,
      buildArea: (id, properties) {
        final sample = properties.first;
        return ErfArea(
          id: id,
          name: township.name,
          source: ErfAreaSource.township,
          propertyCount: properties.length,
          downloadedAt: DateTime.now(),
          minCode: township.code.isEmpty ? null : township.code,
          minRegion: township.name,
          majRegion: sample.majRegion.isEmpty ? null : sample.majRegion,
          province: sample.province.isEmpty ? null : sample.province,
          bounds: township.bounds ??
              ErfBounds.fromPoints(
                  properties.map((p) => p.centroid).toList()),
        );
      },
      fetch: (onProgress) => _csgService.queryAllByPolygon(
        township: township,
        onProgress: (loaded, _) => onProgress(loaded),
        shouldStop: () => _stopRequested,
      ),
      suburb: township.name,
    );
  }

  // ── Sizing ──────────────────────────────────────────────────────────

  /// How many parcels a download would pull, so the user can be warned
  /// before starting one that runs for hours.
  Future<int> countRegionParcels(CsgRegion region) =>
      _csgService.countByMinCode(region.minCode);

  Future<int> countBoundsParcels(ErfBounds bounds) =>
      _csgService.countByBoundingBox(
        minLat: bounds.minLat,
        minLng: bounds.minLng,
        maxLat: bounds.maxLat,
        maxLng: bounds.maxLng,
      );

  // ── Downloads ───────────────────────────────────────────────────────

  /// Download every parcel in a cadastral region and cache it as an area.
  ///
  /// [expectedTotal] comes from the caller's pre-flight count and is what
  /// turns the progress bar into a real percentage with a time estimate.
  ///
  /// Returns the number of parcels saved.
  Future<int> downloadRegion(CsgRegion region, {int? expectedTotal}) async {
    if (region.minCode.isEmpty) {
      _error = 'That suburb has no cadastral code to download by.';
      notifyListeners();
      return 0;
    }

    return _runDownload(
      title: 'Downloading ${region.minRegion}',
      areaId: ErfArea.idForRegion(region),
      expectedTotal: expectedTotal,
      buildArea: (id, properties) {
        // The township layer the search runs against carries only the name
        // and code, so the major region and province are taken from the
        // parcels themselves once they arrive.
        final sample = properties.first;
        return ErfArea(
          id: id,
          name: region.minRegion,
          source: ErfAreaSource.region,
          propertyCount: properties.length,
          downloadedAt: DateTime.now(),
          minCode: region.minCode,
          minRegion:
              region.minRegion.isNotEmpty ? region.minRegion : sample.minRegion,
          majRegion:
              region.majRegion.isNotEmpty ? region.majRegion : sample.majRegion,
          province:
              region.province.isNotEmpty ? region.province : sample.province,
          bounds: ErfBounds.fromPoints(
              properties.map((p) => p.centroid).toList()),
        );
      },
      fetch: (onProgress) => _csgService.queryAllByMinCode(
        minCode: region.minCode,
        onProgress: (loaded, _) => onProgress(loaded),
        shouldStop: () => _stopRequested,
      ),
      suburb: region.minRegion,
    );
  }

  /// Download every parcel intersecting [bounds] and cache it as an area.
  Future<int> downloadBounds(
    ErfBounds bounds, {
    required String name,
    int? expectedTotal,
  }) {
    return _runDownload(
      title: 'Downloading $name',
      areaId: ErfArea.idForBounds(bounds),
      expectedTotal: expectedTotal,
      buildArea: (id, properties) => ErfArea(
        id: id,
        name: name,
        source: ErfAreaSource.boundingBox,
        propertyCount: properties.length,
        downloadedAt: DateTime.now(),
        bounds: bounds,
      ),
      fetch: (onProgress) => _csgService.queryAllInBoundingBox(
        minLat: bounds.minLat,
        minLng: bounds.minLng,
        maxLat: bounds.maxLat,
        maxLng: bounds.maxLng,
        onProgress: (loaded, _) => onProgress(loaded),
        shouldStop: () => _stopRequested,
      ),
      suburb: name,
    );
  }

  Future<int> _runDownload({
    required String title,
    required String areaId,
    required int? expectedTotal,
    required ErfArea Function(String id, List<ErfProperty> properties)
        buildArea,
    required Future<List<ErfProperty>> Function(void Function(int loaded))
        fetch,
    required String suburb,
  }) async {
    _beginTask(ErfTask(
      title: title,
      total: expectedTotal,
      cancellable: true,
      stages: const [
        ErfStage(label: 'Fetch parcels from the register'),
        ErfStage(label: 'Pack into a single file'),
        ErfStage(label: 'Upload and record the area'),
      ],
    ));

    try {
      _updateTask((t) => t.activateStage(0,
          detail: expectedTotal == null
              ? 'Contacting the register…'
              : 'Expecting ${_formatCount(expectedTotal)} parcels'));

      final results = await fetch((loaded) {
        _updateTask((t) => t.copyWith(done: loaded).withDetail(
              expectedTotal == null
                  ? '${_formatCount(loaded)} parcels so far'
                  : '${_formatCount(loaded)} of '
                      '${_formatCount(expectedTotal)} parcels',
            ));
      });

      if (results.isEmpty) {
        _error = _stopRequested
            ? 'Download stopped before any parcels arrived.'
            : 'No ERF parcels came back for $suburb.';
        return 0;
      }

      final stopped = _stopRequested;
      final tagged = results
          .map((p) => p.copyWith(suburb: suburb, areaId: areaId))
          .toList();

      // Hold the parcels before attempting to store them. A download costs
      // minutes of the register's time, so if saving fails the user still
      // has the data for this session rather than having to fetch it again.
      _areaCache[areaId] = tagged;
      _properties = tagged;

      _updateTask((t) => t
          .copyWith(done: tagged.length, total: tagged.length)
          .activateStage(1,
              detail: 'Compressing ${_formatCount(tagged.length)} parcels'));

      try {
        // One Storage object and one Firestore document, rather than a
        // document per parcel.
        final bytes = await _areaStorage.save(
          areaId: areaId,
          name: suburb,
          properties: tagged,
        );

        _updateTask((t) => t.activateStage(2,
            detail: '${(bytes / 1024).round()} KB stored'));

        final area = buildArea(areaId, tagged).copyWith(
          storagePath: ErfAreaStorageService.pathFor(areaId),
          storageBytes: bytes,
        );
        await _firestoreService.saveArea(area);
        _activeArea = area;

        _updateTask((t) => t.activateStage(t.stages.length));
      } catch (e) {
        debugPrint('❌ Could not store area $areaId: $e');
        _updateTask((t) => t.failActiveStage('$e'));
        _error = 'Downloaded ${tagged.length} parcels, but saving them '
            'failed: $e\n\nThey are loaded for this session — you can map '
            'and export them now, but they will not persist.';
      }

      if (stopped && _error == null) {
        _error = 'Stopped early — saved the '
            '${_formatCount(tagged.length)} parcels fetched so far.';
      }

      debugPrint('✅ Downloaded ${tagged.length} parcels into $areaId');
      return tagged.length;
    } catch (e) {
      _updateTask((t) => t.failActiveStage('$e'));
      _error = e.toString();
      debugPrint('❌ ERF download error: $e');
      return 0;
    } finally {
      _endTask();
    }
  }

  static String _formatCount(int value) => value.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'),
        (m) => '${m[1]} ',
      );

  /// Load a previously downloaded area's parcels into [properties].
  Future<void> openArea(ErfArea area) async {
    // Already in memory: no task panel for something instantaneous.
    final cached = _areaCache[area.id];
    if (cached != null) {
      _properties = cached;
      _activeArea = area;
      _error = null;
      notifyListeners();
      return;
    }

    _beginTask(ErfTask(
      title: 'Opening ${area.name}',
      stages: [
        ErfStage(
          label: area.isPacked
              ? 'Download the area file'
              : 'Read the stored parcels',
          detail: area.sizeLabel.isEmpty ? null : area.sizeLabel,
        ),
        const ErfStage(label: 'Unpack parcels'),
      ],
    ));

    try {
      _updateTask((t) => t.activateStage(0));
      final parcels = await _parcelsFor(area);

      _updateTask((t) => t.activateStage(1,
          detail: '${_formatCount(parcels.length)} parcels'));
      _properties = parcels;
      _activeArea = area;
      _updateTask((t) => t.activateStage(t.stages.length));
    } catch (e) {
      _updateTask((t) => t.failActiveStage('$e'));
      _error = 'Could not load ${area.name}: $e';
      debugPrint('❌ openArea error: $e');
    } finally {
      _endTask();
    }
  }

  /// An area's parcels, from the session cache, then Storage, then — for
  /// areas written before the switch to packed files — Firestore.
  Future<List<ErfProperty>> _parcelsFor(ErfArea area) async {
    final cached = _areaCache[area.id];
    if (cached != null) return cached;

    List<ErfProperty>? parcels;
    if (area.isPacked) {
      parcels = await _areaStorage.load(area.id);
    }
    // Legacy areas, and packed areas whose file has gone missing, still have
    // their parcels as individual documents.
    parcels ??= await _firestoreService.getPropertiesByArea(area.id);

    _areaCache[area.id] = parcels;
    return parcels;
  }

  /// Delete a downloaded area and all of its parcels.
  Future<void> deleteArea(ErfArea area) async {
    _isLoading = true;
    notifyListeners();
    try {
      await _areaStorage.delete(area.id);
      await _firestoreService.deleteArea(area.id);
      _areaCache.remove(area.id);
      if (_activeArea?.id == area.id) {
        _activeArea = null;
        _properties = [];
      }
    } catch (e) {
      _error = 'Could not delete ${area.name}: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Pasted list resolution ──────────────────────────────────────────

  /// Parse [text] without looking anything up, so the UI can preview how the
  /// lines were understood.
  List<ErfListEntry> parseList(String text) => ErfListParser.parse(text);

  /// Resolve a pasted list of addresses and/or ERF numbers to parcels.
  ///
  /// Resolution order per entry:
  ///  1. ERF number against the cache, then against CSG
  ///  2. street address via geocoding, then the parcel containing that point
  ///
  /// [region] narrows ERF-number lookups to one suburb, which matters
  /// because ERF numbers are only unique within a cadastral region. Without
  /// it, entries that match several suburbs come back as
  /// [ErfMatchStatus.ambiguous] for the user to resolve.
  Future<List<ErfMatch>> resolveList(
    String text, {
    CsgRegion? region,
    String? label,
  }) async {
    final entries = ErfListParser.parse(text);
    _matches = entries.map(ErfMatch.pending).toList();
    _selectionLabel = (label != null && label.trim().isNotEmpty)
        ? label.trim()
        : (region?.minRegion ?? 'ERF Selection');
    _beginTask(ErfTask(
      title: 'Matching ${entries.length} '
          '${entries.length == 1 ? 'entry' : 'entries'}',
      total: entries.length,
      stages: const [
        ErfStage(label: 'Read the pasted list'),
        ErfStage(label: 'Match ERF numbers'),
        ErfStage(label: 'Geocode addresses'),
      ],
    ));

    try {
      _updateTask((t) => t.activateStage(0));

      final byErf = <int>[];
      final byAddress = <int>[];
      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        if (!entry.isUsable) {
          _matches[i] = _matches[i].copyWith(
            status: ErfMatchStatus.notFound,
            message: 'Nothing recognisable on this line',
          );
        } else if (entry.hasErfNumber) {
          byErf.add(i);
        } else {
          byAddress.add(i);
        }
      }

      _updateTask((t) => t.activateStage(1,
          detail: byErf.isEmpty
              ? 'None on this list'
              : '${byErf.length} to look up'));
      await _resolveByErfNumber(byErf, region);

      _updateTask((t) => t.activateStage(2,
          detail: byAddress.isEmpty
              ? 'None on this list'
              : '${byAddress.length} to geocode'));
      await _resolveByAddress(byAddress, region);

      _updateTask((t) => t.activateStage(t.stages.length));
    } catch (e) {
      _updateTask((t) => t.failActiveStage('$e'));
      _error = 'Lookup failed: $e';
      debugPrint('❌ resolveList error: $e');
    } finally {
      _endTask();
    }

    return _matches;
  }

  /// ERF numbers are looked up in bulk — the downloaded areas are searched
  /// in memory, and only what is left over goes to CSG as a single query for
  /// the whole list rather than a round trip per line.
  Future<void> _resolveByErfNumber(List<int> indices, CsgRegion? region) async {
    if (indices.isEmpty) return;

    final numbers = <String>{
      for (final i in indices) _matches[i].entry.erfNumber!,
    }.toList();

    // Keyed on the numeric core, so a pasted "4673" finds both plain erf
    // 4673 and its remainder "RE/4673". Where both exist they are genuinely
    // different parcels and surface together as an ambiguous match.
    final candidates = <String, List<ErfProperty>>{};
    void index(Iterable<ErfProperty> properties, {bool applyScope = true}) {
      for (final property in properties) {
        if (region != null &&
            region.minCode.isNotEmpty &&
            property.minCode.isNotEmpty &&
            property.minCode != region.minCode) {
          continue;
        }
        if (applyScope &&
            region == null &&
            !_scope.allows(
              majCode: property.majCode,
              province: property.province,
            )) {
          continue;
        }
        final raw = property.tagValue.trim().isNotEmpty
            ? property.tagValue.trim()
            : '${property.erfNumber}';
        final key = CsgPropertyService.normaliseErfNumber(raw);
        final bucket = candidates.putIfAbsent(key, () => <ErfProperty>[]);
        if (!bucket.any((p) => p.id == property.id)) bucket.add(property);
      }
    }

    // 1. Areas already in memory cost nothing to search.
    index(_properties);
    for (final parcels in _areaCache.values) {
      index(parcels);
    }

    // 2. If the list names a suburb that has been downloaded, pull that one
    //    file in — one read that usually answers the whole list.
    if (region != null && region.minCode.isNotEmpty) {
      for (final area in _areas) {
        if (area.minCode != region.minCode) continue;
        if (_areaCache.containsKey(area.id)) continue;

        _updateTask((t) => t.withDetail('Loading ${area.name}…'));
        try {
          index(await _parcelsFor(area));
        } catch (e) {
          debugPrint('⚠️ Could not load area ${area.id} for lookup: $e');
        }
        break;
      }
    }

    // 3. Whatever is still unaccounted for goes to the register.
    final missing = numbers
        .where((n) =>
            !candidates.containsKey(CsgPropertyService.normaliseErfNumber(n)))
        .toList();
    if (missing.isNotEmpty) {
      _updateTask((t) => t.withDetail(
          'Asking the register for ${missing.length} numbers…'));

      index(await _csgService.queryByErfNumbers(
        erfNumbers: missing,
        minCode: region?.minCode,
        scope: _scope,
        onProgress: (done, total) {
          _updateTask((t) => t.withDetail('$done of $total looked up'));
        },
      ));
    }

    for (final i in indices) {
      final entry = _matches[i].entry;
      var found = candidates[
              CsgPropertyService.normaliseErfNumber(entry.erfNumber!)] ??
          const <ErfProperty>[];

      // When the pasted line also named a suburb, use it to break ties.
      if (found.length > 1 && entry.hasAddress) {
        final narrowed = _narrowByAddressText(found, entry.address!);
        if (narrowed.isNotEmpty) found = narrowed;
      }

      if (found.isEmpty) {
        _matches[i] = _matches[i].copyWith(
          status: ErfMatchStatus.notFound,
          message: region != null
              ? 'No ERF ${entry.erfNumber} in ${region.minRegion}'
              : _scope.isRestricted
                  ? 'No ERF ${entry.erfNumber} in ${_scope.label}'
                  : 'No parcel with ERF ${entry.erfNumber}',
        );
      } else if (found.length == 1) {
        _matches[i] = _matches[i]
            .copyWith(status: ErfMatchStatus.matched, property: found.first);
      } else {
        _matches[i] = _matches[i].copyWith(
          status: ErfMatchStatus.ambiguous,
          candidates: found,
          message: '${found.length} suburbs have an ERF ${entry.erfNumber}',
        );
      }
    }
  }

  /// Address-only entries need a geocode each, so they run sequentially with
  /// progress reported per line.
  Future<void> _resolveByAddress(List<int> indices, CsgRegion? region) async {
    if (indices.isEmpty) return;

    var done = 0;
    for (final i in indices) {
      final entry = _matches[i].entry;
      _updateTask((t) => t.withDetail(
          '${done + 1} of ${indices.length}: ${entry.address}'));

      try {
        final query = (region != null &&
                !entry.address!.toUpperCase().contains(region.minRegion))
            ? '${entry.address}, ${region.minRegion}'
            : entry.address!;
        final property = await findPropertyByAddress(query);

        if (property == null) {
          _matches[i] = _matches[i].copyWith(
            status: ErfMatchStatus.notFound,
            message: 'No ERF found for this address',
          );
        } else {
          _matches[i] = _matches[i].copyWith(
            status: ErfMatchStatus.matched,
            property: property.copyWith(streetAddress: entry.address),
          );
        }
      } catch (e) {
        _matches[i] = _matches[i]
            .copyWith(status: ErfMatchStatus.error, message: e.toString());
      }

      done++;
    }
  }

  /// Pick the candidates whose suburb/region name appears in the pasted
  /// address text.
  List<ErfProperty> _narrowByAddressText(
      List<ErfProperty> candidates, String address) {
    final upper = address.toUpperCase();
    return candidates.where((p) {
      final region = p.minRegion.toUpperCase();
      final suburb = (p.suburb ?? '').toUpperCase();
      return (region.isNotEmpty && upper.contains(region)) ||
          (suburb.isNotEmpty && upper.contains(suburb));
    }).toList();
  }

  /// Re-look-up one entry with no geographic restriction.
  ///
  /// For the case where a pasted ERF number genuinely sits outside the
  /// working area: rather than silently widening every lookup, the user
  /// widens the one line that failed and picks from what comes back.
  Future<void> widenSearch(int matchIndex) async {
    if (matchIndex < 0 || matchIndex >= _matches.length) return;
    final entry = _matches[matchIndex].entry;
    if (!entry.hasErfNumber) return;

    _beginTask(ErfTask(
      title: 'Searching all of South Africa for ERF ${entry.erfNumber}',
      stages: const [ErfStage(label: 'Query the national register')],
    ));

    try {
      _updateTask((t) => t.activateStage(0));

      final found = await _csgService.queryByErfNumbers(
        erfNumbers: [entry.erfNumber!],
        scope: ErfSearchScope.southAfrica,
      );

      if (found.isEmpty) {
        _matches[matchIndex] = _matches[matchIndex].copyWith(
          status: ErfMatchStatus.notFound,
          message: 'No ERF ${entry.erfNumber} anywhere in the register',
        );
      } else if (found.length == 1) {
        _matches[matchIndex] = _matches[matchIndex]
            .copyWith(status: ErfMatchStatus.matched, property: found.first);
      } else {
        _matches[matchIndex] = _matches[matchIndex].copyWith(
          status: ErfMatchStatus.ambiguous,
          candidates: found,
          message: '${found.length} parcels nationwide carry this number',
        );
      }
    } catch (e) {
      _matches[matchIndex] = _matches[matchIndex]
          .copyWith(status: ErfMatchStatus.error, message: '$e');
    } finally {
      _endTask();
    }
  }

  /// Resolve an ambiguous entry to one of its candidates.
  void chooseCandidate(int matchIndex, ErfProperty property) {
    if (matchIndex < 0 || matchIndex >= _matches.length) return;
    _matches[matchIndex] = _matches[matchIndex]
        .copyWith(status: ErfMatchStatus.matched, property: property);
    notifyListeners();
  }

  /// Drop one entry from the selection.
  void removeMatch(int matchIndex) {
    if (matchIndex < 0 || matchIndex >= _matches.length) return;
    _matches = List.of(_matches)..removeAt(matchIndex);
    notifyListeners();
  }

  /// Clear the whole pasted selection.
  void clearSelection() {
    _matches = [];
    _selectionLabel = 'ERF Selection';
    notifyListeners();
  }

  /// Use an arbitrary set of parcels as the selection, e.g. one found by
  /// searching a single address.
  void setSelectionFromProperties(
    List<ErfProperty> properties, {
    String? label,
  }) {
    _matches = [
      for (var i = 0; i < properties.length; i++)
        ErfMatch(
          entry: ErfListEntry(
            lineNumber: i + 1,
            rawLine: properties[i].displayLabel,
            address: properties[i].streetAddress,
            erfNumber: properties[i].tagValue,
          ),
          status: ErfMatchStatus.matched,
          property: properties[i],
        ),
    ];
    if (label != null) _selectionLabel = label;
    notifyListeners();
  }

  // ── Single lookups ──────────────────────────────────────────────────

  /// Find which ERF parcel contains a given point.
  ///
  /// Checks the parcels already in memory first, then asks CSG.
  Future<ErfProperty?> findPropertyAtPoint(LatLng point) async {
    for (final property in _properties) {
      if (_isPointInPolygon(point, property.polygon)) {
        return property;
      }
    }
    for (final parcels in _areaCache.values) {
      for (final property in parcels) {
        if (_isPointInPolygon(point, property.polygon)) {
          return property;
        }
      }
    }

    final results = await _csgService.queryByPoint(
      latitude: point.latitude,
      longitude: point.longitude,
    );

    // Deliberately not cached: writing one document per looked-up parcel is
    // exactly the per-parcel Firestore traffic that packed areas removed.
    if (results.isNotEmpty) return results.first;

    return null;
  }

  /// Geocode a free-text place or address to a point.
  Future<LatLng?> geocode(String query) async {
    final coords = await _geocodingService.geocodeAddress(query);
    if (coords == null) return null;
    return LatLng(coords['lat']!, coords['lng']!);
  }

  /// Look up the ERF for a street address by geocoding it, then finding the
  /// parcel that contains the resulting point.
  Future<ErfProperty?> findPropertyByAddress(String address) async {
    final coords = await _geocodingService.geocodeAddress(address);
    if (coords == null) return null;

    final property =
        await findPropertyAtPoint(LatLng(coords['lat']!, coords['lng']!));
    return property?.copyWith(streetAddress: address);
  }

  /// Update the street address for a saved parcel.
  Future<void> updatePropertyAddress(
      String propertyId, String streetAddress, String suburb) async {
    await _firestoreService.updateAddress(propertyId, streetAddress, suburb);
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  /// Ray-casting point-in-polygon test.
  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;

    bool inside = false;
    int j = polygon.length - 1;

    for (int i = 0; i < polygon.length; i++) {
      if ((polygon[i].latitude > point.latitude) !=
              (polygon[j].latitude > point.latitude) &&
          point.longitude <
              (polygon[j].longitude - polygon[i].longitude) *
                      (point.latitude - polygon[i].latitude) /
                      (polygon[j].latitude - polygon[i].latitude) +
                  polygon[i].longitude) {
        inside = !inside;
      }
      j = i;
    }

    return inside;
  }

  @override
  void dispose() {
    _areaSubscription?.cancel();
    super.dispose();
  }
}
