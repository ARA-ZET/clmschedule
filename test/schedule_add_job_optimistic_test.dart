// Adding a job shows it on the grid before the save finishes, saves it once,
// and takes it back off if the save is refused.
import 'dart:async';

import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/firestore_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeFirestoreService implements FirestoreService {
  final saved = <Job>[];
  Completer<void> gate = Completer<void>();
  Object? failWith;

  @override
  String newJobId() => 'new-job-1';

  int appends = 0;

  @override
  Future<String> addJob(Job job, [DateTime? date]) async {
    await gate.future;
    final error = failWith;
    if (error != null) throw error;
    saved.add(job);
    return job.id;
  }

  // A job with an id minted on the device is appended, not read-merged.
  @override
  Future<void> appendNewJobs(List<Job> jobs) async {
    appends++;
    await gate.future;
    final error = failWith;
    if (error != null) throw error;
    saved.addAll(jobs);
  }

  @override
  String getMonthlyDocumentId(DateTime date) => '${date.year}-${date.month}';

  @override
  Stream<List<Job>> streamJobs([DateTime? date]) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Job _blankJob(DateTime date) => Job(
      id: '',
      clients: const [],
      workingAreas: const [],
      workMaps: const [],
      distributorId: 'd1',
      date: date,
      statusId: 'scheduled',
    );

void main() {
  final now = DateTime.now();
  // A day in the month the provider loads by default.
  final day = DateTime(now.year, now.month, 15);

  test('the new job is on the grid before the save completes', () async {
    final fs = _FakeFirestoreService();
    final provider = ScheduleProvider(firestoreService: fs);

    final add = provider.addJob(_blankJob(day));
    await pumpEventQueue();

    expect(provider.jobs.map((j) => j.id), ['new-job-1']);
    expect(provider.pendingWriteCount.value, 1);
    expect(fs.saved, isEmpty, reason: 'still saving');

    fs.gate.complete();
    final saved = await add;

    expect(saved.id, 'new-job-1');
    expect(fs.saved.map((j) => j.id), ['new-job-1']);
    expect(fs.appends, 1, reason: 'one append, no read of the day');
    expect(provider.pendingWriteCount.value, 0);
  });

  test('a refused save takes the job back off and reports the error',
      () async {
    final fs = _FakeFirestoreService()..failWith = StateError('refused');
    final provider = ScheduleProvider(firestoreService: fs);

    final add = provider.addJob(_blankJob(day));
    await pumpEventQueue();
    expect(provider.jobs, hasLength(1));

    fs.gate.complete();
    await expectLater(add, throwsA(isA<StateError>()));

    expect(provider.jobs, isEmpty);
    expect(provider.pendingWriteCount.value, 0);
  });
}
