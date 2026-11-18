import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/job_area_link.dart';
import 'package:clmschedule/shareable_maps/models/map_layer.dart';
import 'package:clmschedule/shareable_maps/models/map_point.dart';
import 'package:clmschedule/shareable_maps/models/shareable_map.dart';
import 'package:clmschedule/shareable_maps/utils/polygon_ids.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

CustomPolygon poly(String name, double lat, {String? id}) => CustomPolygon(
      id: id,
      name: name,
      description: '',
      points: [LatLng(lat, 18.4), LatLng(lat + 0.01, 18.4), LatLng(lat, 18.41)],
      color: Colors.blue,
    );

MapLayer layer(String id, List<CustomPolygon> polygons) => MapLayer(
      id: id,
      name: id,
      order: 0,
      defaultColor: Colors.blue,
      polygons: polygons,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

Job job({
  List<CustomPolygon> workMaps = const [],
  List<String> workingAreas = const [],
  List<JobAreaLink> areaLinks = const [],
}) =>
    Job(
      id: 'j1',
      clients: const ['Acme'],
      workingAreas: workingAreas,
      workMaps: workMaps,
      distributorId: 'd1',
      date: DateTime(2026, 10, 7),
      statusId: 'scheduled',
      areaLinks: areaLinks,
    );

void main() {
  group('stable point ids', () {
    MapPoint pt(String id, double lat) => MapPoint(
          id: id,
          name: 'Lights $lat',
          position: LatLng(lat, 18.4),
          color: Colors.red,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );
    MapLayer withPoints(String id, List<MapPoint> points) => MapLayer(
          id: id,
          name: id,
          order: 0,
          defaultColor: Colors.blue,
          points: points,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );

    test('a stored point keeps its id through a round trip', () {
      final stored = withPoints('l1', [pt('point_123', -33.9)]).toMap();
      final back = MapLayer.fromMap('l1', stored);
      expect(back.points.single.id, 'point_123');
    });

    test('a point saved without an id gets one from its position, the '
        'same on every read, unaffected by deleting an earlier point', () {
      Map<String, dynamic> raw(double lat) =>
          pt('x', lat).toMap()..remove('id');
      final both = MapLayer.fromMap('l1', {
        'points': [raw(-33.9), raw(-33.8)],
      });
      final second = MapLayer.fromMap('l1', {
        'points': [raw(-33.8)],
      });
      expect(both.points[1].id, second.points.single.id);
      expect(both.points[0].id, isNot(both.points[1].id));
      expect(both.points[1].id, startsWith(kPointIdPrefix));
    });

    test('duplicate point ids are made unique across the map', () {
      final out = withStablePolygonIds([
        withPoints('l1', [pt('p', -33.9)]),
        withPoints('l2', [pt('p', -33.8)]),
      ]);
      expect(out[0].points.single.id, 'p');
      expect(out[1].points.single.id, 'p_2');
    });
  });

  group('stable polygon ids', () {
    test('missing ids are derived from the outline, the same every time', () {
      final a = withStablePolygonIds([
        layer('l1', [poly('A', -33.9), poly('B', -33.8)])
      ]);
      final b = withStablePolygonIds([
        layer('l1', [poly('A', -33.9), poly('B', -33.8)])
      ]);
      final idsA = a.first.polygons.map((p) => p.id).toList();
      expect(idsA.every((id) => id!.startsWith(kPolygonIdPrefix)), isTrue);
      expect(idsA, b.first.polygons.map((p) => p.id).toList());
      expect(idsA.toSet().length, 2);
    });

    test('an existing id is kept when the outline changes', () {
      final moved = poly('A', -30.0, id: 'pg_keep');
      final out = withStablePolygonIds([
        layer('l1', [moved])
      ]);
      expect(out.first.polygons.single.id, 'pg_keep');
    });

    test('duplicate ids across layers: the first keeps it, later get a suffix',
        () {
      final out = withStablePolygonIds([
        layer('l1', [poly('A', -33.9, id: 'x')]),
        layer('l2', [poly('A copy', -33.7, id: 'x')]),
      ]);
      expect(out[0].polygons.single.id, 'x');
      expect(out[1].polygons.single.id, 'x_2');
    });

    test('nothing to change returns the same list', () {
      final layers = [
        layer('l1', [poly('A', -33.9, id: 'x')])
      ];
      expect(identical(withStablePolygonIds(layers), layers), isTrue);
    });

    test('ShareableMap.fromMap backfills ids, toMap persists them', () {
      final map = ShareableMap(
        id: 'm1',
        name: 'Acme Oct',
        layers: [
          layer('l1', [poly('A', -33.9)])
        ],
        defaultCenter: const LatLng(-33.9, 18.4),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(map.layers.first.polygons.single.id, isNull);
      final read = ShareableMap.fromMap('m1', map.toMap());
      final id = read.layers.first.polygons.single.id;
      expect(id, isNotNull);
      final reread = ShareableMap.fromMap('m1', read.toMap());
      expect(reread.layers.first.polygons.single.id, id);
    });
  });

  group('Job area links', () {
    const link = JobAreaLink(
        mapId: 'm1',
        monthKey: '10-2026',
        polygonId: 'pg_a',
        name: 'Rondebosch');
    final resolved = poly('Rondebosch', -33.95, id: link.resolvedId);
    final own = poly('Hand drawn', -33.9);

    test('resolved areas are added in memory and stripped on save', () {
      final hydrated = job(
        workMaps: [own],
        workingAreas: const ['Hand drawn'],
        areaLinks: const [link],
      ).withResolvedAreas([resolved]);

      expect(hydrated.workMaps.length, 2);
      expect(hydrated.workingAreas, ['Hand drawn', 'Rondebosch']);

      final stored = hydrated.toMap();
      expect((stored['workMaps'] as List).length, 1);
      expect(stored['workingAreas'], ['Hand drawn']);
      expect((stored['areaLinks'] as List).single['polygonId'], 'pg_a');
    });

    test('resolving twice replaces rather than stacks', () {
      final once = job(areaLinks: const [link]).withResolvedAreas([resolved]);
      final twice = once.withResolvedAreas([resolved]);
      expect(twice.workMaps.length, 1);
      expect(twice.workingAreas, ['Rondebosch']);
    });

    test('links and resolved names survive copyWith and a round trip', () {
      final hydrated =
          job(areaLinks: const [link]).withResolvedAreas([resolved]);
      final edited = hydrated.copyWith(statusId: 'done');
      expect(edited.toMap()['workingAreas'], isEmpty);
      final back = Job.fromMap('j1', edited.toMap());
      expect(back.areaLinks.single.key, link.key);
      expect(back.workMaps, isEmpty);
    });

    test('removing a shown linked area in the work-area list unlinks it', () {
      final hydrated = job(workMaps: [own], areaLinks: const [link])
          .withResolvedAreas([resolved]);
      final edited = hydrated.withEditedWorkMaps([own], ['Hand drawn']);
      expect(edited.areaLinks, isEmpty);
    });

    test('a link whose map has not loaded yet is not dropped by an edit', () {
      // Not hydrated: the link's polygon was never on screen.
      final edited = job(workMaps: [own], areaLinks: const [link])
          .withEditedWorkMaps([own], ['Hand drawn']);
      expect(edited.areaLinks.single.key, link.key);
    });

    test('detachedWorkMaps turns linked areas into plain copies', () {
      final hydrated =
          job(areaLinks: const [link]).withResolvedAreas([resolved]);
      final detached = hydrated.detachedWorkMaps.single;
      expect(JobAreaLink.isResolved(detached), isFalse);
      expect(detached.id, 'pg_a');
    });

    test('a frozen link round-trips its outline', () {
      final frozen = link.copyWith(frozen: poly('Rondebosch', -33.95));
      final back = JobAreaLink.fromMap(frozen.toMap());
      expect(back.isFrozen, isTrue);
      expect(back.frozen!.points.length, 3);
    });
  });
}
