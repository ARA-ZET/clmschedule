import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/inventory_tool.dart';

class QrCodePdfService {
  static Future<void> downloadQrCodePdf(
    List<InventoryTool> tools, {
    int codesPerRow = 3,
    double qrSize = 150,
  }) async {
    final pdf = pw.Document();

    // Use LANDSCAPE orientation (A4 landscape = 297mm x 210mm)
    final pageWidth = 297.0;
    final pageHeight = 210.0;
    final pageFormat = PdfPageFormat(
        pageWidth * PdfPageFormat.mm, pageHeight * PdfPageFormat.mm);

    // Calculate grid layout
    final margin = 10.0;
    final availableWidth = pageWidth - (2 * margin);
    final availableHeight = pageHeight - (2 * margin);

    final cellWidth = availableWidth / codesPerRow;
    final codesPerColumn = (availableHeight / cellWidth).floor();
    final codesPerPage = codesPerRow * codesPerColumn;

    // Load fonts for Unicode support
    final fontBold = await PdfGoogleFonts.robotoBold();
    final fontRegular = await PdfGoogleFonts.robotoRegular();

    // Split tools into pages
    for (int pageIndex = 0;
        pageIndex * codesPerPage < tools.length;
        pageIndex++) {
      final startIndex = pageIndex * codesPerPage;
      final endIndex = (startIndex + codesPerPage).clamp(0, tools.length);
      final pageTools = tools.sublist(startIndex, endIndex);

      pdf.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.all(margin * PdfPageFormat.mm),
          build: (pw.Context context) {
            return _buildQrCodeWidgets(
              pageTools,
              codesPerRow,
              cellWidth,
              fontBold,
              fontRegular,
            );
          },
        ),
      );
    }

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  static pw.Widget _buildQrCodeWidgets(
    List<InventoryTool> tools,
    int codesPerRow,
    double cellWidth,
    pw.Font fontBold,
    pw.Font fontRegular,
  ) {
    // Group tools into rows
    final rows = <List<InventoryTool>>[];
    for (int i = 0; i < tools.length; i += codesPerRow) {
      rows.add(tools.sublist(i, (i + codesPerRow).clamp(0, tools.length)));
    }

    return pw.Column(
      children: rows.map((rowTools) {
        return pw.Expanded(
          child: pw.Row(
            children: rowTools.map((tool) {
              return pw.Expanded(
                child: pw.Container(
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(width: 1),
                  ),
                  child: pw.Column(
                    children: [
                      // QR Code - 70% of cell
                      pw.Expanded(
                        flex: 7,
                        child: pw.Center(
                          child: pw.BarcodeWidget(
                            barcode: pw.Barcode.qrCode(),
                            data: tool.toolId,
                            width: cellWidth * 0.8 * PdfPageFormat.mm,
                            height: cellWidth * 0.8 * PdfPageFormat.mm,
                          ),
                        ),
                      ),
                      // Text labels - 20% of cell
                      pw.Expanded(
                        flex: 3,
                        child: pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: pw.Column(
                            mainAxisAlignment: pw.MainAxisAlignment.center,
                            children: [
                              pw.Text(
                                tool.toolId,
                                style: pw.TextStyle(
                                  fontSize: 18,
                                  fontWeight: pw.FontWeight.bold,
                                  font: fontBold,
                                ),
                                textAlign: pw.TextAlign.center,
                              ),
                              pw.SizedBox(height: 2),
                              pw.Text(
                                tool.name,
                                style: pw.TextStyle(
                                  fontSize: 18,
                                  font: fontBold,
                                ),
                                textAlign: pw.TextAlign.center,
                                maxLines: 2,
                                overflow: pw.TextOverflow.clip,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}
