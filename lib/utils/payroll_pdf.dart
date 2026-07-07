import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/payment_summary.dart';
import '../models/payroll_payslip.dart';
import '../utils/payroll_calculator.dart' as calc;

abstract final class _Company {
  static const String name = 'Community Life Media';
  static const String addressLine1 = 'Unit 69, 27, 7th Avenue';
  static const String addressLine2 = 'The Old Timber Yard, Maitland';
  static const String addressLine3 = 'Cape Town, 7405';
  static const String contactPhone = '+27 71 909 0839';
}

final _dateFormat = DateFormat('d MMMM yyyy');
final _dayFormat = DateFormat('EEE d MMM');

String _money(double v) => 'R ${v.toStringAsFixed(2)}';

/// Generates one distributor's wage slip for a payroll week — header,
/// 7-day breakdown, transport/advance lines, net total, signature footer.
Future<Uint8List> generatePayslipPdf({
  required PayrollPayslip payslip,
  required DateTime weekStart,
  required DateTime weekEnd,
  required DateTime payDate,
}) async {
  final regular = await PdfGoogleFonts.openSansRegular();
  final bold = await PdfGoogleFonts.openSansBold();

  final baseStyle = pw.TextStyle(font: regular, fontSize: 10);
  final boldStyle = pw.TextStyle(font: bold, fontSize: 10);
  final mutedStyle =
      pw.TextStyle(font: regular, fontSize: 9, color: PdfColors.grey700);

  final dates = payslip.dailyEntries.keys.toList()..sort();

  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(_Company.name,
              style: pw.TextStyle(font: bold, fontSize: 16)),
          pw.Text(_Company.addressLine1, style: mutedStyle),
          pw.Text(_Company.addressLine2, style: mutedStyle),
          pw.Text(_Company.addressLine3, style: mutedStyle),
          pw.Text('Tel: ${_Company.contactPhone}', style: mutedStyle),
          pw.SizedBox(height: 16),
          pw.Text('Wage slip', style: pw.TextStyle(font: bold, fontSize: 14)),
          pw.SizedBox(height: 8),
          _kv('Name', payslip.distributorName, boldStyle, baseStyle),
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
              for (final key in dates) _dayRow(payslip, key, baseStyle),
            ],
          ),
          pw.SizedBox(height: 16),
          _summaryRow('Total gross wage', payslip.grossWage, boldStyle),
          if (payslip.transportEligibleSnapshot)
            _summaryRow(
              'Transport (${payslip.transportTrips} trips x '
              '${_money(payslip.transportFareSnapshot)})',
              -payslip.transportDeduction,
              baseStyle,
            ),
          if (payslip.isDeductingAdvanceThisWeek)
            _summaryRow(
              'Advance deduction'
              '${payslip.advanceDeductionNote.isNotEmpty ? ' (${payslip.advanceDeductionNote})' : ''}',
              -payslip.advanceDeductionAmount,
              baseStyle,
            ),
          pw.Divider(color: PdfColors.grey400),
          _summaryRow('Total net wage', payslip.netWage,
              pw.TextStyle(font: bold, fontSize: 13)),
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
                      child: pw.Text('Employee signature', style: mutedStyle)),
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
    ),
  );

  return doc.save();
}

/// Generates the week's payment-run summary — every distributor's net pay
/// + bank details + a grand total (replaces the old sheet's "banking" tab).
Future<Uint8List> generatePaymentSummaryPdf(PaymentSummary summary) async {
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
          pw.Text(_Company.name,
              style: pw.TextStyle(font: bold, fontSize: 16)),
          pw.SizedBox(height: 4),
          pw.Text('Payment summary', style: pw.TextStyle(font: bold, fontSize: 14)),
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
              2: pw.FlexColumnWidth(2),
              3: pw.FlexColumnWidth(1.5),
              4: pw.FlexColumnWidth(1.2),
              5: pw.FlexColumnWidth(1.3),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey800),
                children: [
                  _cell('Distributor', style: _headStyle(bold)),
                  _cell('Method', style: _headStyle(bold)),
                  _cell('Bank / account', style: _headStyle(bold)),
                  _cell('Branch code', style: _headStyle(bold)),
                  _cell('Net pay', style: _headStyle(bold)),
                  _cell('', style: _headStyle(bold)),
                ],
              ),
              for (final line in summary.lines)
                pw.TableRow(children: [
                  _cell(line.distributorName, style: baseStyle),
                  _cell(line.paymentMethod, style: baseStyle),
                  _cell(
                    [
                      if (line.bankName != null) line.bankName!,
                      if (line.bankAccountHolder != null)
                        line.bankAccountHolder!,
                      if (line.bankAccountNumber != null)
                        line.bankAccountNumber!,
                    ].join(' · '),
                    style: baseStyle,
                  ),
                  _cell(line.bankBranchCode ?? '', style: baseStyle),
                  _cell(_money(line.netWage), style: baseStyle),
                  _cell('', style: baseStyle),
                ]),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              'Total: ${_money(summary.totalNet)}',
              style: pw.TextStyle(font: bold, fontSize: 13),
            ),
          ),
        ],
      ),
    ),
  );

  return doc.save();
}

pw.Widget _kv(
    String label, String value, pw.TextStyle labelStyle, pw.TextStyle valueStyle) {
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

pw.TableRow _dayRow(PayrollPayslip payslip, String key, pw.TextStyle style) {
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
      : (entry.specialCode ?? '${entry.flyerSets ?? 0} sets');
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
