import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/dropsheet_task.dart';
import '../models/dropsheet_task_type_config.dart';
import '../services/geocoding_service.dart';

final dropsheetTaskConfigRiverpod =
    riverpod.ChangeNotifierProvider<DropsheetTaskConfigProvider>(
        (ref) => DropsheetTaskConfigProvider());

/// All task types whose label and service-time the user can configure.
/// Mandatory types (inspect/pack/leave) and distributor-based types
/// (dropOff/pickUp) do not use the job-list picker, but their label
/// and stop service-time can still be overridden here.
const configurableDropsheetTaskTypes = [
  // Mandatory — pinned at the start of every driver section
  DropsheetTaskType.inspect,
  DropsheetTaskType.pack,
  DropsheetTaskType.leave,
  DropsheetTaskType.arrive,
  // Auto-populated from the schedule
  DropsheetTaskType.dropOff,
  DropsheetTaskType.pickUp,
  DropsheetTaskType.distribute,
  // Manually added by the dispatcher
  DropsheetTaskType.collection,
  DropsheetTaskType.jobReturn,
  DropsheetTaskType.pickFlyers,
  DropsheetTaskType.furnitureMove,
  DropsheetTaskType.custom,
];

class DropsheetTaskConfigProvider extends ChangeNotifier {
  final _firestore = FirebaseFirestore.instance;
  static const _docPath = 'dropsheetSettings/taskTypeConfig';

  Map<DropsheetTaskType, DropsheetTaskTypeConfig> _configs = {
    for (final t in configurableDropsheetTaskTypes)
      t: DropsheetTaskTypeConfig(type: t),
  };

  List<DynamicTaskTypeDef> _customTypes = [];

  DepotConfig _depot = const DepotConfig();

  bool _isLoading = false;

  /// In-flight geocode, so concurrent callers share one Geocoding API call.
  Future<DepotConfig>? _depotGeocodePending;

  /// Normalised address the geocoder last failed on. Prevents a failed lookup
  /// from being retried on every ETA click; cleared when the address changes.
  String? _depotGeocodeFailedFor;

  Map<DropsheetTaskType, DropsheetTaskTypeConfig> get configs =>
      Map.unmodifiable(_configs);
  List<DynamicTaskTypeDef> get customTypes => List.unmodifiable(_customTypes);
  DepotConfig get depot => _depot;
  bool get isLoading => _isLoading;

  DropsheetTaskConfigProvider() {
    _load();
  }

  Future<void> _load() async {
    _isLoading = true;
    notifyListeners();
    try {
      final doc = await _firestore.doc(_docPath).get();
      if (doc.exists) {
        final data = doc.data() ?? {};
        final updated = <DropsheetTaskType, DropsheetTaskTypeConfig>{};
        for (final t in configurableDropsheetTaskTypes) {
          final key = t.storageKey;
          if (data.containsKey(key) && data[key] is Map) {
            updated[t] = DropsheetTaskTypeConfig.fromMap(
                t, Map<String, dynamic>.from(data[key] as Map));
          } else {
            updated[t] = DropsheetTaskTypeConfig(type: t);
          }
        }
        _configs = updated;

        // Load user-defined dynamic types
        final rawCustom = data['customTypes'];
        if (rawCustom is List) {
          _customTypes = rawCustom
              .whereType<Map>()
              .map((m) =>
                  DynamicTaskTypeDef.fromMap(Map<String, dynamic>.from(m)))
              .toList();
        }

        // Load depot config (or keep defaults).
        final rawDepot = data['depot'];
        if (rawDepot is Map) {
          _depot = DepotConfig.fromMap(Map<String, dynamic>.from(rawDepot));
          debugPrint('[DepotGeocode] loaded office from Firestore: '
              'address="${_depot.address}" '
              'geocodedAddress="${_depot.geocodedAddress}" '
              'lat=${_depot.lat} lng=${_depot.lng} '
              'isGeocoded=${_depot.isGeocoded}');
        } else {
          debugPrint('[DepotGeocode] no `depot` key in $_docPath — '
              'using defaults (will geocode)');
        }
      }
    } catch (e) {
      debugPrint('DropsheetTaskConfigProvider load error: $e');
      _warnIfPermissionDenied(e);
    }
    _isLoading = false;
    notifyListeners();

    // Resolve the office coordinates up front so route/ETA actions never have
    // to send the user to the Task manager. No-op once the address is geocoded.
    unawaited(ensureDepotGeocoded());
  }

