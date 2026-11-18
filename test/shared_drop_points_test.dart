// Shared drop points: one driver drops several distributors at one spot to
// save fuel. Stops within 100 m count as one point on the map and are flagged
// on the dropsheet.
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/dropsheet_day.dart';
import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/utils/shared_drop_points.dart';
import 'package:clmschedule/widgets/day_planner/day_planner_palette.dart';

const _spot = LatLng(-33.9000, 18.4000);
// ~55 m and ~330 m north of [_spot].
const _near = LatLng(-33.8995, 18.4000);
const _far = LatLng(-33.8970, 18.4000);

DropsheetTask _stop(String id, String name, LatLng at,
        {DropsheetTaskType type = DropsheetTaskType.dropOff}) =>
    DropsheetTask(id: id, type: type, contact: name, typeData: {
      'distributorJobId': 'j_$id',
      'distributorName': name,
      'lat': at.latitude,
      'lng': at.longitude,
    });

/// A Job List job on the dropsheet, e.g. "Window Cleaning: Martin".
DropsheetTask _job(String id, String jobType, String client, LatLng at) =>
    DropsheetTask(
        id: id,
        type: DropsheetTaskType.custom,
        job: 'Window Cleaning: $client',
        contact: client,
        sourceJobListItemId: 'item_$id',
        typeData: {
          'jobType': jobType,
          'client': client,
          'lat': at.latitude,
          'lng': at.longitude,
        });

DropsheetDriverSection _run(List<DropsheetTask> tasks, {String id = 's1'}) =>
    DropsheetDriverSection(
        id: id, driverId: 'd_$id', driverName: 'Petros', tasks: tasks);

