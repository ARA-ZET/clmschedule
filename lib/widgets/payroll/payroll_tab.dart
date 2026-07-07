import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/distributor.dart';
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import 'ops_stats_view.dart';
import 'payment_summary_view.dart';
import 'payroll_settings_dialog.dart';
import 'payslip_detail_view.dart';

final _currencyFormat = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
final _weekDayFormat = DateFormat('d MMM');

enum _PayrollView { opsStats, payslips }

/// Main Payroll screen.
///
/// Layout:
///   - This tab's own top bar: week navigation (prev/next/pick/"This week")
///     + Payment summary + Payroll settings — separate from the shared
///     dashboard app bar/tab strip above it, which is common to every tab.
///   - A toggle between two bodies for the selected week:
///     - Ops Stats: bulk daily-stats entry + week-at-a-glance overview
///       (the old sheet's "Ops Stats" tab equivalent) — the default view,
///       since that's the day-to-day data-entry workflow.
///     - Payslips: one row per distributor with gross/transport/advance/net;
///       tapping a row opens that distributor's computed payslip.
///
/// Both views only show active distributors, or non-active distributors
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
          onOpenPaymentSummary: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PaymentSummaryView()),
          ),
        ),
        if (payroll.isLoading)
          const LinearProgressIndicator(minHeight: 2)
        else
          const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<_PayrollView>(
              segments: const [
                ButtonSegment(
                    value: _PayrollView.opsStats,
                    label: Text('Ops Stats'),
                    icon: Icon(Icons.edit_note)),
                ButtonSegment(
                    value: _PayrollView.payslips,
                    label: Text('Payslips'),
                    icon: Icon(Icons.receipt_long)),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
          ),
        ),
        Expanded(
          child: _view == _PayrollView.opsStats
              ? const OpsStatsView()
              : _PayslipsGrid(distributors: distributors, payroll: payroll),
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
    return ListView.separated(
      itemCount: distributors.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final distributor = distributors[index];
        final payslip = payroll.week.payslips[distributor.id];
        return _DistributorPayrollRow(
          distributor: distributor,
          grossWage: payslip?.grossWage ?? 0,
          transportDeduction: payslip?.transportDeduction ?? 0,
          advanceDeduction: payslip?.advanceDeductionAmount ?? 0,
          netWage: payslip?.netWage ?? 0,
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

class _TopBar extends StatelessWidget {
  final DateTime weekStart;
  final DateTime weekEnd;
  final DateTime payDate;
  final ValueChanged<DateTime> onWeekChanged;
  final VoidCallback onPreviousWeek;
  final VoidCallback onNextWeek;
  final VoidCallback onThisWeek;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPaymentSummary;

  const _TopBar({
    required this.weekStart,
    required this.weekEnd,
    required this.payDate,
    required this.onWeekChanged,
    required this.onPreviousWeek,
    required this.onNextWeek,
    required this.onThisWeek,
    required this.onOpenSettings,
    required this.onOpenPaymentSummary,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white54),
            ),
            onPressed: onThisWeek,
            child: const Text('This week'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white54),
            ),
            onPressed: onOpenPaymentSummary,
            icon: const Icon(Icons.receipt_long),
            label: const Text('Payment summary'),
          ),
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Payroll settings',
            onPressed: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

class _DistributorPayrollRow extends StatelessWidget {
  final Distributor distributor;
  final double grossWage;
  final double transportDeduction;
  final double advanceDeduction;
  final double netWage;
  final VoidCallback onTap;

  const _DistributorPayrollRow({
    required this.distributor,
    required this.grossWage,
    required this.transportDeduction,
    required this.advanceDeduction,
    required this.netWage,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      title: Text(distributor.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AmountColumn(label: 'Gross', value: grossWage),
          const SizedBox(width: 16),
          _AmountColumn(label: 'Transport', value: -transportDeduction),
          const SizedBox(width: 16),
          _AmountColumn(label: 'Advance', value: -advanceDeduction),
          const SizedBox(width: 16),
          _AmountColumn(label: 'Net', value: netWage, emphasize: true),
        ],
      ),
    );
  }
}

class _AmountColumn extends StatelessWidget {
  final String label;
  final double value;
  final bool emphasize;

  const _AmountColumn({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(
            _currencyFormat.format(value),
            style: emphasize
                ? const TextStyle(fontWeight: FontWeight.bold)
                : null,
          ),
        ],
      ),
    );
  }
}
