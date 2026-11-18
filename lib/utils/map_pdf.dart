import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/job.dart';

/// One map picture for the PDF: the page's image and orientation, and
/// where it sits in an overview-plus-sections set.
class DistributionMapPdfPage {
  final Uint8List imageBytes;
  final bool isLandscape;

  /// 0 for a single page or the overview, otherwise 1..[sectionCount].
  final int section;
  final int sectionCount;

  const DistributionMapPdfPage({
    required this.imageBytes,
    required this.isLandscape,
    this.section = 0,
    this.sectionCount = 0,
  });

  Map<String, Object?> toMap() => {
        'imageBytes': imageBytes,
        'isLandscape': isLandscape,
        'section': section,
        'sectionCount': sectionCount,
      };
}

/// One pin in the printed key: its black-and-white picture and meaning.
class DistributionMapPinLegendEntry {
  final Uint8List pngBytes;
  final String label;

  const DistributionMapPinLegendEntry({
    required this.pngBytes,
    required this.label,
  });

  Map<String, Object?> toMap() => {'pngBytes': pngBytes, 'label': label};
}

/// Data for [generateDistributionMapPdfFromData], kept to plain values so
/// it can cross an isolate.
///
/// Every page carries the distributor details at the top. Instructions
/// print at the bottom of the first page only, when the job has any.
Map<String, Object?> distributionMapPdfPayload({
  required List<DistributionMapPdfPage> pages,
  required Job job,
  required String? distributorName,
  Set<int> hiddenClientIndices = const {},
  bool hasCloudTracks = false,
  List<DistributionMapPinLegendEntry> pinLegend = const [],
}) {
  final shownClients = job.clients
      .asMap()
      .entries
      .where((e) =>
          e.value.trim().isNotEmpty && !hiddenClientIndices.contains(e.key))
      .toList(growable: false);
  return {
    'pages': [for (final page in pages) page.toMap()],
    'dateIso': job.date.toIso8601String(),
    'distributorName': distributorName,
    'clients': [for (final e in shownClients) e.value],
    // Parallel to 'clients'; older jobs may have fewer instructions.
    'clientInstructions': [
      for (final e in shownClients)
        e.key < job.clientInstructions.length
            ? job.clientInstructions[e.key]
            : '',
    ],
    'mapInstructions': job.mapInstructions,
    'workMaps': job.workMaps
        .where((map) => map.isPolygon)
        .map(
          (map) => {
            'name': map.name,
            'colorArgb': map.color.toARGB32(),
          },
        )
        .toList(growable: false),
    'hasCloudTracks': hasCloudTracks,
    'pinLegend': [for (final entry in pinLegend) entry.toMap()],
  };
}

Future<Uint8List> generateDistributionMapPdfFromData(
  Map<String, Object?> payload,
) async {
  final pages = ((payload['pages'] as List?) ?? const [])
      .whereType<Map>()
      .toList(growable: false);
  final date = DateTime.parse(payload['dateIso'] as String);
  final distributorName = payload['distributorName'] as String?;
  final clients = ((payload['clients'] as List?) ?? const [])
      .whereType<String>()
      .toList(growable: false);
  final workMaps = ((payload['workMaps'] as List?) ?? const [])
      .whereType<Map>()
      .map(_PdfWorkMapInfo.fromMap)
      .toList(growable: false);
  final hasCloudTracks = payload['hasCloudTracks'] as bool? ?? false;
  final clientInstructions = ((payload['clientInstructions'] as List?) ??
          const [])
      .map((e) => e is String ? e : '')
      .toList(growable: false);
  final mapInstructions = payload['mapInstructions'] as String? ?? '';
  final pinLegend = [
    for (final entry in ((payload['pinLegend'] as List?) ?? const [])
        .whereType<Map>())
      (
        pw.MemoryImage(entry['pngBytes'] as Uint8List),
        entry['label'] as String? ?? '',
      ),
  ];

  final doc = pw.Document();
  final dateLabel = DateFormat('d MMMM yyyy').format(date);

  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    final isLandscape = page['isLandscape'] as bool? ?? false;
    final section = page['section'] as int? ?? 0;
    final sectionCount = page['sectionCount'] as int? ?? 0;
    final pageTitle = sectionCount == 0
        ? null
        : section == 0
            ? 'Overview: $sectionCount sections'
            : 'Section $section of $sectionCount';
    final mapImage = pw.MemoryImage(page['imageBytes'] as Uint8List);
    doc.addPage(
      pw.Page(
        pageFormat:
            isLandscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(10),
        build: (_) => _buildDistributionMapPage(
          mapImage: mapImage,
          clients: clients,
          workMaps: workMaps,
          distributorName: distributorName,
          dateLabel: dateLabel,
          pageTitle: pageTitle,
          hasCloudTracks: hasCloudTracks,
          pinLegend: pinLegend,
          clientInstructions: i == 0 ? clientInstructions : const [],
          mapInstructions: i == 0 ? mapInstructions : '',
        ),
      ),
    );
  }

  return doc.save();
}

