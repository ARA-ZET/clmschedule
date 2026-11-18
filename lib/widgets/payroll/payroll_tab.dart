import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../models/distributor.dart';
import '../../models/payment_summary.dart';
import '../../models/payroll_payslip.dart';
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../utils/payroll_pdf.dart';
import '../../utils/payroll_week.dart';
import 'banking_view.dart';
import 'ops_stats_view.dart';
import 'payroll_settings_dialog.dart';
import 'payslip_access_page.dart';
import 'payslip_detail_view.dart';
import '../../undo/undo_history.dart';
import '../../undo/undo_redo_buttons.dart';
import '../../undo/undo_shortcuts.dart';

final _currencyFormat = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
final _weekDayFormat = DateFormat('d MMM');
final _dayChipFormat = DateFormat('EEE d');

enum _PayrollView { opsStats, payslips, banking }

/// Main Payroll screen.
///
/// Layout:
///   - This tab's own top bar: week navigation (prev/next/pick/"This week")
///     + Payroll settings — separate from the shared dashboard app bar/tab
///     strip above it, which is common to every tab.
///   - A 3-way toggle between bodies for the selected week:
///     - Ops Stats: bulk daily-stats entry + week-at-a-glance overview
///       (the old sheet's "Ops Stats" tab equivalent) — the default view,
///       since that's the day-to-day data-entry workflow.
///     - Payslips: one row per distributor with gross/advance/net;
///       tapping a row opens that distributor's computed payslip.
///     - Banking: who gets paid how (eWallet/bank account), the relevant
///       phone/account number, notes, and a paid/processing/not-paid status
///       per distributor, plus eWallet vs bank-account subtotals (the old
///       sheet's "banking" tab equivalent).
///
/// All views only show active distributors, or non-active distributors
/// who have schedule work allocated somewhere in the selected week — see
/// `ScheduleProvider.distributorsWithJobsInRange`.
class PayrollTab extends riverpod.ConsumerStatefulWidget {
  const PayrollTab({super.key});

  @override
  riverpod.ConsumerState<PayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends riverpod.ConsumerState<PayrollTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  _PayrollView _view = _PayrollView.opsStats;
  final _opsStatsController = OpsStatsController();

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final payroll = ref.watch(payrollRiverpod);
    final schedule = ref.watch(scheduleRiverpod);

    final distributors = schedule.distributorsWithJobsInRange(
        payroll.weekStart, payroll.weekEnd)
      ..sort((a, b) => a.index.compareTo(b.index));

    return Column(
      children: [
        _TopBar(
          weekStart: payroll.weekStart,
          weekEnd: payroll.weekEnd,
          payDate: payroll.payDate,
          onWeekChanged: payroll.goToWeek,
          onPreviousWeek: payroll.previousWeek,
          onNextWeek: payroll.nextWeek,
          onThisWeek: payroll.goToThisWeek,
          onOpenSettings: () => showDialog(
            context: context,
            builder: (_) => const PayrollSettingsDialog(),
          ),
          onPrintBanking: () {
            final lines = payroll.week.payslips.values
                .map((p) => PaymentSummaryLine(
                      distributorId: p.distributorId,
                      distributorName: p.distributorName,
                      netWage: p.netWage,
                      paymentMethod:
                          p.paymentAccountSnapshot?.method ?? 'eWallet',
                      accountSummary: p.paymentAccountSnapshot?.summary ?? '',
                    ))
                .toList()
              ..sort((a, b) => a.distributorName.compareTo(b.distributorName));
            final summary = PaymentSummary(
              weekStart: payroll.weekStart,
              payDate: payroll.payDate,
              lines: lines,
              totalNet: lines.fold<double>(0, (t, l) => t + l.netWage),
            );
            Printing.layoutPdf(
              name:
                  'Banking ${DateFormat('yyyy-MM-dd').format(payroll.weekStart)}',
              onLayout: (_) => generatePaymentSummaryPdf(summary,
                  settings: payroll.settings),
            );
          },
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          opsStatsController: _opsStatsController,
          undoKey: payroll.undoKey,
        ),
        if (payroll.isLoading)
          const LinearProgressIndicator(minHeight: 2)
        else
          const SizedBox(height: 2),
        Expanded(
          child: UndoShortcuts(
            undoKey: payroll.undoKey,
            child: switch (_view) {
              _PayrollView.opsStats =>
                OpsStatsView(controller: _opsStatsController),
              _PayrollView.payslips =>
                _PayslipsGrid(distributors: distributors, payroll: payroll),
              _PayrollView.banking => const BankingView(),
            },
          ),
        ),
      ],
    );
  }
}

