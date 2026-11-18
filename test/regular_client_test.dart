import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/regular_client.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/job_assignment_service.dart';
import 'package:clmschedule/services/regular_client_matcher.dart';
import 'package:clmschedule/services/regular_client_service.dart';
import 'package:clmschedule/shareable_maps/adapters/regular_client_map_adapter.dart';
import 'package:clmschedule/shareable_maps/services/shareable_maps_firestore_service.dart';
import 'package:clmschedule/shareable_maps/models/map_layer.dart';
import 'package:clmschedule/shareable_maps/models/map_point.dart';
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

/// The gallery: read-only. Any write to it is a Fake `noSuchMethod` and
/// fails the test — a real client's map must never be changed.
class _FakeMaps extends Fake implements ShareableMapsFirestoreService {
  _FakeMaps(this.stored);

  ShareableMap stored;

  @override
  Future<ShareableMap?> getMap(String monthKey, String docId) async => stored;
}

class _FakeRegularClients extends RegularClientService {
  final savedMaps = <ShareableMap>[];
  final savedPlans = <RegularClient>[];

  @override
  Future<void> saveMap(String id, ShareableMap map) async =>
      savedMaps.add(map);

  @override
  Future<void> save(RegularClient client) async => savedPlans.add(client);
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

    test('points are allocated like areas and go on the job as point pins',
        () {
      final pointMap = map.copyWith(layers: [
        map.layers.single.copyWith(points: [
          MapPoint(
            id: 'tl1',
            name: 'Traffic light Main Rd',
            position: const LatLng(9, 9),
            color: Colors.red,
            createdAt: day,
            updatedAt: day,
          ),
        ]),
      ]);
      final service = JobAssignmentService(_FakeSchedule(distributors, []));
      final out = service.calculateRegularClientAssignments(
        client: 'PnP',
        plan: _plan([
          _slot('1', [
            ['p1', 'tl1']
          ]),
        ]),
        map: pointMap,
        startDate: day,
      );
      final work = out.single.workMaps;
      expect(work.map((p) => p.id), ['p1', 'tl1']);
      expect(work.last.type, MapElementType.point);
      expect(work.last.points, [const LatLng(9, 9)]);
      expect(out.single.workingArea, 'Area p1, Traffic light Main Rd');

      // The editor lists the point as allocatable, found by its own id.
      final adapter = RegularClientMapAdapter(_plan(const []),
          service: _FakeRegularClients(), maps: _FakeMaps(pointMap));
      final areas = adapter.areasOf(pointMap);
      expect(areas.map((a) => (a.id, a.isPoint)),
          [('p1', false), ('p2', false), ('p3', false), ('tl1', true)]);
      expect(adapter.areaForElement(pointMap, 'tl1')?.isPoint, isTrue);
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

  group('RegularClientMapAdapter', () {
    final day = DateTime(2026, 10, 7);
    ShareableMap galleryMap() => ShareableMap(
          id: 'm',
          name: 'Gallery',
          defaultCenter: const LatLng(0, 0),
          createdAt: day,
          updatedAt: day,
          layers: [
            MapLayer.create(name: 'L').copyWith(polygons: [
              _poly('p1', 0).copyWith(description: 'own note'),
              _poly('p2', 2),
            ]),
          ],
        );

    RegularClient planOn(ShareableMap? own) => RegularClient(
          id: 'rc',
          name: 'Timbuild',
          mapId: 'm',
          mapMonthKey: '09-2026',
          mapName: 'Gallery',
          map: own,
          slots: [
            RegularClientSlot(
              id: '1',
              label: 'Distributor 1',
              colorValue: Colors.red.toARGB32(),
              days: const [
                RegularClientDay(polygonIds: ['p1'])
              ],
            ),
          ],
        );

    test('a plan without its own map copies the gallery map once, read-only',
        () async {
      final service = _FakeRegularClients();
      final adapter = RegularClientMapAdapter(planOn(null),
          service: service, maps: _FakeMaps(galleryMap()));

      await adapter.load();
      final copy = service.savedMaps.single;
      expect(copy.id, RegularClient.templateMapId);
      expect(copy.jobListItemId, isNull);
      expect(copy.layers.single.polygons.map((p) => p.id), ['p1', 'p2']);
      expect(adapter.client.map, isNotNull);
    });

    test('templateFrom drops the job link, folders and cloud layers', () {
      final source = galleryMap().copyWith(
        jobListItemId: 'job-1',
        storageFolderPath: 'Distribution/2026/09/Timbuild',
        cloudFolderPaths: ['Distribution/2026/09/Timbuild'],
        layers: [
          ...galleryMap().layers,
          MapLayer.create(name: 'Cloud tracks'),
        ],
      );
      final copy = RegularClient.templateFrom(source);
      expect(copy.jobListItemId, isNull);
      expect(copy.storageFolderPath, isNull);
      expect(copy.cloudFolderPaths, isEmpty);
      expect(copy.layers.map((l) => l.name), ['L']);
    });

    test('edits save to the client\'s own map with its colours, never the '
        'gallery', () async {
      final service = _FakeRegularClients();
      ShareableMap? reloaded;
      final adapter = RegularClientMapAdapter(
        planOn(RegularClient.templateFrom(galleryMap())),
        service: service,
        maps: _FakeMaps(galleryMap()),
        onReload: (m) => reloaded = m,
      );

      final shown = await adapter.load();
      expect(service.savedMaps, isEmpty); // already owned: no copy
      final shownPolys = shown.layers.single.polygons;
      expect(shownPolys[0].color.toARGB32(), Colors.red.toARGB32());
      expect(shownPolys[1].color, RegularClientMapAdapter.unallocatedColor);

      // Reshape p1 and draw a new polygon, as the editor would.
      final layer = shown.layers.single;
      final edited = shown.copyWith(layers: [
        layer.copyWith(polygons: [
          shownPolys[0].copyWith(
              points: [LatLng(0, 0), LatLng(5, 0), LatLng(0, 5)]),
          shownPolys[1],
          CustomPolygon(
            name: 'New',
            description: '',
            points: [LatLng(9, 9), LatLng(10, 9), LatLng(9, 10)],
            color: Colors.green,
          ),
        ]),
      ]);
      await adapter.save(edited);

      final saved = service.savedMaps.single.layers.single.polygons;
      expect(saved[0].points[1], const LatLng(5, 0));
      expect(saved[0].color.toARGB32(), Colors.blue.toARGB32());
      expect(saved[0].description, 'own note');
      expect(saved[1].color.toARGB32(), Colors.blue.toARGB32());
      expect(saved[2].id, isNotEmpty);
      expect(saved[2].color.toARGB32(), Colors.green.toARGB32());

      // The new polygon's id reaches the editor, styled as unallocated.
      final back = reloaded!.layers.single.polygons;
      expect(back[2].id, saved[2].id);
      expect(back[2].color, RegularClientMapAdapter.unallocatedColor);
      expect(adapter.areasOf(reloaded).map((a) => a.id),
          ['p1', 'p2', saved[2].id]);
    });

    test('a plan round-trips its own map', () {
      final plan = planOn(RegularClient.templateFrom(galleryMap()));
      final data = {
        ...plan.toMap(),
        'map': RegularClient.mapToFirestore(plan.map!),
      };
      expect(plan.toMap().containsKey('map'), isFalse);
      final back = RegularClient.fromMap('rc', data);
      expect(back.map!.layers.single.polygons.map((p) => p.id), ['p1', 'p2']);
    });
  });
}