class _PdfWorkMapInfo {
  final String name;
  final int colorArgb;

  const _PdfWorkMapInfo({
    required this.name,
    required this.colorArgb,
  });

  factory _PdfWorkMapInfo.fromMap(Map<dynamic, dynamic> data) {
    return _PdfWorkMapInfo(
      name: data['name'] as String? ?? '',
      colorArgb: data['colorArgb'] as int? ?? 0xFF2196F3,
    );
  }
}

pw.Widget _buildDistributionMapPage({
  required pw.MemoryImage mapImage,
  required List<String> clients,
  required List<_PdfWorkMapInfo> workMaps,
  required String? distributorName,
  required String dateLabel,
  String? pageTitle,
  bool hasCloudTracks = false,
  List<(pw.MemoryImage, String)> pinLegend = const [],
  List<String> clientInstructions = const [],
  String mapInstructions = '',
}) {
  // Header is black text on white: a filled bar wastes printer ink.
  final titleStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 18,
    color: PdfColors.black,
  );
  final headerStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 12,
    color: PdfColors.black,
  );
  // All text is bold, black and large enough to read on a black-and-white
  // printout.
  final labelStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 12,
    color: PdfColors.black,
  );
  final valueStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 12,
    color: PdfColors.black,
  );

  final distributorLabel = _fallback(distributorName, 'Distributor');
  // Only a single work area is named. With several, the count adds
  // nothing to the printout, so it is left off.
  final String? workMapLabel = workMaps.length == 1
      ? _fallback(workMaps.first.name, 'Work area')
      : null;

  // The job's own instructions first, then each client's, labelled with
  // the client's name.
  final instructions = <(String?, String)>[
    if (mapInstructions.trim().isNotEmpty) (null, mapInstructions.trim()),
    for (var i = 0; i < clients.length && i < clientInstructions.length; i++)
      if (clientInstructions[i].trim().isNotEmpty)
        (clients[i].trim(), clientInstructions[i].trim()),
  ];

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(4, 2, 4, 6),
        decoration: const pw.BoxDecoration(
          border: pw.Border(
            bottom: pw.BorderSide(color: PdfColors.black, width: 1.5),
          ),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(distributorLabel, style: titleStyle),
                  if (clients.isNotEmpty) ...[
                    pw.SizedBox(height: 4),
                    _clientList(clients, labelStyle, valueStyle),
                  ],
                  if (workMaps.length > 1) ...[
                    pw.SizedBox(height: 4),
                    _workAreaLegend(workMaps, labelStyle, valueStyle),
                  ],
                  if (hasCloudTracks) ...[
                    pw.SizedBox(height: 4),
                    _recordedTrackLegend(valueStyle),
                  ],
                  if (pinLegend.isNotEmpty) ...[
                    pw.SizedBox(height: 4),
                    _pinLegend(pinLegend, labelStyle, valueStyle),
                  ],
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(dateLabel, style: headerStyle),
                if (pageTitle != null) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(pageTitle, style: titleStyle),
                ],
                if (workMapLabel != null) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(workMapLabel, style: headerStyle),
                ],
              ],
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 5),
      pw.Expanded(
        child: pw.Container(
          decoration: pw.BoxDecoration(
            border: pw.Border.all(
              color: const PdfColor(0.82, 0.82, 0.82),
              width: 0.75,
            ),
          ),
          child: pw.Center(
            child: pw.Image(mapImage, fit: pw.BoxFit.contain),
          ),
        ),
      ),
      // Instructions for the distributor, only when the job has any.
      if (instructions.isNotEmpty) ...[
        pw.SizedBox(height: 5),
        pw.Container(
          padding: const pw.EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            border: pw.Border.all(color: PdfColors.black, width: 1),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Instructions', style: labelStyle),
              for (final line in instructions) ...[
                pw.SizedBox(height: 3),
                line.$1 == null
                    ? pw.Text(line.$2, style: valueStyle)
                    : _infoText(line.$1!, line.$2, labelStyle, valueStyle),
              ],
            ],
          ),
        ),
      ],
    ],
  );
}

