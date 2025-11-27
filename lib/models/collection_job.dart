import 'package:cloud_firestore/cloud_firestore.dart';

enum VehicleType { hyundai, mahindra, nissan }

enum TrailerType { bigTrailer, smallTrailer, noTrailer }

class CollectionJob {
  final String id;
  final String location;
  final VehicleType vehicleType;
  final TrailerType trailerType;
  final DateTime date;
  final String timeSlot; // Time in HH:MM format (08:00-16:00)
  final int
      timeSlots; // Number of 30-minute slots this job occupies (1 or more)
  final List<String> assignedStaff; // Staff names/IDs
  final int staffCount; // Number of staff needed
  final String jobType; // 'junk collection', 'furniture move', etc.
  final String statusId;
  final List<String> clients;
  final String notes;
  final String jobListItemId; // Link to the original job list item

  CollectionJob({
    required this.id,
    required this.location,
    required this.vehicleType,
    required this.trailerType,
    required this.date,
    required this.timeSlot,
    int? timeSlots,
    required this.assignedStaff,
    required this.staffCount,
    required this.jobType,
    required this.statusId,
    required this.clients,
    this.notes = '',
    this.jobListItemId = '', // Optional link to job list item
  }) : timeSlots = (timeSlots != null && timeSlots >= 1) ? timeSlots : 1;

  // Create from Firestore
  factory CollectionJob.fromMap(String id, Map<String, dynamic> data) {
    return CollectionJob(
      id: id,
      location: data['location'] as String? ?? '',
      vehicleType: VehicleType.values.firstWhere(
        (e) =>
            e.toString() == 'VehicleType.${data['vehicleType']}' ||
            e.name == data['vehicleType'],
        orElse: () => VehicleType.hyundai,
      ),
      trailerType: TrailerType.values.firstWhere(
        (e) =>
            e.toString() == 'TrailerType.${data['trailerType']}' ||
            e.name == data['trailerType'],
        orElse: () => TrailerType.noTrailer,
      ),
      date: data['date'] != null
          ? (data['date'] as Timestamp).toDate()
          : DateTime.now(),
      timeSlot: data['timeSlot'] is int
          ? '${(data['timeSlot'] as int).toString().padLeft(2, '0')}:00'
          : data['timeSlot'] as String? ?? '08:00',
      timeSlots: data['timeSlots']
          as int?, // Will default to 1 in constructor if null or < 1
      assignedStaff:
          (data['assignedStaff'] as List<dynamic>?)?.cast<String>() ?? [],
      staffCount: data['staffCount'] as int? ?? 1,
      jobType: data['jobType'] as String? ?? 'junk collection',
      statusId: data['statusId'] as String? ?? 'scheduled',
      clients: (data['clients'] as List<dynamic>?)?.cast<String>() ?? [],
      notes: data['notes'] as String? ?? '',
      jobListItemId: data['jobListItemId'] as String? ?? '',
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'location': location,
      'vehicleType': vehicleType.name,
      'trailerType': trailerType.name,
      'date': Timestamp.fromDate(date),
      'timeSlot': timeSlot,
      'timeSlots': timeSlots,
      'assignedStaff': assignedStaff,
      'staffCount': staffCount,
      'jobType': jobType,
      'statusId': statusId,
      'clients': clients,
      'notes': notes,
      'jobListItemId': jobListItemId,
    };
  }

  // Create a copy with some fields updated
  CollectionJob copyWith({
    String? location,
    VehicleType? vehicleType,
    TrailerType? trailerType,
    DateTime? date,
    String? timeSlot,
    int? timeSlots,
    List<String>? assignedStaff,
    int? staffCount,
    String? jobType,
    String? statusId,
    List<String>? clients,
    String? notes,
    String? jobListItemId,
  }) {
    return CollectionJob(
      id: id,
      location: location ?? this.location,
      vehicleType: vehicleType ?? this.vehicleType,
      trailerType: trailerType ?? this.trailerType,
      date: date ?? this.date,
      timeSlot: timeSlot ?? this.timeSlot,
      timeSlots: timeSlots ?? this.timeSlots,
      assignedStaff: assignedStaff ?? this.assignedStaff,
      staffCount: staffCount ?? this.staffCount,
      jobType: jobType ?? this.jobType,
      statusId: statusId ?? this.statusId,
      clients: clients ?? this.clients,
      notes: notes ?? this.notes,
      jobListItemId: jobListItemId ?? this.jobListItemId,
    );
  }

  // Helper getters
  String get vehicleDisplayName {
    switch (vehicleType) {
      case VehicleType.hyundai:
        return 'Hyundai';
      case VehicleType.mahindra:
        return 'Mahindra';
      case VehicleType.nissan:
        return 'Nissan';
    }
  }

  String get trailerDisplayName {
    switch (trailerType) {
      case TrailerType.bigTrailer:
        return 'Big Trailer';
      case TrailerType.smallTrailer:
        return 'Small Trailer';
      case TrailerType.noTrailer:
        return 'No Trailer';
    }
  }

  String get timeSlotDisplay {
    return timeSlot;
  }

  String get assignedStaffDisplay => assignedStaff.join(', ');

  String get clientsDisplay => clients.join(', ');

  bool get isValidTimeSlot {
    if (timeSlot.isEmpty) return false;
    try {
      final parts = timeSlot.split(':');
      if (parts.length != 2) return false;
      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);

      // Valid hours: 7 (only :30) and 8-20 (both :00 and :30)
      if (hour == 7) {
        return minute == 30; // Only 07:30 is valid for hour 7
      } else if (hour >= 8 && hour <= 20) {
        return minute == 0 || minute == 30;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  @override
  String toString() {
    return 'CollectionJob(id: $id, location: $location, vehicle: $vehicleDisplayName, '
        'trailer: $trailerDisplayName, date: $date, timeSlot: $timeSlotDisplay, '
        'staff: $assignedStaffDisplay, jobType: $jobType)';
  }

  // Static helper methods
  static List<String> get availableTimeSlots {
    return [
      "07:30", // Start from 07:30
      "08:00",
      "08:30",
      "09:00",
      "09:30",
      "10:00",
      "10:30",
      "11:00",
      "11:30",
      "12:00",
      "12:30",
      "13:00",
      "13:30",
      "14:00",
      "14:30",
      "15:00",
      "15:30",
      "16:00",
      "16:30",
      "17:00",
      "17:30",
      "18:00",
      "18:30",
      "19:00",
      "19:30",
      "20:00"
    ];
  }

  // Get the end time slot for this job
  String get endTimeSlot {
    final availableSlots = CollectionJob.availableTimeSlots;
    final startIndex = availableSlots.indexOf(timeSlot);
    if (startIndex == -1) return timeSlot;

    final endIndex =
        (startIndex + timeSlots - 1).clamp(0, availableSlots.length - 1);
    return availableSlots[endIndex];
  }

  // Get display text showing the time range
  String get timeRangeDisplay {
    if (timeSlots <= 1) return timeSlot;
    return '$timeSlot - $endTimeSlot';
  }

  static List<VehicleType> get availableVehicleTypes => VehicleType.values;
  static List<TrailerType> get availableTrailerTypes => TrailerType.values;
}
