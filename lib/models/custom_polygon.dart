import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Type of map element stored in Job.workMaps.
enum MapElementType {
  polygon,
  polyline,
  point,

  /// Legacy value – treated as [point] everywhere.
  marker,
}

/// Category of a point/marker element, determines its bitmap icon.
enum PointCategory {
  generic('generic', 'Point', Icons.place, Colors.red),
  dropoff('dropoff', 'Dropoff', Icons.arrow_downward, Colors.blue),
  pickup('pickup', 'Pickup', Icons.arrow_upward, Colors.green),
  loading('loading', 'Loading', Icons.local_shipping, Colors.orange),
  offloading('offloading', 'Offloading', Icons.inventory, Color(0xFFD32F2F)),
  cleaning('cleaning', 'Cleaning Side', Icons.cleaning_services, Colors.teal);

  const PointCategory(this.id, this.label, this.icon, this.color);
  final String id;
  final String label;
  final IconData icon;
  final Color color;

  static PointCategory fromId(String? id) {
    if (id == null) return PointCategory.generic;
    return PointCategory.values.firstWhere(
      (c) => c.id == id,
      orElse: () => PointCategory.generic,
    );
  }
}

/// Houses-versus-apartments split behind [CustomPolygon.letterBoxEstimate].
///
/// Computed once — when a polygon finishes drawing or editing, or when it is
/// imported from a work area or suburb — and stored with the polygon, so
/// showing it later (the info window, the estimates table) costs nothing.
///
/// Deliberately defined here rather than reusing the letterbox module's own
/// breakdown type: this model is used across the whole app, and it must not
/// take a dependency on that module. The provider translates between the two.
///
/// A null split on a polygon means *never computed*, which is not the same as
/// a computed result that happens to be all zeros.
class LetterBoxSplit {
  /// Letterboxes standing on their own — a house with its own box at the gate.
  final int houses;

  /// Letterboxes in a cluster: the bank of boxes at a block's entrance. A
  /// count of BOXES, not of blocks.
  final int apartmentBoxes;

  /// How many distinct blocks those boxes form.
  final int apartmentBlocks;

  const LetterBoxSplit({
    required this.houses,
    required this.apartmentBoxes,
    required this.apartmentBlocks,
  });

  static const empty =
      LetterBoxSplit(houses: 0, apartmentBoxes: 0, apartmentBlocks: 0);

  /// Total letterboxes across both kinds.
  int get total => houses + apartmentBoxes;

  /// True when there is nothing worth showing.
  bool get isEmpty => houses == 0 && apartmentBoxes == 0;

