import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/distributor.dart';
import '../models/payroll_daily_entry.dart';
import '../models/payroll_payslip.dart';
import '../models/payroll_settings.dart';
import '../models/payroll_week.dart';
import '../services/firestore_service.dart';
import '../services/payroll_service.dart';
import '../utils/payroll_week.dart';
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

  DateTime _weekStart = defaultPayrollWeekStart();
  PayrollWeek _week = PayrollWeek.empty(defaultPayrollWeekStart());
  PayrollSettings _settings = PayrollSettings.defaults();
  bool _isLoading = false;
  String? _error;

  PayrollProvider(this._service, [this._ref]) {
    _listenSettings();
    _listenWeek();
  }

  DateTime get weekStart => _weekStart;
  DateTime get weekEnd => weekEndFor(_weekStart);
  DateTime get payDate => payDateFor(_weekStart);
  PayrollWeek get week => _week;
  PayrollSettings get settings => _settings;
  bool get isLoading => _isLoading;
  String? get error => _error;

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

    _resolveDistributors().then((distributors) {
      if (activeWeekStart != _weekStart) return;
      _service.ensureWeekInitialized(activeWeekStart, distributors, _settings);
    });

    _weekSub = _service.streamWeek(activeWeekStart).listen(
      (week) {
        if (activeWeekStart != _weekStart) return;
        _week = week;
        _isLoading = false;
        _error = null;
        notifyListeners();
      },
      onError: (e) {
        if (activeWeekStart != _weekStart) return;
        _error = e.toString();
        _isLoading = false;
        notifyListeners();
      },
    );
  }

  Future<void> _mutateAndSave(PayrollWeek Function(PayrollWeek) mutate) async {
    final mutated = mutate(_week);
    final recomputed = _service.recomputeWeek(mutated);
    _week = recomputed;
    notifyListeners();
    await _service.saveWeek(recomputed);
  }

  /// Replaces one or more of a distributor's daily entries in one write.
  Future<void> updateDistributorDays(
    String distributorId,
    Map<DateTime, PayrollDailyEntry> edits,
  ) async {
    final payslip = _week.payslips[distributorId];
    if (payslip == null) return;
    await _mutateAndSave((week) {
      final entries = Map<String, PayrollDailyEntry>.from(payslip.dailyEntries);
      for (final e in edits.entries) {
        entries[dayKeyFor(e.key)] = e.value;
      }
      final updated = payslip.copyWith(dailyEntries: entries);
      return week.copyWith(payslips: {...week.payslips, distributorId: updated});
    });
  }

  /// Replaces one day's entry for every distributor in [entriesByDistributorId]
  /// in a single save — the bulk "Ops Stats" workflow, where one day's
  /// numbers are entered for every distributor at once rather than one
  /// distributor's whole week at a time.
  Future<void> updateDayForAllDistributors(
    DateTime date,
    Map<String, PayrollDailyEntry> entriesByDistributorId,
  ) async {
    final key = dayKeyFor(date);
    await _mutateAndSave((week) {
      final payslips = Map<String, PayrollPayslip>.from(week.payslips);
      for (final e in entriesByDistributorId.entries) {
        final payslip = payslips[e.key];
        if (payslip == null) continue;
        final entries = Map<String, PayrollDailyEntry>.from(payslip.dailyEntries);
        entries[key] = e.value;
        payslips[e.key] = payslip.copyWith(dailyEntries: entries);
      }
      return week.copyWith(payslips: payslips);
    });
  }

  Future<void> updateTransportTrips(String distributorId, int trips) async {
    final payslip = _week.payslips[distributorId];
    if (payslip == null) return;
    await _mutateAndSave((week) {
      final updated = payslip.copyWith(transportTrips: trips);
      return week.copyWith(payslips: {...week.payslips, distributorId: updated});
    });
  }

  Future<void> updateAdvanceDeduction(
    String distributorId, {
    required bool isDeducting,
    required double amount,
    String? note,
  }) async {
    final payslip = _week.payslips[distributorId];
    if (payslip == null) return;
    await _mutateAndSave((week) {
      final updated = payslip.copyWith(
        isDeductingAdvanceThisWeek: isDeducting,
        advanceDeductionAmount: amount,
        advanceDeductionNote: note ?? payslip.advanceDeductionNote,
      );
      return week.copyWith(payslips: {...week.payslips, distributorId: updated});
    });
    await _service.syncAdvanceDeduction(week: _week, distributorId: distributorId);
  }

  Future<void> finalizeWeek({String? by}) async {
    _week = _week.copyWith(
      isFinalized: true,
      finalizedAt: DateTime.now(),
      finalizedBy: by,
    );
    notifyListeners();
    await _service.saveWeek(_week);
  }

  Future<void> unfinalizeWeek() async {
    _week = _week.copyWith(isFinalized: false);
    notifyListeners();
    await _service.saveWeek(_week);
  }

  Future<void> updateSettings(PayrollSettings settings) async {
    await _service.saveSettings(settings);
    _settings = settings;
    notifyListeners();
  }

  @override
  void dispose() {
    _weekSub?.cancel();
    _settingsSub?.cancel();
    super.dispose();
  }
}
