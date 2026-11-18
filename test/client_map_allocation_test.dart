import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/job_area_link.dart';
import 'package:clmschedule/services/client_map_allocation_service.dart';
import 'package:clmschedule/shareable_maps/utils/linked_map_polygons.dart';
import 'package:clmschedule/utils/schedule_time.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

typedef S = ClientMapAllocationService;

final today = scheduleToday();

Job job(String id, DateTime date,
        {List<String> clients = const ['Acme Ltd'],
        List<JobAreaLink> links = const [],
        List<CustomPolygon> workMaps = const [],
        String? distributorId}) =>
    Job(
      id: id,
      clients: clients,
      workingAreas: const [],
      workMaps: workMaps,
      distributorId: distributorId ?? 'd_$id',
      date: date,
      statusId: 'scheduled',
      areaLinks: links,
    );

JobAreaLink link(String polygonId,
        {String mapId = 'm1', bool frozen = false}) =>
    JobAreaLink(
      mapId: mapId,
      monthKey: '10-2026',
      polygonId: polygonId,
      frozen: frozen
          ? const CustomPolygon(
              name: 'x', description: '', points: [], color: Colors.blue)
          : null,
    );

CustomPolygon area(String id, {double at = 0}) => CustomPolygon(
      id: id,
      name: 'Area $id',
      description: '',
      points: [LatLng(at, 0), LatLng(at, 1), LatLng(at + 1, 0)],
      color: Colors.blue,
    );

