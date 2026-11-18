import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/advance.dart';
import '../models/advance_repayment.dart';
import '../models/distributor.dart';
import '../models/distributor_payroll_profile.dart';
import '../models/payroll_daily_entry.dart';
import '../models/payroll_payslip.dart';
import '../models/payroll_settings.dart';
import '../models/payroll_week.dart';
import '../models/savings_deposit.dart';
import '../models/savings_withdrawal.dart';
import '../utils/payroll_calculator.dart' as calc;
import '../utils/payroll_week.dart';
import '../utils/schedule_time.dart';
import 'schedule_mutation_types.dart' show deepEquals;
import 'sync_status.dart';

/// Whether [a] and [b] would save the same payslip, apart from the
/// `updatedAt`/`updatedBy` stamp (`toMap` stamps `updatedAt` with the current
/// time, so a plain comparison never matches).
bool payslipsMatchIgnoringStamp(PayrollPayslip a, PayrollPayslip b) {
  final am = a.toMap()
    ..remove('updatedAt')
    ..remove('updatedBy');
  final bm = b.toMap()
    ..remove('updatedAt')
    ..remove('updatedBy');
  return deepEquals(am, bm);
}

/// CRUD + business logic for payroll, mirroring `DropsheetService`'s narrow,
/// single-responsibility style rather than the monolithic `FirestoreService`.
///
/// Storage layout:
///   `/payroll/{YYYY}/{MMM YYYY}/{weekId}`      — one doc per pay week
///   `/payrollSettings/config`                   — singleton company defaults
///   `/payrollAdvances/{distributorId}/advances/{id}`   — individually
///       recorded cash advances, repaid oldest-first
///   `/payrollAdvances/{distributorId}/repayments/{id}` — full repayment
///       history, one entry per advance touched per pay week
///
/// No legacy-fallback layer (unlike `DropsheetService`) — there is no prior
/// Firestore payroll data to fall back to.
class PayrollService {
  final FirebaseFirestore _firestore;

  PayrollService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  // ── Path helpers ──────────────────────────────────────────────────────

  DocumentReference<Map<String, dynamic>> _yearDoc(DateTime weekStart) =>
      _firestore.collection('payroll').doc(yearIdFor(weekStart));

  DocumentReference<Map<String, dynamic>> _weekDoc(DateTime weekStart) =>
      _yearDoc(weekStart)
          .collection(monthLabelFor(weekStart))
          .doc(weekIdFor(weekStart));

  DocumentReference<Map<String, dynamic>> get _settingsDoc =>
      _firestore.collection('payrollSettings').doc('config');

  DocumentReference<Map<String, dynamic>> _advancesRootDoc(
          String distributorId) =>
      _firestore.collection('payrollAdvances').doc(distributorId);

  CollectionReference<Map<String, dynamic>> _advancesCol(
          String distributorId) =>
      _advancesRootDoc(distributorId).collection('advances');

  CollectionReference<Map<String, dynamic>> _repaymentsCol(
          String distributorId) =>
      _advancesRootDoc(distributorId).collection('repayments');

  DocumentReference<Map<String, dynamic>> _savingsRootDoc(
          String distributorId) =>
      _firestore.collection('payrollSavings').doc(distributorId);

  CollectionReference<Map<String, dynamic>> _depositsCol(
          String distributorId) =>
      _savingsRootDoc(distributorId).collection('deposits');

  CollectionReference<Map<String, dynamic>> _withdrawalsCol(
          String distributorId) =>
      _savingsRootDoc(distributorId).collection('withdrawals');

  // ── Weeks ──────────────────────────────────────────────────────────────

  /// Streams the week containing [anyDateInWeek], yielding an empty
  /// placeholder week if it hasn't been created yet.
  Stream<PayrollWeek> streamWeek(DateTime anyDateInWeek) {
    final weekStart = weekStartFor(anyDateInWeek);
    final id = weekIdFor(weekStart);
    return _weekDoc(weekStart).snapshots().map((snap) {
      if (snap.exists && snap.data() != null) {
        return PayrollWeek.fromMap(id, snap.data()!);
      }
      return PayrollWeek.empty(weekStart);
    });
  }

  /// [streamWeek] plus whether each snapshot is confirmed by the server
  /// (not just the local cache) — for the schedule sync, which must not act
  /// on a possibly-stale cached week.
  Stream<({PayrollWeek week, bool fromServer})> streamWeekWithSource(
      DateTime weekStart) {
    final id = weekIdFor(weekStart);
    // Metadata changes too, so a dropped connection is reported (fromServer
    // turns false) instead of the last server snapshot passing as current.
    return _weekDoc(weekStart)
        .snapshots(includeMetadataChanges: true)
        .map((snap) => (
          week: snap.exists && snap.data() != null
              ? PayrollWeek.fromMap(id, snap.data()!)
              : PayrollWeek.empty(weekStart),
          fromServer: !snap.metadata.isFromCache,
        ));
  }

  /// One-shot fetch, same empty-placeholder fallback as [streamWeek].
  Future<PayrollWeek> getWeek(DateTime anyDateInWeek) async {
    final weekStart = weekStartFor(anyDateInWeek);
    final id = weekIdFor(weekStart);
    final snap = await _weekDoc(weekStart).get();
    if (snap.exists && snap.data() != null) {
      return PayrollWeek.fromMap(id, snap.data()!);
    }
    return PayrollWeek.empty(weekStart);
  }

