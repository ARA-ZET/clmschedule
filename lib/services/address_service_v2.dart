import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/address.dart';
import '../models/route_data.dart';

/// Service for managing addresses in Firestore
/// Structure: home_choice/suburbs/{suburbName}: [addresses array]
class AddressServiceV2 {
  final FirebaseFirestore _firestore;

  AddressServiceV2(this._firestore);

  /// Get list of all suburbs
  Future<List<String>> getSuburbs() async {
    try {
      final doc =
          await _firestore.collection('home_choice').doc('suburbs').get();
      if (!doc.exists || doc.data() == null) return [];

      final data = doc.data()!;
      // Filter out metadata fields (starting with _)
      final suburbs = data.keys.where((key) => !key.startsWith('_')).toList()
        ..sort();

      return suburbs;
    } catch (e) {
      debugPrint('Error getting suburbs: $e');
      return [];
    }
  }

  /// Get stream of suburbs
  Stream<List<String>> getSuburbsStream() {
    return _firestore
        .collection('home_choice')
        .doc('suburbs')
        .snapshots()
        .map((doc) {
      if (!doc.exists || doc.data() == null) return <String>[];

      final data = doc.data()!;
      return data.keys.where((key) => !key.startsWith('_')).toList()..sort();
    });
  }

  /// Get addresses for a specific suburb
  Future<List<Address>> getAddresses(String suburb) async {
    try {
      final doc =
          await _firestore.collection('home_choice').doc('suburbs').get();
      if (!doc.exists || doc.data() == null) return [];

      final data = doc.data()!;
      if (!data.containsKey(suburb)) return [];

      final addressesData = data[suburb] as List<dynamic>;
      return addressesData.asMap().entries.map((entry) {
        final map = Map<String, dynamic>.from(entry.value as Map);
        return Address.fromMap('$suburb-${entry.key}', map);
      }).toList();
    } catch (e) {
      debugPrint('Error getting addresses for $suburb: $e');
      return [];
    }
  }

  /// Get stream of addresses for a specific suburb
  Stream<List<Address>> getAddressesStream(String suburb) {
    return _firestore
        .collection('home_choice')
        .doc('suburbs')
        .snapshots()
        .map((doc) {
      if (!doc.exists || doc.data() == null) return <Address>[];

      final data = doc.data()!;
      if (!data.containsKey(suburb)) return <Address>[];

      final addressesData = data[suburb] as List<dynamic>;
      return addressesData.asMap().entries.map((entry) {
        final map = Map<String, dynamic>.from(entry.value as Map);
        return Address.fromMap('$suburb-${entry.key}', map);
      }).toList();
    });
  }

  /// Get all addresses from all suburbs
  Future<List<Address>> getAllAddresses() async {
    try {
      final doc =
          await _firestore.collection('home_choice').doc('suburbs').get();
      if (!doc.exists || doc.data() == null) return [];

      final data = doc.data()!;
      final allAddresses = <Address>[];

      for (final suburb in data.keys) {
        if (suburb.startsWith('_')) continue; // Skip metadata

        final addressesData = data[suburb] as List<dynamic>;
        final addresses = addressesData.asMap().entries.map((entry) {
          final map = Map<String, dynamic>.from(entry.value as Map);
          return Address.fromMap('$suburb-${entry.key}', map);
        }).toList();

        allAddresses.addAll(addresses);
      }

      return allAddresses;
    } catch (e) {
      debugPrint('Error getting all addresses: $e');
      return [];
    }
  }

