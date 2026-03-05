/// Address model for geocoding
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

  // Route optimization data
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

  /// Create from Firestore map
  factory Address.fromMap(String id, Map<String, dynamic> data) {
    return Address(
      id: id,
      streetAddress: data['streetAddress'] ?? '',
      suburb: data['suburb'] ?? '',
      city: data['city'] ?? '',
      postalCode: data['postalCode'] ?? '',
      province: data['province'] ?? '',
      country: data['country'] ?? '',
      latitude: data['latitude']?.toDouble(),
      longitude: data['longitude']?.toDouble(),
      isGeocoded: data['isGeocoded'] ?? false,
      geocodingError: data['geocodingError'],
      routeIndex: data['routeIndex'],
    );
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
      'routeIndex': routeIndex,
    };
  }

  /// Create copy with updated fields
  Address copyWith({
    double? latitude,
    double? longitude,
    bool? isGeocoded,
    String? geocodingError,
    int? routeIndex,
  }) {
    return Address(
      id: id,
      streetAddress: streetAddress,
      suburb: suburb,
      city: city,
      postalCode: postalCode,
      province: province,
      country: country,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      isGeocoded: isGeocoded ?? this.isGeocoded,
      geocodingError: geocodingError,
      routeIndex: routeIndex ?? this.routeIndex,
    );
  }
}
