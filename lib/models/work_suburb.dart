import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A suburb polygon stored inside a single Firestore document at
/// `workSuburbs/main` as an array entry.
class WorkSuburb {
  static const Color defaultColor = Color(0xFF2E7D32);

  final String id;
  final String name;
  final String description;
  final List<LatLng> polygonPoints;
  final int letterBoxEstimate;
  final Color color;

  WorkSuburb({
    required this.id,
    required this.name,
    required this.description,
    required this.polygonPoints,
    this.letterBoxEstimate = 0,
    this.color = defaultColor,
  });

  /// Deserialise from a map entry inside the `suburbs` array of the
  /// single Firestore document.
  factory WorkSuburb.fromMap(Map<String, dynamic> data) {
    final List<dynamic> points = data['polygonPoints'] ?? [];
    return WorkSuburb(
      id: data['id'] as String? ?? '',
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      letterBoxEstimate: (data['letterBoxEstimate'] as num?)?.toInt() ?? 0,
      color: Color((data['color'] as num?)?.toInt() ?? defaultColor.toARGB32()),
      polygonPoints: points.map((point) {
        if (point is GeoPoint) {
          return LatLng(point.latitude, point.longitude);
        } else if (point is Map) {
          final lat = point['latitude'] ?? point['lat'];
          final lng = point['longitude'] ?? point['lng'];
          return LatLng(
            (lat as num).toDouble(),
            (lng as num).toDouble(),
          );
        }
        throw ArgumentError('Invalid point format: $point');
      }).toList(),
    );
  }

  /// Serialise to a map entry for the `suburbs` array.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'letterBoxEstimate': letterBoxEstimate,
      'color': color.toARGB32(),
      'polygonPoints':
          polygonPoints.map((p) => GeoPoint(p.latitude, p.longitude)).toList(),
    };
  }

  WorkSuburb copyWith({
    String? id,
    String? name,
    String? description,
    List<LatLng>? polygonPoints,
    int? letterBoxEstimate,
    Color? color,
  }) {
    return WorkSuburb(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      polygonPoints: polygonPoints ?? this.polygonPoints,
      letterBoxEstimate: letterBoxEstimate ?? this.letterBoxEstimate,
      color: color ?? this.color,
    );
  }
}
