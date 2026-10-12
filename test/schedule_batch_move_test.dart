import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/services/schedule_batch_move.dart';
import 'package:flutter/material.dart' show DateUtils;
import 'package:flutter_test/flutter_test.dart';

Distributor _dist(String id, int index,
        [DistributorStatus status = DistributorStatus.active]) =>
    Distributor(id: id, name: id, index: index, status: status);

Job _job(String id, String distributorId, DateTime date) => Job(
      id: id,
      clients: [id],
      workingAreas: const [],
      workMaps: const [],
      distributorId: distributorId,
      date: date,
      statusId: 'scheduled',
    );

void main() {
  final dists = [_dist('a', 0), _dist('b', 1), _dist('c', 2)];
  final oct7 = DateTime(2026, 10, 7);
  final oct8 = DateTime(2026, 10, 8);
  final end = DateTime(2026, 11, 30);

  BatchMovePlan plan(
    List<Job> jobs,
    List<Job> schedule, {
    Set<String> daysOff = const {},
    List<Distributor>? distributors,
  }) =>
      planBatchMove(
        jobs: jobs,
        distributors: distributors ?? dists,
        startDate: oct7,
        lastDate: end,
        occupiedOn: (d) => {
          for (final j in schedule)
            if (DateUtils.isSameDay(j.date, d)) j.distributorId,
        },
        isDayOff: (id, d) => daysOff.contains('$id|${d.day}'),
      );

  test('fills the free distributors of the day, lowest index first', () {
    final moving = [
      _job('j1', 'a', DateTime(2026, 10, 1)),
      _job('j2', 'b', DateTime(2026, 10, 1)),
    ];
    final p = plan(moving, [...moving, _job('x', 'a', oct7)]);
    expect(p.moved['j1']!.distributorId, 'b');
    expect(p.moved['j2']!.distributorId, 'c');
    expect(p.moved.values.every((j) => j.date == oct7), isTrue);
  });

  test('a full day spills to the next day', () {
    final moving = [
      for (var i = 0; i < 4; i++) _job('j$i', 'a', DateTime(2026, 10, 1 + i)),
    ];
    final p = plan(moving, moving);
    expect([for (var i = 0; i < 4; i++) p.moved['j$i']!.date],
        [oct7, oct7, oct7, oct8]);
    expect(p.moved['j3']!.distributorId, 'a');
  });

  test('days off and inactive distributors are skipped', () {
    final moving = [_job('j1', 'c', DateTime(2026, 10, 1))];
    final p = plan(
      moving,
      moving,
      daysOff: {'a|7'},
      distributors: [
        _dist('a', 0),
        _dist('b', 1, DistributorStatus.values.last),
        _dist('c', 2),
      ],
    );
    expect(p.moved['j1']!.distributorId, 'c');
  });

  test('slots the moving jobs leave are free for the batch', () {
    final moving = [_job('j1', 'a', oct7), _job('j2', 'b', oct7)];
    final p = plan(moving, [...moving, _job('x', 'c', oct7)]);
    expect(p.moved['j1']!.distributorId, 'a');
    expect(p.moved['j2']!.distributorId, 'b');
    expect(p.unplaced, isEmpty);
  });

  test('jobs with no room before the last date are reported unplaced', () {
    final moving = [_job('j1', 'a', DateTime(2026, 10, 1))];
    final full = [
      for (var d = 7; d <= 31; d++)
        for (final id in ['a', 'b', 'c'])
          _job('$id$d', id, DateTime(2026, 10, d)),
    ];
    final p = planBatchMove(
      jobs: moving,
      distributors: dists,
      startDate: oct7,
      lastDate: DateTime(2026, 10, 31),
      occupiedOn: (d) => {
        for (final j in full)
          if (DateUtils.isSameDay(j.date, d)) j.distributorId,
      },
      isDayOff: (_, __) => false,
    );
    expect(p.unplaced.single.id, 'j1');
  });

  test('moved jobs keep everything but distributor and date', () {
    final job = _job('j1', 'a', DateTime(2026, 10, 1))
        .copyWith(mapInstructions: 'Gate 4', clientInstructions: ['note']);
    final p = plan([job], [job]);
    expect(p.moved['j1']!.mapInstructions, 'Gate 4');
    expect(p.moved['j1']!.clientInstructions, ['note']);
  });
}
