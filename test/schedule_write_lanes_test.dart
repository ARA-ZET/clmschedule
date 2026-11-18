// Schedule writes queue per day: writes on different days save side by
// side, writes sharing a day save one after another in the order made. And
// a new job's append is sent once — a retry after a timeout waits on it.
import 'dart:async';

import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/firestore_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every save waits on its own gate, opened by [release], so a test can
/// see which saves are running at once.
class _GatedFirestoreService implements FirestoreService {
  final started = <String>[];
  final _gates = <String, Completer<void>>{};
  int appends = 0;
  bool gateAppends = false;
  int _ids = 0;

  Future<void> _run(String key) {
    started.add(key);
    return (_gates[key] ??= Completer<void>()).future;
  }

  void release(String key) => (_gates[key] ??= Completer<void>()).complete();

  @override
  String newJobId() => 'job-${_ids++}';

  @override
  Future<void> appendNewJobs(List<Job> jobs) async {
    appends++;
    if (gateAppends) await _run('append');
  }

  @override
  Future<void> updateJob(Job job, [DateTime? date]) =>
      _run('update ${job.id}');

  @override
  Future<void> swapJobsBetweenDates(Job originalJobA, Job newJobA,
          Job originalJobB, Job newJobB, DateTime dateA, DateTime dateB) =>
      _run('swap ${originalJobA.id} ${originalJobB.id}');

  @override
  String getMonthlyDocumentId(DateTime date) => '${date.year}-${date.month}';

  @override
  Stream<List<Job>> streamJobs([DateTime? date]) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Job _job(DateTime date, String distributorId) => Job(
      id: '',
      clients: const [],
      workingAreas: const ['Area'],
      workMaps: const [],
      distributorId: distributorId,
      date: date,
      statusId: 'scheduled',
    );

void main() {
  final now = DateTime.now();
  // Days in the month the provider loads by default.
  final dayA = DateTime(now.year, now.month, 10);
  final dayB = DateTime(now.year, now.month, 11);
  final dayC = DateTime(now.year, now.month, 12);

  test('writes on different days save side by side', () async {
    final fs = _GatedFirestoreService();
    final p = ScheduleProvider(firestoreService: fs);
    final a = await p.addJob(_job(dayA, 'd1'));
    final b = await p.addJob(_job(dayB, 'd2'));

    final w1 = p.updateJob(a.copyWith(statusId: 'done'));
    final w2 = p.updateJob(b.copyWith(statusId: 'done'));
    await pumpEventQueue();

    expect(fs.started, ['update ${a.id}', 'update ${b.id}'],
        reason: 'the second did not wait for the first');
    expect(p.pendingWriteCount.value, 2);

    // The later one may finish first.
    fs.release('update ${b.id}');
    await w2;
    expect(p.pendingWriteCount.value, 1);
    fs.release('update ${a.id}');
    await w1;
    expect(p.pendingWriteCount.value, 0);
  });

  test('writes on the same day save one after another, in order', () async {
    final fs = _GatedFirestoreService();
    final p = ScheduleProvider(firestoreService: fs);
    final a = await p.addJob(_job(dayA, 'd1'));
    final b = await p.addJob(_job(dayA, 'd2'));

    final w1 = p.updateJob(a.copyWith(statusId: 'done'));
    final w2 = p.updateJob(b.copyWith(statusId: 'done'));
    await pumpEventQueue();
    expect(fs.started, ['update ${a.id}'], reason: 'b waits for a');

    fs.release('update ${a.id}');
    await w1;
    await pumpEventQueue();
    expect(fs.started, ['update ${a.id}', 'update ${b.id}']);

    fs.release('update ${b.id}');
    await w2;
    expect(p.pendingWriteCount.value, 0);
  });

  test('a swap across two days holds both, not a third', () async {
    final fs = _GatedFirestoreService();
    final p = ScheduleProvider(firestoreService: fs);
    final a = await p.addJob(_job(dayA, 'd1'));
    final b = await p.addJob(_job(dayB, 'd2'));
    final c = await p.addJob(_job(dayC, 'd3'));

    final swap = p.swapJobsWithUndo(a, b, dayB);
    // Shown at once: each job is in the other's cell.
    expect(p.getJobsForDistributorAndDate('d2', dayB).single.id, a.id);
    expect(p.getJobsForDistributorAndDate('d1', dayA).single.id, b.id);
    // b is on day A now — a day the swap is still saving.
    final bOnA = p.updateJob(
        p.jobs.firstWhere((j) => j.id == b.id).copyWith(statusId: 'done'));
    final onC = p.updateJob(c.copyWith(statusId: 'done'));
    await pumpEventQueue();

    expect(fs.started,
        unorderedEquals(['swap ${a.id} ${b.id}', 'update ${c.id}']),
        reason: 'day C is free; day A waits for the swap');

    fs.release('update ${c.id}');
    await onC;
    fs.release('swap ${a.id} ${b.id}');
    await swap;
    await pumpEventQueue();
    expect(fs.started.last, 'update ${b.id}');
    fs.release('update ${b.id}');
    await bOnA;
    expect(p.pendingWriteCount.value, 0);
  });

  testWidgets('a new job is appended once; a timed-out save waits on it',
      (tester) async {
    final fs = _GatedFirestoreService()..gateAppends = true;
    final p = ScheduleProvider(firestoreService: fs);

    var saved = false;
    unawaited(p.addJob(_job(dayA, 'd1')).then((_) => saved = true));
    await tester.pump();
    expect(fs.appends, 1);
    expect(p.jobs, hasLength(1), reason: 'on the grid while saving');

    // Past the 30 s save timeout and the retry's back-off.
    await tester.pump(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 2));
    expect(fs.appends, 1, reason: 'the retry waits on the first append');
    expect(saved, isFalse);

    fs.release('append');
    await tester.pump();
    await tester.pump();
    expect(saved, isTrue);
    expect(p.pendingWriteCount.value, 0);

    // Let the write queue's confirm timers and the banner's run out.
    await tester.pump(const Duration(minutes: 5));
  });
}
