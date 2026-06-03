import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'collection_job.dart';
import 'dropsheet_task.dart';
import 'dropsheet_task_type_config.dart';

/// One driver's section inside a daily dropsheet:
///   - which driver
///   - which vehicle + trailer they're using that day
///   - their ordered task list (mandatory Inspect / Pack / Leave stay first)
class DropsheetDriverSection {
  final String id; // stable id for reorder keys (matches driverId)
  final String driverId;
  final String driverName; // denormalised for offline / historical view
  final VehicleType? vehicle;
  final TrailerType? trailer;
  final List<DropsheetTask> tasks;

  /// Polyline of the most recently optimised route for this driver,
  /// starting at the depot. Empty when no route has been computed.
  final List<LatLng> routePolyline;

  /// Total drive distance (metres) of the optimised route. 0 when no
  /// route has been computed.
  final double routeDistanceMeters;

  /// Total drive duration (seconds) of the optimised route. 0 when no
  /// route has been computed.
  final int routeDurationSeconds;

  const DropsheetDriverSection({
    required this.id,
    required this.driverId,
    required this.driverName,
    this.vehicle,
    this.trailer,
    this.tasks = const [],
    this.routePolyline = const [],
    this.routeDistanceMeters = 0,
    this.routeDurationSeconds = 0,
  });

  factory DropsheetDriverSection.fromMap(Map<String, dynamic> data) {
    VehicleType? vehicle;
    final v = data['vehicle'] as String?;
    if (v != null) {
      for (final e in VehicleType.values) {
        if (e.name == v) {
          vehicle = e;
          break;
        }
      }
    }
    TrailerType? trailer;
    final t = data['trailer'] as String?;
    if (t != null) {
      for (final e in TrailerType.values) {
        if (e.name == t) {
          trailer = e;
          break;
        }
      }
    }
    final rawTasks = (data['tasks'] as List<dynamic>?)
            ?.map((e) =>
                DropsheetTask.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList() ??
        const <DropsheetTask>[];
    // Backward compatibility: older sections were created before the
    // trailing "Arrive at office" mandatory task existed. Append it on
    // read so every section always has it pinned at the bottom.
    final hasArrive = rawTasks.any((t) => t.type == DropsheetTaskType.arrive);
    final id = data['id'] as String;
    final tasks = hasArrive
        ? rawTasks
        : [
            ...rawTasks,
            DropsheetTask(
              id: '${id}_m4',
              type: DropsheetTaskType.arrive,
              job: 'Arrive',
              isMandatory: true,
            ),
          ];
    return DropsheetDriverSection(
      id: id,
      driverId: data['driverId'] as String? ?? '',
      driverName: data['driverName'] as String? ?? '',
      vehicle: vehicle,
      trailer: trailer,
      tasks: tasks,
      routePolyline: (data['routePolyline'] as List<dynamic>?)
              ?.whereType<Map>()
              .map((m) => LatLng(
                    (m['lat'] as num).toDouble(),
                    (m['lng'] as num).toDouble(),
                  ))
              .toList() ??
          const [],
      routeDistanceMeters:
          (data['routeDistanceMeters'] as num?)?.toDouble() ?? 0.0,
      routeDurationSeconds:
          (data['routeDurationSeconds'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'driverId': driverId,
        'driverName': driverName,
        if (vehicle != null) 'vehicle': vehicle!.name,
        if (trailer != null) 'trailer': trailer!.name,
        'tasks': tasks.map((t) => t.toMap()).toList(),
        if (routePolyline.isNotEmpty)
          'routePolyline': routePolyline
              .map((p) => {'lat': p.latitude, 'lng': p.longitude})
              .toList(),
        if (routeDistanceMeters > 0) 'routeDistanceMeters': routeDistanceMeters,
        if (routeDurationSeconds > 0)
          'routeDurationSeconds': routeDurationSeconds,
      };

  DropsheetDriverSection copyWith({
    String? driverName,
    VehicleType? vehicle,
    TrailerType? trailer,
    List<DropsheetTask>? tasks,
    List<LatLng>? routePolyline,
    double? routeDistanceMeters,
    int? routeDurationSeconds,
  }) =>
      DropsheetDriverSection(
        id: id,
        driverId: driverId,
        driverName: driverName ?? this.driverName,
        vehicle: vehicle ?? this.vehicle,
        trailer: trailer ?? this.trailer,
        tasks: tasks ?? this.tasks,
        routePolyline: routePolyline ?? this.routePolyline,
        routeDistanceMeters: routeDistanceMeters ?? this.routeDistanceMeters,
        routeDurationSeconds: routeDurationSeconds ?? this.routeDurationSeconds,
      );

  /// Build a fresh section seeded with the 3 mandatory tasks.
  ///
  /// When [depot] is supplied, the Leave and Arrive tasks are pre-filled
  /// with the office address and coordinates so drivers always see their
  /// start/end location.
  factory DropsheetDriverSection.create({
    required String driverId,
    required String driverName,
    VehicleType? vehicle,
    TrailerType? trailer,
    DepotConfig? depot,
  }) {
    return DropsheetDriverSection(
      id: driverId,
      driverId: driverId,
      driverName: driverName,
      vehicle: vehicle,
      trailer: trailer,
      tasks: DropsheetTask.mandatoryTemplate(
        idPrefix: driverId,
        vehicleLabel: vehicle?.displayName,
        vehicleKey: vehicle?.name,
        depotAddress: depot?.address.isNotEmpty == true ? depot!.address : null,
        depotLat: depot?.lat,
        depotLng: depot?.lng,
        depotStartTime: depot?.startTime,
      ),
    );
  }
}

/// A single day's dropsheet stored at `/dropsheet/daily/{YYYY-MM-DD}`.
class DropsheetDay {
  final DateTime date;
  final List<DropsheetDriverSection> sections;

  const DropsheetDay({
    required this.date,
    this.sections = const [],
  });

  /// Format `YYYY-MM-DD` used as the Firestore document id.
  static String docIdFor(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String get docId => docIdFor(date);

  factory DropsheetDay.fromMap(String docId, Map<String, dynamic> data) {
    final parts = docId.split('-');
    final date = DateTime(
      int.tryParse(parts[0]) ?? DateTime.now().year,
      int.tryParse(parts[1]) ?? 1,
      int.tryParse(parts[2]) ?? 1,
    );
    return DropsheetDay(
      date: date,
      sections: (data['sections'] as List<dynamic>?)
              ?.map((e) => DropsheetDriverSection.fromMap(
                  Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toMap() => {
        'date': docId,
        'sections': sections.map((s) => s.toMap()).toList(),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };

  DropsheetDay copyWith({List<DropsheetDriverSection>? sections}) =>
      DropsheetDay(date: date, sections: sections ?? this.sections);
}
