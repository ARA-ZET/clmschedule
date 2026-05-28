import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class WorkArea {
  static const Color defaultColor = Color(0xFFC62828);

  final String id;
  final String name;
  final String description;
  final List<LatLng> polygonPoints;
  final String kmlFileName;
  final int letterBoxEstimate;
  final Color color;
  final DateTime createdAt;
  final DateTime updatedAt;

  WorkArea({
    required this.id,
    required this.name,
    required this.description,
    required this.polygonPoints,
    required this.kmlFileName,
    this.letterBoxEstimate = 0,
    this.color = defaultColor,
    required this.createdAt,
    required this.updatedAt,
  });

  // Create from Firestore document
  factory WorkArea.fromFirestore(DocumentSnapshot doc) {
    final data = Map<String, dynamic>.from(doc.data() as Map);
    final List<dynamic> points = data['polygonPoints'] ?? [];

    return WorkArea(
      id: doc.id,
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      kmlFileName: data['kmlFileName'] ?? '',
      letterBoxEstimate: (data['letterBoxEstimate'] as num?)?.toInt() ?? 0,
      polygonPoints: points.map((point) {
        final GeoPoint geoPoint = point as GeoPoint;
        return LatLng(geoPoint.latitude, geoPoint.longitude);
      }).toList(),
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      color: Color((data['color'] as num?)?.toInt() ?? defaultColor.toARGB32()),
    );
  }

  // Convert to Firestore document
  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'description': description,
      'kmlFileName': kmlFileName,
      'letterBoxEstimate': letterBoxEstimate,
      'color': color.toARGB32(),
      'polygonPoints': polygonPoints.map((point) {
        return GeoPoint(point.latitude, point.longitude);
      }).toList(),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  // Convert from map (used in Job model)
  factory WorkArea.fromMap(Map<String, dynamic> data) {
    final List<dynamic> points = data['polygonPoints'] ?? [];

    return WorkArea(
      id: data['id'] ?? '',
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      kmlFileName: data['kmlFileName'] ?? '',
      letterBoxEstimate: (data['letterBoxEstimate'] as num?)?.toInt() ?? 0,
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
        throw ArgumentError('Invalid point format');
      }).toList(),
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : DateTime.now(),
      color: Color((data['color'] as num?)?.toInt() ?? defaultColor.toARGB32()),
    );
  }

  // Convert to map (used in Job model)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'kmlFileName': kmlFileName,
      'letterBoxEstimate': letterBoxEstimate,
      'polygonPoints': polygonPoints
          .map(
            (point) => {
              'latitude': point.latitude,
              'longitude': point.longitude,
            },
          )
          .toList(),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'color': color.toARGB32(),
    };
  }

  // Create a polygon for Google Maps
  Polygon toMapPolygon({Color? color}) {
    final polygonColor = color ?? this.color;
    return Polygon(
      polygonId: PolygonId(id),
      points: polygonPoints,
      fillColor: polygonColor.withValues(alpha: 0.3),
      strokeColor: polygonColor,
      strokeWidth: 2,
    );
  }

  // Create a copy with updated fields
  WorkArea copyWith({
    String? id,
    String? name,
    String? description,
    List<LatLng>? polygonPoints,
    String? kmlFileName,
    int? letterBoxEstimate,
    Color? color,
  }) {
    return WorkArea(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      polygonPoints: polygonPoints ?? this.polygonPoints,
      kmlFileName: kmlFileName ?? this.kmlFileName,
      letterBoxEstimate: letterBoxEstimate ?? this.letterBoxEstimate,
      color: color ?? this.color,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