  /// Geocodes the office address if its coordinates are missing or belong to a
  /// previous address, then persists them so it only ever happens once per
  /// address. Returns the resulting depot config.
  ///
  /// [force] re-geocodes even when the address already has current
  /// coordinates. [retryFailed] ignores a previous failure for this address —
  /// pass it for explicit user actions, since the last failure may have been
  /// transient (offline, Maps script not loaded yet).
  Future<DepotConfig> ensureDepotGeocoded({
    bool force = false,
    bool retryFailed = false,
  }) {
    final pending = _depotGeocodePending;
    if (pending != null) return pending;
    if (!force && !_depot.needsGeocoding) return Future.value(_depot);

    final address = _depot.address.trim();
    if (address.isEmpty) return Future.value(_depot);
    final key = DepotConfig.normaliseAddress(address);
    if (!force && !retryFailed && _depotGeocodeFailedFor == key) {
      return Future.value(_depot);
    }

    final future = _geocodeDepot(address, key);
    _depotGeocodePending = future;
    return future.whenComplete(() {
      if (identical(_depotGeocodePending, future)) _depotGeocodePending = null;
    });
  }

  Future<DepotConfig> _geocodeDepot(String address, String key) async {
    // The office is always local; bias the lookup so bare street addresses
    // don't resolve to a same-named street on another continent.
    final query = address.toLowerCase().contains('south africa')
        ? address
        : '$address, Western Cape, South Africa';
    debugPrint('[DepotGeocode] geocoding office="$query"');
    Map<String, double>? res;
    try {
      res = await GeocodingService().geocodeAddress(query);
    } catch (e) {
      debugPrint('[DepotGeocode] error: $e');
    }
    if (res == null) {
      debugPrint('[DepotGeocode] FAILED for "$address"');
      _depotGeocodeFailedFor = key;
      return _depot;
    }

    _depotGeocodeFailedFor = null;
    _depot = _depot.copyWith(
      lat: res['lat'],
      lng: res['lng'],
      geocodedAddress: address,
    );
    notifyListeners();
    await _persistDepot();
    return _depot;
  }

  /// Writes only the `depot` key, leaving task-type configs untouched.
  Future<void> _persistDepot() async {
    try {
      await _firestore
          .doc(_docPath)
          .set({'depot': _depot.toMap()}, SetOptions(merge: true));
      debugPrint('[DepotGeocode] saved office coordinates to $_docPath '
          '(${_depot.lat}, ${_depot.lng})');
    } catch (e) {
      // A denied write here is why the office looked "not geocoded" after
      // every refresh: the coordinates resolve fine, then never persist.
      debugPrint('[DepotGeocode] ✖ COULD NOT SAVE office coordinates to '
          '$_docPath: $e');
      _warnIfPermissionDenied(e);
    }
  }

  /// `dropsheetSettings` must be allowed in firestore.rules — the rules file is
  /// fail-closed, so an unlisted collection silently rejects every write and
  /// the settings appear to save but revert on reload.
  void _warnIfPermissionDenied(Object e) {
    final denied = e is FirebaseException
        ? e.code == 'permission-denied'
        : e.toString().contains('permission-denied');
    if (denied) {
      debugPrint('[DropsheetSettings] PERMISSION DENIED on $_docPath — '
          'firestore.rules is fail-closed and needs a rule for '
          '`dropsheetSettings`. Deploy it with: '
          'firebase deploy --only firestore:rules');
    }
  }

  /// Saves enum-type configs AND dynamic types to Firestore.
  Future<void> saveAll({
    required Map<DropsheetTaskType, DropsheetTaskTypeConfig> configs,
    required List<DynamicTaskTypeDef> customTypes,
    DepotConfig? depot,
  }) async {
    _configs = Map.from(configs);
    _customTypes = List.from(customTypes);
    final addressChanged = depot != null &&
        DepotConfig.normaliseAddress(depot.address) !=
            DepotConfig.normaliseAddress(_depot.address);
    if (depot != null) _depot = depot;
    // A newly entered address deserves a fresh attempt even if the previous
    // one failed to resolve.
    if (addressChanged) _depotGeocodeFailedFor = null;
    notifyListeners();
    final map = <String, dynamic>{
      for (final e in configs.entries) e.key.storageKey: e.value.toMap(),
      'customTypes': customTypes.map((t) => t.toMap()).toList(),
      'depot': _depot.toMap(),
    };
    try {
      await _firestore.doc(_docPath).set(map);
    } catch (e) {
      debugPrint('DropsheetTaskConfigProvider save error: $e');
      _warnIfPermissionDenied(e);
    }
    // Resolve coordinates for the saved address (no-op if already geocoded).
    // An explicit save retries even an address that failed before.
    await ensureDepotGeocoded(retryFailed: true);
  }

