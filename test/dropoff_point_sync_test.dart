// One drop-off point across the screens that show it: the work-area map
// editor and print map (dropoff point in Job.workMaps), the day planner
// (Job.dropOffPoint) and the dropsheet (task typeData lat/lng). A drag on any
// of them must win and reach the others.
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/dropsheet_day.dart';
import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/dropsheet_provider.dart';
import 'package:clmschedule/providers/schedule_provider.dart';

final _date = DateTime(2026, 10, 21);
const _old = LatLng(-33.90, 18.40);
const _new = LatLng(-33.91, 18.41);

const _area = CustomPolygon(
  name: 'Woodstock',
  description: '',
  points: [
    LatLng(-33.80, 18.30),
    LatLng(-33.80, 18.50),
    LatLng(-34.00, 18.50),
    LatLng(-34.00, 18.30),
  ],
  color: Colors.blue,
);

CustomPolygon _dropPin(LatLng p) => CustomPolygon(
      name: 'Drop-off Point',
      description: '',
      points: [p],
      color: Colors.blue,
      type: MapElementType.point,
      pointCategory: PointCategory.dropoff,
    );

Job _job({LatLng? drop, LatLng? pin, LatLng? pickUp}) => Job(
      id: 'j1',
      clients: const ['Client'],
      workingAreas: const ['Woodstock'],
      workMaps: [_area, if (pin != null) _dropPin(pin)],
      distributorId: 'd1',
      date: _date,
      statusId: 'scheduled',
      dropOffPoint: drop,
      pickUpPoint: pickUp,
    );

LatLng? _pinOf(Job j) => j.workMaps
    .where((w) => w.isPoint && w.pointCategory == PointCategory.dropoff)
    .firstOrNull
    ?.points
    .first;

DropsheetTask _task(String id, DropsheetTaskType type, LatLng at,
        {bool pinned = false}) =>
    DropsheetTask(id: id, type: type, typeData: {
      'distributorJobId': 'j1',
      'distributorId': 'd1',
      'workArea': 'Woodstock',
      'lat': at.latitude,
      'lng': at.longitude,
      'eta': '08:30',
      'legDurationS': 600,
      if (pinned) 'workAreaPin': true,
    });

DropsheetDay _day(List<DropsheetTask> tasks) => DropsheetDay(
      date: _date,
      sections: [
        DropsheetDriverSection(
          id: 's1',
          driverId: 'drv1',
          driverName: 'Petros',
          tasks: tasks,
          routePolyline: const [_old, _new],
        ),
      ],
    );

LatLng _at(DropsheetTask t) => LatLng(
    (t.typeData['lat'] as num).toDouble(),
    (t.typeData['lng'] as num).toDouble());

