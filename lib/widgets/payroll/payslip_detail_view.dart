import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../models/advance.dart';
import '../../models/advance_repayment.dart';
import '../../models/distributor.dart';
import '../../models/payroll_payslip.dart';
import '../../models/payroll_settings.dart';
import '../../models/savings_deposit.dart';
import '../../models/savings_withdrawal.dart';
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../utils/payroll_calculator.dart' as calc;
import '../../utils/payroll_pdf.dart';
import '../../utils/payroll_week.dart';
import '../../utils/repayment_schedule.dart';
import 'advance_section.dart';
import 'daily_entry_editor.dart';
import 'savings_section.dart';

final _currencyFormat = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
final _dayFormat = DateFormat('EEE d MMM');
final _shortDateFormat = DateFormat('d MMM');
final _fullDateFormat = DateFormat('d MMMM yyyy');

/// "DR" -> "DR - Driving" when the code has a configured label, else just
/// the bare code.
String _codeWithLabel(String code, Map<String, String> bonusCodeLabels) {
  final label = bonusCodeLabels[code];
  return (label != null && label.trim().isNotEmpty) ? '$code - $label' : code;
}

/// One distributor's full weekly breakdown, shown as an on-screen preview
/// of exactly what gets printed — company letterhead, distributor details,
/// day-by-day table, totals, signature lines — with the admin-only advance
/// controls kept in a clearly separate section below (they aren't part of
/// the printed slip).
class PayslipDetailView extends riverpod.ConsumerStatefulWidget {
  final String distributorId;

  const PayslipDetailView({super.key, required this.distributorId});

  @override
  riverpod.ConsumerState<PayslipDetailView> createState() =>
      _PayslipDetailViewState();
}

class _PayslipDetailViewState extends riverpod.ConsumerState<PayslipDetailView> {
  String get distributorId => widget.distributorId;

  // Held across rebuilds: created inline in build, every payroll or schedule
  // notification handed the StreamBuilders new streams, which re-subscribed
  // all four Firestore listeners and blanked their data meanwhile. Created on
  // first use and dropped while there is no payslip, so a StreamBuilder that
  // mounts again always gets a stream nobody has listened to yet.
  Stream<List<Advance>>? _advances;
  Stream<List<AdvanceRepayment>>? _repayments;
  Stream<List<SavingsDeposit>>? _deposits;
  Stream<List<SavingsWithdrawal>>? _withdrawals;

  @override
  Widget build(BuildContext context) {
    final payroll = ref.watch(payrollRiverpod);
    final payslip = payroll.week.payslips[distributorId];
    final editable = isPayrollWeekEditable(payroll.weekStart);
    final distributors =
        ref.watch(scheduleRiverpod.select((p) => p.distributors));
    Distributor? distributor;
    for (final d in distributors) {
      if (d.id == distributorId) {
        distributor = d;
        break;
      }
    }

    if (payslip == null) {
      _advances = _repayments = _deposits = _withdrawals = null;
      return Scaffold(
        backgroundColor: Colors.grey.shade200,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Payslip'),
        ),
        body: const Center(child: Text('No payslip for this week yet.')),
      );
    }

