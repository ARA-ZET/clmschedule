import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/job_area_link.dart';
import 'package:clmschedule/services/client_map_allocation_service.dart';
import 'package:clmschedule/utils/schedule_time.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

typedef S = ClientMapAllocationService;

final today = scheduleToday();

Job job(String id, DateTime date,
        {List<String> clients = const ['Acme Ltd'],
        List<JobAreaLink> links = const []}) =>
    Job(
      id: id,
      clients: clients,
      workingAreas: const [],
      workMaps: const [],
      distributorId: 'd_$id',
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

CustomPolygon area(String id) => CustomPolygon(
      id: id,
      name: 'Area $id',
      description: '',
      points: const [LatLng(0, 0), LatLng(0, 1), LatLng(1, 0)],
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
}