  /// Convenience: save only the enum-type configs (keeps customTypes unchanged).
  Future<void> save(
      Map<DropsheetTaskType, DropsheetTaskTypeConfig> configs) async {
    await saveAll(configs: configs, customTypes: _customTypes);
  }

  /// Returns the configured label for [type], or the default display name.
  String effectiveLabelFor(DropsheetTaskType type) =>
      _configs[type]?.effectiveLabel ?? type.displayName;

  /// Returns the allowed job-type ID list for [type].
  /// Empty means "no restriction / use built-in fallback".
  List<String> allowedJobTypeIds(DropsheetTaskType type) =>
      _configs[type]?.allowedJobTypeIds ?? [];

  /// Returns the allowed job-type IDs for a dynamic (user-defined) type.
  List<String> allowedJobTypeIdsForDynamic(String dynamicTypeId) => _customTypes
      .firstWhere((t) => t.id == dynamicTypeId,
          orElse: () => DynamicTaskTypeDef(id: dynamicTypeId, label: ''))
      .allowedJobTypeIds;

  DynamicTaskTypeDef? dynamicTypeById(String id) {
    try {
      return _customTypes.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  DropsheetTaskTypeConfig configFor(DropsheetTaskType type) =>
      _configs[type] ?? DropsheetTaskTypeConfig(type: type);

  /// Resolve the service-time (minutes at the stop) for [task]:
  /// 1. Per-task `serviceTimeMinutes` override, if set.
  /// 2. Dynamic type default, if `typeData['dynamicTypeId']` is set.
  /// 3. Enum-type default from `configFor(task.type)`.
  /// 4. 0.
  int serviceMinutesFor(DropsheetTask task) {
    if (task.serviceTimeMinutes != null) return task.serviceTimeMinutes!;
    final dynId = task.typeData['dynamicTypeId'] as String?;
    if (dynId != null && dynId.isNotEmpty) {
      final def = dynamicTypeById(dynId);
      if (def != null) return def.serviceTimeMinutes;
    }
    return configFor(task.type).serviceTimeMinutes;
  }

  /// Seeds sensible built-in defaults for all [configurableDropsheetTaskTypes]
  /// to Firestore. Overwrites any existing enum-type configs but preserves
  /// custom types and depot settings.
  Future<void> seedBuiltinDefaults() async {
    final seeded = <DropsheetTaskType, DropsheetTaskTypeConfig>{
      DropsheetTaskType.inspect: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.inspect,
        serviceTimeMinutes: 10,
      ),
      DropsheetTaskType.pack: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.pack,
        serviceTimeMinutes: 30,
      ),
      DropsheetTaskType.leave: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.leave,
        serviceTimeMinutes: 15,
      ),
      DropsheetTaskType.arrive: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.arrive,
        serviceTimeMinutes: 10,
      ),
      DropsheetTaskType.dropOff: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.dropOff,
        serviceTimeMinutes: 15,
      ),
      DropsheetTaskType.pickUp: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.pickUp,
        serviceTimeMinutes: 15,
      ),
      DropsheetTaskType.distribute: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.distribute,
        serviceTimeMinutes: 0,
      ),
      DropsheetTaskType.collection: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.collection,
        serviceTimeMinutes: 20,
      ),
      DropsheetTaskType.jobReturn: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.jobReturn,
        serviceTimeMinutes: 15,
      ),
      DropsheetTaskType.pickFlyers: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.pickFlyers,
        serviceTimeMinutes: 10,
      ),
      DropsheetTaskType.furnitureMove: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.furnitureMove,
        serviceTimeMinutes: 60,
      ),
      DropsheetTaskType.custom: DropsheetTaskTypeConfig(
        type: DropsheetTaskType.custom,
        serviceTimeMinutes: 0,
      ),
    };
    await saveAll(
      configs: seeded,
      customTypes: _customTypes,
      depot: _depot,
    );
  }
}
