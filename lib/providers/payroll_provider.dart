import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/advance.dart';
import '../models/distributor.dart';
import '../models/distributor_payroll_profile.dart';
import '../models/payment_account.dart';
import '../models/payment_status.dart';
import '../models/payroll_daily_entry.dart';
import '../models/payroll_payslip.dart';
import '../models/payroll_settings.dart';
import '../models/payroll_week.dart';
import '../services/firestore_service.dart';
import '../services/payroll_service.dart';
import '../utils/payroll_week.dart';
import '../utils/schedule_time.dart';
import 'auth_provider.dart';
import 'schedule_provider.dart';

final payrollServiceRiverpod =
    riverpod.Provider<PayrollService>((ref) => PayrollService());

final payrollRiverpod = riverpod.ChangeNotifierProvider<PayrollProvider>(
  (ref) => PayrollProvider(ref.read(payrollServiceRiverpod), ref),
);

/// Manages the currently selected payroll week.
///
/// Unlike [DropsheetProvider], there is no external schedule/job-list to
/// auto-sync from — all payroll data entry is manual — so this provider is
/// deliberately thin: load the week, mutate locally, recompute, save.
class PayrollProvider extends ChangeNotifier {
  final PayrollService _service;
  final riverpod.Ref? _ref;

  StreamSubscription<PayrollWeek>? _weekSub;
  StreamSubscription<PayrollSettings>? _settingsSub;
  StreamSubscription<Map<String, double>>? _outstandingSub;

  DateTime _weekStart = defaultPayrollWeekStart();
  PayrollWeek _week = PayrollWeek.empty(defaultPayrollWeekStart());
  PayrollSettings _settings = PayrollSettings.defaults();
  Map<String, double> _outstandingByDistributor = const {};
  bool _isLoading = false;
  String? _error;

  PayrollProvider(this._service, [this._ref]) {
    _listenSettings();
    _listenOutstanding();
    _listenWeek();
  }

  DateTime get weekStart => _weekStart;
  DateTime get weekEnd => weekEndFor(_weekStart);
  DateTime get payDate => payDateFor(_weekStart);
  PayrollWeek get week => _week;
  PayrollSettings get settings => _settings;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Total outstanding advance/penalty balance for [distributorId] across all
  /// their advances (0 if none) — drives the Payslips list's outstanding
  /// column. Kept live by a single collection-group listener.
  double outstandingBalanceFor(String distributorId) =>
      _outstandingByDistributor[distributorId] ?? 0;

  /// Whether the currently-viewed week's wage data (Ops Stats daily
  /// entries, extra earnings, advance-deduction/savings-withdrawal toggles)
  /// can still be edited — false once the week is more than 2 pay-week
  /// cycles old. Payment-status/notes and payment-account selection are
  /// deliberately NOT gated by this (see the `requireEditable: false`
  /// call sites below) since marking a payment as sent is a separate
  /// workflow from editing the underlying wage figures.
  bool get isWeekEditable => isPayrollWeekEditable(_weekStart);

  /// Distributors from the already-streamed [ScheduleProvider] cache,
  /// falling back to a one-shot fetch — mirrors
  /// `DropsheetProvider._resolveDistributors` to avoid a second Firestore
  /// read for a list that's already live elsewhere in the app.
  Future<List<Distributor>> _resolveDistributors() async {
    final cached = _ref?.read(scheduleRiverpod).distributors;
    if (cached != null && cached.isNotEmpty) return cached;
    return FirestoreService().fetchDistributorsOnce();
  }

  void _listenSettings() {
    _settingsSub?.cancel();
    _settingsSub = _service.streamSettings().listen((settings) {
      _settings = settings;
      notifyListeners();
    });
  }

  void _listenOutstanding() {
    _outstandingSub?.cancel();
    _outstandingSub =
        _service.streamOutstandingByDistributor().listen((byDistributor) {
      _outstandingByDistributor = byDistributor;
      notifyListeners();
    });
  }

  void goToWeek(DateTime anyDate) {
    final snapped = weekStartFor(anyDate);
    if (snapped == _weekStart) return;
    _weekStart = snapped;
    _listenWeek();
    notifyListeners();
  }

