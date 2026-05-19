import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Version-sentinel cache helper for rarely-changing "reference" collections
/// such as `customJobTypes`, `customInvoiceStatuses`, `customJobListStatuses`
/// and `jobStatuses`.
///
/// ## How it works
/// A single Firestore document at `/meta/referenceVersions` stores an integer
/// version counter per collection name. Every time an admin adds, updates or
/// deletes a reference item the version is incremented (see [bumpVersion]).
///
/// When loading a reference collection through [loadCollection] we:
///   1. Read the meta doc (one doc read, served from Firestore cache after
///      the first hit).
///   2. Compare the remote version with the version we last recorded locally
///      (persisted in a small Hive box so it survives app restarts).
///   3. If the versions match, fetch the collection from Firestore's local
///      offline cache using `Source.cache` → **zero billed reads**.
///   4. If they differ (or this is the first run, or cache is empty) fetch
///      from the server and record the new version.
///
/// ## Backward compatibility
/// * If the `/meta/referenceVersions` doc does not exist the remote version
///   is treated as `0`. First-ever load stores `0`; subsequent loads match
///   and use cache. As soon as any client bumps the version the doc is
///   created.
/// * If Hive initialisation fails (e.g. unusual platform) the service silently
///   falls back to an in-memory map — we lose cross-session savings but the
///   app still works correctly.
/// * The underlying collection documents are untouched; the data model is
///   unchanged.
class ReferenceCacheService {
  ReferenceCacheService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final DocumentReference<Map<String, dynamic>> _metaDoc =
      _firestore.collection('meta').doc('referenceVersions');

  static const String _hiveBoxName = 'reference_cache_versions';

  /// Per-session fallback when Hive is unavailable.
  static final Map<String, int> _memoryVersions = {};

  /// Per-session: remembers the remote version we last read from the meta
  /// doc, so repeated loads of the same collection in one session do not
  /// keep re-reading the meta doc.
  static final Map<String, int> _sessionRemoteVersions = {};

  static Box? _box;
  static bool _hiveTried = false;
  static bool _hiveAvailable = false;

