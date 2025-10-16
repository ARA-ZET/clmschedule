// Distributor status enum
enum DistributorStatus {
  active,
  inactive, 
  suspended,
  onLeave;

  String get displayName {
    switch (this) {
      case DistributorStatus.active:
        return 'Active';
      case DistributorStatus.inactive:
        return 'Inactive';
      case DistributorStatus.suspended:
        return 'Suspended';
      case DistributorStatus.onLeave:
        return 'On Leave';
    }
  }

  // Get status from string (for Firestore deserialization)
  static DistributorStatus fromString(String? status) {
    switch (status?.toLowerCase()) {
      case 'inactive':
        return DistributorStatus.inactive;
      case 'suspended':
        return DistributorStatus.suspended;
      case 'onleave':
      case 'on_leave':
        return DistributorStatus.onLeave;
      default:
        return DistributorStatus.active;
    }
  }
}

class Distributor {
  final String id; // Document ID from Firestore
  final String name;
  final int index; // Position/order index for sorting and display
  final String? phone1; // Primary phone number
  final String? phone2; // Secondary phone number
  final DistributorStatus status; // Current status

  Distributor({
    required this.id,
    required this.name,
    required this.index,
    this.phone1,
    this.phone2,
    this.status = DistributorStatus.active,
  });

  // Create from Firestore
  factory Distributor.fromMap(String id, Map<String, dynamic> data) {
    return Distributor(
      id: id,
      name: data['name'] as String,
      index: data['index'] as int? ?? 0, // Default to 0 if not set
      phone1: data['phone1'] as String?,
      phone2: data['phone2'] as String?,
      status: DistributorStatus.fromString(data['status'] as String?),
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'index': index,
      'phone1': phone1,
      'phone2': phone2,
      'status': status.name,
    };
  }

  // Create a copy with updated fields
  Distributor copyWith({
    String? id,
    String? name,
    int? index,
    String? phone1,
    String? phone2,
    DistributorStatus? status,
  }) {
    return Distributor(
      id: id ?? this.id,
      name: name ?? this.name,
      index: index ?? this.index,
      phone1: phone1 ?? this.phone1,
      phone2: phone2 ?? this.phone2,
      status: status ?? this.status,
    );
  }

  @override
  String toString() => 'Distributor(id: $id, name: $name, index: $index, phone1: $phone1, phone2: $phone2, status: ${status.displayName})';
}