  void nextWeek() => goToWeek(_weekStart.add(const Duration(days: 7)));

  void previousWeek() => goToWeek(_weekStart.subtract(const Duration(days: 7)));

  void goToThisWeek() => goToWeek(defaultPayrollWeekStart());

  void _listenWeek() {
    _weekSub?.cancel();
    _isLoading = true;
    final activeWeekStart = _weekStart;

    // Guards `ensureWeekInitialized` to run at most once per week open,
    // triggered by the stream's own first emission rather than a second,
    // independent `getWeek()` read fired concurrently alongside the stream
    // — the old approach cost two reads of the same document on every
    // `goToWeek()` call.
    var ensuredForThisWeek = false;

    _weekSub = _service.streamWeek(activeWeekStart).listen(
      (week) async {
        if (activeWeekStart != _weekStart) return;
        _week = week;
        _isLoading = false;
        _error = null;
        notifyListeners();

        if (ensuredForThisWeek) return;
        ensuredForThisWeek = true;
        final distributors = await _resolveDistributors();
        if (activeWeekStart != _weekStart) return;
        final missing = distributors
            .where((d) => !week.payslips.containsKey(d.id))
            .toList();
        if (missing.isNotEmpty) {
          await _service.ensureWeekInitialized(
              activeWeekStart, distributors, _settings);
        }
      },
      onError: (e) {
        if (activeWeekStart != _weekStart) return;
        _error = e.toString();
        _isLoading = false;
        notifyListeners();
      },
    );
  }

  /// The identity stamped into `updatedBy` for audit — the signed-in admin's
  /// email, or null if unavailable.
  String? get _currentUser {
    final email = _ref?.read(authRiverpod).userEmail;
    return (email == null || email.isEmpty) ? null : email;
  }

  /// Applies per-distributor [mutations] optimistically to local state (for a
  /// snappy UI), then persists them through the service's transactional
  /// read-modify-write — each mutation is re-applied to the FRESHLY-read
  /// payslip inside a Firestore transaction, so a concurrent edit to the same
  /// distributor's payslip can't be clobbered by this stale local snapshot,
  /// and other distributors' payslips are never touched.
  ///
  /// [requireEditable] (default true) silently no-ops the whole mutation once
  /// [isWeekEditable] is false — the data-layer half of the "weeks older than
  /// 2 cycles are read-only" rule; the UI should already disable the controls
  /// that would call this, so this is a defense-in-depth backstop.
  Future<void> _mutatePayslips(
    Map<String, PayrollPayslip Function(PayrollPayslip)> mutations, {
    bool requireEditable = true,
  }) async {
    if (requireEditable && !isWeekEditable) return;
    final payslips = Map<String, PayrollPayslip>.from(_week.payslips);
    final seeds = <String, PayrollPayslip>{};
    var any = false;
    mutations.forEach((id, mutate) {
      final current = _week.payslips[id];
      if (current == null) return;
      seeds[id] = current; // pre-mutation snapshot; the txn applies mutate once
      payslips[id] = mutate(current);
      any = true;
    });
    if (!any) return;
    _week = _service.recomputeWeek(_week.copyWith(payslips: payslips),
        settings: _settings);
    notifyListeners();
    await _service.mutatePayslipsTxn(
      _week.weekStart,
      mutations: mutations,
      seeds: seeds,
      settings: _settings,
      updatedBy: _currentUser,
    );
  }

  /// Replaces one or more of a distributor's daily entries in one write.
  Future<void> updateDistributorDays(
    String distributorId,
    Map<DateTime, PayrollDailyEntry> edits,
  ) async {
    if (!_week.payslips.containsKey(distributorId)) return;
    await _mutatePayslips({
      distributorId: (p) {
        final entries = Map<String, PayrollDailyEntry>.from(p.dailyEntries);
        for (final e in edits.entries) {
          entries[dayKeyFor(e.key)] = e.value;
        }
        return p.copyWith(dailyEntries: entries);
      },
    });
    await _autoApplyDefaultDeductions();
  }

