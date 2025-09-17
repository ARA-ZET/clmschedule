import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum JobStatus { standby, scheduled, done, urgent }

class Job {
  final String id;
  final String client;
  final String workingArea;
  final String mapLink;
  final String distributorId;
  final DateTime date;
  final JobStatus status;

  Job({
    required this.id,
    required this.client,
    required this.workingArea,
    required this.mapLink,
    required this.distributorId,
    required this.date,
    required this.status,
  });

  // Create from Firestore
  factory Job.fromMap(String id, Map<String, dynamic> data) {
    return Job(
      id: id,
      client: data['client'] as String,
      workingArea: data['workingArea'] as String,
      mapLink: data['mapLink'] as String,
      distributorId: data['distributorId'] as String,
      date: (data['date'] as Timestamp).toDate(),
      status: JobStatus.values.firstWhere(
        (e) => e.toString() == 'JobStatus.${data['status']}',
        orElse: () => JobStatus.scheduled,
      ),
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'client': client,
      'workingArea': workingArea,
      'mapLink': mapLink,
      'distributorId': distributorId,
      'date': Timestamp.fromDate(date),

      'status': status.toString().split('.').last,
    };
  }

  // Create a copy of job with some fields updated
  Job copyWith({
    String? client,
    String? workingArea,
    String? mapLink,
    String? distributorId,
    DateTime? date,

    JobStatus? status,
  }) {
    return Job(
      id: id,
      client: client ?? this.client,
      workingArea: workingArea ?? this.workingArea,
      mapLink: mapLink ?? this.mapLink,
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
    return 'Job(id: $id, client: $client, workingArea: $workingArea, '
        'distributorId: $distributorId, date: $date, status: $status)';
  }
}
