// track_editor/services/te_report_pdf.dart
//
// The client-facing Flyer Handout Report.
//
// Written for the client who paid for the flyers. Every section and table is
// organised by DATE; the per-person views — the team table and each
// promoter's flyers/speed timeline — sit inside the date they belong to.
//
// Wording, agreed for client-facing use: the people are "promoters" and the
// work is a "flyer handout" — never "distributor" or "distribution". Clock
// start and finish times are not shown anywhere: shifts are agreed as
// 08:00–17:00, and traffic or logistics can move them, so the report states
// how long flyers were handed out rather than exactly when. Stopped and
// break time are likewise kept out of the client's view.
//
// Kept short on purpose:
//   * Summary   the title and, when the campaign ran more than one day, one
//               row per day.
//   * Each day  one compact block — headline figures, flyers per hour, the
//               team's figures, then each promoter under their own heading:
//               half-width maps zoomed in on each position they worked
//               (linked to the client's interactive map) and a flyers +
//               speed timeline, two promoters a page — and proof photos. Days flow one after another rather than each
//               claiming pages of their own.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../models/payroll_settings.dart';
import '../models/te_promoter_day.dart';
import '../utils/te_track_analysis.dart';
import 'te_place_names.dart';
import 'te_report_maps.dart';

final _longDayFmt = DateFormat('EEEE d MMMM yyyy');
final _shortDayFmt = DateFormat('d MMM yyyy');
final _rowDayFmt = DateFormat('EEE d MMM yyyy');
final _clockFmt = DateFormat('HH:mm');

const String _reportTitle = 'Flyer Handout Report';

/// The on-screen chart palette (`TEChartColors`), re-declared as PdfColor —
/// the `pdf` canvas can't take dart:ui's Color. Only the handouts hue is used
/// for data; everything else is ink and surface.
abstract class _C {
  static const page = PdfColor.fromInt(0xFFFFFFFF);
  static const band = PdfColor.fromInt(0xFFF7F7F5);
  static const grid = PdfColor.fromInt(0xFFE1E0D9);
  static const axis = PdfColor.fromInt(0xFFC3C2B7);
  static const muted = PdfColor.fromInt(0xFF898781);
  static const secondaryInk = PdfColor.fromInt(0xFF52514E);
  static const primaryInk = PdfColor.fromInt(0xFF0B0B0B);

  /// Flyers — the one data series in the report.
  static const flyers = PdfColor.fromInt(0xFFEB6834);

  /// Walking speed — the second series on each promoter's timeline — and
  /// the route line on each promoter's map.
  static const speed = PdfColor.fromInt(0xFF2A78D6);
}

/// The bold face, for chart labels drawn straight onto the canvas (they
/// can't go through `pw.TextStyle`). Loaded once per document.
pw.Font? _boldFont;

/// The same face as the low-level [PdfFont] that `drawString` takes. A
/// `pw.Font` only resolves to one against a `pw.Context`, which a
/// `CustomPaint` painter doesn't get, so it is resolved in the page's build
/// callback, which runs before that page's painters.
PdfFont? _boldPdfFont;

// A4 width minus the 32pt side margins.
const double _contentW = 531;
const pw.EdgeInsets _pageMargin = pw.EdgeInsets.fromLTRB(32, 30, 32, 24);

/// Builds the report PDF for [days] — already the exact set the user
/// selected. Promoter days are merged by date; nothing is filtered out.
/// [photosByDate] is keyed by calendar date (midnight); photos for a date
/// with no selected days are simply not printed.
///
/// [placeNames] names the spots from [teWorkSpots], keyed by [tePlaceKey];
/// spots with no name print as "—" rather than holding the report up.
/// [whereOverrides] is "Where worked" text typed in by hand, keyed by
/// [TEPromoterDay.key], one place per line; it replaces the looked-up names
/// for that shift.
///
/// [mapImages] is the street map behind each promoter's maps, keyed by
/// [teReportMapKey] (see [fetchReportMaps]); a map without one still gets
/// its route drawn, on a blank background. [photosByDate] should
/// already be compressed ([teCompressProofPhotos]) — they go in as given. [mapLinks] is
/// the client's interactive map for each promoter day, by the same key; the
/// map and a link under it open it.
///
/// [company] supplies the business details printed under the logo — the
/// same company settings the payslips use, so an address or phone change
/// made in-app reaches the report too. Defaults when not given.
Future<Uint8List> buildReportPdf(
  List<TEPromoterDay> days, {
  Map<DateTime, List<TEProofPhoto>> photosByDate = const {},
  PayrollSettings? company,
  Map<String, TEPlaceName> placeNames = const {},
  Map<String, String> whereOverrides = const {},
  Map<String, Uint8List> mapImages = const {},
  Map<String, String> mapLinks = const {},
}) async {
  final regular = await PdfGoogleFonts.openSansRegular();
  final bold = await PdfGoogleFonts.openSansBold();
  _boldFont = bold;
  final logo = await _loadLogo();
  final maps = _MapInputs(mapImages, mapLinks);
  final dates = _ReportDate.group(days, photosByDate);
  final business = company ?? PayrollSettings.defaults();
  final generated = DateTime.now();

  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: _pageMargin,
    maxPages: 400,
    footer: (context) => _footer(context, generated),
    build: (context) {
      _boldPdfFont = _boldFont?.getFont(context);
      return [
        _title(dates, logo, business),
        if (dates.length > 1) ...[
          pw.SizedBox(height: 16),
          _section(
            'Daily summary',
            splittable: true,
            child: _dailyTable(dates),
          ),
        ],
        for (final d in dates) ...[
          pw.SizedBox(height: 22),
          ..._dateBlock(d, placeNames, whereOverrides, maps),
        ],
      ];
    },
  ));

  return doc.save();
}

/// The street maps and client-map links for each promoter day, by
/// [TEPromoterDay.key].
class _MapInputs {
  final Map<String, Uint8List> images;
  final Map<String, String> links;
  const _MapInputs(this.images, this.links);
}