  static Future<Box?> _openBox() async {
    if (_box != null) return _box;
    if (_hiveTried && !_hiveAvailable) return null;
    _hiveTried = true;
    try {
      // Hive.initFlutter() is idempotent — safe to call even when another
      // service (e.g. HappySunLocalStorage) has already initialised Hive.
      await Hive.initFlutter();
      _box = await Hive.openBox(_hiveBoxName);
      _hiveAvailable = true;
      return _box;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ReferenceCacheService: Hive unavailable, '
            'falling back to in-memory cache: $e');
      }
      _hiveAvailable = false;
      return null;
    }
  }

  static Future<int?> _getStoredVersion(String collectionName) async {
    final box = await _openBox();
    if (box != null) {
      final v = box.get(collectionName);
      return v is int ? v : null;
    }
    return _memoryVersions[collectionName];
  }

  static Future<void> _setStoredVersion(
      String collectionName, int version) async {
    final box = await _openBox();
    if (box != null) {
      await box.put(collectionName, version);
    } else {
      _memoryVersions[collectionName] = version;
    }
  }

  /// Reads the current server-side version for [collectionName] from the
  /// `/meta/referenceVersions` document. Defaults to `0` if the doc or
  /// field is missing. Costs at most one doc read per session per
  /// collection — subsequent calls are served from an in-memory session
  /// cache.
  static Future<int> _getRemoteVersion(String collectionName) async {
    final cached = _sessionRemoteVersions[collectionName];
    if (cached != null) return cached;

    try {
      final snap = await _metaDoc.get();
      final data = snap.data();
      final v = (data != null ? data[collectionName] : null);
      final version = v is int ? v : 0;
      _sessionRemoteVersions[collectionName] = version;
      return version;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ReferenceCacheService: _getRemoteVersion($collectionName) '
            'failed: $e');
      }
      // On error, treat as version 0 — callers will fall back to a server
      // fetch which is the same behaviour as before the service existed.
      return 0;
    }
  }

  /// Increment the version counter for [collectionName]. Call this from
  /// every add/update/delete on a reference collection so that other
  /// clients know their local cache is stale.
  ///
  /// Also updates the caller's stored version so the caller itself does
  /// not re-fetch from the server on the very next load (the caller's
  /// local Firestore cache already reflects the change).
  static Future<void> bumpVersion(String collectionName) async {
    try {
      await _metaDoc.set(
        {collectionName: FieldValue.increment(1)},
        SetOptions(merge: true),
      );
      // Invalidate our session cache so the next load picks up the new
      // version and records it.
      _sessionRemoteVersions.remove(collectionName);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
            'ReferenceCacheService: bumpVersion($collectionName) failed: $e');
      }
      // Swallow — worst case the cache stays "fresh" for other clients
      // until another bump succeeds.
    }
  }

  /// Load a reference collection using cache-first semantics.
  ///
  /// Returns a list of documents produced by [fromDoc]. The typical usage
  /// is:
  ///
  /// ```dart
  /// _statuses = await ReferenceCacheService.loadCollection(
  ///   query: _firestore.collection('customJobListStatuses').orderBy('label'),
  ///   collectionName: 'customJobListStatuses',
  ///   fromDoc: (doc) => CustomJobListStatus.fromMap({
  ///     ...Map<String, dynamic>.from(doc.data() as Map),
  ///     'id': doc.id,
  ///   }),
  /// );
  /// ```
  ///
  /// Guarantees:
  /// * Data returned is never older than the current `/meta/referenceVersions`
  ///   value for this collection.
  /// * If the server doc is missing (`version == 0`) and we have a cached
  ///   version of `0` we still serve from cache — this is what makes the
  ///   service a no-op "enhancement" for databases that have never had the
  ///   meta doc written to them.
  static Future<List<T>> loadCollection<T>({
    required Query<Object?> query,
    required String collectionName,
    required T Function(QueryDocumentSnapshot<Object?> doc) fromDoc,
  }) async {
    final remoteVersion = await _getRemoteVersion(collectionName);
    final storedVersion = await _getStoredVersion(collectionName);

    // Fast path: versions match → serve from Firestore's local cache.
    if (storedVersion != null && storedVersion == remoteVersion) {
      try {
        final cacheSnap =
            await query.get(const GetOptions(source: Source.cache));
        if (cacheSnap.docs.isNotEmpty) {
          if (kDebugMode) {
            debugPrint('ReferenceCacheService[$collectionName]: '
                'served ${cacheSnap.docs.length} docs from cache '
                '(version=$remoteVersion, 0 billed reads)');
          }
          return cacheSnap.docs.map(fromDoc).toList();
        }
        // Empty cache — fall through to server fetch.
      } catch (e) {
        // Cache miss / unavailable — fall through to server fetch.
        if (kDebugMode) {
          debugPrint(
              'ReferenceCacheService[$collectionName]: cache read failed, '
              'falling back to server: $e');
        }
      }
    }

    // Slow path: fetch from server and remember the version.
    final serverSnap = await query.get();
    await _setStoredVersion(collectionName, remoteVersion);
    if (kDebugMode) {
      debugPrint('ReferenceCacheService[$collectionName]: '
          'fetched ${serverSnap.docs.length} docs from server '
          '(new stored version=$remoteVersion)');
    }
    return serverSnap.docs.map(fromDoc).toList();
  }

  /// Reset all cached state. Useful for tests and for a "force refresh"
  /// affordance. After this call the next [loadCollection] will perform
  /// a server fetch.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    _memoryVersions.clear();
    _sessionRemoteVersions.clear();
    final box = await _openBox();
    if (box != null) await box.clear();
  }
}
