import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/erf_property.dart';

/// Firestore service for persisting ERF property data locally.
///
/// Collection: /erfProperties/{lpiCode}
class ErfPropertyFirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CollectionReference get _collection =>
      _firestore.collection('erfProperties');

  /// Save a property to Firestore.
  Future<void> saveProperty(ErfProperty property) async {
    try {
      await _collection.doc(property.id).set(property.toMap());
    } catch (e) {
      debugPrint('❌ Error saving property: $e');
      rethrow;
    }
  }

  /// Save multiple properties in a batch.
  Future<void> saveProperties(List<ErfProperty> properties) async {
    try {
      final batch = _firestore.batch();
      for (final property in properties) {
        batch.set(_collection.doc(property.id), property.toMap());
      }
      await batch.commit();
      debugPrint('✅ Saved ${properties.length} properties');
    } catch (e) {
      debugPrint('❌ Error saving properties batch: $e');
      rethrow;
    }
  }

  /// Get a property by its ID (LPI code).
  Future<ErfProperty?> getProperty(String id) async {
    try {
      final doc = await _collection.doc(id).get();
      if (doc.exists) {
        return ErfProperty.fromMap(
            doc.id, doc.data() as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error getting property: $e');
      return null;
    }
  }

  /// Get all saved properties for a suburb.
  Future<List<ErfProperty>> getPropertiesBySuburb(String suburb) async {
    try {
      final snapshot = await _collection
          .where('suburb', isEqualTo: suburb)
          .get();
      return snapshot.docs
          .map((doc) =>
              ErfProperty.fromMap(doc.id, doc.data() as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('❌ Error getting properties by suburb: $e');
      return [];
    }
  }

  /// Get all saved properties for a cadastral minor code.
  Future<List<ErfProperty>> getPropertiesByMinCode(String minCode) async {
    try {
      final snapshot = await _collection
          .where('minCode', isEqualTo: minCode)
          .get();
      return snapshot.docs
          .map((doc) =>
              ErfProperty.fromMap(doc.id, doc.data() as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('❌ Error getting properties by minCode: $e');
      return [];
    }
  }

  /// Update the street address for a property.
  Future<void> updateAddress(
      String id, String streetAddress, String suburb) async {
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
    try {
      await _collection.doc(id).delete();
    } catch (e) {
      debugPrint('❌ Error deleting property: $e');
      rethrow;
    }
  }

  /// Stream all properties (for real-time updates).
  Stream<List<ErfProperty>> streamProperties() {
    return _collection.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) =>
              ErfProperty.fromMap(doc.id, doc.data() as Map<String, dynamic>))
          .toList();
    });
  }
}
