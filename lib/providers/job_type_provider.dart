import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/custom_job_type.dart';
import '../services/reference_cache_service.dart';

const String _kCollectionName = 'customJobTypes';

final jobTypeRiverpod = riverpod.ChangeNotifierProvider<JobTypeProvider>(
    (ref) => JobTypeProvider());

class JobTypeProvider extends ChangeNotifier {
  /// Static accessor so model-layer helpers (which have no Riverpod ref)
  /// can resolve job-type flags without callers having to thread a
  /// provider argument through every method. Populated by the constructor
  /// and kept in sync across hot restarts.
  static JobTypeProvider? _instance;
  static JobTypeProvider? get instance => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<CustomJobType> _jobTypes = [];
  bool _isLoading = true;

  List<CustomJobType> get jobTypes => List.unmodifiable(_jobTypes);
  bool get isLoading => _isLoading;

  JobTypeProvider() {
    _instance = this;
    _loadJobTypes();
  }

  /// Load job types using the version-sentinel cache. Replaces the previous
  /// real-time snapshot listener — job types change rarely, so eagerly
  /// streaming them was costing hundreds of reads per day for little benefit.
  ///
  /// Callers who mutate job types (add/update/delete) still update the
  /// in-memory list and `notifyListeners()` immediately so the UI feels
  /// live. Other clients pick up the change on their next session via the
  /// `/meta/referenceVersions` version bump.
  Future<void> _loadJobTypes() async {
    try {
      final loaded = await ReferenceCacheService.loadCollection<CustomJobType>(
        query: _firestore.collection(_kCollectionName).orderBy('order'),
        collectionName: _kCollectionName,
        fromDoc: (doc) =>
            CustomJobType.fromMap(doc.data() as Map<String, dynamic>),
      );

      if (loaded.isEmpty && _isLoading) {
        // First-time setup: seed defaults into Firestore
        await _initializeDefaults();
      } else {
        _jobTypes = loaded;
        _isLoading = false;
        notifyListeners();
        // Fire-and-forget one-time backfill for legacy default docs that
        // pre-date the behaviour-flag fields.
        unawaited(_migrateDefaultFlagsIfNeeded());
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading job types: $e');
      }
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Legacy default-type docs (pre-flag-schema) load with every behaviour
  /// flag at its constructor default. When we detect that pattern on a
  /// default id whose seed specifies non-default flags, rewrite the doc
  /// from the seed. Idempotent: once backfilled, the condition below is
  /// false and the method is a no-op.
  Future<void> _migrateDefaultFlagsIfNeeded() async {
    final seedsById = {
      for (final s in CustomJobType.getDefaults()) s.id: s,
    };
    final toBackfill = <CustomJobType>[];
    for (final jt in _jobTypes) {
      final seed = seedsById[jt.id];
      if (seed == null || !jt.isDefault) continue;
      final atConstructorDefaults = !jt.isHappySunService &&
          !jt.needsTimeSlot &&
          !jt.appearsOnCollectionSchedule &&
          jt.tracksQuantity &&
          jt.quantityLabel == 'Quantity' &&
          jt.defaultTools.isEmpty;
      final seedHasNonDefault = seed.isHappySunService ||
          seed.needsTimeSlot ||
          seed.appearsOnCollectionSchedule ||
          !seed.tracksQuantity ||
          seed.quantityLabel != 'Quantity' ||
          seed.defaultTools.isNotEmpty;
      if (atConstructorDefaults && seedHasNonDefault) {
        // Preserve the user's current label (may have been renamed).
        toBackfill.add(seed.copyWith(label: jt.label, order: jt.order));
      }
    }
    if (toBackfill.isEmpty) return;
    try {
      final batch = _firestore.batch();
      for (final jt in toBackfill) {
        batch.set(
            _firestore.collection(_kCollectionName).doc(jt.id), jt.toMap());
      }
      await batch.commit();
      await ReferenceCacheService.bumpVersion(_kCollectionName);
      // Apply to in-memory list so the UI reflects backfilled flags.
      for (final jt in toBackfill) {
        final idx = _jobTypes.indexWhere((e) => e.id == jt.id);
        if (idx != -1) _jobTypes[idx] = jt;
      }
      notifyListeners();
      if (kDebugMode) {
        print('Backfilled ${toBackfill.length} default job type(s) with '
            'behaviour flags.');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Warning: job type flag backfill failed: $e');
      }
    }
  }

  /// Public refresh — forces a fresh load (will still use cache if version
  /// is unchanged, but flushes any stale in-memory state).
  Future<void> refresh() => _loadJobTypes();

  Future<void> _initializeDefaults() async {
    final defaults = CustomJobType.getDefaults();
    final batch = _firestore.batch();
    for (final jt in defaults) {
      batch.set(_firestore.collection(_kCollectionName).doc(jt.id), jt.toMap());
    }
    await batch.commit();
    await ReferenceCacheService.bumpVersion(_kCollectionName);
    // Refresh from the newly written docs.
    await _loadJobTypes();
  }

  /// Creates a new (non-default) job type and returns the created record so
  /// callers can chain flag updates without a label-based re-lookup.
  Future<CustomJobType> addJobType(String label) async {
    final id = _generateId(label);
    final jobType = CustomJobType(
      id: id,
      label: label,
      order: _getNextOrder(),
    );

    await _firestore.collection(_kCollectionName).doc(id).set(jobType.toMap());
    await ReferenceCacheService.bumpVersion(_kCollectionName);

    _jobTypes.add(jobType);
    _sortJobTypes();
    notifyListeners();
    return jobType;
  }

  Future<void> updateJobType(String id, String label) async {
    final index = _jobTypes.indexWhere((jt) => jt.id == id);
    if (index == -1) return;

    final updated = _jobTypes[index].copyWith(label: label);
    await _firestore
        .collection(_kCollectionName)
        .doc(id)
        .update({'label': label});
    await ReferenceCacheService.bumpVersion(_kCollectionName);

    _jobTypes[index] = updated;
    notifyListeners();
  }

  /// Update any subset of fields on an existing job type. The `id` and
  /// `isDefault` fields are immutable; callers must pass the same values.
  /// Use [clearIcon]/[clearColor] to explicitly remove those optional fields.
  Future<void> updateJobTypeFields(
    String id, {
    String? label,
    bool? isHappySunService,
    bool? needsTimeSlot,
    bool? appearsOnCollectionSchedule,
    bool? tracksQuantity,
    String? quantityLabel,
    String? iconName,
    int? colorValue,
    List<String>? defaultTools,
    bool clearIcon = false,
    bool clearColor = false,
  }) async {
    final index = _jobTypes.indexWhere((jt) => jt.id == id);
    if (index == -1) return;

    final updated = _jobTypes[index].copyWith(
      label: label,
      isHappySunService: isHappySunService,
      needsTimeSlot: needsTimeSlot,
      appearsOnCollectionSchedule: appearsOnCollectionSchedule,
      tracksQuantity: tracksQuantity,
      quantityLabel: quantityLabel,
      iconName: iconName,
      colorValue: colorValue,
      defaultTools: defaultTools,
      clearIcon: clearIcon,
      clearColor: clearColor,
    );

    // Use set(..., merge=true) so nullable clears (icon/color) persist.
    await _firestore.collection(_kCollectionName).doc(id).set(updated.toMap());
    await ReferenceCacheService.bumpVersion(_kCollectionName);

    _jobTypes[index] = updated;
    notifyListeners();
  }

  Future<void> deleteJobType(String id) async {
    final jt = _jobTypes.firstWhere((j) => j.id == id);
    if (jt.isDefault) {
      throw Exception('Cannot delete default job type');
    }

    await _firestore.collection(_kCollectionName).doc(id).delete();
    await ReferenceCacheService.bumpVersion(_kCollectionName);
    _jobTypes.removeWhere((j) => j.id == id);
    notifyListeners();
  }

  CustomJobType? getJobTypeById(String id) {
    try {
      return _jobTypes.firstWhere((jt) => jt.id == id);
    } catch (e) {
      return null;
    }
  }

  String getJobTypeLabel(String id) {
    return getJobTypeById(id)?.label ?? id;
  }

  // ── Behaviour-flag lookups ─────────────────────────────────────────
  // These are the only entry points form code should use. Never branch
  // on a hardcoded jobTypeId string.

  bool isHappySunService(String id) =>
      getJobTypeById(id)?.isHappySunService ?? false;

  bool needsTimeSlot(String id) => getJobTypeById(id)?.needsTimeSlot ?? false;

  bool appearsOnCollectionSchedule(String id) =>
      getJobTypeById(id)?.appearsOnCollectionSchedule ?? false;

  bool tracksQuantity(String id) => getJobTypeById(id)?.tracksQuantity ?? true;

  String quantityLabel(String id) =>
      getJobTypeById(id)?.quantityLabel ?? 'Quantity';

  String? iconName(String id) => getJobTypeById(id)?.iconName;

  int? colorValue(String id) => getJobTypeById(id)?.colorValue;

  List<String> defaultTools(String id) =>
      getJobTypeById(id)?.defaultTools ?? const [];

  /// Convenience: ids of every type currently configured to appear on the
  /// Collection Schedule. Used by providers that need to filter job lists.
  List<String> get collectionScheduleTypeIds => _jobTypes
      .where((jt) => jt.appearsOnCollectionSchedule)
      .map((jt) => jt.id)
      .toList(growable: false);

  /// Convenience: ids of every Happy Sun service. Used by main.dart and
  /// the Happy Sun provider to filter jobs that should sync.
  List<String> get happySunServiceTypeIds => _jobTypes
      .where((jt) => jt.isHappySunService)
      .map((jt) => jt.id)
      .toList(growable: false);

  void _sortJobTypes() {
    _jobTypes.sort((a, b) => a.order.compareTo(b.order));
  }

  int _getNextOrder() {
    if (_jobTypes.isEmpty) return 0;
    return _jobTypes.map((jt) => jt.order).reduce((a, b) => a > b ? a : b) + 1;
  }

  String _generateId(String label) {
    String baseId = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    String id = baseId;
    int counter = 1;
    while (_jobTypes.any((jt) => jt.id == id)) {
      id = '${baseId}_$counter';
      counter++;
    }
    return id;
  }
}
