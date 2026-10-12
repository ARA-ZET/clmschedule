import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../erf_property/models/erf_property.dart';

/// Stores the cadastral parcels behind a suburb's delivery list.
///
/// Parcels are kept apart from the addresses on purpose. A boundary is
/// dozens of coordinates, and 80 of them would dwarf the address array they
/// were attached to — the suburbs document has a 1 MB ceiling and the
/// addresses have to stay cheap to read and rewrite on every geocode. So
/// the addresses hold only an [Address.erfId] join key, and the geometry
/// lives here, one document for the whole tool.
///
/// This deliberately does not write a document per parcel: the ERF viewer
/// learned that lesson already, where a per-parcel layout turned opening a
/// suburb into a thousand reads.
class ErfParcelStore {
  final FirebaseFirestore _firestore;

  ErfParcelStore(this._firestore);

  static const String _collection = 'home_choice';
  static const String _document = 'suburb_parcels';

  /// Firestore rejects a document over 1 MB. Staying well under it leaves
  /// room for the other suburbs sharing this document.
  static const int maxSuburbPayloadBytes = 600 * 1024;

  /// Parcels for [suburb], keyed by [ErfProperty.id].
  Future<Map<String, ErfProperty>> getParcels(String suburb) async {
    try {
      final doc = await _firestore.collection(_collection).doc(_document).get();
      if (!doc.exists || doc.data() == null) return {};

      final data = doc.data()!;
      final value = data[suburb];
      if (value is! List) return {};

      final parcels = <String, ErfProperty>{};
      for (final entry in value) {
        if (entry is! Map) continue;
        try {
          final map = Map<String, dynamic>.from(entry);
          final id = map['id'] as String? ?? '';
          if (id.isEmpty) continue;
          parcels[id] = ErfProperty.fromMap(id, map);
        } catch (e) {
          debugPrint('Skipping a parcel in $suburb: $e');
        }
      }
      return parcels;
    } catch (e) {
      debugPrint('Error reading parcels for $suburb: $e');
      return {};
    }
  }

  /// Replace the parcels stored for [suburb].
  ///
  /// Returns false without writing when the payload would be too large —
  /// the caller keeps them in memory for the session and tells the user,
  /// which is far better than a write that fails halfway.
  Future<bool> saveParcels(String suburb, Iterable<ErfProperty> parcels) async {
    final encoded = [
      for (final parcel in parcels) {...parcel.toMap(), 'id': parcel.id},
    ];

    final size = utf8.encode(jsonEncode(encoded)).length;
    if (size > maxSuburbPayloadBytes) {
      debugPrint('Parcels for $suburb are ${size ~/ 1024} KB — too large to '
          'store, keeping them in memory only');
      return false;
    }

    try {
      await _firestore.collection(_collection).doc(_document).set(
        {suburb: encoded},
        SetOptions(merge: true),
      );
      debugPrint('Saved ${encoded.length} parcels for $suburb '
          '(${size ~/ 1024} KB)');
      return true;
    } catch (e) {
      debugPrint('Error saving parcels for $suburb: $e');
      return false;
    }
  }

  Future<void> deleteParcels(String suburb) async {
    try {
      await _firestore.collection(_collection).doc(_document).update({
        suburb: FieldValue.delete(),
      });
    } catch (e) {
      debugPrint('Error deleting parcels for $suburb: $e');
    }
  }
}
