import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import '../services/work_area_service.dart';
import '../services/gpx_parser_service.dart';
import '../services/kml_parser_service.dart';
import '../models/work_area.dart';
import '../models/custom_polygon.dart';
import '../models/gpx_track.dart';
import '../providers/job_list_provider.dart';
import '../providers/schedule_provider.dart';
import '../providers/map_view_provider.dart';
import 'mymaps_kml_downloader.dart';

class UpdatedMapView extends StatefulWidget {
  final String? jobId;
  final String? workAreaId;
  final WorkArea? customWorkArea;
  final List<CustomPolygon>?
      customPolygons; // New field for direct polygon support
  final String? title;
  final bool isEditable;

  const UpdatedMapView({
    super.key,
    this.jobId,
    this.workAreaId,
    this.customWorkArea,
    this.customPolygons,
    this.title,
    this.isEditable = false,
  });

  @override
  State<UpdatedMapView> createState() => _UpdatedMapViewState();
}

class _UpdatedMapViewState extends State<UpdatedMapView> {
  GoogleMapController? _controller;
  final Set<Polygon> _polygons = {};
  LatLng _center = const LatLng(-33.925, 18.425); // Cape Town city center
  bool _isLoading = true;
  List<WorkArea> _workAreas = [];
  WorkArea? _selectedWorkArea;
  final List<WorkArea> _editableWorkAreas =
      []; // Collection of work areas for this job

  // State is now managed by MapViewProvider
  // Deprecated fields below are kept for reference but should be removed after full migration:
  // - _isPopupVisible
  // - _customPolygons
  // - _selectedCustomPolygon
  // - _selectedPolygonIndex
  // - _editingPoints
  // - _isEditing
  // - _hasUnsavedChanges
  // - _isCreatingNewPolygon
  // - _newPolygonPoints

  BitmapDescriptor? _circleMarkerIcon;
  BitmapDescriptor? _midpointMarkerIcon;
  int? _draggingMidpointIndex;

  // GPX-related state
  GpxData _gpxData = const GpxData(tracks: []);
  bool _isImportingGpx = false;

  // Client Maps state
  final TextEditingController _clientMapsController = TextEditingController();

  @override
  void initState() {
    super.initState();

    if (kDebugMode) {
      print(
          'InitState: Initializing with ${widget.customPolygons?.length ?? 0} polygons from widget');
    }
    _createMarkerIcons();
    _initializeMap();

    // Add listener to _clientMapsController to update UI when text changes
    _clientMapsController.addListener(() {
      // Just call setState to update any related UI components
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(UpdatedMapView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Get provider reference after super call
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);

    if (kDebugMode) {
      print(
          'didUpdateWidget: Current polygons: ${mapViewProvider.customPolygons.length}, Widget polygons: ${widget.customPolygons?.length ?? 0}');
    }

    // Only update polygons if we're not currently editing and there's new data
    if (!mapViewProvider.isEditing &&
        widget.customPolygons != null &&
        widget.customPolygons != oldWidget.customPolygons) {
      if (kDebugMode) {
        print(
            'Widget updated with new polygons - [hasUnsavedChanges: ${mapViewProvider.hasUnsavedChanges}]');
      }

      // Only update if we don't have unsaved changes
      if (!mapViewProvider.hasUnsavedChanges &&
          mapViewProvider.customPolygons.isEmpty) {
        mapViewProvider.updateAllPolygons(widget.customPolygons!);
        if (widget.customPolygons!.isNotEmpty &&
            mapViewProvider.selectedPolygonIndex == null) {
          mapViewProvider.selectPolygon(0);
        }
        if (kDebugMode) {
          print(
              'Updated internal polygon list - now has ${mapViewProvider.customPolygons.length} polygons');
        }
        _updateMapView();
      }
    }
  }

  Future<void> _createMarkerIcons() async {
    // Create main point marker (existing points)
    await _createCircleMarkerIcon(
      size: 16.0,
      fillColor: Colors.white,
      borderColor: Colors.red,
      borderWidth: 1.5,
    );

    // Create midpoint marker (smaller, different color)
    _midpointMarkerIcon = await _createMidpointMarkerIcon();
  }

  Future<BitmapDescriptor> _createMidpointMarkerIcon() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const double size = 12.0;
    const double radius = size / 2;

    // Draw circle background
    final paint = Paint()
      ..color = Colors.orange
      ..style = PaintingStyle.fill;

    canvas.drawCircle(const Offset(radius, radius), radius - 1.0, paint);

    // Draw border
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawCircle(const Offset(radius, radius), radius - 1.0, borderPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.fromBytes(pngBytes!.buffer.asUint8List());
  }

  List<LatLng> _calculateMidpoints(List<LatLng> points) {
    if (points.length < 3) return [];

    List<LatLng> midpoints = [];
    for (int i = 0; i < points.length; i++) {
      final current = points[i];
      final next =
          points[(i + 1) % points.length]; // Wrap around to first point

      // Calculate midpoint
      final midLat = (current.latitude + next.latitude) / 2;
      final midLng = (current.longitude + next.longitude) / 2;
      midpoints.add(LatLng(midLat, midLng));
    }

    return midpoints;
  }

  Set<Marker> _buildEditingMarkers() {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);
    final editingPoints = mapViewProvider.editingPoints;
    final markers = <Marker>{};

    // Add existing polygon point markers
    for (int i = 0; i < editingPoints.length; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('point_$i'),
          icon: _circleMarkerIcon!,
          position: editingPoints[i],
          draggable: true,
          onDrag: (newPosition) {
            mapViewProvider.updateEditingPoint(i, newPosition);
            _updateMapView();
          },
          onDragEnd: (newPosition) {
            mapViewProvider.updateEditingPoint(i, newPosition);
            _updateMapView();
          },
        ),
      );
    }

