import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/advance.dart';
import '../models/advance_repayment.dart';
import '../models/distributor.dart';
import '../models/payment_summary.dart';
import '../models/payroll_payslip.dart';
import '../models/payroll_settings.dart';
import '../models/savings_deposit.dart';
import '../models/savings_withdrawal.dart';
import '../utils/payroll_calculator.dart' as calc;
import '../utils/payroll_week.dart';
import '../utils/repayment_schedule.dart';

const String _fallbackLogoAsset = 'assets/logo.png';

final _dateFormat = DateFormat('d MMMM yyyy');
final _dayFormat = DateFormat('EEE d MMM');

String _money(double v) => 'R ${v.toStringAsFixed(2)}';

/// "DR" -> "DR - Driving" when the code has a configured label, else just
/// the bare code.
String _codeWithLabel(String code, Map<String, String> bonusCodeLabels) {
  final label = bonusCodeLabels[code];
  return (label != null && label.trim().isNotEmpty) ? '$code - $label' : code;
}

double _sumByMethod(PaymentSummary summary, String method) => summary.lines
    .where((l) => l.paymentMethod == method)
    .fold<double>(0, (total, l) => total + l.netWage);

/// Loads the company logo — the uploaded [PayrollSettings.companyLogoUrl]
/// if set, otherwise the bundled fallback asset.
Future<pw.MemoryImage?> _loadCompanyLogo(PayrollSettings settings) async {
  try {
    final url = settings.companyLogoUrl;
    if (url != null && url.isNotEmpty) {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        return pw.MemoryImage(response.bodyBytes);
      }
    }
    final bytes = await rootBundle.load(_fallbackLogoAsset);
    return pw.MemoryImage(bytes.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

/// Generates one distributor's wage slip for a payroll week — company
/// letterhead with logo, distributor identity details, 7-day breakdown,
/// advance/savings lines, net total, signature footer.
Future<Uint8List> generatePayslipPdf({
  required PayrollPayslip payslip,
  required DateTime weekStart,
  required DateTime weekEnd,
  required DateTime payDate,
  required PayrollSettings settings,
  Distributor? distributor,
  double outstandingDeductionBalance = 0,
  double savingsBalanceHeld = 0,
  List<Advance> advances = const [],
  List<AdvanceRepayment> repayments = const [],
  List<SavingsDeposit> deposits = const [],
  List<SavingsWithdrawal> withdrawals = const [],
}) async {
  final regular = await PdfGoogleFonts.openSansRegular();
  final bold = await PdfGoogleFonts.openSansBold();

  final baseStyle = pw.TextStyle(font: regular, fontSize: 10);
  final boldStyle = pw.TextStyle(font: bold, fontSize: 10);
  final mutedStyle =
      pw.TextStyle(font: regular, fontSize: 9, color: PdfColors.grey700);

  final dates = payslip.dailyEntries.keys.toList()..sort();

  final logo = await _loadCompanyLogo(settings);
  final addressLines = settings.companyAddress
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  final displayName = (distributor?.fullName?.trim().isNotEmpty ?? false)
      ? distributor!.fullName!.trim()
      : payslip.distributorName;

  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (context) => [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Expanded(
                  child: pw.Container(
                    alignment: pw.Alignment.centerLeft,
                    child: logo != null
                        ? pw.Image(logo, height: 80, fit: pw.BoxFit.contain)
                        : pw.SizedBox(),
                  ),
                ),
                pw.SizedBox(width: 16),
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(settings.companyName,
                          style: pw.TextStyle(font: bold, fontSize: 16)),
                      for (final line in addressLines)
                        pw.Text(line, style: mutedStyle),
                      if (settings.companyPhone.isNotEmpty)
                        pw.Text('Tel: ${settings.companyPhone}',
                            style: mutedStyle),
                      if (settings.companyEmail.isNotEmpty)
                        pw.Text('Email: ${settings.companyEmail}',
                            style: mutedStyle),
                      if (settings.companyVatNo.isNotEmpty ||
                          settings.companyRegistrationNo.isNotEmpty)
                        pw.Text(
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
            pw.SizedBox(height: 16),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 8),
            pw.Text('Wage slip', style: pw.TextStyle(font: bold, fontSize: 14)),
            pw.SizedBox(height: 8),
            _kv('Name', displayName, boldStyle, baseStyle),
            if (distributor?.idNumber?.trim().isNotEmpty ?? false)
              _kv('ID number', distributor!.idNumber!.trim(), boldStyle,
                  baseStyle),
            if (distributor?.homeAddress?.trim().isNotEmpty ?? false)
              _kv('Home address', distributor!.homeAddress!.trim(), boldStyle,
                  baseStyle),
            _kv(
                'Pay period',
                '${_dayFormat.format(weekStart)} – ${_dayFormat.format(weekEnd)}',
                boldStyle,
                baseStyle),
            _kv('Payment day', _dateFormat.format(payDate), boldStyle,
                baseStyle),
            pw.SizedBox(height: 16),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              columnWidths: const {
                0: pw.FlexColumnWidth(2),
                1: pw.FlexColumnWidth(2),
                2: pw.FlexColumnWidth(1.5),
                3: pw.FlexColumnWidth(1.5),
                4: pw.FlexColumnWidth(1.5),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey800),
                  children: [
                    _cell('Date', style: _headStyle(bold)),
                    _cell('Day', style: _headStyle(bold)),
                    _cell('Basic', style: _headStyle(bold)),
                    _cell('Bonus', style: _headStyle(bold)),
                    _cell('Total', style: _headStyle(bold)),
                  ],
                ),
                for (final key in dates)
                  _dayRow(payslip, key, baseStyle, settings.bonusCodeLabels),
              ],
            ),
            pw.SizedBox(height: 16),
            _summaryRow('Total gross wage', payslip.grossWage, boldStyle),
            _buildDeductionsTable(
              weekStart: weekStart,
              advances: advances,
              repayments: repayments,
              bold: bold,
            ),
            _buildSavingsTable(
              weekStart: weekStart,
              deposits: deposits,
              withdrawals: withdrawals,
              bold: bold,
            ),
            if (payslip.extraEarningsAmount != 0) ...[
              pw.SizedBox(height: 10),
              _extraEarningsBlock(payslip, bold, boldStyle, baseStyle),
            ],
            pw.SizedBox(height: 10),
            pw.Divider(color: PdfColors.grey400),
            _summaryRow('Total net wage', payslip.netWage,
                pw.TextStyle(font: bold, fontSize: 13)),
            if (outstandingDeductionBalance > 0.005 ||
                savingsBalanceHeld > 0.005) ...[
              pw.SizedBox(height: 8),
              if (outstandingDeductionBalance > 0.005)
                pw.Text(
                  'Outstanding deduction balance: '
                  '${_money(outstandingDeductionBalance)}',
                  style: mutedStyle,
                ),
              if (savingsBalanceHeld > 0.005)
                pw.Text(
                  'Savings balance held: ${_money(savingsBalanceHeld)}',
                  style: mutedStyle,
                ),
            ],
            pw.SizedBox(height: 48),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Container(
                        width: 160,
                        decoration: const pw.BoxDecoration(
                            border: pw.Border(
                                top: pw.BorderSide(color: PdfColors.grey600))),
                        padding: const pw.EdgeInsets.only(top: 4),
                        child:
                            pw.Text('Employee signature', style: mutedStyle)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Container(
                        width: 160,
                        decoration: const pw.BoxDecoration(
                            border: pw.Border(
                                top: pw.BorderSide(color: PdfColors.grey600))),
                        padding: const pw.EdgeInsets.only(top: 4),
                        child: pw.Text('Company signature', style: mutedStyle)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  );

  return doc.save();
}

/// Generates the week's payment-run summary — every distributor's net pay
/// + bank details + a grand total (replaces the old sheet's "banking" tab).
Future<Uint8List> generatePaymentSummaryPdf(
  PaymentSummary summary, {
  required PayrollSettings settings,
}) async {
  final regular = await PdfGoogleFonts.openSansRegular();
  final bold = await PdfGoogleFonts.openSansBold();

  final baseStyle = pw.TextStyle(font: regular, fontSize: 9);
  final mutedStyle =
      pw.TextStyle(font: regular, fontSize: 9, color: PdfColors.grey700);

  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(settings.companyName,
              style: pw.TextStyle(font: bold, fontSize: 16)),
          pw.SizedBox(height: 4),
          pw.Text('Payment summary',
              style: pw.TextStyle(font: bold, fontSize: 14)),
          pw.Text(
            'Pay day ${_dateFormat.format(summary.payDate)}   '
            '(week starting ${_dateFormat.format(summary.weekStart)})',
            style: mutedStyle,
          ),
          pw.SizedBox(height: 16),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(2),
              1: pw.FlexColumnWidth(1.5),
              2: pw.FlexColumnWidth(2.5),
              3: pw.FlexColumnWidth(1.3),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey800),
                children: [
                  _cell('Distributor', style: _headStyle(bold)),
                  _cell('Method', style: _headStyle(bold)),
                  _cell('Account', style: _headStyle(bold)),
                  _cell('Net pay', style: _headStyle(bold)),
                ],
              ),
              for (final line in summary.lines)
                pw.TableRow(children: [
                  _cell(line.distributorName, style: baseStyle),
                  _cell(line.paymentMethod, style: baseStyle),
                  _cell(line.accountSummary, style: baseStyle),
                  _cell(_money(line.netWage), style: baseStyle),
                ]),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  'eWallet total: ${_money(_sumByMethod(summary, 'eWallet'))}',
                  style: baseStyle,
                ),
                pw.Text(
                  'Bank account total: '
                  '${_money(_sumByMethod(summary, 'Bank account'))}',
                  style: baseStyle,
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'Grand total: ${_money(summary.totalNet)}',
                  style: pw.TextStyle(font: bold, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  return doc.save();
}

pw.Widget _kv(String label, String value, pw.TextStyle labelStyle,
    pw.TextStyle valueStyle) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: pw.Row(
      children: [
        pw.SizedBox(width: 90, child: pw.Text(label, style: labelStyle)),
        pw.Text(value, style: valueStyle),
      ],
    ),
  );
}

