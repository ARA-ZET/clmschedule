// track_editor/widgets/te_wage_stats_box.dart
//
// Embedded "wage stats for today" entry box shown in the processing
// panel once a tab has a matched distributor — lets the admin record the
// same daily production stats the Ops Stats grid captures (Km walked /
// waypoints auto-filled from the processed track, plus sets/code, audit
// score, notes, estimate reached), confirm/correct which day they belong
// to, and save them straight into the payroll week that day belongs to —
// atomically, in one Firestore transaction — without switching over to
// the Payroll tab to do it manually.
import 'package:flutter/material.dart';
import '../../utils/schedule_time.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/payroll_daily_entry.dart';
import '../../models/payroll_week.dart';
import '../../providers/dropsheet_provider.dart';
import '../../providers/job_status_provider.dart';
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../utils/payroll_week.dart';
import '../../utils/payroll_schedule_rules.dart';
import '../../widgets/payroll/sets_or_code_dropdown.dart';
import '../models/tab_item.dart';
import '../providers/te_wage_stats_provider.dart';
import '../utils/te_track_stats.dart';

final _dateFormat = DateFormat('EEE d MMM yyyy');

/// Short-lived, best-effort prefill cache shared by every [TEWageStatsBox]
/// instance, keyed by `weekIdFor(weekStart)` — switching between two tabs
/// whose target dates fall in the same payroll week reuses the already-
/// fetched week instead of re-reading the whole document again. Kept
/// deliberately local to this file (not `PayrollProvider`'s currently-open
/// week — see [_TEWageStatsBoxState._save]'s note on why this box always
/// reads/writes its own target week independently). A stale hit only risks
/// showing an out-of-date *prefill* the admin can see and correct; every
/// save still goes through the correctness-preserving transactional
/// [PayrollService.saveDailyEntryForDistributor].
const _weekCacheCap = 6;
final Map<String, PayrollWeek> _weekCache = {};
final List<String> _weekCacheOrder = [];

void _cacheWeek(String weekId, PayrollWeek week) {
  if (!_weekCache.containsKey(weekId)) {
    _weekCacheOrder.add(weekId);
    if (_weekCacheOrder.length > _weekCacheCap) {
      _weekCache.remove(_weekCacheOrder.removeAt(0));
    }
  }
  _weekCache[weekId] = week;
}

class TEWageStatsBox extends riverpod.ConsumerStatefulWidget {
  final TETabItem tab;

  /// Best-guess date for this tab (from track metadata/timestamps) — just
  /// the initial suggestion; the admin can confirm or change it in the box.
  final DateTime suggestedDate;

  const TEWageStatsBox(
      {super.key, required this.tab, required this.suggestedDate});

  @override
  riverpod.ConsumerState<TEWageStatsBox> createState() =>
      _TEWageStatsBoxState();
}

class _TEWageStatsBoxState extends riverpod.ConsumerState<TEWageStatsBox> {
  late final TextEditingController _setsOrCode;
  late final TextEditingController _kmWalked;
  late final TextEditingController _waypoints;
  late final TextEditingController _auditScore;
  late final TextEditingController _notes;
  bool _estimateReached = false;
  bool _loaded = false;
  bool _saving = false;

  /// Whether payroll already has a saved daily entry for this distributor on
  /// [_date] — drives the "Save" vs "Update to Payroll" button label so the
  /// admin can tell at a glance whether they're creating or overwriting.
  bool _hasExisting = false;
  late DateTime _date;

  /// What the last save did to the schedule jobs, kept under the button —
  /// a snackbar is easy to miss. [_scheduleNoteFailed] colours it.
  String? _scheduleNote;
  bool _scheduleNoteFailed = false;

  /// Status ids of the distributor's schedule jobs on [_date], shown beside
  /// the payroll button. Null while loading or when it could not be read.
  List<String>? _jobStatusIds;
  bool _jobStatusLoading = false;

  /// Bumped on every status load, so a slow load for a date the admin has
  /// since moved away from cannot overwrite the current one.
  int _jobStatusRequest = 0;

  /// The auto-computed km/waypoints values as of the last time we filled
  /// them into the fields (on load, or on a previous auto-refresh) — lets
  /// [_refreshAutoValuesIfUnedited] tell whether the admin has since typed
  /// a different value in (in which case we leave it alone) versus the
  /// field still showing what we last auto-filled (in which case it's safe
  /// to update it to match a trimmed/edited track).
  double? _lastAutoKm;
  int? _lastAutoWaypoints;

