import 'dart:convert';

// Schedule → dropsheet sync: which task each schedule job becomes and where
// it lands. A distributor with the Driver role can't be dropped off, so their
// job becomes a Distribute task on their own driver section.
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/custom_polygon.dart';

import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/dropsheet_day.dart';
import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/dropsheet_provider.dart';
import 'package:clmschedule/utils/dropsheet_maps.dart';

final _date = DateTime(2026, 9, 30);

Job _job(String id, String distributorId, String area) => Job(
      id: id,
      clients: const ['Client'],
      workingAreas: [area],
      workMaps: const [],
      distributorId: distributorId,
      date: _date,
      statusId: 'scheduled',
    );

final _thabo = Distributor(id: 'dThabo', name: 'Thabo', index: 1);
final _sipho = Distributor(
    id: 'dSipho', name: 'Sipho', index: 2, role: DistributorRole.driver);

DropsheetDriverSection _driver(String name, List<DropsheetTask> tasks) =>
    DropsheetDriverSection(
      id: 's_$name',
      driverId: 'drv_$name',
      driverName: name,
      tasks: tasks,
    );

const _arrive = DropsheetTask(
    id: 'arr',
    type: DropsheetTaskType.arrive,
    job: 'Arrive',
    isMandatory: true);

List<DropsheetTask> _tasksIn(DropsheetDay day, String sectionId) =>
    day.sections.firstWhere((s) => s.id == sectionId).tasks;

DropsheetDay _sync(DropsheetDay day, List<Job> jobs) =>
    DropsheetProvider.computeSyncedDayForTest(day, jobs, [_thabo, _sipho]);

