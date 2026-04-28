import 'collection_job.dart';
import 'dropsheet_task.dart';

/// One driver's section inside a daily dropsheet:
///   - which driver
///   - which vehicle + trailer they're using that day
///   - their ordered task list (first 3 are the mandatory template)
class DropsheetDriverSection {
  final String id; // stable id for reorder keys (matches driverId)
  final String driverId;
  final String driverName; // denormalised for offline / historical view
  final VehicleType? vehicle;
  final TrailerType? trailer;
  final List<DropsheetTask> tasks;

  const DropsheetDriverSection({
    required this.id,
    required this.driverId,
    required this.driverName,
    this.vehicle,
    this.trailer,
    this.tasks = const [],
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
    return DropsheetDriverSection(
      id: data['id'] as String,
      driverId: data['driverId'] as String? ?? '',
      driverName: data['driverName'] as String? ?? '',
      vehicle: vehicle,
      trailer: trailer,
      tasks: (data['tasks'] as List<dynamic>?)
              ?.map((e) => DropsheetTask.fromMap(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'driverId': driverId,
        'driverName': driverName,
        if (vehicle != null) 'vehicle': vehicle!.name,
        if (trailer != null) 'trailer': trailer!.name,
        'tasks': tasks.map((t) => t.toMap()).toList(),
      };

  DropsheetDriverSection copyWith({
    String? driverName,
    VehicleType? vehicle,
    TrailerType? trailer,
    List<DropsheetTask>? tasks,
  }) =>
      DropsheetDriverSection(
        id: id,
        driverId: driverId,
        driverName: driverName ?? this.driverName,
        vehicle: vehicle ?? this.vehicle,
        trailer: trailer ?? this.trailer,
        tasks: tasks ?? this.tasks,
      );

  /// Build a fresh section seeded with the 3 mandatory tasks.
  factory DropsheetDriverSection.create({
    required String driverId,
    required String driverName,
    VehicleType? vehicle,
    TrailerType? trailer,
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
  static String docIdFor(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
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
              ?.map((e) =>
                  DropsheetDriverSection.fromMap(e as Map<String, dynamic>))
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