pw.TextStyle _headStyle(pw.Font bold) =>
    pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white);

pw.Widget _cell(String text, {required pw.TextStyle style}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      child: pw.Text(text, style: style),
    );

pw.TableRow _dayRow(
  PayrollPayslip payslip,
  String key,
  pw.TextStyle style,
  Map<String, String> bonusCodeLabels,
) {
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
  return pw.TableRow(children: [
    _cell(_dayFormat.format(entry.date), style: style),
    _cell(dayLabel, style: style),
    _cell(_money(basic), style: style),
    _cell(_money(bonus), style: style),
    _cell(_money(basic + bonus), style: style),
  ]);
}

pw.Widget _summaryRow(String label, double value, pw.TextStyle style) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: style),
        pw.Text(_money(value), style: style),
      ],
    ),
  );
}

pw.Widget _extraEarningsBlock(
  PayrollPayslip payslip,
  pw.Font bold,
  pw.TextStyle boldStyle,
  pw.TextStyle baseStyle,
) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text('Extra earnings', style: pw.TextStyle(font: bold, fontSize: 11)),
      pw.SizedBox(height: 4),
      if (payslip.extraEarningsNote.isNotEmpty)
        _kv('Description', payslip.extraEarningsNote, boldStyle, baseStyle),
      _kv('Amount', _money(payslip.extraEarningsAmount), boldStyle, baseStyle),
    ],
  );
}