Future<pw.MemoryImage?> _loadLogo() async {
  try {
    final data = await rootBundle.load('assets/clm-official-logo.jpeg');
    return pw.MemoryImage(data.buffer.asUint8List());
  } catch (_) {
    // A missing logo must never cost the client their report.
    return null;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// ONE DATE — every promoter's shift that day, merged
// ════════════════════════════════════════════════════════════════════════════

class _ReportDate {
  final DateTime date;

  /// Every flyer counted, timestamped or not.
  final int flyers;

  /// Flyer presses with no time in the GPX: in the total, not in the chart.
  final int untimed;

  final List<DateTime> handoutTimes;

  /// First to last flyer, or the recorded tracklog window when no flyer
  /// carried a time. Null with neither. Only the length between them is
  /// printed ([handoutTime]) — never the clock times themselves.
  final DateTime? from;
  final DateTime? to;

  final List<TEProofPhoto> photos;

  /// Each promoter's shift that day, by name — for the team table.
  final List<TEPromoterDay> shifts;

  const _ReportDate({
    required this.date,
    required this.flyers,
    required this.untimed,
    required this.handoutTimes,
    required this.from,
    required this.to,
    required this.photos,
    required this.shifts,
  });

  int get promoters => shifts.map((s) => s.distributor.id).toSet().length;

  /// How long flyers were handed out: first flyer to last.
  Duration get handoutTime =>
      from == null || to == null ? Duration.zero : to!.difference(from!);

  /// Flyers per clock hour, from the first flyer's hour to the last's, with
  /// empty hours in between kept so the chart's spacing is honest.
  List<(DateTime, int)> get hourly {
    if (handoutTimes.isEmpty) return const [];
    DateTime hourOf(DateTime t) => DateTime(t.year, t.month, t.day, t.hour);
    final counts = <DateTime, int>{};
    for (final t in handoutTimes) {
      counts[hourOf(t)] = (counts[hourOf(t)] ?? 0) + 1;
    }
    final out = <(DateTime, int)>[];
    for (var h = hourOf(handoutTimes.first);
        !h.isAfter(hourOf(handoutTimes.last));
        h = h.add(const Duration(hours: 1))) {
      out.add((h, counts[h] ?? 0));
    }
    return out;
  }

  (DateTime, int)? get busiestHour {
    final h = hourly;
    if (h.isEmpty) return null;
    return h.reduce((a, b) => b.$2 > a.$2 ? b : a);
  }

  static List<_ReportDate> group(
    List<TEPromoterDay> days,
    Map<DateTime, List<TEProofPhoto>> photosByDate,
  ) {
    final byDate = <DateTime, List<TEPromoterDay>>{};
    for (final d in days) {
      final key = DateTime(d.date.year, d.date.month, d.date.day);
      byDate.putIfAbsent(key, () => []).add(d);
    }
    final keys = byDate.keys.toList()..sort();
    return [
      for (final k in keys) _merge(k, byDate[k]!, photosByDate[k] ?? const []),
    ];
  }

  static _ReportDate _merge(
    DateTime date,
    List<TEPromoterDay> shifts,
    List<TEProofPhoto> photos,
  ) {
    var flyers = 0;
    var untimed = 0;
    final times = <DateTime>[];
    DateTime? trackFrom;
    DateTime? trackTo;

    for (final s in shifts) {
      final a = s.analysis;
      flyers += a.totalHandouts;
      untimed += a.untimedHandouts;
      times.addAll(a.handoutTimes);
      if (!a.isEmpty) {
        if (trackFrom == null || a.start.isBefore(trackFrom)) {
          trackFrom = a.start;
        }
        if (trackTo == null || a.end.isAfter(trackTo)) trackTo = a.end;
      }
    }

    times.sort();

    return _ReportDate(
      date: date,
      flyers: flyers,
      untimed: untimed,
      handoutTimes: times,
      from: times.isNotEmpty ? times.first : trackFrom,
      to: times.isNotEmpty ? times.last : trackTo,
      photos: photos,
      shifts: [...shifts]
        ..sort((a, b) => a.distributor.name.compareTo(b.distributor.name)),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SHARED CHROME
// ════════════════════════════════════════════════════════════════════════════

pw.TextStyle _style({
  double size = 8.5,
  bool bold = false,
  PdfColor color = _C.primaryInk,
  double? letterSpacing,
}) =>
    pw.TextStyle(
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      color: color,
      letterSpacing: letterSpacing,
    );

pw.Widget _eyebrow(String text) => pw.Text(
      text.toUpperCase(),
      style: _style(size: 6.8, bold: true, color: _C.muted, letterSpacing: 0.5),
    );

/// Keeps [child] on one page with nothing to split it: `MultiPage` spans a
/// vertical Flex, and `Container`/`Padding` hand `canSpan` straight to their
/// child, but a horizontal Flex never spans — so a one-child `Row` moves to
/// the next page whole rather than leaving a heading behind.
pw.Widget _keepTogether(pw.Widget child) => pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [pw.Expanded(child: child)],
    );

pw.Widget _section(
  String title, {
  required pw.Widget child,
  bool splittable = false,
}) {
  final column = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(title, style: _style(size: 10.5, bold: true)),
      pw.SizedBox(height: 6),
      child,
    ],
  );
  return splittable ? column : _keepTogether(column);
}

pw.Widget _footer(pw.Context context, DateTime generated) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 8),
      padding: const pw.EdgeInsets.only(top: 5),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _C.grid, width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
              '$_reportTitle  ·  generated ${_shortDayFmt.format(generated)}',
              style: _style(size: 6.8, color: _C.muted)),
          pw.Text('Page ${context.pageNumber} of ${context.pagesCount}',
              style: _style(size: 6.8, color: _C.muted)),
        ],
      ),
    );

pw.Widget _cell(
  String text, {
  bool bold = false,
  bool right = false,
  PdfColor color = _C.primaryInk,
}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: pw.Text(
        text,
        style: _style(size: 8, bold: bold, color: color),
        textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
      ),
    );

pw.Widget _head(String text, {bool right = false}) => pw.Padding(
      padding: const pw.EdgeInsets.fromLTRB(4, 0, 4, 3),
      child: right
          ? pw.Align(alignment: pw.Alignment.centerRight, child: _eyebrow(text))
          : _eyebrow(text),
    );

pw.TableRow _headRow(List<pw.Widget> cells) => pw.TableRow(
      repeat: true,
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _C.axis, width: 0.5)),
      ),
      children: cells,
    );

pw.BoxDecoration _rowDecoration(int i) => pw.BoxDecoration(
      color: i.isOdd ? _C.band : _C.page,
      border:
          const pw.Border(bottom: pw.BorderSide(color: _C.grid, width: 0.4)),
    );

String _thousands(int v) {
  final s = v.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// "5h 20m" / "45m" — minutes are as fine as a client report needs.
String _hours(Duration d) {
  if (d.inMinutes < 1) return '—';
  if (d.inHours == 0) return '${d.inMinutes}m';
  return '${d.inHours}h ${d.inMinutes.remainder(60).toString().padLeft(2, '0')}m';
}

// ════════════════════════════════════════════════════════════════════════════
// SUMMARY
// ════════════════════════════════════════════════════════════════════════════

/// Used when the saved company settings carry no email of their own — the
/// sales address the public CLM advert page already publishes.
const String _fallbackEmail = 'sales@communitylifemedia.co.za';
const String _website = 'www.communitylifemedia.co.za';

pw.Widget _title(
  List<_ReportDate> dates,
  pw.MemoryImage? logo,
  PayrollSettings company,
) {
  final range = dates.isEmpty
      ? ''
      : dates.length == 1
          ? _longDayFmt.format(dates.first.date)
          : '${_shortDayFmt.format(dates.first.date)} – '
              '${_shortDayFmt.format(dates.last.date)}';

  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(_reportTitle, style: _style(size: 18, bold: true)),
            pw.SizedBox(height: 2),
            pw.Text(range, style: _style(size: 9.5, color: _C.secondaryInk)),
            pw.SizedBox(height: 6),
            pw.Container(width: 34, height: 2, color: _C.flyers),
          ],
        ),
      ),
      _businessBlock(logo, company),
    ],
  );
}