  factory LetterBoxSplit.fromMap(Map<String, dynamic> data) {
    return LetterBoxSplit(
      houses: (data['houses'] as num?)?.toInt() ?? 0,
      apartmentBoxes: (data['apartmentBoxes'] as num?)?.toInt() ?? 0,
      apartmentBlocks: (data['apartmentBlocks'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'houses': houses,
        'apartmentBoxes': apartmentBoxes,
        'apartmentBlocks': apartmentBlocks,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LetterBoxSplit &&
          other.houses == houses &&
          other.apartmentBoxes == apartmentBoxes &&
          other.apartmentBlocks == apartmentBlocks;

  @override
  int get hashCode => Object.hash(houses, apartmentBoxes, apartmentBlocks);

  @override
  String toString() => 'LetterBoxSplit(houses: $houses, '
      'apartmentBoxes: $apartmentBoxes, apartmentBlocks: $apartmentBlocks)';
}

class CustomPolygon {
  /// Stable domain identifier for data sets that need one, such as work suburbs.
  /// Regular shareable map polygons can leave this null.
  final String? id;

  final String name;
  final String description;
  final List<LatLng> points;
  final Color color;

  /// Fill opacity: 0.0 (transparent) … 1.0 (solid). Default 0.35.
  final double fillOpacity;

  /// Border stroke width in pixels. Default 2.
  final int strokeWidth;

  /// Whether the polyline is dashed. Only meaningful for [isPolyline].
  final bool isDashed;

  /// Type of map element. Default is polygon for backward compatibility.
  final MapElementType type;

  /// Category of the point (only meaningful when [isPoint] is true).
  final PointCategory pointCategory;

  /// Estimated number of letter boxes in this polygon/work area.
  final int letterBoxEstimate;

  /// Houses-versus-apartments split behind [letterBoxEstimate]. Null when it
  /// has never been computed for this polygon — polygons drawn before the
  /// split existed, or ones whose estimate was typed in by hand.
  final LetterBoxSplit? letterBoxSplit;

  /// The estimate this polygon arrived with, kept when a curated count later
  /// replaces [letterBoxEstimate].
  ///
  /// A polygon imported from another map's "Target Areas" layer carries the
  /// number the client was quoted on. The auto-count then overwrites
  /// [letterBoxEstimate] with what the letterbox index says for the same
  /// ground — which is the right number to work from, but the quoted one is
  /// what the client agreed to, and losing it makes the two impossible to
  /// reconcile. The first recount over a non-zero estimate stashes it here
  /// and nothing overwrites it afterwards.
  ///
  /// Null when the polygon was drawn here, or when no count has replaced its
  /// original number yet — in which case [letterBoxEstimate] IS that number.
  final int? importedLetterBoxEstimate;

  /// Letterbox-index suburbs that contributed to [letterBoxEstimate] when it
  /// was last counted. Stored as ids, not as a trusted/untrusted flag, so the
  /// editor can check each suburb's CURRENT curation status: the warning on
  /// an area clears the moment an admin verifies its suburb, without a
  /// recount. Null when the estimate did not come from the index (typed by
  /// hand) or was counted before this was recorded.
  final List<String>? letterboxSuburbIds;

  /// A person set [letterBoxEstimate] by hand and it must stay as typed: no
  /// recount (vertex edit, boundary stitch, cleanup, recheck) overwrites it,
  /// and it is no longer flagged as resting on unverified suburbs — someone
  /// has looked at it and taken responsibility for the number.
  final bool letterBoxLocked;

  /// Who locked it (an email), for the "set by" note. Null when unlocked.
  final String? letterBoxLockedBy;

  const CustomPolygon({
    this.id,
    required this.name,
    required this.description,
    required this.points,
    required this.color,
    this.fillOpacity = 0.35,
    this.strokeWidth = 2,
    this.isDashed = false,
    this.type = MapElementType.polygon,
    this.pointCategory = PointCategory.generic,
    this.letterBoxEstimate = 0,
    this.letterBoxSplit,
    this.importedLetterBoxEstimate,
    this.letterboxSuburbIds,
    this.letterBoxLocked = false,
    this.letterBoxLockedBy,
  });

  /// Whether this element is a single-point marker / point.
  bool get isMarker =>
      type == MapElementType.marker || type == MapElementType.point;

  /// Whether this element is a point (alias for isMarker).
  bool get isPoint => isMarker;

  /// Whether this element is a polygon area.
  bool get isPolygon => type == MapElementType.polygon;

  /// Whether this element is a polyline / path.
  bool get isPolyline => type == MapElementType.polyline;

  /// The marker position (first point). Only meaningful when [isPoint] is true.
  LatLng? get markerPosition => points.isNotEmpty ? points.first : null;

  // Create from Map (for Firestore)
  factory CustomPolygon.fromMap(Map<String, dynamic> data) {
    final points = (data['points'] as List<dynamic>?)
            ?.map((point) => LatLng(
                  (point['latitude'] as num).toDouble(),
                  (point['longitude'] as num).toDouble(),
                ))
            .toList() ??
        [];

    var type = _parseType(data['type'] as String?);
    // Legacy fix: single-point items stored without a type (or as 'polygon')
    // are actually point/marker elements — a 1-point polygon is invisible.
    if (type == MapElementType.polygon && points.length == 1) {
      type = MapElementType.point;
    }

    return CustomPolygon(
      id: data['id'] as String?,
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      points: points,
      color: Color((data['color'] as num?)?.toInt() ?? Colors.blue.toARGB32()),
      fillOpacity: (data['fillOpacity'] as num?)?.toDouble() ?? 0.35,
      strokeWidth: (data['strokeWidth'] as num?)?.toInt() ?? 2,
      isDashed: data['isDashed'] as bool? ?? false,
      type: type,
      pointCategory: PointCategory.fromId(data['pointCategory'] as String?),
      letterBoxEstimate: (data['letterBoxEstimate'] as num?)?.toInt() ?? 0,
      letterBoxSplit: data['letterBoxSplit'] is Map
          ? LetterBoxSplit.fromMap(
              Map<String, dynamic>.from(data['letterBoxSplit'] as Map))
          : null,
      importedLetterBoxEstimate:
          (data['importedLetterBoxEstimate'] as num?)?.toInt(),
      letterboxSuburbIds: data['letterboxSuburbIds'] is List
          ? List<String>.unmodifiable(
              (data['letterboxSuburbIds'] as List).map((e) => e.toString()))
          : null,
      letterBoxLocked: data['letterBoxLocked'] as bool? ?? false,
      letterBoxLockedBy: data['letterBoxLockedBy'] as String?,
    );
  }

  /// Parse the stored type string, with backward compatibility for 'marker'.
  static MapElementType _parseType(String? value) {
    switch (value) {
      case 'polyline':
        return MapElementType.polyline;
      case 'point':
      case 'marker': // legacy
        return MapElementType.point;
      case 'polygon':
      default:
        return MapElementType.polygon;
    }
  }

  // Convert to Map (for Firestore)
  Map<String, dynamic> toMap() {
    final map = {
      if (id != null && id!.isNotEmpty) 'id': id,
      'name': name,
      'description': description,
      'points': points
          .map((point) => {
                'latitude': point.latitude,
                'longitude': point.longitude,
              })
          .toList(),
      'color': color.toARGB32(),
      'fillOpacity': fillOpacity,
      'strokeWidth': strokeWidth,
      if (isDashed) 'isDashed': true,
      'type': _typeToString(type),
      if (isPoint && pointCategory != PointCategory.generic)
        'pointCategory': pointCategory.id,
      if (letterBoxEstimate > 0) 'letterBoxEstimate': letterBoxEstimate,
      if (letterBoxSplit != null) 'letterBoxSplit': letterBoxSplit!.toMap(),
      if (importedLetterBoxEstimate != null)
        'importedLetterBoxEstimate': importedLetterBoxEstimate,
      if (letterboxSuburbIds != null) 'letterboxSuburbIds': letterboxSuburbIds,
      if (letterBoxLocked) 'letterBoxLocked': true,
      if (letterBoxLocked && letterBoxLockedBy != null)
        'letterBoxLockedBy': letterBoxLockedBy,
    };
    return map;
  }

  static String _typeToString(MapElementType t) {
    switch (t) {
      case MapElementType.polygon:
        return 'polygon';
      case MapElementType.polyline:
        return 'polyline';
      case MapElementType.point:
      case MapElementType.marker:
        return 'point';
    }
  }

  // Create a copy with some fields updated
  CustomPolygon copyWith({
    String? id,
    String? name,
    String? description,
    List<LatLng>? points,
    Color? color,
    double? fillOpacity,
    int? strokeWidth,
    bool? isDashed,
    MapElementType? type,
    PointCategory? pointCategory,
    int? letterBoxEstimate,
    LetterBoxSplit? letterBoxSplit,
    /// Drop the stored split rather than carrying it forward — for when the
    /// total is being overridden by hand, which leaves any previously
    /// computed breakdown describing a different number.
    bool clearLetterBoxSplit = false,
    int? importedLetterBoxEstimate,

    /// Forget the number this polygon was imported with — for when the
    /// polygon is no longer the imported one it was.
    bool clearImportedLetterBoxEstimate = false,

    /// Also cleared by [clearLetterBoxSplit]: a hand-typed total has no
    /// index provenance.
    List<String>? letterboxSuburbIds,
    bool? letterBoxLocked,
    String? letterBoxLockedBy,
  }) {
    final locked = letterBoxLocked ?? this.letterBoxLocked;
    return CustomPolygon(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      points: points != null
          ? List<LatLng>.from(points)
          : List<LatLng>.from(this.points),
      color: color ?? this.color,
      fillOpacity: fillOpacity ?? this.fillOpacity,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      isDashed: isDashed ?? this.isDashed,
      type: type ?? this.type,
      pointCategory: pointCategory ?? this.pointCategory,
      letterBoxEstimate: letterBoxEstimate ?? this.letterBoxEstimate,
      letterBoxSplit: clearLetterBoxSplit
          ? null
          : (letterBoxSplit ?? this.letterBoxSplit),
      importedLetterBoxEstimate: clearImportedLetterBoxEstimate
          ? null
          : (importedLetterBoxEstimate ?? this.importedLetterBoxEstimate),
      letterboxSuburbIds: clearLetterBoxSplit
          ? null
          : (letterboxSuburbIds ?? this.letterboxSuburbIds),
      letterBoxLocked: locked,
      letterBoxLockedBy:
          locked ? (letterBoxLockedBy ?? this.letterBoxLockedBy) : null,
    );
  }

  // Convert to Google Maps Polygon widget (only for polygon type)
  Polygon toGoogleMapsPolygon({
    required String polygonId,
    bool isSelected = false,
    bool isEditing = false,
    VoidCallback? onTap,
  }) {
    Color strokeColor = color;
    Color fillColor = color.withValues(alpha: fillOpacity);
    int sw = strokeWidth;

    if (isEditing) {
      strokeColor = Colors.red;
      fillColor = Colors.red.withValues(alpha: 0.1);
      sw = 5;
    } else if (isSelected) {
      // Emphasise relative to the polygon's own width so the style panel's
      // border slider still shows a change while the polygon is selected.
      sw = strokeWidth + 3;
    }

    return Polygon(
      polygonId: PolygonId(polygonId),
      points: points,
      fillColor: fillColor,
      strokeColor: strokeColor,
      strokeWidth: sw,
      consumeTapEvents: onTap != null,
      onTap: onTap,
    );
  }

  /// Convert to a Google Maps Marker widget (only for marker type).
  /// Returns null if this is not a marker or has no points.
  Marker? toGoogleMapsMarker({
    required String markerId,
    bool isSelected = false,
    VoidCallback? onTap,
    bool draggable = false,
    ValueChanged<LatLng>? onDragEnd,
    BitmapDescriptor? customIcon,
    bool useAdvancedMarker = false,
    bool visible = true,
  }) {
    if (!isMarker && !isPoint || points.isEmpty) return null;

    final fallbackColor =
        pointCategory != PointCategory.generic ? pointCategory.color : color;
    final icon = customIcon ??
        (useAdvancedMarker
            ? BitmapDescriptor.pinConfig(
                backgroundColor: fallbackColor,
                borderColor: Colors.white,
                glyph: const CircleGlyph(color: Colors.white),
              )
            : BitmapDescriptor.defaultMarkerWithHue(_colorToMarkerHue(
                pointCategory != PointCategory.generic
                    ? pointCategory.color
                    : color)));

    if (useAdvancedMarker) {
      return AdvancedMarker(
        markerId: MarkerId(markerId),
        position: points.first,
        icon: icon,
        alpha: isSelected ? 1.0 : 0.85,
        visible: visible,
        infoWindow: InfoWindow(
          title: name.isNotEmpty ? name : pointCategory.label,
          snippet: description.isNotEmpty ? description : null,
        ),
        onTap: onTap,
        draggable: draggable,
        onDragEnd: onDragEnd,
      );
    }

    return Marker(
      markerId: MarkerId(markerId),
      position: points.first,
      icon: icon,
      alpha: isSelected ? 1.0 : 0.85,
      visible: visible,
      infoWindow: InfoWindow(
        title: name.isNotEmpty ? name : pointCategory.label,
        snippet: description.isNotEmpty ? description : null,
      ),
      onTap: onTap,
      draggable: draggable,
      onDragEnd: onDragEnd,
    );
  }

  /// Map a Color to the nearest BitmapDescriptor marker hue.
  static double _colorToMarkerHue(Color c) {
    final r = c.r, g = c.g, b = c.b;
    // Red-ish
    if (r > 0.7 && g < 0.4 && b < 0.4) return BitmapDescriptor.hueRed;
    // Orange-ish
    if (r > 0.7 && g > 0.3 && g < 0.7 && b < 0.3) {
      return BitmapDescriptor.hueOrange;
    }
    // Yellow-ish
    if (r > 0.7 && g > 0.7 && b < 0.4) return BitmapDescriptor.hueYellow;
    // Green-ish
    if (g > 0.5 && r < 0.5 && b < 0.5) return BitmapDescriptor.hueGreen;
    // Cyan-ish
    if (g > 0.5 && b > 0.5 && r < 0.4) return BitmapDescriptor.hueCyan;
    // Azure / Blue-ish
    if (b > 0.5 && r < 0.4 && g < 0.5) return BitmapDescriptor.hueAzure;
    // Violet / Purple
    if (r > 0.4 && b > 0.5 && g < 0.4) return BitmapDescriptor.hueViolet;
    // Magenta / Rose
    if (r > 0.7 && b > 0.5 && g < 0.4) return BitmapDescriptor.hueRose;
    // Default blue
    return BitmapDescriptor.hueBlue;
  }

  @override
  String toString() {
    return 'CustomPolygon(name: $name, type: ${type.name}, description: $description, '
        'pointsCount: ${points.length}, color: $color)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomPolygon &&
        other.id == id &&
        other.name == name &&
        other.description == description &&
        _samePoints(other.points, points) &&
        other.color == color &&
        other.fillOpacity == fillOpacity &&
        other.strokeWidth == strokeWidth &&
        other.isDashed == isDashed &&
        other.type == type &&
        other.pointCategory == pointCategory &&
        other.letterBoxEstimate == letterBoxEstimate &&
        other.letterBoxSplit == letterBoxSplit &&
        other.importedLetterBoxEstimate == importedLetterBoxEstimate &&
        listEquals(other.letterboxSuburbIds, letterboxSuburbIds) &&
        other.letterBoxLocked == letterBoxLocked &&
        other.letterBoxLockedBy == letterBoxLockedBy;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      name,
      description,
      Object.hashAll(points.map((p) => Object.hash(p.latitude, p.longitude))),
      color,
      fillOpacity,
      strokeWidth,
      isDashed,
      type,
      pointCategory,
      letterBoxEstimate,
      letterBoxSplit,
      importedLetterBoxEstimate,
      letterboxSuburbIds == null ? null : Object.hashAll(letterboxSuburbIds!),
      letterBoxLocked,
      letterBoxLockedBy,
    );
  }

  static bool _samePoints(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].latitude != b[i].latitude || a[i].longitude != b[i].longitude) {
        return false;
      }
    }
    return true;
  }
}
