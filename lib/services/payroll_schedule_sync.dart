import 'dart:async';
import 'dart:math';

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
import '../utils/resilient_subscription.dart';
import 'payroll_service.dart';
import 'sync_status.dart';

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

  final List<ResilientSubscription> _subs = [];
  Timer? _debounce;
  Timer? _windowCheck;
  Timer? _errorRetry;
  bool _running = false;
  bool _dirtyWhileRunning = false;
  bool _listeningToSyncStatus = false;

  DateTime? _liveWeekStart;
  List<DateTime> _weekStarts = const [];

  // Latest state of every source.
  final Map<String, Set<String>> _allocatedByDay = {};
  final Map<String, DropsheetDay> _dropsheetByDay = {};
  final Map<DateTime, PayrollWeek> _weeks = {};
  Map<String, Set<String>> _daysOff = {};
  Map<String, Distributor> _distributors = {};
  PayrollSettings? _settings;

  /// Whether each source's LATEST snapshot came from the server. Nothing is
  /// written unless every one is true right now. These used to be sticky
  /// ("has ever been confirmed"), so after a connection drop or a dead
  /// listener the sync kept reconciling payroll against a frozen copy of the
  /// schedule — on 4–5 Nov 2026 Barrie's PC applied no schedule change to
  /// payroll for ~46 h. An empty or stale schedule must never wipe payroll.
  final Map<String, bool> _fresh = {};

  /// Day ids each schedule/dropsheet listener has delivered, so a re-opened
  /// listener can drop days that were deleted while it was down.
  final Map<String, Set<String>> _daysBySource = {};

  void start() {
    _subscribe();
    if (!_listeningToSyncStatus) {
      _listeningToSyncStatus = true;
      SyncStatus.instance.addListener(_onSyncStatus);
    }
    // Rolls the window forward when a new pay week starts.
    _windowCheck = Timer.periodic(const Duration(minutes: 15), (_) {
      if (weekStartFor(scheduleNow()) != _liveWeekStart) _subscribe();
    });
  }

  void stop() {
    _windowCheck?.cancel();
    _debounce?.cancel();
    _errorRetry?.cancel();
    if (_listeningToSyncStatus) {
      _listeningToSyncStatus = false;
      SyncStatus.instance.removeListener(_onSyncStatus);
    }
    _cancelSubs();
  }

  SyncProblem? _lastProblem;

  /// Catch up as soon as the connection is healthy again.
  void _onSyncStatus() {
    final problem = SyncStatus.instance.problem;
    if (problem == _lastProblem) return;
    _lastProblem = problem;
    if (!_connectionBlocksWrites) _changed();
  }

  static bool get _connectionBlocksWrites => const {
        SyncProblem.offline,
        SyncProblem.slowConnection,
        SyncProblem.liveUpdatesStopped,
      }.contains(SyncStatus.instance.problem);

  void _cancelSubs() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  /// Listens to [query] with metadata changes, so `isFromCache` is reported
  /// when the connection drops. Re-opened automatically after an error.
  void _listen<T>(String source, Stream<T> Function() open,
      void Function(T snap) onData, bool Function(T snap) fromServer) {
    _fresh[source] = false;
    _subs.add(ResilientSubscription<T>(
      debugLabel: 'payroll sync $source',
      userLabel: 'the payroll sync',
      open: () {
        _fresh[source] = false;
        return open();
      },
      onData: (snap) {
        onData(snap);
        _fresh[source] = fromServer(snap);
        _changed();
      },
    ));
  }

  /// Applies a day-collection snapshot to [target], forgetting days the
  /// listener no longer reports after a re-open.
  void _applyDays<V>(String source, QuerySnapshot<Map<String, dynamic>> snap,
      Map<String, V> target, V? Function(String id, Map<String, dynamic>? data) parse) {
    final seen = _daysBySource.putIfAbsent(source, () => <String>{});
    if (snap.docChanges.length == snap.docs.length &&
        snap.docChanges.every((c) => c.type == DocumentChangeType.added)) {
      // A first snapshot (initial or after a re-open) lists every day.
      for (final id in seen) {
        target.remove(id);
      }
      seen.clear();
    }
    for (final change in snap.docChanges) {
      final doc = change.doc;
      if (change.type == DocumentChangeType.removed) {
        target.remove(doc.id);
        seen.remove(doc.id);
        continue;
      }
      final value = parse(doc.id, doc.data());
      if (value == null) continue;
      target[doc.id] = value;
      seen.add(doc.id);
    }
  }

  void _subscribe() {
    _cancelSubs();
    _allocatedByDay.clear();
    _dropsheetByDay.clear();
    _weeks.clear();
    _fresh.clear();
    _daysBySource.clear();

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

    bool fromServer(QuerySnapshot<Map<String, dynamic>> s) =>
        !s.metadata.isFromCache;

    for (final e in months.entries) {
      final schedSource = 'schedule ${e.key}';
      _listen<QuerySnapshot<Map<String, dynamic>>>(
        schedSource,
        () => _firestore
            .collection('schedules')
            .doc(e.key)
            .collection('days')
            .snapshots(includeMetadataChanges: true),
        // Only the days that changed — re-reading every day on every event
        // was most of this listener's cost.
        (snap) => _applyDays<Set<String>>(schedSource, snap, _allocatedByDay,
            (id, data) {
          final jobs = data?['jobs'] as List? ?? const [];
          return {
            for (final j in jobs)
              if (j is Map && j['distributorId'] is String)
                j['distributorId'] as String,
          };
        }),
        fromServer,
      );

      final dropSource = 'dropsheet ${e.key}';
      _listen<QuerySnapshot<Map<String, dynamic>>>(
        dropSource,
        () => _firestore
            .collection('dropsheet')
            .doc(e.value.year.toString().padLeft(4, '0'))
            .collection(e.key)
            .snapshots(includeMetadataChanges: true),
        (snap) => _applyDays<DropsheetDay>(dropSource, snap, _dropsheetByDay,
            (id, data) => data == null ? null : DropsheetDay.fromMap(id, data)),
        fromServer,
      );
    }

    _listen<QuerySnapshot<Map<String, dynamic>>>(
      'daysOff',
      () => _firestore
          .collection('distributorDaysOff')
          .snapshots(includeMetadataChanges: true),
      (snap) => _daysOff = {
        for (final doc in snap.docs)
          doc.id: ((doc.data()['dates'] as List?)?.cast<String>() ?? const [])
              .toSet(),
      },
      fromServer,
    );

    _listen<QuerySnapshot<Map<String, dynamic>>>(
      'distributors',
      () => _firestore
          .collection('distributors')
          .snapshots(includeMetadataChanges: true),
      (snap) => _distributors = {
        for (final doc in snap.docs)
          doc.id: Distributor.fromMap(doc.id, doc.data()),
      },
      fromServer,
    );

    _listen<PayrollSettings>(
      'settings',
      _payroll.streamSettings,
      (s) => _settings = s,
      (_) => true,
    );

    for (final weekStart in _weekStarts) {
      _listen<({PayrollWeek week, bool fromServer})>(
        'week ${weekIdFor(weekStart)}',
        () => _payroll.streamWeekWithSource(weekStart),
        (r) => _weeks[weekStart] = r.week,
        (r) => r.fromServer,
      );
    }
  }

  void _onError(Object e) => debugPrint('PayrollScheduleSync: $e');

  final Random _random = Random();

  /// Every admin's app sees the same change at the same moment. A random
  /// extra wait lets one of them save first; the others then receive that
  /// save before running and find nothing left to do, instead of all
  /// colliding on the same week document.
  static const int _maxJitterMs = 2500;

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(
      Duration(milliseconds: 1500 + _random.nextInt(_maxJitterMs)),
      _run,
    );
  }

  bool get _ready =>
      _settings != null &&
      _fresh.isNotEmpty &&
      _fresh.values.every((fresh) => fresh) &&
      !_connectionBlocksWrites;

  Future<void> _run() async {
    if (_running) {
      _dirtyWhileRunning = true;
      return;
    }
    if (!_ready) {
      final stale = [
        for (final e in _fresh.entries)
          if (!e.value) e.key
      ];
      debugPrint('PayrollScheduleSync: waiting for live data before '
          'updating payroll (not live: ${stale.isEmpty ? SyncStatus.instance.problem.name : stale.join(', ')})');
      return;
    }
    _running = true;
    try {
      for (final weekStart in List.of(_weekStarts)) {
        if (!isPayrollWeekEditable(weekStart)) continue;
        // A hung write must not leave [_running] set for good — that would
        // stop the sync for the rest of the session.
        await _syncWeek(weekStart).timeout(const Duration(seconds: 90));
      }
    } catch (e) {
      _onError(e);
      // Try again later rather than straight away, in case it keeps failing.
      _errorRetry?.cancel();
      _errorRetry = Timer(const Duration(seconds: 30), _changed);
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
