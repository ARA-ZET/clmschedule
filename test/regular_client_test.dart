import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/regular_client.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/job_assignment_service.dart';
import 'package:clmschedule/services/regular_client_matcher.dart';
import 'package:clmschedule/shareable_maps/models/map_layer.dart';
import 'package:clmschedule/shareable_maps/models/shareable_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class _FakeSchedule extends Fake implements ScheduleProvider {
  _FakeSchedule(this.distributors, this._jobs);

  @override
  final List<Distributor> distributors;
  final List<Job> _jobs;

  @override
  List<Job> getJobsForDate(DateTime date) => _jobs
      .where((j) =>
          j.date.year == date.year &&
          j.date.month == date.month &&
          j.date.day == date.day)
      .toList();
}

CustomPolygon _poly(String id, double o) => CustomPolygon(
      id: id,
      name: 'Area $id',
      description: '',
      points: [LatLng(o, o), LatLng(o + 1, o), LatLng(o, o + 1)],
      color: Colors.blue,
    );

RegularClientSlot _slot(String id, List<List<String>> days) =>
    RegularClientSlot(
      id: id,
      label: 'Distributor $id',
      colorValue: 0xFF1E88E5,
      days: [for (final d in days) RegularClientDay(polygonIds: d)],
    );

RegularClient _plan(List<RegularClientSlot> slots,
        {String name = 'Pick n Pay Durbanville',
        List<String> aliases = const []}) =>
    RegularClient(
      id: 'rc',
      name: name,
      aliases: aliases,
      mapId: 'm',
      mapMonthKey: '10-2026',
      slots: slots,
    );

