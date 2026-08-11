import 'package:flutter/material.dart';
import '../../utils/schedule_time.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/payroll_payslip.dart';
import '../../models/savings_deposit.dart';
import '../../models/savings_withdrawal.dart';
import '../../providers/payroll_provider.dart';

final _currencyFormat = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
final _dateFormat = DateFormat('d MMM yyyy');
final _shortDateFormat = DateFormat('d MMM');

/// Distributor savings held by the company: each deposit shown as its own
/// card with a horizontal row of its withdrawal dates (mirrors
/// [AdvanceSection]'s layout), plus this-week's combined withdrawal
/// controls (paid out oldest-deposit-first) and a held-balance summary.
class SavingsSection extends riverpod.ConsumerStatefulWidget {
  final String distributorId;
  final PayrollPayslip payslip;

  /// Already-fetched from the parent [PayslipDetailView]'s own streams —
  /// passed down instead of re-subscribing here, so this screen doesn't run
  /// two independent Firestore listeners for the same distributor's data.
  final List<SavingsDeposit> deposits;
  final List<SavingsWithdrawal> withdrawals;

  /// False once this week is more than 2 pay-week cycles old — locks only
  /// the "pay out this week" controls tied to THIS payslip
  /// (`PayrollProvider.updateSavingsWithdrawal`); recording a brand-new
  /// deposit via "Add deposit" stays available regardless, since that's a
  /// distributor-level ledger entry with its own date, not an edit to this
  /// specific week.
  final bool editable;

  const SavingsSection({
    super.key,
    required this.distributorId,
    required this.payslip,
    required this.deposits,
    required this.withdrawals,
    required this.editable,
  });

  @override
  riverpod.ConsumerState<SavingsSection> createState() =>
      _SavingsSectionState();
}

