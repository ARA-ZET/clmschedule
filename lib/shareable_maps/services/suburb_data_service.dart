import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../models/work_suburb.dart';

/// Manages loading and saving Cape Town suburb polygons directly from/to
/// Firestore.
///
/// Structure: a single document at `workSuburbs/main` with a `suburbs` array,
/// each entry serialised via [WorkSuburb.toMap] / [WorkSuburb.fromMap].
/// Colors are stored in every entry and round-trip faithfully.
class SuburbDataService {
  static const String _mainPath = 'workSuburbs/main';

  final FirebaseFirestore? _injectedFirestore;

  /// Resolved lazily rather than in the initializer list so that subclasses
  /// which override every method — test fakes, chiefly — never touch
  /// `FirebaseFirestore.instance` and so do not require an initialised app.
  FirebaseFirestore get _firestore =>
      _injectedFirestore ?? FirebaseFirestore.instance;

  // Session-level in-memory cache — cleared by [invalidateCache].
  static List<WorkSuburb>? _cachedSuburbs;

  SuburbDataService({FirebaseFirestore? firestore})
      : _injectedFirestore = firestore;

  // ── Public API ───────────────────────────────────────────────────────────

  /// Returns all suburbs stored in `workSuburbs/main`.
  ///
  /// Results are cached for the session. Pass [forceRefresh] to bypass the
  /// cache and re-read from Firestore.
  Future<List<WorkSuburb>> loadSuburbs({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedSuburbs != null) {
      return List.unmodifiable(_cachedSuburbs!);
    }

    try {
      DocumentSnapshot snap;
      try {
        snap = await _firestore
            .doc(_mainPath)
            .get(const GetOptions(source: Source.cache));
        if (!snap.exists) snap = await _firestore.doc(_mainPath).get();
      } catch (_) {
        snap = await _firestore.doc(_mainPath).get();
      }

      if (!snap.exists) {
        debugPrint('SuburbDataService: workSuburbs/main does not exist yet');
        _cachedSuburbs = [];
        return const [];
      }

      final data = snap.data() as Map<String, dynamic>;
      final raw = (data['suburbs'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final suburbs = raw.map(WorkSuburb.fromMap).toList();
      _cachedSuburbs = suburbs;
      debugPrint('SuburbDataService: loaded ${suburbs.length} suburbs');
      return List.unmodifiable(suburbs);
    } catch (e) {
      debugPrint('SuburbDataService: load failed: $e');
      return _cachedSuburbs ?? const [];
    }
  }

  /// Persists [suburbs] (including their colors) to `workSuburbs/main`,
  /// replacing any previously stored data.
  Future<void> saveSuburbs(List<WorkSuburb> suburbs) async {
    await _firestore.doc(_mainPath).set({
      'suburbs': suburbs.map((s) => s.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _cachedSuburbs = List.from(suburbs);
    debugPrint('SuburbDataService: saved ${suburbs.length} suburbs');
  }

  /// Clear the session cache, forcing a fresh Firestore read on the next call.
  static void invalidateCache() {
    _cachedSuburbs = null;
  }
}
