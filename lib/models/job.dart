import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'work_area.dart';

enum JobStatus { standby, scheduled, done, urgent }

class Job {
  final String id;
  final String client;
  final String workAreaId; // Reference to the original work area
  final String workingArea; // Name of the work area for display
  final WorkArea? customWorkArea; // Optional custom work area if edited
  final String distributorId;
  final DateTime date;
  final JobStatus status;

  Job({
    required this.id,
    required this.client,
    required this.workAreaId,
    required this.workingArea,
    this.customWorkArea,
    required this.distributorId,
    required this.date,
    required this.status,
  });

  // Create from Firestore
  factory Job.fromMap(String id, Map<String, dynamic> data) {
    return Job(
      id: id,
      client: data['client'] as String? ?? '',
      workAreaId: data['workAreaId'] as String? ?? '',
      workingArea: data['workingArea'] as String? ?? '',
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
      'client': client,
      'workAreaId': workAreaId,
      'workingArea': workingArea,
      'distributorId': distributorId,
      'date': Timestamp.fromDate(date),
      'status': status.toString().split('.').last,
    };

    if (customWorkArea != null) {
      map['customWorkArea'] = customWorkArea!.toMap();
    }

    return map;
  }

  // Create a copy of job with some fields updated
  Job copyWith({
    String? client,
    String? workAreaId,
    String? workingArea,
    WorkArea? customWorkArea,
    String? distributorId,
    DateTime? date,
    JobStatus? status,
  }) {
    return Job(
      id: id,
      client: client ?? this.client,
      workAreaId: workAreaId ?? this.workAreaId,
      workingArea: workingArea ?? this.workingArea,
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
    return 'Job(id: $id, client: $client, workAreaId: $workAreaId, '
        'hasCustomArea: ${customWorkArea != null}, '
        'distributorId: $distributorId, date: $date, status: $status)';
  }
}
