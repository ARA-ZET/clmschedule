import '../models/erf_property.dart';

/// Outcome of resolving one pasted line to a cadastral parcel.
enum ErfMatchStatus {
  /// Not looked up yet.
  pending,

  /// Exactly one parcel was found.
  matched,

  /// Several parcels share the ERF number — the user picks one.
  ambiguous,

  /// Nothing matched the address or ERF number.
  notFound,

  /// The lookup itself failed (network, geocoder quota, …).
  error,
}

/// One line of a pasted address / ERF list, after parsing.
///
/// [rawLine] is always kept so the review list can show the user exactly what
/// they pasted next to what was made of it.
class ErfListEntry {
  final int lineNumber;
  final String rawLine;

  /// Street address portion, when the line contained one.
  final String? address;

  /// ERF number as written (kept as a string so portions like "1234/2"
  /// survive), when the line contained one.
  final String? erfNumber;

  const ErfListEntry({
    required this.lineNumber,
    required this.rawLine,
    this.address,
    this.erfNumber,
  });

  bool get hasErfNumber => erfNumber != null && erfNumber!.isNotEmpty;
  bool get hasAddress => address != null && address!.isNotEmpty;

  /// Whether anything usable was found on the line.
  bool get isUsable => hasErfNumber || hasAddress;

  /// What the entry is looked up by, for display.
  String get parsedLabel {
    if (hasErfNumber && hasAddress) return '$address · ERF $erfNumber';
    if (hasErfNumber) return 'ERF $erfNumber';
    if (hasAddress) return address!;
    return rawLine;
  }
}

/// An [ErfListEntry] together with the parcel(s) it resolved to.
class ErfMatch {
  final ErfListEntry entry;
  final ErfMatchStatus status;

  /// The chosen parcel. Set when [status] is [ErfMatchStatus.matched], and
  /// also once the user picks from [candidates].
  final ErfProperty? property;

  /// Every parcel that matched, when more than one did.
  final List<ErfProperty> candidates;

  /// Why the lookup failed, when it did.
  final String? message;

  const ErfMatch({
    required this.entry,
    required this.status,
    this.property,
    this.candidates = const [],
    this.message,
  });

  ErfMatch.pending(this.entry)
      : status = ErfMatchStatus.pending,
        property = null,
        candidates = const [],
        message = null;

  ErfMatch copyWith({
    ErfMatchStatus? status,
    ErfProperty? property,
    List<ErfProperty>? candidates,
    String? message,
  }) {
    return ErfMatch(
      entry: entry,
      status: status ?? this.status,
      property: property ?? this.property,
      candidates: candidates ?? this.candidates,
      message: message ?? this.message,
    );
  }

  /// The parcel to put on the map, carrying the pasted address so the
  /// placemark is labelled the way the user wrote it.
  ErfProperty? get resolvedProperty {
    final p = property;
    if (p == null) return null;
    if (entry.hasAddress && (p.streetAddress == null || p.streetAddress!.isEmpty)) {
      return p.copyWith(streetAddress: entry.address);
    }
    return p;
  }
}
