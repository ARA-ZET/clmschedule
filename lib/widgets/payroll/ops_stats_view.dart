import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/distributor.dart';
import '../../models/payroll_daily_entry.dart';
import '../../models/payroll_payslip.dart';
import '../../models/payroll_settings.dart';
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../utils/payroll_calculator.dart' as calc;
import '../../utils/payroll_week.dart';

final _dayBlockFormat = DateFormat('d MMMM');

const double _kLabelColumnWidth = 130;
const double _kDataColumnMinWidth = 64;
const double _kDataColumnMaxWidth = 110;
const double _kInputRowHeight = 36;
const double _kTextRowHeight = 20;
const double _kHeaderRowHeight = 30;
const TextStyle _kCellTextStyle =
    TextStyle(fontSize: 12, fontWeight: FontWeight.bold);
const EdgeInsets _kCellContentPadding =
    EdgeInsets.symmetric(horizontal: 6, vertical: 6);
final Color _kWorkingCellColor = Colors.white;
final Color _kOffCellColor = Colors.grey.shade300;

bool _setEquals(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  return a.every(b.contains);
}

/// Distributor columns share the available width evenly, but never below
/// [_kDataColumnMinWidth] (triggering horizontal scroll once too many
/// distributors are on the roster) or above [_kDataColumnMaxWidth] (so a
/// handful of distributors don't stretch into uncomfortably wide cells).
/// Shared by [_DayBlock] and [_WeeklyTotalsRow] so their columns always
/// line up, regardless of which one last resolved the width for a given
/// layout pass.
double _resolveColumnWidth(double availableWidth, int distributorCount) {
  if (distributorCount == 0) return _kDataColumnMinWidth;
  final raw = availableWidth / distributorCount;
  return raw.clamp(_kDataColumnMinWidth, _kDataColumnMaxWidth);
}

/// Keeps several [ScrollController]s in sync so scrolling any one day
/// block's horizontal scroller moves every other day block to the same
/// offset — needed so distributor columns stay visually aligned when
/// scrolling through a week with more distributors than fit on screen.
class _LinkedScrollControllerGroup {
  final List<_LinkedScrollController> _controllers = [];
  bool _isSyncing = false;

  ScrollController addAndGet() {
    final controller = _LinkedScrollController(this);
    _controllers.add(controller);
    return controller;
  }

  void _syncOffset(_LinkedScrollController source) {
    if (_isSyncing || !source.hasClients) return;
    _isSyncing = true;
    final offset = source.offset;
    for (final controller in _controllers) {
      if (identical(controller, source) || !controller.hasClients) continue;
      controller.jumpTo(offset);
    }
    _isSyncing = false;
  }

  void remove(_LinkedScrollController controller) {
    _controllers.remove(controller);
  }
}

class _LinkedScrollController extends ScrollController {
  final _LinkedScrollControllerGroup _group;

  _LinkedScrollController(this._group) {
    addListener(_didScroll);
  }

  void _didScroll() => _group._syncOffset(this);

  @override
  void dispose() {
    removeListener(_didScroll);
    _group.remove(this);
    super.dispose();
  }
}

/// Lets a parent (e.g. day-chip quick-nav rendered in [PayrollTab]'s own
/// header row, alongside the Ops Stats/Payslips toggle) tell an
/// [OpsStatsView] to scroll to a given day, without the parent needing to
/// know anything about the view's internal state.
class OpsStatsController {
  void Function(DateTime)? _scrollToDayImpl;

  void scrollToDay(DateTime day) => _scrollToDayImpl?.call(day);
}

/// Bulk daily-stats entry grid, replacing the old sheet's "Ops Stats" tab:
/// distributors as columns, stats as rows, one block per day of the
/// selected payroll week — matches the spreadsheet layout directly so the
/// whole week is visible by scrolling, with computed Basic/Bonus/Total rows
/// updating live underneath each day's entries.
class OpsStatsView extends riverpod.ConsumerStatefulWidget {
  final OpsStatsController? controller;