void main() {
  group('normalising a saved job', () {
    test('a pin dragged in the map editor wins over the old dropOffPoint', () {
      final before = _job(drop: _old, pin: _old);
      final edited = _job(drop: _old, pin: _new); // editor moved the pin only
      final out = ScheduleProvider.normalizeDropOffPointForTest(edited,
          previous: before);
      expect(out.dropOffPoint, _new);
      expect(_pinOf(out), _new);
    });

    test('a day-planner drag (dropOffPoint only) moves the map pin', () {
      final before = _job(drop: _old, pin: _old);
      final edited = _job(drop: _new, pin: _old);
      final out = ScheduleProvider.normalizeDropOffPointForTest(edited,
          previous: before);
      expect(out.dropOffPoint, _new);
      expect(_pinOf(out), _new);
    });
  });

  group('moving the dropsheet tasks to the job', () {
    test('drop-off moves, loses its ETA, and the route line is cleared', () {
      final out = DropsheetProvider.withJobCoordsForTest(
          _day([_task('t1', DropsheetTaskType.dropOff, _old)]),
          _job(drop: _new, pin: _new))!;
      final t = out.sections.single.tasks.single;
      expect(_at(t), _new);
      expect(t.typeData.containsKey('eta'), isFalse);
      expect(t.typeData.containsKey('legDurationS'), isFalse);
      expect(out.sections.single.routePolyline, isEmpty);
    });

    test('a pick-up without its own point follows the drop-off', () {
      final out = DropsheetProvider.withJobCoordsForTest(
          _day([_task('p1', DropsheetTaskType.pickUp, _old)]),
          _job(drop: _new, pin: _new))!;
      expect(_at(out.sections.single.tasks.single), _new);
    });

    test('a pick-up with its own point stays there', () {
      const own = LatLng(-33.95, 18.45);
      final out = DropsheetProvider.withJobCoordsForTest(
          _day([
            _task('t1', DropsheetTaskType.dropOff, _old),
            _task('p1', DropsheetTaskType.pickUp, own),
          ]),
          _job(drop: _new, pin: _new, pickUp: own))!;
      expect(_at(out.sections.single.tasks[1]), own);
    });

    test('per-area pinned drop-offs keep their own spot', () {
      final day = _day([
        _task('t1', DropsheetTaskType.dropOff, _old, pinned: true),
      ]);
      expect(
          DropsheetProvider.withJobCoordsForTest(
              day, _job(drop: _new, pin: _new)),
          isNull);
    });

    test('nothing to write when the tasks are already there', () {
      final day = _day([_task('t1', DropsheetTaskType.dropOff, _new)]);
      expect(
          DropsheetProvider.withJobCoordsForTest(
              day, _job(drop: _new, pin: _new)),
          isNull);
    });
  });

  group('schedule sync (other devices)', () {
    final dist = Distributor(id: 'd1', name: 'Thabo', index: 1);

    test('moves drop-off and pick-up to the job and clears stale timings', () {
      final out = DropsheetProvider.computeSyncedDayForTest(
        _day([
          _task('t1', DropsheetTaskType.dropOff, _old),
          _task('p1', DropsheetTaskType.pickUp, _old),
        ]),
        [_job(drop: _new, pin: _new)],
        [dist],
      );
      final tasks = out.sections.firstWhere((s) => s.id == 's1').tasks;
      expect(tasks.map(_at), [_new, _new]);
      expect(tasks.every((t) => !t.typeData.containsKey('eta')), isTrue);
      expect(out.sections.firstWhere((s) => s.id == 's1').routePolyline,
          isEmpty);
    });

    test("a pick-up whose job left the day moves to the distributor's other job",
        () {
      final other = Job(
        id: 'j2',
        clients: const ['Client'],
        workingAreas: const ['Observatory'],
        workMaps: const [_area],
        distributorId: 'd1',
        date: _date,
        statusId: 'scheduled',
        dropOffPoint: _new,
      );
      final pickUp = _task('p1', DropsheetTaskType.pickUp, _old); // job j1
      final out = DropsheetProvider.computeSyncedDayForTest(
        _day([pickUp]),
        [other], // j1 is gone; Thabo still works j2
        [dist],
      );
      final t = out.sections.firstWhere((s) => s.id == 's1').tasks.single;
      expect(t.typeData['distributorJobId'], 'j2');
      expect(_at(t), _new);
    });

    test('a pick-up whose distributor has no job left on the day goes', () {
      final out = DropsheetProvider.computeSyncedDayForTest(
        _day([_task('p1', DropsheetTaskType.pickUp, _old)]),
        const [],
        [dist],
      );
      expect(out.sections.firstWhere((s) => s.id == 's1').tasks, isEmpty);
    });

    test('an unmoved sheet keeps its ETAs and route', () {
      final out = DropsheetProvider.computeSyncedDayForTest(
        _day([_task('t1', DropsheetTaskType.dropOff, _new)]),
        [_job(drop: _new, pin: _new)],
        [dist],
      );
      final s = out.sections.firstWhere((s) => s.id == 's1');
      expect(s.tasks.single.typeData['eta'], '08:30');
      expect(s.routePolyline, isNotEmpty);
    });
  });
}
