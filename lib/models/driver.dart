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

  const Driver({
    required this.id,
    required this.name,
    this.phone = '',
    this.defaultVehicle,
    this.defaultTrailer,
    this.active = true,
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
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'phone': phone,
        if (defaultVehicle != null) 'defaultVehicle': defaultVehicle!.name,
        if (defaultTrailer != null) 'defaultTrailer': defaultTrailer!.name,
        'active': active,
      };

  Driver copyWith({
    String? name,
    String? phone,
    VehicleType? defaultVehicle,
    TrailerType? defaultTrailer,
    bool? active,
  }) =>
      Driver(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        defaultVehicle: defaultVehicle ?? this.defaultVehicle,
        defaultTrailer: defaultTrailer ?? this.defaultTrailer,
        active: active ?? this.active,
      );
}
