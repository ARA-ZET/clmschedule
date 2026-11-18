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
import '../services/payroll_schedule_sync.dart';
import '../services/payroll_service.dart';
import '../utils/payroll_week.dart';
import '../utils/resilient_subscription.dart';
import '../utils/schedule_time.dart';
import '../utils/write_retry.dart';
import '../services/sync_status.dart';
import '../undo/undo_history.dart';
import '../services/schedule_mutation_types.dart' show deepEquals;
import 'package:intl/intl.dart' show DateFormat;
import 'auth_provider.dart';
import 'schedule_provider.dart';

final payrollServiceRiverpod =
    riverpod.Provider<PayrollService>((ref) => PayrollService());

/// The live schedule → payroll sync ([PayrollScheduleSync]), running while
/// a signed-in admin has the app open; null for everyone else.
final payrollScheduleSyncRiverpod =
    riverpod.Provider<PayrollScheduleSync?>((ref) {
  final isAdmin = ref.watch(authRiverpod.select((a) => a.isAdmin));
  if (!isAdmin) return null;
  final sync = PayrollScheduleSync(ref.read(payrollServiceRiverpod), () {
    final email = ref.read(authRiverpod).userEmail;
    return email.isEmpty ? null : email;
  })
    ..start();
  ref.onDispose(sync.stop);
  return sync;
});

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

  ResilientSubscription<({PayrollWeek week, bool fromServer})>? _weekSub;

  /// The last week snapshot came from the server, not the local cache. False
  /// while the connection is down or the listener is re-opening.
  bool _weekFromServer = false;
  StreamSubscription<PayrollSettings>? _settingsSub;
  StreamSubscription<Map<String, double>>? _outstandingSub;

  DateTime _weekStart = defaultPayrollWeekStart();
  PayrollWeek _week = PayrollWeek.empty(defaultPayrollWeekStart());
  PayrollSettings _settings = PayrollSettings.defaults();
  Map<String, double> _outstandingByDistributor = const {};
  bool _isLoading = false;
  String? _error;

  /// The week exactly as Firestore last reported it, before local edits
  /// still on their way to the server are laid over it (see [_overlay]).
  PayrollWeek? _serverWeek;

  /// The payslip write currently running, and the ones queued behind it.
  /// Writes go one at a time — concurrent transactions on the single week
  /// doc contend and retry with backoff, which is what made quick
  /// successive Ops Stats edits slow — and everything queued while one is
  /// running is merged into the next single transaction.
  _PayslipWrite? _inFlightWrite;
  final List<_PayslipWrite> _writeQueue = [];

  /// Writes the server has accepted that the week stream hasn't shown yet.
  /// They stay laid over every snapshot until it does: on a lagging
  /// connection an older snapshot could otherwise arrive after the save and
  /// put the old values back on screen — and the Ops Stats grid then saved
  /// those old values for real (what happened on Fri 6 Nov 2026, 18:26).
  final List<_PayslipWrite> _committedWrites = [];

  /// Upper bound on how long a saved write masks the stream when the stream
  /// never shows exactly what was written (someone changed the same payslip
  /// straight after). Past this the connection is reported as slow anyway.
  static const Duration _confirmTimeout = Duration(seconds: 90);

  Timer? _autoDeductTimer;

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

  /// What's on screen is live: the connection is healthy (no banner) and
  /// the last week snapshot came from the server, not the local cache.
  /// Money decisions (marking a payslip paid) need this — a screen showing
  /// stale amounts is how distributors were paid short on 6 Nov 2026. Edits
  /// still saving don't count against it: they're on screen, and the paid
  /// write queues behind them and is checked against the server's amount.
  bool get isInSync =>
      _weekFromServer &&
      SyncStatus.instance.problem == SyncProblem.none &&
      // A feed that just failed is retried quietly before the banner
      // shows — payments still wait for it.
      !SyncStatus.instance.anyFeedDown;

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
    // A week can straddle a month boundary the schedule isn't streaming
    // (e.g. 25 Sep – 1 Oct viewed in October); without those jobs Ops Stats
    // flags every saved day in the other month as a schedule mismatch.
    _ref
        ?.read(scheduleRiverpod)
        .ensureMonthsLoadedForRange(activeWeekStart, weekEnd);

    // Guards `ensureWeekInitialized` to run at most once per week open,
    // triggered by the stream's own first emission rather than a second,
    // independent `getWeek()` read fired concurrently alongside the stream
    // — the old approach cost two reads of the same document on every
    // `goToWeek()` call.
    var ensuredForThisWeek = false;

    _weekFromServer = false;
    for (final w in _committedWrites) {
      w.confirmTimer?.cancel();
    }
    _committedWrites.clear();
    _weekSub = ResilientSubscription<({PayrollWeek week, bool fromServer})>(
      debugLabel: 'payroll week ${weekIdFor(activeWeekStart)}',
      userLabel: 'payroll',
      open: () {
        _weekFromServer = false;
        return _service.streamWeekWithSource(activeWeekStart);
      },
      onData: (snapshot) async {
        if (activeWeekStart != _weekStart) return;
        final week = snapshot.week;
        _weekFromServer = snapshot.fromServer;
        _retireConfirmedWrites(week);
        // A snapshot can land while later local edits are still being
        // written (it only reflects writes committed so far); showing it raw
        // would flash those cells back to their old values — and the Ops
        // Stats grid would then save the reverted values for real.
        _serverWeek = week;
        _week = _overlay(week);
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
  ///
  /// [preconditions]: see [PayrollService.mutatePayslipsTxn]. The returned
  /// set holds the distributors whose precondition failed on the server —
  /// their edit was not saved.
  Future<Set<String>> _mutatePayslips(
    Map<String, PayrollPayslip Function(PayrollPayslip)> mutations, {
    bool requireEditable = true,
    Map<String, bool Function(PayrollPayslip)> preconditions = const {},
  }) {
    if (requireEditable && !isWeekEditable) return Future.value(const {});
    final payslips = Map<String, PayrollPayslip>.from(_week.payslips);
    final applied = <String, PayrollPayslip Function(PayrollPayslip)>{};
    final seeds = <String, PayrollPayslip>{};
    mutations.forEach((id, mutate) {
      final current = _week.payslips[id];
      if (current == null) return;
      seeds[id] = current; // pre-mutation snapshot; the txn applies mutate once
      final precondition = preconditions[id];
      if (precondition == null || precondition(current)) {
        payslips[id] = mutate(current);
      }
      applied[id] = mutate;
    });
    if (applied.isEmpty) return Future.value(const {});
    _week = _service.recomputeWeek(_week.copyWith(payslips: payslips),
        settings: _settings);
    notifyListeners();

    // Merge into the newest queued (not yet running) write for this week,
    // composing per-payslip so every mutation still applies in order.
    final tail = _writeQueue.isEmpty ? null : _writeQueue.last;
    final _PayslipWrite write;
    if (tail != null && tail.weekStart == _weekStart) {
      write = tail;
    } else {
      write = _PayslipWrite(_weekStart);
      _writeQueue.add(write);
    }
    applied.forEach((id, mutate) {
      final prior = write.mutations[id];
      write.mutations[id] = prior == null ? mutate : (p) => mutate(prior(p));
      write.seeds.putIfAbsent(id, () => seeds[id]!);
      // The first edit's check is the one that matters: it describes the
      // value the composed edits were made on top of.
      final precondition = preconditions[id];
      if (precondition != null) {
        write.preconditions.putIfAbsent(id, () => precondition);
      }
    });
    write.updatedBy = _currentUser;
    _reportPendingWrites();
    unawaited(_drainWrites());
    return write.done.future;
  }

  void _reportPendingWrites() {
    SyncStatus.instance.reportPendingWrites(
        'payroll', _writeQueue.length + (_inFlightWrite == null ? 0 : 1));
  }

  /// Saves [write], retrying network and contention failures until it goes
  /// through — they used to drop the edit from the screen with only a
  /// console message. Every mutation is a "set" re-applied to the freshly
  /// read payslip, so a retry after an attempt that did land is harmless.
  Future<Set<String>> _persistWithRetry(_PayslipWrite write) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final skipped = await _service
            .mutatePayslipsTxn(
              write.weekStart,
              mutations: write.mutations,
              seeds: write.seeds,
              preconditions: write.preconditions,
              settings: _settings,
              updatedBy: write.updatedBy,
            )
            .timeout(const Duration(seconds: 40));
        if (attempt > 1) {
          SyncStatus.instance.reportWriteRetrying('payroll', false);
        }
        return skipped;
      } catch (e) {
        if (!isRetryableWriteError(e, attempt: attempt)) {
          SyncStatus.instance.reportWriteRetrying('payroll', false);
          rethrow;
        }
        SyncStatus.instance.reportWriteRetrying('payroll', true);
        final delay = writeRetryDelay(attempt);
        debugPrint('Payroll save attempt $attempt failed ($e); retrying in '
            '${delay.inMilliseconds}ms');
        await Future<void>.delayed(delay);
      }
    }
  }

  /// Drops saved writes that [server] now shows (or that can no longer apply
  /// to it — their precondition fails, so the server's value stands).
  void _retireConfirmedWrites(PayrollWeek server) {
    _committedWrites.removeWhere((w) {
      if (weekIdFor(w.weekStart) != weekIdFor(server.weekStart)) {
        return false;
      }
      final shown = w.mutations.entries.every((e) {
        final p = server.payslips[e.key];
        if (p == null) return false;
        final precondition = w.preconditions[e.key];
        if (precondition != null && !precondition(p)) return true;
        final next = _service.recomputePayslip(e.value(p), settings: _settings);
        return payslipsMatchIgnoringStamp(
            next, _service.recomputePayslip(p, settings: _settings));
      });
      if (shown) w.confirmTimer?.cancel();
      return shown;
    });
  }

  Future<void> _drainWrites() async {
    if (_inFlightWrite != null) return;
    while (_writeQueue.isNotEmpty) {
      final write = _inFlightWrite = _writeQueue.removeAt(0);
      _reportPendingWrites();
      try {
        final skipped = await _persistWithRetry(write);
        _inFlightWrite = null;
        _reportPendingWrites();
        // Keep showing it until the stream does (see [_committedWrites]).
        _committedWrites.add(write);
        write.confirmTimer = Timer(_confirmTimeout, () {
          if (_committedWrites.remove(write)) {
            final server = _serverWeek;
            if (server != null && write.weekStart == _weekStart) {
              _week = _overlay(server);
              notifyListeners();
            }
          }
        });
        final server = _serverWeek;
        if (server != null) _retireConfirmedWrites(server);
        if (skipped.isNotEmpty && server != null &&
            write.weekStart == _weekStart) {
          _week = _overlay(server);
          notifyListeners();
        }
        write.done.complete(skipped);
      } catch (e, st) {
        _inFlightWrite = null;
        _reportPendingWrites();
        debugPrint('Payroll save failed: $e');
        // Drop the failed edit from what's shown: back to the last server
        // snapshot plus whatever is still queued.
        final server = _serverWeek;
        if (write.weekStart == _weekStart && server != null) {
          _week = _overlay(server);
          notifyListeners();
        }
        write.done.completeError(e, st);
      }
    }
  }

  /// [server] with every not-yet-confirmed local write for the viewed week
  /// re-applied on top, oldest first.
  PayrollWeek _overlay(PayrollWeek server) {
    final writes = [
      ..._committedWrites,
      if (_inFlightWrite != null) _inFlightWrite!,
      ..._writeQueue,
    ].where((w) => w.weekStart == _weekStart);
    if (writes.isEmpty) return server;
    final payslips = Map<String, PayrollPayslip>.from(server.payslips);
    for (final w in writes) {
      w.mutations.forEach((id, mutate) {
        final current = payslips[id] ?? w.seeds[id];
        if (current == null) return;
        final precondition = w.preconditions[id];
        if (precondition != null && !precondition(current)) return;
        payslips[id] = mutate(current);
      });
    }
    return _service.recomputeWeek(server.copyWith(payslips: payslips),
        settings: _settings);
  }

  /// Completes once every queued payslip write has finished (or failed).
  Future<void> _writesSettled() async {
    while (_inFlightWrite != null || _writeQueue.isNotEmpty) {
      final last = _writeQueue.isNotEmpty ? _writeQueue.last : _inFlightWrite!;
      try {
        await last.done.future;
      } catch (_) {}
    }
  }

  /// Runs [_autoApplyDefaultDeductions] once edits settle rather than after
  /// every save — it's one transaction per candidate payslip on the same
  /// week doc, so running it between rapid edits held each one up.
  void _scheduleAutoDeductions() {
    _autoDeductTimer?.cancel();
    _autoDeductTimer = Timer(const Duration(milliseconds: 1500), () async {
      await _writesSettled();
      try {
        await _autoApplyDefaultDeductions();
      } catch (e) {
        debugPrint('Auto advance deduction failed: $e');
      }
    });
  }

  // ── Undo / Redo (per week) ─────────────────────────────────────────────────
  //
  // Only plain payslip fields are undoable: daily entries, extra earnings,
  // payment status and notes. Advance deductions, savings, deposits, payment
  // accounts, finalising and settings touch the ledgers and are not.
  //
  // A step holds each changed field's value before and after. Undo checks
  // every field still holds what the step left (another admin, the schedule
  // sync), and that the week is still open for editing, then writes the old
  // values through the same transactional queue as any edit.

  /// The open week's undo history key.
  UndoKey get undoKey => UndoKey(UndoScope.payroll, weekIdFor(_weekStart));

  void _recordPayrollStep(String label, List<_PayslipFieldChange> changes,
      {bool requireEditable = true}) {
    final ref = _ref;
    final real = changes.where((c) => !c.isNoOp).toList();
    if (ref == null || real.isEmpty) return;
    if (requireEditable && !isWeekEditable) return;
    final history = ref.read(undoHistoryRiverpod(undoKey));
    if (history.isApplying) return;
    final weekStart = _weekStart;
    history.record(UndoEntry(
      label: label,
      undo: () => _applyPayrollStep(weekStart, real, requireEditable,
          toBefore: true),
      redo: () => _applyPayrollStep(weekStart, real, requireEditable,
          toBefore: false),
    ));
  }

  Future<void> _applyPayrollStep(DateTime weekStart,
      List<_PayslipFieldChange> changes, bool requireEditable,
      {required bool toBefore}) async {
    if (weekIdFor(weekStart) != weekIdFor(_weekStart)) {
      throw const UndoConflict('that week is no longer open');
    }
    if (requireEditable && (!isWeekEditable || _week.isFinalized)) {
      throw const UndoConflict('the week is finalised or closed');
    }
    for (final c in changes) {
      final p = _week.payslips[c.distributorId];
      if (p == null || !c.holds(p, toBefore ? c.after : c.before)) {
        throw const UndoConflict('the payslip was changed since');
      }
    }
    final mutations = <String, PayrollPayslip Function(PayrollPayslip)>{};
    for (final c in changes) {
      final prior = mutations[c.distributorId];
      PayrollPayslip apply(PayrollPayslip p) =>
          c.write(p, toBefore ? c.before : c.after);
      mutations[c.distributorId] =
          prior == null ? apply : (p) => apply(prior(p));
    }
    await _mutatePayslips(mutations, requireEditable: requireEditable);
    if (changes.any((c) => c.isDay)) _scheduleAutoDeductions();
  }

  List<_PayslipFieldChange> _dayChanges(
      String distributorId, Map<DateTime, PayrollDailyEntry> edits) {
    final p = _week.payslips[distributorId];
    if (p == null) return const [];
    return [
      for (final e in edits.entries)
        _PayslipFieldChange.day(distributorId, dayKeyFor(e.key),
            p.dailyEntries[dayKeyFor(e.key)], e.value),
    ];
  }

  String _who(String distributorId) {
    final name = _week.payslips[distributorId]?.distributorName.trim() ?? '';
    return name.isEmpty ? 'distributor' : name;
  }

  /// Replaces one or more of a distributor's daily entries in one write.
  Future<void> updateDistributorDays(
    String distributorId,
    Map<DateTime, PayrollDailyEntry> edits,
  ) async {
    if (!_week.payslips.containsKey(distributorId)) return;
    _recordPayrollStep('Edit days for ${_who(distributorId)}',
        _dayChanges(distributorId, edits));
    await _mutatePayslips({
      distributorId: (p) {
        final entries = Map<String, PayrollDailyEntry>.from(p.dailyEntries);
        for (final e in edits.entries) {
          entries[dayKeyFor(e.key)] = e.value;
        }
        return p.copyWith(dailyEntries: entries);
      },
    });
    _scheduleAutoDeductions();
  }

  /// Replaces one day's entry for every distributor in [entriesByDistributorId]
  /// in a single save — the bulk "Ops Stats" workflow, where one day's
  /// numbers are entered for every distributor at once rather than one
  /// distributor's whole week at a time. Still just one Firestore write
  /// (multiple `payslips.<id>` field paths in one `update()` call).
  ///
  /// [basedOn] is what each cell showed before the admin typed — the edit
  /// is only saved if the server still holds that (or already holds the
  /// new value). A cell showing an out-of-date value can then never
  /// overwrite a newer one. Returns the names of distributors whose cell
  /// was NOT saved for that reason.
  Future<List<String>> updateDayForAllDistributors(
    DateTime date,
    Map<String, PayrollDailyEntry> entriesByDistributorId, {
    Map<String, PayrollDailyEntry> basedOn = const {},
  }) async {
    final key = dayKeyFor(date);
    _recordPayrollStep('Edit ${DateFormat('EEE d MMM').format(date)}', [
      for (final e in entriesByDistributorId.entries)
        ..._dayChanges(e.key, {date: e.value}),
    ]);
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
    final preconditions = <String, bool Function(PayrollPayslip)>{
      for (final e in basedOn.entries)
        if (mutations.containsKey(e.key))
          e.key: (p) {
            final current =
                p.dailyEntries[key] ?? PayrollDailyEntry.empty(date);
            return dayEditStillApplies(
              current: current,
              basedOn: e.value,
              wanted: entriesByDistributorId[e.key]!,
            );
          },
    };
    final skipped =
        await _mutatePayslips(mutations, preconditions: preconditions);
    _scheduleAutoDeductions();
    return [for (final id in skipped) _who(id)];
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
    final current = _week.payslips[distributorId];
    if (current == null) return;
    _recordPayrollStep('Extra earnings for ${_who(distributorId)}', [
      _PayslipFieldChange.extraEarnings(
        distributorId,
        (current.extraEarningsAmount, current.extraEarningsNote),
        (amount, note ?? current.extraEarningsNote),
      ),
    ]);
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
    final current = _week.payslips[distributorId];
    if (current == null) return;
    if (status == PaymentStatus.paid && !isInSync) {
      throw const PayrollNotInSyncException();
    }
    _recordPayrollStep(
      'Payment status for ${_who(distributorId)}',
      [
        _PayslipFieldChange.paymentStatus(
            distributorId, current.paymentStatus, status),
      ],
      requireEditable: false,
    );
    if (status != PaymentStatus.paid) {
      await _mutatePayslips({
        distributorId: (p) => p.copyWith(paymentStatus: status, clearPaid: true),
      }, requireEditable: false);
      return;
    }
    // Paid is only recorded at the amount on screen: if the server's net
    // differs (the screen was behind), nothing is saved and the admin is
    // told — rather than paying from a stale figure, as on 6 Nov 2026.
    final shownNet = current.netWage;
    final paidBy = _currentUser;
    final paidAt = DateTime.now();
    final skipped = await _mutatePayslips({
      distributorId: (p) => p.copyWith(
            paymentStatus: PaymentStatus.paid,
            paidAmount: shownNet,
            paidAt: p.paidAt ?? paidAt,
            paidBy: p.paidBy ?? paidBy,
          ),
    }, requireEditable: false, preconditions: {
      distributorId: (p) =>
          (_service.recomputePayslip(p, settings: _settings).netWage -
                      shownNet)
                  .abs() <
              0.005,
    });
    if (skipped.contains(distributorId)) {
      throw PayrollAmountChangedException(_who(distributorId), shownNet);
    }
  }

  /// Records a free-text note against this week's payment for [distributorId].
  Future<void> updatePaymentNotes(String distributorId, String notes) async {
    final current = _week.payslips[distributorId];
    if (current == null) return;
    _recordPayrollStep(
      'Payment notes for ${_who(distributorId)}',
      [
        _PayslipFieldChange.paymentNotes(
            distributorId, current.paymentNotes, notes),
      ],
      requireEditable: false,
    );
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
    _autoDeductTimer?.cancel();
    _weekSub?.cancel();
    for (final w in _committedWrites) {
      w.confirmTimer?.cancel();
    }
    _settingsSub?.cancel();
    _outstandingSub?.cancel();
    super.dispose();
  }
}

