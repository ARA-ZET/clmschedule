import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/collection_job.dart';
import '../models/dropsheet_day.dart';
import '../providers/dropsheet_provider.dart' show kUnassignedSectionId;
import 'dropsheet_maps.dart';

/// Generates a PDF for [day] on [date].
///
/// Layout:
/// - A4 landscape, one page per driver section (unassigned section skipped).
/// - Each page has a black header bar with the driver's name, date, and
///   vehicle/trailer info.
/// - A table follows with columns:
///     # | Label | Notes | Start | Location | Contact | Tel
///   where Start, Contact, and Tel have fixed widths; the rest share the
///   remaining width proportionally (Label:Notes:Location = 2:2:3).
/// - Row height is unconstrained — text wraps fully so nothing is clipped.
Future<Uint8List> generateDropsheetPdf(DropsheetDay day, DateTime date) async {
  // Load fonts once for the whole document.
  final regular = await PdfGoogleFonts.openSansRegular();
  final bold = await PdfGoogleFonts.openSansBold();
  final italic = await PdfGoogleFonts.openSansItalic();

  final doc = pw.Document();
  final dateLabel = DateFormat('d MMMM yyyy').format(date);

  for (final section in day.sections) {
    // Skip the virtual "unassigned" holding section — it has no driver.
    if (section.id == kUnassignedSectionId) continue;

    // Pre-compute section-level metadata (needed by header + footer).
    final vehicleParts = <String>[
      if (section.vehicle != null) section.vehicle!.displayName,
      if (section.trailer != null && section.trailer != TrailerType.noTrailer)
        section.trailer!.displayName,
    ];
    final vehicleLabel = vehicleParts.join(' + ');
    final nonMandatory = section.tasks.where((t) => !t.isMandatory).length;
    String routeSummary = '';
    if (section.routeDistanceMeters > 0) {
      final km = (section.routeDistanceMeters / 1000).toStringAsFixed(1);
      final min = (section.routeDurationSeconds / 60).round();
      routeSummary = '$km km · ${_formatMinutes(min)}';
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(30),
        // Header repeats on every page: black title bar + column headers.
        header: (ctx) => _buildPageHeader(
          section: section,
          dateLabel: dateLabel,
          vehicleLabel: vehicleLabel,
          bold: bold,
          regular: regular,
        ),
        // Footer repeats on every page: stop count + route + page number.
        footer: (ctx) => _buildPageFooter(
          nonMandatory: nonMandatory,
          routeSummary: routeSummary,
          pageNumber: ctx.pageNumber,
          pagesCount: ctx.pagesCount,
          regular: regular,
        ),
        build: (ctx) => _buildSectionContent(
          section: section,
          regular: regular,
          bold: bold,
          italic: italic,
        ),
      ),
    );
  }

  if (doc.document.pdfPageList.pages.isEmpty) {
    // Fallback: no sections at all — generate a single blank "no data" page.
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(30),
        build: (_) => pw.Center(
          child: pw.Text(
            'No driver sections on this dropsheet.',
            style: pw.TextStyle(font: bold, fontSize: 16),
          ),
        ),
      ),
    );
  }

  return doc.save();
}

String _formatMinutes(int totalMinutes) {
  if (totalMinutes < 60) return '${totalMinutes}min';
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}min';
}

// ── Shared column layout (A4 landscape, 30pt margins ≈ 782pt usable) ─────────
const Map<int, pw.TableColumnWidth> _columnWidths = {
  0: pw.FixedColumnWidth(28),
  1: pw.FlexColumnWidth(2),
  2: pw.FlexColumnWidth(2),
  3: pw.FixedColumnWidth(58),
  4: pw.FlexColumnWidth(3),
  5: pw.FixedColumnWidth(100),
  6: pw.FixedColumnWidth(82),
};

const pw.TableBorder _tableBorder = pw.TableBorder(
  left: pw.BorderSide(color: PdfColor(0.85, 0.85, 0.85), width: 0.5),
  right: pw.BorderSide(color: PdfColor(0.85, 0.85, 0.85), width: 0.5),
  top: pw.BorderSide(color: PdfColor(0.85, 0.85, 0.85), width: 0.5),
  bottom: pw.BorderSide(color: PdfColor(0.85, 0.85, 0.85), width: 0.5),
  horizontalInside:
      pw.BorderSide(color: PdfColor(0.85, 0.85, 0.85), width: 0.5),
  verticalInside: pw.BorderSide(color: PdfColor(0.85, 0.85, 0.85), width: 0.5),
);

