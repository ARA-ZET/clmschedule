import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/erf_area.dart';
import '../models/erf_property.dart';

/// Firestore service for persisting ERF property data locally.
///
/// Collections:
///   /erfProperties/{lpiCode}  — one document per cadastral parcel
///   /erfAreas/{areaId}        — metadata for each downloaded suburb/extent
///
/// Parcels carry the `areaId` of the download they arrived with, so a suburb
/// can be loaded or removed on its own. Parcel documents are large (a polygon
/// each) and a single suburb can run to thousands of them, so nothing here
/// reads the whole collection.
class ErfPropertyFirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool get _hasSignedInUser => FirebaseAuth.instance.currentUser != null;

  /// Firestore rejects batches over 500 writes.
  static const int _batchLimit = 500;

  /// `whereIn` accepts at most 30 values per query.
  static const int _whereInLimit = 30;

  CollectionReference get _collection =>
      _firestore.collection('erfProperties');

  CollectionReference get _areasCollection => _firestore.collection('erfAreas');

  /// Save a property to Firestore.
  Future<void> saveProperty(ErfProperty property) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF property save because no user is signed in.');
      return;
    }
    try {
      await _collection.doc(property.id).set(property.toMap());
    } catch (e) {
      debugPrint('❌ Error saving property: $e');
      rethrow;
    }
  }

  /// Save multiple properties, splitting into batches that respect the
  /// 500-write Firestore limit.
  Future<void> saveProperties(List<ErfProperty> properties) async {
    if (properties.isEmpty) return;
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF property batch save because no user is signed in.');
      return;
    }
    try {
      for (var i = 0; i < properties.length; i += _batchLimit) {
        final end = (i + _batchLimit < properties.length)
            ? i + _batchLimit
            : properties.length;
        final batch = _firestore.batch();
        for (final property in properties.sublist(i, end)) {
          batch.set(_collection.doc(property.id), property.toMap());
        }
        await batch.commit();
      }
      debugPrint('✅ Saved ${properties.length} properties');
    } catch (e) {
      debugPrint('❌ Error saving properties batch: $e');
      rethrow;
    }
  }

  /// Get a property by its ID (LPI code).
  Future<ErfProperty?> getProperty(String id) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF property read because no user is signed in.');
      return null;
    }
    try {
      final doc = await _collection.doc(id).get();
      if (doc.exists) {
        return ErfProperty.fromMap(
            doc.id, Map<String, dynamic>.from(doc.data() as Map));
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error getting property: $e');
      return null;
    }
  }

  /// Get all saved properties for a suburb.
  Future<List<ErfProperty>> getPropertiesBySuburb(String suburb) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping suburb ERF read because no user is signed in.');
      return const [];
    }
    try {
      final snapshot = await _collection
          .where('suburb', isEqualTo: suburb)
          .get();
      return snapshot.docs
          .map((doc) =>
              ErfProperty.fromMap(doc.id, Map<String, dynamic>.from(doc.data() as Map)))
          .toList();
    } catch (e) {
      debugPrint('❌ Error getting properties by suburb: $e');
      return [];
    }
  }

  /// Get all saved properties for a cadastral minor code.
  Future<List<ErfProperty>> getPropertiesByMinCode(String minCode) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping minCode ERF read because no user is signed in.');
      return const [];
    }
    try {
      final snapshot = await _collection
          .where('minCode', isEqualTo: minCode)
          .get();
      return snapshot.docs
          .map((doc) =>
              ErfProperty.fromMap(doc.id, Map<String, dynamic>.from(doc.data() as Map)))
          .toList();
    } catch (e) {
      debugPrint('❌ Error getting properties by minCode: $e');
      return [];
    }
  }

  /// Update the street address for a property.
  Future<void> updateAddress(
      String id, String streetAddress, String suburb) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF address update because no user is signed in.');
      return;
    }
    try {
      await _collection.doc(id).update({
        'streetAddress': streetAddress,
        'suburb': suburb,
      });
    } catch (e) {
      debugPrint('❌ Error updating address: $e');
      rethrow;
    }
  }

  /// Delete a property.
  Future<void> deleteProperty(String id) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF property delete because no user is signed in.');
      return;
    }
    try {
      await _collection.doc(id).delete();
    } catch (e) {
      debugPrint('❌ Error deleting property: $e');
      rethrow;
    }
  }

  /// Load every parcel belonging to a downloaded area.
  ///
  /// Parcel geometry never changes once downloaded, so this is a one-shot
  /// read rather than a stream.
  Future<List<ErfProperty>> getPropertiesByArea(String areaId) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF area read because no user is signed in.');
      return const [];
    }
    try {
      final snapshot =
          await _collection.where('areaId', isEqualTo: areaId).get();
      return snapshot.docs.map(_fromDoc).toList();
    } catch (e) {
      debugPrint('❌ Error getting properties for area $areaId: $e');
      return [];
    }
  }

  /// Find cached parcels by ERF number (TAG_VALUE), optionally restricted to
  /// one cadastral region.
  ///
  /// ERF numbers repeat between suburbs, so the caller is expected to
  /// disambiguate whatever comes back when [minCode] is not given.
  Future<List<ErfProperty>> findByErfNumbers(
    List<String> erfNumbers, {
    String? minCode,
    String? areaId,
  }) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF number lookup because no user is signed in.');
      return const [];
    }
    final unique = erfNumbers
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (unique.isEmpty) return [];

    final found = <String, ErfProperty>{};
    try {
      for (var i = 0; i < unique.length; i += _whereInLimit) {
        final end = (i + _whereInLimit < unique.length)
            ? i + _whereInLimit
            : unique.length;

        // Only the `tagValue` filter goes to the server. Adding minCode or
        // areaId as a second equality filter would need a composite index,
        // and the result set here is at most 30 ERF numbers' worth of
        // parcels, so the narrowing is cheaper to do in memory.
        final snapshot = await _collection
            .where('tagValue', whereIn: unique.sublist(i, end))
            .get();

        for (final doc in snapshot.docs) {
          final property = _fromDoc(doc);
          if (minCode != null &&
              minCode.isNotEmpty &&
              property.minCode != minCode) {
            continue;
          }
          if (areaId != null &&
              areaId.isNotEmpty &&
              property.areaId != areaId) {
            continue;
          }
          found[property.id] = property;
        }
      }
    } catch (e) {
      debugPrint('❌ Error finding properties by ERF number: $e');
    }
    return found.values.toList();
  }

  // ── Downloaded areas ────────────────────────────────────────────────

  /// Stream the list of downloaded areas. These documents are small, so the
  /// whole collection is safe to watch.
  Stream<List<ErfArea>> streamAreas() {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF area stream because no user is signed in.');
      return const Stream.empty();
    }
    return _areasCollection.snapshots().map((snapshot) {
      final areas = snapshot.docs
          .map((doc) => ErfArea.fromMap(
              doc.id, Map<String, dynamic>.from(doc.data() as Map)))
          .toList();
      areas.sort((a, b) => a.name.compareTo(b.name));
      return areas;
    });
  }

  Future<void> saveArea(ErfArea area) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF area save because no user is signed in.');
      return;
    }
    try {
      await _areasCollection.doc(area.id).set(area.toMap());
    } catch (e) {
      debugPrint('❌ Error saving ERF area: $e');
      rethrow;
    }
  }

  /// Delete an area and every parcel that belongs to it.
  Future<void> deleteArea(String areaId) async {
    if (!_hasSignedInUser) {
      debugPrint('ℹ️ Skipping ERF area delete because no user is signed in.');
      return;
    }
    try {
      var deleted = 0;
      while (true) {
        final snapshot = await _collection
            .where('areaId', isEqualTo: areaId)
            .limit(_batchLimit)
            .get();
        if (snapshot.docs.isEmpty) break;

        final batch = _firestore.batch();
        for (final doc in snapshot.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        deleted += snapshot.docs.length;
      }
      await _areasCollection.doc(areaId).delete();
      debugPrint('🗑️ Deleted area $areaId and $deleted parcels');
    } catch (e) {
      debugPrint('❌ Error deleting ERF area: $e');
      rethrow;
    }
  }

  /// Whether the parcel collection holds anything at all.
  ///
  /// One document read, used to spot ERF data saved before areas existed.
  Future<bool> hasAnyProperties() async {
    try {
      final snapshot = await _collection.limit(1).get();
      return snapshot.docs.isNotEmpty;
    } catch (e) {
      debugPrint('❌ Error probing erfProperties: $e');
      return false;
    }
  }

  /// Read every parcel document in the collection.
  ///
  /// Only used to migrate data written before parcels were packed into
  /// Storage files. It is a full scan, so it runs once, on request, with
  /// progress — never on screen open.
  Future<List<ErfProperty>> loadLegacyProperties({
    required void Function(int scanned) onProgress,
  }) async {
    final all = <ErfProperty>[];
    DocumentSnapshot? cursor;

    while (true) {
      Query query =
          _collection.orderBy(FieldPath.documentId).limit(_batchLimit);
      if (cursor != null) query = query.startAfterDocument(cursor);

      final snapshot = await query.get();
      if (snapshot.docs.isEmpty) break;

      cursor = snapshot.docs.last;
      all.addAll(snapshot.docs.map(_fromDoc));
      onProgress(all.length);

      if (snapshot.docs.length < _batchLimit) break;
    }

    return all;
  }

  /// Delete parcel documents by id, in batches.
  ///
  /// Used after their contents have been packed into a Storage file and read
  /// back successfully.
  Future<int> deletePropertiesByIds(
    List<String> ids, {
    void Function(int deleted)? onProgress,
  }) async {
    var deleted = 0;
    for (var i = 0; i < ids.length; i += _batchLimit) {
      final end = (i + _batchLimit < ids.length) ? i + _batchLimit : ids.length;
      final batch = _firestore.batch();
      for (final id in ids.sublist(i, end)) {
        batch.delete(_collection.doc(id));
      }
      await batch.commit();
      deleted += end - i;
      onProgress?.call(deleted);
    }
    debugPrint('🗑️ Deleted $deleted legacy parcel documents');
    return deleted;
  }

  static ErfProperty _fromDoc(DocumentSnapshot doc) => ErfProperty.fromMap(
        doc.id,
        Map<String, dynamic>.from(doc.data() as Map),
      );
}
