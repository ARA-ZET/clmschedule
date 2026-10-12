import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/distributor.dart';
import '../../models/payment_status.dart';
import '../../models/payroll_daily_entry.dart';
import '../../models/payroll_payslip.dart';
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../utils/payroll_week.dart';
import 'manage_payment_accounts_dialog.dart';

final _currencyFormat = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
final _dayFormat = DateFormat('EEE d');

// Table-like column layout, shared by the header and every row, so a big
// screen's width is used edge-to-edge in one line per distributor instead
// of wrapping fields onto a second line.
const double _kMinTableWidth = 950;
const int _kNameFlex = 2;
const double _kStatusWidth = 140;
const double _kAccountWidth = 280;
const int _kNotesFlex = 2;
const double _kNetPayWidth = 130;
const double _kRowGap = 12;

Color _statusColor(PaymentStatus status, BuildContext context) {
  switch (status) {
    case PaymentStatus.paid:
      return Colors.green.shade100;
    case PaymentStatus.processing:
      return Colors.orange.shade100;
    case PaymentStatus.notPaid:
      return Theme.of(context).scaffoldBackgroundColor;
  }
}

/// The Banking tab: who gets paid how, and whether it's gone out yet.
/// Replaces the old sheet's "banking" tab — each distributor picks which of
/// their saved payment accounts (eWallet numbers / bank accounts, they can
/// have several) this week's payment went to, plus a note and a
/// paid/processing/not-paid status, and eWallet vs bank account subtotals
/// for the week. Laid out as one row per distributor (table-style,
/// edge-to-edge) since this tab is used on large screens.
class BankingView extends riverpod.ConsumerStatefulWidget {
  const BankingView({super.key});

  @override
  riverpod.ConsumerState<BankingView> createState() => _BankingViewState();
}

class _BankingViewState extends riverpod.ConsumerState<BankingView> {
  DateTime? _builtForWeekStart;
  Set<String> _builtDistributorIds = {};
  final Map<String, TextEditingController> _notesControllers = {};

  void _disposeAll() {
    for (final c in _notesControllers.values) {
      c.dispose();
    }
    _notesControllers.clear();
  }

  @override
  void dispose() {
    _disposeAll();
    super.dispose();
  }

  bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.every(b.contains);
  }

  void _buildRows(Map<String, PayrollPayslip> payslips) {
    _disposeAll();
    for (final p in payslips.values) {
      _notesControllers[p.distributorId] =
          TextEditingController(text: p.paymentNotes);
    }
  }

  static bool _hasWageRecorded(PayrollDailyEntry? e) =>
      e != null &&
      e.worked &&
      ((e.specialCode?.isNotEmpty ?? false) || e.flyerSets != null);

  @override
  Widget build(BuildContext context) {
    final payroll = ref.watch(payrollRiverpod);
    final schedule = ref.watch(scheduleRiverpod);
    final distributors = schedule.distributorsWithJobsInRange(
        payroll.weekStart, payroll.weekEnd)
      ..sort((a, b) => a.index.compareTo(b.index));
    final payslips = payroll.week.payslips;

    // Days each distributor had a schedule job but Ops Stats has no sets or
    // code for — their wage for those days is missing, so they can't be
    // marked paid until it's recorded.
    final days = daysInWeek(payroll.weekStart);
    final unrecordedDays = <String, List<DateTime>>{
      for (final d in distributors)
        d.id: [
          for (final day in days)
            if (schedule.getJobsForDistributorAndDate(d.id, day).isNotEmpty &&
                !_hasWageRecorded(payslips[d.id]?.dailyEntries[dayKeyFor(day)]))
              day,
        ],
    };

    final distributorIds = {for (final d in distributors) d.id};
    if (_builtForWeekStart != payroll.weekStart ||
        !_setEquals(_builtDistributorIds, distributorIds)) {
      _buildRows(payslips);
      _builtForWeekStart = payroll.weekStart;
      _builtDistributorIds = distributorIds;
    }

    double ewalletTotal = 0;
    double bankTotal = 0;
    for (final p in payslips.values) {
      if (p.paymentAccountSnapshot?.method == 'Bank account') {
        bankTotal += p.netWage;
      } else {
        ewalletTotal += p.netWage;
      }
    }

    if (distributors.isEmpty) {
      return const Center(child: Text('No distributors found.'));
    }

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tableWidth = constraints.maxWidth < _kMinTableWidth
                  ? _kMinTableWidth
                  : constraints.maxWidth;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: tableWidth,
                  child: Column(
                    children: [
                      const _BankingHeaderRow(),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: distributors.length,
                          itemBuilder: (context, i) {
                            final d = distributors[i];
                            final payslip = payslips[d.id];
                            final notes = _notesControllers[d.id];
                            if (payslip == null || notes == null) {
                              return ListTile(
                                title: Text(d.name),
                                subtitle: const Text(
                                    'No payslip for this week yet.'),
                              );
                            }
                            final missing = unrecordedDays[d.id] ?? const [];
                            return _BankingRow(
                              distributor: d,
                              payslip: payslip,
                              notes: notes,
                              unrecordedDays: missing,
                              onStatusChanged: (status) {
                                if (status == PaymentStatus.paid &&
                                    missing.isNotEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          "Can't mark ${d.name} paid — no "
                                          'sets or code recorded in Ops Stats '
                                          'for ${missing.map(_dayFormat.format).join(', ')}.'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                  return;
                                }
                                ref
                                    .read(payrollRiverpod)
                                    .updatePaymentStatus(d.id, status);
                              },
                              onSelectAccount: (accountId) => ref
                                  .read(payrollRiverpod)
                                  .selectPaymentAccountForWeek(
                                      d.id, accountId),
                              onManageAccounts: () =>
                                  showManagePaymentAccountsDialog(context,
                                      distributorId: d.id),
                              onNotesChanged: () => ref
                                  .read(payrollRiverpod)
                                  .updatePaymentNotes(d.id, notes.text),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade300)),
          ),
          // Left-aligned (not spaceBetween) so the totals stay clear of the
          // AI chat / team chat FABs docked bottom-right of the screen.
          child: Row(
            children: [
              _SummaryFigure(label: 'eWallet total', value: ewalletTotal),
              const SizedBox(width: 32),
              _SummaryFigure(label: 'Bank account total', value: bankTotal),
              const SizedBox(width: 32),
              _SummaryFigure(
                label: 'Grand total',
                value: ewalletTotal + bankTotal,
                emphasize: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BankingHeaderRow extends StatelessWidget {
  const _BankingHeaderRow();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontWeight: FontWeight.bold, fontSize: 12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade400)),
      ),
      child: Row(
        children: [
          Expanded(
              flex: _kNameFlex, child: const Text('Distributor', style: style)),
          const SizedBox(width: _kRowGap),
          SizedBox(width: _kStatusWidth, child: const Text('Status', style: style)),
          SizedBox(
              width: _kAccountWidth,
              child: const Text('Payment account', style: style)),
          const SizedBox(width: _kRowGap),
          Expanded(flex: _kNotesFlex, child: const Text('Notes', style: style)),
          SizedBox(
            width: _kNetPayWidth,
            child: Text('Net pay', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _BankingRow extends StatelessWidget {
  final Distributor distributor;
  final PayrollPayslip payslip;
  final TextEditingController notes;

  /// Scheduled days with no sets/code in Ops Stats — see BankingView.
  final List<DateTime> unrecordedDays;
  final ValueChanged<PaymentStatus> onStatusChanged;
  final ValueChanged<String> onSelectAccount;
  final VoidCallback onManageAccounts;
  final VoidCallback onNotesChanged;

  const _BankingRow({
    required this.distributor,
    required this.payslip,
    required this.notes,
    required this.unrecordedDays,
    required this.onStatusChanged,
    required this.onSelectAccount,
    required this.onManageAccounts,
    required this.onNotesChanged,
  });

  static const _fieldStyle = TextStyle(fontSize: 13);

  @override
  Widget build(BuildContext context) {
    final accounts = distributor.payroll?.paymentAccounts ?? const [];
    final selectedId = payslip.selectedPaymentAccountId;
    // Keep the snapshot's account selectable even if it was since removed
    // from the distributor's live list, so the row never shows a blank
    // dropdown for a week that's already been recorded.
    final snapshot = payslip.paymentAccountSnapshot;
    final dropdownItems = [
      ...accounts,
      if (snapshot != null && !accounts.any((a) => a.id == snapshot.id))
        snapshot,
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _statusColor(payslip.paymentStatus, context),
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: _kNameFlex,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    distributor.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (unrecordedDays.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  // Pushed to the far right, beside the status button.
                  Expanded(
                    child: Tooltip(
                      message: 'Scheduled to work but no sets or code '
                          'recorded in Ops Stats — no wage for these days.',
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              size: 16, color: Colors.red.shade700),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'No wage recorded: '
                              '${unrecordedDays.map(_dayFormat.format).join(', ')}',
                              textAlign: TextAlign.right,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.red.shade700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: _kRowGap),
          SizedBox(
            width: _kStatusWidth,
            child: _PaymentStatusButton(
              status: payslip.paymentStatus,
              onChanged: onStatusChanged,
            ),
          ),
          SizedBox(
            width: _kAccountWidth,
            child: Row(
              children: [
                Expanded(
                  child: dropdownItems.isEmpty
                      ? TextButton.icon(
                          onPressed: onManageAccounts,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add account'),
                        )
                      : DropdownButtonFormField<String>(
                          initialValue: dropdownItems.any((a) => a.id == selectedId)
                              ? selectedId
                              : null,
                          isExpanded: true,
                          style: _fieldStyle.copyWith(
                              color: Colors.black87, fontWeight: FontWeight.bold),
                          decoration: const InputDecoration(
                            isDense: true,
                            isCollapsed: true,
                            border: InputBorder.none,
                          ),
                          items: [
                            for (final a in dropdownItems)
                              DropdownMenuItem(
                                value: a.id,
                                child: Text(a.summary,
                                    overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          onChanged: (id) {
                            if (id != null) onSelectAccount(id);
                          },
                        ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  tooltip: 'Manage payment accounts',
                  visualDensity: VisualDensity.compact,
                  onPressed: onManageAccounts,
                ),
              ],
            ),
          ),
          const SizedBox(width: _kRowGap),
          Expanded(
            flex: _kNotesFlex,
            child: TextField(
              controller: notes,
              style: _fieldStyle,
              decoration: const InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Notes',
              ),
              onChanged: (_) => onNotesChanged(),
            ),
          ),
          SizedBox(
            width: _kNetPayWidth,
            child: Text(
              _currencyFormat.format(payslip.netWage),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: payslip.netWage < 0 ? Colors.red.shade700 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Fixed label width so Paid/Processing/Not paid all render as the same-size
// button regardless of how many characters each word has — "Processing" is
// the longest, so this is sized to fit it without wrapping.
const double _kStatusLabelWidth = 82;

class _PaymentStatusButton extends StatelessWidget {
  final PaymentStatus status;
  final ValueChanged<PaymentStatus> onChanged;

  const _PaymentStatusButton({required this.status, required this.onChanged});

  Color _fg() {
    switch (status) {
      case PaymentStatus.paid:
        return Colors.green.shade900;
      case PaymentStatus.processing:
        return Colors.orange.shade900;
      case PaymentStatus.notPaid:
        return Colors.black87;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<PaymentStatus>(
      onSelected: onChanged,
      itemBuilder: (context) => PaymentStatus.values
          .map((s) =>
              PopupMenuItem(value: s, child: Text(s.displayName)))
          .toList(),
      child: Chip(
        label: SizedBox(
          width: _kStatusLabelWidth,
          child: Text(
            status.displayName,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: _fg(), fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ),
        labelPadding: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        backgroundColor: Colors.white,
        side: BorderSide(color: _fg()),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _SummaryFigure extends StatelessWidget {
  final String label;
  final double value;
  final bool emphasize;

  const _SummaryFigure({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(
          _currencyFormat.format(value),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: emphasize ? 18 : 15,
          ),
        ),
      ],
    );
  }
}