  const OpsStatsView({super.key, this.controller});

  @override
  riverpod.ConsumerState<OpsStatsView> createState() => _OpsStatsViewState();
}

class _OpsStatsViewState extends riverpod.ConsumerState<OpsStatsView> {
  DateTime? _builtForWeekStart;
  Set<String> _builtDistributorIds = {};

  /// The `payslips` map reference last used to (re)build or refresh the
  /// grid — `PayrollProvider`'s live stream hands back a brand-new map on
  /// every Firestore snapshot, so comparing by reference is a cheap,
  /// reliable trigger for "something may have changed remotely" (e.g. the
  /// Track Editor's wage-stats box saving into this same week, or another
  /// session editing Ops Stats concurrently).
  Map<String, PayrollPayslip>? _lastSeenPayslips;
  final Map<String, Map<String, _GridEntryState>> _rowsByDayKey = {};
  final Map<String, GlobalKey> _blockKeys = {};
  final Set<String> _savingDayKeys = {};
  final Map<String, Timer> _autoSaveDebounce = {};
  final Set<String> _collapsedDayKeys = {};

  // One shared group so every day block's horizontal scroller — one column
  // per distributor — stays aligned when scrolling any single one of them.
  final _LinkedScrollControllerGroup _scrollGroup =
      _LinkedScrollControllerGroup();
  final Map<String, ScrollController> _scrollControllersByDayKey = {};

  ScrollController _scrollControllerFor(String dayKey) =>
      _scrollControllersByDayKey.putIfAbsent(dayKey, _scrollGroup.addAndGet);

  void _toggleCollapsed(String key) => setState(() {
        if (!_collapsedDayKeys.remove(key)) _collapsedDayKeys.add(key);
      });

  void _disposeAll() {
    for (final byDistributor in _rowsByDayKey.values) {
      for (final s in byDistributor.values) {
        s.dispose();
      }
    }
    _rowsByDayKey.clear();
    _blockKeys.clear();
    for (final t in _autoSaveDebounce.values) {
      t.cancel();
    }
    _autoSaveDebounce.clear();
    for (final c in _scrollControllersByDayKey.values) {
      c.dispose();
    }
    _scrollControllersByDayKey.clear();
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._scrollToDayImpl = _scrollToDay;
  }

