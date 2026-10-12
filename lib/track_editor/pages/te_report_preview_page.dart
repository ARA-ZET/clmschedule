// track_editor/pages/te_report_preview_page.dart
//
// Full-screen preview of the generated report PDF, with print/share/save
// baked into PdfPreview's own action bar (package:printing) — on web,
// "share" surfaces the browser's native save-as-PDF/download flow, which is
// the same mechanism every other PDF feature in this app already relies on
// (Printing.layoutPdf, used e.g. by the payroll PDFs).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

class TEReportPreviewPage extends StatelessWidget {
  final Uint8List pdfBytes;
  const TEReportPreviewPage({super.key, required this.pdfBytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report preview'),
      ),
      body: PdfPreview(
        build: (format) async => pdfBytes,
        pdfFileName: 'Flyer handout report.pdf',
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
      ),
    );
  }
}
