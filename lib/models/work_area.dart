import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class WorkArea {
  final String id;
  final String name;
  final String description;
  final List<LatLng> polygonPoints;
  final String kmlFileName;
  final DateTime createdAt;
  final DateTime updatedAt;

  WorkArea({
    required this.id,
    required this.name,
    required this.description,
    required this.polygonPoints,
    required this.kmlFileName,
    required this.createdAt,
    required this.updatedAt,
  });

  // Create from Firestore document
  factory WorkArea.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final List<dynamic> points = data['polygonPoints'] ?? [];

    return WorkArea(
      id: doc.id,
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      kmlFileName: data['kmlFileName'] ?? '',
      polygonPoints: points.map((point) {
        final GeoPoint geoPoint = point as GeoPoint;
        return LatLng(geoPoint.latitude, geoPoint.longitude);
      }).toList(),
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
    );
  }

  // Convert to Firestore document
  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'description': description,
      'kmlFileName': kmlFileName,
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
      polygonPoints: points.map((point) {
        if (point is GeoPoint) {
          return LatLng(point.latitude, point.longitude);
        } else if (point is Map<String, dynamic>) {
          return LatLng(
            point['latitude'] as double,
            point['longitude'] as double,
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
    );
  }

  // Convert to map (used in Job model)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'kmlFileName': kmlFileName,
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
    };
  }

  // Create a polygon for Google Maps
  Polygon toMapPolygon({Color? color}) {
    return Polygon(
      polygonId: PolygonId(id),
      points: polygonPoints,
      fillColor:
          color?.withOpacity(0.3) ?? const Color(0xFFFF0000).withOpacity(0.3),
      strokeColor: color ?? const Color(0xFFFF0000),
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
  }) {
    return WorkArea(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      polygonPoints: polygonPoints ?? this.polygonPoints,
      kmlFileName: kmlFileName ?? this.kmlFileName,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