class _PayslipsGrid extends StatelessWidget {
  final List<Distributor> distributors;
  final PayrollProvider payroll;

  const _PayslipsGrid({required this.distributors, required this.payroll});

  @override
  Widget build(BuildContext context) {
    if (distributors.isEmpty) {
      return const Center(child: Text('No distributors found.'));
    }
    return Column(
      children: [
        const _PayslipsLegend(),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    return ListView.separated(
      itemCount: distributors.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final distributor = distributors[index];
        final payslip = payroll.week.payslips[distributor.id];
        return _DistributorPayrollRow(
          distributor: distributor,
          payslip: payslip,
          outstanding: payroll.outstandingBalanceFor(distributor.id),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    PayslipDetailView(distributorId: distributor.id),
              ),
            );
          },
        );
      },
    );
  }
}

/// Explains the conditional row tinting in [_DistributorPayrollRow]: red
/// takes priority over green, which takes priority over blue, matching the
/// order a payslip's own adjustments are resolved in.
class _PayslipsLegend extends StatelessWidget {
  const _PayslipsLegend();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          _legendDot(Colors.red.shade100, 'Advance deduction'),
          _legendDot(Colors.green.shade100, 'Extra earning'),
          _legendDot(Colors.blue.shade100, 'Savings withdrawal'),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey.shade400),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  final DateTime weekStart;
  final DateTime weekEnd;
  final DateTime payDate;
  final ValueChanged<DateTime> onWeekChanged;
  final VoidCallback onPreviousWeek;
  final VoidCallback onNextWeek;
  final VoidCallback onThisWeek;
  final VoidCallback onOpenSettings;
  final VoidCallback onPrintBanking;
  final _PayrollView view;
  final ValueChanged<_PayrollView> onViewChanged;
  final OpsStatsController opsStatsController;

  /// The open week's undo history.
  final UndoKey undoKey;

  const _TopBar({
    required this.weekStart,
    required this.weekEnd,
    required this.payDate,
    required this.onWeekChanged,
    required this.onPreviousWeek,
    required this.onNextWeek,
    required this.onThisWeek,
    required this.onOpenSettings,
    required this.onPrintBanking,
    required this.view,
    required this.onViewChanged,
    required this.opsStatsController,
    required this.undoKey,
  });

  @override
  Widget build(BuildContext context) {
    Future<void> pickWeek() async {
      final picked = await showDatePicker(
        context: context,
        initialDate: weekStart,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        helpText: 'Pick any day in the pay week',
      );
      if (picked != null) onWeekChanged(picked);
    }

    final rangeLabel =
        '${_weekDayFormat.format(weekStart)} – ${_weekDayFormat.format(weekEnd)} '
        '${weekEnd.year}';

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                color: Colors.white,
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Previous week',
                onPressed: onPreviousWeek,
              ),
              InkWell(
                onTap: pickWeek,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        rangeLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Pay day: ${DateFormat('d MMM yyyy').format(payDate)}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                color: Colors.white,
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Next week',
                onPressed: onNextWeek,
              ),
              IconButton(
                color: Colors.white,
                icon: const Icon(Icons.calendar_month_outlined),
                tooltip: 'Pick week',
                onPressed: pickWeek,
              ),
              const Spacer(),
              Row(
                children: [
                  SegmentedButton<_PayrollView>(
                    style: SegmentedButton.styleFrom(
                      foregroundColor: Colors.white,
                      selectedForegroundColor: Colors.black,
                      selectedBackgroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                    segments: const [
                      ButtonSegment(
                          value: _PayrollView.opsStats,
                          label: Text('Ops Stats'),
                          icon: Icon(Icons.edit_note)),
                      ButtonSegment(
                          value: _PayrollView.payslips,
                          label: Text('Payslips'),
                          icon: Icon(Icons.receipt_long)),
                      ButtonSegment(
                          value: _PayrollView.banking,
                          label: Text('Banking'),
                          icon: Icon(Icons.account_balance)),
                    ],
                    selected: {view},
                    onSelectionChanged: (s) => onViewChanged(s.first),
                  ),
                  if (view == _PayrollView.opsStats) ...[
                    const SizedBox(width: 16),
                    for (final day in daysInWeek(weekStart))
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text(_dayChipFormat.format(day)),
                          labelStyle: const TextStyle(color: Colors.white),
                          backgroundColor: Colors.grey.shade800,
                          side: const BorderSide(color: Colors.white54),
                          onPressed: () => opsStatsController.scrollToDay(day),
                        ),
                      ),
                  ],
                ],
              ),
              Spacer(),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                ),
                onPressed: onThisWeek,
                child: const Text('This week'),
              ),
              if (view == _PayrollView.banking)
                IconButton(
                  color: Colors.white,
                  icon: const Icon(Icons.print),
                  tooltip: 'Print / export PDF',
                  onPressed: onPrintBanking,
                ),
              UndoRedoButtons(undoKey: undoKey, color: Colors.white),
              const PayslipAccessButton(),
              IconButton(
                color: Colors.white,
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Payroll settings',
                onPressed: onOpenSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// This week's status for a distributor's payslip row — whichever of an
/// active advance/penalty deduction, an extra earning, or a savings
/// withdrawal applies, in that priority order, driving the row's
/// conditional background tint and detail line.
({Color background, Color text, String detail})? _rowStatusFor(
    PayrollPayslip? payslip) {
  if (payslip == null) return null;
  if (payslip.isDeductingAdvanceThisWeek &&
      payslip.advanceDeductionAmount > 0) {
    return (
      background: Colors.red.shade100,
      text: Colors.red.shade900,
      detail: 'Advance deduction: '
          '${_currencyFormat.format(payslip.advanceDeductionAmount)}'
          '${payslip.advanceDeductionNote.isNotEmpty ? ' (${payslip.advanceDeductionNote})' : ''}',
    );
  }
  if (payslip.extraEarningsAmount != 0) {
    return (
      background: Colors.green.shade100,
      text: Colors.green.shade900,
      detail: 'Extra earning: '
          '${_currencyFormat.format(payslip.extraEarningsAmount)}'
          '${payslip.extraEarningsNote.isNotEmpty ? ' (${payslip.extraEarningsNote})' : ''}',
    );
  }
  if (payslip.isWithdrawingSavingsThisWeek &&
      payslip.savingsWithdrawalAmount > 0) {
    return (
      background: Colors.blue.shade100,
      text: Colors.blue.shade900,
      detail: 'Savings withdrawal: '
          '${_currencyFormat.format(payslip.savingsWithdrawalAmount)}',
    );
  }
  return null;
}

class _DistributorPayrollRow extends StatelessWidget {
  final Distributor distributor;
  final PayrollPayslip? payslip;

  /// Total still owed across all of this distributor's advances/penalties —
  /// shown, alongside this week's deduction, only for those who have any
  /// outstanding balance.
  final double outstanding;
  final VoidCallback onTap;

  const _DistributorPayrollRow({
    required this.distributor,
    required this.payslip,
    required this.outstanding,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final status = _rowStatusFor(payslip);
    final hasOutstanding = outstanding > 0.005;
    final thisWeekDeduction =
        (payslip?.isDeductingAdvanceThisWeek ?? false)
            ? (payslip?.advanceDeductionAmount ?? 0)
            : 0.0;

    final subtitleLines = <Widget>[
      if (status != null)
        Text(
          status.detail,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: status.text),
        ),
      if (hasOutstanding)
        Text(
          'This week deduction: ${_currencyFormat.format(thisWeekDeduction)}'
          '  ·  Outstanding balance: ${_currencyFormat.format(outstanding)}',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.orange.shade900),
        ),
    ];

    return ListTile(
      onTap: onTap,
      tileColor: status?.background,
      isThreeLine: subtitleLines.length > 1,
      title: Text(distributor.name),
      subtitle: subtitleLines.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: subtitleLines,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AmountColumn(label: 'Gross', value: payslip?.grossWage ?? 0),
          const SizedBox(width: 16),
          _AmountColumn(
              label: 'Deduction',
              value: -(payslip?.advanceDeductionAmount ?? 0)),
          const SizedBox(width: 16),
          _AmountColumn(
              label: 'Net',
              value: payslip?.netWage ?? 0,
              emphasize: true,
              warnIfNegative: true),
        ],
      ),
    );
  }
}

class _AmountColumn extends StatelessWidget {
  final String label;
  final double value;
  final bool emphasize;

  /// Highlights the figure in red when negative — used only for "Net" (a
  /// negative net wage means a deduction exceeded the gross wage, which
  /// shouldn't happen without an explicit override; see the confirmation
  /// dialog in `AdvanceSection._apply`). Not used for "Deduction", which is
  /// always shown as a negative number by design.
  final bool warnIfNegative;

  const _AmountColumn({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.warnIfNegative = false,
  });

  @override
  Widget build(BuildContext context) {
    final isWarning = warnIfNegative && value < 0;
    return SizedBox(
      width: 100,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(
            _currencyFormat.format(value),
            style: TextStyle(
              fontWeight: emphasize ? FontWeight.bold : null,
              color: isWarning ? Colors.red.shade700 : null,
            ),
          ),
        ],
      ),
    );
  }
}
