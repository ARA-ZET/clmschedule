import 'package:cloud_firestore/cloud_firestore.dart';

enum VehicleType { hyundai, mahindra, nissan }

enum TrailerType { bigTrailer, smallTrailer, noTrailer }

class CollectionJob {
  final String id;
  final String location;
  final VehicleType vehicleType;
  final TrailerType trailerType;
  final DateTime date;
  final int timeSlot; // Hour in 24-hour format (8-16)
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
    required this.assignedStaff,
    required this.staffCount,
    required this.jobType,
    required this.statusId,
    required this.clients,
    this.notes = '',
    this.jobListItemId = '', // Optional link to job list item
  });

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
      timeSlot: data['timeSlot'] as int? ?? 8,
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
    int? timeSlot,
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
    return '${timeSlot.toString().padLeft(2, '0')}:00';
  }

  String get assignedStaffDisplay => assignedStaff.join(', ');

  String get clientsDisplay => clients.join(', ');

  bool get isValidTimeSlot => timeSlot >= 8 && timeSlot <= 16;

  @override
  String toString() {
    return 'CollectionJob(id: $id, location: $location, vehicle: $vehicleDisplayName, '
        'trailer: $trailerDisplayName, date: $date, timeSlot: $timeSlotDisplay, '
        'staff: $assignedStaffDisplay, jobType: $jobType)';
  }

  // Static helper methods
  static List<String> get availableTimeSlots {
    return List.generate(
        9, (index) => '${(index + 8).toString().padLeft(2, '0')}:00');
  }

  static List<VehicleType> get availableVehicleTypes => VehicleType.values;
  static List<TrailerType> get availableTrailerTypes => TrailerType.values;
}
