import 'geocode_detail.dart';

/// Sentinel for [Address.copyWith] so a caller can tell "leave this field
/// alone" apart from "set this field to null". Without it, clearing a
/// geocoding error and preserving one are the same call.
const Object _unset = Object();

/// A single delivery address: the raw text, its geocoded position, and the
/// place it holds in an optimised route.
class Address {
  final String id;
  final String streetAddress;
  final String suburb;
  final String city;
  final String postalCode;
  final String province;
  final String country;

  // Geocoded data
  final double? latitude;
  final double? longitude;
  final bool isGeocoded;
  final String? geocodingError;

  /// Google's canonical formatting of the match, kept so a low-confidence
  /// pin can be compared against what was actually asked for.
  final String? formattedAddress;

  /// Raw Google `location_type` for the match.
  final String? locationType;

  /// Google flagged the lookup as a partial match.
  final bool partialMatch;

  final String? placeId;

  /// Free-text note carried through to the driver sheet and KML export.
  final String? notes;

  /// LPI code of the cadastral parcel this stop sits on, when the address
  /// was resolved through the ERF register rather than the geocoder.
  ///
  /// The polygon itself is not held here — a delivery list of 80 parcels
  /// would be tens of thousands of points, far past what belongs in an
  /// address array. This is the join key to the parcel store.
  final String? erfId;

  /// ERF number as the register writes it (TAG_VALUE), e.g. `4673` or
  /// `RE/4673`.
  final String? erfNumber;

  /// Route optimization data
  final int? routeIndex;

  Address({
    required this.id,
    required this.streetAddress,
    required this.suburb,
    required this.city,
    required this.postalCode,
    required this.province,
    required this.country,
    this.latitude,
    this.longitude,
    this.isGeocoded = false,
    this.geocodingError,
    this.formattedAddress,
    this.locationType,
    this.partialMatch = false,
    this.placeId,
    this.notes,
    this.erfId,
    this.erfNumber,
    this.routeIndex,
  });

  /// Get full formatted address string
  String get fullAddress {
    final parts = <String>[];
    if (streetAddress.isNotEmpty) parts.add(streetAddress);
    if (suburb.isNotEmpty) parts.add(suburb);
    if (city.isNotEmpty) parts.add(city);
    if (postalCode.isNotEmpty) parts.add(postalCode);
    if (province.isNotEmpty) parts.add(province);
    if (country.isNotEmpty) parts.add(country);
    return parts.join(', ');
  }

  /// Short label for lists, markers and exports.
  String get displayName {
    if (streetAddress.isNotEmpty) return streetAddress;
    if (erfNumber != null && erfNumber!.isNotEmpty) return 'ERF $erfNumber';
    return suburb.isNotEmpty ? suburb : id;
  }

  /// True when this stop came from the cadastral register and has a parcel
  /// boundary to draw.
  bool get hasParcel => erfId != null && erfId!.isNotEmpty;

  /// How much this pin can be trusted. [GeocodePrecision.unknown] for
  /// addresses geocoded before precision was recorded.
  GeocodePrecision get precision => isGeocoded
      ? GeocodePrecision.fromLocationType(locationType,
          partialMatch: partialMatch)
      : GeocodePrecision.unknown;

  /// Key used to spot the same physical address pasted twice.
  String get dedupeKey => [
        streetAddress.trim().toLowerCase(),
        suburb.trim().toLowerCase(),
        city.trim().toLowerCase(),
      ].join('|');

