import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/shareable_map.dart';
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
    await _ensureMonthDoc(mk);
    final data = map.toMap();
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

  /// Save (overwrite) an existing map document.
  Future<void> saveMap(String monthKey, String docId, ShareableMap map) async {
    await _ensureMonthDoc(monthKey);
    final data = map.toMap();
    data['monthKey'] = monthKey;
    await _mapsCollection(monthKey).doc(docId).set(data);
    debugPrint('[ShareableMapsFirestore] Saved map $docId in $monthKey');
  }

  /// Update specific fields on a map document.
  Future<void> updateMapFields(
      String monthKey, String docId, Map<String, dynamic> fields) async {
    fields['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _mapsCollection(monthKey).doc(docId).update(fields);
  }

  /// Delete a map document.
  Future<void> deleteMap(String monthKey, String docId) async {
    await _mapsCollection(monthKey).doc(docId).delete();
    debugPrint('[ShareableMapsFirestore] Deleted map $docId from $monthKey');
  }

  /// Load a single map by its month key and document ID.
  Future<ShareableMap?> getMap(String monthKey, String docId) async {
    final doc = await _mapsCollection(monthKey).doc(docId).get();
    if (!doc.exists) return null;
    return ShareableMap.fromMap(doc.id, doc.data() as Map<String, dynamic>);
  }

  /// Stream a single map document for real-time updates.
  ///
  /// Emits a new [ShareableMap] every time the Firestore document changes.
  /// Emits `null` if the document is deleted.
  Stream<ShareableMap?> streamMap(String monthKey, String docId) {
    return _mapsCollection(monthKey).doc(docId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return ShareableMap.fromMap(doc.id, doc.data() as Map<String, dynamic>);
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
      return ShareableMap.fromMap(doc.id, doc.data() as Map<String, dynamic>);
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