  /// Replaces one day's entry for every distributor in [entriesByDistributorId]
  /// in a single save — the bulk "Ops Stats" workflow, where one day's
  /// numbers are entered for every distributor at once rather than one
  /// distributor's whole week at a time. Still just one Firestore write
  /// (multiple `payslips.<id>` field paths in one `update()` call).
  Future<void> updateDayForAllDistributors(
    DateTime date,
    Map<String, PayrollDailyEntry> entriesByDistributorId,
  ) async {
    final key = dayKeyFor(date);
    final mutations = <String, PayrollPayslip Function(PayrollPayslip)>{
      for (final e in entriesByDistributorId.entries)
        if (_week.payslips.containsKey(e.key))
          e.key: (p) {
            final entries =
                Map<String, PayrollDailyEntry>.from(p.dailyEntries);
            entries[key] = e.value;
            return p.copyWith(dailyEntries: entries);
          },
    };
    await _mutatePayslips(mutations);
    await _autoApplyDefaultDeductions();
  }

  Future<void> updateAdvanceDeduction(
    String distributorId, {
    required bool isDeducting,
    required double amount,
    String? note,
  }) async {
    if (!isWeekEditable) return;
    final payslip = _week.payslips[distributorId];
    if (payslip == null) return;
    final resolvedNote = note ?? payslip.advanceDeductionNote;
    // Optimistic local update for a snappy UI; the atomic transaction below
    // is the source of truth (payslip amount + applied flag + advance ledger
    // reconciled together, based on a fresh in-transaction read of the week).
    final local = _service.recomputePayslip(
      payslip.copyWith(
        isDeductingAdvanceThisWeek: isDeducting,
        advanceDeductionAmount: amount,
        advanceDeductionNote: resolvedNote,
        advanceAppliedToLedger: isDeducting,
        // An explicit admin decision turns off auto-deduction for this week.
        advanceDeductionOverridden: true,
      ),
      settings: _settings,
    );
    _week = _week
        .copyWith(payslips: {..._week.payslips, distributorId: local});
    notifyListeners();
    await _service.applyAdvanceDeduction(
      weekStart: _week.weekStart,
      distributorId: distributorId,
      isDeducting: isDeducting,
      amount: amount,
      note: resolvedNote,
      settings: _settings,
      seed: payslip,
      updatedBy: _currentUser,
      markOverridden: true,
    );
  }

  /// Records a brand-new deduction (advance or penalty) for [distributorId]
  /// — amount, date paid, and the installment amount that should default on
  /// future weeks while it remains outstanding.
  Future<void> addAdvance(
    String distributorId, {
    DeductionType type = DeductionType.advance,
    String? label,
    required double amount,
    required DateTime datePaid,
    required double preferredInstallmentAmount,
    String? note,
  }) async {
    await _service.addAdvance(
      distributorId,
      type: type,
      label: label,
      amount: amount,
      datePaid: datePaid,
      preferredInstallmentAmount: preferredInstallmentAmount,
      note: note,
    );
    // A newly-recorded advance may make this distributor eligible for the
    // default auto-deduction on the live week. Call the service directly for
    // this distributor (rather than the pre-filtered pass) so it doesn't
    // depend on the collection-group outstanding stream having caught up with
    // the advance just written.
    await _service.autoApplyDefaultAdvanceDeduction(
      weekStart: weekStartFor(scheduleNow()),
      distributorId: distributorId,
      settings: _settings,
      updatedBy: _currentUser,
    );
  }

  /// Records a simple one-off addition to this week's net pay — e.g.
  /// unpaid wages owed from a previous week. Not tracked across weeks like
  /// advances/savings; just entered directly on this payslip.
  Future<void> updateExtraEarnings(
    String distributorId, {
    required double amount,
    String? note,
  }) async {
    if (!_week.payslips.containsKey(distributorId)) return;
    await _mutatePayslips({
      distributorId: (p) => p.copyWith(
            extraEarningsAmount: amount,
            extraEarningsNote: note ?? p.extraEarningsNote,
          ),
    });
  }

  /// Records a brand-new savings deposit for [distributorId] — money the
  /// distributor has asked the company to hold, to be paid back out later.
  Future<void> addSavingsDeposit(
    String distributorId, {
    required double amount,
    required DateTime dateDeposited,
    required double preferredWithdrawalAmount,
    String? note,
  }) {
    return _service.addSavingsDeposit(
      distributorId,
      amount: amount,
      dateDeposited: dateDeposited,
      preferredWithdrawalAmount: preferredWithdrawalAmount,
      note: note,
    );
  }

