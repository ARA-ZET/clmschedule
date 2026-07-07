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

final _dayChipFormat = DateFormat('EEE d');
final _dayBlockFormat = DateFormat('d MMMM');

const double _kLabelColumnWidth = 130;
const double _kDataColumnWidth = 64;
const double _kInputRowHeight = 36;
const double _kTextRowHeight = 20;
const TextStyle _kCellTextStyle = TextStyle(fontSize: 12);
const EdgeInsets _kCellContentPadding =
    EdgeInsets.symmetric(horizontal: 6, vertical: 6);

bool _setEquals(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  return a.every(b.contains);
}

/// Bulk daily-stats entry grid, replacing the old sheet's "Ops Stats" tab:
/// distributors as columns, stats as rows, one block per day of the
/// selected payroll week — matches the spreadsheet layout directly so the
/// whole week is visible by scrolling, with computed Basic/Bonus/Total rows
/// updating live underneath each day's entries.
class OpsStatsView extends riverpod.ConsumerStatefulWidget {
  const OpsStatsView({super.key});

  @override
  riverpod.ConsumerState<OpsStatsView> createState() => _OpsStatsViewState();
}

class _OpsStatsViewState extends riverpod.ConsumerState<OpsStatsView> {
  DateTime? _builtForWeekStart;
  Set<String> _builtDistributorIds = {};
  final Map<String, Map<String, _GridEntryState>> _rowsByDayKey = {};
  final Map<String, GlobalKey> _blockKeys = {};
  final Set<String> _savingDayKeys = {};

  void _disposeAll() {
    for (final byDistributor in _rowsByDayKey.values) {
      for (final s in byDistributor.values) {
        s.dispose();
      }
    }
    _rowsByDayKey.clear();
    _blockKeys.clear();
  }

  @override
  void dispose() {
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
          ),
      };
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
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Wrap(
            spacing: 8,
            children: [
              for (final day in days)
                ActionChip(
                  label: Text(_dayChipFormat.format(day)),
                  onPressed: () => _scrollToDay(day),
                ),
            ],
          ),
        ),
        Expanded(
          child: distributors.isEmpty
              ? const Center(child: Text('No distributors found.'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: days.length,
                  itemBuilder: (context, i) {
                    final day = days[i];
                    final key = dayKeyFor(day);
                    return _DayBlock(
                      key: _blockKeys[key],
                      day: day,
                      distributors: distributors,
                      rows: _rowsByDayKey[key] ?? {},
                      payslips: payroll.week.payslips,
                      settings: payroll.settings,
                      saving: _savingDayKeys.contains(key),
                      onChanged: () => setState(() {}),
                      onSave: () => _saveDay(day, payroll.settings),
                    );
                  },
                ),
        ),
      ],
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
  bool estimateReached;

  _GridEntryState(PayrollDailyEntry entry)
      : date = entry.date,
        estimateReached = entry.estimateReached,
        setsOrCode = TextEditingController(
            text: entry.specialCode ?? entry.flyerSets?.toString() ?? ''),
        kmWalked =
            TextEditingController(text: entry.kmWalked?.toString() ?? ''),
        waypoints = TextEditingController(
            text: entry.waypointsReached?.toString() ?? ''),
        auditScore =
            TextEditingController(text: entry.auditScore?.toString() ?? ''),
        notes = TextEditingController(text: entry.notes);

  PayrollDailyEntry toEntry(List<String> knownCodes) {
    final raw = setsOrCode.text.trim();
    if (raw.isEmpty) {
      return PayrollDailyEntry(date: date, worked: false, notes: notes.text.trim());
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
    setsOrCode.dispose();
    kmWalked.dispose();
    waypoints.dispose();
    auditScore.dispose();
    notes.dispose();
  }
}

class _DayBlock extends StatelessWidget {
  final DateTime day;
  final List<Distributor> distributors;
  final Map<String, _GridEntryState> rows;
  final Map<String, PayrollPayslip> payslips;
  final PayrollSettings settings;
  final bool saving;
  final VoidCallback onChanged;
  final VoidCallback onSave;

