import 'collection_job.dart';

/// A driver who can be assigned to a daily dropsheet.
///
/// Stored at `/drivers/{id}` in Firestore.
class Driver {
  final String id;
  final String name;
  final String phone;
  final VehicleType? defaultVehicle;
  final TrailerType? defaultTrailer;
  final bool active;

  /// A member of management who drives, rather than a distributor — paid on
  /// the separate monthly payroll, so not linked to a distributor and never
  /// part of the weekly payroll.
  final bool management;

  const Driver({
    required this.id,
    required this.name,
    this.phone = '',
    this.defaultVehicle,
    this.defaultTrailer,
    this.active = true,
    this.management = false,
  });

  factory Driver.fromMap(String id, Map<String, dynamic> data) {
    VehicleType? vehicle;
    final v = data['defaultVehicle'] as String?;
    if (v != null) {
      vehicle = VehicleType.values
          .where((e) => e.name == v)
          .cast<VehicleType?>()
          .firstWhere((e) => true, orElse: () => null);
    }
    TrailerType? trailer;
    final t = data['defaultTrailer'] as String?;
    if (t != null) {
      trailer = TrailerType.values
          .where((e) => e.name == t)
          .cast<TrailerType?>()
          .firstWhere((e) => true, orElse: () => null);
    }
    return Driver(
      id: id,
      name: data['name'] as String? ?? '',
      phone: data['phone'] as String? ?? '',
      defaultVehicle: vehicle,
      defaultTrailer: trailer,
      active: data['active'] as bool? ?? true,
      management: data['management'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'phone': phone,
        if (defaultVehicle != null) 'defaultVehicle': defaultVehicle!.name,
        if (defaultTrailer != null) 'defaultTrailer': defaultTrailer!.name,
        'active': active,
        if (management) 'management': true,
      };

  Driver copyWith({
    String? name,
    String? phone,
    VehicleType? defaultVehicle,
    TrailerType? defaultTrailer,
    bool? active,
    bool? management,
  }) =>
      Driver(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        defaultVehicle: defaultVehicle ?? this.defaultVehicle,
        defaultTrailer: defaultTrailer ?? this.defaultTrailer,
        active: active ?? this.active,
        management: management ?? this.management,
      );
}