/// A wide, dense table — small bold text throughout — spanning the full
/// page width so several deduction/savings items never need more than one
/// row each.
pw.Widget _itemsTable({
  required List<String> columnHeaders,
  required Map<int, pw.TableColumnWidth> columnWidths,
  required List<List<String>> rows,
  required pw.Font bold,
}) {
  final headerStyle =
      pw.TextStyle(font: bold, fontSize: 8, color: PdfColors.white);
  final cellStyle = pw.TextStyle(font: bold, fontSize: 8);

  return pw.Table(
    border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
    columnWidths: columnWidths,
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey800),
        children: [
          for (final header in columnHeaders)
            pw.Padding(
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              child: pw.Text(header, style: headerStyle),
            ),
        ],
      ),
      for (final row in rows)
        pw.TableRow(
          children: [
            for (final cell in row)
              pw.Padding(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                child: pw.Text(cell, style: cellStyle),
              ),
          ],
        ),
    ],
  );
}

/// Each item's instalment schedule as a horizontal strip of small
/// date/amount boxes — mirroring `_ScheduleHistory` on the on-screen payslip
/// and the original wage-slip spreadsheet, so a distributor holding the
/// PRINTED slip can see exactly WHEN each deduction came off and HOW MUCH.
/// The summary table answers "how many instalments"; this answers "which
/// ones, and when". Paid instalments are shaded and black, still-projected
/// ones outlined and grey, so a forecast is never mistaken for money taken.
pw.Widget _scheduleHistory({
  required String heading,
  required List<({String title, List<ScheduleEntry> schedule})> histories,
  required pw.Font bold,
}) {
  if (histories.isEmpty) return pw.SizedBox();
  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 8),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          '$heading  (shaded = already deducted, grey = still to come)',
          style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
        ),
        for (final h in histories) ...[
          pw.SizedBox(height: 5),
          pw.Text(h.title, style: pw.TextStyle(font: bold, fontSize: 8)),
          pw.SizedBox(height: 2),
          pw.Wrap(
            spacing: 3,
            runSpacing: 3,
            children: [
              for (final e in h.schedule)
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(
                      horizontal: 4, vertical: 2),
                  decoration: pw.BoxDecoration(
                    color: e.isActual ? PdfColors.grey200 : null,
                    border: pw.Border.all(
                        color: PdfColors.grey400, width: 0.5),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.Text(
                        _dayFormat.format(e.date),
                        style: pw.TextStyle(
                          fontSize: 6.5,
                          color: e.isActual
                              ? PdfColors.grey800
                              : PdfColors.grey500,
                        ),
                      ),
                      pw.Text(
                        _money(e.amount),
                        style: pw.TextStyle(
                          font: bold,
                          fontSize: 7.5,
                          color: e.isActual
                              ? PdfColors.black
                              : PdfColors.grey500,
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

pw.Widget _buildDeductionsTable({
  required DateTime weekStart,
  required List<Advance> advances,
  required List<AdvanceRepayment> repayments,
  required pw.Font bold,
}) {
  final weekId = weekIdFor(weekStart);
  final weekEnd = weekEndFor(weekStart);
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
  if (relevant.isEmpty) return pw.SizedBox();

  final counters = <DeductionType, int>{};
  final rows = <List<String>>[];
  final histories = <({String title, List<ScheduleEntry> schedule})>[];
  for (final item in relevant) {
    final count = (counters[item.type] ?? 0) + 1;
    counters[item.type] = count;
    final itemPayments = repayments
        .where((r) =>
            r.advanceId == item.id && isOnOrBeforeWeek(r.linkedWeekId, weekId))
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
      _dayFormat.format(item.datePaid),
      _money(item.amount),
      schedule.isEmpty ? '-' : '${schedule.length}',
      item.preferredInstallmentAmount > 0
          ? _money(item.preferredInstallmentAmount)
          : '-',
      (item.note != null && item.note!.trim().isNotEmpty)
          ? item.note!.trim()
          : '-',
      schedule.isEmpty ? '-' : _dayFormat.format(schedule.last.date),
      _money(thisWeekAmount),
    ]);
    if (schedule.isNotEmpty) {
      histories.add((
        title: '$title  -  ${_dayFormat.format(item.datePaid)}  -  '
            '${_money(item.amount)}',
        schedule: schedule,
      ));
    }
  }

  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 10),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _itemsTable(
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
          columnWidths: {
            0: const pw.FlexColumnWidth(2.2),
            1: const pw.FlexColumnWidth(1.2),
            2: const pw.FlexColumnWidth(1.1),
            3: const pw.FlexColumnWidth(0.9),
            4: const pw.FlexColumnWidth(1.2),
            5: const pw.FlexColumnWidth(1.6),
            6: const pw.FlexColumnWidth(1.2),
            7: const pw.FlexColumnWidth(1.4),
          },
          rows: rows,
          bold: bold,
        ),
        _scheduleHistory(
            heading: 'Deduction history', histories: histories, bold: bold),
      ],
    ),
  );
}

