import 'package:flutter/foundation.dart';

import '../erf_property/models/csg_region.dart';
import '../erf_property/models/erf_property.dart';
import '../erf_property/providers/erf_property_provider.dart';
import 'address_service_v2.dart';
import 'erf_parcel_store.dart';
import 'erf_route_bridge.dart';

/// What an ERF import did, for the message shown afterwards.
class ErfImportOutcome {
  final String suburb;
  final int added;
  final int matched;
  final int ambiguous;
  final int unmatched;

  /// Every parcel now held for the suburb, including ones already there.
  final Map<String, ErfProperty> parcels;

  /// False when the boundaries were too large to persist and live only for
  /// the current session.
  final bool parcelsStored;

  const ErfImportOutcome({
    required this.suburb,
    required this.added,
    required this.matched,
    required this.ambiguous,
    required this.unmatched,
    required this.parcels,
    required this.parcelsStored,
  });

  bool get isEmpty => added == 0 && matched == 0;

  /// One-line summary for a snack bar.
  String get summary => [
        '$added added',
        '$matched matched to a parcel',
        if (ambiguous > 0) '$ambiguous ambiguous',
        if (unmatched > 0) '$unmatched need geocoding',
      ].join(' · ');
}

/// Runs the "paste a list, get parcels" pipeline.
///
/// Extracted so the suburb list and the suburb workspace share one
/// implementation — the landing screen needs it just as much as the
/// workspace does, since that is where someone with no list yet starts.
class ErfImportService {
  final AddressServiceV2 addressService;
  final ErfParcelStore parcelStore;

  const ErfImportService({
    required this.addressService,
    required this.parcelStore,
  });

  /// Resolve [text] against the cadastral register and import the result
  /// into [suburb].
  ///
  /// [existingParcels] are merged with whatever this run finds, so a second
  /// paste adds to the list rather than replacing its boundaries.
  Future<ErfImportOutcome> importList({
    required ErfPropertyProvider erfProvider,
    required String text,
    required String suburb,
    CsgRegion? region,
    String? label,
    String defaultCity = 'CAPE TOWN',
    Map<String, ErfProperty> existingParcels = const {},
  }) async {
    final matches = await erfProvider.resolveList(
      text,
      region: region,
      label: label,
    );

    final imported = ErfRouteBridge.fromMatches(
      matches,
      defaultSuburb: suburb,
      defaultCity: defaultCity,
    );

    if (imported.isEmpty) {
      return ErfImportOutcome(
        suburb: suburb,
        added: 0,
        matched: 0,
        ambiguous: imported.ambiguousCount,
        unmatched: imported.unmatchedCount,
        parcels: existingParcels,
        parcelsStored: true,
      );
    }

    final added = await addressService.appendSuburbAddresses(
      suburb,
      imported.rawAddresses,
    );

    final merged = {...existingParcels, ...imported.parcels};
    final stored = merged.isEmpty
        ? true
        : await parcelStore.saveParcels(suburb, merged.values);

    debugPrint('ERF import into $suburb: $added added, '
        '${imported.matchedCount} matched, parcels stored=$stored');

    return ErfImportOutcome(
      suburb: suburb,
      added: added,
      matched: imported.matchedCount,
      ambiguous: imported.ambiguousCount,
      unmatched: imported.unmatchedCount,
      parcels: merged,
      parcelsStored: stored,
    );
  }

  /// Turn a free-text run name into a suburb key.
  ///
  /// Suburb keys are Firestore map field names and are matched exactly, so
  /// they are lower-cased and stripped of anything that would make two
  /// spellings of the same name fail to line up.
  static String suburbKeyFrom(String label, {String fallback = 'erf list'}) {
    final cleaned = label
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? fallback : cleaned;
  }
}
