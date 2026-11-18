import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/services/schedule_mutation_types.dart';
import 'package:clmschedule/services/schedule_restore.dart';
import 'package:clmschedule/undo/undo_history.dart';
import 'package:flutter_test/flutter_test.dart';

final oct7 = DateTime(2026, 10, 7);
final oct8 = DateTime(2026, 10, 8);

String _key(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Job _job(String id, {String dist = 'a', DateTime? date, String status = 's'}) =>
    Job(
      id: id,
      clients: ['Client $id'],
      workingAreas: const [],
      workMaps: const [],
      distributorId: dist,
      date: date ?? oct7,
      statusId: status,
    );

/// A transaction context over two days holding [jobs] as stored.
ScheduleTxContext _ctx(List<Job> jobs) {
  final byKey = {
    _key(oct7): <Map<String, dynamic>>[],
    _key(oct8): <Map<String, dynamic>>[]
  };
  for (final j in jobs) {
    byKey[_key(j.date)]!.add(j.toMap());
  }
  return ScheduleTxContext(
    jobsByDateKey: byKey,
    beforeByDateKey: {for (final k in byKey.keys) k: null},
    dateKeyFor: _key,
  );
}

List<String> _ids(ScheduleTxContext ctx, DateTime d) =>
    [for (final j in ctx.jobsByDateKey[_key(d)]!) j['id'] as String];

void main() {
  test('undoing a move puts the job back on its old day', () {
    final before = _job('x', date: oct7);
    final after = _job('x', date: oct8, dist: 'b');
    final ctx = _ctx([after]);
    applyScheduleRestore(ctx, expected: [after], replacement: [before]);
    expect(_ids(ctx, oct7), ['x']);
    expect(_ids(ctx, oct8), isEmpty);
    expect(ctx.jobsByDateKey[_key(oct7)]!.single['distributorId'], 'a');
  });

  test('an edit on the same day is replaced in place, keeping the order', () {
    final a = _job('a');
    final edited = _job('b', status: 'done');
    final c = _job('c');
    final ctx = _ctx([a, edited, c]);
    applyScheduleRestore(ctx, expected: [edited], replacement: [_job('b')]);
    expect(_ids(ctx, oct7), ['a', 'b', 'c']);
    expect(ctx.jobsByDateKey[_key(oct7)]![1]['statusId'], 's');
  });

  test('undoing an add removes the job and reports it', () {
    final added = _job('n');
    final ctx = _ctx([added]);
    final r = applyScheduleRestore(ctx, expected: [added], replacement: []);
    expect(_ids(ctx, oct7), isEmpty);
    expect(r.removed.keys, ['n']);
  });

  test('undoing a delete puts the job back', () {
    final deleted = _job('d');
    final ctx = _ctx([]);
    applyScheduleRestore(ctx, expected: [], replacement: [deleted]);
    expect(_ids(ctx, oct7), ['d']);
  });

  test('a job changed since is a conflict and nothing changes', () {
    final after = _job('x', status: 'mine');
    final theirs = _job('x', status: 'theirs');
    final ctx = _ctx([theirs, _job('y')]);
    expect(
      () => applyScheduleRestore(ctx,
          expected: [after, _job('y')],
          replacement: [_job('x'), _job('y', dist: 'b')]),
      throwsA(isA<UndoConflict>()),
    );
    expect(ctx.jobsByDateKey[_key(oct7)]!.first['statusId'], 'theirs');
  });

  test('a job that is gone is a conflict', () {
    expect(
      () => applyScheduleRestore(_ctx([]),
          expected: [_job('x')], replacement: [_job('x', status: 'old')]),
      throwsA(isA<UndoConflict>()),
    );
  });

  test('putting back a job that is already there is a conflict', () {
    final ctx = _ctx([_job('d', dist: 'z')]);
    expect(
      () => applyScheduleRestore(ctx, expected: [], replacement: [_job('d')]),
      throwsA(isA<UndoConflict>()),
    );
  });

  test('a retry after the write committed changes nothing', () {
    final before = _job('x', date: oct7);
    final after = _job('x', date: oct8);
    final ctx = _ctx([before]); // the undo already landed
    final r =
        applyScheduleRestore(ctx, expected: [after], replacement: [before]);
    expect(r.alreadyApplied, isTrue);
    expect(_ids(ctx, oct7), ['x']);
  });

  test('a swap undoes both jobs together', () {
    final a0 = _job('a', dist: 'a');
    final b0 = _job('b', dist: 'b', date: oct8);
    final a1 = _job('a', dist: 'b', date: oct8);
    final b1 = _job('b', dist: 'a');
    final ctx = _ctx([b1, a1]);
    applyScheduleRestore(ctx, expected: [a1, b1], replacement: [a0, b0]);
    expect(_ids(ctx, oct7), ['a']);
    expect(_ids(ctx, oct8), ['b']);
  });
}