pw.Widget _buildSavingsTable({
  required DateTime weekStart,
  required List<SavingsDeposit> deposits,
  required List<SavingsWithdrawal> withdrawals,
  required pw.Font bold,
}) {
  final weekId = weekIdFor(weekStart);
  final weekEnd = weekEndFor(weekStart);
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
  if (relevant.isEmpty) return pw.SizedBox();

  var count = 0;
  final rows = <List<String>>[];
  final histories = <({String title, List<ScheduleEntry> schedule})>[];
  for (final item in relevant) {
    count++;
    final itemWithdrawals = withdrawals
        .where((w) =>
            w.depositId == item.id && isOnOrBeforeWeek(w.linkedWeekId, weekId))
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
      _dayFormat.format(item.dateDeposited),
      _money(item.amount),
      schedule.isEmpty ? '-' : '${schedule.length}',
      item.preferredWithdrawalAmount > 0
          ? _money(item.preferredWithdrawalAmount)
          : '-',
      schedule.isEmpty ? '-' : _dayFormat.format(schedule.last.date),
      _money(thisWeekAmount),
    ]);
    if (schedule.isNotEmpty) {
      histories.add((
        title: '$title  -  ${_dayFormat.format(item.dateDeposited)}  -  '
            '${_money(item.amount)}',
        schedule: schedule,
      ));
    }
  }

  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 10),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _itemsTable(
          columnHeaders: const [
            'Description',
            'Date deposited',
            'Amount',
            'Instalments',
            'Instalment amt',
            'Last instalment',
            "This week's withdrawal",
          ],
          columnWidths: {
            0: const pw.FlexColumnWidth(2.2),
            1: const pw.FlexColumnWidth(1.3),
            2: const pw.FlexColumnWidth(1.1),
            3: const pw.FlexColumnWidth(0.9),
            4: const pw.FlexColumnWidth(1.3),
            5: const pw.FlexColumnWidth(1.3),
            6: const pw.FlexColumnWidth(1.5),
          },
          rows: rows,
          bold: bold,
        ),
        _scheduleHistory(
            heading: 'Withdrawal history', histories: histories, bold: bold),
      ],
    ),
  );
}
