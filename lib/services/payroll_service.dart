import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/advance_ledger.dart';
import '../models/advance_transaction.dart';
import '../models/distributor.dart';
import '../models/distributor_payroll_profile.dart';
import '../models/payment_summary.dart';
import '../models/payroll_payslip.dart';
import '../models/payroll_settings.dart';
import '../models/payroll_week.dart';
import '../utils/payroll_calculator.dart' as calc;
import '../utils/payroll_week.dart';

/// CRUD + business logic for payroll, mirroring `DropsheetService`'s narrow,
/// single-responsibility style rather than the monolithic `FirestoreService`.
///
/// Storage layout:
///   `/payroll/{YYYY}/{MMM YYYY}/{weekId}`      — one doc per pay week
///   `/payrollSettings/config`                   — singleton company defaults
///   `/payrollAdvances/{distributorId}`          — ledger rollup
///   `/payrollAdvances/{distributorId}/transactions/{id}` — ledger history
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

  DocumentReference<Map<String, dynamic>> _ledgerDoc(String distributorId) =>
      _firestore.collection('payrollAdvances').doc(distributorId);

  CollectionReference<Map<String, dynamic>> _transactionsCol(
          String distributorId) =>
      _ledgerDoc(distributorId).collection('transactions');

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

  Future<void> saveWeek(PayrollWeek week) async {
    await _weekDoc(week.weekStart).set(week.toMap(), SetOptions(merge: false));
  }

  /// Adds a blank, rate-snapshotted payslip for any [distributors] missing
  /// from the week, without touching existing payslips. Call once when a
  /// week is first opened.
  Future<void> ensureWeekInitialized(
    DateTime weekStart,
    List<Distributor> distributors,
    PayrollSettings settings,
  ) async {
    final week = await getWeek(weekStart);
    final missing =
        distributors.where((d) => !week.payslips.containsKey(d.id)).toList();
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
    await saveWeek(week.copyWith(payslips: payslips));
  }

  /// Pure recompute of every payslip's totals from its own snapshotted
  /// rates — no Firestore reads. Caller decides when to [saveWeek] the
  /// result.
  PayrollWeek recomputeWeek(PayrollWeek week) {
    final payslips = week.payslips.map((id, p) {
      final gross = calc.weeklyGross(
        p.dailyEntries,
        dayRate: p.dayRateSnapshot,
        bonusCodeAmounts: p.bonusCodeAmountsSnapshot,
        perSetRate: p.perSetRateSnapshot,
        estimateBonus: p.estimateBonusSnapshot,
      );
      final transportDed = calc.transportDeduction(
        transportEligible: p.transportEligibleSnapshot,
        trips: p.transportTrips,
        farePerTrip: p.transportFareSnapshot,
      );
      final net = calc.netWage(
        gross: gross,
        transportDeduction: transportDed,
        advanceDeductionAmount: p.advanceDeductionAmount,
      );
      return MapEntry(
        id,
        p.copyWith(
          transportDeduction: transportDed,
          grossWage: gross,
          netWage: net,
        ),
      );
    });
    return week.copyWith(payslips: payslips);
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

  // ── Advance ledger ───────────────────────────────────────────────────

  Future<AdvanceLedger> getLedger(String distributorId) async {
    final snap = await _ledgerDoc(distributorId).get();
    if (snap.exists && snap.data() != null) {
      return AdvanceLedger.fromMap(distributorId, snap.data()!);
    }
    return AdvanceLedger.empty(distributorId);
  }

  Stream<AdvanceLedger> streamLedger(String distributorId) =>
      _ledgerDoc(distributorId).snapshots().map((snap) => snap.exists &&
              snap.data() != null
          ? AdvanceLedger.fromMap(distributorId, snap.data()!)
          : AdvanceLedger.empty(distributorId));

  /// Grants a new advance: posts a `grant` transaction and bumps
  /// `totalAdvanced`/`balance` on the rollup atomically.
  Future<void> recordAdvanceGrant(
    String distributorId,
    double amount, {
    String? note,
    DateTime? date,
    String? createdBy,
  }) async {
    await _firestore.runTransaction((txn) async {
      final ledgerRef = _ledgerDoc(distributorId);
      final ledgerSnap = await txn.get(ledgerRef);
      final ledger = ledgerSnap.exists && ledgerSnap.data() != null
          ? AdvanceLedger.fromMap(distributorId, ledgerSnap.data()!)
          : AdvanceLedger.empty(distributorId);

      final txnRef = _transactionsCol(distributorId).doc();
      final transaction = AdvanceTransaction(
        id: txnRef.id,
        type: AdvanceTransactionType.grant,
        amount: amount,
        date: date ?? DateTime.now(),
        note: note,
        createdBy: createdBy,
        createdAt: DateTime.now(),
      );

      txn.set(txnRef, transaction.toMap());
      final updated = AdvanceLedger(
        distributorId: distributorId,
        totalAdvanced: ledger.totalAdvanced + amount,
        totalRepaid: ledger.totalRepaid,
        balance: ledger.balance + amount,
      );
      txn.set(ledgerRef, updated.toMap(), SetOptions(merge: false));
    });
  }

  /// Reconciles [week]'s payslip for [distributorId] against the advance
  /// ledger, using **delta-based** posting keyed by `linkedWeekId` so that
  /// re-saving a payslip after an unrelated edit never double-posts the
  /// same week's deduction.
  Future<void> syncAdvanceDeduction({
    required PayrollWeek week,
    required String distributorId,
  }) async {
    final payslip = week.payslips[distributorId];
    if (payslip == null) return;
    final weekId = weekIdFor(week.weekStart);

    await _firestore.runTransaction((txn) async {
      final ledgerRef = _ledgerDoc(distributorId);
      final txnCol = _transactionsCol(distributorId);

      final ledgerSnap = await txn.get(ledgerRef);
      final ledger = ledgerSnap.exists && ledgerSnap.data() != null
          ? AdvanceLedger.fromMap(distributorId, ledgerSnap.data()!)
          : AdvanceLedger.empty(distributorId);

      final existingQuery = await txnCol
          .where('type', isEqualTo: AdvanceTransactionType.deduction.name)
          .where('linkedWeekId', isEqualTo: weekId)
          .limit(1)
          .get();
      final existing = existingQuery.docs.isEmpty
          ? null
          : AdvanceTransaction.fromMap(
              existingQuery.docs.first.id, existingQuery.docs.first.data());

      final wantsDeduction = payslip.isDeductingAdvanceThisWeek;
      final wantedAmount = payslip.advanceDeductionAmount;

      double repaidDelta = 0;

      if (existing == null) {
        if (wantsDeduction && wantedAmount != 0) {
          // No prior post for this week — post the full deduction.
          final ref = txnCol.doc();
          final t = AdvanceTransaction(
            id: ref.id,
            type: AdvanceTransactionType.deduction,
            amount: -wantedAmount,
            date: week.payDate,
            linkedWeekId: weekId,
            createdAt: DateTime.now(),
          );
          txn.set(ref, t.toMap());
          repaidDelta = wantedAmount;
        }
        // Not wanting a deduction and nothing posted yet — nothing to do.
      } else {
        final postedAmount = -existing.amount; // stored signed negative
        if (!wantsDeduction) {
          // Was posted, now unchecked — reverse it fully (never delete
          // history, post an offsetting adjustment instead).
          final ref = txnCol.doc();
          final t = AdvanceTransaction(
            id: ref.id,
            type: AdvanceTransactionType.adjustment,
            amount: postedAmount,
            date: DateTime.now(),
            linkedWeekId: weekId,
            note: 'Reversal of $weekId deduction',
            createdAt: DateTime.now(),
          );
          txn.set(ref, t.toMap());
          repaidDelta = -postedAmount;
        } else if (wantedAmount != postedAmount) {
          // Amount changed — post only the delta as an adjustment.
          final delta = wantedAmount - postedAmount;
          final ref = txnCol.doc();
          final t = AdvanceTransaction(
            id: ref.id,
            type: AdvanceTransactionType.adjustment,
            amount: -delta,
            date: DateTime.now(),
            linkedWeekId: weekId,
            note: 'Adjustment of $weekId deduction',
            createdAt: DateTime.now(),
          );
          txn.set(ref, t.toMap());
          repaidDelta = delta;
        }
        // Amount unchanged — nothing to do.
      }

      if (repaidDelta != 0) {
        final updated = AdvanceLedger(
          distributorId: distributorId,
          totalAdvanced: ledger.totalAdvanced,
          totalRepaid: ledger.totalRepaid + repaidDelta,
          balance: ledger.balance - repaidDelta,
        );
        txn.set(ledgerRef, updated.toMap(), SetOptions(merge: false));
      }
    });

    // Reflect the post on the payslip so the UI doesn't re-trigger it.
    final updatedPayslip =
        payslip.copyWith(advanceAppliedToLedger: payslip.isDeductingAdvanceThisWeek);
    final updatedWeek = week.copyWith(payslips: {
      ...week.payslips,
      distributorId: updatedPayslip,
    });
    await saveWeek(updatedWeek);
  }

  // ── Payment summary ────────────────────────────────────────────────────

  Future<PaymentSummary> getPaymentSummary(DateTime anyDateInWeek) async {
    final week = await getWeek(anyDateInWeek);
    final lines = week.payslips.values
        .map((p) => PaymentSummaryLine(
              distributorId: p.distributorId,
              distributorName: p.distributorName,
              netWage: p.netWage,
              bankName: p.bankNameSnapshot,
              bankAccountHolder: p.bankAccountHolderSnapshot,
              bankAccountNumber: p.bankAccountNumberSnapshot,
              bankBranchCode: p.bankBranchCodeSnapshot,
              paymentMethod: p.paymentMethodSnapshot,
            ))
        .toList();
    final totalNet = lines.fold<double>(0, (total, l) => total + l.netWage);
    return PaymentSummary(
      weekStart: week.weekStart,
      payDate: week.payDate,
      lines: lines,
      totalNet: totalNet,
    );
  }
}
