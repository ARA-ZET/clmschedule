import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/address.dart';
import '../models/route_data.dart';
import 'address_import_parser.dart';

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
      // Metadata keys start with _; other keys may hold something that is
      // not an address array, and those are not suburbs either.
      final suburbs = data.keys
          .where((key) => !key.startsWith('_') && data[key] is List)
          .toList()
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

  /// Get addresses for a specific suburb.
  ///
  /// Throws if the document cannot be read, so the caller can show a real
  /// error rather than an empty list that looks like "no addresses here".
  /// Individual malformed records are skipped, not fatal.
  Future<List<Address>> getAddresses(String suburb) async {
    final doc = await _firestore.collection('home_choice').doc('suburbs').get();
    if (!doc.exists || doc.data() == null) return [];

    final data = doc.data()!;
    if (!data.containsKey(suburb)) return [];

    return parseSuburbEntry(suburb, data[suburb]);
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

      return parseSuburbEntry(suburb, data[suburb]);
    });
  }

  /// Get all addresses from all suburbs.
  ///
  /// Parsing is isolated per suburb and per entry: one malformed record
  /// costs that record, not the whole document. This used to be a single
  /// try/catch around the entire loop, which meant one unexpected value
  /// under any key returned an empty list and the tool looked like it had
  /// no data at all.
  Future<List<Address>> getAllAddresses() async {
    final doc = await _firestore.collection('home_choice').doc('suburbs').get();
    if (!doc.exists || doc.data() == null) return [];

    final data = doc.data()!;
    final allAddresses = <Address>[];

    for (final suburb in data.keys) {
      allAddresses.addAll(parseSuburbEntry(suburb, data[suburb]));
    }
    return allAddresses;
  }

  /// Read one suburb's entry into addresses, skipping anything unusable.
  ///
  /// Returns empty for metadata keys and for values that are not a list
  /// of maps — the document holds more than just address arrays. Static
  /// and pure so the parsing can be tested without a Firestore.
  static List<Address> parseSuburbEntry(String suburb, dynamic value) {
    if (suburb.startsWith('_')) return const [];
    if (value is! List) {
      debugPrint('Skipping "$suburb": not an address list '
          '(${value.runtimeType})');
      return const [];
    }

    final addresses = <Address>[];
    for (var i = 0; i < value.length; i++) {
      final entry = value[i];
      if (entry is! Map) {
        debugPrint('Skipping $suburb[$i]: not a map (${entry.runtimeType})');
        continue;
      }
      try {
        addresses.add(
          Address.fromMap('$suburb-$i', Map<String, dynamic>.from(entry)),
        );
      } catch (e) {
        debugPrint('Skipping $suburb[$i]: $e');
      }
    }
    return addresses;
  }

  /// Counts for every suburb, from a single document read.
  ///
  /// Keys whose value is not an address list are left out entirely, so
  /// route caches or metadata stored alongside never show up as empty
  /// suburbs.
  Future<Map<String, Map<String, int>>> getAllSuburbStats() async {
    final doc = await _firestore.collection('home_choice').doc('suburbs').get();
    if (!doc.exists || doc.data() == null) return {};

    final data = doc.data()!;
    final stats = <String, Map<String, int>>{};

    for (final suburb in data.keys) {
      if (suburb.startsWith('_')) continue;
      final value = data[suburb];
      if (value is! List) continue;

      final addresses = parseSuburbEntry(suburb, value);
      stats[suburb] = {
        'total': addresses.length,
        'geocoded': addresses.where((a) => a.isGeocoded).length,
        'review': addresses
            .where((a) => a.isGeocoded && a.precision.needsReview)
            .length,
      };
    }

    return stats;
  }

  /// Set/replace all addresses for a suburb
  Future<void> setSuburbAddresses(
      String suburb, List<Map<String, String>> rawAddresses) async {
    try {
      final addressMaps = rawAddresses.map(_rawToMap(suburb)).toList();

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

  /// Parse addresses from pasted text.
  ///
  /// Delegates to [AddressImportParser], which handles CSV/TSV columns,
  /// header rows, quoted commas, list numbering and free-text lines.
  List<Map<String, String>> parseAddressesFromText(
    String text,
    String defaultSuburb, {
    AddressParseMode mode = AddressParseMode.auto,
  }) {
    return parseAddressesDetailed(text, defaultSuburb, mode: mode)
        .addresses
        .map((a) => a.toRawMap())
        .toList();
  }

  /// Parse pasted text, keeping the duplicate/skipped report so the
  /// import screen can show what was dropped and why.
  AddressParseResult parseAddressesDetailed(
    String text,
    String defaultSuburb, {
    AddressParseMode mode = AddressParseMode.auto,
  }) {
    return AddressImportParser(defaultSuburb: defaultSuburb)
        .parse(text, mode: mode);
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

  /// Record the drive order for a suburb, in one write.
  ///
  /// The order is stored as a `routeIndex` on each address; the array
  /// itself is left in the position it was already in. That matters
  /// because an [Address.id] is derived from its slot (`<suburb>-<n>`),
  /// so physically reordering the array silently reassigns every id —
  /// and a subsequent [updateAddress] or [deleteAddress], which address
  /// an entry by that position, would then write over the wrong one.
  Future<void> saveOptimizedRoute(
    String suburb,
    List<Address> optimizedAddresses,
  ) async {
    try {
      final orderById = <String, int>{
        for (var i = 0; i < optimizedAddresses.length; i++)
          optimizedAddresses[i].id: i,
      };

      final stored = await getAddresses(suburb);
      final updated = [
        for (final address in stored)
          address.copyWith(routeIndex: orderById[address.id]).toMap(),
      ];

      await _firestore.collection('home_choice').doc('suburbs').set(
        {suburb: updated},
        SetOptions(merge: true),
      );

      debugPrint('Saved drive order for $suburb '
          '(${orderById.length} of ${stored.length} addresses routed)');
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

  /// Add addresses to a suburb, keeping what is already there.
  ///
  /// Rows matching an existing address (same street/suburb/city) are
  /// skipped rather than duplicated. Returns how many were actually added.
  Future<int> appendSuburbAddresses(
    String suburb,
    List<Map<String, String>> rawAddresses, {
    bool skipDuplicates = true,
  }) async {
    final existing = await getAddresses(suburb);
    final seen = existing.map((a) => a.dedupeKey).toSet();

    final toAdd = <Map<String, dynamic>>[];
    for (final raw in rawAddresses) {
      final map = _rawToMap(suburb)(raw);
      final key = [
        (map['streetAddress'] as String).trim().toLowerCase(),
        (map['suburb'] as String).trim().toLowerCase(),
        (map['city'] as String).trim().toLowerCase(),
      ].join('|');
      if (skipDuplicates && !seen.add(key)) continue;
      toAdd.add(map);
    }

    if (toAdd.isEmpty) return 0;

    final merged = [
      ...existing.map((a) => a.toMap()),
      ...toAdd,
    ];
    await _firestore.collection('home_choice').doc('suburbs').set(
      {suburb: merged},
      SetOptions(merge: true),
    );

    debugPrint('✅ Appended ${toAdd.length} addresses to $suburb');
    return toAdd.length;
  }

  /// Remove one address from a suburb by its position in the list.
  Future<void> deleteAddress(String suburb, int index) async {
    final addresses = await getAddresses(suburb);
    if (index < 0 || index >= addresses.length) return;

    addresses.removeAt(index);
    await _firestore.collection('home_choice').doc('suburbs').update({
      suburb: addresses.map((a) => a.toMap()).toList(),
    });
    debugPrint('✅ Deleted address $index from $suburb');
  }

  /// Remove every address that has no coordinates yet.
  Future<int> deleteUngeocoded(String suburb) async {
    final addresses = await getAddresses(suburb);
    final kept = addresses.where((a) => a.isGeocoded).toList();
    final removed = addresses.length - kept.length;
    if (removed == 0) return 0;

    await _firestore.collection('home_choice').doc('suburbs').update({
      suburb: kept.map((a) => a.toMap()).toList(),
    });
    return removed;
  }

  /// Drop addresses that repeat an earlier one. Returns how many went.
  Future<int> deduplicate(String suburb) async {
    final addresses = await getAddresses(suburb);
    final seen = <String>{};
    final kept = <Address>[];
    for (final a in addresses) {
      if (seen.add(a.dedupeKey)) kept.add(a);
    }
    final removed = addresses.length - kept.length;
    if (removed == 0) return 0;

    await _firestore.collection('home_choice').doc('suburbs').update({
      suburb: kept.map((a) => a.toMap()).toList(),
    });
    return removed;
  }

  // ── Depots ─────────────────────────────────────────────────────────────
  //
  // A depot is where a run starts and (optionally) ends. Stored apart from
  // the delivery lists so the same yard can anchor every suburb's route.

  /// All saved depots, newest name order.
  Future<List<Address>> getDepots() async {
    try {
      final doc = await _firestore.collection('home_choice').doc('depots').get();
      if (!doc.exists || doc.data() == null) return [];

      final data = doc.data()!;
      final depots = <Address>[];
      for (final entry in data.entries) {
        if (entry.key.startsWith('_')) continue;
        depots.add(Address.fromMap(
          entry.key,
          Map<String, dynamic>.from(entry.value as Map),
        ));
      }
      depots.sort((a, b) => a.displayName.compareTo(b.displayName));
      return depots;
    } catch (e) {
      debugPrint('Error getting depots: $e');
      return [];
    }
  }

  /// Save (or overwrite) a depot under [Address.id].
  Future<void> saveDepot(Address depot) async {
    await _firestore.collection('home_choice').doc('depots').set(
      {depot.id: depot.toMap()},
      SetOptions(merge: true),
    );
    debugPrint('✅ Saved depot ${depot.id}');
  }

  Future<void> deleteDepot(String depotId) async {
    await _firestore.collection('home_choice').doc('depots').update({
      depotId: FieldValue.delete(),
    });
  }

  /// Shape a parsed raw row into the Firestore address map.
  ///
  /// A row that already carries coordinates — an ERF-register match, whose
  /// position comes from the surveyed parcel — is imported as located.
  /// Everything else starts unlocated for the geocoder to resolve.
  Map<String, dynamic> Function(Map<String, String>) _rawToMap(String suburb) {
    return (raw) {
      final lat = double.tryParse(raw['latitude'] ?? '');
      final lng = double.tryParse(raw['longitude'] ?? '');
      final located = lat != null && lng != null;

      return {
        'streetAddress': raw['streetAddress'] ?? '',
        'suburb': (raw['suburb']?.isNotEmpty ?? false) ? raw['suburb']! : suburb,
        'city': raw['city'] ?? '',
        'postalCode': raw['postalCode'] ?? '',
        'province': raw['province'] ?? '',
        'country': raw['country'] ?? '',
        'notes': raw['notes'] ?? '',
        'latitude': lat,
        'longitude': lng,
        'isGeocoded': located,
        'geocodingError': null,
        'formattedAddress': raw['formattedAddress'],
        'locationType': located ? raw['locationType'] : null,
        'partialMatch': false,
        'placeId': raw['placeId'],
        'erfId': raw['erfId'],
        'erfNumber': raw['erfNumber'],
        'routeIndex': null,
      };
    };
  }

  // ── Client maps ────────────────────────────────────────────────────────
  //
  // Which shareable map a suburb's run was published to, so re-publishing
  // updates that map rather than littering the gallery with a new copy
  // every time someone clicks the button.

  static const String _clientMapDoc = 'suburb_client_maps';

  /// The published client map for [suburb], or null if never published.
  Future<({String docId, String monthKey})?> getClientMapRef(
      String suburb) async {
    try {
      final doc = await _firestore
          .collection('home_choice')
          .doc(_clientMapDoc)
          .get();
      if (!doc.exists || doc.data() == null) return null;

      final entry = doc.data()![suburb];
      if (entry is! Map) return null;

      final docId = entry['docId'] as String?;
      final monthKey = entry['monthKey'] as String?;
      if (docId == null || monthKey == null) return null;
      return (docId: docId, monthKey: monthKey);
    } catch (e) {
      debugPrint('Error reading client map ref for $suburb: $e');
      return null;
    }
  }

  Future<void> saveClientMapRef(
    String suburb, {
    required String docId,
    required String monthKey,
  }) async {
    await _firestore.collection('home_choice').doc(_clientMapDoc).set({
      suburb: {
        'docId': docId,
        'monthKey': monthKey,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
    }, SetOptions(merge: true));
  }

  Future<void> clearClientMapRef(String suburb) async {
    try {
      await _firestore.collection('home_choice').doc(_clientMapDoc).update({
        suburb: FieldValue.delete(),
      });
    } catch (e) {
      debugPrint('Error clearing client map ref for $suburb: $e');
    }
  }
}
