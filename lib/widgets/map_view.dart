import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'dart:math' show min, max;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import '../services/work_area_service.dart';
import '../services/gpx_parser_service.dart';
import '../models/work_area.dart';
import '../models/custom_polygon.dart';
import '../models/gpx_track.dart';

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

  // GPX-related state
  GpxData _gpxData = const GpxData(tracks: []);
  bool _isSidebarVisible = true;
  bool _isImportingGpx = false;

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
          onDrag: (newPosition) {
            setState(() {
              _editingPoints[i] = newPosition;
              _updateMapView();
            });
          },
          onDragEnd: (newPosition) {
            setState(() {
              _editingPoints[i] = newPosition;
              _hasUnsavedChanges = true;
              _updateMapView();
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
                _updateMapView();
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
          onDrag: (newPosition) {
            setState(() {
              _newPolygonPoints[i] = newPosition;
              _updateMapView();
            });
          },
          onDragEnd: (newPosition) {
            setState(() {
              _newPolygonPoints[i] = newPosition;
              _updateMapView();
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

  void _saveChanges() {
    try {
      // Apply editing changes if in editing mode
      if (_isEditing && _selectedPolygonIndex != null) {
        final updatedPolygon = _customPolygons[_selectedPolygonIndex!].copyWith(
          points: _editingPoints,
        );
        _customPolygons[_selectedPolygonIndex!] = updatedPolygon;
        _selectedCustomPolygon = updatedPolygon;

        // Exit editing mode
        setState(() {
          _isEditing = false;
          _editingPoints.clear();
        });
      }

      // Clear unsaved changes flag - changes are now saved locally
      setState(() {
        _hasUnsavedChanges = false;
        _updateMapView();
      });

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Changes saved! Continue editing or close when finished.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
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
    if (_selectedCustomPolygon == null || _selectedPolygonIndex == null) return;

    final TextEditingController nameController = TextEditingController(
      text: _selectedCustomPolygon!.name,
    );

    Color selectedColor = _selectedCustomPolygon!.color;

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

    if (result != null) {
      setState(() {
        // Update the polygon with the new name and color
        final updatedPolygon = _selectedCustomPolygon!.copyWith(
          name: result['name'] as String,
          color: result['color'] as Color,
        );
        _customPolygons[_selectedPolygonIndex!] = updatedPolygon;
        _selectedCustomPolygon = updatedPolygon;
        _hasUnsavedChanges = true;
        _updateMapView();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: CloseButton(onPressed: () async {
          // Check for unsaved changes before closing
          if (_hasUnsavedChanges) {
            final shouldDiscard = await _showDiscardDialog();
            if (!shouldDiscard) return;
          }

          // Return updated CustomPolygons if available
          if (_customPolygons.isNotEmpty) {
            Navigator.of(context).pop(_customPolygons);
          } else {
            Navigator.of(context).pop();
          }
        }),
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
                          _editingPoints =
                              List.from(_selectedCustomPolygon!.points);
                        } else if (_selectedWorkArea != null) {
                          _editingPoints =
                              List.from(_selectedWorkArea!.polygonPoints);
                        }
                        _hasUnsavedChanges = false;
                      });
                    },
                  ),

                // Edit polygon properties button (only for CustomPolygons)
                if (!_isEditing &&
                    !_isCreatingNewPolygon &&
                    _selectedCustomPolygon != null)
                  IconButton(
                    icon: const Icon(Icons.edit_note),
                    tooltip: 'Edit polygon name & color',
                    onPressed: _showEditNameDialog,
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

                // Single "Save Changes" button - only appears when there are unsaved changes
                if (_hasUnsavedChanges)
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
                if (_isCreatingNewPolygon && _newPolygonPoints.length >= 3)
                  IconButton(
                    icon: const Icon(Icons.check),
                    tooltip: 'Finish creating area',
                    onPressed: () {
                      if (_customPolygons.isNotEmpty) {
                        final newCustomPolygon = CustomPolygon(
                          name: 'New Area ${_customPolygons.length + 1}',
                          description: 'User created area',
                          points: List.from(_newPolygonPoints),
                          color: Colors.blue,
                        );

                        setState(() {
                          _customPolygons.add(newCustomPolygon);
                          _isCreatingNewPolygon = false;
                          _newPolygonPoints.clear();
                          _hasUnsavedChanges =
                              true; // Mark as unsaved so user can save later
                          _updateMapView();
                        });
                      } else {
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
                          _hasUnsavedChanges =
                              true; // Mark as unsaved so user can save later
                          _updateMapView();
                        });
                      }

                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Area created! Click "Save Changes" to save to database.'),
                          backgroundColor: Colors.green,
                          duration: Duration(seconds: 3),
                        ),
                      );
                    },
                  ),
              ]
            : null,
      ),
      body: Row(
        children: [
          // Left Sidebar for GPX tracks
          if (_isSidebarVisible)
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
                  cloudMapId: "89c628d2bb3002712797ce42",
                  style: "",
                  initialCameraPosition:
                      CameraPosition(target: _center, zoom: 12),
                  polygons: _polygons,
                  polylines: _gpxData.allPolylines.toSet(), // Add GPX polylines
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

                // Sidebar toggle button
                Positioned(
                  top: 16,
                  left: 16,
                  child: FloatingActionButton(
                    mini: true,
                    onPressed: () {
                      setState(() {
                        _isSidebarVisible = !_isSidebarVisible;
                      });
                    },
                    child: Icon(_isSidebarVisible ? Icons.close : Icons.menu),
                    tooltip:
                        _isSidebarVisible ? 'Hide sidebar' : 'Show sidebar',
                  ),
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
                        if (_isCreatingNewPolygon &&
                            _newPolygonPoints.isNotEmpty)
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
          ),
        ],
      ),
    );
  }

  Widget _buildGpxSidebar() {
    return Column(
      children: [
        // Header
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
              label:
                  Text(_isImportingGpx ? 'Importing...' : 'Import GPX Files'),
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
                Icon(Icons.info_outline, size: 16, color: Colors.grey.shade600),
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
    setState(() {
      _isImportingGpx = true;
    });

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
          setState(() {
            final allTracks = List<GpxTrack>.from(_gpxData.tracks);
            allTracks.addAll(newTracks);
            _gpxData = GpxData(tracks: allTracks);
            _updateMapView();
          });

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
        setState(() {
          _isImportingGpx = false;
        });
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

    setState(() {
      _gpxData = GpxData(tracks: updatedTracks);
      _updateMapView();
    });
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

    setState(() {
      _gpxData = GpxData(tracks: updatedTracks);
      _updateMapView();
    });
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
