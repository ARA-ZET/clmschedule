// models/job_linked_map.dart
//
// One client map linked to a schedule job. A job can be sent out with
// several client maps at once (two clients sharing a distributor's day, or
// one client's ground split across maps), so `Job.linkedMaps` holds a list
// of these and the older single `linkedMapId`/`linkedMapMonthKey` fields
// mirror the first one for anything still reading them.
class JobLinkedMap {
  /// Firestore id of the `ShareableMap` document.
  final String mapId;

  /// Month key (e.g. `'03-2026'`) of the map's Firestore path
  /// (`/shareableMaps/{monthKey}/maps/{mapId}`).
  final String monthKey;

  /// The map's name at link time — a label only, so the UI can list the
  /// links without fetching every document. The map's live state (layers,
  /// polygons, cloud folders) is always re-fetched, never cached here.
  final String name;

  const JobLinkedMap({
    required this.mapId,
    required this.monthKey,
    this.name = '',
  });

  factory JobLinkedMap.fromMap(Map<String, dynamic> data) => JobLinkedMap(
        mapId: data['mapId'] as String? ?? '',
        monthKey: data['monthKey'] as String? ?? '',
        name: data['name'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
        'mapId': mapId,
        'monthKey': monthKey,
        'name': name,
      };

  JobLinkedMap copyWith({String? mapId, String? monthKey, String? name}) =>
      JobLinkedMap(
        mapId: mapId ?? this.mapId,
        monthKey: monthKey ?? this.monthKey,
        name: name ?? this.name,
      );

  @override
  bool operator ==(Object other) =>
      other is JobLinkedMap &&
      other.mapId == mapId &&
      other.monthKey == monthKey &&
      other.name == name;

  @override
  int get hashCode => Object.hash(mapId, monthKey, name);

  @override
  String toString() => 'JobLinkedMap($mapId, $monthKey, $name)';
}
