// A whole schedule allocation is saved as ONE write: every job shows on the
// grid at once, one append saves them (no read of their days), one Undo
// step covers them, and a refusal takes them all back off.
//
// Also a latency simulation of the old way (one transaction per job, one
// after another) against the new one, printed as a before/after table.
import 'dart:async';

import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/firestore_service.dart';
import 'package:clmschedule/services/schedule_mutation_types.dart';
import 'package:clmschedule/undo/undo_history.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:flutter_test/flutter_test.dart';

/// A schedule database whose transactions cost two round trips each (read
/// the day docs, then commit), like the real one.
class _NetFirestoreService implements FirestoreService {
  _NetFirestoreService({this.rtt = Duration.zero});

  final Duration rtt;
  final saved = <Job>[];
  final batches = <List<Job>>[];
  int transactions = 0;
  Completer<void>? gate;
  Object? failWith;
  int _ids = 0;

  @override
  ScheduleLogUser Function()? logUserResolver;

  Future<void> _transaction(List<Job> jobs) async {
    transactions++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await gate?.future;
      await Future<void>.delayed(rtt); // read the day docs
      await Future<void>.delayed(rtt); // commit
      final error = failWith;
      if (error != null) throw error;
      saved.addAll(jobs);
    } finally {
      inFlight--;
    }
  }

  @override
  String newJobId() => 'job-${_ids++}';

  @override
  Future<String> addJob(Job job, [DateTime? date]) async {
    await _transaction([job]);
    return job.id;
  }

  @override
  Future<void> addJobs(List<Job> jobs) async {
    batches.add(jobs);
    await _transaction(jobs);
  }

  /// New ids: one batched append — the commit only, no read of the days.
  int appends = 0;

  @override
  Future<void> appendNewJobs(List<Job> jobs) async {
    appends++;
    batches.add(jobs);
    await gate?.future;
    await Future<void>.delayed(rtt); // commit
    final error = failWith;
    if (error != null) throw error;
    saved.addAll(jobs);
  }

  /// Writes of the schedule in flight at once, and the most seen together.
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  String getMonthlyDocumentId(DateTime date) => '${date.year}-${date.month}';

  @override
  Stream<List<Job>> streamJobs([DateTime? date]) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [n] jobs for one client on consecutive days of the loaded month, one
/// distributor each — what an allocation produces.
List<Job> _allocation(int n, {String client = 'Timbuild'}) {
  final now = DateTime.now();
  return [
    for (var i = 0; i < n; i++)
      Job(
        id: '',
        clients: [client],
        workingAreas: const ['Bellville'],
        workMaps: const [],
        distributorId: 'd$i',
        // Within the month the provider loads by default.
        date: DateTime(now.year, now.month, 1 + i % 28),
        statusId: 'logged',
      ),
  ];
}

void main() {
  group('addJobsWithUndo', () {
    test('8 jobs: all on the grid at once, saved by ONE write', () async {
      final fs = _NetFirestoreService()..gate = Completer<void>();
      final provider = ScheduleProvider(firestoreService: fs);

      final add = provider.addJobsWithUndo(_allocation(8));
      await pumpEventQueue();

      expect(provider.jobs, hasLength(8), reason: 'shown before the save');
      expect(provider.jobs.map((j) => j.id).toSet(), hasLength(8));
      expect(provider.pendingWriteCount.value, 1, reason: 'one write, not 8');
      expect(fs.saved, isEmpty);

      fs.gate!.complete();
      final saved = await add;

      expect(fs.appends, 1, reason: 'one append for all 8');
      expect(fs.transactions, 0, reason: 'no read-and-rewrite of the days');
      expect(fs.batches.single, hasLength(8));
      expect(saved.map((j) => j.id), fs.batches.single.map((j) => j.id));
      expect(provider.pendingWriteCount.value, 0);
    });

    test('a refused save takes all of them back off the grid', () async {
      final fs = _NetFirestoreService()
        ..gate = Completer<void>()
        ..failWith = StateError('refused');
      final provider = ScheduleProvider(firestoreService: fs);

      final add = provider.addJobsWithUndo(_allocation(8));
      await pumpEventQueue();
      expect(provider.jobs, hasLength(8));

      fs.gate!.complete();
      await expectLater(add, throwsStateError);
      expect(provider.jobs, isEmpty);
      expect(provider.pendingWriteCount.value, 0);
    });

    test('is one Undo step, named after the client', () async {
      final fs = _NetFirestoreService();
      final container = riverpod.ProviderContainer();
      addTearDown(container.dispose);
      final schedule = riverpod.Provider(
          (ref) => ScheduleProvider(firestoreService: fs, ref: ref));

      await container.read(schedule).addJobsWithUndo(_allocation(8));

      final history = container.read(undoHistoryRiverpod(UndoKey.schedule));
      expect(history.undoCount, 1);
      expect(history.undoLabel, 'Add 8 jobs for Timbuild');
    });
  });

  // Fake time: the simulated round trips cost nothing to run.
  testWidgets('latency simulation: old one-by-one vs one append',
      (tester) async {
    final rows = <String>[];
    for (final rtt in const [
      Duration(milliseconds: 300),
      Duration(seconds: 1),
    ]) {
      for (final n in const [8, 19]) {
        Future<Duration> timeIt(Future<void> Function() run) async {
          var done = false;
          unawaited(run().whenComplete(() => done = true));
          var elapsed = Duration.zero;
          const tick = Duration(milliseconds: 50);
          while (!done) {
            await tester.pump(tick);
            elapsed += tick;
          }
          return elapsed;
        }

        // Before: what the queue did — one transaction per job (read the
        // day, then commit), one after another.
        final oldFs = _NetFirestoreService(rtt: rtt);
        final before = await timeIt(() async {
          for (final j in _allocation(n)) {
            await oldFs.addJob(j.copyWith(), j.date);
          }
        });

        // After: one append for the lot — one round trip, no read.
        final newFs = _NetFirestoreService(rtt: rtt);
        final provider = ScheduleProvider(firestoreService: newFs);
        final after =
            await timeIt(() => provider.addJobsWithUndo(_allocation(n)));

        // Jobs added one by one from the grid, each on its own day: each is
        // one append, and the day lanes save them side by side.
        final laneFs = _NetFirestoreService(rtt: rtt);
        final laneProvider = ScheduleProvider(firestoreService: laneFs);
        final oneByOne = await timeIt(() => Future.wait([
              for (final j in _allocation(n))
                laneProvider.addJobWithUndo(j, j.date),
            ]));

        expect(oldFs.transactions, n);
        expect(newFs.appends, 1);
        expect(newFs.transactions, 0);
        expect(laneFs.appends, n);
        // Old ≈ n transactions of 2 round trips; new ≈ one round trip.
        expect(before, greaterThanOrEqualTo(rtt * 2 * n));
        expect(after, lessThan(rtt + const Duration(milliseconds: 200)));
        expect(oneByOne, lessThan(rtt + const Duration(milliseconds: 200)));

        String s(Duration d) =>
            '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
        rows.add('  RTT ${s(rtt).padLeft(6)}  $n jobs   before: '
            '${s(before).padLeft(6)} ($n transactions in a row)   '
            'after: ${s(after).padLeft(5)} (1 append)   '
            'one-by-one now: ${s(oneByOne).padLeft(5)} '
            '($n appends side by side)');
      }
    }
    // ignore: avoid_print
    print('\nSchedule allocation save time (simulated)\n${rows.join('\n')}');
    // Let the write queue's confirm timers and the banner's run out.
    await tester.pump(const Duration(minutes: 5));
  });
}