  const _DayBlock({
    super.key,
    required this.day,
    required this.distributors,
    required this.rows,
    required this.payslips,
    required this.settings,
    required this.saving,
    required this.onChanged,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            color: Colors.grey.shade800,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _dayBlockFormat.format(day),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                ),
                SizedBox(
                  height: 28,
                  child: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : TextButton(
                          onPressed: onSave,
                          child: const Text('Save day',
                              style: TextStyle(color: Colors.white)),
                        ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: _kLabelColumnWidth, child: _buildLabelColumn()),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: _buildDataColumns(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowLabel(String text, double height) => SizedBox(
        height: height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );

  Widget _buildLabelColumn() {
    return Column(
      children: [
        SizedBox(height: _kTextRowHeight), // header spacer
        _rowLabel('Number of sets / code', _kInputRowHeight),
        _rowLabel('Km walked', _kInputRowHeight),
        _rowLabel('Waypoints', _kInputRowHeight),
        _rowLabel('Estimate reached', _kInputRowHeight),
        _rowLabel('Audit score', _kInputRowHeight),
        _rowLabel('Any other issue', _kInputRowHeight),
        const Divider(height: 8),
        _rowLabel('Basic wage', _kTextRowHeight),
        _rowLabel('Bonus', _kTextRowHeight),
        _rowLabel('Total earning', _kTextRowHeight),
      ],
    );
  }

  Widget _buildDataColumns(BuildContext context) {
    return Column(
      children: [
        // Distributor name header row.
        Row(
          children: [
            for (final d in distributors)
              SizedBox(
                height: _kTextRowHeight,
                width: _kDataColumnWidth,
                child: Text(
                  d.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        _dataRow((d, s) => TextField(
              controller: s.setsOrCode,
              style: _kCellTextStyle,
              decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: _kCellContentPadding,
                  border: OutlineInputBorder()),
              onChanged: (_) => onChanged(),
            )),
        _dataRow((d, s) => TextField(
              controller: s.kmWalked,
              style: _kCellTextStyle,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: _kCellContentPadding,
                  border: OutlineInputBorder()),
              onChanged: (_) => onChanged(),
            )),
        _dataRow((d, s) => TextField(
              controller: s.waypoints,
              style: _kCellTextStyle,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: _kCellContentPadding,
                  border: OutlineInputBorder()),
              onChanged: (_) => onChanged(),
            )),
        _dataRow((d, s) => Checkbox(
              value: s.estimateReached,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) {
                s.estimateReached = v ?? false;
                onChanged();
              },
            )),
        _dataRow((d, s) => TextField(
              controller: s.auditScore,
              style: _kCellTextStyle,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: _kCellContentPadding,
                  border: OutlineInputBorder()),
              onChanged: (_) => onChanged(),
            )),
        _dataRow((d, s) => TextField(
              controller: s.notes,
              style: _kCellTextStyle,
              decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: _kCellContentPadding,
                  border: OutlineInputBorder()),
              onChanged: (_) => onChanged(),
            )),
        const Divider(height: 8),
        _computedRow((p, entry) =>
            calc.dailyBasic(entry, dayRate: p.dayRateSnapshot)),
        _computedRow((p, entry) => calc.dailyBonus(
              entry,
              bonusCodeAmounts: p.bonusCodeAmountsSnapshot,
              perSetRate: p.perSetRateSnapshot,
              estimateBonus: p.estimateBonusSnapshot,
            )),
        _computedRow(
          (p, entry) =>
              calc.dailyBasic(entry, dayRate: p.dayRateSnapshot) +
              calc.dailyBonus(
                entry,
                bonusCodeAmounts: p.bonusCodeAmountsSnapshot,
                perSetRate: p.perSetRateSnapshot,
                estimateBonus: p.estimateBonusSnapshot,
              ),
          bold: true,
        ),
      ],
    );
  }

  Widget _dataRow(Widget Function(Distributor, _GridEntryState) cellBuilder) {
    return Row(
      children: [
        for (final d in distributors)
          SizedBox(
            height: _kInputRowHeight,
            width: _kDataColumnWidth,
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

  Widget _computedRow(
    double Function(PayrollPayslip, PayrollDailyEntry) compute, {
    bool bold = false,
  }) {
    return Row(
      children: [
        for (final d in distributors)
          SizedBox(
            height: _kTextRowHeight,
            width: _kDataColumnWidth,
            child: Builder(builder: (context) {
              final payslip = payslips[d.id];
              final state = rows[d.id];
              if (payslip == null || state == null) return const Text('—');
              final value =
                  compute(payslip, state.toEntry(settings.bonusCodes));
              return Text(
                value.toStringAsFixed(0),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal),
              );
            }),
          ),
      ],
    );
  }
}
