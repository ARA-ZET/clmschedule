import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../providers/inventory_provider.dart';
import 'tool_details_dialog.dart';

class QrScannerDialog extends StatefulWidget {
  const QrScannerDialog({super.key});

  @override
  State<QrScannerDialog> createState() => _QrScannerDialogState();
}

class _QrScannerDialogState extends State<QrScannerDialog> {
  final MobileScannerController controller = MobileScannerController();
  bool _isProcessing = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _handleBarcode(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final String? code = barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    setState(() => _isProcessing = true);

    try {
      final inventoryProvider = context.read<InventoryProvider>();
      final tool = await inventoryProvider.getToolByQrCode(code);

      if (!mounted) return;

      if (tool != null) {
        // Close scanner and show tool details
        Navigator.of(context).pop();
        showDialog(
          context: context,
          builder: (context) => ToolDetailsDialog(tool: tool),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Tool not found for QR code: $code'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isProcessing = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error scanning QR code: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isProcessing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 500,
        height: 600,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(4)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Scan QR Code',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // Scanner
            Expanded(
              child: Stack(
                children: [
                  MobileScanner(
                    controller: controller,
                    onDetect: _handleBarcode,
                  ),
                  // Overlay with scanning frame
                  Center(
                    child: Container(
                      width: 250,
                      height: 250,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.green, width: 3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  if (_isProcessing)
                    Container(
                      color: Colors.black54,
                      child: const Center(
                        child: CircularProgressIndicator(),
                      ),
                    ),
                ],
              ),
            ),
            // Instructions
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(4)),
              ),
              child: Column(
                children: [
                  const Text(
                    'Position the QR code within the frame',
                    style: TextStyle(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: () => controller.toggleTorch(),
                        icon: const Icon(Icons.flash_on),
                        tooltip: 'Toggle Flash',
                      ),
                      IconButton(
                        onPressed: () => controller.switchCamera(),
                        icon: const Icon(Icons.flip_camera_ios),
                        tooltip: 'Switch Camera',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
