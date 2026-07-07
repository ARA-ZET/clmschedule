import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../models/advance_ledger.dart';
import '../../models/payroll_payslip.dart';
import '../../providers/payroll_provider.dart';
import '../../utils/payroll_calculator.dart' as calc;
import '../../utils/payroll_pdf.dart';
import 'daily_entry_editor.dart';

final _currencyFormat = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
final _dayLabelFormat = DateFormat('EEE d MMM');

/// One distributor's full weekly breakdown: daily entries, transport,
/// advance-deduction controls, and print/PDF export.
class PayslipDetailView extends riverpod.ConsumerWidget {
  final String distributorId;

  const PayslipDetailView({super.key, required this.distributorId});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final payroll = ref.watch(payrollRiverpod);
    final payslip = payroll.week.payslips[distributorId];

    return Scaffold(
      appBar: AppBar(
        title: Text(payslip?.distributorName ?? 'Payslip'),
        actions: [
          if (payslip != null)
            IconButton(
              tooltip: 'Print / export PDF',
              icon: const Icon(Icons.print, color: Colors.white),
              onPressed: () => Printing.layoutPdf(
                name: 'Payslip ${payslip.distributorName} '
                    '${DateFormat('yyyy-MM-dd').format(payroll.weekStart)}',
                onLayout: (_) => generatePayslipPdf(
                  payslip: payslip,
                  weekStart: payroll.weekStart,
                  weekEnd: payroll.weekEnd,
                  payDate: payroll.payDate,
                ),
              ),
            ),
          if (payslip != null)
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        DailyEntryEditor(distributorId: distributorId),
                  ),
                );
              },
              icon: const Icon(Icons.edit_calendar, color: Colors.white),
              label:
                  const Text('Edit days', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: payslip == null
          ? const Center(child: Text('No payslip for this week yet.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '${_dayLabelFormat.format(payroll.weekStart)} – '
                  '${_dayLabelFormat.format(payroll.weekEnd)}   '
                  '(pay day ${DateFormat('d MMM yyyy').format(payroll.payDate)})',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 12),
                _DailyBreakdownTable(payslip: payslip),
                const Divider(height: 32),
                _SummaryRow(label: 'Gross wage', value: payslip.grossWage),
                if (payslip.transportEligibleSnapshot)
                  _SummaryRow(
                    label:
                        'Transport (${payslip.transportTrips} trips × '
                        '${_currencyFormat.format(payslip.transportFareSnapshot)})',
                    value: -payslip.transportDeduction,
                  ),
                _SummaryRow(
                  label: payslip.isDeductingAdvanceThisWeek
                      ? 'Advance deduction'
                      : 'Advance deduction (not applied this week)',
                  value: -payslip.advanceDeductionAmount,
                ),
                const Divider(),
                _SummaryRow(
                  label: 'Net wage',
                  value: payslip.netWage,
                  emphasize: true,
                ),
                const Divider(height: 32),
                _AdvanceSection(distributorId: distributorId, payslip: payslip),
              ],
            ),
    );
  }
}

/// Advance ledger balance + this-week deduction controls. The user
/// explicitly decides, per week, whether a deduction applies and how
/// much/why — no automatic date-matching (unlike the old sheet).
class _AdvanceSection extends riverpod.ConsumerStatefulWidget {
  final String distributorId;
  final PayrollPayslip payslip;

  const _AdvanceSection({required this.distributorId, required this.payslip});

  @override
  riverpod.ConsumerState<_AdvanceSection> createState() =>
      _AdvanceSectionState();
}

