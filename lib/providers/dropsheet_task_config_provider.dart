import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/dropsheet_task.dart';
import '../models/dropsheet_task_type_config.dart';

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
        }
      }
    } catch (e) {
      debugPrint('DropsheetTaskConfigProvider load error: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Saves enum-type configs AND dynamic types to Firestore.
  Future<void> saveAll({
    required Map<DropsheetTaskType, DropsheetTaskTypeConfig> configs,
    required List<DynamicTaskTypeDef> customTypes,
    DepotConfig? depot,
  }) async {
    _configs = Map.from(configs);
    _customTypes = List.from(customTypes);
    if (depot != null) _depot = depot;
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
    }
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