void main() {
  group('RegularClient', () {
    test('round-trips through its map', () {
      final plan = _plan([
        _slot('1', [
          ['p1', 'p2'],
          ['p3']
        ]),
      ], aliases: ['PnP Durbanville']);
      final back = RegularClient.fromMap('rc', plan.toMap());
      expect(back.name, plan.name);
      expect(back.aliases, ['PnP Durbanville']);
      expect(back.slots.single.days.map((d) => d.polygonIds), [
        ['p1', 'p2'],
        ['p3']
      ]);
      expect(back.totalManDays, 2);
    });

    test('holdings, unallocated and missing ids', () {
      final plan = _plan([
        _slot('1', [
          ['p1'],
          ['p2']
        ]),
        _slot('2', [
          ['p2', 'gone']
        ]),
      ]);
      expect(plan.holdingsOf('p2').map((h) => h.label),
          ['Distributor 1 · Day 2', 'Distributor 2 · Day 1']);
      expect(plan.unallocatedIds(['p1', 'p2', 'p3']), ['p3']);
      expect(plan.missingIds(['p1', 'p2', 'p3']), {'gone'});
    });

    test('togglePolygon adds then removes', () {
      final plan = _plan([
        _slot('1', [[]])
      ]);
      final added = plan.togglePolygon('1', 0, 'p1');
      expect(added.holdingsOf('p1'), hasLength(1));
      expect(added.togglePolygon('1', 0, 'p1').holdingsOf('p1'), isEmpty);
    });

    test('newSlot numbers past existing labels and picks an unused colour', () {
      final plan = _plan([
        RegularClientSlot(
          id: 'a',
          label: 'Distributor 1',
          colorValue: kRegularClientSlotPalette[0].toARGB32(),
        ),
      ]);
      final s = plan.newSlot();
      expect(s.label, 'Distributor 2');
      expect(s.colorValue, kRegularClientSlotPalette[1].toARGB32());
    });
  });

  group('RegularClientMatcher', () {
    final all = [
      _plan(const [], name: 'Pick n Pay Durbanville'),
      RegularClient(
          id: 'spar',
          name: 'Spar Bellville',
          aliases: const ['SuperSpar Tyger Valley'],
          mapId: 'm',
          mapMonthKey: 'k'),
    ];

    test('exact name ignores case and punctuation', () {
      expect(RegularClientMatcher.bestMatch('pick-n-pay durbanville', all)?.id,
          'rc');
    });
    test('alias matches', () {
      expect(RegularClientMatcher.bestMatch('Superspar Tyger Valley', all)?.id,
          'spar');
    });
    test('containment matches', () {
      expect(RegularClientMatcher.bestMatch('Spar Bellville North', all)?.id,
          'spar');
    });
    test('shared words match', () {
      expect(RegularClientMatcher.bestMatch('Durbanville Pick n Pay', all)?.id,
          'rc');
    });
    test('unrelated name does not match', () {
      expect(RegularClientMatcher.bestMatch('Woolworths Claremont', all),
          isNull);
      expect(RegularClientMatcher.bestMatch('', all), isNull);
    });
  });

  group('calculateRegularClientAssignments', () {
    final day = DateTime(2026, 10, 7);
    final distributors = [
      Distributor(id: 'a', name: 'Anna', index: 0),
      Distributor(id: 'b', name: 'Ben', index: 1),
      Distributor(id: 'c', name: 'Cara', index: 2),
    ];
    final map = ShareableMap(
      id: 'm',
      name: 'Map',
      defaultCenter: const LatLng(0, 0),
      createdAt: day,
      updatedAt: day,
      layers: [
        MapLayer.create(name: 'L').copyWith(polygons: [
          _poly('p1', 0),
          _poly('p2', 2),
          _poly('p3', 4),
        ]),
      ],
    );
    Job busy(String id, DateTime date) => Job(
          id: 'job-$id',
          clients: const ['Existing'],
          workingAreas: const ['Area'],
          workMaps: const [],
          distributorId: id,
          date: date,
          statusId: 'logged',
        );

    test('one row per slot-day, same distributor across days, own areas', () {
      final service = JobAssignmentService(_FakeSchedule(distributors, []));
      final out = service.calculateRegularClientAssignments(
        client: 'PnP',
        plan: _plan([
          _slot('1', [
            ['p1'],
            ['p2']
          ]),
          _slot('2', [
            ['p2', 'p3']
          ]),
        ]),
        map: map,
        startDate: day,
      );
      expect(out, hasLength(3));
      expect(out[0].label, 'Distributor 1 · Day 1');
      expect(out[0].date, day);
      expect(out[1].date, DateTime(2026, 10, 8));
      expect(out[0].distributorId, out[1].distributorId);
      expect(out[0].workMaps.map((p) => p.id), ['p1']);
      expect(out[1].workMaps.map((p) => p.id), ['p2']);
      // Slot 2 shares p2 with slot 1, and gets its own copy on day 1 with
      // someone other than slot 1's distributor.
      expect(out[2].date, day);
      expect(out[2].distributorId, isNot(out[0].distributorId));
      expect(out[2].workMaps.map((p) => p.id), ['p2', 'p3']);
      expect(out[2].workingArea, 'Area p2, Area p3');
    });

    test('a busy distributor is swapped for a free one, then kept', () {
      final service = JobAssignmentService(
          _FakeSchedule(distributors, [busy('a', day)]));
      final out = service.calculateRegularClientAssignments(
        client: 'PnP',
        plan: _plan([
          _slot('1', [
            ['p1'],
            ['p2']
          ]),
        ]),
        map: map,
        startDate: day,
      );
      expect(out.map((a) => a.distributorId), ['b', 'b']);
    });

    test('spills to the next day when nobody is free', () {
      final service = JobAssignmentService(_FakeSchedule(
          [distributors.first], [busy('a', day)]));
      final out = service.calculateRegularClientAssignments(
        client: 'PnP',
        plan: _plan([
          _slot('1', [
            ['p1']
          ]),
        ]),
        map: map,
        startDate: day,
      );
      expect(out.single.date, DateTime(2026, 10, 8));
    });

    test('areas missing from the map are skipped', () {
      final service = JobAssignmentService(_FakeSchedule(distributors, []));
      final out = service.calculateRegularClientAssignments(
        client: 'PnP',
        plan: _plan([
          _slot('1', [
            ['p1', 'gone']
          ]),
        ]),
        map: map,
        startDate: day,
      );
      expect(out.single.workMaps.map((p) => p.id), ['p1']);
    });

    test('nobody eligible returns empty', () {
      final service = JobAssignmentService(_FakeSchedule(const [], const []));
      expect(
        service.calculateRegularClientAssignments(
          client: 'PnP',
          plan: _plan([
            _slot('1', [
              ['p1']
            ]),
          ]),
          map: map,
          startDate: day,
        ),
        isEmpty,
      );
    });
  });
}