  @override
  void didUpdateWidget(OpsStatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._scrollToDayImpl = null;
      widget.controller?._scrollToDayImpl = _scrollToDay;
    }
  }

  @override
  void dispose() {
    widget.controller?._scrollToDayImpl = null;
    _disposeAll();
    super.dispose();
  }

  void _buildRows(
    List<DateTime> days,
    List<Distributor> distributors,
    Map<String, PayrollPayslip> payslips,
  ) {
    _disposeAll();
    for (final day in days) {
      final key = dayKeyFor(day);
      _blockKeys[key] = GlobalKey();
      _rowsByDayKey[key] = {
        for (final d in distributors)
          d.id: _GridEntryState(
            payslips[d.id]?.dailyEntries[key] ?? PayrollDailyEntry.empty(day),
          )..onFieldBlur = () =>
              _scheduleSaveOnBlur(day, ref.read(payrollRiverpod).settings),
      };
    }
  }

  /// Re-syncs already-built rows to a fresh `payslips` snapshot without
  /// disposing/recreating any `_GridEntryState` (which would drop focus/
  /// cursor position mid-edit) — the fix for Ops Stats not reflecting a
  /// remote update (another session, or the Track Editor's wage-stats box
  /// saving into this same week) until the tab was switched away and back,
  /// which previously force-recreated the state from scratch.
  void _refreshRows(List<DateTime> days, Map<String, PayrollPayslip> payslips) {
    for (final day in days) {
      final key = dayKeyFor(day);
      final byDistributor = _rowsByDayKey[key];
      if (byDistributor == null) continue;
      for (final entry in byDistributor.entries) {
        final newEntry = payslips[entry.key]?.dailyEntries[key] ??
            PayrollDailyEntry.empty(day);
        entry.value.refreshFromEntry(newEntry);
      }
    }
  }

  Future<void> _saveDay(DateTime day, PayrollSettings settings) async {
    final key = dayKeyFor(day);
    setState(() => _savingDayKeys.add(key));
    final rows = _rowsByDayKey[key] ?? {};
    final edits = <String, PayrollDailyEntry>{
      for (final e in rows.entries) e.key: e.value.toEntry(settings.bonusCodes),
    };
    await ref.read(payrollRiverpod).updateDayForAllDistributors(day, edits);
    if (mounted) setState(() => _savingDayKeys.remove(key));
  }

  /// Saves [day] a short delay after the admin moves on from a field
  /// (loses focus) or toggles the estimate-reached checkbox — NOT on every
  /// keystroke. Typing freely in a field never triggers a write; the short
  /// delay here just coalesces several near-simultaneous blur events (e.g.
  /// tabbing through several fields in one row) into a single save.
  void _scheduleSaveOnBlur(DateTime day, PayrollSettings settings) {
    final key = dayKeyFor(day);
    _autoSaveDebounce[key]?.cancel();
    _autoSaveDebounce[key] = Timer(const Duration(milliseconds: 300), () {
      _autoSaveDebounce.remove(key);
      _saveDay(day, settings);
    });
  }

  void _scrollToDay(DateTime day) {
    final key = _blockKeys[dayKeyFor(day)];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payroll = ref.watch(payrollRiverpod);
    final schedule = ref.watch(scheduleRiverpod);
    final editable = isPayrollWeekEditable(payroll.weekStart);
    final distributors = schedule.distributorsWithJobsInRange(
        payroll.weekStart, payroll.weekEnd)
      ..sort((a, b) => a.index.compareTo(b.index));
    final days = daysInWeek(payroll.weekStart);

    final distributorIds = {for (final d in distributors) d.id};
    if (_builtForWeekStart != payroll.weekStart ||
        !_setEquals(_builtDistributorIds, distributorIds)) {
      _buildRows(days, distributors, payroll.week.payslips);
      _builtForWeekStart = payroll.weekStart;
      _builtDistributorIds = distributorIds;
      _lastSeenPayslips = payroll.week.payslips;
    } else if (!identical(_lastSeenPayslips, payroll.week.payslips)) {
      // Same week/roster, but a new payslips snapshot arrived (a remote
      // write — e.g. Track Editor's wage-stats box, another admin session,
      // or this view's own debounced save round-tripping back) — refresh
      // in place instead of waiting for the admin to leave and re-enter.
      _refreshRows(days, payroll.week.payslips);
      _lastSeenPayslips = payroll.week.payslips;
    }

    if (distributors.isEmpty) {
      return const Center(child: Text('No distributors found.'));
    }

    return Column(
      children: [
        if (!editable) const _LockedWeekBanner(),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: days.length,
            itemBuilder: (context, i) {
              final day = days[i];
              final key = dayKeyFor(day);
              final workingDistributorIds = {
                for (final d in distributors)
                  if (schedule
                      .getJobsForDistributorAndDate(d.id, day)
                      .isNotEmpty)
                    d.id,
              };
              // A distributor with stats already saved for this day
              // (`worked: true`) who no longer has a schedule job on it —
              // the schedule was changed after the stats were entered, so
              // the saved numbers may no longer be valid. Flagged with a
              // red cell border rather than silently left as-is.
              final mismatchedDistributorIds = {
                for (final d in distributors)
                  if (!workingDistributorIds.contains(d.id) &&
                      (payroll.week.payslips[d.id]?.dailyEntries[key]
                              ?.worked ??
                          false))
                    d.id,
              };
              return _DayBlock(
                key: _blockKeys[key],
                day: day,
                distributors: distributors,
                rows: _rowsByDayKey[key] ?? {},
                payslips: payroll.week.payslips,
                settings: payroll.settings,
                saving: _savingDayKeys.contains(key),
                collapsed: _collapsedDayKeys.contains(key),
                editable: editable,
                workingDistributorIds: workingDistributorIds,
                mismatchedDistributorIds: mismatchedDistributorIds,
                scrollController: _scrollControllerFor(key),
                onToggleCollapsed: () => _toggleCollapsed(key),
                // Deliberately does NOT call setState: each distributor's
                // computed cells listen directly to that distributor's own
                // _GridEntryState.listenable (see _ComputedTriple), so a
                // keystroke only repaints that one column instead of
                // rebuilding this whole day block (all distributors, all
                // rows) on every character typed. Text fields no longer
                // call this on every keystroke either (see the _dataRow
                // TextFields below) — only the estimate-reached checkbox
                // still uses it directly, since a checkbox toggle is a
                // discrete action rather than something a focus-loss event
                // makes sense for.
                onChanged: () => _scheduleSaveOnBlur(day, payroll.settings),
              );
            },
          ),
        ),
        _WeeklyTotalsRow(
          distributors: distributors,
          payslips: payroll.week.payslips,
          scrollController: _scrollControllerFor(_kWeeklyTotalsScrollKey),
        ),
      ],
    );
  }
}

