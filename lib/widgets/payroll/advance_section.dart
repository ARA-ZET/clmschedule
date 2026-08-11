import 'package:flutter/material.dart';
import '../../utils/schedule_time.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/advance.dart';
import '../../models/advance_repayment.dart';
import '../../models/payroll_payslip.dart';
import '../../providers/payroll_provider.dart';
import '../../utils/payroll_calculator.dart' as calc;

final _currencyFormat = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
final _dateFormat = DateFormat('d MMM yyyy');
final _shortDateFormat = DateFormat('d MMM');

/// Deductions (advances/penalties): each one shown as its own card with the
/// item's details and a horizontal row of its repayment dates — matching
/// how the original spreadsheet laid each deduction out — plus this-week's
/// combined deduction controls (applied oldest-item-first) and an
/// outstanding-balance summary.
class AdvanceSection extends riverpod.ConsumerStatefulWidget {
  final String distributorId;
  final PayrollPayslip payslip;

  /// Already-fetched from the parent [PayslipDetailView]'s own streams —
  /// passed down instead of re-subscribing here, so this screen doesn't run
  /// two independent Firestore listeners for the same distributor's data.
  final List<Advance> advances;
  final List<AdvanceRepayment> repayments;

  /// False once this week is more than 2 pay-week cycles old — locks only
  /// the "deduct this week" controls tied to THIS payslip
  /// (`PayrollProvider.updateAdvanceDeduction`); recording a brand-new
  /// advance/penalty via "Add deduction" stays available regardless, since
  /// that's a distributor-level ledger entry with its own date, not an edit
  /// to this specific week.
  final bool editable;

  const AdvanceSection({
    super.key,
    required this.distributorId,
    required this.payslip,
    required this.advances,
    required this.repayments,
    required this.editable,
  });

  @override
  riverpod.ConsumerState<AdvanceSection> createState() =>
      _AdvanceSectionState();
}

class _AdvanceSectionState extends riverpod.ConsumerState<AdvanceSection> {
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

