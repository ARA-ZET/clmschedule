import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'custom_polygon.dart';

/// One area in the Client Maps library.
///
/// The same shape as a [WorkArea] — a named polygon with a letterbox number —
/// but for the other side of the business: a work area is ground a distributor
/// is sent to, a client area is ground a client is quoted for. They are kept as
/// separate collections rather than one with a flag because they are edited by
/// different people at different times, and a rename or redraw on one must
/// never move the other.
///
/// What a client area carries that a work area does not:
///
///  * **[letterBoxSplit]** — the houses-versus-apartments breakdown behind the
///    total. Two areas with the same 1 200 are very different jobs if one is
///    mostly blocks, and that is the difference a quote turns on.
///  * **[client]** — who the area is for.
///  * **[surveyedAt]** — when the letterbox index under this polygon was last
///    replaced from a walked round. An estimate counted off a curated index is
///    worth more the more recently that index was surveyed, and without this
///    there is no way to tell a fresh number from a two-year-old one.
///
/// Firestore path: `clientAreas/{id}`.
class ClientArea {
  static const Color defaultColor = Color(0xFF1565C0);

  final String id;
  final String name;

  /// Who this area is for. Free text — it comes from whatever the round's
  /// polygon was labelled with, which is a client name, not an id.
  final String client;

  final String description;
  final List<LatLng> polygonPoints;
  final Color color;

  /// Letterboxes inside this polygon, counted from the curated index.
  final int letterBoxEstimate;

  /// The houses-versus-apartments split behind [letterBoxEstimate]. Null when
  /// it has never been computed — which is not the same as a computed split
  /// that happens to be all zeros.
  final LetterBoxSplit? letterBoxSplit;

  /// The estimate this area's polygon arrived with, when a curated count has
  /// since replaced [letterBoxEstimate].
  ///
  /// Areas pulled in from another map's "Target Areas" layer carry the number
  /// the client was quoted on. The count from the letterbox index is the
  /// better number to plan and bill against, but the quoted one is what was
  /// agreed — a quote that silently changes its own figure is worse than one
  /// that shows both. See [CustomPolygon.importedLetterBoxEstimate].
  final int? importedLetterBoxEstimate;

  /// The track-editor polygon this area was created from, when it came from a
  /// letterbox-index update — a fast path for finding the area a re-survey
  /// should refresh.
  ///
  /// A hint, NOT a stable identity: a track-editor polygon's id is derived
  /// from its name and geometry for schedule work maps, and from a timestamp
  /// for one drawn by hand, so nudging a vertex or drawing the area again in a
  /// later session produces a different id for the same ground. The name is
  /// what actually carries identity across a re-survey — see
  /// [ClientAreaService.findForSurvey].
  final String? sourcePolygonId;

