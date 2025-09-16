import 'package:cloud_firestore/cloud_firestore.dart';

enum JobStatus {
  scheduled,
  inProgress,
  completed,
}

class Job {
  final String id;
  final String client;
  final String workingArea;
  final String mapLink;
  final String distributorId;
  final DateTime date;
  final DateTime startTime;
  final DateTime endTime;
  final JobStatus status;

  Job({
    required this.id,
    required this.client,
    required this.workingArea,
    required this.mapLink,
    required this.distributorId,
    required this.date,
    required this.startTime,
    required this.endTime,
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
      startTime: (data['startTime'] as Timestamp).toDate(),
      endTime: (data['endTime'] as Timestamp).toDate(),
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
      'startTime': Timestamp.fromDate(startTime),
      'endTime': Timestamp.fromDate(endTime),
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
    DateTime? startTime,
    DateTime? endTime,
    JobStatus? status,
  }) {
    return Job(
      id: id,
      client: client ?? this.client,
      workingArea: workingArea ?? this.workingArea,
      mapLink: mapLink ?? this.mapLink,
      distributorId: distributorId ?? this.distributorId,
      date: date ?? this.date,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      status: status ?? this.status,
    );
  }

  @override
  String toString() {
    return 'Job(id: $id, client: $client, workingArea: $workingArea, '
        'distributorId: $distributorId, date: $date, status: $status)';
  }
}