import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:math' show min, max;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../models/work_area.dart';
import '../models/job.dart';
import 'package:intl/intl.dart';

class PrintMapView extends StatefulWidget {
  final Job job;
  final String? distributorName;

  const PrintMapView({
    super.key,
    required this.job,
    this.distributorName,
  });

  @override
  State<PrintMapView> createState() => _PrintMapViewState();
}

class _PrintMapViewState extends State<PrintMapView> {
  GoogleMapController? _controller;
  final Set<Polygon> _polygons = {};
  LatLng _center = const LatLng(-33.925, 18.425); // Cape Town city center
  bool _isLoading = true;
  WorkArea? _selectedWorkArea;
  bool _isPortrait = true;
  bool _isDraggingInfoBox = false; // Track when dragging info box
  bool _isResizingInfoBox = false; // Track when resizing info box

  // Position and size of the movable info box
  Offset _infoBoxPosition = const Offset(20, 20);
  Size _infoBoxSize = const Size(250, 160); // Default size
  double _fontScale = 1.0; // Font scale factor

  // Global key for capturing the map widget
  final GlobalKey _mapKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    try {
      // Use work maps from the job directly
      if (widget.job.workMaps.isNotEmpty) {
        // For printing, we'll use the first work map as the selected area
        // In the future, this could show all work maps or allow selection
        final firstWorkMap = widget.job.workMaps.first;

        // Create a temporary WorkArea for compatibility with existing printing logic
        _selectedWorkArea = WorkArea(
          id: 'temp_${firstWorkMap.name}',
          name: firstWorkMap.name,
          description: firstWorkMap.description,
          polygonPoints: firstWorkMap.points,
          kmlFileName: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
      }

      _updateMapView();
    } catch (e) {
      print('Error initializing map: $e');
      // Set a default center if initialization fails
      _center = const LatLng(-33.925, 18.425); // Cape Town city center
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _updateMapView() {
    _polygons.clear();

    // Don't show background work areas - only show the job-specific polygon
    // This ensures only the current job's work area is visible when printing

    // Add the selected work area (highlighted)
    if (_selectedWorkArea != null) {
      _polygons.add(
        Polygon(
          polygonId: PolygonId(_selectedWorkArea!.id),
          points: _selectedWorkArea!.polygonPoints,
          fillColor: Colors.red.withOpacity(0), // Semi-transparent fill
          strokeColor: Colors.red,
          strokeWidth: 3,
        ),
      );
    }

    // Center map on selected area
    _updateMapCenter();
  }

  void _updateMapCenter() {
    if (_selectedWorkArea?.polygonPoints.isNotEmpty == true) {
      final points = _selectedWorkArea!.polygonPoints;
      double minLat = 90;
      double maxLat = -90;
      double minLng = 180;
      double maxLng = -180;

      for (final point in points) {
        minLat = min(minLat, point.latitude);
        maxLat = max(maxLat, point.latitude);
        minLng = min(minLng, point.longitude);
        maxLng = max(maxLng, point.longitude);
      }

      _center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);

      // Only animate camera if controller is available and not disposed
      if (_controller != null && mounted) {
        try {
          _controller!.animateCamera(
            CameraUpdate.newLatLngBounds(
              LatLngBounds(
                southwest: LatLng(minLat, minLng),
                northeast: LatLng(maxLat, maxLng),
              ),
              100, // padding
            ),
          );
        } catch (e) {
          print('Error animating camera: $e');
        }
      }
    } else {
      // No polygons available, use default center
      _center = const LatLng(-33.925, 18.425); // Cape Town city center

      // Only animate camera if controller is available and not disposed
      if (_controller != null && mounted) {
        try {
          _controller!.animateCamera(
            CameraUpdate.newLatLng(_center),
          );
        } catch (e) {
          print('Error setting default camera position: $e');
        }
      }
    }
  }

  Future<void> _printMap() async {
    try {
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Text('Preparing map for printing...'),
            ],
          ),
        ),
      );

      // Wait a moment to ensure the map is fully rendered
      await Future.delayed(const Duration(milliseconds: 500));

      // Capture the map as screenshot
      final RenderRepaintBoundary boundary =
          _mapKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      final Uint8List imageBytes = byteData!.buffer.asUint8List();

      // Hide loading indicator
      ScaffoldMessenger.of(context).clearSnackBars();

      // For web platform, trigger download
      if (mounted) {
        _triggerWebDownload(imageBytes);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error preparing map: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _triggerWebDownload(Uint8List bytes) {
    // Create a blob and download link for web
    final String fileName =
        'map_${widget.job.primaryClient}_${DateFormat('yyyy-MM-dd').format(widget.job.date)}.png';

    // Show print dialog with the image
    showDialog(
      context: context,
      builder: (context) => _PrintPreviewDialog(
        imageBytes: bytes,
        fileName: fileName,
        job: widget.job,
        distributorName: widget.distributorName,
        isPortrait: _isPortrait,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    // Calculate available dimensions (account for app bar and margins)
    final appBarHeight = AppBar().preferredSize.height;
    final availableHeight =
        screenHeight - appBarHeight - 50; // 25px top + 25px bottom
    final availableWidth = screenWidth - 50; // 25px left + 25px right margins

    // Calculate map dimensions based on A4 aspect ratio and available space
    double mapWidth, mapHeight;

    if (_isPortrait) {
      // Portrait A4: height > width (ratio = 1:1.414, so height = width * 1.414)
      final maxWidthBasedHeight = availableWidth * 1.414;
      final maxHeightBasedWidth = availableHeight / 1.414;

      if (maxWidthBasedHeight <= availableHeight) {
        // Limited by width
        mapWidth = availableWidth;
        mapHeight = maxWidthBasedHeight;
      } else {
        // Limited by height
        mapHeight = availableHeight;
        mapWidth = maxHeightBasedWidth;
      }
    } else {
      // Landscape A4: width > height (ratio = 1.414:1, so width = height * 1.414)
      final maxHeightBasedWidth = availableHeight * 1.414;
      final maxWidthBasedHeight = availableWidth / 1.414;

      if (maxHeightBasedWidth <= availableWidth) {
        // Limited by height
        mapHeight = availableHeight;
        mapWidth = maxHeightBasedWidth;
      } else {
        // Limited by width
        mapWidth = availableWidth;
        mapHeight = maxWidthBasedHeight;
      }
    }

    // Center the map container horizontally and vertically
    final mapLeft = (screenWidth - mapWidth) / 2;
    final mapTop = (screenHeight - appBarHeight - mapHeight) / 2;

    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        title: const Text('Print Map View'),
        actions: [
          // Orientation toggle
          IconButton(
            icon: Icon(_isPortrait
                ? Icons.stay_current_portrait
                : Icons.stay_current_landscape),
            tooltip: _isPortrait ? 'Switch to Landscape' : 'Switch to Portrait',
            onPressed: () {
              setState(() {
                _isPortrait = !_isPortrait;
                // Reset info box position and size when orientation changes
                _infoBoxPosition = const Offset(20, 20);
                _infoBoxSize = const Size(250, 160);
                _fontScale = 1.0;
              });
            },
          ),
          // Print button
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'Print Map',
            onPressed: _printMap,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Center the A4 map container
          Positioned(
            left: mapLeft,
            top: mapTop,
            child: RepaintBoundary(
              key: _mapKey,
              child: Container(
                width: mapWidth,
                height: mapHeight,
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // Google Map
                    GoogleMap(
                      onMapCreated: (controller) {
                        try {
                          _controller = controller;
                          if (mounted) {
                            _updateMapCenter();
                          }
                        } catch (e) {
                          print('Error in onMapCreated: $e');
                        }
                      },
                      initialCameraPosition:
                          CameraPosition(target: _center, zoom: 12),
                      polygons: _polygons,
                      mapType: MapType.normal,
                      cloudMapId: "89c628d2bb3002712797ce42",
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                      myLocationButtonEnabled: false,
                      scrollGesturesEnabled:
                          !_isDraggingInfoBox && !_isResizingInfoBox,
                      zoomGesturesEnabled:
                          !_isDraggingInfoBox && !_isResizingInfoBox,
                      rotateGesturesEnabled: false,
                      tiltGesturesEnabled: false,
                    ),
                    // Loading overlay
                    if (_isLoading)
                      Container(
                        color: Colors.white.withOpacity(0.8),
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                    // Information Box (rendered as part of the screenshot)
                    Positioned(
                      left: _infoBoxPosition.dx,
                      top: _infoBoxPosition.dy,
                      child: _buildInfoBox(),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Movable Information Box (for positioning only - invisible)
          Positioned(
            left: mapLeft + _infoBoxPosition.dx,
            top: mapTop + _infoBoxPosition.dy,
            child: GestureDetector(
              onPanStart: (details) {
                setState(() {
                  _isDraggingInfoBox = true;
                });
              },
              onPanUpdate: (details) {
                setState(() {
                  final newX = _infoBoxPosition.dx + details.delta.dx;
                  final newY = _infoBoxPosition.dy + details.delta.dy;

                  // Keep the box within the map bounds using dynamic size
                  _infoBoxPosition = Offset(
                    newX.clamp(0, mapWidth - _infoBoxSize.width),
                    newY.clamp(0, mapHeight - _infoBoxSize.height),
                  );
                });
              },
              onPanEnd: (details) {
                setState(() {
                  _isDraggingInfoBox = false;
                });
              },
              child: Stack(
                children: [
                  // Main draggable container
                  Container(
                    width: _infoBoxSize.width,
                    height: _infoBoxSize.height,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      border: Border.all(
                        color: (_isDraggingInfoBox || _isResizingInfoBox)
                            ? Colors.red.withOpacity(0.8)
                            : Colors.blue.withOpacity(0),
                        width:
                            (_isDraggingInfoBox || _isResizingInfoBox) ? 2 : 1,
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.drag_handle,
                        color: (_isDraggingInfoBox || _isResizingInfoBox)
                            ? Colors.red.withOpacity(0.7)
                            : Colors.blue.withOpacity(0),
                        size: 24 * _fontScale,
                      ),
                    ),
                  ),
                  // Resize handle in bottom-right corner
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onPanStart: (details) {
                        setState(() {
                          _isResizingInfoBox = true;
                        });
                      },
                      onPanUpdate: (details) {
                        setState(() {
                          final newWidth =
                              _infoBoxSize.width + details.delta.dx;
                          final newHeight =
                              _infoBoxSize.height + details.delta.dy;

                          // Min and max constraints for size
                          const minSize = Size(150, 100);
                          final maxSize = Size(mapWidth * 0.4, mapHeight * 0.4);

                          _infoBoxSize = Size(
                            newWidth.clamp(minSize.width, maxSize.width),
                            newHeight.clamp(minSize.height, maxSize.height),
                          );

                          // Update font scale based on size
                          final sizeRatio = (_infoBoxSize.width / 250 +
                                  _infoBoxSize.height / 160) /
                              2;
                          _fontScale = sizeRatio.clamp(0.6, 2.0);

                          // Adjust position if needed to stay within bounds
                          _infoBoxPosition = Offset(
                            _infoBoxPosition.dx
                                .clamp(0, mapWidth - _infoBoxSize.width),
                            _infoBoxPosition.dy
                                .clamp(0, mapHeight - _infoBoxSize.height),
                          );
                        });
                      },
                      onPanEnd: (details) {
                        setState(() {
                          _isResizingInfoBox = false;
                        });
                      },
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: _isResizingInfoBox
                              ? Colors.red.withOpacity(0.8)
                              : Colors.blue
                                  .withOpacity(_isDraggingInfoBox ? 0.6 : 0),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const Icon(
                          Icons.drag_handle,
                          color: Colors.white,
                          size: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBox() {
    final dateFormatter = DateFormat('dd MMM yyyy');

    return Container(
      width: _infoBoxSize.width,
      height: _infoBoxSize.height,
      padding: EdgeInsets.all(12 * _fontScale),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with drag handle
            Row(
              children: [
                Icon(Icons.drag_handle,
                    size: 14 * _fontScale, color: Colors.grey),
                SizedBox(width: 6 * _fontScale),
                Expanded(
                  child: Text(
                    'Distribution Details',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13 * _fontScale,
                    ),
                  ),
                ),
              ],
            ),
            Divider(thickness: 1 * _fontScale),

            // Name (Distributor)
            _buildInfoRow('Name:', widget.distributorName ?? '.'),

            // Map (Working Area)
            _buildInfoRow(
                'Map:',
                widget.job.primaryWorkingArea.isNotEmpty
                    ? widget.job.primaryWorkingArea
                    : '.'),

            // Date
            _buildInfoRow('Date:', dateFormatter.format(widget.job.date)),

            // Clients (numbered list)
            SizedBox(height: 6 * _fontScale),
            Text(
              'Clients:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 11 * _fontScale,
              ),
            ),
            SizedBox(height: 3 * _fontScale),
            ...widget.job.clients.asMap().entries.map((entry) {
              final index = entry.key + 1;
              final client = entry.value;
              return Padding(
                padding: EdgeInsets.only(
                    left: 12 * _fontScale, bottom: 1 * _fontScale),
                child: Text(
                  '$index. $client',
                  style: TextStyle(
                    fontSize: 10 * _fontScale,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            }).toList(),

            if (widget.job.clients.isEmpty)
              Padding(
                padding: EdgeInsets.only(left: 12 * _fontScale),
                child: Text(
                  '.',
                  style: TextStyle(
                    fontSize: 10 * _fontScale,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.only(bottom: 4 * _fontScale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 45 * _fontScale,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 11 * _fontScale,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11 * _fontScale,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  @override
  void dispose() {
    try {
      _controller?.dispose();
    } catch (e) {
      print('Error disposing map controller: $e');
    }
    super.dispose();
  }
}

class _PrintPreviewDialog extends StatelessWidget {
  final Uint8List imageBytes;
  final String fileName;
  final Job job;
  final String? distributorName;
  final bool isPortrait;

  const _PrintPreviewDialog({
    required this.imageBytes,
    required this.fileName,
    required this.job,
    required this.distributorName,
    required this.isPortrait,
  });

  void _downloadImage(BuildContext context) {
    // Show instructions for manual download
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Download Instructions'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('To save this map image:'),
            SizedBox(height: 8),
            Text('1. Right-click on the map image above'),
            Text('2. Select "Save image as..." or "Copy image"'),
            Text('3. Choose your preferred location to save'),
            SizedBox(height: 16),
            Text(
              'The map is optimized for A4 printing.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _printImage(BuildContext context) {
    // Show print instructions
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Print Instructions'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('To print this map:'),
            SizedBox(height: 8),
            Text('1. Right-click on the map image above'),
            Text('2. Select "Print..." or use browser print (Ctrl+P / Cmd+P)'),
            Text('3. Choose your printer and adjust settings'),
            Text('4. The map is already sized for A4 paper'),
            SizedBox(height: 16),
            Text(
              'Alternatively, you can take a screenshot and print it from your photo app.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: screenWidth * 0.8,
        height: screenHeight * 0.8,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Colors.blue,
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.print, color: Colors.white),
                  const SizedBox(width: 12),
                  const Text(
                    'Print Preview',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Preview
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      'Distribution Map - ${distributorName ?? "."}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Format: ${isPortrait ? "Portrait" : "Landscape"} A4',
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey[300]!),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            imageBytes,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Actions
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => _downloadImage(context),
                    icon: const Icon(Icons.download),
                    label: const Text('Download'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () => _printImage(context),
                    icon: const Icon(Icons.print),
                    label: const Text('Print'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
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