pw.Widget _infoText(
  String label,
  String value,
  pw.TextStyle labelStyle,
  pw.TextStyle valueStyle,
) {
  return pw.RichText(
    text: pw.TextSpan(
      children: [
        pw.TextSpan(text: '$label: ', style: labelStyle),
        pw.TextSpan(text: value, style: valueStyle),
      ],
    ),
  );
}

pw.Widget _clientList(
  List<String> clients,
  pw.TextStyle labelStyle,
  pw.TextStyle valueStyle,
) {
  return pw.Wrap(
    spacing: 8,
    runSpacing: 3,
    children: [
      pw.Text('Clients:', style: labelStyle),
      ...clients.asMap().entries.map(
            (entry) =>
                pw.Text('${entry.key + 1}. ${entry.value}', style: valueStyle),
          ),
    ],
  );
}

pw.Widget _workAreaLegend(
  List<_PdfWorkMapInfo> workMaps,
  pw.TextStyle labelStyle,
  pw.TextStyle valueStyle,
) {
  return pw.Wrap(
    spacing: 9,
    runSpacing: 3,
    crossAxisAlignment: pw.WrapCrossAlignment.center,
    children: [
      pw.Text('Work areas:', style: labelStyle),
      ...workMaps.asMap().entries.map((entry) {
        final workMap = entry.value;
        final name = _fallback(workMap.name, 'Area ${entry.key + 1}');
        return pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Container(
              width: 7,
              height: 7,
              decoration: pw.BoxDecoration(
                color: _pdfColor(workMap.colorArgb),
                border: pw.Border.all(color: PdfColors.black, width: 0.25),
              ),
            ),
            pw.SizedBox(width: 3),
            pw.Text('${entry.key + 1}. $name', style: valueStyle),
          ],
        );
      }),
    ],
  );
}

/// What each pin on the map means, pictured as it prints.
pw.Widget _pinLegend(
  List<(pw.MemoryImage, String)> pins,
  pw.TextStyle labelStyle,
  pw.TextStyle valueStyle,
) {
  return pw.Wrap(
    spacing: 10,
    runSpacing: 3,
    crossAxisAlignment: pw.WrapCrossAlignment.center,
    children: [
      pw.Text('Map pins:', style: labelStyle),
      for (final (image, label) in pins)
        pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Image(
              image,
              height: 18,
              // Pins with a tag are wide; keep their shape.
              width: 18 * (image.width ?? 1) / (image.height ?? 1),
            ),
            pw.SizedBox(width: 3),
            pw.Text(label, style: valueStyle),
          ],
        ),
    ],
  );
}

pw.Widget _recordedTrackLegend(pw.TextStyle valueStyle) {
  return pw.Row(
    mainAxisSize: pw.MainAxisSize.min,
    children: [
      pw.Container(
        width: 14,
        height: 2,
        color: PdfColors.blueAccent700,
      ),
      pw.SizedBox(width: 3),
      pw.Text('Recorded track', style: valueStyle),
    ],
  );
}

PdfColor _pdfColor(int colorArgb) {
  return PdfColor.fromInt(0xFF000000 | (colorArgb & 0x00FFFFFF));
}

String _fallback(String? value, String fallback) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? fallback : trimmed;
}
