import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Reusable QR scanner widget for Happy Sun checkout, checklist, and checkin flows.
///
/// This widget manages its own scanner lifecycle and provides a consistent
/// scanning experience across all Happy Sun features.
class HappySunQRScannerWidget extends StatefulWidget {
  /// Callback when a barcode is successfully scanned
  final void Function(String code) onScan;

  /// Custom instruction text to display over the scanner
  final String? instructionText;

  /// Whether to automatically start scanning when widget is built
  final bool autoStart;

  const HappySunQRScannerWidget({
    super.key,
    required this.onScan,
    this.instructionText,
    this.autoStart = true,
  });

  @override
  State<HappySunQRScannerWidget> createState() =>
      HappySunQRScannerWidgetState();
}

/// Public state class so it can be accessed via GlobalKey
class HappySunQRScannerWidgetState extends State<HappySunQRScannerWidget> {
  MobileScannerController? _scannerController;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        startScanning();
      });
    }
  }

  @override
  void dispose() {
    stopScanning();
    super.dispose();
  }

  /// Start the scanner - can be called from parent via GlobalKey
  void startScanning() {
    if (!mounted || _isScanning) return;

    setState(() {
      _isScanning = true;
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    });
  }

  /// Stop the scanner - can be called from parent via GlobalKey
  void stopScanning() {
    if (!_isScanning) return;

    _scannerController?.dispose();
    _scannerController = null;

    if (mounted) {
      setState(() {
        _isScanning = false;
      });
    }
  }

  /// Check if currently scanning
  bool get isScanning => _isScanning;

  void _handleBarcodeScan(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;

    for (final barcode in barcodes) {
      final String? code = barcode.rawValue;

      if (code != null && code.isNotEmpty) {
        widget.onScan(code);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 400,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: _isScanning && _scannerController != null
            ? Stack(
                children: [
                  MobileScanner(
                    controller: _scannerController,
                    onDetect: _handleBarcodeScan,
                  ),
                  // Scan overlay frame
                  Center(
                    child: Container(
                      width: 250,
                      height: 250,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.green,
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  // Instructions overlay
                  if (widget.instructionText != null)
                    Positioned(
                      top: 50,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          widget.instructionText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              )
            : Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(
                      color: Colors.orange,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Initializing camera...',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
