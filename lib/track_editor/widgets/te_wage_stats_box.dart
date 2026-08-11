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
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../utils/payroll_week.dart';
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
    setState(() => _loaded = false);

    final service = ref.read(payrollServiceRiverpod);
    final weekStart = weekStartFor(_date);
    final weekId = weekIdFor(weekStart);

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

    _setsOrCode.text =
        existing?.specialCode ?? existing?.flyerSets?.toString() ?? '1';
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Wage stats saved to payroll for ${_dateFormat.format(_date)}'),
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
              Expanded(child: _field('Sets / code', _setsOrCode)),
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
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: (_saving || !_loaded) ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(_hasExisting ? Icons.sync : Icons.save, size: 16),
              label: Text(_hasExisting ? 'Update to Payroll' : 'Save to Payroll'),
              style: FilledButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
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