  /// Sets this week's savings withdrawal (paid out oldest-deposit-first)
  /// and syncs it against the distributor's outstanding deposits.
  Future<void> updateSavingsWithdrawal(
    String distributorId, {
    required bool isWithdrawing,
    required double amount,
    String? note,
  }) async {
    if (!isWeekEditable) return;
    final payslip = _week.payslips[distributorId];
    if (payslip == null) return;
    final resolvedNote = note ?? payslip.savingsWithdrawalNote;
    // Optimistic local update; the atomic transaction below is the source of
    // truth (payslip amount + applied flag + savings ledger reconciled
    // together, based on a fresh in-transaction read of the week).
    final local = _service.recomputePayslip(
      payslip.copyWith(
        isWithdrawingSavingsThisWeek: isWithdrawing,
        savingsWithdrawalAmount: amount,
        savingsWithdrawalNote: resolvedNote,
        savingsWithdrawalApplied: isWithdrawing,
      ),
      settings: _settings,
    );
    _week = _week
        .copyWith(payslips: {..._week.payslips, distributorId: local});
    notifyListeners();
    await _service.applySavingsWithdrawal(
      weekStart: _week.weekStart,
      distributorId: distributorId,
      isWithdrawing: isWithdrawing,
      amount: amount,
      note: resolvedNote,
      settings: _settings,
      seed: payslip,
      updatedBy: _currentUser,
    );
  }

  /// Records this week's payment status for [distributorId] — from the
  /// Banking tab's paid/processing/not-paid control.
  Future<void> updatePaymentStatus(
    String distributorId,
    PaymentStatus status,
  ) async {
    if (!_week.payslips.containsKey(distributorId)) return;
    await _mutatePayslips({
      distributorId: (p) => p.copyWith(paymentStatus: status),
    }, requireEditable: false);
  }

  /// Records a free-text note against this week's payment for [distributorId].
  Future<void> updatePaymentNotes(String distributorId, String notes) async {
    if (!_week.payslips.containsKey(distributorId)) return;
    await _mutatePayslips({
      distributorId: (p) => p.copyWith(paymentNotes: notes),
    }, requireEditable: false);
  }

  Future<Distributor?> _findDistributor(String distributorId) async {
    final distributors = await _resolveDistributors();
    for (final d in distributors) {
      if (d.id == distributorId) return d;
    }
    return null;
  }

  /// Reads-modifies-persists a distributor's payroll profile in one place,
  /// shared by every payment-account management method below.
  Future<void> _updateDistributorProfile(
    String distributorId,
    DistributorPayrollProfile Function(DistributorPayrollProfile) mutate,
  ) async {
    final distributor = await _findDistributor(distributorId);
    if (distributor == null) return;
    final profile = distributor.payroll ?? const DistributorPayrollProfile();
    final updated = mutate(profile);
    await _ref
        ?.read(scheduleRiverpod)
        .updateDistributor(distributor.copyWith(payroll: updated));
  }

  /// Records which of the distributor's saved accounts this week was paid
  /// through — snapshots it onto the payslip so later edits/removals of the
  /// account don't retroactively change this week's record.
  Future<void> selectPaymentAccountForWeek(
    String distributorId,
    String accountId,
  ) async {
    final distributor = await _findDistributor(distributorId);
    final account = distributor?.payroll?.accountById(accountId);
    if (account == null) return;
    if (!_week.payslips.containsKey(distributorId)) return;
    await _mutatePayslips({
      distributorId: (p) => p.copyWith(
            selectedPaymentAccountId: accountId,
            paymentAccountSnapshot: account,
          ),
    }, requireEditable: false);
  }

