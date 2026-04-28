import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'custom_polygon.dart';

// Keep enum for backwards compatibility during migration
enum JobStatus { standby, scheduled, done, urgent }

class Job {
  final String id;
  final List<String> clients;
  final List<String> workingAreas; // Names of the work areas for display
  final List<CustomPolygon>
      workMaps; // Custom polygons with name, description, points, color
  final String distributorId;
  final DateTime date;
  final String statusId; // Changed from JobStatus enum to String
  final LatLng? dropOffPoint;

  Job({
    required this.id,
    required this.clients,
    required this.workingAreas,
    required this.workMaps,
    required this.distributorId,
    required this.date,
    required this.statusId,
    this.dropOffPoint,
  });

  // Create from Firestore
  factory Job.fromMap(String id, Map<String, dynamic> data) {
    // Handle migration from old enum-based status to new string-based statusId
    String statusId;
    if (data['statusId'] != null) {
      statusId = data['statusId'] as String;
    } else if (data['status'] != null) {
      // Migration: convert old enum status to statusId
      statusId = data['status'] as String;
    } else {
      statusId = 'scheduled'; // Default fallback
    }

    LatLng? dropOffPoint;
    final dropMap = data['dropOffPoint'];
    if (dropMap is Map<String, dynamic>) {
      final lat = (dropMap['latitude'] as num?)?.toDouble();
      final lng = (dropMap['longitude'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        dropOffPoint = LatLng(lat, lng);
      }
    } else {
      // Backward compatibility if old flat fields are present
      final lat = (data['dropOffLat'] as num?)?.toDouble();
      final lng = (data['dropOffLng'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        dropOffPoint = LatLng(lat, lng);
      }
    }

    return Job(
      id: id,
      clients: (data['clients'] as List<dynamic>?)?.cast<String>() ??
          (data['client'] != null
              ? [data['client'] as String]
              : ['']), // Backwards compatibility
      workingAreas: (data['workingAreas'] as List<dynamic>?)?.cast<String>() ??
          (data['workingArea'] != null
              ? [data['workingArea'] as String]
              : ['']), // Backwards compatibility
      workMaps: (data['workMaps'] as List<dynamic>?)
              ?.map((mapData) =>
                  CustomPolygon.fromMap(mapData as Map<String, dynamic>))
              .toList() ??
          [],
      distributorId: data['distributorId'] as String? ?? '',
      date: data['date'] != null
          ? (data['date'] as Timestamp).toDate()
          : DateTime.now(),
      statusId: statusId,
      dropOffPoint: dropOffPoint,
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    final map = {
      'id': id, // Include ID for array storage
      'clients': clients,
      'workingAreas': workingAreas,
      'workMaps': workMaps.map((workMap) => workMap.toMap()).toList(),
      'distributorId': distributorId,
      'date': Timestamp.fromDate(date),
      'statusId': statusId,
      // Keep backwards compatibility
      'status': statusId, // Also store as status for backwards compatibility
      'client': clients.isNotEmpty ? clients.first : '',
      'workingArea': workingAreas.isNotEmpty ? workingAreas.first : '',
      if (dropOffPoint != null)
        'dropOffPoint': {
          'latitude': dropOffPoint!.latitude,
          'longitude': dropOffPoint!.longitude,
        },
    };

    return map;
  }

  // Factory method for creating from array element
  factory Job.fromArrayElement(Map<String, dynamic> data) {
    final id = data['id'] as String;
    return Job.fromMap(id, data);
  }

  // Create a copy of job with some fields updated
  // Deep copies lists to prevent mutation issues
  Job copyWith({
    List<String>? clients,
    List<String>? workingAreas,
    List<CustomPolygon>? workMaps,
    String? distributorId,
    DateTime? date,
    String? statusId,
    LatLng? dropOffPoint,
  }) {
    return Job(
      id: id,
      clients: clients != null
          ? List<String>.from(clients)
          : List<String>.from(this.clients),
      workingAreas: workingAreas != null
          ? List<String>.from(workingAreas)
          : List<String>.from(this.workingAreas),
      workMaps: workMaps != null
          ? workMaps
              .map((wm) => CustomPolygon(
                    name: wm.name,
                    description: wm.description,
                    points: List.from(wm.points),
                    color: wm.color,
                    fillOpacity: wm.fillOpacity,
                    strokeWidth: wm.strokeWidth,
                    isDashed: wm.isDashed,
                    type: wm.type,
                    pointCategory: wm.pointCategory,
                  ))
              .toList()
          : this
              .workMaps
              .map((wm) => CustomPolygon(
                    name: wm.name,
                    description: wm.description,
                    points: List.from(wm.points),
                    color: wm.color,
                    fillOpacity: wm.fillOpacity,
                    strokeWidth: wm.strokeWidth,
                    isDashed: wm.isDashed,
                    type: wm.type,
                    pointCategory: wm.pointCategory,
                  ))
              .toList(),
      distributorId: distributorId ?? this.distributorId,
      date: date ?? this.date,
      statusId: statusId ?? this.statusId,
      dropOffPoint: dropOffPoint ?? this.dropOffPoint,
    );
  }

  /// Estimates a default drop-off point from job work maps.
  ///
  /// Priority:
  /// 1) Existing dropoff point element in work maps
  /// 2) Centroid (simple average) of first polygon-type work map
  /// 3) First point of first non-empty work map
  static LatLng? estimateDropOffPointFromWorkMaps(List<CustomPolygon> maps) {
    for (final map in maps) {
      if (map.isPoint &&
          map.pointCategory == PointCategory.dropoff &&
          map.points.isNotEmpty) {
        return map.points.first;
      }
    }

    for (final map in maps) {
      if (map.isPolygon && map.points.isNotEmpty) {
        return _centroid(map.points);
      }
    }

    for (final map in maps) {
      if (map.points.isNotEmpty) return map.points.first;
    }

    return null;
  }

  /// Returns true when [point] is inside at least one polygon work map.
  static bool isPointInsideAnyWorkArea(
      LatLng point, List<CustomPolygon> workMaps) {
    final polygons = workMaps.where((w) => w.isPolygon && w.points.length >= 3);
    for (final polygon in polygons) {
      if (_isPointInPolygon(point, polygon.points)) return true;
    }
    return false;
  }

  static LatLng _centroid(List<LatLng> points) {
    double lat = 0;
    double lng = 0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  static bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    bool inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;

      final intersects = ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude <
              (xj - xi) * (point.latitude - yi) / ((yj - yi) + 1e-12) + xi);
      if (intersects) inside = !inside;
    }
    return inside;
  }

  // Note: Status color is now handled by JobStatusProvider

  @override
  String toString() {
    return 'Job(id: $id, clients: $clients, workingAreas: $workingAreas, '
        'workMapsCount: ${workMaps.length}, '
        'distributorId: $distributorId, date: $date, statusId: $statusId, '
        'dropOffPoint: $dropOffPoint)';
  }

  // Helper methods for backwards compatibility and ease of use
  String get primaryClient => clients.isNotEmpty ? clients.first : '';
  String get primaryWorkingArea =>
      workingAreas.isNotEmpty ? workingAreas.first : '';

  // Helper method to get display text for clients
  String get clientsDisplay => clients.join(', ');

  // Helper method to get display text for working areas
  String get workingAreasDisplay => workingAreas.join(', ');
}