void main() {
  group('candidates', () {
    final from = today;
    test('same client (loosely matched), on or after the start, by date', () {
      final jobs = [
        job('late', today.add(const Duration(days: 5)),
            clients: const ['ACME LTD.']),
        job('early', today.add(const Duration(days: 1))),
        job('before', today.subtract(const Duration(days: 1))),
        job('other', today.add(const Duration(days: 2)),
            clients: const ['Other']),
        job('shared', today.add(const Duration(days: 3)),
            clients: const ['Other', 'Acme Ltd']),
      ];
      expect(S.candidates(jobs, 'Acme Ltd', from).map((j) => j.id),
          ['early', 'shared', 'late']);
    });

    test('window starts three days before the Job List date', () {
      expect(S.windowStart(DateTime(2026, 10, 10, 14)), DateTime(2026, 10, 7));
    });
  });

  group('holdings', () {
    test('grouped by polygon, only for this map, history marked', () {
      final past = job('past', today.subtract(const Duration(days: 2)),
          links: [link('a')]);
      final future = job('future', today.add(const Duration(days: 2)),
          links: [link('a'), link('b'), link('z', mapId: 'other')]);
      final frozen = job('frozen', today.add(const Duration(days: 1)),
          links: [link('b', frozen: true)]);
      final h = S.holdingsByPolygon([future, past, frozen], 'm1');

      expect(h.keys.toSet(), {'a', 'b'});
      expect(h['a']!.map((x) => x.job.id), ['past', 'future']);
      expect(S.currentOwners(h['a']).map((x) => x.job.id), ['future']);
      expect(S.currentOwners(h['b']).map((x) => x.job.id), ['future']);
    });
  });

  group('allocationChanges', () {
    final owner =
        job('owner', today.add(const Duration(days: 1)), links: [link('a')]);
    final worked = job('worked', today.subtract(const Duration(days: 1)),
        links: [link('a')]);
    final target = job('target', today.add(const Duration(days: 2)));
    final holdings = S.holdingsByPolygon([owner, worked, target], 'm1');

    test('split: the target gains the areas, nobody loses them', () {
      final changes = S.allocationChanges(
        mapId: 'm1',
        monthKey: '10-2026',
        polygons: [area('a'), area('b')],
        target: target,
        holdings: holdings,
        move: false,
      );
      expect(changes.length, 1);
      expect(changes.single.jobId, 'target');
      expect(changes.single.add.map((l) => l.polygonId), ['a', 'b']);
    });

    test('move: current owners lose it in the same change set, history keeps',
        () {
      final changes = S.allocationChanges(
        mapId: 'm1',
        monthKey: '10-2026',
        polygons: [area('a')],
        target: target,
        holdings: holdings,
        move: true,
      );
      expect(changes.map((c) => c.jobId), ['target', 'owner']);
      expect(changes.last.removeKeys, {'m1/a'});
    });
  });

  group('AreaLinkChange.applyTo', () {
    test('removes, then adds without stacking duplicates', () {
      final change = AreaLinkChange(
        jobId: 'j',
        date: today,
        add: [link('a'), link('c')],
        removeKeys: {'m1/b'},
      );
      final out = change.applyTo([link('a'), link('b')]);
      expect(out.map((l) => l.polygonId), ['a', 'c']);
    });
  });

  group('copied areas', () {
    final mapPolygons = [area('a'), area('b', at: 5)];
    // A copy with the map's id, and an id-less copy matched by outline.
    final byId = area('a');
    final byOutline = area('b', at: 5).copyWith(id: 'local-1');
    final copier = job('copier', today.add(const Duration(days: 1)),
        workMaps: [byId, byOutline]);
    final otherClient = job('other', today.add(const Duration(days: 1)),
        clients: const ['Other'], workMaps: [area('a')]);
    final resolved = job('resolved', today.add(const Duration(days: 1)),
        workMaps: [area('a').copyWith(id: 'arealink:m1/a')]);

    Map<String, List<AreaHolding>> holdings(List<Job> jobs) =>
        S.holdingsByPolygon(jobs, 'm1',
            client: 'Acme Ltd', mapPolygons: mapPolygons);

    test('count as held, by id or by outline, only for the client', () {
      final h = holdings([copier, otherClient, resolved]);
      expect(h['a']!.map((x) => x.job.id), ['copier']);
      expect(h['b']!.map((x) => x.job.id), ['copier']);
      expect(h['a']!.single.isCopy, isTrue);
    });

    test('a link and a copy on one job are one holding', () {
      final both = job('both', today.add(const Duration(days: 1)),
          links: [link('a')], workMaps: [area('a')]);
      final h = holdings([both])['a']!.single;
      expect(h.isCopy, isFalse);
      expect(h.copy, isNotNull);
      final removal = h.removal();
      expect(removal.removeKeys, {'m1/a'});
      expect(removal.removeCopyIds, {'a'});
    });

    test('move converts: the copy comes off the old job', () {
      final target = job('target', today.add(const Duration(days: 2)));
      final changes = S.allocationChanges(
        mapId: 'm1',
        monthKey: '10-2026',
        polygons: [area('b', at: 5)],
        target: target,
        holdings: holdings([copier, target]),
        move: true,
      );
      expect(changes.map((c) => c.jobId), ['target', 'copier']);
      expect(changes.first.add.single.polygonId, 'b');
      expect(changes.last.removeKeys, isEmpty);
      expect(changes.last.removesCopy(byOutline, polygonGeometryKey), isTrue);
      expect(changes.last.removesCopy(byId, polygonGeometryKey), isFalse);
    });

    test('allocating to a job holding a copy replaces the copy', () {
      final changes = S.allocationChanges(
        mapId: 'm1',
        monthKey: '10-2026',
        polygons: [area('a')],
        target: copier,
        holdings: holdings([copier]),
        move: false,
      );
      expect(changes.single.add.single.polygonId, 'a');
      expect(changes.single.removesCopy(byId, polygonGeometryKey), isTrue);
    });

    test('moveChanges links on the target and unlinks/uncopies the old', () {
      final target = job('target', today.add(const Duration(days: 2)));
      final h = holdings([copier, target]);
      final changes = S.moveChanges(
        mapId: 'm1',
        monthKey: '10-2026',
        holding: h['a']!.single,
        target: target,
        holdings: h,
      );
      expect(changes.first.jobId, 'target');
      expect(changes.first.add.single.key, 'm1/a');
      expect(changes.last.jobId, 'copier');
      expect(changes.last.removeCopyIds, {'a'});
    });

    test('resolved link polygons are never removed as copies', () {
      final change = AreaLinkChange(
          jobId: 'j', date: _epoch, removeCopyIds: {'arealink:m1/a'});
      expect(
          change.removesCopy(
              area('a').copyWith(id: 'arealink:m1/a'), polygonGeometryKey),
          isFalse);
    });
  });

  group('colours & style', () {
    test('by first date, then name; stable for the same schedule', () {
      final jobs = [
        job('x', today.add(const Duration(days: 2)), distributorId: 'zed'),
        job('y', today.add(const Duration(days: 1)), distributorId: 'bob'),
        job('z', today.add(const Duration(days: 1)), distributorId: 'amy'),
        job('w', today, distributorId: 'zed'),
      ];
      final c = S.distributorColours(jobs);
      expect(c.keys, ['zed', 'amy', 'bob']);
      expect(S.distributorColours(jobs.reversed.toList()), c);
    });

    test('grey when free, owner colour, heavy when shared', () {
      final a = job('a', today.add(const Duration(days: 1)),
          links: [link('p')], distributorId: 'amy');
      final b = job('b', today.add(const Duration(days: 2)),
          links: [link('p')], distributorId: 'bob');
      final colours = S.distributorColours([a, b]);
      final p = area('p');

      final free = S.styleFor(p, null, colours);
      expect(free.color, kUnallocatedAreaColor);

      final solo = S.styleFor(p, S.holdingsByPolygon([a], 'm1')['p'], colours);
      expect(solo.color, colours['amy']);
      expect(solo.strokeWidth, 2);

      final shared =
          S.styleFor(p, S.holdingsByPolygon([a, b], 'm1')['p'], colours);
      expect(shared.color, colours['amy']);
      expect(shared.strokeWidth, 5);
    });

    test('groups list each distributor\'s days in order, empty ones too', () {
      final d1 = job('d1', today.add(const Duration(days: 1)),
          links: [link('p')], distributorId: 'amy');
      final d2 = job('d2', today.add(const Duration(days: 2)),
          distributorId: 'amy');
      final e1 = job('e1', today.add(const Duration(days: 1)),
          distributorId: 'bob');
      final h = S.holdingsByPolygon([d1, d2, e1], 'm1');
      final colours = S.distributorColours([d1, d2, e1]);
      final g = S.groups([d2, e1, d1], h, colours);
      expect(g.map((x) => x.distributorId), ['amy', 'bob']);
      expect(g.first.days.map((d) => d.job.id), ['d1', 'd2']);
      expect(g.first.days.first.holdings.single.polygonId, 'p');
      expect(g.first.days.last.holdings, isEmpty);
    });
  });

  group('points', () {
    CustomPolygon point(String id, {double lat = 2}) => CustomPolygon(
          id: id,
          name: 'Lights $id',
          description: '',
          points: [LatLng(lat, 3)],
          color: Colors.red,
          type: MapElementType.point,
        );

    test('a linked point is held like an area', () {
      final j = job('j', today.add(const Duration(days: 1)),
          links: [link('pt1')], distributorId: 'amy');
      final h = S.holdingsByPolygon([j], 'm1',
          client: 'Acme Ltd', mapPolygons: [point('pt1')]);
      expect(h['pt1']!.single.job.id, 'j');
      final colours = S.distributorColours([j]);
      expect(S.colourFor(h['pt1'], colours), colours['amy']);
      expect(S.colourFor(null, colours), kUnallocatedAreaColor);
    });

    test('copied points match by id only, never by position', () {
      // The job's own address pin sits exactly on the client-map point.
      final addressPin = point('address', lat: 2).copyWith(id: 'addr');
      final copied = point('pt1');
      final j = job('j', today.add(const Duration(days: 1)),
          workMaps: [addressPin]);
      final k = job('k', today.add(const Duration(days: 1)),
          workMaps: [copied]);
      final h = S.holdingsByPolygon([j, k], 'm1',
          client: 'Acme Ltd', mapPolygons: [point('pt1')]);
      expect(h['pt1']!.map((x) => x.job.id), ['k']);
    });
  });
}

final _epoch = DateTime(2026);
