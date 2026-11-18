import 'package:flutter/foundation.dart';

import '../../models/job_list_item.dart';
import '../../utils/save_timeline.dart';

enum SagaStepState { pending, running, done, failed, skipped }

class SagaStep {
  final String label;
  SagaStepState state;

  /// Filled on completion or failure — shown next to the step.
  String? detail;

  SagaStep(this.label) : state = SagaStepState.pending;

  bool get isTerminal =>
      state == SagaStepState.done || state == SagaStepState.skipped;
}

/// Saves a job and raises its invoice as an ordered, resumable sequence.
///
/// Generic over the provider's customer ([C]) and invoice ([I]) types: the
/// ordering, retry and idempotency rules are identical for Zoho and Xero, and
/// duplicating them would let two copies of subtle financial logic drift apart.
/// Callers supply the provider's name and the two label functions so the step
/// text reads naturally for whichever books are being written to.
///
/// This is a **saga, not a transaction** — a Firestore transaction cannot span
/// an external HTTP API, and neither provider has a prepare/commit phase.
/// Safety comes from ordering and idempotency instead:
///
///  * The job is saved **first**. A job with no invoice is a normal state you
///    can retry; an invoice with no job is orphaned accounting data that can
///    only be voided, never deleted.
///  * Completed steps record their result ([savedJob], [customer],
///    [invoice]) and are never re-run, so [run] can be called again after a
///    failure without creating a second job or a duplicate invoice.
///  * Only the final link step writes inside a Firestore transaction, where
///    atomicity is actually achievable.
class InvoiceSaveSaga<C, I> {
  /// Persists the job and returns it with its id. Runs on every attempt until
  /// it succeeds once.
  final Future<JobListItem> Function() saveJob;

  /// Creates the invoice for the resolved customer.
  final Future<I> Function(JobListItem job, C customer) createInvoice;

  /// Stamps the provider's ids back onto the job, transactionally.
  final Future<void> Function(JobListItem job, C customer, I invoice) linkToJob;

  /// The customer this invoice is for, created and saved with the provider
  /// **before** the saga runs.
  ///
  /// Required, and never made here. Creating a customer mid-saga meant a
  /// failure at the invoice step could leave a half-finished customer in the
  /// books with nothing attached to it. Both providers now create the customer
  /// up front from the form, so by the time this runs it is an accomplished
  /// fact — which is why its step reports as done rather than skipped.
  final C customer;

  /// Shown in the step labels, e.g. "Zoho" or "Xero".
  final String providerName;

  /// How to name a customer in the step detail line.
  final String Function(C customer) customerLabel;

  /// How to name an invoice in the step detail line.
  final String Function(I invoice) invoiceLabel;

  /// Notifies the dialog to repaint as steps progress.
  final VoidCallback onProgress;

  /// True when [createInvoice] amends the job's existing invoice rather than
  /// raising a new one. Affects the step labels only — the ordering, retry
  /// semantics and idempotency are identical either way.
  final bool isUpdate;

  /// Puts the saved job on the Schedule grid, for new jobs of auto-allocate
  /// types. Returns the step detail when allocated, or null when the user
  /// declined the assignment preview; throws when allocation is impossible.
  ///
  /// Starts straight after the save, so it cannot be forgotten once the
  /// invoice is up and the user's attention moves to printing or sharing it.
  /// It runs **alongside** the invoice steps — the invoice is raised while
  /// the user is still looking at the assignment preview — and does not halt
  /// them: an unallocated job is fixable on the Schedule, while holding the
  /// invoice back over it would leave the job unbilled as well.
  final Future<String?> Function(JobListItem job)? allocateToSchedule;

  /// Times the save, invoice and link steps for the console (see
  /// [SaveTimeline]). Optional.
  final SaveTimeline? timeline;

  late final SagaStep _saveStep = SagaStep('Save job to Job List');
  late final SagaStep? allocateStep =
      allocateToSchedule == null ? null : SagaStep('Allocate to Schedule');
  late final SagaStep _customerStep = SagaStep('Customer in $providerName');
  late final SagaStep _invoiceStep = SagaStep(isUpdate
      ? 'Update invoice in $providerName'
      : 'Create invoice in $providerName');
  late final SagaStep _linkStep =
      SagaStep(isUpdate ? 'Refresh invoice on job' : 'Link invoice to job');

  late final List<SagaStep> steps = [
    if (_includesSaveStep) _saveStep,
    if (allocateStep != null) allocateStep!,
    _customerStep,
    _invoiceStep,
    _linkStep,
  ];

  // Results, retained across attempts so a retry resumes rather than repeats.
  // The customer is not among them — it is supplied, not resolved.
  JobListItem? savedJob;
  I? invoice;

  /// False when the saga was handed a job that is already saved — a split
  /// invoice raised against a job another saga (or a plain save) just wrote.
  /// The save step is then left off the panel rather than shown as a no-op.
  final bool _includesSaveStep;

  bool _isRunning = false;

