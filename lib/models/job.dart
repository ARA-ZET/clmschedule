import 'package:cloud_firestore/cloud_firestore.dart';
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

  Job({
    required this.id,
    required this.clients,
    required this.workingAreas,
    required this.workMaps,
    required this.distributorId,
    required this.date,
    required this.statusId,
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
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    final map = {
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
    };

    return map;
  }

  // Create a copy of job with some fields updated
  Job copyWith({
    List<String>? clients,
    List<String>? workingAreas,
    List<CustomPolygon>? workMaps,
    String? distributorId,
    DateTime? date,
    String? statusId,
  }) {
    return Job(
      id: id,
      clients: clients ?? this.clients,
      workingAreas: workingAreas ?? this.workingAreas,
      workMaps: workMaps ?? this.workMaps,
      distributorId: distributorId ?? this.distributorId,
      date: date ?? this.date,
      statusId: statusId ?? this.statusId,
    );
  }

  // Note: Status color is now handled by JobStatusProvider

  @override
  String toString() {
    return 'Job(id: $id, clients: $clients, workingAreas: $workingAreas, '
        'workMapsCount: ${workMaps.length}, '
        'distributorId: $distributorId, date: $date, statusId: $statusId)';
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