/// Logo with the business's details beneath it. The block sits at the right
/// of the header, but its lines are left-aligned so they read as one column.
/// VAT number is left off on purpose: the business doesn't charge VAT, and a
/// VAT number on a client document reads as though it does.
pw.Widget _businessBlock(pw.MemoryImage? logo, PayrollSettings company) {
  final email =
      company.companyEmail.isNotEmpty ? company.companyEmail : _fallbackEmail;
  final lines = <String>[
    if (company.companyName.isNotEmpty) company.companyName,
    if (company.companyRegistrationNo.isNotEmpty)
      'Reg. No. ${company.companyRegistrationNo}',
    ...company.companyAddress
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty),
    if (company.companyPhone.isNotEmpty) 'Tel: ${company.companyPhone}',
    'Email: $email',
    _website,
  ];

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      if (logo != null) ...[
        pw.Image(logo, height: 38, fit: pw.BoxFit.contain),
        pw.SizedBox(height: 5),
      ],
      for (var i = 0; i < lines.length; i++)
        pw.Text(
          lines[i],
          textAlign: pw.TextAlign.left,
          style: i == 0 && company.companyName.isNotEmpty
              ? _style(size: 7.5, bold: true)
              : _style(size: 7, color: _C.secondaryInk),
        ),
    ],
  );
}

pw.Widget _stat(String value, String label) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(value, style: _style(size: 12, bold: true)),
        pw.Text(label, style: _style(size: 7, color: _C.muted)),
      ],
    );

pw.Widget _divider() => pw.Container(
      width: 0.5,
      height: 22,
      color: _C.axis,
      margin: const pw.EdgeInsets.symmetric(horizontal: 12),
    );

pw.Widget _dailyTable(List<_ReportDate> dates) {
  final total = dates.fold<int>(0, (a, d) => a + d.flyers);
  final totalTime =
      dates.fold<Duration>(Duration.zero, (a, d) => a + d.handoutTime);
  return pw.Table(
    columnWidths: const {
      0: pw.FlexColumnWidth(2.2),
      1: pw.FlexColumnWidth(1.8),
      2: pw.FlexColumnWidth(1.1),
      3: pw.FlexColumnWidth(1.1),
    },
    children: [
      _headRow([
        _head('Date'),
        _head('Handout time'),
        _head('Promoters', right: true),
        _head('Flyers handed out', right: true),
      ]),
      for (var i = 0; i < dates.length; i++)
        pw.TableRow(decoration: _rowDecoration(i), children: [
          _cell(_rowDayFmt.format(dates[i].date), bold: true),
          _cell(_hours(dates[i].handoutTime)),
          _cell('${dates[i].promoters}', right: true),
          _cell(_thousands(dates[i].flyers), right: true, bold: true),
        ]),
      pw.TableRow(
        decoration: const pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: _C.axis, width: 0.7)),
        ),
        children: [
          _cell('Total', bold: true, color: _C.secondaryInk),
          _cell(_hours(totalTime), bold: true),
          pw.SizedBox(),
          _cell(_thousands(total), right: true, bold: true),
        ],
      ),
    ],
  );
}

// ════════════════════════════════════════════════════════════════════════════
// ONE DAY
// ════════════════════════════════════════════════════════════════════════════

List<pw.Widget> _dateBlock(_ReportDate d, Map<String, TEPlaceName> places,
    Map<String, String> overrides, _MapInputs maps) {
  final hourly = d.hourly;
  final busiest = d.busiestHour;

  // Heading, figures and chart travel together so a date never starts at the
  // foot of a page without anything under it.
  final head = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(_longDayFmt.format(d.date),
          style: _style(size: 12.5, bold: true)),
      pw.SizedBox(height: 4),
      pw.Container(height: 1, color: _C.flyers),
      pw.SizedBox(height: 8),
      pw.Row(
        children: [
          _stat(_thousands(d.flyers), 'Flyers handed out'),
          _divider(),
          _stat(_hours(d.handoutTime), 'Handout time'),
          _divider(),
          _stat('${d.promoters}', d.promoters == 1 ? 'Promoter' : 'Promoters'),
          if (busiest != null && busiest.$2 > 0) ...[
            _divider(),
            _stat(
              '${_clockFmt.format(busiest.$1)} – '
                  '${_clockFmt.format(busiest.$1.add(const Duration(hours: 1)))}',
              'Busiest hour (${_thousands(busiest.$2)} flyers)',
            ),
          ],
        ],
      ),
      if (hourly.isNotEmpty) ...[
        pw.SizedBox(height: 12),
        _eyebrow('Flyers per hour'),
        pw.SizedBox(height: 4),
        pw.CustomPaint(
          size: const PdfPoint(_contentW, 84),
          painter: (canvas, size) => _paintColumns(
            canvas,
            size,
            [
              for (final h in hourly)
                '${_clockFmt.format(h.$1)} – '
                    '${_clockFmt.format(h.$1.add(const Duration(hours: 1)))}',
            ],
            [for (final h in hourly) h.$2],
          ),
        ),
      ],
      if (d.untimed > 0) ...[
        pw.SizedBox(height: 4),
        pw.Text(
          '${_thousands(d.untimed)} flyers were recorded without a time; they '
          'are included in the total but not in the chart.',
          style: _style(size: 7, color: _C.muted),
        ),
      ],
    ],
  );

  return [
    _keepTogether(head),
    if (d.shifts.isNotEmpty) ...[
      pw.SizedBox(height: 12),
      _keepTogether(_teamTable(d, places, overrides)),
    ],
    ..._promoterBlocks(d, places, overrides, maps),
    if (d.photos.isNotEmpty) ...[
      // Clear room after the last promoter's figures, so the photos read
      // as their own section.
      pw.SizedBox(height: 40),
      ..._photos(d),
    ],
  ];
}

/// The places a promoter mainly worked: handout clusters (one per
/// intersection, from their waypoints) carrying a real share of the day —
/// at least 10 flyers and 5% of the shift — biggest first, at most three.
/// A shift with clusters but none that large still gets its biggest one.
List<TEHotspot> teWorkSpots(TETrackAnalysis a) {
  if (a.hotspots.isEmpty) return const [];
  final floor = math.max(10, (a.handoutTimes.length * 0.05).ceil());
  final sorted = [...a.hotspots]
    ..sort((x, y) => y.handouts.compareTo(x.handouts));
  final big = sorted.where((h) => h.handouts >= floor).take(3).toList();
  return big.isEmpty ? [sorted.first] : big;
}

