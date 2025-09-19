import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'dart:math' show min, max;
import '../services/work_area_service.dart';
import '../models/work_area.dart';

class MapView extends StatefulWidget {
  final String? jobId;
  final String? workAreaId;
  final WorkArea? customWorkArea;
  final String? title;
  final bool isEditable;

  const MapView({
    super.key,
    this.jobId,
    this.workAreaId,
    this.customWorkArea,
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
  List<LatLng> _editingPoints = [];
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    try {
      // Load all work areas first
      final workAreaService = context.read<WorkAreaService>();
      _workAreas = await workAreaService.getWorkAreas().first;

      // Find selected work area
      if (widget.workAreaId != null && widget.workAreaId!.isNotEmpty) {
        try {
          _selectedWorkArea = _workAreas.firstWhere(
            (area) => area.id == widget.workAreaId,
          );
        } catch (e) {
          _selectedWorkArea = widget.customWorkArea;
        }
      } else if (widget.customWorkArea != null) {
        _selectedWorkArea = widget.customWorkArea;
      }

      // Initialize editing points if editing is enabled and we have a selected area
      if (widget.isEditable && _selectedWorkArea != null) {
        _editingPoints = List.from(_selectedWorkArea!.polygonPoints);
        _isEditing = true;
      }

      _updateMapView();
    } catch (e) {
      print('Error initializing map: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _updateMapView() {
    _polygons.clear();

    // Add only the selected work area
    if (_selectedWorkArea != null) {
      _polygons.add(
        Polygon(
          polygonId: PolygonId(_selectedWorkArea?.id ?? 'selected'),
          points:
              _isEditing ? _editingPoints : _selectedWorkArea!.polygonPoints,
          fillColor: Colors.red.withOpacity(0.0), // Transparent fill
          strokeColor: Colors.red,
          strokeWidth: 5,
        ),
      );

      // Add markers for editing if in edit mode
      if (_isEditing) {
        // Add markers for each point...
        // This will be handled in the build method
      }
    }

    // Center map on selected area or all areas
    _updateMapCenter();
  }

  void _updateMapCenter() {
    List<LatLng> points = [];

    if (_selectedWorkArea != null) {
      points = _isEditing ? _editingPoints : _selectedWorkArea!.polygonPoints;
    }

    if (points.isNotEmpty) {
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
      _controller?.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng),
          ),
          50, // padding
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
        title: Text(widget.title ?? 'Map View'),
        actions: widget.isEditable && _selectedWorkArea != null
            ? [
                IconButton(
                  icon: Icon(_isEditing ? Icons.check : Icons.edit),
                  onPressed: () {
                    if (_isEditing) {
                      Navigator.of(context).pop(_editingPoints);
                    } else {
                      setState(() {
                        _isEditing = true;
                        _editingPoints = List.from(
                          _selectedWorkArea!.polygonPoints,
                        );
                      });
                    }
                  },
                ),
              ]
            : null,
      ),
      body: Stack(
        children: [
          GoogleMap(
            onMapCreated: (controller) {
              _controller = controller;
            },
            initialCameraPosition: CameraPosition(target: _center, zoom: 12),
            polygons: _polygons,
            markers: _isEditing
                ? _editingPoints
                    .asMap()
                    .map(
                      (index, point) => MapEntry(
                        index,
                        Marker(
                          markerId: MarkerId('point_$index'),
                          position: point,
                          draggable: true,
                          onDragEnd: (newPosition) {
                            setState(() {
                              _editingPoints[index] = newPosition;
                              _updateMapView();
                            });
                          },
                        ),
                      ),
                    )
                    .values
                    .toSet()
                : {},
            mapType: MapType.normal,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            zoomControlsEnabled: true,
            zoomGesturesEnabled: true,
            onTap: _isEditing
                ? (latLng) {
                    setState(() {
                      _editingPoints.add(latLng);
                      _updateMapView();
                    });
                  }
                : null,
          ),
          if (_isLoading)
            Container(
              color: Colors.black45,
              child: const Center(child: CircularProgressIndicator()),
            ),
          if (_isEditing)
            Positioned(
              bottom: 16,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_editingPoints.isNotEmpty)
                    FloatingActionButton(
                      heroTag: 'undo',
                      onPressed: () {
                        setState(() {
                          _editingPoints.removeLast();
                          _updateMapView();
                        });
                      },
                      child: const Icon(Icons.undo),
                    ),
                  const SizedBox(height: 8),
                  if (_editingPoints.length >= 3)
                    FloatingActionButton(
                      heroTag: 'save',
                      onPressed: () {
                        Navigator.of(context).pop(_editingPoints);
                      },
                      child: const Icon(Icons.save),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
