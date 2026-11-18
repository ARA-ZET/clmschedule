// The invoice saga raises the invoice while the schedule allocation (the
// assignment preview, then its save) is still going, instead of after it.
// The job is still saved first, and the link still waits for the invoice.
import 'dart:async';

import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/utils/save_timeline.dart';
import 'package:clmschedule/widgets/zoho/invoice_save_saga.dart';
import 'package:flutter_test/flutter_test.dart';

JobListItem _job() {
  final date = DateTime(2026, 11, 20);
  return JobListItem(
    id: 'job-1',
    invoice: '',
    amount: 0,
    client: 'Timbuild',
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

class _Harness {
  final events = <String>[];
  Completer<String?> allocation = Completer<String?>();
  Completer<String> invoice = Completer<String>();
  int allocations = 0;
  int invoices = 0;
  int saves = 0;

  late final InvoiceSaveSaga<String, String> saga = InvoiceSaveSaga(
    providerName: 'Zoho',
    customerLabel: (c) => c,
    invoiceLabel: (i) => i,
    customer: 'Timbuild (Pty) Ltd',
    onProgress: () {},
    timeline: SaveTimeline('test', printer: (_) {}),
    saveJob: () async {
      saves++;
      events.add('save');
      return _job();
    },
    allocateToSchedule: (job) {
      allocations++;
      events.add('allocate start');
      return allocation.future.whenComplete(() => events.add('allocate end'));
    },
    createInvoice: (job, customer) {
      invoices++;
      events.add('invoice start');
      return invoice.future.whenComplete(() => events.add('invoice end'));
    },
    linkToJob: (job, customer, inv) async => events.add('link'),
  );
}

void main() {
  test('the invoice is raised while the allocation preview is still open',
      () async {
    final h = _Harness();
    final run = h.saga.run();
    await pumpEventQueue();

    expect(h.events, ['save', 'allocate start', 'invoice start']);

    h.invoice.complete('INV-001');
    await pumpEventQueue();
    // Linked without waiting for the allocation.
    expect(h.events, ['save', 'allocate start', 'invoice start',
        'invoice end', 'link']);
    expect(h.saga.isRunning, isTrue,
        reason: 'run() waits for the allocation before it finishes');

    h.allocation.complete('Assigned 8 jobs to distributors');
    await run;
    expect(h.saga.isRunning, isFalse);
    expect(h.saga.isComplete, isTrue);
    expect(h.saga.allocateStep!.detail, 'Assigned 8 jobs to distributors');
  });

  test('a failed allocation does not hold back the invoice or the link',
      () async {
    final h = _Harness();
    final run = h.saga.run();
    await pumpEventQueue();
    h.allocation.completeError(StateError('no distributors'));
    h.invoice.complete('INV-001');
    await run;

    expect(h.events, contains('link'));
    expect(h.saga.allocateStep!.state, SagaStepState.failed);
    expect(h.saga.onlyAllocationFailed, isTrue);
    expect(h.saga.isFinished, isTrue);
  });

  test('a retry repeats only what failed', () async {
    final h = _Harness();
    // Allocation done, invoice fails.
    final first = h.saga.run();
    await pumpEventQueue();
    h.allocation.complete('Assigned 8 jobs to distributors');
    h.invoice.completeError(StateError('Zoho timed out'));
    await first;
    expect(h.saga.hasFailed, isTrue);
    expect(h.events, isNot(contains('link')));

    h.invoice = Completer<String>()..complete('INV-002');
    await h.saga.run();

    expect(h.saves, 1, reason: 'the job is never saved twice');
    expect(h.allocations, 1, reason: 'a finished allocation is not redone');
    expect(h.invoices, 2);
    expect(h.saga.isComplete, isTrue);
  });

  test('the job is still saved before anything else starts', () async {
    final h = _Harness();
    final run = h.saga.run();
    await pumpEventQueue();
    expect(h.events.first, 'save');
    h.allocation.complete(null); // declined the preview
    h.invoice.complete('INV-001');
    await run;
    expect(h.saga.allocateStep!.state, SagaStepState.skipped);
    expect(h.saga.isComplete, isTrue);
  });
}