  InvoiceSaveSaga({
    required this.saveJob,
    required this.createInvoice,
    required this.linkToJob,
    required this.customer,
    required this.onProgress,
    required this.providerName,
    required this.customerLabel,
    required this.invoiceLabel,
    this.isUpdate = false,
    this.allocateToSchedule,
    this.timeline,
    JobListItem? alreadySavedJob,
  })  : savedJob = alreadySavedJob,
        _includesSaveStep = alreadySavedJob == null;

  bool get isRunning => _isRunning;

  bool get isComplete => steps.every((s) => s.isTerminal);

  bool get hasFailed => steps.any((s) => s.state == SagaStepState.failed);

  /// The invoice side has finished, so the user can print, share and close.
  /// A failed allocation does not hold this back — it stays on screen, red,
  /// with its own retry, rather than trapping the user when no distributor is
  /// free.
  bool get isFinished =>
      !_isRunning &&
      steps.where((s) => s != allocateStep).every((s) => s.isTerminal);

  /// True once the invoice exists with the provider — from here on, abandoning
  /// leaves a real invoice behind, so the UI must say so rather than closing
  /// quietly.
  bool get invoiceExists => invoice != null;

  /// True when the allocation step is the only failure — the invoice side
  /// finished, so the warning is about the schedule, not the books.
  bool get onlyAllocationFailed =>
      allocateStep?.state == SagaStepState.failed &&
      steps
          .where((s) => s != allocateStep)
          .every((s) => s.state != SagaStepState.failed);

  /// The first failure message, for the summary line.
  String? get failureMessage {
    for (final s in steps) {
      if (s.state == SagaStepState.failed) return s.detail;
    }
    return null;
  }

  /// Run from the first step that has not completed. Safe to call repeatedly.
  Future<void> run() async {
    if (_isRunning) return;
    _isRunning = true;

    // Clear prior failures so a retry shows fresh state, but keep results.
    for (final s in steps) {
      if (s.state == SagaStepState.failed) {
        s.state = SagaStepState.pending;
        s.detail = null;
      }
    }
    onProgress();

    // Started after the save and awaited before [run] returns, so a retry
    // can never start it a second time while it is still going.
    Future<void>? allocation;
    try {
      // 1 — Save the job. Skipped entirely if a previous attempt saved it.
      if (savedJob == null) {
        if (!await _runStep(_saveStep, () async {
          savedJob = await saveJob();
          return 'Saved (${savedJob!.id})';
        })) {
          return;
        }
      } else {
        _markDone(_saveStep, 'Already saved (${savedJob!.id})');
      }

      // 2 — Allocate to the schedule, alongside the invoice steps below.
      // Never repeated once done or declined; a failure is retried but does
      // not stop the invoice.
      allocation = _runAllocation(savedJob!);

      // 3 — The customer already exists; record it as the settled fact it is.
      _markDone(_customerStep, customerLabel(customer));

      // 4 — Create the invoice. Never repeated once it exists.
      if (invoice == null) {
        if (!await _runStep(_invoiceStep, () async {
          invoice = await createInvoice(savedJob!, customer);
          return 'Invoice ${invoiceLabel(invoice as I)}';
        })) {
          return;
        }
      } else {
        _markDone(
            _invoiceStep, 'Already created ${invoiceLabel(invoice as I)}');
      }

      // 5 — Link back to the job. Never repeated once linked.
      if (_linkStep.isTerminal) return;
      await _runStep(_linkStep, () async {
        await linkToJob(savedJob!, customer, invoice as I);
        return 'Linked to job';
      });
    } finally {
      if (allocation != null) await allocation;
      _isRunning = false;
      onProgress();
    }
  }

  /// Step 2. Never throws: a failure is shown on the step, with its retry.
  Future<void> _runAllocation(JobListItem job) async {
    final allocate = allocateToSchedule;
    final allocStep = allocateStep;
    if (allocate == null || allocStep == null || allocStep.isTerminal) return;
    allocStep.state = SagaStepState.running;
    allocStep.detail = null;
    onProgress();
    try {
      final detail = await allocate(job);
      allocStep.state =
          detail == null ? SagaStepState.skipped : SagaStepState.done;
      allocStep.detail = detail ?? 'Skipped — not on the Schedule';
    } catch (e) {
      allocStep.state = SagaStepState.failed;
      allocStep.detail = e.toString();
    }
    onProgress();
  }

  /// Returns true when the step succeeded.
  Future<bool> _runStep(SagaStep step, Future<String> Function() body) async {
    step.state = SagaStepState.running;
    step.detail = null;
    onProgress();
    try {
      final tl = timeline;
      step.detail = tl == null ? await body() : await tl.step(step.label, body);
      step.state = SagaStepState.done;
      onProgress();
      return true;
    } catch (e) {
      step.state = SagaStepState.failed;
      step.detail = e.toString();
      onProgress();
      return false;
    }
  }

  void _markDone(SagaStep step, String detail) {
    step.state = SagaStepState.done;
    step.detail = detail;
  }
}