/// One queued payslip transaction for [weekStart] — see
/// `PayrollProvider._writeQueue`.
class _PayslipWrite {
  final DateTime weekStart;
  final Map<String, PayrollPayslip Function(PayrollPayslip)> mutations = {};
  final Map<String, PayrollPayslip> seeds = {};
  final Map<String, bool Function(PayrollPayslip)> preconditions = {};

  /// Completes with the distributors whose precondition failed (not saved).
  final Completer<Set<String>> done = Completer<Set<String>>();
  Timer? confirmTimer;
  String? updatedBy;

  _PayslipWrite(this.weekStart);
}

/// One payslip field an undo step changed: its value before and after, how
/// to compare a payslip against a value, and how to write one.
class _PayslipFieldChange {
  final String distributorId;
  final Object? before;
  final Object? after;
  final bool isDay;
  final Object? Function(Object? value) _norm;
  final Object? Function(PayrollPayslip p) _read;
  final PayrollPayslip Function(PayrollPayslip p, Object? value) write;

  _PayslipFieldChange._(
    this.distributorId,
    this.before,
    this.after,
    this._read,
    this.write, {
    Object? Function(Object? value)? norm,
    this.isDay = false,
  }) : _norm = norm ?? ((v) => v);

  bool get isNoOp => deepEquals(_norm(before), _norm(after));