void main() {
  test('Own transport: no stop numbers, no shared points, no Arrive row', () {
    final own = _run([
      _stop('a', 'Thabo', _spot),
      _stop('b', 'Sipho', _near),
    ], id: kOwnTransportSectionId);
    expect(stopNumbersFor(own), isEmpty);
    expect(sharedStopsInSection(own), isEmpty);
    final reloaded = DropsheetDriverSection.fromMap(own.toMap());
    expect(reloaded.tasks.map((t) => t.id), ['a', 'b']);
    // A driver's section still gets its Arrive row back on read.
    final driver = DropsheetDriverSection.fromMap(_run(const []).toMap());
    expect(driver.tasks.single.type, DropsheetTaskType.arrive);
  });

  test('stop numbers skip fixed rows; pick-ups count again from 1', () {
    const fixed = DropsheetTask(
        id: 'i', type: DropsheetTaskType.inspect, isMandatory: true);
    final run = _run([
      fixed,
      _stop('a', 'Thabo', _spot),
      const DropsheetTask(id: 'x', type: DropsheetTaskType.custom), // no point
      _stop('b', 'Sipho', _far),
      _stop('p', 'Thabo', _spot, type: DropsheetTaskType.pickUp),
    ]);
    expect(stopNumbersFor(run), {'a': 1, 'b': 2, 'p': 1});
  });

  test('the planner leaves out stops whose schedule job is gone', () {
    final job = Job(
      id: 'j_a',
      clients: const ['Client'],
      workingAreas: const ['Woodstock'],
      workMaps: const [],
      distributorId: 'd1',
      date: DateTime(2026, 10, 21),
      statusId: 'scheduled',
      dropOffPoint: _near,
    );
    final live = _stop('a', 'Thabo', _spot); // job j_a
    final orphan = _stop('b', 'Sipho', _spot); // job j_b — not on the day
    final jobs = {job.id: job};
    expect(plannerStops(live, jobs).single.position, _near,
        reason: "pinned at the job's live point");
    expect(plannerStops(orphan, jobs), isEmpty);
    expect(
        stopNumbersFor(_run([orphan, live]),
            stopCount: (t) => plannerStops(t, jobs).length),
        {'a': 1});
  });

  test('distanceMeters is about right', () {
    expect(distanceMeters(_spot, _near), closeTo(55, 3));
    expect(distanceMeters(_spot, _far), closeTo(333, 5));
  });

  test('stops within 100 m share a point; further ones do not', () {
    final shared = sharedStopsInSection(_run([
      _stop('a', 'Thabo', _spot),
      _stop('b', 'Sipho', _near),
      _stop('c', 'Lindiwe', _far),
    ]));
    expect(shared.keys, unorderedEquals(['a', 'b']));
    expect(shared['a']!.map((t) => t.id), ['a', 'b']);
  });

  test('the note names the others at the point', () {
    final run = _run([
      _stop('a', 'Thabo', _spot),
      _stop('b', 'Sipho', _spot),
      _stop('c', 'Lindiwe', _spot),
    ]);
    final shared = sharedStopsInSection(run);
    expect(sharedStopNote(run.tasks[0], shared),
        'Same drop point as Sipho, Lindiwe');
    expect(sharedStopNote(run.tasks[1], shared),
        'Same drop point as Thabo, Lindiwe');
  });

  test('a drop-off and a pick-up at one spot are not a shared point', () {
    final shared = sharedStopsInSection(_run([
      _stop('a', 'Thabo', _spot),
      _stop('b', 'Thabo', _spot, type: DropsheetTaskType.pickUp),
    ]));
    expect(shared, isEmpty);
  });

  test('pick-ups share too, and say so', () {
    final run = _run([
      _stop('a', 'Thabo', _spot, type: DropsheetTaskType.pickUp),
      _stop('b', 'Sipho', _near, type: DropsheetTaskType.pickUp),
    ]);
    expect(sharedStopNote(run.tasks[0], sharedStopsInSection(run)),
        'Same pick-up point as Sipho');
  });

  test('different drivers at one spot are separate runs', () {
    final day = DropsheetDay(date: DateTime(2026, 10, 21), sections: [
      _run([_stop('a', 'Thabo', _spot)], id: 's1'),
      _run([_stop('b', 'Sipho', _spot)], id: 's2'),
    ]);
    expect(sharedStopsByTaskId(day), isEmpty);
  });

  test('a driver distributing himself is not a shared drop', () {
    final shared = sharedStopsInSection(_run([
      _stop('a', 'Thabo', _spot),
      _stop('b', 'Sipho', _spot, type: DropsheetTaskType.distribute),
    ]));
    expect(shared, isEmpty);
  });

  test('stops without a coordinate never share', () {
    final shared = sharedStopsInSection(_run([
      _stop('a', 'Thabo', _spot),
      const DropsheetTask(
          id: 'b', type: DropsheetTaskType.dropOff, contact: 'Sipho'),
    ]));
    expect(shared, isEmpty);
  });

  group('a drop-off dragged outside its own area', () {
    const area = CustomPolygon(
      name: 'Woodstock',
      description: '',
      points: [
        LatLng(-33.95, 18.45),
        LatLng(-33.95, 18.46),
        LatLng(-33.96, 18.46),
        LatLng(-33.96, 18.45),
      ],
      color: Colors.blue,
    );
    Job job(LatLng? drop) => Job(
          id: 'j1',
          clients: const ['Client'],
          workingAreas: const ['Woodstock'],
          workMaps: const [area],
          distributorId: 'd1',
          date: DateTime(2026, 10, 21),
          statusId: 'scheduled',
          dropOffPoint: drop,
        );

    test('sticks (stored as the drop-off map point)', () {
      const inside = LatLng(-33.955, 18.455);
      final out = ScheduleProvider.normalizeDropOffPointForTest(job(_spot),
          previous: job(inside));
      expect(out.dropOffPoint, _spot);
      final pin = out.workMaps.where(
          (w) => w.isPoint && w.pointCategory == PointCategory.dropoff);
      expect(pin.single.points.single, _spot);
      // A later unrelated save keeps it.
      final again =
          ScheduleProvider.normalizeDropOffPointForTest(out, previous: out);
      expect(again.dropOffPoint, _spot);
    });
  });

  group('job sites (Junk & Stuff / Happy Sun)', () {
    final run = _run([
      const DropsheetTask(
          id: 'i', type: DropsheetTaskType.inspect, isMandatory: true),
      _stop('h', 'Hakizimana', _far),
      _stop('t', 'Talent', _near),
      _stop('g', 'Gift', _near),
      _stop('p', 'Petros', _spot, type: DropsheetTaskType.distribute),
      _job('w', 'windowCleaning', 'Martin Vanlierde', _spot),
      _stop('tp', 'Talent', _near, type: DropsheetTaskType.pickUp),
    ]);

    test('crew within 100 m list under the job, the driver included', () {
      final sites = jobSitesInSection(run);
      expect(sites.keys.toSet(), {'t', 'g', 'p', 'w'});
      expect(sites['w']!.crew.map((t) => t.id), ['t', 'g', 'p']);
      expect(jobSiteNote(run.tasks[5], sites),
          'Crew: Talent, Gift, Petros (driver)');
      expect(jobSiteNote(run.tasks[2], sites),
          'Crew for Window Cleaning: Martin Vanlierde');
      expect(jobSiteNote(run.tasks[1], sites), isNull);
    });

    test('is one stop number, and its crew is no shared drop point', () {
      expect(stopNumbersFor(run),
          {'h': 1, 't': 2, 'g': 2, 'p': 2, 'w': 2, 'tp': 1});
      expect(sharedStopsInSection(run).containsKey('t'), isFalse);
    });

    test('CLM job-list tasks and lone jobs are not sites', () {
      final clm = _run([
        _stop('a', 'Thabo', _spot),
        _job('c', 'flyerDistribution', 'Spar', _spot),
      ]);
      expect(jobSitesInSection(clm), isEmpty);
      final lone = _run([
        _stop('a', 'Thabo', _far),
        _job('w', 'windowCleaning', 'Martin', _spot),
      ]);
      expect(jobSitesInSection(lone), isEmpty);
    });
  });
}
