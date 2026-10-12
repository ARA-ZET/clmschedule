import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/distributor.dart';
import '../models/distributor_payroll_profile.dart';
import '../models/dropsheet_day.dart';
import '../models/payroll_daily_entry.dart';
import '../models/payroll_payslip.dart';
import '../models/payroll_settings.dart';
import '../models/payroll_week.dart';
import '../utils/payroll_schedule_rules.dart';
import '../utils/payroll_week.dart';
import '../utils/schedule_time.dart';
import 'payroll_service.dart';

/// Keeps payroll in step with the schedule, live, for every pay week that
/// isn't frozen yet (the current week and the two before it — see
/// [isPayrollWeekEditable]).
///
/// Listens to the schedule days, the dropsheet (who drives a vehicle), days
/// off, distributors and the payroll weeks themselves; a short while after
/// any of them changes, each affected payslip is brought in line with
/// [reconcileWithSchedule] inside a payroll transaction. Runs in every
/// signed-in admin's app, so a schedule change made anywhere (another
/// admin, a Cloud Function) reaches payroll while any admin has the app
/// open. Writes are idempotent, so several admins running it at once
/// converge on the same result.
///
/// Future weeks are left alone: their payslips would snapshot today's rates
/// before the week starts (see `PayrollProvider._applySettingsToLiveWeek`).
class PayrollScheduleSync {
  final FirebaseFirestore _firestore;
  final PayrollService _payroll;
  final String? Function() _currentUser;

