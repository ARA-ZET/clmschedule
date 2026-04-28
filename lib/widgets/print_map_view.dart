import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:math' show min, max;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../providers/schedule_provider.dart';
import '../shareable_maps/utils/point_marker_icons.dart';
import 'package:intl/intl.dart';

// Class to store polygon override settings
class PolygonOverride {
  final Color strokeColor;
  final int strokeWidth;

  const PolygonOverride({
    required this.strokeColor,
    required this.strokeWidth,
  });
}

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
  final Set<Polyline> _polylines = {};
  final Set<Marker> _customPointMarkers = {};
  Marker? _dropOffMarker;
  LatLng? _dropOffPoint;
  LatLng _center = const LatLng(-33.925, 18.425); // Cape Town city center
  bool _isLoading = true;
  bool _isDraggingInfoBox = false; // Track when dragging info box
  bool _isResizingInfoBox = false; // Track when resizing info box

  // Polygon override settings
  final Map<String, PolygonOverride> _polygonOverrides = {};

  // Global polygon settings
  bool _useBlackBorders = false;
  int _globalBorderWidth = 3;

  // Position and size of the movable info box
  Offset _infoBoxPosition = const Offset(20, 20);
  Size _infoBoxSize = const Size(250, 160); // Default size
  double _fontScale = 1.0; // Font scale factor

  // Position and size of the work areas box (when multiple areas exist)
  Offset _workAreasBoxPosition = const Offset(20, 200);
  Size _workAreasBoxSize = const Size(250, 100); // Default size
  double _workAreasFontScale = 1.0; // Font scale factor
  bool _isDraggingWorkAreasBox = false; // Track when dragging work areas box
  bool _isResizingWorkAreasBox = false; // Track when resizing work areas box

  // Global key for capturing the map widget
  final GlobalKey _mapKey = GlobalKey();

  // Vertex editing state
  bool _isEditingVertices = false;
  int? _editingPolygonIndex; // which workmap polygon is being edited
  List<LatLng>? _editingPoints; // mutable copy of the polygon's points
  Set<Marker> _vertexMarkers = {};
  BitmapDescriptor? _vertexMarkerIcon;
  BitmapDescriptor? _midpointMarkerIcon;
  Map<PointCategory, BitmapDescriptor>? _pointIcons;

  @override
  void initState() {
    super.initState();
    _initializeMap();
    _createMarkerIcons();
  }

  Future<void> _initializeMap() async {
    try {
      _dropOffPoint = widget.job.dropOffPoint ??
          Job.estimateDropOffPointFromWorkMaps(widget.job.workMaps);
      // Initialize map view with all work maps
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
    _polylines.clear();
    _customPointMarkers.clear();

    // Show all work maps with their respective colors
    if (widget.job.workMaps.isNotEmpty) {
      for (int i = 0; i < widget.job.workMaps.length; i++) {
        final workMap = widget.job.workMaps[i];

        // Handle point/marker-type elements
        if (workMap.isPoint && workMap.points.isNotEmpty) {
          if (workMap.pointCategory == PointCategory.dropoff) {
            _dropOffPoint ??= workMap.points.first;
            continue;
          }
          final marker = workMap.toGoogleMapsMarker(
            markerId: 'workmap_marker_$i',
            customIcon: _pointIcons?[workMap.pointCategory],
          );
          if (marker != null) {
            _customPointMarkers.add(marker);
          }
          continue;
        }

        // Handle polyline-type elements
        if (workMap.isPolyline && workMap.points.length >= 2) {
          _polylines.add(
            Polyline(
              polylineId: PolylineId('workmap_polyline_$i'),
              points: workMap.points,
              color: workMap.color,
              width: workMap.strokeWidth,
              patterns: workMap.isDashed
                  ? [PatternItem.dash(20), PatternItem.gap(10)]
                  : [],
            ),
          );
          continue;
        }

        final polygonId = 'workmap_$i';

        // Check if there's an override for this polygon
        final override = _polygonOverrides[polygonId];

        // Determine stroke color: individual override > global setting > original color
        Color strokeColor;
        if (override?.strokeColor != null) {
          strokeColor = override!.strokeColor;
        } else if (_useBlackBorders) {
          strokeColor = Colors.black;
        } else {
          strokeColor = workMap.color;
        }

        // Determine stroke width: individual override > global setting
        int strokeWidth = override?.strokeWidth ?? _globalBorderWidth;

        // Use editing points if this polygon is being edited
        final points = (_editingPolygonIndex == i && _editingPoints != null)
            ? _editingPoints!
            : workMap.points;

        _polygons.add(
          Polygon(
            polygonId: PolygonId(polygonId),
            points: points,
            fillColor: workMap.color
                .withValues(alpha: 0), // Slight fill to make tappable
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            consumeTapEvents: _isEditingVertices,
            onTap: () {
              if (_isEditingVertices) {
                _selectPolygonForEditing(i);
              }
            },
          ),
        );
      }
    }

    if (_dropOffPoint != null) {
      _dropOffMarker = Marker(
        markerId: const MarkerId('dropoff_point'),
        position: _dropOffPoint!,
        draggable: true,
        infoWindow: const InfoWindow(title: 'Drop-off Point'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        onDragEnd: (position) async {
          _dropOffPoint = position;
          setState(() {});
          await _persistDropOffPoint(position);
        },
      );
    } else {
      _dropOffMarker = null;
    }

    // Center map on all polygons
    _updateMapCenter();
  }

  void _updateMapCenter() {
    if (widget.job.workMaps.isNotEmpty) {
      // Calculate bounds for all polygons
      double minLat = 90;
      double maxLat = -90;
      double minLng = 180;
      double maxLng = -180;

      // Iterate through all work maps to find overall bounds
      for (final workMap in widget.job.workMaps) {
        for (final point in workMap.points) {
          minLat = min(minLat, point.latitude);
          maxLat = max(maxLat, point.latitude);
          minLng = min(minLng, point.longitude);
          maxLng = max(maxLng, point.longitude);
        }
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

  // ── Vertex editing helpers ────────────────────────────────────────

  Future<void> _createMarkerIcons() async {
    try {
      _vertexMarkerIcon = await _createCircleIcon(
        size: 16.0,
        fillColor: Colors.white,
        borderColor: Colors.red,
        borderWidth: 1.5,
      );
    } catch (_) {
      _vertexMarkerIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    }
    try {
      _midpointMarkerIcon = await _createCircleIcon(
        size: 12.0,
        fillColor: Colors.orange,
        borderColor: Colors.white,
        borderWidth: 1.0,
      );
    } catch (_) {
      _midpointMarkerIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    }
    try {
      await PointMarkerIcons.preload();
      _pointIcons = PointMarkerIcons.allCached;
    } catch (_) {
      _pointIcons = null;
    }
    if (mounted) setState(() {});
  }

  Future<BitmapDescriptor> _createCircleIcon({
    required double size,
    required Color fillColor,
    required Color borderColor,
    required double borderWidth,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final double radius = size / 2;
    canvas.drawCircle(
      Offset(radius, radius),
      radius - borderWidth,
      Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(radius, radius),
      radius - borderWidth,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth,
    );
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (pngBytes == null) throw Exception('icon toByteData returned null');
    return BitmapDescriptor.bytes(pngBytes.buffer.asUint8List());
  }

  void _selectPolygonForEditing(int polygonIndex) {
    if (_editingPolygonIndex == polygonIndex) return; // already selected
    final workMap = widget.job.workMaps[polygonIndex];
    setState(() {
      _editingPolygonIndex = polygonIndex;
      _editingPoints = List<LatLng>.from(workMap.points);
      _rebuildVertexMarkers();
    });
  }

  void _rebuildVertexMarkers() {
    final markers = <Marker>{};
    final points = _editingPoints;
    if (points == null || points.isEmpty) {
      _vertexMarkers = markers;
      return;
    }

    final vertexIcon = _vertexMarkerIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    final midpointIcon = _midpointMarkerIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

    // Vertex markers (draggable)
    for (int i = 0; i < points.length; i++) {
      markers.add(Marker(
        markerId: MarkerId('vertex_$i'),
        icon: vertexIcon,
        position: points[i],
        draggable: true,
        onDrag: (pos) {
          _editingPoints![i] = pos;
          setState(() {
            _rebuildVertexMarkers();
            _updateMapView();
          });
        },
        onDragEnd: (pos) {
          _editingPoints![i] = pos;
          setState(() {
            _rebuildVertexMarkers();
            _updateMapView();
          });
        },
      ));
    }

    // Midpoint markers (dragging inserts a new vertex)
    if (points.length >= 2) {
      for (int i = 0; i < points.length; i++) {
        final j = (i + 1) % points.length;
        final mid = LatLng(
          (points[i].latitude + points[j].latitude) / 2,
          (points[i].longitude + points[j].longitude) / 2,
        );
        markers.add(Marker(
          markerId: MarkerId('midpoint_$i'),
          icon: midpointIcon,
          position: mid,
          draggable: true,
          anchor: const Offset(0.5, 0.5),
          onDragEnd: (pos) {
            _editingPoints!.insert(i + 1, pos);
            setState(() {
              _rebuildVertexMarkers();
              _updateMapView();
            });
          },
        ));
      }
    }

    _vertexMarkers = markers;
  }

  void _saveVertexEditing() {
    if (_editingPolygonIndex == null || _editingPoints == null) return;
    final idx = _editingPolygonIndex!;
    final old = widget.job.workMaps[idx];
    widget.job.workMaps[idx] = CustomPolygon(
      name: old.name,
      description: old.description,
      points: List<LatLng>.from(_editingPoints!),
      color: old.color,
      fillOpacity: old.fillOpacity,
      strokeWidth: old.strokeWidth,
      isDashed: old.isDashed,
      type: old.type,
      pointCategory: old.pointCategory,
      letterBoxEstimate: old.letterBoxEstimate,
    );

    // Keep drop-off point aligned to updated work areas.
    if (_dropOffPoint == null ||
        !Job.isPointInsideAnyWorkArea(_dropOffPoint!, widget.job.workMaps)) {
      _dropOffPoint = Job.estimateDropOffPointFromWorkMaps(widget.job.workMaps);
      if (_dropOffPoint != null) {
        _persistDropOffPoint(_dropOffPoint!);
      }
    } else {
      _persistWorkAreaChanges();
    }

    setState(() {
      _editingPolygonIndex = null;
      _editingPoints = null;
      _vertexMarkers = {};
      _updateMapView();
    });
  }

  void _cancelVertexEditing() {
    setState(() {
      _editingPolygonIndex = null;
      _editingPoints = null;
      _vertexMarkers = {};
      _updateMapView();
    });
  }

  void _removeLastVertex() {
    if (_editingPoints == null || _editingPoints!.length <= 3) return;
    // Find closest vertex to remove — for simplicity, remove the last one
    _editingPoints!.removeLast();
    setState(() {
      _rebuildVertexMarkers();
      _updateMapView();
    });
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

  Future<void> _persistDropOffPoint(LatLng point) async {
    final scheduleProvider = ProviderScope.containerOf(context, listen: false)
        .read(scheduleRiverpod);
    final freshJob = scheduleProvider.jobs.firstWhere(
      (j) => j.id == widget.job.id,
      orElse: () => widget.job,
    );
    final updatedJob = freshJob.copyWith(dropOffPoint: point);
    await scheduleProvider.updateJobWithUndo(
        freshJob, updatedJob, freshJob.date);
  }

  Future<void> _persistWorkAreaChanges() async {
    final scheduleProvider = ProviderScope.containerOf(context, listen: false)
        .read(scheduleRiverpod);
    final freshJob = scheduleProvider.jobs.firstWhere(
      (j) => j.id == widget.job.id,
      orElse: () => widget.job,
    );
    final updatedJob = freshJob.copyWith(
      workMaps: List<CustomPolygon>.from(widget.job.workMaps),
      workingAreas: widget.job.workMaps
          .where((w) => w.isPolygon)
          .map((w) => w.name)
          .where((name) => name.isNotEmpty)
          .toList(),
      dropOffPoint: _dropOffPoint,
    );
    await scheduleProvider.updateJobWithUndo(
        freshJob, updatedJob, freshJob.date);
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
        isPortrait: true, // Always use portrait for print
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    // Use full screen dimensions
    final appBarHeight = AppBar().preferredSize.height;
    final mapWidth = screenWidth;
    final mapHeight = screenHeight - appBarHeight;
    final mapLeft = 0.0;
    final mapTop = 0.0;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Print Map View'),
            if (_polygonOverrides.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_polygonOverrides.length} customized',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          // Reset overrides button (only show when overrides exist)
          if (_polygonOverrides.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reset All Polygon Customizations',
              onPressed: () {
                setState(() {
                  _polygonOverrides.clear();
                  _useBlackBorders = false;
                  _globalBorderWidth = 3;
                  _updateMapView();
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'All polygon customizations and global settings reset'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          // Border width dropdown
          Tooltip(
            message: 'Global Border Width',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: DropdownButton<int>(
                value: _globalBorderWidth,
                icon: const Icon(Icons.line_weight),
                underline: Container(),
                items: [3, 4, 5, 6, 7, 8].map((int value) {
                  return DropdownMenuItem<int>(
                    value: value,
                    child: Text('${value}px'),
                  );
                }).toList(),
                onChanged: (int? newValue) {
                  if (newValue != null) {
                    setState(() {
                      _globalBorderWidth = newValue;
                      _updateMapView();
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content:
                            Text('Global border width set to ${newValue}px'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
            ),
          ),
          // Color toggle button
          IconButton(
            icon: Icon(
              _useBlackBorders ? Icons.palette : Icons.palette_outlined,
              color: _useBlackBorders ? Colors.black : null,
            ),
            tooltip: _useBlackBorders
                ? 'Switch to Original Colors'
                : 'Switch to Black Borders',
            onPressed: () {
              setState(() {
                _useBlackBorders = !_useBlackBorders;
                _updateMapView();
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_useBlackBorders
                      ? 'All borders set to black'
                      : 'Borders restored to original colors'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          // Help button
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Help - How to customize polygons',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Polygon Customization'),
                  content: const Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Global Controls:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 4),
                      Text(
                          '• Dropdown: Set border width for all polygons (3-8px)'),
                      Text(
                          '• Palette icon: Toggle between black and original colors'),
                      SizedBox(height: 12),
                      Text('Edit Points:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 4),
                      Text('1. Tap the edit (pencil) icon to enter edit mode'),
                      Text('2. Tap a polygon to select it for editing'),
                      Text('3. Drag white vertex markers to move points'),
                      Text('4. Drag orange midpoint markers to add new points'),
                      Text('5. Use the toolbar to remove, save, or cancel'),
                      SizedBox(height: 8),
                      Text('• Use refresh button in toolbar to reset all'),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Got it'),
                    ),
                  ],
                ),
              );
            },
          ),

          // Edit points toggle
          IconButton(
            icon: Icon(
              _isEditingVertices ? Icons.edit : Icons.edit_outlined,
              color: _isEditingVertices ? const Color(0xFF1967D2) : null,
            ),
            tooltip:
                _isEditingVertices ? 'Exit edit mode' : 'Edit polygon points',
            onPressed: () {
              setState(() {
                _isEditingVertices = !_isEditingVertices;
                if (!_isEditingVertices) {
                  // Exiting edit mode — cancel any active editing
                  _cancelVertexEditing();
                }
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
          // Full screen map container
          Positioned(
            left: mapLeft,
            top: mapTop,
            child: RepaintBoundary(
              key: _mapKey,
              child: Container(
                width: mapWidth,
                height: mapHeight,
                color: Colors.white,
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
                      polylines: _polylines,
                      markers: {
                        ..._vertexMarkers,
                        ..._customPointMarkers,
                        if (_dropOffMarker != null) _dropOffMarker!,
                      },
                      mapType: MapType.normal,
                      cloudMapId: "89c628d2bb3002712797ce42",
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                      myLocationButtonEnabled: false,
                      scrollGesturesEnabled: !_isDraggingInfoBox &&
                          !_isResizingInfoBox &&
                          !_isDraggingWorkAreasBox &&
                          !_isResizingWorkAreasBox,
                      zoomGesturesEnabled: !_isDraggingInfoBox &&
                          !_isResizingInfoBox &&
                          !_isDraggingWorkAreasBox &&
                          !_isResizingWorkAreasBox,
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
                    // Work Areas Box (only when multiple areas exist)
                    if (widget.job.workMaps.length > 1)
                      Positioned(
                        left: _workAreasBoxPosition.dx,
                        top: _workAreasBoxPosition.dy,
                        child: _buildWorkAreasBox(),
                      ),
                    // Vertex editing toolbar
                    if (_isEditingVertices && _editingPolygonIndex != null)
                      Positioned(
                        bottom: 16,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Material(
                            elevation: 4,
                            borderRadius: BorderRadius.circular(24),
                            color: Colors.white,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Editing: ${widget.job.workMaps[_editingPolygonIndex!].name}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(
                                        Icons.remove_circle_outline,
                                        size: 20,
                                        color: Colors.red),
                                    tooltip: 'Remove last vertex',
                                    onPressed: _editingPoints != null &&
                                            _editingPoints!.length > 3
                                        ? _removeLastVertex
                                        : null,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close,
                                        size: 20, color: Color(0xFF5F6368)),
                                    tooltip: 'Cancel',
                                    onPressed: _cancelVertexEditing,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.check,
                                        size: 20, color: Color(0xFF1967D2)),
                                    tooltip: 'Save changes',
                                    onPressed: _saveVertexEditing,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Edit mode hint (when no polygon selected yet)
                    if (_isEditingVertices && _editingPolygonIndex == null)
                      Positioned(
                        bottom: 16,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Material(
                            elevation: 4,
                            borderRadius: BorderRadius.circular(24),
                            color: Colors.white,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: Text(
                                'Tap a polygon to edit its points',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF5F6368),
                                ),
                              ),
                            ),
                          ),
                        ),
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

          // Movable Work Areas Box (for positioning only - invisible, only when multiple areas exist)
          if (widget.job.workMaps.length > 1)
            Positioned(
              left: mapLeft + _workAreasBoxPosition.dx,
              top: mapTop + _workAreasBoxPosition.dy,
              child: GestureDetector(
                onPanStart: (details) {
                  setState(() {
                    _isDraggingWorkAreasBox = true;
                  });
                },
                onPanUpdate: (details) {
                  setState(() {
                    final newX = _workAreasBoxPosition.dx + details.delta.dx;
                    final newY = _workAreasBoxPosition.dy + details.delta.dy;

                    // Keep the box within the map bounds using dynamic size
                    _workAreasBoxPosition = Offset(
                      newX.clamp(0, mapWidth - _workAreasBoxSize.width),
                      newY.clamp(0, mapHeight - _workAreasBoxSize.height),
                    );
                  });
                },
                onPanEnd: (details) {
                  setState(() {
                    _isDraggingWorkAreasBox = false;
                  });
                },
                child: Stack(
                  children: [
                    // Main draggable container
                    Container(
                      width: _workAreasBoxSize.width,
                      height: _workAreasBoxSize.height,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        border: Border.all(
                          color: (_isDraggingWorkAreasBox ||
                                  _isResizingWorkAreasBox)
                              ? Colors.red.withOpacity(0.8)
                              : Colors.blue.withOpacity(0),
                          width: (_isDraggingWorkAreasBox ||
                                  _isResizingWorkAreasBox)
                              ? 2
                              : 1,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.drag_handle,
                          color: (_isDraggingWorkAreasBox ||
                                  _isResizingWorkAreasBox)
                              ? Colors.red.withOpacity(0.7)
                              : Colors.blue.withOpacity(0),
                          size: 20 * _workAreasFontScale,
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
                            _isResizingWorkAreasBox = true;
                          });
                        },
                        onPanUpdate: (details) {
                          setState(() {
                            final newWidth =
                                _workAreasBoxSize.width + details.delta.dx;
                            final newHeight =
                                _workAreasBoxSize.height + details.delta.dy;

                            // Min and max constraints for size
                            const minSize = Size(200, 60);
                            final maxSize =
                                Size(mapWidth * 0.6, mapHeight * 0.3);

                            _workAreasBoxSize = Size(
                              newWidth.clamp(minSize.width, maxSize.width),
                              newHeight.clamp(minSize.height, maxSize.height),
                            );

                            // Update font scale based on size
                            final sizeRatio = (_workAreasBoxSize.width / 250 +
                                    _workAreasBoxSize.height / 100) /
                                2;
                            _workAreasFontScale = sizeRatio.clamp(0.6, 2.0);

                            // Adjust position if needed to stay within bounds
                            _workAreasBoxPosition = Offset(
                              _workAreasBoxPosition.dx
                                  .clamp(0, mapWidth - _workAreasBoxSize.width),
                              _workAreasBoxPosition.dy.clamp(
                                  0, mapHeight - _workAreasBoxSize.height),
                            );
                          });
                        },
                        onPanEnd: (details) {
                          setState(() {
                            _isResizingWorkAreasBox = false;
                          });
                        },
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: _isResizingWorkAreasBox
                                ? Colors.red.withOpacity(0.8)
                                : Colors.blue.withOpacity(
                                    _isDraggingWorkAreasBox ? 0.6 : 0),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: const Icon(
                            Icons.drag_handle,
                            color: Colors.white,
                            size: 10,
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

            // Map (Working Area) - show single area or indicate multiple
            _buildInfoRow(
                'Map:',
                widget.job.workMaps.isEmpty
                    ? '.'
                    : widget.job.workMaps.length == 1
                        ? widget.job.workMaps.first.name
                        : '${widget.job.workMaps.length} work areas'),

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
            }),

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

  Widget _buildWorkAreasBox() {
    return Container(
      width: _workAreasBoxSize.width,
      height: _workAreasBoxSize.height,
      padding: EdgeInsets.all(8 * _workAreasFontScale),
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
            // Header
            Row(
              children: [
                Icon(Icons.drag_handle,
                    size: 12 * _workAreasFontScale, color: Colors.grey),
                SizedBox(width: 4 * _workAreasFontScale),
                Expanded(
                  child: Text(
                    'Work Areas',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11 * _workAreasFontScale,
                    ),
                  ),
                ),
              ],
            ),
            Divider(thickness: 1 * _workAreasFontScale),

            // Work areas in a single line format
            Wrap(
              spacing: 8 * _workAreasFontScale,
              runSpacing: 4 * _workAreasFontScale,
              children: widget.job.workMaps.asMap().entries.map((entry) {
                final index = entry.key + 1;
                final workMap = entry.value;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10 * _workAreasFontScale,
                      height: 10 * _workAreasFontScale,
                      decoration: BoxDecoration(
                        color: workMap.color,
                        border: Border.all(color: Colors.black, width: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    SizedBox(width: 4 * _workAreasFontScale),
                    Text(
                      '$index. ${workMap.name}',
                      style: TextStyle(
                        fontSize: 9 * _workAreasFontScale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                );
              }).toList(),
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