    // Add midpoint markers (only if we have at least 3 points for a polygon)
    if (editingPoints.length >= 3) {
      final midpoints = _calculateMidpoints(editingPoints);
      for (int i = 0; i < midpoints.length; i++) {
        markers.add(
          Marker(
            markerId: MarkerId('midpoint_$i'),
            icon: _midpointMarkerIcon!,
            position: midpoints[i],
            draggable: true,
            onDragStart: (position) {
              // When user starts dragging a midpoint, insert it into the polygon
              final insertIndex = i + 1;
              mapViewProvider.insertEditingPoint(insertIndex, position);
              _draggingMidpointIndex = insertIndex;
            },
            onDragEnd: (newPosition) {
              // Update the position of the newly inserted point
              if (_draggingMidpointIndex != null &&
                  _draggingMidpointIndex! <
                      mapViewProvider.editingPoints.length) {
                mapViewProvider.updateEditingPoint(
                    _draggingMidpointIndex!, newPosition);
              }
              _draggingMidpointIndex = null;
              _updateMapView();
            },
          ),
        );
      }
    }

    return markers;
  }

  void _onMapTap(LatLng tappedPoint) {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);

    if (mapViewProvider.isCreatingNewPolygon) {
      // Handle new polygon creation
      mapViewProvider.addPolygonPoint(tappedPoint);
      _updateMapView();
      // Don't auto-center when user is creating a polygon - let them control the view
      return;
    }

    // Clear selection when tapping empty area
    if (mapViewProvider.selectedPolygonIndex != null) {
      mapViewProvider.deselectPolygon();
      _updateMapView();
    }
  }

  Set<Marker> _buildNewPolygonMarkers() {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);
    final newPolygonPoints = mapViewProvider.newPolygonPoints;
    Set<Marker> markers = {};

    // Add markers for new polygon points
    for (int i = 0; i < newPolygonPoints.length; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('new_polygon_point_$i'),
          position: newPolygonPoints[i],
          icon: _circleMarkerIcon ?? BitmapDescriptor.defaultMarker,
          draggable: true,
          onDrag: (newPosition) {
            // For new polygon creation, update the point position
            mapViewProvider.newPolygonPoints[i] = newPosition;
            _updateMapView();
          },
          onDragEnd: (newPosition) {
            // Update the position in the new polygon points
            mapViewProvider.newPolygonPoints[i] = newPosition;
            _updateMapView();
          },
        ),
      );
    }

    return markers;
  }

  Future<void> _createCircleMarkerIcon({
    double size = 16.0,
    Color fillColor = Colors.blue,
    Color borderColor = Colors.white,
    double borderWidth = 2.0,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final double radius = size / 2;

    // Draw circle background
    final paint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(radius, radius), radius - borderWidth, paint);

    // Draw border
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    canvas.drawCircle(
        Offset(radius, radius), radius - borderWidth, borderPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);

    _circleMarkerIcon =
        BitmapDescriptor.fromBytes(pngBytes!.buffer.asUint8List());
  }

  Future<void> _initializeMap() async {
    try {
      // Get provider reference
      final mapViewProvider =
          Provider.of<MapViewProvider>(context, listen: false);

      // Check if we're using the new CustomPolygon system
      if (widget.customPolygons != null && widget.customPolygons!.isNotEmpty) {
        // New system: Initialize with CustomPolygons (only if not already initialized)
        if (mapViewProvider.customPolygons.isEmpty) {
          mapViewProvider.updateAllPolygons(widget.customPolygons!);
          print(
              'Initialized ${mapViewProvider.customPolygons.length} custom polygons');
        }
        if (mapViewProvider.customPolygons.isNotEmpty &&
            mapViewProvider.selectedPolygonIndex == null) {
          mapViewProvider.selectPolygon(0);

          // Don't automatically start editing - let user select which polygon to edit
          // User needs to tap a polygon and then press edit button
        }
      } else {
        // Legacy system: Load WorkAreas from service
        final workAreaService = context.read<WorkAreaService>();
        _workAreas = await workAreaService.getWorkAreas().first;

        // Initialize the editable work areas collection for this job
        _editableWorkAreas.clear();

        // Find selected work area and add it to the editable collection
        if (widget.workAreaId != null && widget.workAreaId!.isNotEmpty) {
          try {
            _selectedWorkArea = _workAreas.firstWhere(
              (area) => area.id == widget.workAreaId,
            );
            _editableWorkAreas.add(_selectedWorkArea!);
          } catch (e) {
            if (widget.customWorkArea != null) {
              _selectedWorkArea = widget.customWorkArea;
              _editableWorkAreas.add(_selectedWorkArea!);
            }
          }
        } else if (widget.customWorkArea != null) {
          _selectedWorkArea = widget.customWorkArea;
          _editableWorkAreas.add(_selectedWorkArea!);
        }

        // Initialize editing points if editing is enabled and we have a selected area
        if (widget.isEditable && _selectedWorkArea != null) {
          final mapViewProvider =
              Provider.of<MapViewProvider>(context, listen: false);
          mapViewProvider
              .updateEditingPoints(List.from(_selectedWorkArea!.polygonPoints));
          mapViewProvider.startEditing(0);
        }
      }

      _updateMapView();
    } catch (e) {
      print('Error initializing map: $e');
      // Set a default center if initialization fails
      _center = const LatLng(-33.925, 18.425); // Cape Town city center
    } finally {
      if (mounted) {
        _isLoading = false;
        _updateMapView(); // This will trigger a rebuild
      }
    }
  }

  void _updateMapView() {
    _polygons.clear();
    // Get provider data
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);
    final customPolygons = mapViewProvider.customPolygons;
    final selectedPolygonIndex = mapViewProvider.selectedPolygonIndex;
    final isEditing = mapViewProvider.isEditing;
    final editingPoints = mapViewProvider.editingPoints;
    final isCreatingNewPolygon = mapViewProvider.isCreatingNewPolygon;
    final newPolygonPoints = mapViewProvider.newPolygonPoints;
    final isPopupVisible = mapViewProvider.isPopupVisible;

    print(
        '_updateMapView called: ${customPolygons.length} custom polygons available [widget.customPolygons length: ${widget.customPolygons?.length ?? 0}]');

    // Check if we're using the new CustomPolygon system
    if (customPolygons.isNotEmpty) {
      // New system: Add CustomPolygons
      for (int i = 0; i < customPolygons.length; i++) {
        final customPolygon = customPolygons[i];
        final isCurrentlyEditing = isEditing && i == selectedPolygonIndex;
        final isSelected = i == selectedPolygonIndex;

        final polygonPoints =
            isCurrentlyEditing ? editingPoints : customPolygon.points;
        print(
            'Rendering polygon $i: isEditing=$isCurrentlyEditing, points=${polygonPoints.length}');

        _polygons.add(
          Polygon(
            polygonId: PolygonId('custom_polygon_$i'),
            points: polygonPoints,
            fillColor: isCurrentlyEditing
                ? Colors.red.withOpacity(0.1)
                : isSelected
                    ? Colors.red.withOpacity(0.1)
                    : customPolygon.color.withOpacity(0.2),
            strokeColor: isCurrentlyEditing
                ? Colors.red
                : isSelected
                    ? Colors.red
                    : customPolygon.color,
            strokeWidth: isCurrentlyEditing
                ? 5
                : isSelected
                    ? 4
                    : 2,
            onTap: !isEditing && !isCreatingNewPolygon && !isPopupVisible
                ? () {
                    mapViewProvider.selectPolygon(i);
                    _updateMapView();
                    // Show polygon info popup at polygon center
                    final center =
                        _calculatePolygonCenter(customPolygon.points);
                    _showPolygonInfoPopup(i, center);
                  }
                : null,
          ),
        );
      }
    } else {
      // Legacy system: Add WorkAreas
      final mapViewProvider =
          Provider.of<MapViewProvider>(context, listen: false);
      for (int i = 0; i < _editableWorkAreas.length; i++) {
        final area = _editableWorkAreas[i];
        final isCurrentlyEditing =
            mapViewProvider.isEditing && area == _selectedWorkArea;
        final isSelected = area == _selectedWorkArea;

        _polygons.add(
          Polygon(
            polygonId: PolygonId(area.id.isNotEmpty ? area.id : 'area_$i'),
            points: isCurrentlyEditing
                ? mapViewProvider.editingPoints
                : area.polygonPoints,
            fillColor: isSelected
                ? Colors.red.withOpacity(0.1)
                : Colors.orange.withOpacity(0.05),
            strokeColor: isCurrentlyEditing
                ? Colors.red
                : isSelected
                    ? Colors.red
                    : Colors.orange,
            strokeWidth: isCurrentlyEditing
                ? 5
                : isSelected
                    ? 4
                    : 2,
            onTap: !mapViewProvider.isEditing &&
                    !mapViewProvider.isCreatingNewPolygon
                ? () {
                    _selectedWorkArea = area;
                    _updateMapView();
                  }
                : null,
          ),
        );
      }
    }

    // Add new polygon being created
    if (isCreatingNewPolygon && newPolygonPoints.length > 2) {
      _polygons.add(
        Polygon(
          polygonId: const PolygonId('new_polygon'),
          points: newPolygonPoints,
          fillColor: Colors.blue.withOpacity(0.2),
          strokeColor: Colors.blue,
          strokeWidth: 3,
        ),
      );
    }

    // Center map on selected area or all areas
    _updateMapCenter();
  }

  void _updateMapCenter({bool forceUpdate = false}) {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);

    // Only auto-center on initial load or when explicitly requested
    if (mapViewProvider.hasInitiallyPositioned && !forceUpdate) {
      return;
    }

    List<LatLng> points = [];

    // Check if we're using the new CustomPolygon system
    if (mapViewProvider.customPolygons.isNotEmpty) {
      // New system: Include custom polygons in center calculation
      for (int i = 0; i < mapViewProvider.customPolygons.length; i++) {
        final customPolygon = mapViewProvider.customPolygons[i];
        if (i == mapViewProvider.selectedPolygonIndex &&
            mapViewProvider.isEditing) {
          points.addAll(mapViewProvider.editingPoints);
        } else {
          points.addAll(customPolygon.points);
        }
      }
    } else {
      // Legacy system: Include all editable work areas in the center calculation
      for (final area in _editableWorkAreas) {
        if (area == _selectedWorkArea && mapViewProvider.isEditing) {
          points.addAll(mapViewProvider.editingPoints);
        } else {
          points.addAll(area.polygonPoints);
        }
      }
    }

    // Also include new polygon points if creating
    if (mapViewProvider.isCreatingNewPolygon) {
      points.addAll(mapViewProvider.newPolygonPoints);
    }

    if (points.isNotEmpty) {
      if (points.length == 1) {
        // Single point - just center on it with a reasonable zoom level
        _center = points.first;
        if (_controller != null && mounted) {
          try {
            _controller!.animateCamera(
              CameraUpdate.newLatLngZoom(
                  _center, 16.0), // Good zoom level for single point
            );
            // Mark as initially positioned after successful camera animation
            mapViewProvider.markAsInitiallyPositioned();
          } catch (e) {
            print('Error animating camera to single point: $e');
          }
        }
      } else {
        // Multiple points - calculate bounds
        double minLat = 90;
        double maxLat = -90;
        double minLng = 180;
        double maxLng = -180;

        for (final point in points) {
          minLat = math.min(minLat, point.latitude);
          maxLat = math.max(maxLat, point.latitude);
          minLng = math.min(minLng, point.longitude);
          maxLng = math.max(maxLng, point.longitude);
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
                100, // Increased padding for better visualization
              ),
            );
            // Mark as initially positioned after successful camera animation
            mapViewProvider.markAsInitiallyPositioned();
          } catch (e) {
            print('Error animating camera: $e');
          }
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
          // Mark as initially positioned after successful camera animation
          mapViewProvider.markAsInitiallyPositioned();
        } catch (e) {
          print('Error setting default camera position: $e');
        }
      }
    }
  }

  Future<bool> _showDiscardDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard Changes?'),
        content: const Text(
          'You have unsaved changes to the area boundary. Are you sure you want to discard them?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showPolygonInfoPopup(int polygonIndex, LatLng tapPosition) async {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);
    if (polygonIndex >= mapViewProvider.customPolygons.length) return;

    final polygon = mapViewProvider.customPolygons[polygonIndex];
    final area = _calculatePolygonArea(polygon.points);
    final perimeter = _calculatePolygonPerimeter(polygon.points);

    // Set popup state to disable polygon onTap
    mapViewProvider.openPopup(polygonIndex, tapPosition);

    // Convert LatLng to screen coordinates for positioning
    final screenPoint = await _controller?.getScreenCoordinate(tapPosition);
    double left = screenPoint?.x.toDouble() ?? 50;
    double top = screenPoint?.y.toDouble() ?? 100;

    // Adjust position to keep popup on screen
    final screenSize = MediaQuery.of(context).size;
    const popupWidth = 280.0;
    const popupHeight = 200.0;

    if (left + popupWidth > screenSize.width) {
      left = screenSize.width - popupWidth - 20;
    }
    if (left < 20) {
      left = 20;
    }

    if (top + popupHeight > screenSize.height) {
      top = screenSize.height - popupHeight - 20;
    }
    if (top < 100) {
      top = 100;
    }

    showDialog(
      context: context,
      barrierColor: Colors.black26,
      barrierDismissible: false,
      builder: (context) => Stack(
        children: [
          // Positioned popup near the tap location
          Positioned(
            left: left,
            top: top,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 280,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header with close button
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            polygon.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            // Prevent event propagation and close the dialog
                            Navigator.of(context).pop();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Icon(
                              Icons.close,
                              size: 20,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Area and perimeter info
                    Row(
                      children: [
                        Icon(Icons.crop_free,
                            size: 16, color: Colors.grey.shade600),
                        const SizedBox(width: 4),
                        Text(
                          '${area.toStringAsFixed(2)} km²',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Icon(Icons.straighten,
                            size: 16, color: Colors.grey.shade600),
                        const SizedBox(width: 4),
                        Text(
                          '${perimeter.toStringAsFixed(1)} km',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Action buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildActionButton(
                          icon: Icons.edit,
                          onPressed: () {
                            Navigator.of(context).pop();
                            _startEditingPolygon(polygonIndex);
                          },
                          tooltip: 'Edit Points',
                        ),
                        _buildActionButton(
                          icon: Icons.palette,
                          onPressed: () {
                            Navigator.of(context).pop();
                            _showEditNameDialog();
                          },
                          tooltip: 'Edit Properties',
                        ),
                        _buildActionButton(
                          icon: Icons.camera_alt,
                          onPressed: () {
                            Navigator.of(context).pop();
                            _zoomToPolygon(polygonIndex);
                          },
                          tooltip: 'Zoom to Polygon',
                        ),
                        _buildActionButton(
                          icon: Icons.delete,
                          onPressed: () {
                            Navigator.of(context).pop();
                            _deletePolygon(polygonIndex);
                          },
                          tooltip: 'Delete',
                          color: Colors.red,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ).then((_) {
      // Reset popup state when dialog closes and deselect the polygon
      if (mounted) {
        // Add a small delay to ensure tap events are not processed during dialog dismissal
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            mapViewProvider.closePopup();
            _updateMapView();
          }
        });
      }
    });
  }

  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback onPressed,
    required String tooltip,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (color ?? Colors.grey.shade600).withOpacity(0.1),
          ),
          child: Icon(
            icon,
            size: 20,
            color: color ?? Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  double _calculatePolygonArea(List<LatLng> points) {
    if (points.length < 3) return 0.0;

    // Using the shoelace formula for polygon area
    double area = 0.0;
    for (int i = 0; i < points.length; i++) {
      int j = (i + 1) % points.length;
      area += points[i].longitude * points[j].latitude;
      area -= points[j].longitude * points[i].latitude;
    }
    area = area.abs() / 2.0;

    // Convert to km² (rough approximation)
    // At Cape Town latitude, 1 degree ≈ 111 km
    const double kmPerDegree = 111.0;
    return area * kmPerDegree * kmPerDegree;
  }

  double _calculatePolygonPerimeter(List<LatLng> points) {
    if (points.length < 2) return 0.0;

    double perimeter = 0.0;
    for (int i = 0; i < points.length; i++) {
      int j = (i + 1) % points.length;
      perimeter += _distanceBetweenPoints(points[i], points[j]);
    }

    return perimeter;
  }

  double _distanceBetweenPoints(LatLng point1, LatLng point2) {
    // Haversine formula for distance between two points
    const double earthRadius = 6371.0; // km

    double lat1Rad = point1.latitude * (math.pi / 180.0);
    double lat2Rad = point2.latitude * (math.pi / 180.0);
    double deltaLatRad =
        (point2.latitude - point1.latitude) * (math.pi / 180.0);
    double deltaLngRad =
        (point2.longitude - point1.longitude) * (math.pi / 180.0);

    double a = math.sin(deltaLatRad / 2) * math.sin(deltaLatRad / 2) +
        math.cos(lat1Rad) *
            math.cos(lat2Rad) *
            math.sin(deltaLngRad / 2) *
            math.sin(deltaLngRad / 2);
    double c = 2 * math.asin(math.sqrt(a));

    return earthRadius * c;
  }

  LatLng _calculatePolygonCenter(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(-33.925, 18.425);

    if (points.length == 1) return points.first;

    // Calculate centroid of polygon
    double centerLat = 0;
    double centerLng = 0;

    for (final point in points) {
      centerLat += point.latitude;
      centerLng += point.longitude;
    }

    return LatLng(centerLat / points.length, centerLng / points.length);
  }

  void _startEditingPolygon(int polygonIndex) {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);
    if (polygonIndex >= mapViewProvider.customPolygons.length) return;

    mapViewProvider.startEditing(polygonIndex);
    _updateMapView();
  }

  void _zoomToPolygon(int polygonIndex) {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);
    if (polygonIndex >= mapViewProvider.customPolygons.length) return;

    final points = mapViewProvider.customPolygons[polygonIndex].points;
    if (points.isEmpty) return;

    if (points.length == 1) {
      _controller?.animateCamera(
        CameraUpdate.newLatLngZoom(points.first, 15),
      );
    } else {
      double minLat = 90;
      double maxLat = -90;
      double minLng = 180;
      double maxLng = -180;

      for (final point in points) {
        minLat = math.min(minLat, point.latitude);
        maxLat = math.max(maxLat, point.latitude);
        minLng = math.min(minLng, point.longitude);
        maxLng = math.max(maxLng, point.longitude);
      }

      _controller?.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng),
          ),
          100,
        ),
      );
    }
  }

  void _deletePolygon(int polygonIndex) {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);
    if (polygonIndex >= mapViewProvider.customPolygons.length) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Polygon'),
        content: Text(
          'Are you sure you want to delete "${mapViewProvider.customPolygons[polygonIndex].name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              mapViewProvider.deletePolygon(polygonIndex);
              _updateMapView();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _saveChanges() async {
    try {
      final mapViewProvider =
          Provider.of<MapViewProvider>(context, listen: false);

      // Apply editing changes if in editing mode
      if (mapViewProvider.isEditing &&
          mapViewProvider.selectedPolygonIndex != null) {
        print(
            'Saving polygon changes: ${mapViewProvider.editingPoints.length} points');
        mapViewProvider.saveEditingChanges();
        print(
            'Updated polygon: ${mapViewProvider.editingPoints.length} points');
      }

      // Save polygon data to database if we have a jobId
      if (widget.jobId != null && mounted) {
        bool jobUpdated = false;

        // Try to find and update job in JobListProvider first
        try {
          final jobListProvider =
              Provider.of<JobListProvider>(context, listen: false);
          final job = jobListProvider.jobListItems.firstWhere(
            (job) => job.id == widget.jobId,
          );

          // Update the job with current polygon data
          final updatedJob = job.copyWith(
            customPolygons:
                List<CustomPolygon>.from(mapViewProvider.customPolygons),
          );

          // Save to database via JobListProvider
          await jobListProvider.updateJobListItem(updatedJob);
          jobUpdated = true;
          if (kDebugMode) {
            print(
                'Saved ${mapViewProvider.customPolygons.length} polygons to JobList database for job ${widget.jobId}');
          }
        } catch (e) {
          if (kDebugMode) {
            print('Job not found in JobListProvider: $e');
          }
        }

        // If not found in JobListProvider, try ScheduleProvider
        if (!jobUpdated) {
          try {
            final scheduleProvider =
                Provider.of<ScheduleProvider>(context, listen: false);
            final job = scheduleProvider.jobs.firstWhere(
              (job) => job.id == widget.jobId,
            );

            // Update the job with current polygon data by updating workMaps
            final updatedJob = job.copyWith(
              workMaps:
                  List<CustomPolygon>.from(mapViewProvider.customPolygons),
            );

            // Save to database via ScheduleProvider
            await scheduleProvider.updateJob(updatedJob);
            jobUpdated = true;
            print(
                'Saved ${mapViewProvider.customPolygons.length} polygons to Schedule database for job ${widget.jobId} as workMaps');
          } catch (e) {
            print('Job not found in ScheduleProvider: $e');
          }
        }

        if (!jobUpdated) {
          throw Exception(
              'Job with ID ${widget.jobId} not found in any provider');
        }
      }

      // Exit editing mode and update map
      mapViewProvider.cancelEditing();
      _updateMapView();

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.jobId != null
              ? 'Changes saved to database!'
              : 'Changes saved! Continue editing or close when finished.'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving changes: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _showEditNameDialog() async {
    final mapViewProvider =
        Provider.of<MapViewProvider>(context, listen: false);
    if (mapViewProvider.selectedCustomPolygon == null ||
        mapViewProvider.selectedPolygonIndex == null) {
      return;
    }

    final TextEditingController nameController = TextEditingController(
      text: mapViewProvider.selectedCustomPolygon!.name,
    );

    Color selectedColor = mapViewProvider.selectedCustomPolygon!.color;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit Polygon Properties'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Enter polygon name',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              const Text('Color:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Colors.blue,
                  Colors.red,
                  Colors.green,
                  Colors.orange,
                  Colors.purple,
                  Colors.teal,
                  Colors.indigo,
                  Colors.brown,
                  Colors.pink,
                  Colors.cyan,
                ]
                    .map((color) => GestureDetector(
                          onTap: () {
                            setDialogState(() {
                              selectedColor = color;
                            });
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selectedColor == color
                                    ? Colors.black
                                    : Colors.grey.shade300,
                                width: selectedColor == color ? 3 : 1,
                              ),
                            ),
                            child: selectedColor == color
                                ? const Icon(Icons.check, color: Colors.white)
                                : null,
                          ),
                        ))
                    .toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final newName = nameController.text.trim();
                if (newName.isNotEmpty) {
                  Navigator.of(context).pop({
                    'name': newName,
                    'color': selectedColor,
                  });
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result != null && mapViewProvider.selectedPolygonIndex != null) {
      // Update the polygon with the new name and color
      mapViewProvider.updatePolygonProperty(
        mapViewProvider.selectedPolygonIndex!,
        name: result['name'] as String,
        color: result['color'] as Color,
      );
      _updateMapView();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewProvider>(
      builder: (context, mapViewProvider, child) {
        return Scaffold(
          appBar: AppBar(
            leading: CloseButton(onPressed: () async {
              // Check for unsaved changes before closing
              if (mapViewProvider.hasUnsavedChanges) {
                final shouldDiscard = await _showDiscardDialog();
                if (!shouldDiscard) return;
              }

              // Return updated CustomPolygons if available
              if (mapViewProvider.customPolygons.isNotEmpty) {
                Navigator.of(context).pop(mapViewProvider.customPolygons);
              } else {
                Navigator.of(context).pop();
              }
            }),
            title: Text(
              '${widget.title ?? 'Map View'}${mapViewProvider.hasUnsavedChanges ? ' •' : ''}',
            ),
            actions: widget.isEditable
                ? [
                    // Create new area button (always available when editable)
                    if (!mapViewProvider.isEditing &&
                        !mapViewProvider.isCreatingNewPolygon)
                      IconButton(
                        icon: const Icon(Icons.add_location),
                        tooltip: 'Create new area',
                        onPressed: () {
                          mapViewProvider.startCreatingPolygon();
                          _updateMapView();
                        },
                      ),

                    // Edit existing area button (only when area is selected)
                    if (!mapViewProvider.isEditing &&
                        !mapViewProvider.isCreatingNewPolygon &&
                        (_selectedWorkArea != null ||
                            mapViewProvider.selectedCustomPolygon != null))
                      IconButton(
                        icon: const Icon(Icons.edit),
                        tooltip: 'Edit area boundary',
                        onPressed: () {
                          if (mapViewProvider.selectedPolygonIndex != null) {
                            mapViewProvider.startEditing(
                                mapViewProvider.selectedPolygonIndex!);
                            _updateMapView();
                          }
                        },
                      ),

                    // Edit polygon properties button (only for CustomPolygons)
                    if (!mapViewProvider.isEditing &&
                        !mapViewProvider.isCreatingNewPolygon &&
                        mapViewProvider.selectedCustomPolygon != null)
                      IconButton(
                        icon: const Icon(Icons.edit_note),
                        tooltip: 'Edit polygon name & color',
                        onPressed: _showEditNameDialog,
                      ),

                    // Cancel buttons for editing/creating
                    if (mapViewProvider.isEditing ||
                        mapViewProvider.isCreatingNewPolygon)
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: mapViewProvider.isCreatingNewPolygon
                            ? 'Cancel creation'
                            : 'Cancel changes',
                        onPressed: () async {
                          if (mapViewProvider.isEditing &&
                              mapViewProvider.hasUnsavedChanges) {
                            final shouldDiscard = await _showDiscardDialog();
                            if (!shouldDiscard) return;
                          }
                          mapViewProvider.cancelEditing();
                          mapViewProvider.cancelCreatingPolygon();
                          _updateMapView();
                        },
                      ),

                    // Single "Save Changes" button - only appears when there are unsaved changes
                    if (mapViewProvider.hasUnsavedChanges)
                      ElevatedButton.icon(
                        icon: const Icon(Icons.save, size: 16),
                        label: const Text('Save Changes'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                        ),
                        onPressed: _saveChanges,
                      ),

                    // Finish creation button for new polygons
                    if (mapViewProvider.isCreatingNewPolygon &&
                        mapViewProvider.newPolygonPoints.length >= 3)
                      IconButton(
                        icon: const Icon(Icons.check),
                        tooltip: 'Finish creating area',
                        onPressed: () async {
                          try {
                            print(
                                'Creating new polygon with ${mapViewProvider.newPolygonPoints.length} points');

                            // Finish creating the polygon via provider
                            mapViewProvider.finishCreatingPolygon();
                            print(
                                'Added polygon to local state. Total polygons: ${mapViewProvider.customPolygons.length}');
                            _updateMapView();

                            // Save to database if we have a jobId
                            if (widget.jobId != null && mounted) {
                              print(
                                  'Attempting to save polygon to database for job ${widget.jobId}');
                              bool jobUpdated = false;

                              // Try to find and update job in JobListProvider first
                              try {
                                final jobListProvider =
                                    Provider.of<JobListProvider>(context,
                                        listen: false);
                                final job =
                                    jobListProvider.jobListItems.firstWhere(
                                  (job) => job.id == widget.jobId,
                                );

                                print(
                                    'Found job in JobListProvider - updating with ${mapViewProvider.customPolygons.length} polygons');

                                // Update the job with current polygon data
                                final updatedJob = job.copyWith(
                                  customPolygons: List<CustomPolygon>.from(
                                      mapViewProvider.customPolygons),
                                );

                                // Save to database via JobListProvider
                                await jobListProvider
                                    .updateJobListItem(updatedJob);
                                jobUpdated = true;
                                print(
                                    'Successfully saved ${mapViewProvider.customPolygons.length} polygon(s) to JobList database for job ${widget.jobId}');
                              } catch (e) {
                                print('Job not found in JobListProvider: $e');
                              }

                              // If not found in JobListProvider, try ScheduleProvider
                              if (!jobUpdated) {
                                try {
                                  final scheduleProvider =
                                      Provider.of<ScheduleProvider>(context,
                                          listen: false);
                                  final job = scheduleProvider.jobs.firstWhere(
                                    (job) => job.id == widget.jobId,
                                  );

                                  print(
                                      'Found job in ScheduleProvider - updating workMaps with ${mapViewProvider.customPolygons.length} polygons');

                                  // Update the job with current polygon data by updating workMaps
                                  final updatedJob = job.copyWith(
                                    workMaps: List<CustomPolygon>.from(
                                        mapViewProvider.customPolygons),
                                  );

                                  // Save to database via ScheduleProvider
                                  await scheduleProvider.updateJob(updatedJob);
                                  jobUpdated = true;
                                  print(
                                      'Successfully saved ${mapViewProvider.customPolygons.length} polygon(s) to Schedule database for job ${widget.jobId} as workMaps');
                                } catch (e) {
                                  print(
                                      'Job not found in ScheduleProvider: $e');
                                }
                              }

                              if (jobUpdated) {
                                // Show success message
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        'Area created and saved to database! (Total: ${mapViewProvider.customPolygons.length} areas)'),
                                    backgroundColor: Colors.green,
                                    duration: const Duration(seconds: 3),
                                  ),
                                );
                              } else {
                                throw Exception(
                                    'Job with ID ${widget.jobId} not found in any provider');
                              }
                            } else {
                              print(
                                  'No jobId provided - marking as unsaved changes');
                              mapViewProvider
                                  .markAsInitiallyPositioned(); // Mark as modified

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      'Area created! (${mapViewProvider.customPolygons.length} total) - Click "Save Changes" to save to database.'),
                                  backgroundColor: Colors.green,
                                  duration: const Duration(seconds: 3),
                                ),
                              );
                            }
                          } catch (e) {
                            print('Error creating area: $e');
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error creating area: $e'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        },
                      ),
                  ]
                : null,
          ),
          body: Row(
            children: [
              // Left Sidebar for GPX tracks
              if (mapViewProvider.isSidebarVisible)
                Container(
                  width: 300,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      right: BorderSide(color: Colors.grey.shade300),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(2, 0),
                      ),
                    ],
                  ),
                  child: _buildGpxSidebar(),
                ),

              // Main map view
              Expanded(
                child: Stack(
                  children: [
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
                      onTap: _onMapTap,

                      initialCameraPosition:
                          CameraPosition(target: _center, zoom: 12),
                      polygons: _polygons,
                      polylines:
                          _gpxData.allPolylines.toSet(), // Add GPX polylines
                      markers: mapViewProvider.isEditing &&
                              _circleMarkerIcon != null &&
                              _midpointMarkerIcon != null
                          ? _buildEditingMarkers()
                          : mapViewProvider.isCreatingNewPolygon
                              ? _buildNewPolygonMarkers()
                              : {},
                      mapType: MapType.normal,
                      myLocationEnabled: true,
                      myLocationButtonEnabled: true,
                      zoomControlsEnabled: true,
                      zoomGesturesEnabled: true,
                    ),

                    // Sidebar toggle button
                    Positioned(
                      top: 16,
                      left: 16,
                      child: FloatingActionButton(
                        mini: true,
                        onPressed: () {
                          mapViewProvider.toggleSidebar();
                          // No setState needed as toggleSidebar already calls notifyListeners
                        },
                        tooltip: mapViewProvider.isSidebarVisible
                            ? 'Hide sidebar'
                            : 'Show sidebar',
                        child: Icon(mapViewProvider.isSidebarVisible
                            ? Icons.close
                            : Icons.menu),
                      ),
                    ),

                    if (_isLoading)
                      Container(
                        color: Colors.black45,
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                    if (mapViewProvider.isEditing ||
                        mapViewProvider.isCreatingNewPolygon)
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Undo button for editing existing polygon
                            if (mapViewProvider.isEditing &&
                                mapViewProvider.editingPoints.isNotEmpty)
                              FloatingActionButton(
                                heroTag: 'undo_edit',
                                onPressed: () {
                                  mapViewProvider.updateEditingPoints(
                                    List<LatLng>.from(
                                        mapViewProvider.editingPoints)
                                      ..removeLast(),
                                  );
                                  _updateMapView();
                                },
                                child: const Icon(Icons.undo),
                              ),
                            // Undo button for creating new polygon
                            if (mapViewProvider.isCreatingNewPolygon &&
                                mapViewProvider.newPolygonPoints.isNotEmpty)
                              FloatingActionButton(
                                heroTag: 'undo_create',
                                onPressed: () {
                                  if (mapViewProvider
                                      .newPolygonPoints.isNotEmpty) {
                                    // Create a copy of the current points without the last one
                                    final points = List<LatLng>.from(
                                        mapViewProvider.newPolygonPoints);
                                    points.removeLast();

                                    // Store current polygons
                                    final existingPolygons =
                                        List<CustomPolygon>.from(
                                            mapViewProvider.customPolygons);

                                    // Reset polygon creation state and restart with fewer points
                                    mapViewProvider.cancelCreatingPolygon();
                                    mapViewProvider.startCreatingPolygon();

                                    // Add all points except the last one back
                                    for (var point in points) {
                                      mapViewProvider.addPolygonPoint(point);
                                    }

                                    // Ensure existing polygons are preserved
                                    if (existingPolygons.isNotEmpty) {
                                      mapViewProvider
                                          .updateAllPolygons(existingPolygons);
                                    }

                                    _updateMapView();
                                  }
                                },
                                child: const Icon(Icons.undo),
                              ),
                          ],
                        ),
                      ),
                    // Instructions overlay for new polygon creation
                    if (mapViewProvider.isCreatingNewPolygon)
                      Positioned(
                        top: 16,
                        left: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Tap on the map to add points for your new area. You need at least 3 points to create an area.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),

                    // Instructions overlay for polygon selection
                    if (!mapViewProvider.isCreatingNewPolygon &&
                        !mapViewProvider.isEditing &&
                        _editableWorkAreas.length > 1)
                      Positioned(
                        top: 16,
                        left: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Tap on any polygon to select it, then tap the Edit button to modify it.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGpxSidebar() {
    return Column(
      children: [
        // GPX Tracks Section
        Expanded(
          flex: 2,
          child: Column(
            children: [
              // GPX Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  border: Border(
                    bottom: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.layers, color: Colors.blue.shade700),
                    const SizedBox(width: 8),
                    Text(
                      'GPX Tracks',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ],
                ),
              ),

              // Import button
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isImportingGpx ? null : _importGpxFiles,
                    icon: _isImportingGpx
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.file_upload),
                    label: Text(
                        _isImportingGpx ? 'Importing...' : 'Import GPX Files'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),

              // Track list
              Expanded(
                child: _gpxData.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.route, size: 48, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'No GPX tracks loaded',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Import GPX files to see tracks here',
                              style: TextStyle(color: Colors.grey),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        itemCount: _gpxData.tracks.length,
                        itemBuilder: (context, index) {
                          final track = _gpxData.tracks[index];
                          return _buildTrackListItem(track, index);
                        },
                      ),
              ),

              // Footer with track count
              if (_gpxData.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    border: Border(
                      top: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: Colors.grey.shade600),
                      const SizedBox(width: 8),
                      Text(
                        '${_gpxData.trackCount} tracks (${_gpxData.visibleTrackCount} visible)',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),

        // Client Maps Section
        Expanded(
          flex: 1,
          child: _buildClientMapsSection(),
        ),
      ],
    );
  }

  Widget _buildClientMapsSection() {
    return Consumer<JobListProvider>(
      builder: (context, jobListProvider, child) {
        return Column(
          children: [
            // Client Maps Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                border: Border(
                  top: BorderSide(color: Colors.grey.shade300),
                  bottom: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.map, color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  Text(
                    'Client Maps',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange.shade700,
                    ),
                  ),
                ],
              ),
            ),

            // URL/Text input with client suggestions
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 24),

                    // KML Downloader Widget
                    MyMapsKmlDownloader(
                      onKmlDataRetrieved: _handleKmlData,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTrackListItem(GpxTrack track, int index) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        dense: true,
        leading: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: track.color,
            shape: BoxShape.circle,
          ),
          child: track.isVisible
              ? const Icon(Icons.visibility, color: Colors.white, size: 16)
              : const Icon(Icons.visibility_off, color: Colors.white, size: 16),
        ),
        title: Text(
          track.name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${track.allPoints.length} points • ${track.segments.length} segments',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            Text(
              'From: ${track.fileName}',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) => _handleTrackAction(value, track, index),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'toggle_visibility',
              child: Row(
                children: [
                  Icon(track.isVisible
                      ? Icons.visibility_off
                      : Icons.visibility),
                  const SizedBox(width: 8),
                  Text(track.isVisible ? 'Hide' : 'Show'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'zoom_to',
              child: Row(
                children: [
                  Icon(Icons.zoom_in),
                  SizedBox(width: 8),
                  Text('Zoom to track'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'remove',
              child: Row(
                children: [
                  Icon(Icons.delete, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Remove', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
        onTap: () => _toggleTrackVisibility(track, index),
      ),
    );
  }

  Future<void> _importGpxFiles() async {
    _isImportingGpx = true;
    // Manually trigger rebuild since this is UI-only state
    if (mounted) {
      setState(() {});
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gpx'],
        allowMultiple: true,
        withData: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final newTracks = <GpxTrack>[];

        for (final file in result.files) {
          if (file.bytes != null && file.name.toLowerCase().endsWith('.gpx')) {
            try {
              final gpxData = await GpxParserService.parseGpxFile(
                file.bytes!,
                file.name,
              );
              newTracks.addAll(gpxData.tracks);
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to parse ${file.name}: $e'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }
          }
        }

        if (newTracks.isNotEmpty) {
          final allTracks = List<GpxTrack>.from(_gpxData.tracks);
          allTracks.addAll(newTracks);
          _gpxData = GpxData(tracks: allTracks);
          _updateMapView();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content:
                    Text('Imported ${newTracks.length} tracks successfully'),
                backgroundColor: Colors.green,
              ),
            );

            // Zoom to fit all tracks
            _zoomToAllTracks();
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error importing GPX files: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        _isImportingGpx = false;
        // Manually trigger a rebuild since this is UI-only state
        setState(() {});
      }
    }
  }

  void _handleTrackAction(String action, GpxTrack track, int index) {
    switch (action) {
      case 'toggle_visibility':
        _toggleTrackVisibility(track, index);
        break;
      case 'zoom_to':
        _zoomToTrack(track);
        break;
      case 'remove':
        _removeTrack(index);
        break;
    }
  }

  void _toggleTrackVisibility(GpxTrack track, int index) {
    final updatedTracks = List<GpxTrack>.from(_gpxData.tracks);
    updatedTracks[index] = track.copyWith(isVisible: !track.isVisible);

    _gpxData = GpxData(tracks: updatedTracks);
    _updateMapView();
  }

  void _zoomToTrack(GpxTrack track) {
    final bounds = track.bounds;
    if (bounds != null && _controller != null) {
      _controller!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 100),
      );
    }
  }

  void _zoomToAllTracks() {
    final bounds = _gpxData.combinedBounds;
    if (bounds != null && _controller != null) {
      _controller!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 100),
      );
    }
  }

  void _removeTrack(int index) {
    final updatedTracks = List<GpxTrack>.from(_gpxData.tracks);
    updatedTracks.removeAt(index);

    _gpxData = GpxData(tracks: updatedTracks);
    _updateMapView();
  }

  // Client Maps functionality

  /// Handle KML data retrieved from MyMapsKmlDownloader
  void _handleKmlData(Uint8List kmlBytes, String fileName) async {
    try {
      final mapViewProvider =
          Provider.of<MapViewProvider>(context, listen: false);
      // Parse KML data using KmlParserService
      final polygons = await KmlParserService.parseKmlData(kmlBytes, fileName);

      if (polygons.isNotEmpty) {
        // Add polygons to provider
        final currentPolygons =
            List<CustomPolygon>.from(mapViewProvider.customPolygons);
        currentPolygons.addAll(polygons);
        mapViewProvider.updateAllPolygons(currentPolygons);

        // Select the first new polygon
        if (mapViewProvider.selectedPolygonIndex == null &&
            currentPolygons.isNotEmpty) {
          final newPolygonIndex = (currentPolygons.length - polygons.length);
          mapViewProvider.selectPolygon(newPolygonIndex);
        }

        _updateMapView();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content:
                  Text('Loaded ${polygons.length} polygon(s) from $fileName'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No polygons found in the KML file'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error processing KML: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _clientMapsController.dispose();
    try {
      _controller?.dispose();
    } catch (e) {
      print('Error disposing map controller: $e');
    }
    super.dispose();
  }
}