  PayrollScheduleSync(this._payroll, this._currentUser,
      {FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static String _monthId(DateTime d) => '${_monthNames[d.month - 1]} ${d.year}';

  final List<StreamSubscription> _subs = [];
  Timer? _debounce;
  Timer? _windowCheck;
  bool _running = false;
  bool _dirtyWhileRunning = false;

  DateTime? _liveWeekStart;
  List<DateTime> _weekStarts = const [];

  // Latest state of every source. A source missing from its "server" set
  // hasn't been confirmed by the server yet, and nothing is written until
  // all are — an empty cached schedule must never wipe payroll.
  final Map<String, Set<String>> _allocatedByDay = {};
  final Map<String, DropsheetDay> _dropsheetByDay = {};
  final Set<String> _scheduleMonthsConfirmed = {};
  final Set<String> _dropsheetMonthsConfirmed = {};
  final Map<DateTime, PayrollWeek> _weeks = {};
  final Set<DateTime> _weeksConfirmed = {};
  Map<String, Set<String>> _daysOff = {};
  bool _daysOffConfirmed = false;
  Map<String, Distributor> _distributors = {};
  bool _distributorsConfirmed = false;
  PayrollSettings? _settings;

  void start() {
    _subscribe();
    // Rolls the window forward when a new pay week starts.
    _windowCheck = Timer.periodic(const Duration(minutes: 15), (_) {
      if (weekStartFor(scheduleNow()) != _liveWeekStart) _subscribe();
    });
  }

  void stop() {
    _windowCheck?.cancel();
    _debounce?.cancel();
    _cancelSubs();
  }

  void _cancelSubs() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  void _subscribe() {
    _cancelSubs();
    _allocatedByDay.clear();
    _dropsheetByDay.clear();
    _scheduleMonthsConfirmed.clear();
    _dropsheetMonthsConfirmed.clear();
    _weeks.clear();
    _weeksConfirmed.clear();
    _daysOffConfirmed = false;
    _distributorsConfirmed = false;

    final live = weekStartFor(scheduleNow());
    _liveWeekStart = live;
    _weekStarts = [
      live.subtract(const Duration(days: 14)),
      live.subtract(const Duration(days: 7)),
      live,
    ];
    final first = _weekStarts.first;
    final last = weekEndFor(live);
    final months = <String, DateTime>{};
    for (var m = DateTime(first.year, first.month);
        !m.isAfter(DateTime(last.year, last.month));
        m = DateTime(m.year, m.month + 1)) {
      months[_monthId(m)] = m;
    }

    for (final e in months.entries) {
      _subs.add(_firestore
          .collection('schedules')
          .doc(e.key)
          .collection('days')
          .snapshots()
          .listen((snap) {
        for (final doc in snap.docs) {
          final jobs = doc.data()['jobs'] as List? ?? const [];
          _allocatedByDay[doc.id] = {
            for (final j in jobs)
              if (j is Map && j['distributorId'] is String)
                j['distributorId'] as String,
          };
        }
        for (final change in snap.docChanges) {
          if (change.type == DocumentChangeType.removed) {
            _allocatedByDay.remove(change.doc.id);
          }
        }
        if (!snap.metadata.isFromCache) _scheduleMonthsConfirmed.add(e.key);
        _changed();
      }, onError: _onError));

      _subs.add(_firestore
          .collection('dropsheet')
          .doc(e.value.year.toString().padLeft(4, '0'))
          .collection(e.key)
          .snapshots()
          .listen((snap) {
        for (final doc in snap.docs) {
          _dropsheetByDay[doc.id] = DropsheetDay.fromMap(doc.id, doc.data());
        }
        for (final change in snap.docChanges) {
          if (change.type == DocumentChangeType.removed) {
            _dropsheetByDay.remove(change.doc.id);
          }
        }
        if (!snap.metadata.isFromCache) _dropsheetMonthsConfirmed.add(e.key);
        _changed();
      }, onError: _onError));
    }

    _subs.add(
        _firestore.collection('distributorDaysOff').snapshots().listen((snap) {
      _daysOff = {
        for (final doc in snap.docs)
          doc.id: ((doc.data()['dates'] as List?)?.cast<String>() ?? const [])
              .toSet(),
      };
      if (!snap.metadata.isFromCache) _daysOffConfirmed = true;
      _changed();
    }, onError: _onError));

    _subs.add(_firestore.collection('distributors').snapshots().listen((snap) {
      _distributors = {
        for (final doc in snap.docs)
          doc.id: Distributor.fromMap(doc.id, doc.data()),
      };
      if (!snap.metadata.isFromCache) _distributorsConfirmed = true;
      _changed();
    }, onError: _onError));

    _subs.add(_payroll.streamSettings().listen((s) {
      _settings = s;
      _changed();
    }, onError: _onError));

    for (final weekStart in _weekStarts) {
      _subs.add(_payroll.streamWeekWithSource(weekStart).listen((r) {
        _weeks[weekStart] = r.week;
        if (r.fromServer) _weeksConfirmed.add(weekStart);
        _changed();
      }, onError: _onError));
    }
  }

  void _onError(Object e) => debugPrint('PayrollScheduleSync: $e');

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), _run);
  }

  bool get _ready {
    final months = {for (final w in _weekStarts) ...daysInWeek(w).map(_monthId)};
    return _settings != null &&
        _daysOffConfirmed &&
        _distributorsConfirmed &&
        _weeksConfirmed.length == _weekStarts.length &&
        months.every(_scheduleMonthsConfirmed.contains) &&
        months.every(_dropsheetMonthsConfirmed.contains);
  }

  Future<void> _run() async {
    if (_running) {
      _dirtyWhileRunning = true;
      return;
    }
    if (!_ready) return;
    _running = true;
    try {
      for (final weekStart in List.of(_weekStarts)) {
        if (!isPayrollWeekEditable(weekStart)) continue;
        await _syncWeek(weekStart);
      }
    } catch (e) {
      _onError(e);
    } finally {
      _running = false;
      if (_dirtyWhileRunning) {
        _dirtyWhileRunning = false;
        _changed();
      }
    }
  }

  bool _allocated(String distributorId, String dayKey) =>
      (_allocatedByDay[dayKey]?.contains(distributorId) ?? false) &&
      !(_daysOff[distributorId]?.contains(dayKey) ?? false);

  /// [p]'s days brought in line with the schedule — [p] itself (identical)
  /// when nothing needs to change.
  PayrollPayslip _reconcilePayslip(
      PayrollPayslip p, DateTime weekStart, PayrollSettings settings) {
    final distributor = _distributors[p.distributorId];
    Map<String, PayrollDailyEntry>? entries;
    for (final day in daysInWeek(weekStart)) {
      final key = dayKeyFor(day);
      final dropsheet = _dropsheetByDay[key];
      final next = reconcileWithSchedule(
        date: day,
        saved: p.dailyEntries[key],
        allocated: _allocated(p.distributorId, key),
        driving: distributor != null &&
            dropsheet != null &&
            drivesVehicleOn(dropsheet, distributor),
        knownCodes: settings.bonusCodes,
      );
      if (next == null) continue;
      (entries ??= Map.of(p.dailyEntries))[key] = next;
    }
    return entries == null ? p : p.copyWith(dailyEntries: entries);
  }

  Future<void> _syncWeek(DateTime weekStart) async {
    final settings = _settings!;
    final week = _weeks[weekStart] ?? PayrollWeek.empty(weekStart);

    // Everyone with a payslip this week, plus anyone allocated on one of
    // its days who doesn't have one yet.
    final ids = {...week.payslips.keys};
    for (final day in daysInWeek(weekStart)) {
      final key = dayKeyFor(day);
      for (final id in _allocatedByDay[key] ?? const <String>{}) {
        if (_distributors.containsKey(id) && _allocated(id, key)) ids.add(id);
      }
    }

    final seeds = <String, PayrollPayslip>{};
    final mutations = <String, PayrollPayslip Function(PayrollPayslip)>{};
    for (final id in ids) {
      var current = week.payslips[id];
      if (current == null) {
        final d = _distributors[id]!;
        current = seeds[id] = PayrollPayslip.blank(
          distributorId: d.id,
          distributorName: d.name,
          weekStart: weekStart,
          settings: settings,
          profile: d.payroll ?? const DistributorPayrollProfile(),
        );
      }
      // Cheap pre-check on the snapshot; the transaction re-applies the
      // same rule to the freshly-read payslip, so a concurrent admin edit
      // is never overwritten with a value computed from stale data.
      if (identical(_reconcilePayslip(current, weekStart, settings), current) &&
          week.payslips.containsKey(id)) {
        continue;
      }
      mutations[id] = (p) => _reconcilePayslip(p, weekStart, settings);
    }
    if (mutations.isEmpty) return;

    debugPrint('PayrollScheduleSync: updating ${mutations.length} payslip(s) '
        'for week ${weekIdFor(weekStart)}');
    await _payroll.mutatePayslipsTxn(
      weekStart,
      mutations: mutations,
      seeds: seeds,
      settings: settings,
      updatedBy: _currentUser(),
    );

    // Wages changed, so the live week's automatic advance deductions may
    // need adjusting too — best-effort, as after any other stats save.
    if (weekStart == weekStartFor(scheduleNow())) {
      for (final id in mutations.keys) {
        try {
          await _payroll.autoApplyDefaultAdvanceDeduction(
            weekStart: weekStart,
            distributorId: id,
            settings: settings,
            updatedBy: _currentUser(),
          );
        } catch (e) {
          _onError(e);
        }
      }
    }
  }
}
