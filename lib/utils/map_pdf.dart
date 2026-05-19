import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/job.dart';

/// Generates a print-ready distribution map PDF.
///
/// Layout:
/// - A4 portrait or landscape, selected from the map bounds by the caller.
/// - A black header bar with distributor, date, and map summary.
/// - The captured Google Map image is preserved inside the center area.
/// - Distribution details sit in a compact footer so the map stays clean.
Future<Uint8List> generateDistributionMapPdf({
  required Uint8List mapImageBytes,
  required Job job,
  required String? distributorName,
  required bool isLandscape,
}) async {
  return generateDistributionMapPdfFromData(
    distributionMapPdfPayload(
      mapImageBytes: mapImageBytes,
      job: job,
      distributorName: distributorName,
      isLandscape: isLandscape,
    ),
  );
}

Map<String, Object?> distributionMapPdfPayload({
  required Uint8List mapImageBytes,
  required Job job,
  required String? distributorName,
  required bool isLandscape,
}) {
  return {
    'mapImageBytes': mapImageBytes,
    'dateIso': job.date.toIso8601String(),
    'distributorName': distributorName,
    'isLandscape': isLandscape,
    'clients': job.clients
        .where((client) => client.trim().isNotEmpty)
        .toList(growable: false),
    'workMaps': job.workMaps
        .where((map) => map.isPolygon)
        .map(
          (map) => {
            'name': map.name,
            'colorArgb': map.color.toARGB32(),
          },
        )
        .toList(growable: false),
  };
}

Future<Uint8List> generateDistributionMapPdfFromData(
  Map<String, Object?> payload,
) async {
  final mapImageBytes = payload['mapImageBytes'] as Uint8List;
  final date = DateTime.parse(payload['dateIso'] as String);
  final distributorName = payload['distributorName'] as String?;
  final isLandscape = payload['isLandscape'] as bool? ?? false;
  final clients = ((payload['clients'] as List?) ?? const [])
      .whereType<String>()
      .toList(growable: false);
  final workMaps = ((payload['workMaps'] as List?) ?? const [])
      .whereType<Map>()
      .map(_PdfWorkMapInfo.fromMap)
      .toList(growable: false);

  final doc = pw.Document();
  final dateLabel = DateFormat('d MMMM yyyy').format(date);
  final mapImage = pw.MemoryImage(mapImageBytes);
  final pageFormat =
      isLandscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

  doc.addPage(
    pw.Page(
      pageFormat: pageFormat,
      margin: const pw.EdgeInsets.all(10),
      build: (_) => _buildDistributionMapPage(
        mapImage: mapImage,
        clients: clients,
        workMaps: workMaps,
        distributorName: distributorName,
        dateLabel: dateLabel,
        isLandscape: isLandscape,
      ),
    ),
  );

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
  required bool isLandscape,
}) {
  final titleStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 18,
    color: PdfColors.white,
  );
  final headerStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 11,
    color: PdfColors.white,
  );
  final mutedHeaderStyle = pw.TextStyle(
    fontSize: 9,
    color: const PdfColor(0.72, 0.72, 0.72),
  );
  final labelStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 8.5,
    color: PdfColors.grey800,
  );
  final valueStyle = pw.TextStyle(
    fontSize: 8.5,
    color: PdfColors.grey800,
  );

  final distributorLabel = _fallback(distributorName, 'Distributor');
  final workMapLabel = workMaps.isEmpty
      ? '.'
      : workMaps.length == 1
          ? _fallback(workMaps.first.name, 'Work area')
          : '${workMaps.length} work areas';

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: const pw.BoxDecoration(color: PdfColors.black),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(distributorLabel, style: titleStyle),
                  pw.SizedBox(height: 2),
                  pw.Text('Distribution Map', style: mutedHeaderStyle),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(dateLabel, style: headerStyle),
                pw.SizedBox(height: 2),
                pw.Text(
                  '${isLandscape ? 'Landscape' : 'Portrait'} A4  |  $workMapLabel',
                  style: mutedHeaderStyle,
                ),
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
      pw.SizedBox(height: 5),
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: pw.BoxDecoration(
          color: const PdfColor.fromInt(0xFFF7F7F7),
          border: pw.Border.all(
            color: const PdfColor(0.84, 0.84, 0.84),
            width: 0.5,
          ),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _infoText('Name', distributorLabel, labelStyle, valueStyle),
                _infoText('Date', dateLabel, labelStyle, valueStyle),
                _infoText('Map', workMapLabel, labelStyle, valueStyle),
              ],
            ),
            if (clients.isNotEmpty) ...[
              pw.SizedBox(height: 5),
              _clientList(clients, labelStyle, valueStyle),
            ],
            if (workMaps.length > 1) ...[
              pw.SizedBox(height: 5),
              _workAreaLegend(workMaps, labelStyle, valueStyle),
            ],
          ],
        ),
      ),
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

PdfColor _pdfColor(int colorArgb) {
  return PdfColor.fromInt(0xFF000000 | (colorArgb & 0x00FFFFFF));
}

String _fallback(String? value, String fallback) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? fallback : trimmed;
}
