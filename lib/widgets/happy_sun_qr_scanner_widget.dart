import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'dart:async';

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
  String? _lastScannedCode;
  DateTime? _lastScanTime;
  Color _overlayColor = Colors.green;
  Timer? _overlayResetTimer;

  // Debounce: prevent same code from being scanned within 2 seconds
  static const _scanDebounceMs = 2000;

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
    _overlayResetTimer?.cancel();
    super.dispose();
  }

  /// Start the scanner - can be called from parent via GlobalKey
  void startScanning() {
    if (!mounted || _isScanning) return;

    setState(() {
      _isScanning = true;
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal, // Faster detection
        facing: CameraFacing.back,
        torchEnabled: false,
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
        // Check if this is a duplicate scan within debounce period
        final now = DateTime.now();
        if (_lastScannedCode == code && _lastScanTime != null) {
          final timeSinceLastScan =
              now.difference(_lastScanTime!).inMilliseconds;
          if (timeSinceLastScan < _scanDebounceMs) {
            // Skip duplicate scan
            return;
          }
        }

        // Update last scan info
        _lastScannedCode = code;
        _lastScanTime = now;

        // Trigger haptic feedback for scan detection
        HapticFeedback.lightImpact();

        // Call the parent callback
        widget.onScan(code);
      }
    }
  }

  /// Show success feedback (green flash)
  void showSuccessFeedback() {
    if (!mounted) return;

    setState(() {
      _overlayColor = Colors.green;
    });

    HapticFeedback.mediumImpact();

    _overlayResetTimer?.cancel();
    _overlayResetTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _overlayColor = Colors.green;
        });
      }
    });
  }

  /// Show error feedback (red flash)
  void showErrorFeedback() {
    if (!mounted) return;

    setState(() {
      _overlayColor = Colors.red;
    });

    HapticFeedback.vibrate();

    _overlayResetTimer?.cancel();
    _overlayResetTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _overlayColor = Colors.green;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 320,
      margin: const EdgeInsets.all(12),
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
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _overlayColor,
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  // Instructions overlay
                  if (widget.instructionText != null)
                    Positioned(
                      top: 40,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          widget.instructionText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
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
                    const SizedBox(height: 12),
                    Text(
                      'Initializing camera...',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