  @override
  void initState() {
    super.initState();
    _date = widget.suggestedDate;
    _setsOrCode = TextEditingController()..addListener(_markDirty);
    _kmWalked = TextEditingController()..addListener(_markDirty);
    _waypoints = TextEditingController()..addListener(_markDirty);
    _auditScore = TextEditingController()..addListener(_markDirty);
    _notes = TextEditingController()..addListener(_markDirty);
    _loadForCurrentTarget();
  }

  @override
  void didUpdateWidget(covariant TEWageStatsBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only reset to the parent's suggested date when this is genuinely a
    // different tab — once loaded, the admin's own date choice for this
    // tab should stick across incidental rebuilds.
    if (!identical(widget.tab, oldWidget.tab)) {
      _date = widget.suggestedDate;
      _loadForCurrentTarget();
    } else {
      // Same tab instance, but trimming/deleting a track or waypoint
      // mutates its `tracks`/`waypoints` lists in place (see TETabsProvider)
      // rather than replacing the tab — so this is where that shows up.
      _refreshAutoValuesIfUnedited();
    }
  }

  @override
  void dispose() {
    _setsOrCode.dispose();
    _kmWalked.dispose();
    _waypoints.dispose();
    _auditScore.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_loaded) return; // ignore programmatic prefill during load
    ref.read(teWageStatsRiverpod).setDirty(widget.tab, true);
  }

  double get _autoKmWalked => widget.tab.tracks
      .map((t) => TETrackStats.fromTrack(t).distanceKm)
      .fold(0.0, (a, b) => a + b);

  int get _autoWaypoints => widget.tab.waypoints.length;

  /// Re-syncs the km/waypoints fields to the tab's current track/waypoint
  /// data after a trim/delete edit — but only for a field the admin hasn't
  /// since typed a different value into (still showing exactly what we last
  /// auto-filled). Setting `.text` here runs through each controller's
  /// dirty listener like any other edit, so this correctly flips the box
  /// back to "needs saving" if the admin already saved once before trimming.
  void _refreshAutoValuesIfUnedited() {
    if (!_loaded) return;
    final newAutoKm = _autoKmWalked;
    final newAutoWaypoints = _autoWaypoints;

    if (_lastAutoKm != null &&
        newAutoKm != _lastAutoKm &&
        _kmWalked.text == _lastAutoKm!.toStringAsFixed(2)) {
      _kmWalked.text = newAutoKm.toStringAsFixed(2);
    }
    if (_lastAutoWaypoints != null &&
        newAutoWaypoints != _lastAutoWaypoints &&
        _waypoints.text == '$_lastAutoWaypoints') {
      _waypoints.text = '$newAutoWaypoints';
    }
    _lastAutoKm = newAutoKm;
    _lastAutoWaypoints = newAutoWaypoints;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: scheduleNow().add(const Duration(days: 1)),
    );
    if (picked == null ||
        (picked.year == _date.year &&
            picked.month == _date.month &&
            picked.day == _date.day)) {
      return;
    }
    if (!isPayrollWeekEditable(weekStartFor(picked))) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'That week is more than 2 weeks old and is now read-only.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    setState(() => _date = picked);
    await _loadForCurrentTarget();
  }

  Future<void> _loadForCurrentTarget() async {
    final distributorId = widget.tab.distributorId;
    if (distributorId == null) return;
    setState(() {
      _loaded = false;
      _scheduleNote = null;
    });
    // Independent of the payroll read — don't hold the form up on it.
    _loadScheduleStatus();

    final service = ref.read(payrollServiceRiverpod);
    final weekStart = weekStartFor(_date);
    final weekId = weekIdFor(weekStart);

    // Started alongside the payroll read: whether the dropsheet has this
    // distributor driving a vehicle that day decides the sets/code default.
    final distributor = ref
        .read(scheduleRiverpod)
        .distributors
        .where((d) => d.id == distributorId)
        .firstOrNull;
    final drivingFuture = distributor == null
        ? Future.value(false)
        : ref
            .read(dropsheetServiceRiverpod)
            .getDay(_date)
            .then((day) => drivesVehicleOn(day, distributor))
            .catchError((_) => false);

    PayrollDailyEntry? existing;
    try {
      final cached = _weekCache[weekId];
      final week = cached ?? await service.getWeek(weekStart);
      if (cached == null) _cacheWeek(weekId, week);
      existing = week.payslips[distributorId]?.dailyEntries[dayKeyFor(_date)];
    } catch (_) {
      // Couldn't read the payroll week (offline / transient Firestore error).
      // Fall back to the track's auto-computed values so the admin can still
      // enter and save — never leave the box stuck on its loading spinner,
      // which disables the Save button and silently blocks the stats from
      // ever reaching payroll.
      existing = null;
    }
    // A "worked" entry means real stats are already recorded for this day.
    _hasExisting = existing != null && existing.worked;

    final driving = await drivingFuture;
    if (!mounted) return;
    _setsOrCode.text = existing?.specialCode ??
        existing?.flyerSets?.toString() ??
        defaultSetsOrCode(
            drivingThatDay: driving,
            knownCodes: ref.read(payrollRiverpod).settings.bonusCodes);
    _kmWalked.text = (existing?.kmWalked ?? _autoKmWalked).toStringAsFixed(2);
    _waypoints.text = (existing?.waypointsReached ?? _autoWaypoints).toString();
    _auditScore.text = existing?.auditScore?.toString() ?? '';
    _notes.text = existing?.notes ?? '';
    _estimateReached = existing?.estimateReached ?? false;
    // Baseline for _refreshAutoValuesIfUnedited to compare future track
    // edits against — the auto-computed value as of right now, regardless
    // of whether the field above ended up showing it or an existing saved
    // value instead.
    _lastAutoKm = _autoKmWalked;
    _lastAutoWaypoints = _autoWaypoints;

    if (mounted) {
      setState(() => _loaded = true);
      // The prefill above triggers each controller's dirty listener; clear
      // it back out since this was a load, not an admin edit.
      ref.read(teWageStatsRiverpod).setDirty(widget.tab, false);
    }
  }

  PayrollDailyEntry _buildEntry(List<String> knownCodes) {
    final raw = _setsOrCode.text.trim();
    if (raw.isEmpty) {
      return PayrollDailyEntry(
          date: _date, worked: false, notes: _notes.text.trim());
    }
    String? matchedCode;
    for (final c in knownCodes) {
      if (c.toLowerCase() == raw.toLowerCase()) {
        matchedCode = c;
        break;
      }
    }
    return PayrollDailyEntry(
      date: _date,
      worked: true,
      specialCode: matchedCode,
      flyerSets: matchedCode == null ? int.tryParse(raw) : null,
      kmWalked: double.tryParse(_kmWalked.text.trim()),
      waypointsReached: int.tryParse(_waypoints.text.trim()),
      estimateReached: _estimateReached,
      auditScore: int.tryParse(_auditScore.text.trim()),
      notes: _notes.text.trim(),
    );
  }

  /// Atomically writes this one distributor/day into whichever payroll
  /// week it falls in — see [PayrollService.saveDailyEntryForDistributor].
  /// Deliberately bypasses the shared [PayrollProvider]'s currently-open
  /// week (the Payroll tab might have a different week open right now) so
  /// this can never overwrite the wrong week.
  Future<void> _save() async {
    final distributorId = widget.tab.distributorId;
    if (distributorId == null) return;
    // This box bypasses PayrollProvider (see the class doc above), so it
    // doesn't get that provider's isWeekEditable guard for free — check it
    // directly. In practice _date can't reach a locked week today (the
    // panel that shows this box only renders it for an editable suggested
    // date, and _pickDate refuses to move to a locked one), but this is
    // the actual data-layer backstop for that rule on this write path.
    if (!isPayrollWeekEditable(weekStartFor(_date))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('That week is more than 2 weeks old and is now read-only.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final service = ref.read(payrollServiceRiverpod);
      final settings = ref.read(payrollRiverpod).settings;
      final distributor = ref
          .read(scheduleRiverpod)
          .distributors
          .where((d) => d.id == distributorId)
          .firstOrNull;
      if (distributor == null) {
        throw Exception('Matched distributor no longer exists');
      }

      final entry = _buildEntry(settings.bonusCodes);
      await service.saveDailyEntryForDistributor(
        distributor: distributor,
        date: _date,
        entry: entry,
        settings: settings,
      );
      // Invalidate this week's cached prefill data so the next tab
      // targeting the same week re-fetches the just-saved values instead of
      // showing what was cached before this save.
      _weekCache.remove(weekIdFor(weekStartFor(_date)));

      ref.read(teWageStatsRiverpod).setDirty(widget.tab, false);
      // Stats now exist for this day → the button becomes "Update to Payroll".
      if (mounted) setState(() => _hasExisting = true);

      // Recorded stats mean the round was worked, so the distributor's
      // schedule jobs for that day are done. Payroll is already saved at this
      // point, so a failure here is reported on its own, not as a failed save.
      String? statusNote;
      var statusFailed = false;
      try {
        statusNote = await _markScheduleJobsDone(distributorId, _date);
        if (mounted) {
          setState(() {
            _scheduleNote = 'Schedule: $statusNote';
            _scheduleNoteFailed = false;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _scheduleNote = 'Schedule not updated: $e';
            _scheduleNoteFailed = true;
          });
        }
        debugPrint('[TEWageStats] marking schedule jobs done failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Stats saved, but the schedule job status could '
                  'not be set to done: $e'),
              backgroundColor: Colors.orange.shade800,
            ),
          );
        }
        statusFailed = true;
      }
      // Show what the schedule says now, whichever way that went.
      _loadScheduleStatus();

      if (mounted && !statusFailed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Wage stats saved to payroll for ${_dateFormat.format(_date)}'
                '${statusNote == null ? '' : ' · $statusNote'}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Save failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  /// Read the schedule status of the distributor's jobs on [_date].
  Future<void> _loadScheduleStatus() async {
    final distributorId = widget.tab.distributorId;
    if (distributorId == null) return;
    final request = ++_jobStatusRequest;
    setState(() => _jobStatusLoading = true);
    List<String>? ids;
    try {
      final statuses = ref.read(jobStatusRiverpod);
      if (statuses.statuses.isEmpty) await statuses.loadStatuses();
      final jobs = await ref
          .read(scheduleRiverpod)
          .fetchJobsForDistributorAndDate(distributorId, _date);
      ids = [for (final job in jobs) job.statusId];
    } catch (e) {
      debugPrint('[TEWageStats] reading schedule status failed: $e');
    }
    if (!mounted || request != _jobStatusRequest) return;
    setState(() {
      _jobStatusIds = ids;
      _jobStatusLoading = false;
    });
  }

  /// The schedule status of this day's jobs, as the job card shows it. One
  /// chip per distinct status, so a day with a done and a scheduled job says
  /// so rather than picking one.
  Widget _buildScheduleStatus() {
    if (_jobStatusLoading && _jobStatusIds == null) {
      return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2));
    }
    final ids = _jobStatusIds;
    if (ids == null) {
      return Text('Schedule status unavailable',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600));
    }
    if (ids.isEmpty) {
      return Text('No schedule job',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600));
    }
    final statuses = ref.watch(jobStatusRiverpod);
    final counts = <String, int>{};
    for (final id in ids) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return Tooltip(
      message: '${ids.length} schedule job${ids.length == 1 ? '' : 's'} on '
          '${_dateFormat.format(_date)}',
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: WrapAlignment.end,
        children: [
          for (final entry in counts.entries)
            Builder(builder: (_) {
              final status = statuses.getStatusById(entry.key);
              final color = status?.color ?? Colors.grey;
              final label = status?.label ?? entry.key;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  border: Border.all(color: color),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  counts.length == 1 && entry.value == 1
                      ? label
                      : '$label ×${entry.value}',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color.lerp(color, Colors.black, 0.35)),
                ),
              );
            }),
        ],
      ),
    );
  }

  /// Set every schedule job [distributorId] has on [date] to the "Done"
  /// status. Returns a one-line outcome for the save message; throws when the
  /// status cannot be set.
  Future<String> _markScheduleJobsDone(
      String distributorId, DateTime date) async {
    // Resolve "Done" from the configured statuses rather than assuming its
    // id, so a renamed or re-created status still matches.
    final statuses = ref.read(jobStatusRiverpod);
    if (statuses.statuses.isEmpty) await statuses.loadStatuses();
    final done = statuses.getStatusById('done') ??
        statuses.statuses
            .where((st) => st.label.trim().toLowerCase() == 'done')
            .firstOrNull;
    if (done == null) {
      throw Exception('no "Done" status is configured for schedule jobs');
    }

    final schedule = ref.read(scheduleRiverpod);
    final jobs =
        await schedule.fetchJobsForDistributorAndDate(distributorId, date);
    debugPrint('[TEWageStats] ${jobs.length} schedule job(s) for '
        '$distributorId on ${_dateFormat.format(date)}: '
        '${jobs.map((j) => '${j.id}=${j.statusId}').join(', ')}');
    if (jobs.isEmpty) {
      return 'no schedule job found for this distributor on '
          '${_dateFormat.format(date)}';
    }

    var marked = 0;
    for (final job in jobs) {
      if (job.statusId == done.id) continue;
      await schedule.updateJob(job.copyWith(statusId: done.id));
      marked++;
    }
    if (marked == 0) {
      return 'schedule job${jobs.length == 1 ? ' was' : 's were'} '
          'already ${done.label}';
    }
    return '$marked schedule job${marked == 1 ? '' : 's'} set to ${done.label}';
  }

  /// Blue while still loading; green once loaded and in sync with what's
  /// saved to payroll (including right after a successful save); amber
  /// whenever there are edits — including this box's own auto-refresh from
  /// a trimmed/edited track — that haven't been saved yet.
  Color _stateColor(bool isDirty, Color Function(MaterialColor) shade) {
    if (!_loaded) return shade(Colors.blue);
    return shade(isDirty ? Colors.orange : Colors.green);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tab.distributorId == null) return const SizedBox.shrink();

    final isDirty = ref.watch(teWageStatsRiverpod).isDirty(widget.tab);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _stateColor(isDirty, (c) => c.shade50),
        border: Border.all(color: _stateColor(isDirty, (c) => c.shade200)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.payments_outlined,
                  size: 16, color: _stateColor(isDirty, (c) => c.shade700)),
              const SizedBox(width: 6),
              Text(
                'Wage stats for this day',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _stateColor(isDirty, (c) => c.shade800)),
              ),
              const SizedBox(width: 6),
              if (_loaded)
                Tooltip(
                  message: isDirty
                      ? 'Unsaved changes — update to payroll'
                      : 'Saved to payroll',
                  child: Icon(
                    isDirty ? Icons.circle : Icons.check_circle,
                    size: isDirty ? 8 : 14,
                    color: isDirty
                        ? Colors.orange.shade600
                        : Colors.green.shade700,
                  ),
                ),
              if (!_loaded) ...[
                const SizedBox(width: 2),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Date',
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_dateFormat.format(_date),
                        style: const TextStyle(fontSize: 12)),
                  ),
                  const Icon(Icons.edit_calendar, size: 14),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _setsOrCodeField()),
              const SizedBox(width: 6),
              Expanded(child: _field('Km walked', _kmWalked, numeric: true)),
              const SizedBox(width: 6),
              Expanded(child: _field('Waypoints', _waypoints, numeric: true)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                  child: _field('Audit score', _auditScore, numeric: true)),
              const SizedBox(width: 6),
              Expanded(
                flex: 2,
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  value: _estimateReached,
                  onChanged: (v) => setState(() {
                    _estimateReached = v ?? false;
                    _markDirty();
                  }),
                  title: const Text('Estimate reached',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _field('Any other issue', _notes),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _buildScheduleStatus(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: (_saving || !_loaded) ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(_hasExisting ? Icons.sync : Icons.save, size: 16),
                label: Text(
                    _hasExisting ? 'Update to Payroll' : 'Save to Payroll'),
                style: FilledButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (_scheduleNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(
                      _scheduleNoteFailed
                          ? Icons.error_outline
                          : Icons.event_available,
                      size: 14,
                      color: _scheduleNoteFailed
                          ? Colors.orange.shade800
                          : Colors.green.shade700),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(_scheduleNote!,
                        style: TextStyle(
                            fontSize: 11,
                            color: _scheduleNoteFailed
                                ? Colors.orange.shade800
                                : Colors.green.shade800)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _setsOrCodeField() {
    final settings = ref.watch(payrollRiverpod).settings;
    return SetsOrCodeDropdown(
      controller: _setsOrCode,
      codes: settings.bonusCodes,
      codeLabels: settings.bonusCodeLabels,
      style: const TextStyle(fontSize: 12, color: Colors.black87),
      decoration: const InputDecoration(
        labelText: 'Sets / code',
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller,
      {bool numeric = false}) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 12),
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
