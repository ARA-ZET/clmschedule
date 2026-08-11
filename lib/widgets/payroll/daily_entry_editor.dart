import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/payroll_daily_entry.dart';
import '../../models/payroll_payslip.dart';
import '../../models/payroll_settings.dart';
import '../../providers/payroll_provider.dart';
import '../../utils/payroll_calculator.dart' as calc;
import '../../utils/payroll_week.dart';
import 'payroll_entry_state.dart';

final _dayLabelFormat = DateFormat('EEEE d MMM');

/// Full-page editor for one distributor's 7 daily entries (Fri..Thu) for
/// the currently selected payroll week. Each day is either off, a
/// flat-bonus special-code day (driving, scooter, etc.), or a normal
/// distribution day (flyer sets / km / waypoints / estimate / notes) —
/// never both. Shows a live computed total per day using the payslip's
/// already-snapshotted rates, so the preview always matches what gets
/// saved.
class DailyEntryEditor extends riverpod.ConsumerStatefulWidget {
  final String distributorId;

  const DailyEntryEditor({super.key, required this.distributorId});

  @override
  riverpod.ConsumerState<DailyEntryEditor> createState() =>
      _DailyEntryEditorState();
}

class _DailyEntryEditorState extends riverpod.ConsumerState<DailyEntryEditor> {
  late List<DayEntryState> _rows;
  bool _initialized = false;
  bool _saving = false;

  @override
  void dispose() {
    if (_initialized) {
      for (final row in _rows) {
        row.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final payroll = ref.watch(payrollRiverpod);
    final payslip = payroll.week.payslips[widget.distributorId];
    final editable = isPayrollWeekEditable(payroll.weekStart);

    if (!_initialized) {
      final days = daysInWeek(payroll.weekStart);
      _rows = days.map((d) {
        final entry =
            payslip?.dailyEntries[dayKeyFor(d)] ?? PayrollDailyEntry.empty(d);
        return DayEntryState(entry);
      }).toList();
      _initialized = true;
    }

    if (payslip == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit days')),
        body: const Center(child: Text('No payslip for this week yet.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${payslip.distributorName} — daily entries'),
        actions: [
          TextButton(
            onPressed:
                (!editable || _saving) ? null : () => _save(payroll, payslip),
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('SAVE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!editable)
            Container(
              width: double.infinity,
              color: Colors.grey.shade200,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.lock_outline,
                      size: 16, color: Colors.grey.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This week is more than 2 weeks old and is now read-only.',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length,
              itemBuilder: (context, i) => _DayCard(
                state: _rows[i],
                settings: payroll.settings,
                payslip: payslip,
                editable: editable,
                onChanged: () => setState(() {}),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save(PayrollProvider payroll, PayrollPayslip payslip) async {
    setState(() => _saving = true);
    final edits = <DateTime, PayrollDailyEntry>{
      for (final row in _rows) row.entry.date: row.entry,
    };
    await payroll.updateDistributorDays(widget.distributorId, edits);
    if (mounted) Navigator.of(context).pop();
  }
}

class _DayCard extends StatelessWidget {
  final DayEntryState state;
  final PayrollSettings settings;
  final PayrollPayslip payslip;
  final bool editable;
  final VoidCallback onChanged;

  const _DayCard({
    required this.state,
    required this.settings,
    required this.payslip,
    required this.editable,
    required this.onChanged,
  });

  double get _liveTotal => calc.dailyTotal(
        state.entry,
        dayRate: payslip.dayRateSnapshot,
        bonusCodeAmounts: payslip.effectiveBonusCodeAmounts(settings),
        perSetRate: payslip.perSetRateSnapshot,
        estimateBonus: payslip.estimateBonusSnapshot,
      );

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _dayLabelFormat.format(state.date),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  'R${_liveTotal.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<DayMode>(
              segments: const [
                ButtonSegment(value: DayMode.off, label: Text('Off')),
                ButtonSegment(
                    value: DayMode.normal, label: Text('Normal day')),
                ButtonSegment(
                    value: DayMode.special, label: Text('Special code')),
              ],
              selected: {state.mode},
              onSelectionChanged: !editable
                  ? null
                  : (s) {
                      state.mode = s.first;
                      if (state.mode == DayMode.special) {
                        state.specialCode ??= settings.bonusCodes.isNotEmpty
                            ? settings.bonusCodes.first
                            : null;
                      }
                      onChanged();
                    },
            ),
            const SizedBox(height: 8),
            if (state.mode == DayMode.special) _buildSpecialFields(),
            if (state.mode == DayMode.normal) _buildNormalFields(),
            if (state.mode != DayMode.off) ...[
              const SizedBox(height: 8),
              TextField(
                controller: state.notes,
                enabled: editable,
                decoration: const InputDecoration(
                  labelText: 'Notes / issues',
                  isDense: true,
                ),
                onChanged: (_) => onChanged(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSpecialFields() {
    return DropdownButtonFormField<String>(
      initialValue: state.specialCode,
      decoration: const InputDecoration(labelText: 'Code', isDense: true),
      items: settings.bonusCodes
          .map((code) => DropdownMenuItem(
                value: code,
                child: Text(
                    '$code — ${settings.bonusCodeLabels[code] ?? code} '
                    '(${payslip.effectiveBonusCodeAmounts(settings)[code]?.toStringAsFixed(0) ?? '0'})'),
              ))
          .toList(),
      onChanged: !editable
          ? null
          : (v) {
              state.specialCode = v;
              onChanged();
            },
    );
  }

  Widget _buildNormalFields() {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        SizedBox(
          width: 100,
          child: TextField(
            controller: state.flyerSets,
            enabled: editable,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Flyer sets', isDense: true),
            onChanged: (_) => onChanged(),
          ),
        ),
        SizedBox(
          width: 100,
          child: TextField(
            controller: state.kmWalked,
            enabled: editable,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                const InputDecoration(labelText: 'Km walked', isDense: true),
            onChanged: (_) => onChanged(),
          ),
        ),
        SizedBox(
          width: 110,
          child: TextField(
            controller: state.waypointsReached,
            enabled: editable,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: 'Waypoints', isDense: true),
            onChanged: (_) => onChanged(),
          ),
        ),
        SizedBox(
          width: 100,
          child: TextField(
            controller: state.auditScore,
            enabled: editable,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: 'Audit score', isDense: true),
            onChanged: (_) => onChanged(),
          ),
        ),
        SizedBox(
          width: 160,
          child: CheckboxListTile(
            value: state.estimateReached,
            onChanged: !editable
                ? null
                : (v) {
                    state.estimateReached = v ?? false;
                    onChanged();
                  },
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Estimate reached'),
          ),
        ),
      ],
    );
  }
}
