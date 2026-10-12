import '../erf_property/models/erf_list_entry.dart';
import '../erf_property/models/erf_property.dart';
import '../models/address.dart';
import '../models/geocode_detail.dart';

/// Result of turning a resolved ERF list into routable stops.
class ErfRouteImport {
  /// One raw address map per stop, in the order the list was pasted.
  ///
  /// Shaped for [AddressServiceV2.appendSuburbAddresses] so the ERF path
  /// reuses the ordinary import and persistence machinery rather than a
  /// parallel one.
  final List<Map<String, String>> rawAddresses;

  /// The parcels behind those stops, keyed by [ErfProperty.id].
  final Map<String, ErfProperty> parcels;

  /// Lines that resolved to a parcel.
  final int matchedCount;

  /// Lines that resolved to more than one parcel and still need a choice.
  final int ambiguousCount;

  /// Lines nothing was found for. They are still imported — as ordinary
  /// addresses to be geocoded — so nothing is silently dropped.
  final int unmatchedCount;

  const ErfRouteImport({
    required this.rawAddresses,
    required this.parcels,
    required this.matchedCount,
    required this.ambiguousCount,
    required this.unmatchedCount,
  });

  int get total => rawAddresses.length;
  bool get isEmpty => rawAddresses.isEmpty;
}

/// Converts cadastral parcels into delivery stops.
///
/// A parcel is a far better delivery target than a geocoded street address:
/// the register knows exactly where the property boundary is, so the pin
/// lands on the actual erf rather than on a street-level interpolation. This
/// takes the output of an ERF list lookup and produces stops that are
/// already located — no geocoding pass needed for anything that matched.
class ErfRouteBridge {
  /// Marker written into `locationType` for a stop positioned from the
  /// cadastral register. It reads as [GeocodePrecision.exact] because a
  /// surveyed parcel centroid is at least as trustworthy as a rooftop
  /// geocode.
  static const String cadastralLocationType = 'ROOFTOP';

  /// Build importable stops from resolved ERF matches.
  ///
  /// [defaultSuburb] fills the suburb column for lines the register did not
  /// name one for. Entries that failed to match still come through, without
  /// coordinates, so the ordinary geocoder can have a go at them.
  static ErfRouteImport fromMatches(
    List<ErfMatch> matches, {
    required String defaultSuburb,
    String defaultCity = 'CAPE TOWN',
    String defaultProvince = 'Western Cape',
    String defaultCountry = 'South Africa',
  }) {
    final rawAddresses = <Map<String, String>>[];
    final parcels = <String, ErfProperty>{};
    var matched = 0;
    var ambiguous = 0;
    var unmatched = 0;

    for (final match in matches) {
      final parcel = match.resolvedProperty;
      final entry = match.entry;

      if (parcel == null) {
        if (match.status == ErfMatchStatus.ambiguous) {
          ambiguous++;
        } else {
          unmatched++;
        }
        // Keep the line. An unresolved ERF is still a delivery someone has
        // to make, and dropping it here would hide it entirely.
        if (entry.isUsable) {
          rawAddresses.add({
            'streetAddress': entry.address ?? '',
            'suburb': defaultSuburb,
            'city': defaultCity,
            'postalCode': '',
            'province': defaultProvince,
            'country': defaultCountry,
            'notes': entry.hasErfNumber
                ? 'ERF ${entry.erfNumber} — not found in the register'
                : '',
            'erfNumber': entry.erfNumber ?? '',
          });
        }
        continue;
      }

      matched++;
      parcels[parcel.id] = parcel;

      rawAddresses.add({
        'streetAddress': parcel.streetAddress?.isNotEmpty == true
            ? parcel.streetAddress!
            : (entry.address ?? 'ERF ${parcel.tagValue}'),
        'suburb': parcel.suburb?.isNotEmpty == true
            ? parcel.suburb!
            : (parcel.minRegion.isNotEmpty ? parcel.minRegion : defaultSuburb),
        'city': defaultCity,
        'postalCode': '',
        'province':
            parcel.province.isNotEmpty ? parcel.province : defaultProvince,
        'country': defaultCountry,
        'notes': '',
        'erfId': parcel.id,
        'erfNumber':
            parcel.tagValue.isNotEmpty ? parcel.tagValue : '${parcel.erfNumber}',
        'latitude': '${parcel.centroid.latitude}',
        'longitude': '${parcel.centroid.longitude}',
        'isGeocoded': 'true',
        'locationType': cadastralLocationType,
        'formattedAddress': parcel.displayLabel,
      });
    }

    return ErfRouteImport(
      rawAddresses: rawAddresses,
      parcels: parcels,
      matchedCount: matched,
      ambiguousCount: ambiguous,
      unmatchedCount: unmatched,
    );
  }

  /// Build a standalone [Address] from a parcel, for callers that are not
  /// going through the import path.
  static Address addressFromParcel(
    ErfProperty parcel, {
    required String id,
    String defaultCity = 'CAPE TOWN',
    String defaultCountry = 'South Africa',
  }) {
    return Address(
      id: id,
      streetAddress: parcel.streetAddress?.isNotEmpty == true
          ? parcel.streetAddress!
          : 'ERF ${parcel.tagValue}',
      suburb: parcel.suburb ?? parcel.minRegion,
      city: defaultCity,
      postalCode: '',
      province: parcel.province,
      country: defaultCountry,
      latitude: parcel.centroid.latitude,
      longitude: parcel.centroid.longitude,
      isGeocoded: true,
      locationType: cadastralLocationType,
      formattedAddress: parcel.displayLabel,
      erfId: parcel.id,
      erfNumber:
          parcel.tagValue.isNotEmpty ? parcel.tagValue : '${parcel.erfNumber}',
    );
  }
}
