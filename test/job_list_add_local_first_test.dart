// Adding a Job List job no longer waits for the server: the id is made on
// the device, the job is returned at once, the unsaved count (the "Saving…"
// chip, the connection banner and the leave-page warning) covers it until
// the server confirms, and a refusal is reported.
import 'dart:async';

import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/providers/auth_provider.dart';
import 'package:clmschedule/providers/job_list_provider.dart';
import 'package:clmschedule/services/job_list_service.dart';
import 'package:clmschedule/services/sync_status.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeJobListService implements JobListService {
  final saved = <String, JobListItem>{};
  Completer<void> gate = Completer<void>();
  Object? failWith;
  int _ids = 0;

  @override
  String newJobListItemId(DateTime date) => 'jl-${_ids++}';

  @override
  Future<void> setNewJobListItem(String id, JobListItem jobListItem) async {
    await gate.future;
    final error = failWith;
    if (error != null) throw error;
    saved[id] = jobListItem;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuth implements AuthProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

JobListItem _item(String client) {
  final date = DateTime(2026, 11, 20);
  return JobListItem(
    id: '',
    invoice: '',
    amount: 0,
    client: client,
    jobStatusId: 'standby',
    jobTypeId: 'flyers',
    area: '',
    quantity: 0,
    manDays: 8,
    date: date,
    collectionAddress: '',
    collectionDate: date,
    specialInstructions: '',
    quantityDistributed: 0,
    invoiceDetails: '',
    reportAddresses: '',
    whoToInvoice: '',
  );
}

void main() {
  test('returns the job with its id before the server confirms', () async {
    final service = _FakeJobListService();
    final provider = JobListProvider(service, _FakeAuth());

    final added = provider.addJobListItemLocal(_item('Timbuild'));
    expect(added.job.id, 'jl-0');
    expect(added.job.client, 'Timbuild');
    expect(provider.unsavedCount.value, 1);
    expect(SyncStatus.instance.pendingWriteCount, greaterThanOrEqualTo(1));

    var confirmed = false;
    unawaited(added.saved.then((_) => confirmed = true));
    await pumpEventQueue();
    expect(confirmed, isFalse, reason: 'the server has not answered yet');

    service.gate.complete();
    await added.saved;
    expect(confirmed, isTrue);
    expect(service.saved.keys, ['jl-0']);
    expect(provider.unsavedCount.value, 0);
    expect(provider.actionError, isNull);
  });

  test('addJobListItemAndReturn waits for the server only when asked',
      () async {
    final service = _FakeJobListService();
    final provider = JobListProvider(service, _FakeAuth());

    // Not waiting: done while the server is still silent.
    final quick = await provider.addJobListItemAndReturn(_item('A'));
    expect(quick.id, 'jl-0');

    var waitedDone = false;
    final waited = provider
        .addJobListItemAndReturn(_item('B'), waitForServer: true)
        .then((j) {
      waitedDone = true;
      return j;
    });
    await pumpEventQueue();
    expect(waitedDone, isFalse);

    service.gate.complete();
    expect((await waited).id, 'jl-1');
  });

  test('a refused save is reported, and stops counting as unsaved',
      () async {
    final service = _FakeJobListService()
      ..failWith = StateError('permission-denied');
    final provider = JobListProvider(service, _FakeAuth());

    final added = provider.addJobListItemLocal(_item('Timbuild'));
    service.gate.complete();
    await expectLater(added.saved, throwsStateError);

    expect(provider.actionError, isNotNull);
    expect(provider.unsavedCount.value, 0);
  });

  test('nobody listening to a refusal is not an uncaught error', () async {
    final service = _FakeJobListService()..failWith = StateError('refused');
    final provider = JobListProvider(service, _FakeAuth());

    provider.addJobListItemLocal(_item('Timbuild'));
    service.gate.complete();
    await pumpEventQueue();
    expect(provider.actionError, isNotNull);
  });
}