/// The key [_scrollControllerFor] uses for the weekly-totals footer row's
/// scroll controller — distinct from any real `dayKeyFor(...)` value so it
/// gets its own controller in the shared [_LinkedScrollControllerGroup]
/// (keeping this row's columns aligned with every day block's) without
/// colliding with an actual day.
const _kWeeklyTotalsScrollKey = '__weekly_totals__';

/// Fixed footer below the scrollable day blocks — one column per
/// distributor showing their gross wage summed across the whole week
/// (`PayrollPayslip.grossWage`, already kept current by `recomputeWeek` on
/// every save), so the week's bottom line is visible without scrolling
/// through every day. Shares the day blocks' scroll-sync group and column
/// width so it stays lined up with them when scrolling horizontally.
class _WeeklyTotalsRow extends StatelessWidget {
  final List<Distributor> distributors;
  final Map<String, PayrollPayslip> payslips;
  final ScrollController scrollController;

  const _WeeklyTotalsRow({
    required this.distributors,
    required this.payslips,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    // Mirrors _DayBlock.build()'s exact padding structure (outer
    // Padding(8) -> Row[label(130), Expanded(...)] -> inner
    // Padding(left: 8) before the per-distributor columns) so this row's
    // columns land at precisely the same x-offsets as every day block's,
    // keeping them visually aligned when scrolled via the shared
    // _LinkedScrollControllerGroup.
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(
              width: _kLabelColumnWidth,
              child: Text(
                'Weekly gross wage',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columnWidth = _resolveColumnWidth(
                      constraints.maxWidth, distributors.length);
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: scrollController,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Row(
                        children: [
                          for (final d in distributors)
                            SizedBox(
                              width: columnWidth,
                              child: Center(
                                child: Text(
                                  (payslips[d.id]?.grossWage ?? 0)
                                      .toStringAsFixed(0),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown above the grid instead of editing being silently ignored — this
/// week is more than 2 pay-week cycles old, so `PayrollProvider` refuses
/// to persist edits to it (see `PayrollProvider.isWeekEditable`).
class _LockedWeekBanner extends StatelessWidget {
  const _LockedWeekBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: Colors.grey.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This week is more than 2 weeks old and is now read-only.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ),
        ],
      ),
    );
  }
}

/// Free-typed editing state for one distributor's one day within the grid.
/// Unlike [DayEntryState] (used by the single-distributor editor's explicit
/// Off/Normal/Special toggle), the grid mirrors the original sheet: one text
/// cell for "sets", where typing a known bonus code (e.g. "DR") or a number
/// both live in the same field.
class _GridEntryState {
  final DateTime date;
  final TextEditingController setsOrCode;
  final TextEditingController kmWalked;
  final TextEditingController waypoints;
  final TextEditingController auditScore;
  final TextEditingController notes;
  final ValueNotifier<bool> estimateReachedNotifier;

  /// The entry these fields were last populated from — either at initial
  /// load or the last successful [refreshFromEntry] — used to tell whether
  /// a field still shows exactly what was loaded (safe to refresh) versus
  /// having since been typed into by the admin (must not be clobbered).
  PayrollDailyEntry _lastLoadedEntry;

  /// Fires whenever anything about this distributor's day changes — lets
  /// just this one column's computed cells rebuild instead of the whole
  /// day block (see [_DistributorColumn]).
  late final Listenable listenable = Listenable.merge([
    setsOrCode,
    kmWalked,
    waypoints,
    auditScore,
    notes,
    estimateReachedNotifier,
  ]);

  bool get estimateReached => estimateReachedNotifier.value;
  set estimateReached(bool v) => estimateReachedNotifier.value = v;

  final FocusNode setsOrCodeFocus = FocusNode();
  final FocusNode kmWalkedFocus = FocusNode();
  final FocusNode waypointsFocus = FocusNode();
  final FocusNode auditScoreFocus = FocusNode();
  final FocusNode notesFocus = FocusNode();

  /// Fired when any of this row's text fields loses focus — the save
  /// trigger. Typing itself never schedules a write (unlike the old
  /// per-keystroke debounce); a value is only persisted once the admin
  /// actually moves on from the field, so sitting in a field mid-thought
  /// never causes a background save.
  VoidCallback? onFieldBlur;

  _GridEntryState(PayrollDailyEntry entry)
      : date = entry.date,
        _lastLoadedEntry = entry,
        estimateReachedNotifier = ValueNotifier(entry.estimateReached),
        setsOrCode = TextEditingController(
            text: entry.specialCode ?? entry.flyerSets?.toString() ?? ''),
        kmWalked =
            TextEditingController(text: entry.kmWalked?.toString() ?? ''),
        waypoints = TextEditingController(
            text: entry.waypointsReached?.toString() ?? ''),
        auditScore =
            TextEditingController(text: entry.auditScore?.toString() ?? ''),
        notes = TextEditingController(text: entry.notes) {
    for (final node in [
      setsOrCodeFocus,
      kmWalkedFocus,
      waypointsFocus,
      auditScoreFocus,
      notesFocus,
    ]) {
      node.addListener(() {
        if (!node.hasFocus) onFieldBlur?.call();
      });
    }
  }

  static String _formatSetsOrCode(PayrollDailyEntry e) =>
      e.specialCode ?? e.flyerSets?.toString() ?? '';

  void _refreshField(
      TextEditingController controller, String oldValue, String newValue) {
    // Only overwrite if the field still shows exactly what it was last
    // loaded with — if it differs, the admin has typed something in since,
    // and a remote update (e.g. from the Ops Stats grid on another
    // session, or the Track Editor's wage-stats box) must not clobber it.
    if (oldValue != newValue && controller.text == oldValue) {
      controller.text = newValue;
    }
  }

  /// Re-syncs these fields to [newEntry] (a fresh snapshot arriving via
  /// `PayrollProvider`'s live Firestore stream) — called whenever the
  /// underlying payslip data changes for a day/distributor whose grid row
  /// is already built, so edits made elsewhere (another session, or the
  /// Track Editor's "Wage stats for this day" box writing directly into
  /// this same week) show up here without needing to leave and re-enter
  /// the Ops Stats tab.
  void refreshFromEntry(PayrollDailyEntry newEntry) {
    _refreshField(setsOrCode, _formatSetsOrCode(_lastLoadedEntry),
        _formatSetsOrCode(newEntry));
    _refreshField(kmWalked, _lastLoadedEntry.kmWalked?.toString() ?? '',
        newEntry.kmWalked?.toString() ?? '');
    _refreshField(
        waypoints,
        _lastLoadedEntry.waypointsReached?.toString() ?? '',
        newEntry.waypointsReached?.toString() ?? '');
    _refreshField(auditScore, _lastLoadedEntry.auditScore?.toString() ?? '',
        newEntry.auditScore?.toString() ?? '');
    _refreshField(notes, _lastLoadedEntry.notes, newEntry.notes);
    if (estimateReached == _lastLoadedEntry.estimateReached) {
      estimateReached = newEntry.estimateReached;
    }
    _lastLoadedEntry = newEntry;
  }

  PayrollDailyEntry toEntry(List<String> knownCodes) {
    final raw = setsOrCode.text.trim();
    if (raw.isEmpty) {
      return PayrollDailyEntry(
          date: date, worked: false, notes: notes.text.trim());
    }
    String? matchedCode;
    for (final c in knownCodes) {
      if (c.toLowerCase() == raw.toLowerCase()) {
        matchedCode = c;
        break;
      }
    }
    return PayrollDailyEntry(
      date: date,
      worked: true,
      specialCode: matchedCode,
      flyerSets: matchedCode == null ? int.tryParse(raw) : null,
      kmWalked: double.tryParse(kmWalked.text.trim()),
      waypointsReached: int.tryParse(waypoints.text.trim()),
      estimateReached: estimateReached,
      auditScore: int.tryParse(auditScore.text.trim()),
      notes: notes.text.trim(),
    );
  }

  void dispose() {
    // Disposing a still-focused FocusNode notifies listeners with
    // hasFocus == false as part of tearing it down — clear the callback
    // first so that doesn't schedule a pointless (and potentially unsafe,
    // this-state-may-already-be-gone) save.
    onFieldBlur = null;
    setsOrCode.dispose();
    kmWalked.dispose();
    waypoints.dispose();
    auditScore.dispose();
    notes.dispose();
    setsOrCodeFocus.dispose();
    kmWalkedFocus.dispose();
    waypointsFocus.dispose();
    auditScoreFocus.dispose();
    notesFocus.dispose();
    estimateReachedNotifier.dispose();
  }
}

class _DayBlock extends StatelessWidget {
  final DateTime day;
  final List<Distributor> distributors;
  final Map<String, _GridEntryState> rows;
  final Map<String, PayrollPayslip> payslips;
  final PayrollSettings settings;
  final bool saving;
  final bool collapsed;

  /// False once this week is more than 2 pay-week cycles old — every
  /// input in this block becomes read-only (see [_cellDecoration] and the
  /// `enabled:`/`onChanged:` wiring in [_buildDataColumns]).
  final bool editable;

  /// Ids of distributors who have a job allocated on the main schedule for
  /// [day] — their column's entry fields get a white background; everyone
  /// else (off, or simply not allocated) gets a grey one and is locked
  /// against editing (see [_cellDecoration] and the `enabled:` wiring in
  /// [_buildDataColumns]).
  final Set<String> workingDistributorIds;

  /// Ids of distributors with stats already saved for [day] whose schedule
  /// job for that day has since been removed/reassigned — i.e. the
  /// schedule changed after the stats were entered. Their cells get a red
  /// border instead of the normal grey/off one, on top of being disabled.
  final Set<String> mismatchedDistributorIds;
  final ScrollController scrollController;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onChanged;

  const _DayBlock({
    super.key,
    required this.day,
    required this.distributors,
    required this.rows,
    required this.payslips,
    required this.settings,
    required this.saving,
    required this.collapsed,
    required this.editable,
    required this.workingDistributorIds,
    required this.mismatchedDistributorIds,
    required this.scrollController,
    required this.onToggleCollapsed,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: _kLabelColumnWidth, child: _buildLabelColumn()),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columnWidth = _resolveColumnWidth(
                      constraints.maxWidth, distributors.length);
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: scrollController,
                    child: _buildDataColumns(context, columnWidth),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowLabel(String text, double height) => SizedBox(
        height: height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );

  Widget _buildLabelColumn() {
    return Column(
      children: [
        Container(
          height: _kHeaderRowHeight,
          color: Colors.black,
          child: Row(
            children: [
              InkWell(
                onTap: onToggleCollapsed,
                child: Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  _dayBlockFormat.format(day),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (saving)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
            ],
          ),
        ),
        if (!collapsed) ...[
          _rowLabel('Number of sets / code', _kInputRowHeight),
          _rowLabel('Km walked', _kInputRowHeight),
          _rowLabel('Waypoints', _kInputRowHeight),
          _rowLabel('Estimate reached', _kInputRowHeight),
          _rowLabel('Audit score', _kInputRowHeight),
          _rowLabel('Any other issue', _kInputRowHeight),
          const Divider(height: 8),
        ],
        _rowLabel('Basic wage', _kTextRowHeight),
        _rowLabel('Bonus', _kTextRowHeight),
        _rowLabel('Total earning', _kTextRowHeight),
      ],
    );
  }

  Color _cellColorFor(Distributor d) => workingDistributorIds.contains(d.id)
      ? _kWorkingCellColor
      : _kOffCellColor;

  /// A distributor's stats cells for this day can only be typed into when
  /// the week isn't locked AND they actually have a schedule job on this
  /// day — a day they didn't work shouldn't accept stats at all, matching
  /// the checkbox cell (which already only renders for working days).
  bool _isEditableFor(Distributor d) =>
      editable && workingDistributorIds.contains(d.id);

  /// Off cells get a border matching their grey fill, so the whole cell
  /// reads as one solid blocked-out box; working cells get a subtle light
  /// border against their white fill so the input field is still visible.
  /// A mismatched cell (stats saved, then the schedule job removed —
  /// see [mismatchedDistributorIds]) gets a red border instead, so it
  /// stands out even though it's also disabled. Every border variant
  /// (enabled/focused/disabled) is pinned to the same color explicitly —
  /// Material's default focus/hover state colors would otherwise override
  /// a plain `border:` once the field is interacted with.
  InputDecoration _cellDecoration(Distributor d) {
    final isMismatched = mismatchedDistributorIds.contains(d.id);
    final color = isMismatched
        ? Colors.red
        : workingDistributorIds.contains(d.id)
            ? Colors.grey.shade200
            : _kOffCellColor;
    final border = OutlineInputBorder(
      borderSide: BorderSide(color: color, width: isMismatched ? 2 : 1),
    );
    return InputDecoration(
      isDense: true,
      contentPadding: _kCellContentPadding,
      border: border,
      enabledBorder: border,
      focusedBorder: border,
      disabledBorder: border,
    );
  }

  Widget _buildDataColumns(BuildContext context, double columnWidth) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        children: [
          // Distributor name header row — shares its row with the date label
          // in the label column to its left, saving a whole row of height.
          Container(
            color: Colors.black,
            child: Row(
              children: [
                for (final d in distributors)
                  SizedBox(
                    height: _kHeaderRowHeight,
                    width: columnWidth,
                    child: Center(
                      child: Text(
                        d.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!collapsed) ...[
            _dataRow(
                columnWidth,
                (d, s) => TextField(
                      controller: s.setsOrCode,
                      focusNode: s.setsOrCodeFocus,
                      enabled: _isEditableFor(d),
                      style: _kCellTextStyle,
                      decoration: _cellDecoration(d),
                    )),
            _dataRow(
                columnWidth,
                (d, s) => TextField(
                      controller: s.kmWalked,
                      focusNode: s.kmWalkedFocus,
                      enabled: _isEditableFor(d),
                      style: _kCellTextStyle,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: _cellDecoration(d),
                    )),
            _dataRow(
                columnWidth,
                (d, s) => TextField(
                      controller: s.waypoints,
                      focusNode: s.waypointsFocus,
                      enabled: _isEditableFor(d),
                      style: _kCellTextStyle,
                      keyboardType: TextInputType.number,
                      decoration: _cellDecoration(d),
                    )),
            _dataRow(
                columnWidth,
                (d, s) => Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: mismatchedDistributorIds.contains(d.id)
                              ? Colors.red
                              : workingDistributorIds.contains(d.id)
                                  ? Colors.grey.shade100
                                  : _kOffCellColor,
                          width:
                              mismatchedDistributorIds.contains(d.id) ? 2 : 1,
                        ),
                      ),
                      child: workingDistributorIds.contains(d.id)
                          ? Checkbox(
                              value: s.estimateReached,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: !editable
                                  ? null
                                  : (v) {
                                      s.estimateReached = v ?? false;
                                      onChanged();
                                    },
                            )
                          : null,
                    )),
            _dataRow(
                columnWidth,
                (d, s) => TextField(
                      controller: s.auditScore,
                      focusNode: s.auditScoreFocus,
                      enabled: _isEditableFor(d),
                      style: _kCellTextStyle,
                      keyboardType: TextInputType.number,
                      decoration: _cellDecoration(d),
                    )),
            _dataRow(
                columnWidth,
                (d, s) => TextField(
                      controller: s.notes,
                      focusNode: s.notesFocus,
                      enabled: _isEditableFor(d),
                      style: _kCellTextStyle,
                      decoration: _cellDecoration(d),
                    )),
            const Divider(height: 8),
          ],
          _computedTripleRow(columnWidth),
        ],
      ),
    );
  }

  /// One row of per-distributor computed Basic/Bonus/Total cells. Each
  /// distributor's triple is wrapped in a single `ListenableBuilder` tied to
  /// that distributor's own `_GridEntryState.listenable`, so: (a) typing in
  /// one distributor's fields only repaints that distributor's own three
  /// computed cells, never the other distributors' or the surrounding day
  /// block; and (b) `toEntry()` is computed once per distributor and shared
  /// across Basic/Bonus/Total instead of being re-derived independently by
  /// each of the three rows.
  Widget _computedTripleRow(double columnWidth) {
    return Row(
      children: [
        for (final d in distributors)
          Container(
            width: columnWidth,
            color: _cellColorFor(d),
            child: rows[d.id] == null
                ? SizedBox(height: _kTextRowHeight * 3)
                : ListenableBuilder(
                    listenable: rows[d.id]!.listenable,
                    builder: (context, _) {
                      final payslip = payslips[d.id];
                      final state = rows[d.id]!;
                      if (payslip == null) {
                        return SizedBox(
                          height: _kTextRowHeight * 3,
                          child: const Center(child: Text('—')),
                        );
                      }
                      final entry = state.toEntry(settings.bonusCodes);
                      final basic = calc.dailyBasic(entry,
                          dayRate: payslip.dayRateSnapshot);
                      final bonus = calc.dailyBonus(
                        entry,
                        bonusCodeAmounts:
                            payslip.effectiveBonusCodeAmounts(settings),
                        perSetRate: payslip.perSetRateSnapshot,
                        estimateBonus: payslip.estimateBonusSnapshot,
                      );
                      final total = basic + bonus;
                      return Column(
                        children: [
                          _computedCellText(basic, bold: true),
                          _computedCellText(bonus),
                          _computedCellText(total, bold: true),
                        ],
                      );
                    },
                  ),
          ),
      ],
    );
  }

  Widget _computedCellText(double value, {bool bold = false}) => SizedBox(
        height: _kTextRowHeight,
        child: Text(
          value.toStringAsFixed(0),
          style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal),
        ),
      );

  Widget _dataRow(double columnWidth,
      Widget Function(Distributor, _GridEntryState) cellBuilder) {
    return Row(
      children: [
        for (final d in distributors)
          Container(
            height: _kInputRowHeight,
            width: columnWidth,
            color: _cellColorFor(d),
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: rows[d.id] == null
                  ? const SizedBox.shrink()
                  : cellBuilder(d, rows[d.id]!),
            ),
          ),
      ],
    );
  }
}
