// models/job_area_link.dart
//
// One client-map polygon allocated to a schedule job — by reference.
//
// The polygon itself stays on its client map (`shareableMaps/{monthKey}/maps/
// {mapId}`, found by its stable `polygonId`); the job holds only this link.
// `AreaLinkResolver` looks the polygon up when jobs are read and puts it into
// `Job.workMaps` in memory, so the print map, day planner, track editor and
// every other reader see the client map's CURRENT outline without knowing a
// link exists. `Job.toMap` strips those resolved polygons again, so a copy is
// never written back onto the job.
//
// Once the job's day has been worked the link is [frozen]: it keeps the
// outline that was actually walked, and later edits to the client map no
// longer move it. Until then [frozen] is null and the link is live.
import 'custom_polygon.dart';

class JobAreaLink {
  /// Firestore id of the client `ShareableMap` document.
  final String mapId;

  /// Month key (e.g. `'09-2026'`) of the map's Firestore path.
  final String monthKey;

  /// The polygon's stable id on that map (see `utils/polygon_ids.dart`).
  final String polygonId;

  /// The polygon's name when it was allocated — a label for when the map
  /// cannot be read (deleted map, deleted polygon). The live name wins.
  final String name;

  /// The outline as it was worked, once the job's day is done. Null while
  /// the link is live.
  final CustomPolygon? frozen;

  const JobAreaLink({
    required this.mapId,
    required this.monthKey,
    required this.polygonId,
    this.name = '',
    this.frozen,
  });

  /// Identity of the polygon this link points at — the same polygon linked
  /// twice to one job is one link.
  String get key => '$mapId/$polygonId';

  /// Id given to the polygon this link resolves to inside `Job.workMaps`.
  /// The prefix is how serialisation recognises and strips it.
  String get resolvedId => '$kResolvedIdPrefix$key';

  static const String kResolvedIdPrefix = 'arealink:';

  /// True for a `workMaps` entry that came from a link, not from the job.
  static bool isResolved(CustomPolygon p) =>
      p.id?.startsWith(kResolvedIdPrefix) ?? false;

  bool get isFrozen => frozen != null;

  factory JobAreaLink.fromMap(Map<String, dynamic> data) => JobAreaLink(
        mapId: data['mapId'] as String? ?? '',
        monthKey: data['monthKey'] as String? ?? '',
        polygonId: data['polygonId'] as String? ?? '',
        name: data['name'] as String? ?? '',
        frozen: data['frozen'] is Map
            ? CustomPolygon.fromMap(
                Map<String, dynamic>.from(data['frozen'] as Map))
            : null,
      );

  Map<String, dynamic> toMap() => {
        'mapId': mapId,
        'monthKey': monthKey,
        'polygonId': polygonId,
        'name': name,
        if (frozen != null) 'frozen': frozen!.toMap(),
      };

  JobAreaLink copyWith({String? name, CustomPolygon? frozen}) => JobAreaLink(
        mapId: mapId,
        monthKey: monthKey,
        polygonId: polygonId,
        name: name ?? this.name,
        frozen: frozen ?? this.frozen,
      );

  @override
  bool operator ==(Object other) =>
      other is JobAreaLink &&
      other.mapId == mapId &&
      other.monthKey == monthKey &&
      other.polygonId == polygonId &&
      other.name == name &&
      other.isFrozen == isFrozen;

  @override
  int get hashCode => Object.hash(mapId, monthKey, polygonId, name, isFrozen);

  @override
  String toString() => 'JobAreaLink($key${isFrozen ? ', frozen' : ''})';
}

/// One job's share of an allocation change: links to add and links (by
/// [JobAreaLink.key]) to remove. Applied by
/// `FirestoreService.applyAreaLinkChanges`, which touches nothing on the job
/// but its `areaLinks`.
class AreaLinkChange {
  final String jobId;

  /// The job's schedule day — the day doc it lives in.
  final DateTime date;

  final List<JobAreaLink> add;
  final Set<String> removeKeys;

  const AreaLinkChange({
    required this.jobId,
    required this.date,
    this.add = const [],
    this.removeKeys = const {},
  });

  /// [links] after this change: removals first, then additions not already
  /// present (a link to the same polygon is never stacked).
  List<JobAreaLink> applyTo(List<JobAreaLink> links) {
    final out = links.where((l) => !removeKeys.contains(l.key)).toList();
    final keys = out.map((l) => l.key).toSet();
    for (final l in add) {
      if (keys.add(l.key)) out.add(l);
    }
    return out;
  }
}
