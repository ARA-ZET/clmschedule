import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/address.dart';

/// Service for managing addresses in Firestore
class AddressService {
  final FirebaseFirestore _firestore;

  AddressService(this._firestore);

  /// Get addresses for a specific area (e.g., 'pinelands')
  Stream<List<Address>> getAddressesStream(
      String collectionName, String areaName) {
    return _firestore
        .collection('home_choice')
        .doc(collectionName)
        .snapshots()
        .map((doc) {
      if (!doc.exists || doc.data() == null) return <Address>[];

      final data = doc.data()!;
      final addressesData = data[areaName] as List<dynamic>?;

      if (addressesData == null) return <Address>[];

      return addressesData.asMap().entries.map((entry) {
        final index = entry.key;
        final addressMap = entry.value as Map<String, dynamic>;
        return Address.fromMap('$areaName-$index', addressMap);
      }).toList();
    });
  }

  /// Get addresses once (not streaming)
  Future<List<Address>> getAddresses(
      String collectionName, String areaName) async {
    try {
      final doc =
          await _firestore.collection('home_choice').doc(collectionName).get();

      if (!doc.exists || doc.data() == null) return <Address>[];

      final data = doc.data()!;
      final addressesData = data[areaName] as List<dynamic>?;

      if (addressesData == null) return <Address>[];

      return addressesData.asMap().entries.map((entry) {
        final index = entry.key;
        final addressMap = entry.value as Map<String, dynamic>;
        return Address.fromMap('$areaName-$index', addressMap);
      }).toList();
    } catch (e) {
      debugPrint('Error getting addresses: $e');
      return <Address>[];
    }
  }

  /// Initialize addresses from raw data (first time setup)
  Future<void> initializeAddresses(
    String collectionName,
    String areaName,
    List<Map<String, String>> rawAddresses,
  ) async {
    try {
      final addresses = rawAddresses.map((raw) {
        return {
          'streetAddress': raw['streetAddress'] ?? '',
          'suburb': raw['suburb'] ?? '',
          'city': raw['city'] ?? '',
          'postalCode': raw['postalCode'] ?? '',
          'province': raw['province'] ?? '',
          'country': raw['country'] ?? '',
          'latitude': null,
          'longitude': null,
          'isGeocoded': false,
          'geocodingError': null,
        };
      }).toList();

      await _firestore
          .collection('home_choice')
          .doc(collectionName)
          .set({areaName: addresses}, SetOptions(merge: true));

      debugPrint(
          '✅ Initialized ${addresses.length} addresses in $collectionName/$areaName');
    } catch (e) {
      debugPrint('❌ Error initializing addresses: $e');
      rethrow;
    }
  }

  /// Update a single address with geocoded data
  Future<void> updateAddress(
    String collectionName,
    String areaName,
    int index,
    Address address,
  ) async {
    try {
      final doc =
          await _firestore.collection('home_choice').doc(collectionName).get();

      if (!doc.exists) return;

      final data = doc.data()!;
      final addresses = List<Map<String, dynamic>>.from(data[areaName] ?? []);

      if (index >= 0 && index < addresses.length) {
        addresses[index] = address.toMap();

        await _firestore
            .collection('home_choice')
            .doc(collectionName)
            .update({areaName: addresses});

        debugPrint('✅ Updated address at index $index');
      }
    } catch (e) {
      debugPrint('❌ Error updating address: $e');
      rethrow;
    }
  }

  /// Batch update multiple addresses
  Future<void> batchUpdateAddresses(
    String collectionName,
    String areaName,
    List<Address> addresses,
  ) async {
    try {
      final addressMaps = addresses.map((addr) => addr.toMap()).toList();

      await _firestore
          .collection('home_choice')
          .doc(collectionName)
          .set({areaName: addressMaps}, SetOptions(merge: true));

      debugPrint('✅ Batch updated ${addresses.length} addresses');
    } catch (e) {
      debugPrint('❌ Error batch updating addresses: $e');
      rethrow;
    }
  }
}
