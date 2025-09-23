import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'dart:math' show min, max;
import 'dart:ui' as ui;
import '../services/work_area_service.dart';
import '../models/work_area.dart';
import '../models/custom_polygon.dart';

class MapView extends StatefulWidget {
  final String? jobId;
  final String? workAreaId;
  final WorkArea? customWorkArea;
  final List<CustomPolygon>?
      customPolygons; // New field for direct polygon support
  final String? title;
  final bool isEditable;

  const MapView({
    super.key,
    this.jobId,
    this.workAreaId,
    this.customWorkArea,
    this.customPolygons,
    this.title,
    this.isEditable = false,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  GoogleMapController? _controller;
  final Set<Polygon> _polygons = {};
  LatLng _center = const LatLng(-33.925, 18.425); // Cape Town city center
  bool _isLoading = true;
  List<WorkArea> _workAreas = [];
  WorkArea? _selectedWorkArea;
  List<WorkArea> _editableWorkAreas =
      []; // Collection of work areas for this job

  // New fields for CustomPolygon support
  List<CustomPolygon> _customPolygons = [];
  CustomPolygon? _selectedCustomPolygon;
  int? _selectedPolygonIndex;

  List<LatLng> _editingPoints = [];
  bool _isEditing = false;
  bool _hasUnsavedChanges = false;
  bool _isCreatingNewPolygon = false;
  List<LatLng> _newPolygonPoints = [];
  BitmapDescriptor? _circleMarkerIcon;
  BitmapDescriptor? _midpointMarkerIcon;
  int? _draggingMidpointIndex;

  @override
  void initState() {
    super.initState();
    _createMarkerIcons();
    _initializeMap();
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
    final double radius = size / 2;

    // Draw circle background
    final paint = Paint()
      ..color = Colors.orange
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(radius, radius), radius - 1.0, paint);

    // Draw border
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawCircle(Offset(radius, radius), radius - 1.0, borderPaint);

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
    final markers = <Marker>{};

    // Add existing polygon point markers
    for (int i = 0; i < _editingPoints.length; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('point_$i'),
          icon: _circleMarkerIcon!,
          position: _editingPoints[i],
          draggable: true,
          onDragEnd: (newPosition) {
            setState(() {
              _editingPoints[i] = newPosition;
              _hasUnsavedChanges = true;
              // _updateMapView();
              // _updateMapCenter(); // Auto-zoom to include moved point
            });
          },
        ),
      );
    }