  /// Adds a new saved payment account (eWallet number or bank account) for
  /// a distributor — they can have several and alternate between them
  /// without losing any. If this is their first account ever, it becomes
  /// the default and is auto-selected for the current week too.
  Future<void> addPaymentAccount(
    String distributorId,
    PaymentAccount account,
  ) async {
    await _updateDistributorProfile(distributorId, (profile) {
      final isFirst = profile.paymentAccounts.isEmpty;
      return profile.copyWith(
        paymentAccounts: [...profile.paymentAccounts, account],
        defaultPaymentAccountId:
            isFirst ? account.id : profile.defaultPaymentAccountId,
      );
    });
    final payslip = _week.payslips[distributorId];
    if (payslip != null && payslip.selectedPaymentAccountId == null) {
      await selectPaymentAccountForWeek(distributorId, account.id);
    }
  }

  /// Edits an existing saved account. If it's the one selected for the
  /// current week, that week's snapshot is refreshed immediately too.
  Future<void> updatePaymentAccount(
    String distributorId,
    PaymentAccount updated,
  ) async {
    await _updateDistributorProfile(distributorId, (profile) {
      final list = [
        for (final a in profile.paymentAccounts)
          a.id == updated.id ? updated : a,
      ];
      return profile.copyWith(paymentAccounts: list);
    });
    final payslip = _week.payslips[distributorId];
    if (payslip != null && payslip.selectedPaymentAccountId == updated.id) {
      await _mutatePayslips({
        distributorId: (p) => p.copyWith(paymentAccountSnapshot: updated),
      }, requireEditable: false);
    }
  }

  /// Removes a saved account. Past weeks keep their frozen snapshot
  /// regardless — this only affects the distributor's profile going
  /// forward and, if it was the default, reassigns the default.
  Future<void> deletePaymentAccount(
    String distributorId,
    String accountId,
  ) async {
    await _updateDistributorProfile(distributorId, (profile) {
      final list =
          profile.paymentAccounts.where((a) => a.id != accountId).toList();
      final wasDefault = profile.defaultPaymentAccountId == accountId;
      return profile.copyWith(
        paymentAccounts: list,
        defaultPaymentAccountId: wasDefault && list.isNotEmpty
            ? list.first.id
            : (wasDefault ? null : profile.defaultPaymentAccountId),
        clearDefaultPaymentAccountId: wasDefault && list.isEmpty,
      );
    });
  }

  /// Sets which saved account a brand-new week's payslip is seeded with.
  Future<void> setDefaultPaymentAccount(
    String distributorId,
    String accountId,
  ) async {
    await _updateDistributorProfile(
      distributorId,
      (profile) => profile.copyWith(defaultPaymentAccountId: accountId),
    );
  }

  Future<void> finalizeWeek({String? by}) async {
    final finalizedAt = DateTime.now();
    _week = _week.copyWith(
      isFinalized: true,
      finalizedAt: finalizedAt,
      finalizedBy: by,
    );
    notifyListeners();
    await _service.updateFinalizeFields(
      _week.weekStart,
      isFinalized: true,
      finalizedAt: finalizedAt,
      finalizedBy: by,
    );
  }

  Future<void> unfinalizeWeek() async {
    _week = _week.copyWith(isFinalized: false);
    notifyListeners();
    // Preserve the existing finalizedAt/finalizedBy history (unfinalizing
    // only flips the flag, matching this method's prior full-document-save
    // behavior which never cleared them either).
    await _service.updateFinalizeFields(
      _week.weekStart,
      isFinalized: false,
      finalizedAt: _week.finalizedAt,
      finalizedBy: _week.finalizedBy,
    );
  }

  Future<void> updateSettings(PayrollSettings settings) async {
    await _service.saveSettings(settings);
    _settings = settings;
    notifyListeners();
    // A rate / special-code change flows through to the single LIVE pay week
    // (the week today falls into) — never any earlier week, which are locked
    // and keep their frozen snapshots as historical record. This is
    // independent of whichever week the admin happens to be viewing.
    await _applySettingsToLiveWeek();
  }