/// The looked-up intersection for each spot where [a] was worked. Empty when
/// nothing came back.
List<String> teAutoWhere(TETrackAnalysis a, Map<String, TEPlaceName> places) {
  final names = <String>[];
  for (final spot in teWorkSpots(a)) {
    final name =
        places[tePlaceKey(spot.centre.latitude, spot.centre.longitude)]
            ?.intersection;
    if (name != null && !names.contains(name)) names.add(name);
  }
  return names;
}

/// The "Where worked" cell: each place worked, one per line — the hand-typed
/// text when there is some, otherwise the looked-up names.
pw.Widget _whereCell(TEPromoterDay day, Map<String, TEPlaceName> places,
    Map<String, String> overrides) {
  final override = overrides[day.key];
  final intersections = override != null
      ? [
          for (final line in override.split('\n'))
            if (line.trim().isNotEmpty) line.trim(),
        ]
      : teAutoWhere(day.analysis, places);
  if (intersections.isEmpty) return _cell('—');

  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final i in intersections) pw.Text(i, style: _style(size: 7.5)),
      ],
    ),
  );
}

/// Each promoter's figures for the day. The average counts only time spent
/// working an intersection, so walking between spots doesn't dilute it.
pw.Widget _teamTable(_ReportDate d, Map<String, TEPlaceName> places,
    Map<String, String> overrides) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.SizedBox(height: 4),
      pw.Table(
        columnWidths: const {
          0: pw.FlexColumnWidth(1.6),
          1: pw.FlexColumnWidth(2.5),
          2: pw.FlexColumnWidth(1.35),
          3: pw.FlexColumnWidth(0.5),
          4: pw.FlexColumnWidth(1.55),
        },
        children: [
          _headRow([
            _head('Promoter'),
            _head('Where worked'),
            _head('Flyers handed out', right: true),
            _head('Km', right: true),
            _head('Avg per working hr', right: true),
          ]),
          for (var i = 0; i < d.shifts.length; i++)
            () {
              final a = d.shifts[i].analysis;
              return pw.TableRow(
                decoration: _rowDecoration(i),
                verticalAlignment: pw.TableCellVerticalAlignment.top,
                children: [
                  _cell(d.shifts[i].distributor.name, bold: true),
                  _whereCell(d.shifts[i], places, overrides),
                  _cell(_thousands(a.totalHandouts), right: true, bold: true),
                  _cell(a.isEmpty ? '—' : a.distanceKm.toStringAsFixed(1),
                      right: true),
                  _cell(
                    a.ratePerHourWorking == null
                        ? '—'
                        : a.ratePerHourWorking!.toStringAsFixed(0),
                    right: true,
                  ),
                ],
              );
            }(),
        ],
      ),
    ],
  );
}

// ── Each promoter under their own heading: maps, link, timeline ─────────────

/// Each half-width map, and the gap between two side by side.
const double _mapGap = 10;
const double _mapW = (_contentW - _mapGap) / 2;
const double _mapH = _mapW * teMapHeight / teMapWidth;

List<pw.Widget> _promoterBlocks(_ReportDate d, Map<String, TEPlaceName> places,
    Map<String, String> overrides, _MapInputs maps) {
  final blocks = <(TEPromoterDay, TEMapRoute, List<TEReportMap>, int)>[];
  for (final s in d.shifts) {
    final route = teMapRoute(s);
    final shown = teReportMaps(route);
    if (shown.isEmpty && s.analysis.isEmpty) continue;
    final more = teMapPositions(route).length - shown.length;
    blocks.add((s, route, shown, math.max(0, more)));
  }
  if (blocks.isEmpty) return const [];
  final charted = [
    for (final b in blocks)
      if (!b.$1.analysis.isEmpty) b.$1.analysis,
  ];

  return [
    for (var i = 0; i < blocks.length; i++) ...[
      // Room above each heading marks where one promoter's section starts.
      pw.SizedBox(height: 22),
      () {
        final (shift, route, shown, more) = blocks[i];
        final a = shift.analysis;
        final link = maps.links[shift.key] ?? '';
        final hasStreetMaps = [
          for (var m = 0; m < shown.length; m++)
            maps.images[teReportMapKey(shift, m)],
        ].every((img) => img != null);
        final cells = [
          for (var m = 0; m < shown.length; m++)
            _mapCell(
              route,
              shown[m],
              maps.images[teReportMapKey(shift, m)],
              link,
              _positionCaption(shift, shown[m], m, places, overrides),
            ),
        ];

        return _keepTogether(pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _promoterHeading(shift),
            pw.SizedBox(height: 8),
            if (cells.length >= 2) ...[
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  cells[0],
                  pw.SizedBox(width: _mapGap),
                  cells[1],
                ],
              ),
              pw.SizedBox(height: 5),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Expanded(
                    child: pw.Wrap(
                      spacing: 14,
                      crossAxisAlignment: pw.WrapCrossAlignment.center,
                      children: [
                        _routeLegend(route, hasStreetMap: hasStreetMaps),
                        if (more > 0)
                          pw.Text(
                              '+$more more position${more == 1 ? '' : 's'} '
                              'on the interactive map',
                              style: _style(size: 7, color: _C.muted)),
                      ],
                    ),
                  ),
                  if (link.isNotEmpty) _mapLink(link),
                ],
              ),
            ] else if (cells.length == 1)
              // One position: the map on the left, where and how to see
              // more beside it.
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  cells[0],
                  pw.SizedBox(width: _mapGap + 6),
                  pw.Expanded(
                    child: _mapSidePanel(shift, route, places, overrides,
                        link: link, hasStreetMap: hasStreetMaps),
                  ),
                ],
              ),
            if (!a.isEmpty) ...[
              pw.SizedBox(height: 8),
              pw.CustomPaint(
                size: const PdfPoint(_contentW, _promoterTimelineH),
                painter: (canvas, size) => _paintTimeline(canvas, size, a),
              ),
            ],
            // The timeline legend rides with the last promoter so it can't be
            // stranded at the top of the next page.
            if (i == blocks.length - 1 && charted.isNotEmpty) ...[
              pw.SizedBox(height: 6),
              _timelineLegend(charted),
            ],
          ],
        ));
      }(),
    ],
  ];
}