    // Add midpoint markers (only if we have at least 3 points for a polygon)
    if (_editingPoints.length >= 3) {
      final midpoints = _calculateMidpoints(_editingPoints);
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
              setState(() {
                _editingPoints.insert(insertIndex, position);
                _draggingMidpointIndex = insertIndex;
                _hasUnsavedChanges = true;
              });
            },
            onDragEnd: (newPosition) {
              // Update the position of the newly inserted point
              setState(() {
                if (_draggingMidpointIndex != null &&
                    _draggingMidpointIndex! < _editingPoints.length) {
                  _editingPoints[_draggingMidpointIndex!] = newPosition;
                }
                _draggingMidpointIndex = null;
                // _updateMapView();
                // _updateMapCenter(); // Auto-zoom to include new midpoint
              });
            },
          ),
        );
      }
    }

    return markers;
  }

  void _onMapTap(LatLng tappedPoint) {
    if (_isCreatingNewPolygon) {
      // Handle new polygon creation
      setState(() {
        _newPolygonPoints.add(tappedPoint);
        _updateMapView();
        _updateMapCenter(); // Auto-zoom to include new point
      });
      return;
    }

    // Note: Polygon selection is now handled by polygon.onTap directly
  }

  Set<Marker> _buildNewPolygonMarkers() {
    Set<Marker> markers = {};

    // Add markers for new polygon points
    for (int i = 0; i < _newPolygonPoints.length; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('new_polygon_point_$i'),
          position: _newPolygonPoints[i],
          icon: _circleMarkerIcon ?? BitmapDescriptor.defaultMarker,
          draggable: true,
          onDragEnd: (newPosition) {
            setState(() {
              _newPolygonPoints[i] = newPosition;
              // _updateMapView();
              // _updateMapCenter(); // Auto-zoom to include moved point
            });
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
      // Check if we're using the new CustomPolygon system
      if (widget.customPolygons != null && widget.customPolygons!.isNotEmpty) {
        // New system: Initialize with CustomPolygons
        _customPolygons = List.from(widget.customPolygons!);
        if (_customPolygons.isNotEmpty) {
          _selectedCustomPolygon = _customPolygons.first;
          _selectedPolygonIndex = 0;

          // Initialize editing points if editing is enabled
          if (widget.isEditable) {
            _editingPoints = List.from(_selectedCustomPolygon!.points);
            _isEditing = true;
          }
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
          _editingPoints = List.from(_selectedWorkArea!.polygonPoints);
          _isEditing = true;
        }
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

    // Check if we're using the new CustomPolygon system
    if (_customPolygons.isNotEmpty) {
      // New system: Add CustomPolygons
      for (int i = 0; i < _customPolygons.length; i++) {
        final customPolygon = _customPolygons[i];
        final isCurrentlyEditing = _isEditing && i == _selectedPolygonIndex;
        final isSelected = i == _selectedPolygonIndex;

        _polygons.add(
          Polygon(
            polygonId: PolygonId('custom_polygon_$i'),
            points: isCurrentlyEditing ? _editingPoints : customPolygon.points,
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
            onTap: !_isEditing && !_isCreatingNewPolygon
                ? () {
                    setState(() {
                      _selectedPolygonIndex = i;
                      _selectedCustomPolygon = customPolygon;
                      _updateMapView();
                    });
                  }
                : null,
          ),
        );
      }
    } else {
      // Legacy system: Add WorkAreas
      for (int i = 0; i < _editableWorkAreas.length; i++) {
        final area = _editableWorkAreas[i];
        final isCurrentlyEditing = _isEditing && area == _selectedWorkArea;
        final isSelected = area == _selectedWorkArea;

        _polygons.add(
          Polygon(
            polygonId: PolygonId(area.id.isNotEmpty ? area.id : 'area_$i'),
            points: isCurrentlyEditing ? _editingPoints : area.polygonPoints,
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
            onTap: !_isEditing && !_isCreatingNewPolygon
                ? () {
                    setState(() {
                      _selectedWorkArea = area;
                      _updateMapView();
                    });
                  }
                : null,
          ),
        );
      }
    }

    // Add new polygon being created
    if (_isCreatingNewPolygon && _newPolygonPoints.length > 2) {
      _polygons.add(
        Polygon(
          polygonId: const PolygonId('new_polygon'),
          points: _newPolygonPoints,
          fillColor: Colors.blue.withOpacity(0.2),
          strokeColor: Colors.blue,
          strokeWidth: 3,
        ),
      );
    }

    // Center map on selected area or all areas
    _updateMapCenter();
  }

  void _updateMapCenter() {
    List<LatLng> points = [];

    // Check if we're using the new CustomPolygon system
    if (_customPolygons.isNotEmpty) {
      // New system: Include custom polygons in center calculation
      for (int i = 0; i < _customPolygons.length; i++) {
        final customPolygon = _customPolygons[i];
        if (i == _selectedPolygonIndex && _isEditing) {
          points.addAll(_editingPoints);
        } else {
          points.addAll(customPolygon.points);
        }
      }
    } else {
      // Legacy system: Include all editable work areas in the center calculation
      for (final area in _editableWorkAreas) {
        if (area == _selectedWorkArea && _isEditing) {
          points.addAll(_editingPoints);
        } else {
          points.addAll(area.polygonPoints);
        }
      }
    }

    // Also include new polygon points if creating
    if (_isCreatingNewPolygon) {
      points.addAll(_newPolygonPoints);
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
                100, // Increased padding for better visualization
              ),
            );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
        title: Text(
          '${widget.title ?? 'Map View'}${_hasUnsavedChanges ? ' •' : ''}',
        ),
        actions: widget.isEditable
            ? [
                // Create new area button (always available when editable)
                if (!_isEditing && !_isCreatingNewPolygon)
                  IconButton(
                    icon: const Icon(Icons.add_location),
                    tooltip: 'Create new area',
                    onPressed: () {
                      setState(() {
                        _isCreatingNewPolygon = true;
                        _newPolygonPoints.clear();
                        // Don't deselect current area - keep existing polygons visible
                        _updateMapView();
                      });
                    },
                  ),

                // Edit existing area button (only when area is selected)
                if (!_isEditing &&
                    !_isCreatingNewPolygon &&
                    (_selectedWorkArea != null ||
                        _selectedCustomPolygon != null))
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Edit area boundary',
                    onPressed: () {
                      setState(() {
                        _isEditing = true;
                        if (_selectedCustomPolygon != null) {
                          // New system: edit custom polygon
                          _editingPoints =
                              List.from(_selectedCustomPolygon!.points);
                        } else if (_selectedWorkArea != null) {
                          // Legacy system: edit work area
                          _editingPoints =
                              List.from(_selectedWorkArea!.polygonPoints);
                        }
                        _hasUnsavedChanges = false;
                      });
                    },
                  ),

                // Cancel buttons for editing/creating
                if (_isEditing || _isCreatingNewPolygon)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: _isCreatingNewPolygon
                        ? 'Cancel creation'
                        : 'Cancel changes',
                    onPressed: () async {
                      if (_isEditing && _hasUnsavedChanges) {
                        final shouldDiscard = await _showDiscardDialog();
                        if (!shouldDiscard) return;
                      }
                      setState(() {
                        _isEditing = false;
                        _isCreatingNewPolygon = false;
                        _hasUnsavedChanges = false;
                        _editingPoints.clear();
                        _newPolygonPoints.clear();
                        _updateMapView();
                      });
                    },
                  ),

                // Save buttons for editing/creating
                if (_isEditing && _hasUnsavedChanges)
                  IconButton(
                    icon: const Icon(Icons.check),
                    tooltip: 'Save changes',
                    onPressed: () {
                      Navigator.of(context).pop(_editingPoints);
                    },
                  ),
                if (_isCreatingNewPolygon && _newPolygonPoints.length >= 3)
                  IconButton(
                    icon: const Icon(Icons.check),
                    tooltip: 'Save new area',
                    onPressed: () {
                      // Add the new polygon to the editable collection
                      final now = DateTime.now();
                      final newWorkArea = WorkArea(
                        id: 'new_${now.millisecondsSinceEpoch}',
                        name: 'New Area ${_editableWorkAreas.length + 1}',
                        description: 'User created area',
                        polygonPoints: List.from(_newPolygonPoints),
                        kmlFileName: '',
                        createdAt: now,
                        updatedAt: now,
                      );

                      setState(() {
                        _editableWorkAreas.add(newWorkArea);
                        _isCreatingNewPolygon = false;
                        _newPolygonPoints.clear();
                        _updateMapView();
                      });

                      // Show success message
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                              'New area added! You can create more areas or tap "Done" when finished.'),
                          backgroundColor: Colors.green,
                          duration: Duration(seconds: 3),
                        ),
                      );
                    },
                  ),

                // Done button (when there are multiple areas to save)
                if (!_isEditing &&
                    !_isCreatingNewPolygon &&
                    _editableWorkAreas.length > 1)
                  IconButton(
                    icon: const Icon(Icons.done),
                    tooltip: 'Finish editing',
                    onPressed: () {
                      // Return all polygon points combined (for now, return the primary area's points)
                      // This might need adjustment based on how the parent handles multiple polygons
                      final allPoints = _editableWorkAreas.isNotEmpty
                          ? _editableWorkAreas.first.polygonPoints
                          : <LatLng>[];
                      Navigator.of(context).pop(allPoints);
                    },
                  ),
              ]
            : null,
      ),
      body: Stack(
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
            onTap:
                _onMapTap, // Always enable tap for both polygon creation and selection
            cloudMapId: "89c628d2bb3002712797ce42",
            style: "",
            initialCameraPosition: CameraPosition(target: _center, zoom: 12),
            polygons: _polygons,
            markers: _isEditing &&
                    _circleMarkerIcon != null &&
                    _midpointMarkerIcon != null
                ? _buildEditingMarkers()
                : _isCreatingNewPolygon
                    ? _buildNewPolygonMarkers()
                    : {},
            mapType: MapType.normal,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            zoomControlsEnabled: true,
            zoomGesturesEnabled: true,
          ),
          if (_isLoading)
            Container(
              color: Colors.black45,
              child: const Center(child: CircularProgressIndicator()),
            ),
          if (_isEditing || _isCreatingNewPolygon)
            Positioned(
              bottom: 16,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Undo button for editing existing polygon
                  if (_isEditing && _editingPoints.isNotEmpty)
                    FloatingActionButton(
                      heroTag: 'undo_edit',
                      onPressed: () {
                        setState(() {
                          _editingPoints.removeLast();
                          _hasUnsavedChanges = true;
                          _updateMapView();
                        });
                      },
                      child: const Icon(Icons.undo),
                    ),
                  // Undo button for creating new polygon
                  if (_isCreatingNewPolygon && _newPolygonPoints.isNotEmpty)
                    FloatingActionButton(
                      heroTag: 'undo_create',
                      onPressed: () {
                        setState(() {
                          _newPolygonPoints.removeLast();
                          _updateMapView();
                        });
                      },
                      child: const Icon(Icons.undo),
                    ),
                ],
              ),
            ),
          // Instructions overlay for new polygon creation
          if (_isCreatingNewPolygon)
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
                child: Text(
                  'Tap on the map to add points for your new area. You need at least 3 points to create an area.',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

          // Instructions overlay for polygon selection
          if (!_isCreatingNewPolygon &&
              !_isEditing &&
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
                child: Text(
                  'Tap on any polygon to select it, then tap the Edit button to modify it.',
                  style: const TextStyle(
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
