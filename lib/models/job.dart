import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'work_area.dart';

enum JobStatus { standby, scheduled, done, urgent }

class Job {
  final String id;
  final List<String> clients;
  final String workAreaId; // Reference to the original work area
  final List<String> workingAreas; // Names of the work areas for display
  final WorkArea? customWorkArea; // Optional custom work area if edited
  final String distributorId;
  final DateTime date;
  final JobStatus status;

  Job({
    required this.id,
    required this.clients,
    required this.workAreaId,
    required this.workingAreas,
    this.customWorkArea,
    required this.distributorId,
    required this.date,
    required this.status,
  });

  // Create from Firestore
  factory Job.fromMap(String id, Map<String, dynamic> data) {
    return Job(
      id: id,
      clients: (data['clients'] as List<dynamic>?)?.cast<String>() ??
          (data['client'] != null
              ? [data['client'] as String]
              : ['']), // Backwards compatibility
      workAreaId: data['workAreaId'] as String? ?? '',
      workingAreas: (data['workingAreas'] as List<dynamic>?)?.cast<String>() ??
          (data['workingArea'] != null
              ? [data['workingArea'] as String]
              : ['']), // Backwards compatibility
      customWorkArea: data['customWorkArea'] != null
          ? WorkArea.fromMap(data['customWorkArea'] as Map<String, dynamic>)
          : null,
      distributorId: data['distributorId'] as String? ?? '',
      date: data['date'] != null
          ? (data['date'] as Timestamp).toDate()
          : DateTime.now(),
      status: JobStatus.values.firstWhere(
        (e) => e.toString() == 'JobStatus.${data['status']}',
        orElse: () => JobStatus.scheduled,
      ),
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    final map = {
      'clients': clients,
      'workAreaId': workAreaId,
      'workingAreas': workingAreas,
      'distributorId': distributorId,
      'date': Timestamp.fromDate(date),
      'status': status.toString().split('.').last,
      // Keep backwards compatibility
      'client': clients.isNotEmpty ? clients.first : '',
      'workingArea': workingAreas.isNotEmpty ? workingAreas.first : '',
    };

    if (customWorkArea != null) {
      map['customWorkArea'] = customWorkArea!.toMap();
    }

    return map;
  }

  // Create a copy of job with some fields updated
  Job copyWith({
    List<String>? clients,
    String? workAreaId,
    List<String>? workingAreas,
    WorkArea? customWorkArea,
    String? distributorId,
    DateTime? date,
    JobStatus? status,
  }) {
    return Job(
      id: id,
      clients: clients ?? this.clients,
      workAreaId: workAreaId ?? this.workAreaId,
      workingAreas: workingAreas ?? this.workingAreas,
      customWorkArea: customWorkArea ?? this.customWorkArea,
      distributorId: distributorId ?? this.distributorId,
      date: date ?? this.date,
      status: status ?? this.status,
    );
  }

  // Get card color based on status
  Color getStatusColor() {
    switch (status) {
      case JobStatus.standby:
        return Colors.grey;
      case JobStatus.scheduled:
        return Colors.orange;
      case JobStatus.done:
        return Colors.green;
      case JobStatus.urgent:
        return Colors.red;
    }
  }

  @override
  String toString() {
    return 'Job(id: $id, clients: $clients, workAreaId: $workAreaId, '
        'hasCustomArea: ${customWorkArea != null}, '
        'distributorId: $distributorId, date: $date, status: $status)';
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