/// "Talent – 13 Oct 2026" and the day in figures, bold, over an orange
/// rule — the heading of the promoter's section.
pw.Widget _promoterHeading(TEPromoterDay shift) {
  final a = shift.analysis;
  final stats = [
    '${_thousands(a.totalHandouts)} flyers',
    if (!a.isEmpty) '${a.distanceKm.toStringAsFixed(1)} km walked',
    if (!a.isEmpty)
      'top speed ${_topWalkingSpeed(a).toStringAsFixed(1)} km/h',
  ].join('   ·   ');
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Expanded(
            child: pw.RichText(
              text: pw.TextSpan(
                style: _style(size: 12.5, bold: true),
                children: [
                  pw.TextSpan(text: shift.distributor.name),
                  pw.TextSpan(
                    text: '  –  ${_shortDayFmt.format(shift.date)}',
                    style: _style(
                        size: 12.5, bold: true, color: _C.secondaryInk),
                  ),
                ],
              ),
            ),
          ),
          pw.Text(stats,
              style: _style(size: 8.5, bold: true, color: _C.secondaryInk)),
        ],
      ),
      pw.SizedBox(height: 3),
      pw.Container(height: 1, color: _C.flyers),
    ],
  );
}

/// One half-width map with its caption: the intersection and how many
/// flyers went out there.
pw.Widget _mapCell(TEMapRoute route, TEReportMap map, Uint8List? image,
    String link, String? caption) {
  final flyers = map.position?.flyers.length;
  final mapWidget = _routeMap(route, map.frame, image);
  return pw.SizedBox(
    width: _mapW,
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        link.isEmpty
            ? mapWidget
            : pw.UrlLink(destination: link, child: mapWidget),
        if (caption != null || flyers != null) ...[
          pw.SizedBox(height: 3),
          pw.RichText(
            maxLines: 1,
            overflow: pw.TextOverflow.clip,
            text: pw.TextSpan(children: [
              if (caption != null)
                pw.TextSpan(
                    text: caption,
                    style: _style(size: 7.5, bold: true)),
              if (flyers != null)
                pw.TextSpan(
                    text: '${caption == null ? '' : '   ·   '}'
                        '${_thousands(flyers)} flyers here',
                    style: _style(size: 7.5, color: _C.muted)),
            ]),
          ),
        ],
      ],
    ),
  );
}

/// The intersection map [index] of [shift] is zoomed in on: the typed-in
/// "Where worked" line in the same place when there is typed text, else the
/// looked-up name of the work spot at that position.
String? _positionCaption(TEPromoterDay shift, TEReportMap map, int index,
    Map<String, TEPlaceName> places, Map<String, String> overrides) {
  final typed = overrides[shift.key];
  if (typed != null) {
    final lines = [
      for (final l in typed.split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    return index < lines.length ? lines[index] : null;
  }
  final position = map.position;
  if (position == null) return null;
  for (final spot in teWorkSpots(shift.analysis)) {
    final c = (spot.centre.latitude, spot.centre.longitude);
    if (teMetres(c, position.centre) > 300) continue;
    final name = places[tePlaceKey(c.$1, c.$2)]?.intersection;
    if (name != null) return name;
  }
  return null;
}

/// Beside a lone map: where the promoter worked, the map key, and the link
/// to the interactive map.
pw.Widget _mapSidePanel(TEPromoterDay shift, TEMapRoute route,
    Map<String, TEPlaceName> places, Map<String, String> overrides,
    {required String link, required bool hasStreetMap}) {
  final typed = overrides[shift.key];
  final where = typed != null
      ? [
          for (final l in typed.split('\n'))
            if (l.trim().isNotEmpty) l.trim(),
        ]
      : teAutoWhere(shift.analysis, places);
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _eyebrow('Where worked'),
      pw.SizedBox(height: 4),
      if (where.isEmpty)
        pw.Text('—', style: _style(size: 9))
      else
        for (final w in where)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Text(w, style: _style(size: 9, bold: true)),
          ),
      pw.SizedBox(height: 14),
      _eyebrow('On the map'),
      pw.SizedBox(height: 4),
      _routeLegend(route, hasStreetMap: hasStreetMap),
      if (link.isNotEmpty) ...[
        pw.SizedBox(height: 14),
        _eyebrow('See it live'),
        pw.SizedBox(height: 4),
        _mapLink(link),
      ],
    ],
  );
}

/// "Interactive map: maps.communitylifemedia.co.za/map/x7Kp2m",
/// clickable, and short enough to type in from a printed copy.
pw.Widget _mapLink(String url) {
  final shown = url.replaceFirst(RegExp(r'^https?://'), '');
  return pw.UrlLink(
    destination: url,
    child: pw.RichText(
      text: pw.TextSpan(
        style: _style(size: 7.5, color: _C.secondaryInk),
        children: [
          const pw.TextSpan(text: 'Interactive map:  '),
          pw.TextSpan(
            text: shown,
            style: _style(size: 7.5, bold: true, color: _C.speed).copyWith(
              decoration: pw.TextDecoration.underline,
              decorationColor: _C.speed,
            ),
          ),
        ],
      ),
    ),
  );
}

/// One legend for all of the day's timelines, listing only what appears.
pw.Widget _timelineLegend(List<TETrackAnalysis> analyses) {
  return pw.Wrap(
    spacing: 14,
    runSpacing: 4,
    children: [
      _legendItem(_C.speed, 'Speed (km/h, left scale)', line: true),
      _legendItem(_C.flyers, 'Flyers handed out (running total, right scale)',
          line: true),
    ],
  );
}

pw.Widget _legendItem(
  PdfColor color,
  String label, {
  bool line = false,
}) =>
    pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.CustomPaint(
          size: PdfPoint(line ? 11 : 8, 8),
          painter: (canvas, size) {
            if (line) {
              canvas
                ..setStrokeColor(color)
                ..setLineWidth(1.4)
                ..drawLine(0, size.y / 2, size.x, size.y / 2)
                ..strokePath();
            } else {
              canvas
                ..setFillColor(_tint(color, 0.30))
                ..drawRect(0, 0, size.x, size.y)
                ..fillPath();
            }
          },
        ),
        pw.SizedBox(width: 4),
        pw.Text(label, style: _style(size: 7, color: _C.secondaryInk)),
      ],
    );

/// "Photos – 22 Oct 2026" over an orange rule, then the date's photos in
/// rows. The heading and the first two rows travel together so the heading
/// is never left alone at the foot of a page; later rows flow on.
List<pw.Widget> _photos(_ReportDate d) {
  // One shared height, each photo as wide as its own aspect ratio needs, so
  // nothing the client took is cropped away. Small enough to keep the report
  // short, big enough to see what was handed out and where.
  const gutter = 6.0;
  const double h = 110;
  // Laid out in rows here rather than by a Wrap so the page can break
  // between rows and the heading can be kept with the first of them.
  final rows = <List<pw.Widget>>[];
  var rowW = 0.0;
  for (final photo in d.photos) {
    final image = pw.MemoryImage(photo.bytes);
    final w = math.min(_contentW, h * (image.width ?? 4) / (image.height ?? 3));
    if (rows.isEmpty || rowW + gutter + w > _contentW) {
      rows.add([]);
      rowW = w;
    } else {
      rowW += gutter + w;
    }
    rows.last.add(_photo(image, h));
  }
  pw.Widget row(List<pw.Widget> photos) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: gutter),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < photos.length; i++) ...[
              if (i > 0) pw.SizedBox(width: gutter),
              photos[i],
            ],
          ],
        ),
      );
  return [
    _keepTogether(pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _photosHeading(d),
        pw.SizedBox(height: 2),
        for (final r in rows.take(2)) row(r),
      ],
    )),
    for (final r in rows.skip(2)) row(r),
  ];
}

