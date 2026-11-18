// Deleting selected schedule jobs: they leave the grid at once, are saved
// as ONE write and ONE Undo step, a refusal puts them all back, and Undo
// restores them (marking their Recycle Bin entries restored).
import 'dart:async';

import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/firestore_service.dart';
import 'package:clmschedule/services/schedule_mutation_types.dart';
import 'package:clmschedule/undo/undo_history.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:flutter_test/flutter_test.dart';

class _FakeFirestoreService implements FirestoreService {
  final deleteCalls = <Map<String, DateTime>>[];
  final restoreCalls = <({List<Job> replacement, List<String> binIds})>[];
  Completer<void>? gate;
  Object? failWith;
  int _ids = 0;

  @override
  ScheduleLogUser Function()? logUserResolver;

  @override
  String newJobId() => 'job-${_ids++}';

  @override
  Future<void> appendNewJobs(List<Job> jobs) async {}

  @override
  Future<Map<String, String>> deleteJobs(Map<String, DateTime> jobs) async {
    deleteCalls.add(jobs);
    await gate?.future;
    final error = failWith;
    if (error != null) throw error;
    return {for (final id in jobs.keys) id: 'bin-$id'};
  }

  @override
  Future<Map<String, String>> restoreScheduleJobs({
    required List<Job> expected,
    required List<Job> replacement,
    required String action,
    bool binRemovals = false,
    List<String> restoredBinIds = const [],
  }) async {
    restoreCalls.add((replacement: replacement, binIds: restoredBinIds));
    return const {};
  }

  @override
  String getMonthlyDocumentId(DateTime date) => '${date.year}-${date.month}';

  @override
  Stream<List<Job>> streamJobs([DateTime? date]) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Job _job(int day, String distributorId) {
  final now = DateTime.now();
  return Job(
    id: '',
    clients: const [],
    workingAreas: const ['Area'],
    workMaps: const [],
    distributorId: distributorId,
    // Past days of the month: the dropsheet re-sync skips them.
    date: DateTime(now.year, now.month, day),
    statusId: 'scheduled',
  );
}

void main() {
  test('3 selected jobs leave the grid at once and save as ONE write',
      () async {
    final fs = _FakeFirestoreService();
    final p = ScheduleProvider(firestoreService: fs);
    final a = await p.addJob(_job(1, 'd1'));
    final b = await p.addJob(_job(1, 'd2'));
    final c = await p.addJob(_job(2, 'd1'));
    final keep = await p.addJob(_job(2, 'd2'));
    fs.gate = Completer<void>();

    final delete = p.deleteJobsWithUndo([a, b, c]);
    expect(p.jobs.map((j) => j.id), [keep.id], reason: 'gone before saving');
    await pumpEventQueue();
    expect(fs.deleteCalls.single.keys, unorderedEquals([a.id, b.id, c.id]));

    fs.gate!.complete();
    await delete;
    expect(fs.deleteCalls, hasLength(1));
    expect(p.jobs.map((j) => j.id), [keep.id]);
    expect(p.pendingWriteCount.value, 0);
  });

  test('a refused delete puts them all back', () async {
    final fs = _FakeFirestoreService();
    final p = ScheduleProvider(firestoreService: fs);
    final a = await p.addJob(_job(1, 'd1'));
    final b = await p.addJob(_job(2, 'd1'));
    fs
      ..gate = Completer<void>()
      ..failWith = StateError('refused');

    final delete = p.deleteJobsWithUndo([a, b]);
    expect(p.jobs, isEmpty);
    fs.gate!.complete();
    await expectLater(delete, throwsStateError);
    expect(p.jobs.map((j) => j.id), unorderedEquals([a.id, b.id]));
  });

  test('is one Undo step; undo restores them and their bin entries',
      () async {
    final fs = _FakeFirestoreService();
    final container = riverpod.ProviderContainer();
    addTearDown(container.dispose);
    final schedule = riverpod.Provider(
        (ref) => ScheduleProvider(firestoreService: fs, ref: ref));
    final p = container.read(schedule);
    final history = container.read(undoHistoryRiverpod(UndoKey.schedule));

    final a = await p.addJob(_job(1, 'd1'));
    final b = await p.addJob(_job(3, 'd2'));
    history.clear();

    UndoEntry? entry;
    await p.deleteJobsWithUndo([a, b], onRecorded: (e) => entry = e);
    expect(history.undoCount, 1);
    expect(history.undoLabel, 'Delete 2 jobs');
    expect(entry, isNotNull);
    expect(history.isNewest(entry!), isTrue);

    await history.undo();
    final restore = fs.restoreCalls.single;
    expect(restore.replacement.map((j) => j.id),
        unorderedEquals([a.id, b.id]));
    expect(restore.binIds, unorderedEquals(['bin-${a.id}', 'bin-${b.id}']));
    expect(p.jobs.map((j) => j.id), unorderedEquals([a.id, b.id]));
    expect(history.isNewest(entry!), isFalse, reason: 'already undone');
  });
}