// ── Page header (repeats on every page via MultiPage.header) ─────────────────
pw.Widget _buildPageHeader({
  required DropsheetDriverSection section,
  required String dateLabel,
  required String vehicleLabel,
  required pw.Font bold,
  required pw.Font regular,
}) {
  final hStyle = pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white);

  pw.Widget hCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
        child: pw.Text(text, style: hStyle),
      );

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      // Black title bar
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: const pw.BoxDecoration(color: PdfColors.black),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(
              (section.driverName.isEmpty ? 'DRIVER' : section.driverName)
                  .toUpperCase(),
              style: pw.TextStyle(
                  font: bold, fontSize: 13, color: PdfColors.white),
            ),
            pw.Text(
              (vehicleLabel.isEmpty ? '—' : vehicleLabel).toUpperCase(),
              style: pw.TextStyle(
                  font: bold, fontSize: 13, color: PdfColors.white),
            ),
            pw.Text(
              dateLabel.toUpperCase(),
              style: pw.TextStyle(
                  font: bold, fontSize: 13, color: PdfColors.white),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 8),
      // Column header row — repeats on every page
      pw.Table(
        columnWidths: _columnWidths,
        border: _tableBorder,
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey800),
            children: [
              hCell('#'),
              hCell('Label'),
              hCell('Notes'),
              hCell('Start'),
              hCell('Location'),
              hCell('Contact'),
              hCell('Tel'),
            ],
          ),
        ],
      ),
    ],
  );
}

// ── Page footer (repeats on every page via MultiPage.footer) ─────────────────
pw.Widget _buildPageFooter({
  required int nonMandatory,
  required String routeSummary,
  required int pageNumber,
  required int pagesCount,
  required pw.Font regular,
}) {
  final style =
      pw.TextStyle(font: regular, fontSize: 8, color: PdfColors.grey600);
  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 6),
    child: pw.Row(
      children: [
        pw.Text('$nonMandatory stop${nonMandatory == 1 ? '' : 's'}',
            style: style),
        if (routeSummary.isNotEmpty)
          pw.Text('  ·  $routeSummary', style: style),
        pw.Spacer(),
        if (pagesCount > 1) pw.Text('$pageNumber / $pagesCount', style: style),
        pw.SizedBox(width: 8),
        pw.Text(
          'CLM Schedule',
          style: pw.TextStyle(
              font: regular, fontSize: 8, color: PdfColors.grey400),
        ),
      ],
    ),
  );
}

// ── Section content (data rows, flows across pages automatically) ─────────────
List<pw.Widget> _buildSectionContent({
  required DropsheetDriverSection section,
  required pw.Font regular,
  required pw.Font bold,
  required pw.Font italic,
}) {
  final baseStyle = pw.TextStyle(font: regular, fontSize: 9);
  final boldStyle = pw.TextStyle(font: bold, fontSize: 9);
  final mutedStyle =
      pw.TextStyle(font: regular, fontSize: 9, color: PdfColors.grey700);
  final italicStyle =
      pw.TextStyle(font: italic, fontSize: 9, color: PdfColors.grey600);

  pw.Widget cell(String text, {pw.TextStyle? style, bool softWrap = true}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: pw.Text(text, softWrap: softWrap, style: style ?? baseStyle),
      );

  final dataRows = <pw.TableRow>[];
  for (var i = 0; i < section.tasks.length; i++) {
    final task = section.tasks[i];
    final jobLabel = task.job.isNotEmpty
        ? task.job
        : DropsheetMaps.defaultJobLabel(task.type);
    final locationLabel = DropsheetMaps.locationLabel(task);
    final rowBg =
        i.isEven ? PdfColors.white : const PdfColor.fromInt(0xFFF8F8F8);
    dataRows.add(
      pw.TableRow(
        decoration: pw.BoxDecoration(color: rowBg),
        children: [
          cell('${i + 1}', style: boldStyle, softWrap: false),
          cell(jobLabel, style: task.isMandatory ? mutedStyle : boldStyle),
          cell(task.details, style: baseStyle),
          cell(task.startTime, style: baseStyle, softWrap: false),
          cell(locationLabel,
              style: locationLabel.isEmpty ? italicStyle : baseStyle),
          cell(task.contact, style: baseStyle),
          cell(task.tel, style: baseStyle),
        ],
      ),
    );
  }

  return [
    pw.Table(
      columnWidths: _columnWidths,
      border: _tableBorder,
      children: dataRows,
    ),
  ];
}