  bool holds(PayrollPayslip p, Object? value) =>
      deepEquals(_norm(_read(p)), _norm(value));

  /// A daily entry; null means "no entry for that day".
  factory _PayslipFieldChange.day(String distributorId, String key,
      PayrollDailyEntry? before, PayrollDailyEntry? after) {
    return _PayslipFieldChange._(
      distributorId,
      before,
      after,
      (p) => p.dailyEntries[key],
      (p, v) {
        final entries = Map<String, PayrollDailyEntry>.from(p.dailyEntries);
        if (v == null) {
          entries.remove(key);
        } else {
          entries[key] = v as PayrollDailyEntry;
        }
        return p.copyWith(dailyEntries: entries);
      },
      norm: (v) => (v as PayrollDailyEntry?)?.toMap(),
      isDay: true,
    );
  }

  factory _PayslipFieldChange.extraEarnings(String distributorId,
      (double, String) before, (double, String) after) {
    return _PayslipFieldChange._(
      distributorId,
      before,
      after,
      (p) => (p.extraEarningsAmount, p.extraEarningsNote),
      (p, v) {
        final (amount, note) = v as (double, String);
        return p.copyWith(extraEarningsAmount: amount, extraEarningsNote: note);
      },
      norm: (v) {
        final (amount, note) = v as (double, String);
        return [amount, note];
      },
    );
  }

