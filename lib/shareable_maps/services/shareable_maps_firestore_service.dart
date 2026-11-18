import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../../recycle_bin/recycle_bin_entry.dart';
import '../../recycle_bin/recycle_bin_payload_store.dart';
import '../../recycle_bin/recycle_bin_writer.dart';
import '../models/shareable_map.dart';
import 'map_name_index_service.dart';
import 'map_thumbnail_service.dart';
import 'map_link_service.dart';

/// Firestore service for persisting shareable maps.
///
/// Collection structure (monthly sub-collections):
/// ```
/// /shareableMaps/03-2026          ← monthly document (MM-YYYY)
///   /maps/{mapId}                 ← individual map documents
///     name: String
///     description: String
///     monthKey: String            // '03-2026' (stored for collectionGroup queries)
///     createdAt: int              // milliseconds since epoch
///     updatedAt: int
///     layers: List<Map>           // full layer data
///     defaultCenterLat: double
///     defaultCenterLng: double
///     defaultZoom: double
/// ```
class ShareableMapsFirestoreService {
  final FirebaseFirestore _firestore;

  ShareableMapsFirestoreService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Root collection reference.
  CollectionReference get _root => _firestore.collection('shareableMaps');

  /// Get the maps sub-collection for a given month key (e.g. '03-2026').
  CollectionReference _mapsCollection(String monthKey) =>
      _root.doc(monthKey).collection('maps');

  // ---------------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------------

  /// Ensure the monthly parent document exists so it shows up in root queries.
  Future<void> _ensureMonthDoc(String monthKey) async {
    await _root.doc(monthKey).set({
      'monthKey': monthKey,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    }, SetOptions(merge: true));
  }

  /// Create a new map document in Firestore. Returns the generated doc ID.
  ///
  /// Also creates a share-link entry in `/mapLinks/{code}` so the map can
  /// be opened via a deep link without loading all maps.
  Future<String> createMap(ShareableMap map, {String? monthKey}) async {
    final mk = monthKey ?? monthKeyFor(map.createdAt);
    MapNameIndexService.instance.invalidate();
    await _ensureMonthDoc(mk);
    final data = map.withStablePolygonIds().toMap();
    data['monthKey'] = mk;
    final docRef = await _mapsCollection(mk).add(data);

    // Auto-generate a share link
    final linkService = MapLinkService(firestore: _firestore);
    final code = await linkService.createShareLink(
      monthKey: mk,
      mapId: docRef.id,
      mapName: map.name,
    );
    // Store the share code on the map doc for quick access
    await docRef.update({'shareCode': code});

    debugPrint(
        '[ShareableMapsFirestore] Created map ${docRef.id} in $mk (share: $code)');
    return docRef.id;
  }

  /// The share code stored on a map document, if it has one.
  Future<String?> getShareCode(String monthKey, String docId) async {
    try {
      final doc = await _mapsCollection(monthKey).doc(docId).get();
      final data = doc.data() as Map<String, dynamic>?;
      return data?['shareCode'] as String?;
    } catch (e) {
      debugPrint('[ShareableMapsFirestore] share code lookup failed: $e');
      return null;
    }
  }

  /// True when the map document still exists.
  ///
  /// A run remembers which map it published to; if someone deleted that map
  /// from the gallery, republishing has to create a fresh one rather than
  /// writing a document back from under them.
  Future<bool> mapExists(String monthKey, String docId) async {
    try {
      final doc = await _mapsCollection(monthKey).doc(docId).get();
      return doc.exists;
    } catch (e) {
      debugPrint('[ShareableMapsFirestore] existence check failed: $e');
      return false;
    }
  }

  /// Save (overwrite) an existing map document.
  Future<void> saveMap(String monthKey, String docId, ShareableMap map) async {
    await _ensureMonthDoc(monthKey);
    final data = map.withStablePolygonIds().toMap();
    data['monthKey'] = monthKey;
    await _mapsCollection(monthKey).doc(docId).set(data);
    MapNameIndexService.instance.invalidate(); // name/description may change
    debugPrint('[ShareableMapsFirestore] Saved map $docId in $monthKey');
  }

