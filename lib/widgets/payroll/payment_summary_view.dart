import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../models/payment_summary.dart';
import '../../providers/payroll_provider.dart';
import '../../utils/payroll_pdf.dart';

final _currencyFormat = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);

/// The EFT-run view for the selected payroll week — every distributor's
/// net pay + bank details + a grand total. Replaces the old sheet's
/// "banking" tab. Built client-side from the already-loaded [PayrollWeek]
/// so it always reflects any unsaved-but-applied edits in this session.
class PaymentSummaryView extends riverpod.ConsumerWidget {
  const PaymentSummaryView({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final payroll = ref.watch(payrollRiverpod);
    final week = payroll.week;

    final lines = week.payslips.values
        .map((p) => PaymentSummaryLine(
              distributorId: p.distributorId,
              distributorName: p.distributorName,
              netWage: p.netWage,
              bankName: p.bankNameSnapshot,
              bankAccountHolder: p.bankAccountHolderSnapshot,
              bankAccountNumber: p.bankAccountNumberSnapshot,
              bankBranchCode: p.bankBranchCodeSnapshot,
              paymentMethod: p.paymentMethodSnapshot,
            ))
        .toList()
      ..sort((a, b) => a.distributorName.compareTo(b.distributorName));
    final totalNet = lines.fold<double>(0, (total, l) => total + l.netWage);
    final summary = PaymentSummary(
      weekStart: week.weekStart,
      payDate: week.payDate,
      lines: lines,
      totalNet: totalNet,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment summary'),
        actions: [
          IconButton(
            tooltip: 'Print / export PDF',
            icon: const Icon(Icons.print, color: Colors.white),
            onPressed: () => Printing.layoutPdf(
              name: 'Payment summary '
                  '${DateFormat('yyyy-MM-dd').format(week.weekStart)}',
              onLayout: (_) => generatePaymentSummaryPdf(summary),
            ),
          ),
        ],
      ),
      body: lines.isEmpty
          ? const Center(child: Text('No payslips for this week yet.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Pay day ${DateFormat('d MMMM yyyy').format(week.payDate)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Table(
                  columnWidths: const {
                    0: FlexColumnWidth(2),
                    1: FlexColumnWidth(3),
                    2: FlexColumnWidth(1.2),
                  },
                  children: [
                    const TableRow(children: [
                      _HeaderCell('Distributor'),
                      _HeaderCell('Bank / account'),
                      _HeaderCell('Net pay'),
                    ]),
                    for (final line in lines)
                      TableRow(children: [
                        _Cell(line.distributorName),
                        _Cell([
                          if (line.bankName != null) line.bankName!,
                          if (line.bankAccountHolder != null)
                            line.bankAccountHolder!,
                          if (line.bankAccountNumber != null)
                            line.bankAccountNumber!,
                        ].join(' · ')),
                        _Cell(_currencyFormat.format(line.netWage)),
                      ]),
                  ],
                ),
                const Divider(height: 32),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Total: ${_currencyFormat.format(totalNet)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
              ],
            ),
    );
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