  /// Create from Firestore map.
  ///
  /// Every field is read defensively. Records here were written by
  /// several generations of import code, so coordinates turn up as
  /// numbers *and* as strings, and text fields occasionally hold a
  /// number — a hard cast on any of them would throw and take the whole
  /// address list down with it.
  factory Address.fromMap(String id, Map<String, dynamic> data) {
    return Address(
      id: id,
      streetAddress: _asText(data['streetAddress']),
      suburb: _asText(data['suburb']),
      city: _asText(data['city']),
      postalCode: _asText(data['postalCode']),
      province: _asText(data['province']),
      country: _asText(data['country']),
      latitude: _asDouble(data['latitude']),
      longitude: _asDouble(data['longitude']),
      isGeocoded: data['isGeocoded'] == true,
      geocodingError: _asTextOrNull(data['geocodingError']),
      formattedAddress: _asTextOrNull(data['formattedAddress']),
      locationType: _asTextOrNull(data['locationType']),
      partialMatch: data['partialMatch'] == true,
      placeId: _asTextOrNull(data['placeId']),
      notes: _asTextOrNull(data['notes']),
      erfId: _asTextOrNull(data['erfId']),
      erfNumber: _asTextOrNull(data['erfNumber']),
      routeIndex: _asInt(data['routeIndex']),
    );
  }

  static String _asText(dynamic value) =>
      value == null ? '' : value.toString();

  static String? _asTextOrNull(dynamic value) {
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  static double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// Convert to Firestore map
  Map<String, dynamic> toMap() {
    return {
      'streetAddress': streetAddress,
      'suburb': suburb,
      'city': city,
      'postalCode': postalCode,
      'province': province,
      'country': country,
      'latitude': latitude,
      'longitude': longitude,
      'isGeocoded': isGeocoded,
      'geocodingError': geocodingError,
      'formattedAddress': formattedAddress,
      'locationType': locationType,
      'partialMatch': partialMatch,
      'placeId': placeId,
      'notes': notes,
      'erfId': erfId,
      'erfNumber': erfNumber,
      'routeIndex': routeIndex,
    };
  }

  /// Create copy with updated fields. Omitted fields are preserved; pass
  /// an explicit `null` to clear a nullable one.
  Address copyWith({
    String? streetAddress,
    String? suburb,
    String? city,
    String? postalCode,
    String? province,
    String? country,
    Object? latitude = _unset,
    Object? longitude = _unset,
    bool? isGeocoded,
    Object? geocodingError = _unset,
    Object? formattedAddress = _unset,
    Object? locationType = _unset,
    bool? partialMatch,
    Object? placeId = _unset,
    Object? notes = _unset,
    Object? erfId = _unset,
    Object? erfNumber = _unset,
    Object? routeIndex = _unset,
  }) {
    return Address(
      id: id,
      streetAddress: streetAddress ?? this.streetAddress,
      suburb: suburb ?? this.suburb,
      city: city ?? this.city,
      postalCode: postalCode ?? this.postalCode,
      province: province ?? this.province,
      country: country ?? this.country,
      latitude:
          identical(latitude, _unset) ? this.latitude : latitude as double?,
      longitude:
          identical(longitude, _unset) ? this.longitude : longitude as double?,
      isGeocoded: isGeocoded ?? this.isGeocoded,
      geocodingError: identical(geocodingError, _unset)
          ? this.geocodingError
          : geocodingError as String?,
      formattedAddress: identical(formattedAddress, _unset)
          ? this.formattedAddress
          : formattedAddress as String?,
      locationType: identical(locationType, _unset)
          ? this.locationType
          : locationType as String?,
      partialMatch: partialMatch ?? this.partialMatch,
      placeId: identical(placeId, _unset) ? this.placeId : placeId as String?,
      notes: identical(notes, _unset) ? this.notes : notes as String?,
      erfId: identical(erfId, _unset) ? this.erfId : erfId as String?,
      erfNumber:
          identical(erfNumber, _unset) ? this.erfNumber : erfNumber as String?,
      routeIndex:
          identical(routeIndex, _unset) ? this.routeIndex : routeIndex as int?,
    );
  }

  /// Apply a successful geocode, clearing any previous error.
  Address withGeocode(GeocodeDetail detail) => copyWith(
        latitude: detail.latitude,
        longitude: detail.longitude,
        isGeocoded: true,
        geocodingError: null,
        formattedAddress: detail.formattedAddress,
        locationType: detail.locationType,
        partialMatch: detail.partialMatch,
        placeId: detail.placeId,
      );

  /// Record a failed geocode attempt.
  Address withGeocodeFailure(String error) => copyWith(
        isGeocoded: false,
        geocodingError: error,
      );
}