/// Styled like [_promoterHeading]: bold title, the date beside it in grey,
/// an orange rule beneath.
pw.Widget _photosHeading(_ReportDate d) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.RichText(
          text: pw.TextSpan(
            style: _style(size: 12.5, bold: true),
            children: [
              const pw.TextSpan(text: 'Photos'),
              pw.TextSpan(
                text: '  –  ${_shortDayFmt.format(d.date)}',
                style: _style(size: 12.5, bold: true, color: _C.secondaryInk),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 3),
        pw.Container(height: 1, color: _C.flyers),
      ],
    );

/// [image] at height [h] and its natural width — the width already accounts
/// for EXIF rotation. A panorama too wide for the page is scaled down to the
/// content width instead, keeping its shape.
pw.Widget _photo(pw.MemoryImage image, double h) {
  final iw = image.width ?? 4, ih = image.height ?? 3;
  var w = h * iw / ih;
  if (w > _contentW) {
    h = _contentW * ih / iw;
    w = _contentW;
  }
  return pw.ClipRRect(
    horizontalRadius: 3,
    verticalRadius: 3,
    child: pw.Image(image, width: w, height: h, fit: pw.BoxFit.contain),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// ROUTE MAPS — half the page wide, zoomed in on one position each
// ════════════════════════════════════════════════════════════════════════════

pw.Widget _routeMap(TEMapRoute route, TEMapFrame frame, Uint8List? image) {
  const w = _mapW;
  const h = _mapH;
  return pw.ClipRRect(
    horizontalRadius: 3,
    verticalRadius: 3,
    child: pw.Container(
      width: w,
      height: h,
      color: _C.band,
      child: pw.Stack(
        children: [
          if (image != null)
            pw.Image(pw.MemoryImage(image),
                width: w, height: h, fit: pw.BoxFit.fill),
          pw.CustomPaint(
            size: PdfPoint(w, h),
            painter: (canvas, size) => _paintRoute(canvas, size, route, frame),
          ),
        ],
      ),
    ),
  );
}

/// The route as a blue line with a white casing, so it reads on any street
/// colour. Flyers aren't marked — the route says enough, and the maps are
/// already zoomed in on where they went out. The `pdf` canvas has its
/// origin bottom-left, so map pixels are flipped.
void _paintRoute(
  PdfGraphics canvas,
  PdfPoint size,
  TEMapRoute route,
  TEMapFrame frame,
) {
  final k = size.x / frame.width;
  (double, double) at((double, double) p) {
    final (x, y) = frame.toPixel(p.$1, p.$2);
    return (x * k, size.y - y * k);
  }

  // A map zoomed in on one position clips the rest of the day away; what
  // lies well off it isn't written into the file at all.
  const margin = 24.0;
  bool onMap((double, double) q) =>
      q.$1 > -margin &&
      q.$1 < size.x + margin &&
      q.$2 > -margin &&
      q.$2 < size.y + margin;

  // Each segment once, thinned to points at least half a point apart — a
  // full shift is thousands of fixes, far more than the line can show — and
  // broken where it runs off the map.
  final lines = <List<(double, double)>>[];
  for (final seg in route.segments) {
    var line = <(double, double)>[];
    (double, double)? prev;
    for (final p in seg) {
      final q = at(p);
      final inside = onMap(q);
      if (!inside && (prev == null || !onMap(prev))) {
        if (line.length >= 2) lines.add(line);
        line = [];
        prev = q;
        continue;
      }
      if (line.isEmpty && prev != null) line.add(prev);
      prev = q;
      if (line.isNotEmpty &&
          (q.$1 - line.last.$1).abs() + (q.$2 - line.last.$2).abs() < 0.5) {
        continue;
      }
      line.add(q);
    }
    if (line.length >= 2) lines.add(line);
  }

  void strokeLines(PdfColor color, double width) {
    canvas
      ..setStrokeColor(color)
      ..setLineWidth(width)
      ..setLineJoin(PdfLineJoin.round)
      ..setLineCap(PdfLineCap.round);
    for (final line in lines) {
      canvas.moveTo(line.first.$1, line.first.$2);
      for (final q in line.skip(1)) {
        canvas.lineTo(q.$1, q.$2);
      }
    }
    canvas.strokePath();
  }

  strokeLines(_C.page, 3.4);
  strokeLines(_C.speed, 1.7);
}

pw.Widget _routeLegend(TEMapRoute route, {required bool hasStreetMap}) {
  return pw.Wrap(
    spacing: 14,
    runSpacing: 4,
    children: [
      if (route.segments.isNotEmpty)
        _legendItem(_C.speed, 'Route walked', line: true),
      if (!hasStreetMap)
        pw.Text('Street map unavailable',
            style: _style(size: 7, color: _C.muted)),
    ],
  );
}

// ════════════════════════════════════════════════════════════════════════════
// TIMELINE — handouts over speed, one clock
// ════════════════════════════════════════════════════════════════════════════

/// Under a promoter's maps — short enough that two promoters' sections
/// share an A4 page.
const double _promoterTimelineH = 76;

/// One plot per promoter with both lines drawn from the same zero baseline
/// and overlapping: speed reads off the left-hand scale, flyers' running
/// total off the right-hand one. The two scales are independent — where the
/// lines cross means nothing on its own — which is why each scale is labelled
/// on its own side and the legend says which line uses which.
///
/// The time axis counts from 0 at the start of the shift ("1h", "2h", …) —
/// no clock times, in line with the rest of the report. Working stops are
/// shaded behind the plot.
void _paintTimeline(PdfGraphics canvas, PdfPoint size, TETrackAnalysis a) {
  const double axisW = 24;
  const double xAxisH = 11;
  const double captionH = 9;
  final left = axisW;
  final right = size.x - axisW;
  final plotW = right - left;
  final bottom = xAxisH;
  final top = size.y - captionH;
  if (plotW <= 0 || top <= bottom) return;

  final spanMs = math.max(a.elapsed.inMilliseconds, 1);
  double xOf(DateTime t) =>
      left + t.difference(a.start).inMilliseconds / spanMs * plotW;
  final speedMax = math.max(_topWalkingSpeed(a), 1.0);
  double ySpeed(double v) =>
      bottom + (v / speedMax).clamp(0.0, 1.0) * (top - bottom);
  final flyerMax = math.max(a.handoutTimes.length, 1);
  double yFlyers(int n) =>
      bottom + (n / flyerMax).clamp(0.0, 1.0) * (top - bottom);

  // Working stops, behind the plot.
  for (final st in a.stops.where((s) => s.kind == TEStopKind.handout)) {
    final x1 = xOf(st.start).clamp(left, right);
    final x2 = xOf(st.end).clamp(left, right);
    if (x2 - x1 < 0.4) continue;
    canvas
      ..setFillColor(_tint(_C.flyers, 0.12))
      ..drawRect(x1, bottom, x2 - x1, top - bottom)
      ..fillPath();
  }

  // Shared zero baseline, a midline and a top line; speed labelled on the
  // left, flyers on the right, at the same heights.
  for (var i = 0; i <= 2; i++) {
    final y = bottom + (top - bottom) * i / 2;
    canvas
      ..setStrokeColor(i == 0 ? _C.axis : _C.grid)
      ..setLineWidth(i == 0 ? 0.5 : 0.35)
      ..drawLine(left, y, right, y)
      ..strokePath();
    final speedLabel = i == 0 ? '0' : _trimNumber(speedMax * i / 2);
    final flyerLabel = i == 0 ? '0' : _thousands((flyerMax * i / 2).round());
    _drawText(canvas, speedLabel, left - 4, y - 2,
        align: _TextAlign.right, color: _C.muted, size: 6);
    _drawText(canvas, flyerLabel, right + 4, y - 2,
        align: _TextAlign.left, color: _C.muted, size: 6);
  }

  // Speed, walking pace only: a reading over [_maxPlottedKmh] is a vehicle or
  // a GPS jump, not a flyer handout, so it is left off and the line lifts
  // over it. Across a long stretch with no trackpoints the line drops to zero
  // rather than cutting a diagonal through time nobody walked; a short hole
  // just joins the points either side.
  final samples = a.samples;
  canvas
    ..setStrokeColor(_C.speed)
    ..setLineWidth(0.8);
  var penDown = false;
  for (var i = 0; i < samples.length; i++) {
    final cur = samples[i];
    if (cur.speedKmh > _maxPlottedKmh) {
      if (penDown) canvas.strokePath();
      penDown = false;
      continue;
    }
    final x = xOf(cur.time);
    final y = ySpeed(cur.speedKmh);
    if (!penDown) {
      canvas.moveTo(x, y);
      penDown = true;
      continue;
    }
    final prev = samples[i - 1].time;
    if (a.spansGap(prev, cur.time) &&
        reportBreaks(a)
            .any((b) => !b.$1.isAfter(prev) && !b.$2.isBefore(cur.time))) {
      canvas
        ..lineTo(xOf(prev), bottom)
        ..lineTo(x, bottom);
    }
    canvas.lineTo(x, y);
  }
  if (penDown) canvas.strokePath();

  // Flyers: running-total step line, drawn last so the dense speed trace
  // never hides it.
  final times = a.handoutTimes;
  if (times.isNotEmpty) {
    canvas
      ..setLineJoin(PdfLineJoin.round)
      ..setStrokeColor(_C.flyers)
      ..setLineWidth(1.2)
      ..moveTo(xOf(a.start), yFlyers(0));
    for (var i = 0; i < times.length; i++) {
      final x = xOf(times[i]);
      canvas
        ..lineTo(x, yFlyers(i))
        ..lineTo(x, yFlyers(i + 1));
    }
    canvas
      ..lineTo(xOf(a.end), yFlyers(times.length))
      ..strokePath();
  }

  _drawText(canvas, 'SPEED KM/H', left, top + 2.5,
      align: _TextAlign.left, color: _C.muted, size: 5.8, bold: true);
  _drawText(canvas, 'FLYERS', right, top + 2.5,
      align: _TextAlign.right, color: _C.muted, size: 5.8, bold: true);

  // Time since the shift began. Every hour on a normal shift; every half hour
  // on a short one, every two on a very long one.
  final elapsed = a.elapsed;
  final step = elapsed > const Duration(hours: 12)
      ? const Duration(hours: 2)
      : elapsed >= const Duration(hours: 3)
          ? const Duration(hours: 1)
          : const Duration(minutes: 30);
  for (var t = Duration.zero; t <= elapsed; t += step) {
    final x = xOf(a.start.add(t));
    _drawText(canvas, _elapsedLabel(t), x, 2.5,
        align: t == Duration.zero
            ? _TextAlign.left
            : x > right - 8
                ? _TextAlign.right
                : _TextAlign.center,
        color: _C.muted,
        size: 6);
  }
}

/// "5", "2.5" — a scale label without a pointless ".0".
String _trimNumber(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// "0h", "30m", "1h", "1h 30m".
String _elapsedLabel(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (m == 0) return '${h}h';
  if (h == 0) return '${m}m';
  return '${h}h ${m}m';
}

/// A stretch with no handouts has to run longer than this to be reported as
/// a break. Anything shorter is ordinary work: waiting for the lights,
/// moving between corners.
const Duration _breakAfter = Duration(minutes: 15);

/// How far a promoter may drift and still count as not moving. GPS jitter
/// at a standstill stays well inside this; walking leaves it in under a
/// minute.
const double _stillRadiusM = 50;

/// A distributor's breaks may add up to this much before the report starts
/// questioning them. Past it, stretches where they kept moving are taken back
/// out, leaving only the breaks where they genuinely stood still.
const Duration _breakBudget = Duration(minutes: 75);

final _breaksCache = Expando<List<(DateTime, DateTime)>>();

/// The break periods the report prints, oldest first, merged where they
/// touch. Worked out in two passes:
///
///   1. Every stretch of more than [_breakAfter] between two handouts is a
///      break, moving or not, plus every still break from [_stillBreaks]
///      (which also catches the quiet ends of a shift and long holes in the
///      tracklog).
///   2. If those add up to more than [_breakBudget], the report goes back
///      and removes the ones where the distributor was moving, keeping only
///      the still breaks.
@visibleForTesting
List<(DateTime, DateTime)> reportBreaks(TETrackAnalysis a) =>
    _breaksCache[a] ??= _findBreaks(a);

List<(DateTime, DateTime)> _findBreaks(TETrackAnalysis a) {
  final still = _stillBreaks(a);

  final quiet = <(DateTime, DateTime)>[];
  final times = a.handoutTimes;
  for (var i = 1; i < times.length; i++) {
    if (times[i].difference(times[i - 1]) > _breakAfter) {
      quiet.add((times[i - 1], times[i]));
    }
  }

  final all = _mergePeriods([...quiet, ...still]);
  return _totalOf(all) > _breakBudget ? still : all;
}

Duration _totalOf(List<(DateTime, DateTime)> periods) =>
    periods.fold(Duration.zero, (sum, p) => sum + p.$2.difference(p.$1));

List<(DateTime, DateTime)> _mergePeriods(List<(DateTime, DateTime)> periods) {
  final sorted = [...periods]..sort((x, y) => x.$1.compareTo(y.$1));
  final merged = <(DateTime, DateTime)>[];
  for (final p in sorted) {
    if (merged.isNotEmpty && !p.$1.isAfter(merged.last.$2)) {
      final last = merged.removeLast();
      merged.add((last.$1, p.$2.isAfter(last.$2) ? p.$2 : last.$2));
    } else {
      merged.add(p);
    }
  }
  return merged;
}

/// Breaks where the distributor did not move: stretches longer than
/// [_breakAfter] with no handouts in which
///
///   * every trackpoint stays within [_stillRadiusM] of where the stretch
///     began — a detected "stop" alone isn't enough, since on real loggers
///     the stop detection can span a whole day of slow walking;
///   * or a motion-triggered logger went quiet in one place, which is exactly
///     what standing still looks like on that device;
///   * or there are no trackpoints at all (logger off, no signal) — the
///     report presents those as breaks, never as tracking dropping out.
List<(DateTime, DateTime)> _stillBreaks(TETrackAnalysis a) {
  final found = <(DateTime, DateTime)>[];
  void consider(DateTime from, DateTime to) {
    if (to.difference(from) > _breakAfter) found.add((from, to));
  }

  for (final g in a.gaps) {
    consider(g.start, g.end);
  }

  final pts = a.samples.where((p) => !p.synthetic).toList();
  final times = a.handoutTimes;
  var h = 0;
  var i = 0;
  while (i < pts.length) {
    final anchor = pts[i];
    // The first handout after the anchor ends any still run that starts here.
    while (h < times.length && !times[h].isAfter(anchor.time)) {
      h++;
    }
    final nextHandout = h < times.length ? times[h] : null;
    bool still(TESample p) =>
        _metres(anchor.lat, anchor.lon, p.lat, p.lon) <= _stillRadiusM;

    var j = i;
    while (j + 1 < pts.length) {
      final next = pts[j + 1];
      if (nextHandout != null && !next.time.isBefore(nextHandout)) break;
      // A hole in the tracklog is judged on its own above.
      if (a.spansGap(pts[j].time, next.time)) break;
      if (!still(next)) break;
      j++;
    }

    var end = pts[j].time;
    // Stopped by a handout while still in place: they were standing there
    // right up until that flyer went out.
    if (nextHandout != null &&
        j + 1 < pts.length &&
        !pts[j + 1].time.isBefore(nextHandout) &&
        still(pts[j + 1])) {
      end = nextHandout;
    }
    consider(anchor.time, end);

    i = j > i ? j : i + 1;
  }

  return _mergePeriods(found);
}

double _metres(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(x)));
}

/// Speeds above this are left off the charts: flyers are handed out at
/// walking pace, and anything faster is a lift, a taxi or a GPS jump.
const double _maxPlottedKmh = 10;

/// The fastest walking-pace reading — what the chart's scale and the "top
/// speed" caption use, so a single drive can't flatten the rest of the line.
double _topWalkingSpeed(TETrackAnalysis a) => a.samples
    .where((p) => p.speedKmh <= _maxPlottedKmh)
    .fold(0.0, (m, p) => math.max(m, p.speedKmh));

/// PDF fills drop alpha, so a wash is mixed against the white page instead.
PdfColor _tint(PdfColor c, double t) =>
    PdfColor(1 - t * (1 - c.red), 1 - t * (1 - c.green), 1 - t * (1 - c.blue));

// ════════════════════════════════════════════════════════════════════════════
// COLUMN CHART
// ════════════════════════════════════════════════════════════════════════════

/// One series of labelled columns — flyers per day, or per hour. A value on
/// every cap and no y-axis: with this few columns the labels are the scale.
void _paintColumns(
  PdfGraphics canvas,
  PdfPoint size,
  List<String> labels,
  List<int> values,
) {
  if (values.isEmpty) return;
  final peak = values.fold<int>(0, math.max);
  if (peak == 0) return;

  const double labelH = 13;
  const double valueH = 11;
  final base = labelH;
  final plotH = size.y - labelH - valueH;
  // Cap how wide one column's slot may be, so a two-column chart doesn't
  // maroon its bars half a page apart.
  final slot = math.min(size.x / values.length, 62.0);
  final barW = math.min(22.0, math.max(3.0, slot * 0.62));
  // Thin the labels out by their actual width, so wide keys like
  // "08:00 – 09:00" never run into each other.
  final font = canvas.defaultFont!;
  final widest = labels.fold<double>(
      0, (m, l) => math.max(m, font.stringMetrics(l).width * 6.5));
  final labelStep = math.max(1, ((widest + 6) / slot).ceil());
  final valueLabels = values.length <= 20;

  for (var i = 0; i < values.length; i++) {
    final cx = slot * i + slot / 2;
    final h = values[i] / peak * plotH;
    _fillColumn(canvas, cx - barW / 2, base, barW, h, _C.flyers);
    if (valueLabels && values[i] > 0) {
      _drawText(canvas, _thousands(values[i]), cx, base + h + 2.5,
          align: _TextAlign.center,
          color: _C.primaryInk,
          size: 6.8,
          bold: true);
    }
    if (i % labelStep == 0) {
      _drawText(canvas, labels[i], cx, 3,
          align: _TextAlign.center, color: _C.muted, size: 6.5);
    }
  }

  canvas
    ..setStrokeColor(_C.axis)
    ..setLineWidth(0.6)
    ..drawLine(0, base, slot * values.length, base)
    ..strokePath();
}

/// Square at the baseline, rounded at the data end.
void _fillColumn(
  PdfGraphics canvas,
  double x,
  double base,
  double w,
  double h,
  PdfColor color,
) {
  if (w <= 0 || h <= 0) return;
  final r = math.min(2.5, math.min(w / 2, h));
  final top = base + h;
  const k = 0.5523;
  canvas
    ..setFillColor(color)
    ..moveTo(x, base)
    ..lineTo(x, top - r)
    ..curveTo(x, top - r + k * r, x + r - k * r, top, x + r, top)
    ..lineTo(x + w - r, top)
    ..curveTo(x + w - r + k * r, top, x + w, top - r + k * r, x + w, top - r)
    ..lineTo(x + w, base)
    ..fillPath();
}

enum _TextAlign { left, right, center }

/// A chart label drawn straight onto the canvas, in the document's own fonts.
void _drawText(
  PdfGraphics canvas,
  String text,
  double x,
  double y, {
  required _TextAlign align,
  required PdfColor color,
  required double size,
  bool bold = false,
}) {
  final font = (bold ? _boldPdfFont : null) ?? canvas.defaultFont!;
  final width = font.stringMetrics(text).width * size;
  final dx = switch (align) {
    _TextAlign.left => x,
    _TextAlign.right => x - width,
    _TextAlign.center => x - width / 2,
  };
  canvas
    ..setColor(color)
    ..drawString(font, size, text, dx, y);
}
