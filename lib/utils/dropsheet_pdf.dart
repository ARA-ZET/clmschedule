import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/dropsheet_day.dart';
import '../models/dropsheet_task.dart';
import '../providers/dropsheet_provider.dart' show kUnassignedSectionId;
import 'dropsheet_layout.dart';
import 'dropsheet_maps.dart';
import 'shared_drop_points.dart';

/// Generates a PDF for [day] on [date].
///
/// Layout:
/// - A4 landscape, one page per driver section (unassigned section skipped).
///   The Own transport list prints on a page of its own, unnumbered.
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
    // An empty Own transport list is not worth a page.
    if (section.isOwnTransport && section.tasks.isEmpty) continue;

    // Pre-compute section-level metadata (needed by header + footer).
    final vehicleLabel = section.vehicleTrailerLabel;
    // Stops as the driver makes them: a shared drop point is one stop.
    final nonMandatory = _stopCount(section);
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
          countLabel: section.isOwnTransport
              ? '$nonMandatory on own transport'
              : '$nonMandatory stop${nonMandatory == 1 ? '' : 's'}',
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

// ── Column layout (A4 landscape, 30pt margins ≈ 782pt usable) ───────────────
// Same columns as the on-screen sheet; widths tuned for paper
// (DropsheetColumn.printWidth).
final Map<int, pw.TableColumnWidth> _columnWidths = {
  for (final c in DropsheetColumn.values)
    c.index: c.printWidth.points != null
        ? pw.FixedColumnWidth(c.printWidth.points!)
        : pw.FlexColumnWidth(c.printWidth.flex!),
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
              for (final c in DropsheetColumn.values) hCell(c.title),
            ],
          ),
        ],
      ),
    ],
  );
}