void main() {
  test('a normal distributor gets a drop-off in Unassigned', () {
    final out =
        _sync(DropsheetDay(date: _date), [_job('j1', 'dThabo', 'Woodstock')]);
    final t = _tasksIn(out, kUnassignedSectionId).single;
    expect(t.type, DropsheetTaskType.dropOff);
    expect(t.job, 'Drop off: Woodstock');
    expect(t.details, '', reason: 'name lives in contact, not notes');
    expect(t.contact, 'Thabo');
  });

  test('a driver-distributor gets Distribute on their own section', () {
    final day = DropsheetDay(date: _date, sections: [
      _driver('Sipho', [_arrive])
    ]);
    final out = _sync(day, [_job('j2', 'dSipho', 'Observatory')]);
    final tasks = _tasksIn(out, 's_Sipho');
    expect(tasks.map((t) => t.type),
        [DropsheetTaskType.distribute, DropsheetTaskType.arrive]);
    expect(tasks.first.job, 'Distribute: Observatory');
    expect(out.sections.any((s) => s.id == kUnassignedSectionId), isFalse);
  });

  test('a driver-distributor without a section waits in Unassigned', () {
    final out =
        _sync(DropsheetDay(date: _date), [_job('j2', 'dSipho', 'Observatory')]);
    expect(_tasksIn(out, kUnassignedSectionId).single.type,
        DropsheetTaskType.distribute);
  });

  test('an existing drop-off for a driver converts and moves to their section',
      () {
    const legacy = DropsheetTask(
      id: 'old',
      type: DropsheetTaskType.dropOff,
      job: 'Drop off: Observatory',
      details: 'Sipho',
      contact: 'Sipho',
      typeData: {
        'distributorJobId': 'j2',
        'distributorId': 'dSipho',
        'distributorName': 'Sipho',
        'workArea': 'Observatory',
      },
    );
    final day = DropsheetDay(date: _date, sections: [
      const DropsheetDriverSection(
        id: kUnassignedSectionId,
        driverId: kUnassignedSectionId,
        driverName: 'Unassigned stops',
        tasks: [legacy],
      ),
      _driver('Sipho', [_arrive]),
    ]);
    final out = _sync(day, [_job('j2', 'dSipho', 'Observatory')]);
    expect(_tasksIn(out, kUnassignedSectionId), isEmpty);
    final moved = _tasksIn(out, 's_Sipho').first;
    expect(moved.id, 'old');
    expect(moved.type, DropsheetTaskType.distribute);
    expect(moved.job, 'Distribute: Observatory');
    expect(moved.notes, '', reason: 'legacy auto-filled name hidden');
    expect(moved.details, 'Sipho',
        reason: 'stored text untouched, so old clients never fight over it');
  });

  test('user notes and wording survive a re-sync', () {
    const edited = DropsheetTask(
      id: 'e1',
      type: DropsheetTaskType.dropOff,
      job: 'Drop Thabo at the garage',
      details: '3 boxes, gate code 1234',
      contact: 'Thabo',
      typeData: {
        'distributorJobId': 'j1',
        'distributorId': 'dThabo',
        'distributorName': 'Thabo',
        'workArea': 'Woodstock',
        DropsheetTask.kUserEditedKey: true,
      },
    );
    final day = DropsheetDay(date: _date, sections: [
      _driver('Mike', [edited, _arrive])
    ]);
    final out = _sync(day, [_job('j1', 'dThabo', 'Woodstock')]);
    final t = _tasksIn(out, 's_Mike').first;
    expect(t.job, 'Drop Thabo at the garage');
    expect(t.details, '3 boxes, gate code 1234');
  });

  test('duplicate drop-offs for one job collapse to the driver copy', () {
    DropsheetTask copy(String id) => DropsheetTask(
          id: id,
          type: DropsheetTaskType.dropOff,
          typeData: const {'distributorJobId': 'j1', 'workArea': 'Woodstock'},
        );
    final day = DropsheetDay(date: _date, sections: [
      DropsheetDriverSection(
        id: kUnassignedSectionId,
        driverId: kUnassignedSectionId,
        driverName: 'Unassigned stops',
        tasks: [copy('auto')],
      ),
      _driver('Mike', [copy('manual'), _arrive]),
    ]);
    final out = _sync(day, [_job('j1', 'dThabo', 'Woodstock')]);
    expect(_tasksIn(out, kUnassignedSectionId), isEmpty);
    expect(_tasksIn(out, 's_Mike').map((t) => t.id), ['manual', 'arr']);
  });

  test('re-syncing is stable (no repeated tasks)', () {
    var day = DropsheetDay(date: _date, sections: [
      _driver('Sipho', [_arrive])
    ]);
    final jobs = [
      _job('j1', 'dThabo', 'Woodstock'),
      _job('j2', 'dSipho', 'Observatory'),
    ];
    for (var i = 0; i < 5; i++) {
      day = DropsheetDay.fromMap(day.docId, _roundTrip(_sync(day, jobs)));
    }
    expect(_tasksIn(day, 's_Sipho').map((t) => t.type),
        [DropsheetTaskType.distribute, DropsheetTaskType.arrive]);
    expect(
        _tasksIn(day, kUnassignedSectionId)
            .where((t) => t.type == DropsheetTaskType.dropOff),
        hasLength(1));
  });

  test('distribute is stored as a flagged dropOff that older builds accept',
      () {
    const t = DropsheetTask(
      id: 'x',
      type: DropsheetTaskType.distribute,
      typeData: {'distributorJobId': 'j2'},
    );
    final stored = t.toMap();
    expect(stored['type'], 'dropOff');
    expect((stored['typeData'] as Map)[DropsheetTask.kDistributeKey], isTrue);
    final back = DropsheetTask.fromMap(stored);
    expect(back.type, DropsheetTaskType.distribute);
    expect(back.typeData.containsKey(DropsheetTask.kDistributeKey), isFalse);
  });

  test('copies an older build saved as custom collapse back to one', () {
    Map<String, dynamic> corrupted(String id) => {
          'id': id,
          'type': 'custom',
          'job': 'Distribute: Observatory',
          'contact': 'Sipho',
          'typeData': {
            'distributorJobId': 'j2',
            'distributorId': 'dSipho',
            'distributorName': 'Sipho',
            'workArea': 'Observatory',
          },
        };
    final day = DropsheetDay(date: _date, sections: [
      _driver('Sipho', [
        for (var i = 0; i < 20; i++) DropsheetTask.fromMap(corrupted('c$i')),
        _arrive,
      ]),
    ]);
    final out = _sync(day, [_job('j2', 'dSipho', 'Observatory')]);
    final tasks = _tasksIn(out, 's_Sipho');
    expect(tasks.map((t) => t.id), ['c0', 'arr']);
    expect(tasks.first.type, DropsheetTaskType.distribute);
  });

  test('an unknown distributor never flips distribute back to drop-off', () {
    const t = DropsheetTask(
      id: 'k',
      type: DropsheetTaskType.distribute,
      typeData: {'distributorJobId': 'j9', 'workArea': 'Pinelands'},
    );
    final day = DropsheetDay(date: _date, sections: [
      _driver('Sipho', [t, _arrive])
    ]);
    // Distributor 'dGhost' is not in the list (partial / loading cache).
    final out = _sync(day, [_job('j9', 'dGhost', 'Pinelands')]);
    expect(_tasksIn(out, 's_Sipho').first.type, DropsheetTaskType.distribute);
  });

  test('an old build\'s "Drop off" label is left alone and shown as Distribute',
      () {
    const t = DropsheetTask(
      id: 'k',
      type: DropsheetTaskType.distribute,
      job: 'Drop off: Observatory',
      typeData: {'distributorJobId': 'j2', 'workArea': 'Observatory'},
    );
    final day = DropsheetDay(date: _date, sections: [
      _driver('Sipho', [t, _arrive])
    ]);
    final out = _sync(day, [_job('j2', 'dSipho', 'Observatory')]);
    final synced = _tasksIn(out, 's_Sipho').first;
    expect(synced.job, 'Drop off: Observatory', reason: 'no rewrite war');
    expect(synced.displayJob, 'Distribute: Observatory');
  });

  test('only jobs without work-area polygons are marked point-only', () {
    final withPolygon = _job('j1', 'dThabo', 'Woodstock').copyWith(workMaps: [
      const CustomPolygon(
          name: 'Woodstock',
          description: '',
          points: [],
          color: Color(0xFF2196F3))
    ]);
    final pointOnly = _job('j3', 'dThabo', 'Salt River');
    final out = _sync(DropsheetDay(date: _date), [withPolygon, pointOnly]);
    final byJob = {
      for (final t in _tasksIn(out, kUnassignedSectionId))
        t.typeData['distributorJobId']: t.typeData[DropsheetTask.kPointOnlyKey],
    };
    expect(byJob, {'j1': false, 'j3': true});
  });

  test('"To be assigned" never reaches the dropsheet label', () {
    final out = _sync(
        DropsheetDay(date: _date), [_job('j4', 'dThabo', 'To be assigned')]);
    final t = _tasksIn(out, kUnassignedSectionId).single;
    expect(t.job, 'Drop off');
    expect(t.typeData['workArea'], '');
  });

  test('a stale "To be assigned" pick-up follows its now-named point job', () {
    const stale = DropsheetTask(
      id: 'pu',
      type: DropsheetTaskType.pickUp,
      job: 'Pick up: To be assigned',
      details: 'Thabo',
      location: 'To be assigned',
      contact: 'Thabo',
      typeData: {
        'distributorJobId': 'j5',
        'distributorId': 'dThabo',
        'distributorName': 'Thabo',
        'workArea': 'To be assigned',
        'lat': -34.02,
        'lng': 18.44,
      },
    );
    final day = DropsheetDay(date: _date, sections: [
      _driver('Mike', [stale, _arrive])
    ]);
    // The schedule job has since been named after its street corner and has
    // only a point (no polygons).
    final out =
        _sync(day, [_job('j5', 'dThabo', 'Constantia Main Rd & Alphen Dr')]);
    final t = _tasksIn(out, 's_Mike').firstWhere((t) => t.id == 'pu');
    expect(t.job, 'Pick up: Constantia Main Rd & Alphen Dr');
    expect(t.typeData['workArea'], 'Constantia Main Rd & Alphen Dr');
    expect(t.typeData[DropsheetTask.kPointOnlyKey], isTrue);
    expect(DropsheetMaps.locationLabel(t), 'Constantia Main Rd & Alphen Dr');
    expect(t.typeData['lat'], -34.02, reason: 'coordinates untouched');
  });

  test('Location never falls back to the distributor name', () {
    const t = DropsheetTask(
      id: 'x',
      type: DropsheetTaskType.pickUp,
      location: 'To be assigned',
      typeData: {'distributorName': 'Mandla', 'workArea': 'To be assigned'},
    );
    expect(DropsheetMaps.locationLabel(t), '');
  });
}

Map<String, dynamic> _roundTrip(DropsheetDay d) =>
    jsonDecode(jsonEncode(d.toMap())) as Map<String, dynamic>;