  /// Transactionally read-modify-writes one or more of the week's payslips.
  ///
  /// This is the banking-grade replacement for the old
  /// "mutate-local-then-blind-write" path: every mutation now (1) reads the
  /// week document *inside* a Firestore transaction, (2) applies [mutations]
  /// to the FRESHLY-read payslip for each distributor, (3) recomputes that
  /// payslip's totals, and (4) writes only the touched `payslips.<id>` field
  /// paths back. Because the week doc is read inside the transaction, a
  /// concurrent edit to the SAME distributor's payslip (another session, the
  /// Ops Stats grid, the Track Editor's wage box, or a ledger sync) forces a
  /// retry instead of being silently overwritten by a stale local snapshot —
  /// closing the same-distributor lost-update window the previous
  /// `updatePayslipFields` blind write left open. Other distributors'
  /// payslips are still never touched (only named field paths are written).
  ///
  /// Each entry in [mutations] is a pure `(current) -> next` function applied
  /// to the current payslip. [seeds] supplies a fallback payslip to build
  /// from when the fresh read has no payslip for that distributor yet (e.g.
  /// the week doc was only just created); the mutation is applied to the seed
  /// exactly once. [updatedBy] is stamped for audit.
  ///
  /// [preconditions] guard against a stale screen: a distributor whose
  /// freshly-read payslip fails its check is left untouched, and its id is
  /// returned — e.g. an Ops Stats cell only overwrites the server value it
  /// was based on, and "paid" is only recorded at the amount the admin saw.
  Future<Set<String>> mutatePayslipsTxn(
    DateTime weekStart, {
    required Map<String, PayrollPayslip Function(PayrollPayslip)> mutations,
    Map<String, PayrollPayslip> seeds = const {},
    Map<String, bool Function(PayrollPayslip current)> preconditions =
        const {},
    required PayrollSettings settings,
    String? updatedBy,
  }) async {
    if (mutations.isEmpty) return const {};
    final weekId = weekIdFor(weekStart);
    final doc = _weekDoc(weekStart);
    var skipped = <String>{};
    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(doc);
      final week = (snap.exists && snap.data() != null)
          ? PayrollWeek.fromMap(weekId, snap.data()!)
          : PayrollWeek.empty(weekStart);

      final resolved = <String, PayrollPayslip>{};
      final skippedThisTry = <String>{};
      mutations.forEach((id, mutate) {
        final stored = week.payslips[id];
        final current = stored ?? seeds[id];
        if (current == null) return;
        final precondition = preconditions[id];
        if (precondition != null && !precondition(current)) {
          skippedThisTry.add(id);
          return;
        }
        final next = recomputePayslip(mutate(current), settings: settings)
            .copyWith(updatedBy: updatedBy);
        // Already saved exactly like this (typically by another admin's
        // PayrollScheduleSync a moment earlier): writing it again would only
        // bump updatedAt and wake every listener on the week.
        if (stored != null && payslipsMatchIgnoringStamp(stored, next)) return;
        resolved[id] = next;
      });
      skipped = skippedThisTry;
      if (resolved.isEmpty) return;

      if (snap.exists) {
        final updates = <String, dynamic>{
          for (final e in resolved.entries) 'payslips.${e.key}': e.value.toMap(),
          'updatedAt': FieldValue.serverTimestamp(),
          if (updatedBy != null) 'updatedBy': updatedBy,
        };
        txn.update(doc, updates);
      } else {
        final merged = {...week.payslips, ...resolved};
        txn.set(doc, week.copyWith(payslips: merged, updatedBy: updatedBy).toMap(),
            SetOptions(merge: false));
      }
    });
    return skipped;
  }

  /// Updates only the week-level finalize fields, leaving every payslip
  /// untouched. Runs in a transaction so that, if the week doc doesn't exist
  /// yet, it's created as a fully-valid empty week (with `weekStart` /
  /// `payslips`) rather than a bare finalize-only doc — the latter would be
  /// rejected by the `validPayrollWeek()` security rule.
  Future<void> updateFinalizeFields(
    DateTime weekStart, {
    required bool isFinalized,
    DateTime? finalizedAt,
    String? finalizedBy,
  }) async {
    final doc = _weekDoc(weekStart);
    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(doc);
      final fields = {
        'isFinalized': isFinalized,
        'finalizedAt':
            finalizedAt != null ? Timestamp.fromDate(finalizedAt) : null,
        'finalizedBy': finalizedBy,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (snap.exists && snap.data() != null) {
        txn.update(doc, fields);
      } else {
        txn.set(doc, {
          ...PayrollWeek.empty(weekStart).toMap(),
          ...fields,
        });
      }
    });
  }

  /// Adds a blank, rate-snapshotted payslip for any [distributors] missing
  /// from the week, without touching existing payslips. Call once when a
  /// week is first opened. Runs as a single transaction (read + write) so
  /// two admins opening the same brand-new week at the same time can't
  /// race each other into clobbering one another's initialization.
  Future<void> ensureWeekInitialized(
    DateTime weekStart,
    List<Distributor> distributors,
    PayrollSettings settings,
  ) async {
    final weekId = weekIdFor(weekStart);
    final doc = _weekDoc(weekStart);
    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(doc);
      final week = (snap.exists && snap.data() != null)
          ? PayrollWeek.fromMap(weekId, snap.data()!)
          : PayrollWeek.empty(weekStart);
      final missing = distributors
          .where((d) => !week.payslips.containsKey(d.id))
          .toList();
      if (missing.isEmpty) return;

      final payslips = Map<String, PayrollPayslip>.from(week.payslips);
      for (final d in missing) {
        payslips[d.id] = PayrollPayslip.blank(
          distributorId: d.id,
          distributorName: d.name,
          weekStart: weekStart,
          settings: settings,
          profile: d.payroll ?? const DistributorPayrollProfile(),
        );
      }
      txn.set(doc, week.copyWith(payslips: payslips).toMap(),
          SetOptions(merge: false));
    });
  }

  /// Pure recompute of every payslip's totals from its own snapshotted
  /// rates — no Firestore reads. Caller decides when to [saveWeek] the
  /// result.
  ///
  /// When [settings] is supplied, each payslip's frozen
  /// `bonusCodeAmountsSnapshot` is topped up (in the returned copy, so it's
  /// persisted on save) with any special day codes present in current
  /// settings but missing from the snapshot — i.e. codes added after this
  /// week's payslips were first created. Existing snapshot values are never
  /// overwritten, so editing an existing code's amount still doesn't rewrite
  /// history; only genuinely-new codes are filled in. Passing null keeps the
  /// snapshot exactly as-is (a pure totals-only recompute).
  PayrollWeek recomputeWeek(PayrollWeek week, {PayrollSettings? settings}) {
    final payslips = week.payslips
        .map((id, p) => MapEntry(id, recomputePayslip(p, settings: settings)));
    return week.copyWith(payslips: payslips);
  }

  /// Pure recompute of one payslip's totals from its own snapshotted rates —
  /// the single-payslip core shared by [recomputeWeek] and every
  /// transactional mutation. See [recomputeWeek] for the [settings]
  /// bonus-code top-up semantics.
  PayrollPayslip recomputePayslip(PayrollPayslip p, {PayrollSettings? settings}) {
    final bonusAmounts = settings != null
        ? p.effectiveBonusCodeAmounts(settings)
        : p.bonusCodeAmountsSnapshot;
    final gross = calc.weeklyGross(
      p.dailyEntries,
      dayRate: p.dayRateSnapshot,
      bonusCodeAmounts: bonusAmounts,
      perSetRate: p.perSetRateSnapshot,
      estimateBonus: p.estimateBonusSnapshot,
    );
    final net = calc.netWage(
      gross: gross,
      advanceDeductionAmount: p.advanceDeductionAmount,
      extraEarningsAmount: p.extraEarningsAmount,
      savingsWithdrawalAmount:
          p.isWithdrawingSavingsThisWeek ? p.savingsWithdrawalAmount : 0,
    );
    return p.copyWith(
      bonusCodeAmountsSnapshot: settings != null ? bonusAmounts : null,
      grossWage: gross,
      netWage: net,
    );
  }

  /// Atomically writes [entry] as [distributor]'s day for [date], within
  /// whichever payroll week that date falls in — one Firestore transaction
  /// (one read, one write) through [mutatePayslipsTxn]. Initializes the
  /// week/payslip on the fly if this is the first entry recorded for this
  /// distributor that week, and never clobbers a concurrent edit (e.g. from
  /// the Ops Stats grid) since the read and write happen inside the same
  /// transaction.
  ///
  /// Only this distributor's `payslips.<id>` is written, not the whole week
  /// document (every distributor's payslip) as this used to — a much smaller
  /// upload, and a save identical to what is stored writes nothing at all.
  ///
  /// Completes once the stats are committed. The live week's automatic
  /// advance deduction is reconciled after that, without the caller waiting
  /// on it — see [_reconcileDeductionInBackground].
  Future<void> saveDailyEntryForDistributor({
    required Distributor distributor,
    required DateTime date,
    required PayrollDailyEntry entry,
    required PayrollSettings settings,
  }) async {
    final weekStart = weekStartFor(date);
    final dayKey = dayKeyFor(date);

    await mutatePayslipsTxn(
      weekStart,
      mutations: {
        distributor.id: (p) =>
            p.copyWith(dailyEntries: {...p.dailyEntries, dayKey: entry}),
      },
      seeds: {
        distributor.id: PayrollPayslip.blank(
          distributorId: distributor.id,
          distributorName: distributor.name,
          weekStart: weekStart,
          settings: settings,
          profile: distributor.payroll ?? const DistributorPayrollProfile(),
        ),
      },
      settings: settings,
    );

    // The Track Editor writes wage stats through this method (bypassing the
    // PayrollProvider), so it doesn't get the provider's post-stats
    // auto-deduction pass. Run it here too — but only for the live pay week,
    // matching the provider's rule that earlier weeks are handled manually.
    if (weekStart == weekStartFor(scheduleNow())) {
      _reconcileDeductionInBackground(
        weekStart: weekStart,
        distributorId: distributor.id,
        settings: settings,
      );
    }
  }

  /// Deduction passes started by [_reconcileDeductionInBackground] that have
  /// not finished — shared by every [PayrollService] instance, as they all
  /// report under the one [SyncStatus] source.
  static int _backgroundDeductions = 0;

  /// [autoApplyDefaultAdvanceDeduction] without holding up the save that
  /// triggered it: it is its own transaction plus two ledger queries, which
  /// the person saving used to sit through after their stats had already
  /// reached payroll. Same reasoning as the Payroll screen, which also runs
  /// its pass after the save rather than inside it.
  ///
  /// Counted as a pending write while it runs, so the web "leave page?"
  /// warning covers it. Best-effort: the stats are already committed, and
  /// the Payroll screen and [PayrollScheduleSync] reconcile deductions on
  /// the live week too, so a failure here is caught up there.
  void _reconcileDeductionInBackground({
    required DateTime weekStart,
    required String distributorId,
    required PayrollSettings settings,
  }) {
    void report() => SyncStatus.instance
        .reportPendingWrites('payrollDeductions', _backgroundDeductions);
    _backgroundDeductions++;
    report();
    unawaited(autoApplyDefaultAdvanceDeduction(
      weekStart: weekStart,
      distributorId: distributorId,
      settings: settings,
    ).catchError((Object e) {
      debugPrint('PayrollService: background advance deduction for '
          '$distributorId failed: $e');
    }).whenComplete(() {
      _backgroundDeductions--;
      report();
    }));
  }

  // ── Settings ───────────────────────────────────────────────────────────

  Future<PayrollSettings> getSettings() async {
    final snap = await _settingsDoc.get();
    if (snap.exists && snap.data() != null) {
      return PayrollSettings.fromMap(snap.data()!);
    }
    return PayrollSettings.defaults();
  }

  Stream<PayrollSettings> streamSettings() => _settingsDoc.snapshots().map(
        (snap) => snap.exists && snap.data() != null
            ? PayrollSettings.fromMap(snap.data()!)
            : PayrollSettings.defaults(),
      );

  Future<void> saveSettings(PayrollSettings settings) async {
    await _settingsDoc.set(settings.toMap(), SetOptions(merge: false));
  }

  // ── Advances (multi-advance, FIFO repayment) ────────────────────────────

  /// All of a distributor's advances, oldest paid-date first — the order
  /// they're repaid in.
  Future<List<Advance>> getAdvances(String distributorId) async {
    final snap = await _advancesCol(distributorId).orderBy('datePaid').get();
    return [for (final d in snap.docs) Advance.fromMap(d.id, d.data())];
  }

  Stream<List<Advance>> streamAdvances(String distributorId) =>
      _advancesCol(distributorId).orderBy('datePaid').snapshots().map((snap) =>
          [for (final d in snap.docs) Advance.fromMap(d.id, d.data())]);

  /// Live total outstanding advance/penalty balance per distributor, across
  /// ALL their advances — one collection-group listener instead of one per
  /// distributor, so the Payslips list can show each distributor's remaining
  /// balance without N separate subscriptions. Keyed by distributorId;
  /// distributors with nothing outstanding are omitted.
  Stream<Map<String, double>> streamOutstandingByDistributor() =>
      _firestore.collectionGroup('advances').snapshots().map((snap) {
        final byDistributor = <String, double>{};
        for (final d in snap.docs) {
          final distributorId = d.reference.parent.parent?.id;
          if (distributorId == null) continue;
          final balance = Advance.fromMap(d.id, d.data()).balance;
          if (balance <= 0.005) continue;
          byDistributor[distributorId] =
              (byDistributor[distributorId] ?? 0) + balance;
        }
        return byDistributor;
      });

  /// Full repayment history across every advance, most recent first — the
  /// table the user wants to be able to review.
  Stream<List<AdvanceRepayment>> streamRepayments(String distributorId) =>
      _repaymentsCol(distributorId)
          .orderBy('date', descending: true)
          .snapshots()
          .map((snap) => [
                for (final d in snap.docs)
                  AdvanceRepayment.fromMap(d.id, d.data())
              ]);

  /// One-shot fetch of the full repayment history — used when generating a
  /// payslip PDF, where a live stream isn't appropriate.
  Future<List<AdvanceRepayment>> getRepayments(String distributorId) async {
    final snap = await _repaymentsCol(distributorId)
        .orderBy('date', descending: true)
        .get();
    return [
      for (final d in snap.docs) AdvanceRepayment.fromMap(d.id, d.data())
    ];
  }

  /// Records a brand-new advance: amount, date paid, and the installment
  /// amount to default to each week while it's still outstanding.
  Future<void> addAdvance(
    String distributorId, {
    DeductionType type = DeductionType.advance,
    String? label,
    required double amount,
    required DateTime datePaid,
    required double preferredInstallmentAmount,
    String? note,
  }) async {
    final ref = _advancesCol(distributorId).doc();
    final advance = Advance(
      id: ref.id,
      type: type,
      label: label,
      amount: amount,
      datePaid: datePaid,
      preferredInstallmentAmount: preferredInstallmentAmount,
      note: note,
      createdAt: DateTime.now(),
    );
    await ref.set(advance.toMap());
  }

  /// Edits an advance's recorded amount / preferred installment / note.
  ///
  /// NOTE: this does NOT re-reconcile any already-open week's deduction
  /// against the new amount. If this is ever wired to the UI for editing the
  /// principal, the caller must also run [autoApplyDefaultAdvanceDeduction]
  /// (or [applyAdvanceDeduction]) for the live week afterwards so its
  /// deduction/net stays consistent. `amountRepaid` is preserved (it's a
  /// server-maintained counter — never overwrite it from a stale local copy),
  /// so only pass an [updated] built from a freshly-read advance.
  Future<void> updateAdvance(String distributorId, Advance updated) async {
    await _advancesCol(distributorId).doc(updated.id).update({
      'type': updated.type.name,
      'label': updated.label,
      'amount': updated.amount,
      'datePaid': Timestamp.fromDate(updated.datePaid),
      'preferredInstallmentAmount': updated.preferredInstallmentAmount,
      'note': updated.note,
    });
  }

  /// Deletes an advance recorded in error, along with every repayment linked
  /// to it (so no repayment doc is ever left orphaned, pointing at an advance
  /// that no longer exists). Batched so the advance and its repayments go in
  /// one atomic write.
  ///
  /// NOTE: this does not re-reconcile the payslip deduction of any week those
  /// repayments belonged to — if wired to the UI, follow with
  /// [autoApplyDefaultAdvanceDeduction] for the live week.
  Future<void> deleteAdvance(String distributorId, String advanceId) async {
    final linked = await _repaymentsCol(distributorId)
        .where('advanceId', isEqualTo: advanceId)
        .get();
    final batch = _firestore.batch();
    for (final d in linked.docs) {
      batch.delete(d.reference);
    }
    batch.delete(_advancesCol(distributorId).doc(advanceId));
    await batch.commit();
  }

  /// Atomically sets [distributorId]'s advance deduction for the week
  /// starting [weekStart] AND reconciles it against the distributor's
  /// outstanding advances (oldest-first / FIFO) — all in one transaction.
  ///
  /// This folds what used to be two separate writes (the payslip amount via
  /// the provider, then a `syncAdvanceDeduction` ledger pass) into a single
  /// atomic operation. The week doc is read *inside* the transaction and the
  /// payslip is rebuilt from that fresh copy, so a concurrent same-
  /// distributor edit can't be clobbered by a stale local snapshot, and
  /// there's no window where the ledger is updated but the payslip's amount
  /// or applied-flag never catches up.
  ///
  /// The advance/repayment collections are read with plain (non-transactional)
  /// queries — the Flutter SDK can't read a *query* inside a transaction —
  /// but correctness is preserved by the **reverse-and-redo** approach keyed
  /// by `linkedWeekId`: any repayment(s) already posted for this week are
  /// undone before re-allocating the requested amount from scratch, so the
  /// operation always converges instead of double-posting, no matter how many
  /// times it runs.
  Future<void> applyAdvanceDeduction({
    required DateTime weekStart,
    required String distributorId,
    required bool isDeducting,
    required double amount,
    required String note,
    required PayrollSettings settings,
    PayrollPayslip? seed,
    String? updatedBy,
    bool markOverridden = false,
  }) async {
    final weekId = weekIdFor(weekStart);
    final payDate = payDateFor(weekStart);
    final weekDoc = _weekDoc(weekStart);

    await _firestore.runTransaction((txn) async {
      final weekSnap = await txn.get(weekDoc);
      final week = (weekSnap.exists && weekSnap.data() != null)
          ? PayrollWeek.fromMap(weekId, weekSnap.data()!)
          : PayrollWeek.empty(weekStart);
      final current = week.payslips[distributorId] ?? seed;
      if (current == null) return;

      final advances = await _advancesOldestFirst(distributorId);
      final linkedDocs = await _linkedRepaymentDocs(distributorId, weekId);
      final base = _advancesBeforeThisWeek(advances, linkedDocs);
      _reallocateWeekDeduction(
        txn,
        distributorId: distributorId,
        baseAdvances: base,
        linkedDocs: linkedDocs,
        amount: isDeducting ? amount : 0,
        note: note,
        payDate: payDate,
        weekId: weekId,
      );

      final updatedPayslip = recomputePayslip(
        current.copyWith(
          isDeductingAdvanceThisWeek: isDeducting,
          advanceDeductionAmount: amount,
          advanceDeductionNote: note,
          advanceAppliedToLedger: isDeducting,
          // An explicit admin action switches off auto-deduction for the week;
          // passing null (when not marking) preserves the current flag.
          advanceDeductionOverridden: markOverridden ? true : null,
        ),
        settings: settings,
      ).copyWith(updatedBy: updatedBy);
      _writeSinglePayslip(
          txn, weekDoc, weekSnap, week, distributorId, updatedPayslip, updatedBy);
    });
  }

  /// Recomputes [distributorId]'s DEFAULT advance deduction for the week and
  /// reconciles the ledger — the automatic "deduct by default once this
  /// week's gross exceeds R500" behaviour.
  ///
  /// No-ops if the payslip has been manually overridden by an admin (so a
  /// deliberate admin decision, including choosing NOT to deduct, is never
  /// undone), if the week doc doesn't exist yet, or if the payslip already
  /// reflects the desired deduction (the common steady-state case — avoids
  /// needless ledger churn on every stats save). Otherwise the deduction is
  /// the oldest outstanding advance's preferred instalment — or its whole
  /// remaining balance when less than one instalment is still owed — applied
  /// **all-or-nothing** against the R500 net floor: if the week can't afford
  /// the full amount it deducts NOTHING and rolls over to a week that can,
  /// rather than posting a clipped part-instalment. If nothing is
  /// outstanding, or this week can't afford the instalment, any prior auto
  /// deduction for the week is reversed. Idempotent (reverse-and-redo keyed
  /// by `linkedWeekId`).
  Future<void> autoApplyDefaultAdvanceDeduction({
    required DateTime weekStart,
    required String distributorId,
    required PayrollSettings settings,
    String? updatedBy,
  }) async {
    final weekId = weekIdFor(weekStart);
    final payDate = payDateFor(weekStart);
    final weekDoc = _weekDoc(weekStart);

    await _firestore.runTransaction((txn) async {
      final weekSnap = await txn.get(weekDoc);
      if (!weekSnap.exists || weekSnap.data() == null) return;
      final week = PayrollWeek.fromMap(weekId, weekSnap.data()!);
      final current = week.payslips[distributorId];
      if (current == null || current.advanceDeductionOverridden) return;

      // Two independent ledger reads, side by side rather than one after
      // the other — every attempt of this transaction pays for them.
      final ledger = await Future.wait<Object>([
        _advancesOldestFirst(distributorId),
        _linkedRepaymentDocs(distributorId, weekId),
      ]);
      final advances = ledger[0] as List<Advance>;
      final linkedDocs =
          ledger[1] as List<QueryDocumentSnapshot<Map<String, dynamic>>>;
      final base = _advancesBeforeThisWeek(advances, linkedDocs);
      final outstanding = base.where((a) => a.balance > 0.005).toList();
      final totalOutstanding =
          outstanding.fold<double>(0, (t, a) => t + a.balance);

      // Never leave the distributor with less than R500 net for the week —
      // and never break an agreed instalment up to squeeze under that floor.
      // It's all-or-nothing: a week either affords the WHOLE instalment (or
      // the whole remaining balance, when that's less than one instalment)
      // or nothing is deducted and it rolls over to a week that can afford
      // it. Clipping to the headroom instead — the old behaviour — silently
      // turned a R100/week plan into odd amounts like R16 on a low week.
      final headroom = current.grossWage - 500;
      var amount = 0.0;
      if (totalOutstanding > 0.005) {
        final oldest = outstanding.first;
        final instalment = oldest.preferredInstallmentAmount > 0
            ? oldest.preferredInstallmentAmount
            : oldest.balance;
        // One full instalment, or everything still owed if that's less.
        final desired =
            instalment > totalOutstanding ? totalOutstanding : instalment;
        if (desired <= headroom) amount = desired;
      }
      final isDeducting = amount > 0.005;

      // Steady-state skip: the payslip already matches the desired state, so
      // leave the ledger exactly as-is (nothing reversed, nothing written).
      if (current.isDeductingAdvanceThisWeek == isDeducting &&
          (current.advanceDeductionAmount - amount).abs() < 0.005) {
        return;
      }

      _reallocateWeekDeduction(
        txn,
        distributorId: distributorId,
        baseAdvances: base,
        linkedDocs: linkedDocs,
        amount: isDeducting ? amount : 0,
        note: current.advanceDeductionNote,
        payDate: payDate,
        weekId: weekId,
      );

      final updatedPayslip = recomputePayslip(
        current.copyWith(
          isDeductingAdvanceThisWeek: isDeducting,
          advanceDeductionAmount: amount,
          advanceAppliedToLedger: isDeducting,
        ),
        settings: settings,
      ).copyWith(updatedBy: updatedBy);
      _writeSinglePayslip(
          txn, weekDoc, weekSnap, week, distributorId, updatedPayslip, updatedBy);
    });
  }

  // ── Advance-ledger transaction helpers (shared by manual + auto deduct) ──

  Future<List<Advance>> _advancesOldestFirst(String distributorId) async {
    final snap = await _advancesCol(distributorId).orderBy('datePaid').get();
    return [for (final d in snap.docs) Advance.fromMap(d.id, d.data())];
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _linkedRepaymentDocs(String distributorId, String weekId) async {
    final snap = await _repaymentsCol(distributorId)
        .where('linkedWeekId', isEqualTo: weekId)
        .get();
    return snap.docs;
  }

  /// [advances] rewound to their pre-this-week state (this week's repayments
  /// added back to each advance's balance) — read-only, mutates nothing, so a
  /// caller can decide whether anything actually needs re-writing.
  List<Advance> _advancesBeforeThisWeek(List<Advance> advances,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> linkedDocs) {
    final reversedByAdvance = <String, double>{};
    for (final d in linkedDocs) {
      final r = AdvanceRepayment.fromMap(d.id, d.data());
      reversedByAdvance[r.advanceId] =
          (reversedByAdvance[r.advanceId] ?? 0) + r.amount;
    }
    return [
      for (final a in advances)
        reversedByAdvance[a.id] != null
            ? a.copyWith(amountRepaid: a.amountRepaid - reversedByAdvance[a.id]!)
            : a,
    ];
  }

  /// Deletes this week's existing repayment docs and re-allocates [amount]
  /// oldest-advance-first over [baseAdvances] (the pre-week state), writing
  /// fresh repayment docs — the shared reverse-and-redo core.
  ///
  /// Each advance's stored `amountRepaid` is adjusted with an ATOMIC
  /// `FieldValue.increment` of the net change (new allocation minus what was
  /// reversed), never a blind absolute overwrite. Because the advance docs
  /// are read non-transactionally (the Flutter SDK can't read a query inside
  /// a transaction), an absolute write here could lose an update from a
  /// concurrent deduction for the same distributor on a *different* week;
  /// server-side increments compose correctly instead, so `amountRepaid`
  /// always stays equal to the true sum of that advance's repayment docs.
  void _reallocateWeekDeduction(
    Transaction txn, {
    required String distributorId,
    required List<Advance> baseAdvances,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> linkedDocs,
    required double amount,
    required String note,
    required DateTime payDate,
    required String weekId,
  }) {
    final advancesCol = _advancesCol(distributorId);
    final repaymentsCol = _repaymentsCol(distributorId);

    // Reverse: delete this week's repayment docs, tracking how much comes
    // back off each advance.
    final reversedByAdvance = <String, double>{};
    for (final d in linkedDocs) {
      final r = AdvanceRepayment.fromMap(d.id, d.data());
      reversedByAdvance[r.advanceId] =
          (reversedByAdvance[r.advanceId] ?? 0) + r.amount;
      txn.delete(d.reference);
    }

    // Re-allocate this week's deduction over the pre-week balances,
    // oldest-advance-first.
    final allocByAdvance = <String, double>{};
    final advances = [...baseAdvances];
    var remaining = amount;
    for (var i = 0; i < advances.length && remaining > 0.005; i++) {
      final a = advances[i];
      if (a.balance <= 0) continue;
      final alloc = remaining < a.balance ? remaining : a.balance;
      final repayRef = repaymentsCol.doc();
      txn.set(
        repayRef,
        AdvanceRepayment(
          id: repayRef.id,
          advanceId: a.id,
          amount: alloc,
          date: payDate,
          linkedWeekId: weekId,
          note: note.isEmpty ? null : note,
          createdAt: DateTime.now(),
        ).toMap(),
      );
      allocByAdvance[a.id] = (allocByAdvance[a.id] ?? 0) + alloc;
      advances[i] = a.copyWith(amountRepaid: a.amountRepaid + alloc);
      remaining -= alloc;
    }

    // Apply only the net delta to each touched advance's stored counter.
    final touched = {...reversedByAdvance.keys, ...allocByAdvance.keys};
    for (final id in touched) {
      final delta = (allocByAdvance[id] ?? 0) - (reversedByAdvance[id] ?? 0);
      if (delta.abs() < 0.000001) continue;
      txn.update(
          advancesCol.doc(id), {'amountRepaid': FieldValue.increment(delta)});
    }
  }

  /// Writes a single distributor's [payslip] into the week doc within [txn] —
  /// a targeted `payslips.<id>` field update when the doc exists, or a full
  /// create otherwise.
  void _writeSinglePayslip(
    Transaction txn,
    DocumentReference<Map<String, dynamic>> weekDoc,
    DocumentSnapshot<Map<String, dynamic>> weekSnap,
    PayrollWeek week,
    String distributorId,
    PayrollPayslip payslip,
    String? updatedBy,
  ) {
    if (weekSnap.exists) {
      txn.update(weekDoc, {
        'payslips.$distributorId': payslip.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
        if (updatedBy != null) 'updatedBy': updatedBy,
      });
    } else {
      txn.set(
          weekDoc,
          week.copyWith(payslips: {
            ...week.payslips,
            distributorId: payslip,
          }, updatedBy: updatedBy).toMap(),
          SetOptions(merge: false));
    }
  }

  // ── Savings (multi-deposit, FIFO withdrawal) ────────────────────────────

  /// All of a distributor's savings deposits, oldest first — the order
  /// they're paid back out in.
  Future<List<SavingsDeposit>> getSavingsDeposits(String distributorId) async {
    final snap =
        await _depositsCol(distributorId).orderBy('dateDeposited').get();
    return [for (final d in snap.docs) SavingsDeposit.fromMap(d.id, d.data())];
  }

  Stream<List<SavingsDeposit>> streamSavingsDeposits(String distributorId) =>
      _depositsCol(distributorId).orderBy('dateDeposited').snapshots().map(
          (snap) => [
                for (final d in snap.docs)
                  SavingsDeposit.fromMap(d.id, d.data())
              ]);

  /// Full withdrawal history across every deposit, most recent first.
  Stream<List<SavingsWithdrawal>> streamSavingsWithdrawals(
          String distributorId) =>
      _withdrawalsCol(distributorId)
          .orderBy('date', descending: true)
          .snapshots()
          .map((snap) => [
                for (final d in snap.docs)
                  SavingsWithdrawal.fromMap(d.id, d.data())
              ]);

  /// One-shot fetch of the full withdrawal history — used when generating a
  /// payslip PDF, where a live stream isn't appropriate.
  Future<List<SavingsWithdrawal>> getSavingsWithdrawals(
      String distributorId) async {
    final snap = await _withdrawalsCol(distributorId)
        .orderBy('date', descending: true)
        .get();
    return [
      for (final d in snap.docs) SavingsWithdrawal.fromMap(d.id, d.data())
    ];
  }

  /// Records a brand-new savings deposit: amount, date deposited, and the
  /// withdrawal amount to default to each week once it starts being paid
  /// back out.
  Future<void> addSavingsDeposit(
    String distributorId, {
    required double amount,
    required DateTime dateDeposited,
    required double preferredWithdrawalAmount,
    String? note,
  }) async {
    final ref = _depositsCol(distributorId).doc();
    final deposit = SavingsDeposit(
      id: ref.id,
      amount: amount,
      dateDeposited: dateDeposited,
      preferredWithdrawalAmount: preferredWithdrawalAmount,
      note: note,
      createdAt: DateTime.now(),
    );
    await ref.set(deposit.toMap());
  }

  /// Edits a deposit's recorded amount / preferred withdrawal / note.
  Future<void> updateSavingsDeposit(
      String distributorId, SavingsDeposit updated) async {
    await _depositsCol(distributorId)
        .doc(updated.id)
        .set(updated.toMap(), SetOptions(merge: false));
  }

  /// Deletes a deposit that was recorded in error. Any withdrawals already
  /// linked to it are left as-is (historical record); in practice this
  /// should only be used on deposits with no withdrawals yet.
  Future<void> deleteSavingsDeposit(
      String distributorId, String depositId) async {
    await _depositsCol(distributorId).doc(depositId).delete();
  }

  /// Atomically sets [distributorId]'s savings withdrawal for the week
  /// starting [weekStart] AND reconciles it against the distributor's
  /// deposits, paying out **oldest deposit first** (FIFO) — the mirror image
  /// of [applyAdvanceDeduction]: this *adds* to net pay instead of
  /// subtracting, and increments `amountWithdrawn` instead of `amountRepaid`.
  /// Same single-transaction, fresh-week-read, reverse-and-redo guarantees.
  Future<void> applySavingsWithdrawal({
    required DateTime weekStart,
    required String distributorId,
    required bool isWithdrawing,
    required double amount,
    required String note,
    required PayrollSettings settings,
    PayrollPayslip? seed,
    String? updatedBy,
  }) async {
    final weekId = weekIdFor(weekStart);
    final payDate = payDateFor(weekStart);
    final weekDoc = _weekDoc(weekStart);
    final depositsCol = _depositsCol(distributorId);
    final withdrawalsCol = _withdrawalsCol(distributorId);

    await _firestore.runTransaction((txn) async {
      // ── Reads (week doc transactionally; ledger via plain queries) ──
      final weekSnap = await txn.get(weekDoc);
      final week = (weekSnap.exists && weekSnap.data() != null)
          ? PayrollWeek.fromMap(weekId, weekSnap.data()!)
          : PayrollWeek.empty(weekStart);
      final current = week.payslips[distributorId] ?? seed;
      if (current == null) return;

      final depositsSnap = await depositsCol.orderBy('dateDeposited').get();
      final deposits = [
        for (final d in depositsSnap.docs)
          SavingsDeposit.fromMap(d.id, d.data())
      ];
      final linkedSnap =
          await withdrawalsCol.where('linkedWeekId', isEqualTo: weekId).get();

      // ── Reverse any withdrawals already posted for this week ──
      // (delete the docs and rewind each deposit's in-memory balance to its
      // pre-week state, so the re-allocation below sees true availability).
      final reversedByDeposit = <String, double>{};
      for (final d in linkedSnap.docs) {
        final w = SavingsWithdrawal.fromMap(d.id, d.data());
        reversedByDeposit[w.depositId] =
            (reversedByDeposit[w.depositId] ?? 0) + w.amount;
        txn.delete(d.reference);
      }
      for (var i = 0; i < deposits.length; i++) {
        final reversed = reversedByDeposit[deposits[i].id];
        if (reversed != null) {
          deposits[i] = deposits[i].copyWith(
              amountWithdrawn: deposits[i].amountWithdrawn - reversed);
        }
      }

      // ── Re-allocate this week's requested withdrawal, oldest deposit first ──
      final allocByDeposit = <String, double>{};
      var remaining = isWithdrawing ? amount : 0.0;
      for (var i = 0; i < deposits.length && remaining > 0.005; i++) {
        final d = deposits[i];
        if (d.balance <= 0) continue;
        final alloc = remaining < d.balance ? remaining : d.balance;
        final withdrawRef = withdrawalsCol.doc();
        txn.set(
          withdrawRef,
          SavingsWithdrawal(
            id: withdrawRef.id,
            depositId: d.id,
            amount: alloc,
            date: payDate,
            linkedWeekId: weekId,
            note: note.isEmpty ? null : note,
            createdAt: DateTime.now(),
          ).toMap(),
        );
        allocByDeposit[d.id] = (allocByDeposit[d.id] ?? 0) + alloc;
        deposits[i] = d.copyWith(amountWithdrawn: d.amountWithdrawn + alloc);
        remaining -= alloc;
      }

      // Apply only the net delta to each touched deposit's stored counter via
      // an ATOMIC increment (never a blind absolute write) — same concurrency
      // rationale as the advance ledger's `_reallocateWeekDeduction`.
      final touchedDeposits = {
        ...reversedByDeposit.keys,
        ...allocByDeposit.keys
      };
      for (final id in touchedDeposits) {
        final delta = (allocByDeposit[id] ?? 0) - (reversedByDeposit[id] ?? 0);
        if (delta.abs() < 0.000001) continue;
        txn.update(depositsCol.doc(id),
            {'amountWithdrawn': FieldValue.increment(delta)});
      }

      // ── Payslip amount + applied flag, recomputed and written in the same
      //    transaction as the ledger postings above ──
      final updatedPayslip = recomputePayslip(
        current.copyWith(
          isWithdrawingSavingsThisWeek: isWithdrawing,
          savingsWithdrawalAmount: amount,
          savingsWithdrawalNote: note,
          savingsWithdrawalApplied: isWithdrawing,
        ),
        settings: settings,
      ).copyWith(updatedBy: updatedBy);

      if (weekSnap.exists) {
        txn.update(weekDoc, {
          'payslips.$distributorId': updatedPayslip.toMap(),
          'updatedAt': FieldValue.serverTimestamp(),
          if (updatedBy != null) 'updatedBy': updatedBy,
        });
      } else {
        txn.set(
            weekDoc,
            week.copyWith(payslips: {
              ...week.payslips,
              distributorId: updatedPayslip,
            }, updatedBy: updatedBy).toMap(),
            SetOptions(merge: false));
      }
    });
  }
}