  /// Set/replace all addresses for a suburb
  Future<void> setSuburbAddresses(
      String suburb, List<Map<String, String>> rawAddresses) async {
    try {
      final addressMaps = rawAddresses.map((raw) {
        return {
          'streetAddress': raw['streetAddress'] ?? '',
          'suburb': raw['suburb'] ?? suburb,
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

      await _firestore.collection('home_choice').doc('suburbs').set({
        suburb: addressMaps,
      }, SetOptions(merge: true));

      debugPrint('✅ Set ${addressMaps.length} addresses for suburb: $suburb');
    } catch (e) {
      debugPrint('❌ Error setting suburb addresses: $e');
      rethrow;
    }
  }

  /// Update a single address in a suburb
  Future<void> updateAddress(String suburb, int index, Address address) async {
    try {
      final addresses = await getAddresses(suburb);
      if (index < 0 || index >= addresses.length) {
        debugPrint('❌ Index out of bounds: $index');
        return;
      }

      addresses[index] = address;
      final addressMaps = addresses.map((a) => a.toMap()).toList();

      await _firestore.collection('home_choice').doc('suburbs').update({
        suburb: addressMaps,
      });

      debugPrint('✅ Updated address at index $index in $suburb');
    } catch (e) {
      debugPrint('❌ Error updating address: $e');
      rethrow;
    }
  }

  /// Batch update addresses for a suburb
  Future<void> batchUpdateAddresses(
      String suburb, List<Address> addresses) async {
    try {
      final addressMaps = addresses.map((a) => a.toMap()).toList();

      await _firestore.collection('home_choice').doc('suburbs').update({
        suburb: addressMaps,
      });

      debugPrint('✅ Batch updated ${addressMaps.length} addresses for $suburb');
    } catch (e) {
      debugPrint('❌ Error batch updating addresses: $e');
      rethrow;
    }
  }

  /// Delete a suburb and all its addresses
  Future<void> deleteSuburb(String suburb) async {
    try {
      await _firestore.collection('home_choice').doc('suburbs').update({
        suburb: FieldValue.delete(),
      });

      debugPrint('✅ Deleted suburb: $suburb');
    } catch (e) {
      debugPrint('❌ Error deleting suburb: $e');
      rethrow;
    }
  }

  /// Parse addresses from pasted text
  /// Supports formats: CSV, TSV, JSON, or line-by-line with commas
  List<Map<String, String>> parseAddressesFromText(
      String text, String defaultSuburb) {
    final addresses = <Map<String, String>>[];
    final lines =
        text.split('\n').where((line) => line.trim().isNotEmpty).toList();

    for (final line in lines) {
      // Try to parse as CSV/TSV
      List<String> parts;
      if (line.contains('\t')) {
        parts = line.split('\t');
      } else if (line.contains(',')) {
        parts = line.split(',');
      } else {
        // Single field - treat as street address
        parts = [line];
      }

      parts = parts.map((p) => p.trim()).toList();

      addresses.add({
        'streetAddress': parts.isNotEmpty ? parts[0] : '',
        'suburb':
            parts.length > 1 && parts[1].isNotEmpty ? parts[1] : defaultSuburb,
        'city':
            parts.length > 2 && parts[2].isNotEmpty ? parts[2] : 'CAPE TOWN',
        'postalCode': parts.length > 3 ? parts[3] : '',
        'province':
            parts.length > 4 && parts[4].isNotEmpty ? parts[4] : 'Western Cape',
        'country':
            parts.length > 5 && parts[5].isNotEmpty ? parts[5] : 'South Africa',
      });
    }

    return addresses;
  }

  /// Get statistics for a suburb
  Future<Map<String, int>> getSuburbStats(String suburb) async {
    final addresses = await getAddresses(suburb);
    final geocoded = addresses.where((a) => a.isGeocoded).length;

    return {
      'total': addresses.length,
      'geocoded': geocoded,
      'pending': addresses.length - geocoded,
    };
  }

  /// Get statistics for all suburbs
  Future<Map<String, dynamic>> getAllStats() async {
    final suburbs = await getSuburbs();
    int totalAddresses = 0;
    int totalGeocoded = 0;

    for (final suburb in suburbs) {
      final stats = await getSuburbStats(suburb);
      totalAddresses += stats['total'] ?? 0;
      totalGeocoded += stats['geocoded'] ?? 0;
    }

    return {
      'totalSuburbs': suburbs.length,
      'totalAddresses': totalAddresses,
      'totalGeocoded': totalGeocoded,
      'totalPending': totalAddresses - totalGeocoded,
    };
  }

  /// Save optimized route for a suburb (updates addresses with route indices in one call)
  Future<void> saveOptimizedRoute(
    String suburb,
    List<Address> optimizedAddresses,
  ) async {
    try {
      // Add route indices to addresses
      final addressesWithIndices = <Map<String, dynamic>>[];
      for (int i = 0; i < optimizedAddresses.length; i++) {
        final address = optimizedAddresses[i].copyWith(routeIndex: i);
        addressesWithIndices.add(address.toMap());
      }

      // Save all addresses in one call
      await _firestore.collection('home_choice').doc('suburbs').set(
        {suburb: addressesWithIndices},
        SetOptions(merge: true),
      );

      debugPrint(
          'Saved optimized route for $suburb with ${optimizedAddresses.length} addresses');
    } catch (e) {
      debugPrint('Error saving optimized route: $e');
      rethrow;
    }
  }

  /// Save complete route data with segments for a suburb (one call)
  Future<void> saveSuburbRouteData(SuburbRouteData routeData) async {
    try {
      await _firestore.collection('home_choice').doc('suburbs_routes').set(
        {routeData.suburb: routeData.toMap()},
        SetOptions(merge: true),
      );

      debugPrint('Saved route data for ${routeData.suburb}: '
          '${routeData.segments.length} segments, '
          '${routeData.totalDistanceKm.toStringAsFixed(1)} km, '
          '${routeData.totalDurationFormatted}');
    } catch (e) {
      debugPrint('Error saving route data: $e');
      rethrow;
    }
  }

  /// Get route data for a suburb
  Future<SuburbRouteData?> getSuburbRouteData(String suburb) async {
    try {
      final doc = await _firestore
          .collection('home_choice')
          .doc('suburbs_routes')
          .get();
      if (!doc.exists || doc.data() == null) return null;

      final data = doc.data()!;
      if (!data.containsKey(suburb)) return null;

      return SuburbRouteData.fromMap(Map<String, dynamic>.from(data[suburb] as Map));
    } catch (e) {
      debugPrint('Error getting route data: $e');
      return null;
    }
  }

  /// Delete route data for a suburb
  Future<void> deleteSuburbRouteData(String suburb) async {
    try {
      await _firestore.collection('home_choice').doc('suburbs_routes').update({
        suburb: FieldValue.delete(),
      });

      debugPrint('Deleted route data for $suburb');
    } catch (e) {
      debugPrint('Error deleting route data: $e');
      rethrow;
    }
  }
}