    // A single set of live subscriptions for this distributor's
    // advances/repayments/deposits/withdrawals, shared by the body (via
    // AdvanceSection/SavingsSection props below) and the print button —
    // rather than each independently re-subscribing to the same Firestore
    // collections or the print button re-fetching them one-shot.
    return StreamBuilder<List<Advance>>(
      stream: _advances ??=
          ref.read(payrollServiceRiverpod).streamAdvances(distributorId),
      builder: (context, advSnapshot) {
        final advances = advSnapshot.data ?? const <Advance>[];
        final outstandingDeductionBalance =
            advances.fold<double>(0, (t, a) => t + a.balance);
        return StreamBuilder<List<AdvanceRepayment>>(
          stream: _repayments ??= ref
              .read(payrollServiceRiverpod)
              .streamRepayments(distributorId),
          builder: (context, repSnapshot) {
            final repayments =
                repSnapshot.data ?? const <AdvanceRepayment>[];
            return StreamBuilder<List<SavingsDeposit>>(
              stream: _deposits ??= ref
                  .read(payrollServiceRiverpod)
                  .streamSavingsDeposits(distributorId),
              builder: (context, savSnapshot) {
                final deposits =
                    savSnapshot.data ?? const <SavingsDeposit>[];
                final savingsBalanceHeld =
                    deposits.fold<double>(0, (t, d) => t + d.balance);
                return StreamBuilder<List<SavingsWithdrawal>>(
                  stream: _withdrawals ??= ref
                      .read(payrollServiceRiverpod)
                      .streamSavingsWithdrawals(distributorId),
                  builder: (context, withSnapshot) {
                    final withdrawals =
                        withSnapshot.data ?? const <SavingsWithdrawal>[];

                    return Scaffold(
                      backgroundColor: Colors.grey.shade200,
                      appBar: AppBar(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        title: Text(payslip.distributorName),
                        actions: [
                          TextButton.icon(
                            onPressed: !editable
                                ? null
                                : () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => DailyEntryEditor(
                                            distributorId: distributorId),
                                      ),
                                    );
                                  },
                            icon: Icon(Icons.edit_calendar,
                                color: editable
                                    ? Colors.white
                                    : Colors.white38),
                            label: Text('Edit days',
                                style: TextStyle(
                                    color: editable
                                        ? Colors.white
                                        : Colors.white38)),
                          ),
                          IconButton(
                            tooltip: 'Print / export PDF',
                            icon: const Icon(Icons.print,
                                color: Colors.white),
                            onPressed: () async {
                              await Printing.layoutPdf(
                                name: 'Payslip ${payslip.distributorName} '
                                    '${DateFormat('yyyy-MM-dd').format(payroll.weekStart)}',
                                onLayout: (_) => generatePayslipPdf(
                                  payslip: payslip,
                                  weekStart: payroll.weekStart,
                                  weekEnd: payroll.weekEnd,
                                  payDate: payroll.payDate,
                                  settings: payroll.settings,
                                  distributor: distributor,
                                  outstandingDeductionBalance:
                                      outstandingDeductionBalance,
                                  savingsBalanceHeld: savingsBalanceHeld,
                                  advances: advances,
                                  repayments: repayments,
                                  deposits: deposits,
                                  withdrawals: withdrawals,
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                      body: ListView(
                              padding: const EdgeInsets.all(24),
                              children: [
                                if (!editable)
                                  Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                          maxWidth: 720),
                                      child: Container(
                                        width: double.infinity,
                                        margin:
                                            const EdgeInsets.only(bottom: 16),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade200,
                                          border: Border.all(
                                              color: Colors.grey.shade400),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(Icons.lock_outline,
                                                size: 16,
                                                color: Colors.grey.shade700),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'This week is more than 2 '
                                                'weeks old and is now '
                                                'read-only.',
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color:
                                                        Colors.grey.shade700),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                Center(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 720),
                                    child: _PayslipPaper(
                                      payslip: payslip,
                                      distributor: distributor,
                                      settings: payroll.settings,
                                      weekStart: payroll.weekStart,
                                      weekEnd: payroll.weekEnd,
                                      payDate: payroll.payDate,
                                      outstandingDeductionBalance:
                                          outstandingDeductionBalance,
                                      savingsBalanceHeld: savingsBalanceHeld,
                                      advances: advances,
                                      repayments: repayments,
                                      deposits: deposits,
                                      withdrawals: withdrawals,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Center(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 720),
                                    child: Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Extra earnings',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16),
                                            ),
                                            const Text(
                                              'A simple one-off addition to this week\'s '
                                              'net pay — e.g. unpaid wages owed from a '
                                              'previous week.',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey),
                                            ),
                                            const SizedBox(height: 12),
                                            _ExtraEarningsEditor(
                                              distributorId: distributorId,
                                              payslip: payslip,
                                              editable: editable,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Center(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 720),
                                    child: Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Deductions',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16),
                                            ),
                                            const Text(
                                              'Admin-only — not shown on the printed '
                                              'payslip in detail (only the applied '
                                              'total is).',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey),
                                            ),
                                            const SizedBox(height: 12),
                                            AdvanceSection(
                                                distributorId: distributorId,
                                                payslip: payslip,
                                                advances: advances,
                                                repayments: repayments,
                                                weekStart: payroll.weekStart,
                                                editable: editable),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Center(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 720),
                                    child: Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Savings',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16),
                                            ),
                                            const Text(
                                              'Admin-only — not shown on the printed '
                                              'payslip in detail (only the applied '
                                              'total and balance are).',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey),
                                            ),
                                            const SizedBox(height: 12),
                                            SavingsSection(
                                                distributorId: distributorId,
                                                payslip: payslip,
                                                deposits: deposits,
                                                withdrawals: withdrawals,
                                                editable: editable),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Simple one-off editable addition to this week's net pay — e.g. unpaid
/// wages owed from a previous week. Unlike deductions/savings this isn't
/// tracked across weeks; it's just entered directly on this payslip.
class _ExtraEarningsEditor extends riverpod.ConsumerStatefulWidget {
  final String distributorId;
  final PayrollPayslip payslip;
  final bool editable;

  const _ExtraEarningsEditor(
      {required this.distributorId,
      required this.payslip,
      required this.editable});

  @override
  riverpod.ConsumerState<_ExtraEarningsEditor> createState() =>
      _ExtraEarningsEditorState();
}

class _ExtraEarningsEditorState
    extends riverpod.ConsumerState<_ExtraEarningsEditor> {
  late TextEditingController _amountController;
  late TextEditingController _noteController;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
        text: widget.payslip.extraEarningsAmount == 0
            ? ''
            : widget.payslip.extraEarningsAmount.toString());
    _noteController =
        TextEditingController(text: widget.payslip.extraEarningsNote);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    final amount = double.tryParse(_amountController.text.trim()) ?? 0;
    await ref.read(payrollRiverpod).updateExtraEarnings(
          widget.distributorId,
          amount: amount,
          note: _noteController.text.trim(),
        );
    if (mounted) setState(() => _applying = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _amountController,
          enabled: widget.editable,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Amount (R)'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _noteController,
          enabled: widget.editable,
          decoration: const InputDecoration(
              labelText: 'Note (e.g. "unpaid wages w/e 2 May")'),
        ),
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

/// On-screen preview styled to match [generatePayslipPdf]'s printed layout:
/// company letterhead + logo, distributor identity details, day-by-day
/// table, totals, signature lines.
class _PayslipPaper extends StatelessWidget {
  final PayrollPayslip payslip;
  final Distributor? distributor;
  final PayrollSettings settings;
  final DateTime weekStart;
  final DateTime weekEnd;
  final DateTime payDate;
  final double outstandingDeductionBalance;
  final double savingsBalanceHeld;
  final List<Advance> advances;
  final List<AdvanceRepayment> repayments;
  final List<SavingsDeposit> deposits;
  final List<SavingsWithdrawal> withdrawals;

  const _PayslipPaper({
    required this.payslip,
    required this.distributor,
    required this.settings,
    required this.weekStart,
    required this.weekEnd,
    required this.payDate,
    this.outstandingDeductionBalance = 0,
    this.savingsBalanceHeld = 0,
    this.advances = const [],
    this.repayments = const [],
    this.deposits = const [],
    this.withdrawals = const [],
  });

  @override
  Widget build(BuildContext context) {
    final mutedStyle = TextStyle(fontSize: 12, color: Colors.grey.shade700);
    final displayName = (distributor?.fullName?.trim().isNotEmpty ?? false)
        ? distributor!.fullName!.trim()
        : payslip.distributorName;
    final addressLines = settings.companyAddress
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _CompanyLogo(url: settings.companyLogoUrl),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      settings.companyName.isNotEmpty
                          ? settings.companyName
                          : 'Company name',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    for (final line in addressLines)
                      Text(line, style: mutedStyle),
                    if (settings.companyPhone.isNotEmpty)
                      Text('Tel: ${settings.companyPhone}', style: mutedStyle),
                    if (settings.companyEmail.isNotEmpty)
                      Text('Email: ${settings.companyEmail}',
                          style: mutedStyle),
                    if (settings.companyVatNo.isNotEmpty ||
                        settings.companyRegistrationNo.isNotEmpty)
                      Text(
                        [
                          if (settings.companyVatNo.isNotEmpty)
                            'VAT No: ${settings.companyVatNo}',
                          if (settings.companyRegistrationNo.isNotEmpty)
                            'Reg No: ${settings.companyRegistrationNo}',
                        ].join('   '),
                        style: mutedStyle,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'WAGE SLIP',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
          const SizedBox(height: 12),
          _KvRow('Name', displayName),
          if (distributor?.idNumber?.trim().isNotEmpty ?? false)
            _KvRow('ID number', distributor!.idNumber!.trim()),
          if (distributor?.homeAddress?.trim().isNotEmpty ?? false)
            _KvRow('Home address', distributor!.homeAddress!.trim()),
          _KvRow(
            'Pay period',
            '${_dayFormat.format(weekStart)} – ${_dayFormat.format(weekEnd)}',
          ),
          _KvRow('Payment day', _fullDateFormat.format(payDate)),
          const SizedBox(height: 16),
          _PrintStyleTable(
              payslip: payslip, bonusCodeLabels: settings.bonusCodeLabels),
          const SizedBox(height: 16),
          _SummaryRow(label: 'Total gross wage', value: payslip.grossWage),
          _buildDeductionsTable(),
          _buildSavingsTable(),
          if (payslip.extraEarningsAmount != 0) ...[
            const SizedBox(height: 12),
            _ExtraEarningsBlock(payslip: payslip),
          ],
          const SizedBox(height: 12),
          const Divider(),
          _SummaryRow(
            label: 'Total net wage',
            value: payslip.netWage,
            emphasize: true,
          ),
          if (outstandingDeductionBalance > 0.005 ||
              savingsBalanceHeld > 0.005) ...[
            const SizedBox(height: 8),
            if (outstandingDeductionBalance > 0.005)
              Text(
                'Outstanding deduction balance: '
                '${_currencyFormat.format(outstandingDeductionBalance)}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
            if (savingsBalanceHeld > 0.005)
              Text(
                'Savings balance held: '
                '${_currencyFormat.format(savingsBalanceHeld)}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
          ],
          const SizedBox(height: 48),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              _SignatureLine('Employee signature'),
              _SignatureLine('Company signature'),
            ],
          ),
        ],
      ),
    );
  }

  /// Every advance/penalty that [belongsOnPayslip] for this week as a single
  /// wide summary table — one row per item, spanning the full paper width,
  /// so several deductions never blow the payslip out to extra printed pages
  /// — followed by each item's instalment strip (see [_ScheduleHistory]) for
  /// the when-and-how-much detail the summary row can't carry.
  Widget _buildDeductionsTable() {
    final weekId = weekIdFor(weekStart);
    final relevant = advances
        .where((a) => belongsOnPayslip(
              originDate: a.datePaid,
              totalAmount: a.amount,
              weekEnd: weekEnd,
              weekId: weekId,
              payments: [
                for (final r in repayments)
                  if (r.advanceId == a.id)
                    (linkedWeekId: r.linkedWeekId, amount: r.amount),
              ],
            ))
        .toList()
      ..sort((a, b) => a.datePaid.compareTo(b.datePaid));
    if (relevant.isEmpty) return const SizedBox.shrink();

    final counters = <DeductionType, int>{};
    final rows = <List<String>>[];
    final histories = <({String title, List<ScheduleEntry> schedule})>[];
    for (final item in relevant) {
      final count = (counters[item.type] ?? 0) + 1;
      counters[item.type] = count;
      final itemPayments = repayments
          .where((r) =>
              r.advanceId == item.id &&
              isOnOrBeforeWeek(r.linkedWeekId, weekId))
          .map((r) => (date: r.date, amount: r.amount))
          .toList();
      final schedule = buildRepaymentSchedule(
        totalAmount: item.amount,
        instalmentAmount: item.preferredInstallmentAmount,
        originDate: item.datePaid,
        actualPayments: itemPayments,
      );
      final thisWeekAmount = repayments
          .where((r) => r.advanceId == item.id && r.linkedWeekId == weekId)
          .fold<double>(0, (t, r) => t + r.amount);
      final title = (item.label != null && item.label!.trim().isNotEmpty)
          ? item.label!.trim()
          : '${item.type.displayName} $count';

      rows.add([
        title,
        _shortDateFormat.format(item.datePaid),
        _currencyFormat.format(item.amount),
        schedule.isEmpty ? '—' : '${schedule.length}',
        item.preferredInstallmentAmount > 0
            ? _currencyFormat.format(item.preferredInstallmentAmount)
            : '—',
        (item.note != null && item.note!.trim().isNotEmpty)
            ? item.note!.trim()
            : '—',
        schedule.isEmpty ? '—' : _shortDateFormat.format(schedule.last.date),
        _currencyFormat.format(thisWeekAmount),
      ]);
      if (schedule.isNotEmpty) {
        histories.add((
          title: '$title  ·  ${_shortDateFormat.format(item.datePaid)}  ·  '
              '${_currencyFormat.format(item.amount)}',
          schedule: schedule,
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ItemsTable(
            columnHeaders: const [
              'Description',
              'Date paid',
              'Amount',
              'Instalments',
              'Instalment amt',
              'Notes',
              'Last instalment',
              "This week's deduction",
            ],
            columnWidths: const {
              0: FlexColumnWidth(2.2),
              1: FlexColumnWidth(1.2),
              2: FlexColumnWidth(1.1),
              3: FlexColumnWidth(0.9),
              4: FlexColumnWidth(1.2),
              5: FlexColumnWidth(1.6),
              6: FlexColumnWidth(1.2),
              7: FlexColumnWidth(1.4),
            },
            rows: rows,
          ),
          _ScheduleHistory(
              heading: 'Deduction history', histories: histories),
        ],
      ),
    );
  }

  /// Mirrors [_buildDeductionsTable] for savings deposits/withdrawals.
  Widget _buildSavingsTable() {
    final weekId = weekIdFor(weekStart);
    final relevant = deposits
        .where((d) => belongsOnPayslip(
              originDate: d.dateDeposited,
              totalAmount: d.amount,
              weekEnd: weekEnd,
              weekId: weekId,
              payments: [
                for (final w in withdrawals)
                  if (w.depositId == d.id)
                    (linkedWeekId: w.linkedWeekId, amount: w.amount),
              ],
            ))
        .toList()
      ..sort((a, b) => a.dateDeposited.compareTo(b.dateDeposited));
    if (relevant.isEmpty) return const SizedBox.shrink();

    var count = 0;
    final rows = <List<String>>[];
    final histories = <({String title, List<ScheduleEntry> schedule})>[];
    for (final item in relevant) {
      count++;
      final itemWithdrawals = withdrawals
          .where((w) =>
              w.depositId == item.id &&
              isOnOrBeforeWeek(w.linkedWeekId, weekId))
          .map((w) => (date: w.date, amount: w.amount))
          .toList();
      final schedule = buildRepaymentSchedule(
        totalAmount: item.amount,
        instalmentAmount: item.preferredWithdrawalAmount,
        originDate: item.dateDeposited,
        actualPayments: itemWithdrawals,
      );
      final thisWeekAmount = withdrawals
          .where((w) => w.depositId == item.id && w.linkedWeekId == weekId)
          .fold<double>(0, (t, w) => t + w.amount);
      final title = (item.note != null && item.note!.trim().isNotEmpty)
          ? item.note!.trim()
          : 'Savings $count';

      rows.add([
        title,
        _shortDateFormat.format(item.dateDeposited),
        _currencyFormat.format(item.amount),
        schedule.isEmpty ? '—' : '${schedule.length}',
        item.preferredWithdrawalAmount > 0
            ? _currencyFormat.format(item.preferredWithdrawalAmount)
            : '—',
        schedule.isEmpty ? '—' : _shortDateFormat.format(schedule.last.date),
        _currencyFormat.format(thisWeekAmount),
      ]);
      if (schedule.isNotEmpty) {
        histories.add((
          title: '$title  ·  ${_shortDateFormat.format(item.dateDeposited)}'
              '  ·  ${_currencyFormat.format(item.amount)}',
          schedule: schedule,
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ItemsTable(
            columnHeaders: const [
              'Description',
              'Date deposited',
              'Amount',
              'Instalments',
              'Instalment amt',
              'Last instalment',
              "This week's withdrawal",
            ],
            columnWidths: const {
              0: FlexColumnWidth(2.2),
              1: FlexColumnWidth(1.3),
              2: FlexColumnWidth(1.1),
              3: FlexColumnWidth(0.9),
              4: FlexColumnWidth(1.3),
              5: FlexColumnWidth(1.3),
              6: FlexColumnWidth(1.5),
            },
            rows: rows,
          ),
          _ScheduleHistory(
              heading: 'Withdrawal history', histories: histories),
        ],
      ),
    );
  }
}

/// Each item's instalment schedule as a horizontal strip of small
/// date/amount boxes — the same layout the admin Deductions card uses, and
/// the one the original wage-slip spreadsheet used, so a distributor holding
/// a printed slip can see exactly WHEN each deduction came off and HOW MUCH.
/// The summary table above answers "how many instalments"; this answers
/// "which ones, and when".
///
/// Instalments already paid are shaded and dated in black; ones still
/// projected ahead at the item's instalment amount are outlined and greyed,
/// so nobody mistakes a forecast for money already taken.
class _ScheduleHistory extends StatelessWidget {
  final String heading;
  final List<({String title, List<ScheduleEntry> schedule})> histories;

  const _ScheduleHistory({required this.heading, required this.histories});

  @override
  Widget build(BuildContext context) {
    if (histories.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$heading  (shaded = already deducted, grey = still to come)',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade700)),
          for (final h in histories) ...[
            const SizedBox(height: 6),
            Text(h.title,
                style:
                    const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
            const SizedBox(height: 3),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final e in h.schedule)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: e.isActual ? Colors.grey.shade200 : null,
                      border: Border.all(
                          color: Colors.grey.shade400, width: 0.5),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          _shortDateFormat.format(e.date),
                          style: TextStyle(
                            fontSize: 8,
                            color: e.isActual
                                ? Colors.grey.shade800
                                : Colors.grey.shade500,
                          ),
                        ),
                        Text(
                          _currencyFormat.format(e.amount),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: e.isActual
                                ? Colors.black
                                : Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A wide, dense table — small bold text throughout for readability at a
/// compact size — spanning the full paper width so several deduction or
/// savings items never need more than one row each.
class _ItemsTable extends StatelessWidget {
  final List<String> columnHeaders;
  final Map<int, TableColumnWidth> columnWidths;
  final List<List<String>> rows;

  const _ItemsTable({
    required this.columnHeaders,
    required this.columnWidths,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    const headerStyle = TextStyle(
        fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white);
    const cellStyle = TextStyle(fontSize: 9, fontWeight: FontWeight.bold);

    return Table(
      border: TableBorder.all(color: Colors.grey.shade400, width: 0.5),
      columnWidths: columnWidths,
      children: [
        TableRow(
          decoration: BoxDecoration(color: Colors.grey.shade800),
          children: [
            for (final header in columnHeaders)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(header, style: headerStyle),
              ),
          ],
        ),
        for (final row in rows)
          TableRow(
            children: [
              for (final cell in row)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text(cell, style: cellStyle),
                ),
            ],
          ),
      ],
    );
  }
}

class _ExtraEarningsBlock extends StatelessWidget {
  final PayrollPayslip payslip;

  const _ExtraEarningsBlock({required this.payslip});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Extra earnings',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 4),
        if (payslip.extraEarningsNote.isNotEmpty)
          _KvRow('Description', payslip.extraEarningsNote),
        _KvRow('Amount', _currencyFormat.format(payslip.extraEarningsAmount)),
      ],
    );
  }
}

class _CompanyLogo extends StatelessWidget {
  final String? url;

  const _CompanyLogo({required this.url});

  static const double _height = 110;

  @override
  Widget build(BuildContext context) {
    Widget image;
    if (url != null && url!.isNotEmpty) {
      image = Image.network(
        url!,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorBuilder: (_, __, ___) => Image.asset(
          'assets/logo.png',
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      );
    } else {
      image = Image.asset(
        'assets/logo.png',
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return SizedBox(height: _height, width: double.infinity, child: image);
  }
}

class _KvRow extends StatelessWidget {
  final String label;
  final String value;

  const _KvRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// Day-by-day breakdown styled to mirror the printed table: a dark header
/// row with white text and bordered cells.
class _PrintStyleTable extends StatelessWidget {
  final PayrollPayslip payslip;
  final Map<String, String> bonusCodeLabels;

  const _PrintStyleTable({
    required this.payslip,
    required this.bonusCodeLabels,
  });

  @override
  Widget build(BuildContext context) {
    final dates = payslip.dailyEntries.keys.toList()..sort();
    final border = TableBorder.all(color: Colors.grey.shade400, width: 0.5);
    const headerStyle = TextStyle(
        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12);
    const cellStyle = TextStyle(fontSize: 12);

    return Table(
      border: border,
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(2),
        2: FlexColumnWidth(1.5),
        3: FlexColumnWidth(1.5),
        4: FlexColumnWidth(1.5),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(color: Colors.grey.shade800),
          children: const [
            _TableCell('Date', style: headerStyle),
            _TableCell('Day', style: headerStyle),
            _TableCell('Basic', style: headerStyle),
            _TableCell('Bonus', style: headerStyle),
            _TableCell('Total', style: headerStyle),
          ],
        ),
        for (final key in dates) _rowFor(key, cellStyle),
      ],
    );
  }

  TableRow _rowFor(String key, TextStyle style) {
    final entry = payslip.dailyEntries[key]!;
    final basic = calc.dailyBasic(entry, dayRate: payslip.dayRateSnapshot);
    final bonus = calc.dailyBonus(
      entry,
      bonusCodeAmounts: payslip.bonusCodeAmountsSnapshot,
      perSetRate: payslip.perSetRateSnapshot,
      estimateBonus: payslip.estimateBonusSnapshot,
    );
    final dayLabel = !entry.worked
        ? 'Off'
        : (entry.specialCode != null && entry.specialCode!.isNotEmpty)
            ? _codeWithLabel(entry.specialCode!, bonusCodeLabels)
            : '${entry.flyerSets ?? 0} sets';
    return TableRow(children: [
      _TableCell(_dayFormat.format(entry.date), style: style),
      _TableCell(dayLabel, style: style),
      _TableCell(_currencyFormat.format(basic), style: style),
      _TableCell(_currencyFormat.format(bonus), style: style),
      _TableCell(_currencyFormat.format(basic + bonus), style: style),
    ]);
  }
}

class _TableCell extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _TableCell(this.text, {required this.style});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(text, style: style),
      );
}

class _SignatureLine extends StatelessWidget {
  final String label;

  const _SignatureLine(this.label);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 160,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade500)),
          ),
          padding: const EdgeInsets.only(top: 4),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        ),
      ],
    );
  }
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
        ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)
        : const TextStyle(fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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