class _AdvanceSectionState extends riverpod.ConsumerState<_AdvanceSection> {
  late bool _isDeducting;
  late TextEditingController _amountController;
  late TextEditingController _noteController;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _isDeducting = widget.payslip.isDeductingAdvanceThisWeek;
    _amountController = TextEditingController(
        text: widget.payslip.advanceDeductionAmount == 0
            ? ''
            : widget.payslip.advanceDeductionAmount.toString());
    _noteController =
        TextEditingController(text: widget.payslip.advanceDeductionNote);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    final amount =
        _isDeducting ? (double.tryParse(_amountController.text.trim()) ?? 0) : 0.0;
    await ref.read(payrollRiverpod).updateAdvanceDeduction(
          widget.distributorId,
          isDeducting: _isDeducting,
          amount: amount,
          note: _noteController.text.trim(),
        );
    if (mounted) setState(() => _applying = false);
  }

  Future<void> _addAdvance() async {
    final result = await showDialog<({double amount, String note})>(
      context: context,
      builder: (_) => const _AddAdvanceDialog(),
    );
    if (result == null) return;
    await ref
        .read(payrollServiceRiverpod)
        .recordAdvanceGrant(widget.distributorId, result.amount,
            note: result.note.isEmpty ? null : result.note);
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.read(payrollServiceRiverpod);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Advance',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            TextButton.icon(
              onPressed: _addAdvance,
              icon: const Icon(Icons.add),
              label: const Text('Add advance'),
            ),
          ],
        ),
        StreamBuilder<AdvanceLedger>(
          stream: service.streamLedger(widget.distributorId),
          builder: (context, snapshot) {
            final balance = snapshot.data?.balance ?? 0;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Outstanding balance: ${_currencyFormat.format(balance)}',
                style: TextStyle(
                  color: balance > 0 ? Colors.orange.shade800 : Colors.grey,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _isDeducting,
          onChanged: (v) => setState(() => _isDeducting = v ?? false),
          title: const Text('Deduct an advance instalment this week'),
        ),
        if (_isDeducting) ...[
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                const InputDecoration(labelText: 'Deduction amount (R)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(
                labelText: 'Note (e.g. "instalment 2 of 4")'),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _applying ? null : _apply,
            child: _applying
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Apply'),
          ),
        ),
      ],
    );
  }
}

class _AddAdvanceDialog extends StatefulWidget {
  const _AddAdvanceDialog();

  @override
  State<_AddAdvanceDialog> createState() => _AddAdvanceDialogState();
}

class _AddAdvanceDialogState extends State<_AddAdvanceDialog> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add advance'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _amountController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount (R)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final amount = double.tryParse(_amountController.text.trim()) ?? 0;
            if (amount <= 0) return;
            Navigator.of(context)
                .pop((amount: amount, note: _noteController.text.trim()));
          },
          child: const Text('Grant'),
        ),
      ],
    );
  }
}

class _DailyBreakdownTable extends StatelessWidget {
  final PayrollPayslip payslip;

  const _DailyBreakdownTable({required this.payslip});

  @override
  Widget build(BuildContext context) {
    final dates = payslip.dailyEntries.keys.toList()..sort();
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(2),
        2: FlexColumnWidth(2),
        3: FlexColumnWidth(2),
      },
      children: [
        const TableRow(children: [
          _HeaderCell('Date'),
          _HeaderCell('Day'),
          _HeaderCell('Basic'),
          _HeaderCell('Bonus'),
          _HeaderCell('Total'),
        ]),
        for (final key in dates) _rowFor(key),
      ],
    );
  }

  TableRow _rowFor(String key) {
    final entry = payslip.dailyEntries[key]!;
    final basic =
        calc.dailyBasic(entry, dayRate: payslip.dayRateSnapshot);
    final bonus = calc.dailyBonus(
      entry,
      bonusCodeAmounts: payslip.bonusCodeAmountsSnapshot,
      perSetRate: payslip.perSetRateSnapshot,
      estimateBonus: payslip.estimateBonusSnapshot,
    );
    final dayLabel = !entry.worked
        ? 'Off'
        : (entry.specialCode ?? '${entry.flyerSets ?? 0} sets');
    return TableRow(children: [
      _Cell(_dayLabelFormat.format(entry.date)),
      _Cell(dayLabel),
      _Cell(_currencyFormat.format(basic)),
      _Cell(_currencyFormat.format(bonus)),
      _Cell(_currencyFormat.format(basic + bonus)),
    ]);
  }
}

class _HeaderCell extends StatelessWidget {
  final String text;
  const _HeaderCell(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
      );
}

class _Cell extends StatelessWidget {
  final String text;
  const _Cell(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text),
      );
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final double value;
  final bool emphasize;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = emphasize
        ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: style)),
          Text(_currencyFormat.format(value), style: style),
        ],
      ),
    );
  }
}
