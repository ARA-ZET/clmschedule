import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/inventory_tool.dart';

class QrCodeDisplayDialog extends StatelessWidget {
  final InventoryTool tool;

  const QrCodeDisplayDialog({super.key, required this.tool});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tool.name,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // QR Code
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: tool.qrCode,
                version: QrVersions.auto,
                size: 250.0,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.H,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'ID: ${tool.qrCode}',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    // TODO: Implement print functionality
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Print functionality to be implemented'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.print),
                  label: const Text('Print Label'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