  /// Re-syncs the deduct-this-week controls when the payslip prop actually
  /// changes — e.g. the automatic "deduct when gross > R500" pass, or another
  /// admin's edit, arriving via the live stream while this section is open.
  /// Without this the controls kept their stale `initState` values, and
  /// pressing Apply would silently overwrite (and lock off, via
  /// `advanceDeductionOverridden`) the auto-applied deduction. Only reacts to
  /// genuine payslip changes (typing here doesn't rebuild with a new payslip),
  /// so it doesn't fight the admin mid-edit.
  @override
  void didUpdateWidget(AdvanceSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final p = widget.payslip;
    final old = oldWidget.payslip;
    if (p.isDeductingAdvanceThisWeek != old.isDeductingAdvanceThisWeek ||
        p.advanceDeductionAmount != old.advanceDeductionAmount ||
        p.advanceDeductionNote != old.advanceDeductionNote) {
      _isDeducting = p.isDeductingAdvanceThisWeek;
      _amountController.text =
          p.advanceDeductionAmount == 0 ? '' : p.advanceDeductionAmount.toString();
      _noteController.text = p.advanceDeductionNote;
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final amount = _isDeducting
        ? (double.tryParse(_amountController.text.trim()) ?? 0)
        : 0.0;

    // The auto-suggested amount (see the checkbox's onChanged above) is
    // already capped to keep at least R500 net, so this only ever fires
    // for a manually-typed amount beyond that cap — payment can't be
    // negative, so require an explicit confirmation rather than silently
    // applying or silently blocking it.
    if (amount > 0) {
      final projectedNet = calc.netWage(
        gross: widget.payslip.grossWage,
        advanceDeductionAmount: amount,
        extraEarningsAmount: widget.payslip.extraEarningsAmount,
        savingsWithdrawalAmount: widget.payslip.isWithdrawingSavingsThisWeek
            ? widget.payslip.savingsWithdrawalAmount
            : 0,
      );
      if (projectedNet < 0) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Deduction exceeds this week\'s wages'),
            content: Text(
              'Deducting ${_currencyFormat.format(amount)} against a gross '
              'wage of ${_currencyFormat.format(widget.payslip.grossWage)} '
              'would leave a negative net wage of '
              '${_currencyFormat.format(projectedNet)} this week. '
              'Continue anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Deduct anyway'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
    }

    setState(() => _applying = true);
    await ref.read(payrollRiverpod).updateAdvanceDeduction(
          widget.distributorId,
          isDeducting: _isDeducting,
          amount: amount,
          note: _noteController.text.trim(),
        );
    if (mounted) setState(() => _applying = false);
  }

  Future<void> _addDeduction() async {
    final result = await showDialog<
        ({
          DeductionType type,
          String label,
          double amount,
          DateTime datePaid,
          double preferredInstallmentAmount,
          String note,
        })>(
      context: context,
      builder: (_) => const _AddDeductionDialog(),
    );
    if (result == null) return;
    await ref.read(payrollRiverpod).addAdvance(
          widget.distributorId,
          type: result.type,
          label: result.label.isEmpty ? null : result.label,
          amount: result.amount,
          datePaid: result.datePaid,
          preferredInstallmentAmount: result.preferredInstallmentAmount,
          note: result.note.isEmpty ? null : result.note,
        );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.advances;
    final repayments = widget.repayments;
    final outstanding = items.where((a) => a.balance > 0.005).toList();
    final totalOutstanding =
        outstanding.fold<double>(0, (t, a) => t + a.balance);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Deductions',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            TextButton.icon(
              onPressed: _addDeduction,
              icon: const Icon(Icons.add),
              label: const Text('Add deduction'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Outstanding balance: '
            '${_currencyFormat.format(totalOutstanding)}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color:
                  totalOutstanding > 0 ? Colors.orange.shade800 : Colors.grey,
            ),
          ),
        ),
        if (items.isNotEmpty)
          Column(
            children: [
              for (final item in items)
                _DeductionItemCard(
                  item: item,
                  repayments: repayments
                      .where((r) => r.advanceId == item.id)
                      .toList()
                    ..sort((a, b) => a.date.compareTo(b.date)),
                ),
            ],
          ),
        const SizedBox(height: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _isDeducting,
          onChanged: !widget.editable
              ? null
              : (v) {
                  setState(() {
                    _isDeducting = v ?? false;
                    if (_isDeducting &&
                        _amountController.text.trim().isEmpty &&
                        outstanding.isNotEmpty) {
                      final oldest = outstanding.first;
                      final rawSuggestion =
                          oldest.preferredInstallmentAmount > 0
                              ? oldest.preferredInstallmentAmount
                              : oldest.balance;
                      // Never suggest a deduction that would leave the
                      // distributor with less than R500 net for the week
                      // — the admin can still type a larger amount
                      // manually if that's genuinely intended.
                      final wageBeforeDeduction = widget.payslip.grossWage;
                      final maxAllowed = (wageBeforeDeduction - 500) < 0
                          ? 0.0
                          : (wageBeforeDeduction - 500);
                      final suggested = rawSuggestion > maxAllowed
                          ? maxAllowed
                          : rawSuggestion;
                      _amountController.text = suggested.toStringAsFixed(2);
                    }
                  });
                },
          title: const Text('Deduct this week (oldest item first)'),
          subtitle: outstanding.isNotEmpty
              ? Text(
                  'Oldest outstanding: ${outstanding.first.displayLabel} — '
                  '${_dateFormat.format(outstanding.first.datePaid)} '
                  '(${_currencyFormat.format(outstanding.first.balance)} left, '
                  'usual instalment '
                  '${_currencyFormat.format(outstanding.first.preferredInstallmentAmount)})',
                )
              : null,
        ),
        if (_isDeducting) ...[
          TextField(
            controller: _amountController,
            enabled: widget.editable,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                const InputDecoration(labelText: 'Deduction amount (R)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteController,
            enabled: widget.editable,
            decoration: const InputDecoration(
                labelText: 'Note (e.g. "instalment 2 of 4")'),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: (_applying || !widget.editable) ? null : _apply,
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

/// One deduction item — header details plus, if it has any, a horizontal
/// row of "date over amount" cells for its repayment history, matching the
/// original spreadsheet's per-item date-row layout.
class _DeductionItemCard extends StatelessWidget {
  final Advance item;
  final List<AdvanceRepayment> repayments;

  const _DeductionItemCard({required this.item, required this.repayments});

  @override
  Widget build(BuildContext context) {
    final isPenalty = item.type == DeductionType.penalty;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(item.type.displayName,
                      style: const TextStyle(fontSize: 11)),
                  backgroundColor:
                      isPenalty ? Colors.red.shade50 : Colors.blue.shade50,
                  labelStyle: TextStyle(
                      color: isPenalty
                          ? Colors.red.shade800
                          : Colors.blue.shade800),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(item.displayLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(
                  item.isSettled
                      ? 'Settled'
                      : '${_currencyFormat.format(item.balance)} left',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: item.isSettled
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text('Date: ${_dateFormat.format(item.datePaid)}',
                    style: const TextStyle(fontSize: 12)),
                Text('Amount: ${_currencyFormat.format(item.amount)}',
                    style: const TextStyle(fontSize: 12)),
                Text(
                    'Instalment: '
                    '${_currencyFormat.format(item.preferredInstallmentAmount)}',
                    style: const TextStyle(fontSize: 12)),
                if (item.note != null && item.note!.trim().isNotEmpty)
                  Text('Note: ${item.note}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            if (repayments.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Repayments',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final r in repayments)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          children: [
                            Text(_shortDateFormat.format(r.date),
                                style: const TextStyle(fontSize: 10)),
                            Text(_currencyFormat.format(r.amount),
                                style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddDeductionDialog extends StatefulWidget {
  const _AddDeductionDialog();

  @override
  State<_AddDeductionDialog> createState() => _AddDeductionDialogState();
}

class _AddDeductionDialogState extends State<_AddDeductionDialog> {
  DeductionType _type = DeductionType.advance;
  final _labelController = TextEditingController();
  final _amountController = TextEditingController();
  final _installmentController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime _datePaid = scheduleNow();

  @override
  void dispose() {
    _labelController.dispose();
    _amountController.dispose();
    _installmentController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _datePaid,
      firstDate: DateTime(2020),
      lastDate: scheduleNow().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _datePaid = picked);
  }

  @override
  Widget build(BuildContext context) {
    final isPenalty = _type == DeductionType.penalty;
    return AlertDialog(
      title: const Text('Add deduction'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<DeductionType>(
              segments: const [
                ButtonSegment(
                    value: DeductionType.advance, label: Text('Advance')),
                ButtonSegment(
                    value: DeductionType.penalty, label: Text('Penalty')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _labelController,
              decoration: InputDecoration(
                labelText: isPenalty ? 'Reason' : 'Label (optional)',
                hintText:
                    isPenalty ? 'e.g. Lost cellphone, Damages' : 'e.g. Advance',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amountController,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount (R)'),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: InputDecoration(
                    labelText: isPenalty ? 'Date' : 'Date paid'),
                child: Text(_dateFormat.format(_datePaid)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _installmentController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Preferred instalment amount (R)',
                helperText: 'Suggested weekly deduction while outstanding',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
          ],
        ),
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
            final installment =
                double.tryParse(_installmentController.text.trim()) ?? 0;
            Navigator.of(context).pop((
              type: _type,
              label: _labelController.text.trim(),
              amount: amount,
              datePaid: _datePaid,
              preferredInstallmentAmount: installment,
              note: _noteController.text.trim(),
            ));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