  factory _PayslipFieldChange.paymentStatus(
      String distributorId, PaymentStatus before, PaymentStatus after) {
    return _PayslipFieldChange._(
      distributorId,
      before,
      after,
      (p) => p.paymentStatus,
      (p, v) => p.copyWith(paymentStatus: v as PaymentStatus),
    );
  }

  factory _PayslipFieldChange.paymentNotes(
      String distributorId, String before, String after) {
    return _PayslipFieldChange._(
      distributorId,
      before,
      after,
      (p) => p.paymentNotes,
      (p, v) => p.copyWith(paymentNotes: v as String),
    );
  }
}

/// Two daily entries record the same thing (the date is the map key, so
/// [PayrollDailyEntry.toMap] leaves it out).
bool sameDailyEntry(PayrollDailyEntry a, PayrollDailyEntry b) =>
    deepEquals(a.toMap(), b.toMap());

/// An Ops Stats edit made on top of [basedOn] may be saved over [current]
/// (the server's value now) only if nothing else changed it in between —
/// or it already holds [wanted]. Otherwise the cell was showing an
/// out-of-date value and saving would overwrite a newer one.
bool dayEditStillApplies({
  required PayrollDailyEntry current,
  required PayrollDailyEntry basedOn,
  required PayrollDailyEntry wanted,
}) =>
    sameDailyEntry(current, basedOn) || sameDailyEntry(current, wanted);

/// Marking paid was refused because the screen isn't showing the server's
/// current figures.
class PayrollNotInSyncException implements Exception {
  const PayrollNotInSyncException();
  @override
  String toString() => "This screen isn't up to date with the server yet "
      '(slow connection or changes still saving), so payments can\'t be '
      'marked. Wait until the warning at the top clears and try again.';
}

/// Marking paid was refused because the payslip's net on the server is not
/// the amount the admin was looking at.
class PayrollAmountChangedException implements Exception {
  final String distributorName;
  final double shownNet;
  const PayrollAmountChangedException(this.distributorName, this.shownNet);
  @override
  String toString() => "$distributorName's pay has changed since this "
      'screen showed R${shownNet.toStringAsFixed(2)} — not marked paid. '
      'Check the new amount before paying.';
}