  /// Re-snapshots the LIVE pay week's payslip rates from the latest
  /// [settings] (merged over each distributor's profile overrides) and
  /// recomputes totals — so editing the company day rate / per-set rate /
  /// estimate bonus, or adding/editing a special day-type code, immediately
  /// updates the current week's wages instead of only affecting weeks
  /// created afterwards.
  ///
  /// The live week is the week TODAY falls into (`weekStartFor(now)`),
  /// resolved fresh here rather than using the currently-viewed week — every
  /// earlier week is locked and must keep its snapshots so already-paid
  /// wages never change retroactively. Only payslips whose resolved rates
  /// actually changed are written (a company-name-only settings edit touches
  /// nothing); if the live week hasn't been created yet there's nothing to
  /// do, since its payslips will be seeded with the new rates when opened.
  Future<void> _applySettingsToLiveWeek() async {
    final liveWeekStart = weekStartFor(scheduleNow());
    final week = (liveWeekStart == _weekStart)
        ? _week
        : await _service.getWeek(liveWeekStart);
    if (week.payslips.isEmpty) return;

    final distributors = await _resolveDistributors();
    final profileById = {
      for (final d in distributors)
        d.id: d.payroll ?? const DistributorPayrollProfile(),
    };
    final mutations = <String, PayrollPayslip Function(PayrollPayslip)>{};
    week.payslips.forEach((id, p) {
      final profile =
          profileById[id] ?? const DistributorPayrollProfile();
      final dayRate = profile.resolvedDayRate(_settings);
      final perSet = profile.resolvedPerSetRate(_settings);
      final estimate = profile.resolvedEstimateBonus(_settings);
      final bonuses = profile.resolvedBonusCodeAmounts(_settings);
      final unchanged = p.dayRateSnapshot == dayRate &&
          p.perSetRateSnapshot == perSet &&
          p.estimateBonusSnapshot == estimate &&
          mapEquals(p.bonusCodeAmountsSnapshot, bonuses);
      if (unchanged) return;
      mutations[id] = (cur) => cur.copyWith(
            dayRateSnapshot: dayRate,
            perSetRateSnapshot: perSet,
            estimateBonusSnapshot: estimate,
            bonusCodeAmountsSnapshot: bonuses,
          );
    });
    if (mutations.isEmpty) return;
    await _service.mutatePayslipsTxn(
      liveWeekStart,
      mutations: mutations,
      seeds: week.payslips,
      settings: _settings,
      updatedBy: _currentUser,
    );
    // Rate changes shift gross wages, which can cross the R500 auto-deduct
    // threshold — reconcile the default deduction for each affected payslip
    // on the live week.
    for (final id in mutations.keys) {
      await _service.autoApplyDefaultAdvanceDeduction(
        weekStart: liveWeekStart,
        distributorId: id,
        settings: _settings,
        updatedBy: _currentUser,
      );
    }
  }

  /// Applies the default "deduct advances once this week's gross exceeds
  /// R500" behaviour to the live pay week's payslips after a stats change.
  ///
  /// No-op unless the week currently loaded IS the live week (`weekStartFor`
  /// of today) — earlier weeks are locked and their deductions are handled
  /// manually. Skips payslips an admin has overridden and, as a cheap
  /// pre-filter, those that couldn't possibly change; the service still does
  /// the authoritative eligibility check and a steady-state skip inside its
  /// own transaction, so this never double-deducts.
  Future<void> _autoApplyDefaultDeductions() async {
    if (_weekStart != weekStartFor(scheduleNow())) return;
    // Candidates are payslips that could plausibly need a change: not admin-
    // overridden, and either already deducting (may need adjusting/reversing)
    // or over the R500 threshold. Deliberately NOT filtered by the
    // outstanding-balance stream — that stream may not have loaded yet on
    // first use, which would wrongly skip an eligible distributor; the
    // service does the authoritative outstanding check inside its own
    // transaction and cheaply no-ops (steady-state skip) for anyone with
    // nothing to deduct.
    final candidates = <String>[
      for (final e in _week.payslips.entries)
        if (!e.value.advanceDeductionOverridden &&
            (e.value.isDeductingAdvanceThisWeek || e.value.grossWage > 500))
          e.key,
    ];
    for (final id in candidates) {
      await _service.autoApplyDefaultAdvanceDeduction(
        weekStart: _weekStart,
        distributorId: id,
        settings: _settings,
        updatedBy: _currentUser,
      );
    }
  }

  @override
  void dispose() {
    _weekSub?.cancel();
    _settingsSub?.cancel();
    _outstandingSub?.cancel();
    super.dispose();
  }
}
