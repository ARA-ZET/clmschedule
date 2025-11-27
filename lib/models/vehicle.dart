import 'package:cloud_firestore/cloud_firestore.dart';

/// Vehicle model for tracking system
class Vehicle {
  final String id;
  final String name; // e.g., "Mahindra", "Hyundai", "Traffic light"
  final String type; // e.g., "truck", "van", "car"
  final String? plateNumber;
  final bool isActive;

  Vehicle({
    required this.id,
    required this.name,
    required this.type,
    this.plateNumber,
    this.isActive = true,
  });

  factory Vehicle.fromMap(String id, Map<String, dynamic> data) {
    return Vehicle(
      id: id,
      name: data['name'] as String,
      type: data['type'] as String,
      plateNumber: data['plateNumber'] as String?,
      isActive: data['isActive'] as bool? ?? true,
    );
  }

  factory Vehicle.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Vehicle.fromMap(doc.id, data);
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'type': type,
      'plateNumber': plateNumber,
      'isActive': isActive,
    };
  }

  Vehicle copyWith({
    String? id,
    String? name,
    String? type,
    String? plateNumber,
    bool? isActive,
  }) {
    return Vehicle(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      plateNumber: plateNumber ?? this.plateNumber,
      isActive: isActive ?? this.isActive,
    );
  }
}

/// Driver model for tracking system
class Driver {
  final String id;
  final String name;
  final String? phone;
  final String? vehicleId;
  final bool isActive;

  Driver({
    required this.id,
    required this.name,
    this.phone,
    this.vehicleId,
    this.isActive = true,
  });

  factory Driver.fromMap(String id, Map<String, dynamic> data) {
    return Driver(
      id: id,
      name: data['name'] as String,
      phone: data['phone'] as String?,
      vehicleId: data['vehicleId'] as String?,
      isActive: data['isActive'] as bool? ?? true,
    );
  }

  factory Driver.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Driver.fromMap(doc.id, data);
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phone': phone,
      'vehicleId': vehicleId,
      'isActive': isActive,
    };
  }

  Driver copyWith({
    String? id,
    String? name,
    String? phone,
    String? vehicleId,
    bool? isActive,
  }) {
    return Driver(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      vehicleId: vehicleId ?? this.vehicleId,
      isActive: isActive ?? this.isActive,
    );
  }
}

/// Daily tracking entry matching Google Sheets format
class DailyTrackingEntry {
  final String id;
  final DateTime date;
  final String? driverId;
  final String? vehicleId;
  final String distributorId;
  final String area;
  final int? bagOut;
  final int? bagIn;
  final String? specialInstructions;
  final DateTime createdAt;

  DailyTrackingEntry({
    required this.id,
    required this.date,
    this.driverId,
    this.vehicleId,
    required this.distributorId,
    required this.area,
    this.bagOut,
    this.bagIn,
    this.specialInstructions,
    required this.createdAt,
  });

  factory DailyTrackingEntry.fromMap(String id, Map<String, dynamic> data) {
    return DailyTrackingEntry(
      id: id,
      date: (data['date'] as Timestamp).toDate(),
      driverId: data['driverId'] as String?,
      vehicleId: data['vehicleId'] as String?,
      distributorId: data['distributorId'] as String,
      area: data['area'] as String,
      bagOut: data['bagOut'] as int?,
      bagIn: data['bagIn'] as int?,
      specialInstructions: data['specialInstructions'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
    );
  }

  factory DailyTrackingEntry.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return DailyTrackingEntry.fromMap(doc.id, data);
  }

  Map<String, dynamic> toMap() {
    return {
      'date': Timestamp.fromDate(date),
      'driverId': driverId,
      'vehicleId': vehicleId,
      'distributorId': distributorId,
      'area': area,
      'bagOut': bagOut,
      'bagIn': bagIn,
      'specialInstructions': specialInstructions,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
