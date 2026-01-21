import 'package:cloud_firestore/cloud_firestore.dart';

class WindowCleaningJob {
  final String id;
  final String location;
  final String client;
  final DateTime date;
  final String timeSlot; // Time in HH:MM format (08:00-16:00)
  final int
      timeSlots; // Number of 30-minute slots this job occupies (1 or more)
  final List<String> assignedStaff; // Staff names/IDs
  final int staffCount; // Number of staff needed
  final String statusId;
  final String notes;
  final String jobListItemId; // Link to the original job list item
  final double amount; // Job amount/price

  WindowCleaningJob({
    required this.id,
    required this.location,
    required this.client,
    required this.date,
    required this.timeSlot,
    int? timeSlots,
    required this.assignedStaff,
    required this.staffCount,
    required this.statusId,
    this.notes = '',
    this.jobListItemId = '',
    this.amount = 0.0,
  }) : timeSlots = (timeSlots != null && timeSlots >= 1) ? timeSlots : 1;

  // Create from Firestore
  factory WindowCleaningJob.fromMap(String id, Map<String, dynamic> data) {
    return WindowCleaningJob(
      id: id,
      location: data['location'] as String? ?? '',
      client: data['client'] as String? ?? '',
      date: data['date'] != null
          ? (data['date'] as Timestamp).toDate()
          : DateTime.now(),
      timeSlot: data['timeSlot'] is int
          ? '${(data['timeSlot'] as int).toString().padLeft(2, '0')}:00'
          : data['timeSlot'] as String? ?? '08:00',
      timeSlots: data['timeSlots'] as int?,
      assignedStaff:
          (data['assignedStaff'] as List<dynamic>?)?.cast<String>() ?? [],
      staffCount: data['staffCount'] as int? ?? 2,
      statusId: data['statusId'] as String? ?? 'scheduled',
      notes: data['notes'] as String? ?? '',
      jobListItemId: data['jobListItemId'] as String? ?? '',
      amount: (data['amount'] as num?)?.toDouble() ?? 0.0,
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'location': location,
      'client': client,
      'date': Timestamp.fromDate(date),
      'timeSlot': timeSlot,
      'timeSlots': timeSlots,
      'assignedStaff': assignedStaff,
      'staffCount': staffCount,
      'statusId': statusId,
      'notes': notes,
      'jobListItemId': jobListItemId,
      'amount': amount,
    };
  }

  // Create a copy with some fields updated
  WindowCleaningJob copyWith({
    String? location,
    String? client,
    DateTime? date,
    String? timeSlot,
    int? timeSlots,
    List<String>? assignedStaff,
    int? staffCount,
    String? statusId,
    String? notes,
    String? jobListItemId,
    double? amount,
  }) {
    return WindowCleaningJob(
      id: id,
      location: location ?? this.location,
      client: client ?? this.client,
      date: date ?? this.date,
      timeSlot: timeSlot ?? this.timeSlot,
      timeSlots: timeSlots ?? this.timeSlots,
      assignedStaff: assignedStaff ?? this.assignedStaff,
      staffCount: staffCount ?? this.staffCount,
      statusId: statusId ?? this.statusId,
      notes: notes ?? this.notes,
      jobListItemId: jobListItemId ?? this.jobListItemId,
      amount: amount ?? this.amount,
    );
  }

  // Available time slots (30-minute intervals from 8:00 to 16:00)
  static const List<String> availableTimeSlots = [
    '08:00',
    '08:30',
    '09:00',
    '09:30',
    '10:00',
    '10:30',
    '11:00',
    '11:30',
    '12:00',
    '12:30',
    '13:00',
    '13:30',
    '14:00',
    '14:30',
    '15:00',
    '15:30',
    '16:00',
  ];
}