// ── Page footer (repeats on every page via MultiPage.footer) ─────────────────
pw.Widget _buildPageFooter({
  required String countLabel,
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
        pw.Text(countLabel, style: style),
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

  // Numbers match the day planner map's pins; a shared drop point prints as
  // one numbered stop with a line per distributor, like its pin.
  final numbers = dropsheetRowNumbers(section);
  final sharedStops = sharedStopsInSection(section);
  // A Junk & Stuff / Happy Sun job prints as one stop with its crew under it.
  final sites = jobSitesInSection(section);
  final printed = <String>{};
  // The Job cell: the label, then — as on screen — a line saying the route
  // gets there early (blue) or late (red) for a booked time.
  pw.Widget jobCell(DropsheetTask t, String label, pw.TextStyle style) {
    final note = t.bookingTimingNote;
    if (note == null) return cell(label, style: style);
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(label, style: style),
          pw.SizedBox(height: 2),
          pw.Text(note,
              style: pw.TextStyle(
                  font: bold,
                  fontSize: 8,
                  color: t.appointmentLateMinutes > 0
                      ? PdfColors.red800
                      : PdfColors.blue800)),
        ],
      ),
    );
  }

  // The Location cell: a blue map link, as on screen (tappable in the PDF).
  pw.Widget locationCell(DropsheetTask t, {pw.TextStyle? style}) {
    final label = DropsheetMaps.locationLabel(t);
    final links = DropsheetMaps.linksFor(t);
    if (links.isEmpty) {
      return cell(label, style: label.isEmpty ? italicStyle : style);
    }
    final linkStyle = (style ?? baseStyle).copyWith(color: PdfColors.blue800);
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          for (final link in links)
            pw.UrlLink(
              destination: link.url,
              child: pw.Text(links.length == 1 ? label : link.label,
                  style: linkStyle),
            ),
        ],
      ),
    );
  }

  final dataRows = <pw.TableRow>[];
  var shade = 0;
  for (final task in section.tasks) {
    if (printed.contains(task.id)) continue;
    final rowBg = shade.isEven
        ? PdfColors.white
        : const PdfColor.fromInt(0xFFF8F8F8);
    shade++;
    final number = numbers[task.id]?.toString() ?? '';

    // "Leave and start pickups": a blue band, as on screen.
    if (task.typeData['isPickupDivider'] == true) {
      printed.add(task.id);
      dataRows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE3F2FD)),
        children: [
          cell('', style: baseStyle),
          cell(task.job.isNotEmpty ? task.job : kPickupDividerLabel,
              style: pw.TextStyle(
                  font: bold, fontSize: 9, color: PdfColors.blue800)),
          for (var i = 0; i < DropsheetColumn.values.length - 2; i++)
            cell('', style: baseStyle),
        ],
      ));
      continue;
    }

    // Two-address job: a Loading line, then an Offloading line, each with
    // its own time, address and map pin number — as on screen.
    if (task.isTwoStop) {
      printed.add(task.id);
      final nums = task.twoStopNumbers(numbers[task.id]);
      pw.Widget addressCell(String address) {
        final links = DropsheetMaps.twoStopLinks(address);
        if (links.isEmpty) return cell(address, style: baseStyle);
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: pw.UrlLink(
            destination: links.first.url,
            child: pw.Text(address,
                style: baseStyle.copyWith(color: PdfColors.blue800)),
          ),
        );
      }

      dataRows
        ..add(pw.TableRow(
          decoration: pw.BoxDecoration(color: rowBg),
          children: [
            cell(nums.loading?.toString() ?? '',
                style: boldStyle, softWrap: false),
            jobCell(task, task.loadingLineLabel, boldStyle),
            cell(task.detailsText, style: baseStyle),
            cell(task.startTime, style: baseStyle, softWrap: false),
            addressCell(task.loadingAddress),
            cell(task.contact, style: baseStyle),
            cell(task.tel, style: baseStyle),
          ],
        ))
        ..add(pw.TableRow(
          decoration: pw.BoxDecoration(color: rowBg),
          children: [
            cell(nums.offload?.toString() ?? '',
                style: boldStyle, softWrap: false),
            cell(task.offloadingLineLabel, style: boldStyle),
            cell('', style: baseStyle),
            cell(task.offloadTime, style: baseStyle, softWrap: false),
            addressCell(task.offloadAddress),
            cell('', style: baseStyle),
            cell('', style: baseStyle),
          ],
        ));
      continue;
    }

    final site = sites[task.id];
    if (site != null) {
      printed.addAll(site.taskIds);
      final job = site.job;
      dataRows.add(
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE0F2F1)),
          children: [
            cell(numbers[job.id]?.toString() ?? number,
                style: boldStyle, softWrap: false),
            jobCell(job, job.displayJob, boldStyle),
            cell(job.detailsText, style: baseStyle),
            cell(job.startTime, style: baseStyle, softWrap: false),
            locationCell(job, style: boldStyle),
            cell(job.contact, style: baseStyle),
            cell(job.tel, style: baseStyle),
          ],
        ),
      );
      for (final member in site.crew) {
        dataRows.add(
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.white),
            children: [
              cell('', style: baseStyle),
              cell('-  Crew: ${crewMemberName(member)}', style: baseStyle),
              cell(member.detailsText, style: baseStyle),
              cell('', style: baseStyle),
              cell('', style: baseStyle),
              cell(stopPersonName(member), style: boldStyle),
              cell(member.tel, style: baseStyle),
            ],
          ),
        );
      }
      continue;
    }

    final group = sharedStops[task.id];
    if (group == null) {
      printed.add(task.id);
      dataRows.add(
        pw.TableRow(
          // Fixed Inspect / Pack / Leave / Arrive rows: amber, as on screen.
          decoration: pw.BoxDecoration(
              color: task.isMandatory
                  ? const PdfColor.fromInt(0xFFFFF8E1)
                  : rowBg),
          children: [
            cell(number, style: boldStyle, softWrap: false),
            jobCell(task, task.displayJob, boldStyle),
            cell(task.detailsText, style: baseStyle),
            cell(task.startTime, style: baseStyle, softWrap: false),
            locationCell(task),
            cell(task.contact, style: baseStyle),
            cell(task.tel, style: baseStyle),
          ],
        ),
      );
      continue;
    }

    // Shared drop point: the stop, then one line per distributor.
    printed.addAll(group.map((t) => t.id));
    final first = group.first;
    final what = first.type == DropsheetTaskType.pickUp ? 'pick-up' : 'drop';
    const groupBg = PdfColor.fromInt(0xFFE0F2F1);
    dataRows.add(
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: groupBg),
        children: [
          cell(numbers[first.id]?.toString() ?? number,
              style: boldStyle, softWrap: false),
          cell('Shared $what point · ${group.length} people',
              style: boldStyle),
          cell('', style: baseStyle),
          cell(first.startTime, style: baseStyle, softWrap: false),
          locationCell(first, style: boldStyle),
          cell('', style: baseStyle),
          cell('', style: baseStyle),
        ],
      ),
    );
    for (final member in group) {
      dataRows.add(
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.white),
          children: [
            cell('', style: baseStyle),
            jobCell(member, '-  ${member.displayJob}', baseStyle),
            cell(member.detailsText, style: baseStyle),
            cell('', style: baseStyle),
            cell(member.shortWorkArea, style: mutedStyle),
            cell(member.contact, style: boldStyle),
            cell(member.tel, style: baseStyle),
          ],
        ),
      );
    }
  }

  return [
    pw.Table(
      columnWidths: _columnWidths,
      border: _tableBorder,
      children: dataRows,
    ),
  ];
}

/// Stops [section] makes: its non-fixed rows (not the pick-up divider),
/// counting each shared drop point and job site once.
int _stopCount(DropsheetDriverSection section) {
  final shared = sharedStopsInSection(section);
  final sites = jobSitesInSection(section);
  final seen = <String>{};
  var count = 0;
  for (final t in section.tasks) {
    if (t.isMandatory || seen.contains(t.id)) continue;
    if (t.typeData['isPickupDivider'] == true) continue; // not a stop
    seen.addAll(sites[t.id]?.taskIds ?? (shared[t.id] ?? [t]).map((m) => m.id));
    count++;
  }
  return count;
}