class _SavingsSectionState extends riverpod.ConsumerState<SavingsSection> {
  late bool _isWithdrawing;
  late TextEditingController _amountController;
  late TextEditingController _noteController;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _isWithdrawing = widget.payslip.isWithdrawingSavingsThisWeek;
    _amountController = TextEditingController(
        text: widget.payslip.savingsWithdrawalAmount == 0
            ? ''
            : widget.payslip.savingsWithdrawalAmount.toString());
    _noteController =
        TextEditingController(text: widget.payslip.savingsWithdrawalNote);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    final amount = _isWithdrawing
        ? (double.tryParse(_amountController.text.trim()) ?? 0)
        : 0.0;
    await ref.read(payrollRiverpod).updateSavingsWithdrawal(
          widget.distributorId,
          isWithdrawing: _isWithdrawing,
          amount: amount,
          note: _noteController.text.trim(),
        );
    if (mounted) setState(() => _applying = false);
  }

  Future<void> _addDeposit() async {
    final result = await showDialog<
        ({
          double amount,
          DateTime dateDeposited,
          double preferredWithdrawalAmount,
          String note,
        })>(
      context: context,
      builder: (_) => const _AddSavingsDepositDialog(),
    );
    if (result == null) return;
    await ref.read(payrollRiverpod).addSavingsDeposit(
          widget.distributorId,
          amount: result.amount,
          dateDeposited: result.dateDeposited,
          preferredWithdrawalAmount: result.preferredWithdrawalAmount,
          note: result.note.isEmpty ? null : result.note,
        );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.deposits;
    final withdrawals = widget.withdrawals;
    final outstanding = items.where((d) => d.balance > 0.005).toList();
    final totalHeld = outstanding.fold<double>(0, (t, d) => t + d.balance);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Savings',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            TextButton.icon(
              onPressed: _addDeposit,
              icon: const Icon(Icons.add),
              label: const Text('Add deposit'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Savings balance held: ${_currencyFormat.format(totalHeld)}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: totalHeld > 0 ? Colors.green.shade800 : Colors.grey,
            ),
          ),
        ),
        if (items.isNotEmpty)
          Column(
            children: [
              for (final item in items)
                _SavingsDepositCard(
                  item: item,
                  withdrawals: withdrawals
                      .where((w) => w.depositId == item.id)
                      .toList()
                    ..sort((a, b) => a.date.compareTo(b.date)),
                ),
            ],
          ),
        const SizedBox(height: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _isWithdrawing,
          onChanged: !widget.editable
              ? null
              : (v) {
                  setState(() {
                    _isWithdrawing = v ?? false;
                    if (_isWithdrawing &&
                        _amountController.text.trim().isEmpty &&
                        outstanding.isNotEmpty) {
                      final oldest = outstanding.first;
                      final suggested = oldest.preferredWithdrawalAmount > 0
                          ? oldest.preferredWithdrawalAmount
                          : oldest.balance;
                      _amountController.text = suggested.toStringAsFixed(2);
                    }
                  });
                },
          title:
              const Text('Pay out savings this week (oldest deposit first)'),
          subtitle: outstanding.isNotEmpty
              ? Text(
                  'Oldest deposit: '
                  '${_dateFormat.format(outstanding.first.dateDeposited)} '
                  '(${_currencyFormat.format(outstanding.first.balance)} held, '
                  'usual withdrawal '
                  '${_currencyFormat.format(outstanding.first.preferredWithdrawalAmount)})',
                )
              : null,
        ),
        if (_isWithdrawing) ...[
          TextField(
            controller: _amountController,
            enabled: widget.editable,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                const InputDecoration(labelText: 'Withdrawal amount (R)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteController,
            enabled: widget.editable,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
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

/// One savings deposit — header details plus, if it has any, a horizontal
/// row of "date over amount" cells for its withdrawal history.
class _SavingsDepositCard extends StatelessWidget {
  final SavingsDeposit item;
  final List<SavingsWithdrawal> withdrawals;

  const _SavingsDepositCard({required this.item, required this.withdrawals});

  @override
  Widget build(BuildContext context) {
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
                  label: const Text('Savings', style: TextStyle(fontSize: 11)),
                  backgroundColor: Colors.green.shade50,
                  labelStyle: TextStyle(color: Colors.green.shade800),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.note != null && item.note!.trim().isNotEmpty
                        ? item.note!.trim()
                        : 'Deposit',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  item.isSettled
                      ? 'Fully withdrawn'
                      : '${_currencyFormat.format(item.balance)} held',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: item.isSettled
                        ? Colors.grey.shade600
                        : Colors.green.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text('Date deposited: ${_dateFormat.format(item.dateDeposited)}',
                    style: const TextStyle(fontSize: 12)),
                Text('Amount: ${_currencyFormat.format(item.amount)}',
                    style: const TextStyle(fontSize: 12)),
                Text(
                    'Usual withdrawal: '
                    '${_currencyFormat.format(item.preferredWithdrawalAmount)}',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
            if (withdrawals.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Withdrawals',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final w in withdrawals)
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
                            Text(_shortDateFormat.format(w.date),
                                style: const TextStyle(fontSize: 10)),
                            Text(_currencyFormat.format(w.amount),
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

class _AddSavingsDepositDialog extends StatefulWidget {
  const _AddSavingsDepositDialog();

  @override
  State<_AddSavingsDepositDialog> createState() =>
      _AddSavingsDepositDialogState();
}

class _AddSavingsDepositDialogState extends State<_AddSavingsDepositDialog> {
  final _amountController = TextEditingController();
  final _withdrawalController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime _dateDeposited = scheduleNow();

  @override
  void dispose() {
    _amountController.dispose();
    _withdrawalController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateDeposited,
      firstDate: DateTime(2020),
      lastDate: scheduleNow().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _dateDeposited = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add savings deposit'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _amountController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount (R)'),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Date deposited'),
                child: Text(_dateFormat.format(_dateDeposited)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _withdrawalController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Preferred withdrawal amount (R)',
                helperText: 'Suggested weekly payout once withdrawing starts',
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
            final withdrawal =
                double.tryParse(_withdrawalController.text.trim()) ?? 0;
            Navigator.of(context).pop((
              amount: amount,
              dateDeposited: _dateDeposited,
              preferredWithdrawalAmount: withdrawal,
              note: _noteController.text.trim(),
            ));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
