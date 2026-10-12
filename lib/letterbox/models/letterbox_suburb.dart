import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Curation state of one suburb's letterbox set.
///
/// Only [verified] suburbs are trusted downstream: an unverified count is a
/// machine guess seeded from GPS drops, and must never be used to quote a
/// client or to score a distributor's performance.
enum LetterboxSuburbStatus {
  /// No seed has been run for this suburb yet.
  unseeded,

  /// Candidates generated from GPS drops; nobody has looked at them.
  seeded,

  /// Someone has started correcting the candidates but not signed off.
  inProgress,

  /// Curated and signed off. This is the only status the business trusts.
  verified;

  static LetterboxSuburbStatus fromId(String? id) {
    return LetterboxSuburbStatus.values.firstWhere(
      (s) => s.name == id,
      orElse: () => LetterboxSuburbStatus.unseeded,
    );
  }
}

/// Axis-aligned bounds, stored on the metadata document so a polygon query can
/// decide which suburb payloads it needs without downloading any of them.
class LetterboxBounds {
  final double minLat;
  final double minLng;
  final double maxLat;
  final double maxLng;

  const LetterboxBounds({
    required this.minLat,
    required this.minLng,
    required this.maxLat,
    required this.maxLng,
  });

  /// Bounds covering [points]. Returns null for an empty list.
  static LetterboxBounds? fromPoints(List<LatLng> points) {
    if (points.isEmpty) return null;
    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LetterboxBounds(
      minLat: minLat,
      minLng: minLng,
      maxLat: maxLat,
      maxLng: maxLng,
    );
  }

  /// True when this box and [other] share any area. Used to shortlist suburbs
  /// for a polygon query — a cheap reject before any file is fetched.
  bool intersects(LetterboxBounds other) {
    return minLat <= other.maxLat &&
        maxLat >= other.minLat &&
        minLng <= other.maxLng &&
        maxLng >= other.minLng;
  }

  Map<String, dynamic> toMap() => {
        'minLat': minLat,
        'minLng': minLng,
        'maxLat': maxLat,
        'maxLng': maxLng,
      };

  static LetterboxBounds? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final minLat = (map['minLat'] as num?)?.toDouble();
    final minLng = (map['minLng'] as num?)?.toDouble();
    final maxLat = (map['maxLat'] as num?)?.toDouble();
    final maxLng = (map['maxLng'] as num?)?.toDouble();
    if (minLat == null || minLng == null || maxLat == null || maxLng == null) {
      return null;
    }
    return LetterboxBounds(
      minLat: minLat,
      minLng: minLng,
      maxLat: maxLat,
      maxLng: maxLng,
    );
  }
}

/// Metadata for one suburb's letterbox set.
///
/// Firestore path: `letterboxSuburbs/{suburbId}`. Deliberately small — the
/// positions themselves live in one gzipped Storage object per suburb (see
/// `LetterboxCodec`), so the whole collection can be streamed to drive the
/// overview choropleth in a single query.
class LetterboxSuburb {
  final String suburbId;
  final String suburbName;

  /// Curated letterbox count. This is the number every downstream feature
  /// reads — quoting, work-area tiers, distributor review.
  final int count;

  final LetterboxSuburbStatus status;

  /// How many candidates the GPS seed produced, kept so curation progress
  /// ("started from 1 450, kept 1 380") stays visible after editing.
  final int seededCount;

  /// Set when new GPS drops have arrived for a suburb that is already
  /// [LetterboxSuburbStatus.verified]. The refresh job never edits a verified
  /// suburb silently — it raises this flag and waits for a human.
  final bool hasNewCandidates;

  final DateTime? verifiedAt;
  final String? verifiedBy;
  final String? storagePath;
  final int storageBytes;
  final LetterboxBounds? bounds;
  final int formatVersion;
  final DateTime? updatedAt;

  const LetterboxSuburb({
    required this.suburbId,
    required this.suburbName,
    this.count = 0,
    this.status = LetterboxSuburbStatus.unseeded,
    this.seededCount = 0,
    this.hasNewCandidates = false,
    this.verifiedAt,
    this.verifiedBy,
    this.storagePath,
    this.storageBytes = 0,
    this.bounds,
    this.formatVersion = 0,
    this.updatedAt,
  });

  /// True when the count may be used to quote or to score a distributor.
  bool get isTrusted => status == LetterboxSuburbStatus.verified;

  /// True when a payload file has been written for this suburb.
  bool get hasPayload => (storagePath ?? '').isNotEmpty;

  factory LetterboxSuburb.fromMap(String id, Map<String, dynamic> map) {
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    return LetterboxSuburb(
      suburbId: id,
      suburbName: map['suburbName'] as String? ?? '',
      count: (map['count'] as num?)?.toInt() ?? 0,
      status: LetterboxSuburbStatus.fromId(map['status'] as String?),
      seededCount: (map['seededCount'] as num?)?.toInt() ?? 0,
      hasNewCandidates: map['hasNewCandidates'] as bool? ?? false,
      verifiedAt: ts(map['verifiedAt']),
      verifiedBy: map['verifiedBy'] as String?,
      storagePath: map['storagePath'] as String?,
      storageBytes: (map['storageBytes'] as num?)?.toInt() ?? 0,
      bounds: LetterboxBounds.fromMap(
          (map['bounds'] as Map?)?.cast<String, dynamic>()),
      formatVersion: (map['formatVersion'] as num?)?.toInt() ?? 0,
      updatedAt: ts(map['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() => {
        'suburbName': suburbName,
        'count': count,
        'status': status.name,
        'seededCount': seededCount,
        'hasNewCandidates': hasNewCandidates,
        if (verifiedAt != null) 'verifiedAt': Timestamp.fromDate(verifiedAt!),
        if (verifiedBy != null) 'verifiedBy': verifiedBy,
        if (storagePath != null) 'storagePath': storagePath,
        'storageBytes': storageBytes,
        if (bounds != null) 'bounds': bounds!.toMap(),
        'formatVersion': formatVersion,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  LetterboxSuburb copyWith({
    String? suburbName,
    int? count,
    LetterboxSuburbStatus? status,
    int? seededCount,
    bool? hasNewCandidates,
    DateTime? verifiedAt,
    String? verifiedBy,
    String? storagePath,
    int? storageBytes,
    LetterboxBounds? bounds,
    int? formatVersion,
    DateTime? updatedAt,
  }) {
    return LetterboxSuburb(
      suburbId: suburbId,
      suburbName: suburbName ?? this.suburbName,
      count: count ?? this.count,
      status: status ?? this.status,
      seededCount: seededCount ?? this.seededCount,
      hasNewCandidates: hasNewCandidates ?? this.hasNewCandidates,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      verifiedBy: verifiedBy ?? this.verifiedBy,
      storagePath: storagePath ?? this.storagePath,
      storageBytes: storageBytes ?? this.storageBytes,
      bounds: bounds ?? this.bounds,
      formatVersion: formatVersion ?? this.formatVersion,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