  /// Update specific fields on a map document.
  Future<void> updateMapFields(
      String monthKey, String docId, Map<String, dynamic> fields) async {
    fields['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _mapsCollection(monthKey).doc(docId).update(fields);
    MapNameIndexService.instance.invalidate();
  }

  /// Clears `jobListItemId` on every map that names job-list item [jobId]
  /// except [keepMapId] — the job's map now. A map left pointing at a job it
  /// was unlinked from would still be handed the job's folder by the Cloud
  /// Function and offer the job's schedule allocation. Returns how many.
  Future<int> releaseJobListItemLink(String jobId,
      {required String keepMapId}) async {
    if (jobId.isEmpty) return 0;
    final snap = await _firestore
        .collectionGroup('maps')
        .where('jobListItemId', isEqualTo: jobId)
        .get();
    final stale = snap.docs.where((d) =>
        d.id != keepMapId && d.reference.path.startsWith('shareableMaps/'));
    final updates = {
      for (final d in stale)
        d.reference: <String, dynamic>{
          'jobListItemId': FieldValue.delete(),
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
    };
    await _commitInChunks(updates);
    return updates.length;
  }

  /// Update cached cloud waypoint count on every map document that is
  /// linked to [folderPath] via [ShareableMap.storageFolderPath].
  ///
  /// Called whenever the compiled GPX index for a folder is rebuilt so the
  /// gallery tile badges stay in sync with the actual cloud contents.
  /// Does NOT bump `updatedAt` to avoid reordering maps in the gallery just
  /// because their linked folder changed.
  Future<int> updateCloudCountsByFolderPath(
    String folderPath, {
    required int waypointCount,
  }) async {
    if (folderPath.isEmpty) return 0;
    try {
      final snapshot = await _firestore
          .collectionGroup('maps')
          .where('storageFolderPath', isEqualTo: folderPath)
          .get();
      if (snapshot.docs.isEmpty) return 0;
      final batch = _firestore.batch();
      for (final doc in snapshot.docs) {
        batch.update(doc.reference, {
          'cloudWaypointCount': waypointCount,
        });
      }
      await batch.commit();
      debugPrint(
          '[ShareableMapsFirestore] Updated cloud waypoint count for ${snapshot.docs.length} map(s) linked to "$folderPath" (waypoints=$waypointCount)');
      return snapshot.docs.length;
    } catch (e) {
      debugPrint(
          '[ShareableMapsFirestore] updateCloudCountsByFolderPath failed for "$folderPath": $e');
      return 0;
    }
  }

  /// When a Cloud Storage folder is renamed, update every Firestore document
  /// that referenced the old path — or any folder *under* it — so cloud track /
  /// waypoint loading and the distribution report keep working.
  ///
  /// Renaming a client folder also renames its `Round N` sub-folders, and
  /// renaming a month or year folder renames every job folder inside it, so
  /// an exact-path match alone leaves those links pointing at nothing.
  ///
  /// Fields updated on **shareable-map** documents:
  ///   - `storageFolderPath`
  ///   - `cloudFolderPaths` entries
  ///   - keys in `cloudTrackColors` and `cloudLayerNames` maps
  ///
  /// Fields updated on **job-list-item** documents:
  ///   - `storageFolderPath`
  ///
  /// The collection-group queries need the COLLECTION_GROUP field overrides in
  /// firestore.indexes.json and the `{path=**}` read rules in firestore.rules.
  ///
  /// Returns how many documents were updated as `({int maps, int jobs})`.
  Future<({int maps, int jobs})> updateFolderPathReference(
    String oldPath,
    String newPath,
  ) async {
    if (oldPath.isEmpty || newPath.isEmpty || oldPath == newPath) {
      return (maps: 0, jobs: 0);
    }

    String? remap(String path) {
      if (path == oldPath) return newPath;
      if (path.startsWith('$oldPath/')) {
        return newPath + path.substring(oldPath.length);
      }
      return null;
    }

    // Everything strictly below `oldPath/`: '/' + U+F8FF sorts after any
    // character a folder name can contain.
    Query<Map<String, dynamic>> under(Query<Map<String, dynamic>> q) => q
        .where('storageFolderPath', isGreaterThan: '$oldPath/')
        .where('storageFolderPath', isLessThan: '$oldPath/');

    try {
      // ── Job List Items ──────────────────────────────────────────────────
      final items = _firestore.collectionGroup('items');
      final jobSnaps = await Future.wait([
        items.where('storageFolderPath', isEqualTo: oldPath).get(),
        under(items).get(),
      ]);
      final jobUpdates = <DocumentReference, Map<String, dynamic>>{};
      for (final doc in jobSnaps.expand((s) => s.docs)) {
        if (!doc.reference.path.startsWith('jobLists/')) continue;
        final next = remap(doc.data()['storageFolderPath'] as String? ?? '');
        if (next != null) jobUpdates[doc.reference] = {'storageFolderPath': next};
      }

      // ── Shareable Maps ──────────────────────────────────────────────────
      // A map can name a sub-folder only in `cloudFolderPaths`, which has no
      // prefix query — so also take every map linked to an affected job.
      final maps = _firestore.collectionGroup('maps');
      final mapSnaps = await Future.wait([
        maps.where('storageFolderPath', isEqualTo: oldPath).get(),
        under(maps).get(),
        maps.where('cloudFolderPaths', arrayContains: oldPath).get(),
      ]);
      final mapDocs = <String, DocumentSnapshot<Map<String, dynamic>>>{
        for (final doc in mapSnaps.expand((s) => s.docs))
          doc.reference.path: doc,
      };
      final jobIds = jobUpdates.keys.map((r) => r.id).toList();
      for (var i = 0; i < jobIds.length; i += 30) {
        final chunk = jobIds.sublist(i, (i + 30).clamp(0, jobIds.length));
        final linked = await maps.where('jobListItemId', whereIn: chunk).get();
        for (final doc in linked.docs) {
          mapDocs[doc.reference.path] = doc;
        }
      }

      final mapUpdates = <DocumentReference, Map<String, dynamic>>{};
      for (final doc in mapDocs.values) {
        final data = doc.data() ?? const <String, dynamic>{};
        final update = <String, dynamic>{};

        final legacy = data['storageFolderPath'] as String?;
        final nextLegacy = legacy == null ? null : remap(legacy);
        if (nextLegacy != null) update['storageFolderPath'] = nextLegacy;

        final folders = (data['cloudFolderPaths'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList();
        final nextFolders = [for (final f in folders) remap(f) ?? f];
        if (!listEquals(folders, nextFolders)) {
          update['cloudFolderPaths'] = nextFolders;
        }

        for (final key in const ['cloudTrackColors', 'cloudLayerNames']) {
          final raw = data[key] as Map<String, dynamic>?;
          if (raw == null || !raw.keys.any((k) => remap(k) != null)) continue;
          update[key] = {
            for (final e in raw.entries) (remap(e.key) ?? e.key): e.value,
          };
        }

        if (update.isNotEmpty) mapUpdates[doc.reference] = update;
      }

      await _commitInChunks({...jobUpdates, ...mapUpdates});
      debugPrint('[ShareableMapsFirestore] updateFolderPathReference: '
          '"$oldPath" → "$newPath" updated ${mapUpdates.length} map(s), '
          '${jobUpdates.length} job item(s)');
      return (maps: mapUpdates.length, jobs: jobUpdates.length);
    } catch (e) {
      debugPrint(
          '[ShareableMapsFirestore] updateFolderPathReference failed: $e');
      rethrow;
    }
  }

  /// Apply [updates] in batches under Firestore's 500-writes-per-batch cap.
  Future<void> _commitInChunks(
      Map<DocumentReference, Map<String, dynamic>> updates) async {
    final entries = updates.entries.toList();
    for (var i = 0; i < entries.length; i += 400) {
      final batch = _firestore.batch();
      for (final e in entries.skip(i).take(400)) {
        batch.update(e.key, e.value);
      }
      await batch.commit();
    }
  }

  /// Moves a map to the Recycle Bin and returns the bin entry id (null if
  /// the map was already gone).
  ///
  /// The map doc and its share links are deleted and copied into the entry
  /// in one batch, so restoring brings the old share links back too. The
  /// thumbnail stays in Storage, owned by the entry, so a restored map keeps
  /// its picture; it is deleted when the entry is purged.
  Future<String?> deleteMapToBin(String monthKey, String docId) async {
    final ref = _mapsCollection(monthKey).doc(docId);
    final snap = await ref.get();
    if (!snap.exists) return null;
    final data = Map<String, dynamic>.from(snap.data() as Map);
    final links = await _firestore
        .collection('mapLinks')
        .where('monthKey', isEqualTo: monthKey)
        .where('mapId', isEqualTo: docId)
        .get();

    final writer = RecycleBinWriter(_firestore);
    final entryRef = writer.newEntryRef();
    // A map can come close to Firestore's 1 MiB cap on its own.
    final inline = fitsInline(data);
    final payloadRef = inline ? null : await uploadPayload(entryRef.id, data);
    final name = (data['name'] as String?)?.trim() ?? '';

    final batch = _firestore.batch();
    writer.addToBatch(
      batch,
      RecycleBinRecord(
        type: RecycleBinType.shareableMap,
        label: '${name.isEmpty ? 'Untitled map' : name} · $monthKey',
        originalPath: ref.path,
        payload: inline ? data : const {},
        payloadRef: payloadRef,
        related: [
          for (final l in links.docs) RecycleBinRelated(l.reference.path, l.data()),
        ],
        ownedStorage: [MapThumbnailService.pathFor(monthKey, docId)],
      ),
      ref: entryRef,
    );
    for (final l in links.docs) {
      batch.delete(l.reference);
    }
    batch.delete(ref);
    await batch.commit();
    debugPrint('[ShareableMapsFirestore] Map $docId ($monthKey) → Recycle Bin');
    return entryRef.id;
  }

  /// Delete a map document permanently. Prefer [deleteMapToBin].
  Future<void> deleteMap(String monthKey, String docId) async {
    await _mapsCollection(monthKey).doc(docId).delete();
    debugPrint('[ShareableMapsFirestore] Deleted map $docId from $monthKey');
  }

  /// Load a single map by its month key and document ID.
  Future<ShareableMap?> getMap(String monthKey, String docId) async {
    final doc = await _mapsCollection(monthKey).doc(docId).get();
    if (!doc.exists) return null;
    return ShareableMap.fromMap(
        doc.id, Map<String, dynamic>.from(doc.data() as Map));
  }

  /// Map [mapId] and its month key, looked for in the months of [near] and
  /// the month either side of each, or null when it is in none of them.
  ///
  /// Maps live under their creation month, which a caller holding only the
  /// id doesn't know. A collection-group query by id would need an index
  /// (and `jobListItemId` lookups need one that is not deployed), so this
  /// reads the few likely months directly instead.
  Future<(String, ShareableMap)?> findMapNear(
      String mapId, List<DateTime> near) async {
    if (mapId.isEmpty) return null;
    final keys = <String>{
      for (final d in near)
        for (final m in [-1, 0, 1])
          monthKeyFor(DateTime(d.year, d.month + m, 1)),
    };
    for (final key in keys) {
      final map = await getMap(key, mapId);
      if (map != null) return (key, map);
    }
    return null;
  }

  /// Stream a single map document for real-time updates.
  ///
  /// Emits a new [ShareableMap] every time the Firestore document changes.
  /// Emits `null` if the document is deleted.
  Stream<ShareableMap?> streamMap(String monthKey, String docId) {
    return _mapsCollection(monthKey).doc(docId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return ShareableMap.fromMap(
          doc.id, Map<String, dynamic>.from(doc.data() as Map));
    });
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Stream maps for a specific month (e.g. '03-2026').
  Stream<List<ShareableMap>> streamMapsByMonth(String monthKey) {
    return _mapsCollection(monthKey)
        .orderBy('updatedAt', descending: true)
        .snapshots()
        .map(_snapshotToList);
  }

  /// Fetch maps for a given month once.
  Future<List<ShareableMap>> getMapsByMonth(String monthKey) async {
    final snapshot = await _mapsCollection(monthKey)
        .orderBy('updatedAt', descending: true)
        .get();
    return _snapshotToList(snapshot);
  }

  /// Stream all maps across all months using Firestore collectionGroup.
  ///
  /// This listens to every `/shareableMaps/*/maps` sub-collection in a single
  /// reactive query. Each map document stores its `monthKey` field so we can
  /// pair it back without parsing the path.
  Stream<List<MapWithMonth>> streamAllMaps() {
    return _firestore
        .collectionGroup('maps')
        .orderBy('updatedAt', descending: true)
        .snapshots()
        .map((snapshot) {
      final List<MapWithMonth> results = [];
      for (final doc in snapshot.docs) {
        // Only include docs whose parent collection is under shareableMaps.
        // Path: shareableMaps/{monthKey}/maps/{mapId}
        final pathSegments = doc.reference.path.split('/');
        if (pathSegments.length >= 4 && pathSegments[0] == 'shareableMaps') {
          final data = doc.data();
          final mk = data['monthKey'] as String? ?? pathSegments[1];
          final map = ShareableMap.fromMap(doc.id, data);
          results.add(MapWithMonth(map: map, monthKey: mk));
        }
      }
      return results;
    });
  }

  /// Fetch all maps across months once (non-realtime).
  Future<List<MapWithMonth>> getAllMaps() async {
    final snapshot = await _firestore
        .collectionGroup('maps')
        .orderBy('updatedAt', descending: true)
        .get();
    final List<MapWithMonth> all = [];
    for (final doc in snapshot.docs) {
      final pathSegments = doc.reference.path.split('/');
      if (pathSegments.length >= 4 && pathSegments[0] == 'shareableMaps') {
        final data = doc.data();
        final mk = data['monthKey'] as String? ?? pathSegments[1];
        final map = ShareableMap.fromMap(doc.id, data);
        all.add(MapWithMonth(map: map, monthKey: mk));
      }
    }
    return all;
  }

  /// Get all month keys that have documents.
  Future<List<String>> getAvailableMonths() async {
    final snapshot = await _root.get();
    final months = snapshot.docs.map((d) => d.id).toList()
      ..sort((a, b) => _sortableKey(b).compareTo(_sortableKey(a)));
    return months;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  List<ShareableMap> _snapshotToList(QuerySnapshot snapshot) {
    return snapshot.docs.map((doc) {
      return ShareableMap.fromMap(
          doc.id, Map<String, dynamic>.from(doc.data() as Map));
    }).toList();
  }

  /// Derive a month key like '03-2026' from a DateTime.
  static String _monthKey(DateTime dt) {
    return '${dt.month.toString().padLeft(2, '0')}-${dt.year}';
  }

  /// Public helper so callers can compute the month key too.
  static String monthKeyFor(DateTime dt) => _monthKey(dt);

  /// Convert '03-2026' → '2026-03' for chronological sorting.
  static String _sortableKey(String mk) {
    final parts = mk.split('-');
    if (parts.length != 2) return mk;
    return '${parts[1]}-${parts[0]}';
  }
}

/// Pairs a [ShareableMap] with its monthly document key.
class MapWithMonth {
  final ShareableMap map;
  final String monthKey;

  const MapWithMonth({required this.map, required this.monthKey});
}
