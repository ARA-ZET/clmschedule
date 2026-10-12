/// Result of a single geocode lookup, richer than a bare lat/lng.
///
/// The extra fields exist so a run can be reviewed before it is driven:
/// Google will happily return a suburb centroid for a street number it
/// cannot find, and that pin looks identical to a real one on a map. The
/// precision and partial-match flags are what separate "this is the
/// building" from "this is roughly the neighbourhood".
class GeocodeDetail {
  final double latitude;
  final double longitude;

  /// Google's canonical formatting of what it actually matched.
  final String formattedAddress;

  /// Raw Google `location_type`: ROOFTOP, RANGE_INTERPOLATED,
  /// GEOMETRIC_CENTER or APPROXIMATE.
  final String locationType;

  /// Google flagged the query as only partially matched (usually a
  /// misspelling or a street number outside the known range).
  final bool partialMatch;

  final String placeId;

  /// Comma-separated Google place types for the match.
  final String types;

  const GeocodeDetail({
    required this.latitude,
    required this.longitude,
    this.formattedAddress = '',
    this.locationType = '',
    this.partialMatch = false,
    this.placeId = '',
    this.types = '',
  });

  /// Confidence bucket derived from [locationType] and [partialMatch].
  GeocodePrecision get precision => GeocodePrecision.fromLocationType(
        locationType,
        partialMatch: partialMatch,
      );

  Map<String, double> get latLng => {'lat': latitude, 'lng': longitude};
}

/// How much a geocoded pin can be trusted to be the actual delivery door.
enum GeocodePrecision {
  /// Someone dropped this pin by hand on the map. Trusted above anything
  /// Google returns, because a person looked at it.
  manual,

  /// Google returned a rooftop match — the building itself.
  exact,

  /// Interpolated between two known street numbers; normally within a
  /// house or two.
  interpolated,

  /// Centre of a street or block — good enough to navigate to, not to
  /// deliver blind.
  approximate,

  /// Suburb/city centroid or a partial match. Needs a human look.
  low,

  /// Not geocoded yet, or precision was never recorded.
  unknown;

  String get label => switch (this) {
        GeocodePrecision.manual => 'Placed by hand',
        GeocodePrecision.exact => 'Rooftop',
        GeocodePrecision.interpolated => 'Interpolated',
        GeocodePrecision.approximate => 'Street level',
        GeocodePrecision.low => 'Approximate',
        GeocodePrecision.unknown => 'Unknown',
      };

  /// True when the pin should be reviewed before the run goes out.
  bool get needsReview =>
      this == GeocodePrecision.low || this == GeocodePrecision.unknown;

  /// Marker written into `locationType` when a pin is positioned by hand.
  static const String manualLocationType = 'MANUAL';

  static GeocodePrecision fromLocationType(String? locationType,
      {bool partialMatch = false}) {
    if (locationType == manualLocationType) return GeocodePrecision.manual;
    if (partialMatch) return GeocodePrecision.low;
    switch (locationType) {
      case 'ROOFTOP':
        return GeocodePrecision.exact;
      case 'RANGE_INTERPOLATED':
        return GeocodePrecision.interpolated;
      case 'GEOMETRIC_CENTER':
        return GeocodePrecision.approximate;
      case 'APPROXIMATE':
        return GeocodePrecision.low;
      default:
        return GeocodePrecision.unknown;
    }
  }
}