  /// When the letterbox index inside this polygon was last replaced from a
  /// walked round. Null for an area drawn by hand in the editor.
  final DateTime? surveyedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  ClientArea({
    required this.id,
    required this.name,
    this.client = '',
    this.description = '',
    required this.polygonPoints,
    this.color = defaultColor,
    this.letterBoxEstimate = 0,
    this.letterBoxSplit,
    this.importedLetterBoxEstimate,
    this.sourcePolygonId,
    this.surveyedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// True when the estimate was counted from a survey rather than typed in.
  bool get isSurveyed => surveyedAt != null;

  factory ClientArea.fromMap(Map<String, dynamic> data) {
    final List<dynamic> points = data['polygonPoints'] ?? const [];
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;

    return ClientArea(
      id: data['id'] as String? ?? '',
      name: data['name'] as String? ?? '',
      client: data['client'] as String? ?? '',
      description: data['description'] as String? ?? '',
      polygonPoints: points
          .map(_pointFrom)
          .whereType<LatLng>()
          .toList(growable: false),
      color: Color((data['color'] as num?)?.toInt() ?? defaultColor.toARGB32()),
      letterBoxEstimate: (data['letterBoxEstimate'] as num?)?.toInt() ?? 0,
      letterBoxSplit: data['letterBoxSplit'] is Map
          ? LetterBoxSplit.fromMap(
              Map<String, dynamic>.from(data['letterBoxSplit'] as Map))
          : null,
      importedLetterBoxEstimate:
          (data['importedLetterBoxEstimate'] as num?)?.toInt(),
      sourcePolygonId: data['sourcePolygonId'] as String?,
      surveyedAt: ts(data['surveyedAt']),
      createdAt: ts(data['createdAt']) ?? DateTime.now(),
      updatedAt: ts(data['updatedAt']) ?? DateTime.now(),
    );
  }

  factory ClientArea.fromFirestore(DocumentSnapshot doc) {
    final data = Map<String, dynamic>.from(doc.data() as Map);
    data['id'] = doc.id;
    return ClientArea.fromMap(data);
  }

  /// Accepts both storage shapes: [GeoPoint], which is what this collection
  /// writes, and a `{latitude, longitude}` map, which is what the shareable
  /// map layers use — so a polygon copied between the two still parses.
  static LatLng? _pointFrom(dynamic point) {
    if (point is GeoPoint) return LatLng(point.latitude, point.longitude);
    if (point is Map) {
      final lat = point['latitude'] ?? point['lat'];
      final lng = point['longitude'] ?? point['lng'];
      if (lat is num && lng is num) {
        return LatLng(lat.toDouble(), lng.toDouble());
      }
    }
    return null;
  }

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'client': client,
        'description': description,
        'color': color.toARGB32(),
        'letterBoxEstimate': letterBoxEstimate,
        if (letterBoxSplit != null) 'letterBoxSplit': letterBoxSplit!.toMap(),
        if (importedLetterBoxEstimate != null)
          'importedLetterBoxEstimate': importedLetterBoxEstimate,
        if (sourcePolygonId != null && sourcePolygonId!.isNotEmpty)
          'sourcePolygonId': sourcePolygonId,
        if (surveyedAt != null) 'surveyedAt': Timestamp.fromDate(surveyedAt!),
        'polygonPoints': polygonPoints
            .map((p) => GeoPoint(p.latitude, p.longitude))
            .toList(),
        'createdAt': Timestamp.fromDate(createdAt),
        'updatedAt': Timestamp.fromDate(updatedAt),
      };

  /// Same fields as [toFirestore] plus the document id, for embedding this
  /// area inside another document.
  Map<String, dynamic> toMap() => {'id': id, ...toFirestore()};

  /// This area as a map-editor polygon. The split rides along, so the info
  /// window shows houses and apartments without a fetch.
  CustomPolygon toCustomPolygon() => CustomPolygon(
        id: id,
        name: name,
        description: description,
        points: List<LatLng>.from(polygonPoints),
        color: color,
        letterBoxEstimate: letterBoxEstimate,
        letterBoxSplit: letterBoxSplit,
        importedLetterBoxEstimate: importedLetterBoxEstimate,
      );

  ClientArea copyWith({
    String? id,
    String? name,
    String? client,
    String? description,
    List<LatLng>? polygonPoints,
    Color? color,
    int? letterBoxEstimate,
    LetterBoxSplit? letterBoxSplit,
    int? importedLetterBoxEstimate,
    String? sourcePolygonId,
    DateTime? surveyedAt,
    DateTime? updatedAt,
  }) {
    return ClientArea(
      id: id ?? this.id,
      name: name ?? this.name,
      client: client ?? this.client,
      description: description ?? this.description,
      polygonPoints: polygonPoints ?? this.polygonPoints,
      color: color ?? this.color,
      letterBoxEstimate: letterBoxEstimate ?? this.letterBoxEstimate,
      letterBoxSplit: letterBoxSplit ?? this.letterBoxSplit,
      importedLetterBoxEstimate:
          importedLetterBoxEstimate ?? this.importedLetterBoxEstimate,
      sourcePolygonId: sourcePolygonId ?? this.sourcePolygonId,
      surveyedAt: surveyedAt ?? this.surveyedAt,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  @override
  String toString() => 'ClientArea($name, client: $client, '
      '${polygonPoints.length} pts, $letterBoxEstimate letterboxes)';
}
