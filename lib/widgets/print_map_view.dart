import 'dart:convert';
import 'dart:math' show atan, cos, exp, log, max, min, pi, pow, sin;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../providers/schedule_provider.dart';
import '../shareable_maps/services/map_thumbnail_service.dart';
import '../shareable_maps/utils/point_marker_icons.dart';
import '../utils/browser_screenshot.dart';
import '../utils/map_pdf.dart';

// Class to store polygon override settings
class PolygonOverride {
  final Color strokeColor;
  final int strokeWidth;

  const PolygonOverride({
    required this.strokeColor,
    required this.strokeWidth,
  });
}

/// Editable client-name label attached to a polygon, used in the printed map.
///
/// [anchor] is the geographic position the label is pinned to so it stays
/// fixed as the user pans/zooms the map. [text] is plain editable text and
/// the rendered label is drawn with a transparent background so the map
/// underneath remains visible in the printout.
class _PolygonLabel {
  String text;
  LatLng anchor;

  _PolygonLabel({required this.text, required this.anchor});
}

enum _PrintSelectionHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class _MapPrintBounds {
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;

  const _MapPrintBounds({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });

  factory _MapPrintBounds.fromPoints(List<LatLng> points) {
    var minLat = 90.0;
    var maxLat = -90.0;
    var minLng = 180.0;
    var maxLng = -180.0;

    for (final point in points) {
      minLat = min(minLat, point.latitude);
      maxLat = max(maxLat, point.latitude);
      minLng = min(minLng, point.longitude);
      maxLng = max(maxLng, point.longitude);
    }

    return _MapPrintBounds(
      minLat: minLat,
      maxLat: maxLat,
      minLng: minLng,
      maxLng: maxLng,
    );
  }

  LatLng get center => LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);

  bool get isPointLike {
    return (maxLat - minLat).abs() < 0.00001 &&
        (maxLng - minLng).abs() < 0.00001;
  }

  bool get prefersLandscape => geoAspectRatio >= 1;

  LatLng get staticMapCenter {
    final centerY = (_latToMercatorY(minLat) + _latToMercatorY(maxLat)) / 2;
    return LatLng(_mercatorYToLat(centerY), (minLng + maxLng) / 2);
  }

  double get geoAspectRatio {
    final latSpan = max((maxLat - minLat).abs(), 0.000001);
    final lngSpan = max((maxLng - minLng).abs(), 0.000001);
    final meanLatRadians = center.latitude * pi / 180;
    final adjustedLngSpan = lngSpan * max(cos(meanLatRadians).abs(), 0.1);
    return adjustedLngSpan / latSpan;
  }

  LatLngBounds get cameraBounds {
    final latSpan = (maxLat - minLat).abs();
    final lngSpan = (maxLng - minLng).abs();
    final latPadding = max(latSpan * 0.06, 0.0005);
    final lngPadding = max(lngSpan * 0.06, 0.0005);

    return LatLngBounds(
      southwest: LatLng(minLat - latPadding, minLng - lngPadding),
      northeast: LatLng(maxLat + latPadding, maxLng + lngPadding),
    );
  }

  double staticMapZoom(Size mapSize, double paddingPixels) {
    if (isPointLike) return 17;

    final usableWidth = max(mapSize.width - (paddingPixels * 2), 1.0);
    final usableHeight = max(mapSize.height - (paddingPixels * 2), 1.0);
    final lngSpan = max((maxLng - minLng).abs(), 0.000001);
    final xSpanAtZoomZero = (lngSpan / 360) * 256;
    final ySpanAtZoomZero =
        (_latToMercatorY(minLat) - _latToMercatorY(maxLat)).abs() * 256;

    final zoomForWidth = log(usableWidth / xSpanAtZoomZero) / log(2);
    final zoomForHeight =
        log(usableHeight / max(ySpanAtZoomZero, 0.000001)) / log(2);
    final zoom = min(zoomForWidth, zoomForHeight);
    return zoom.floor().clamp(1, 20).toDouble();
  }

  static double _latToMercatorY(double latitude) {
    final clampedLatitude = latitude.clamp(-85.05112878, 85.05112878);
    final sinLat = sin(clampedLatitude * pi / 180);
    return 0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * pi);
  }

  static double _mercatorYToLat(double y) {
    final n = pi - (2 * pi * y);
    return (180 / pi) * atan((exp(n) - exp(-n)) / 2);
  }
}

class PrintMapView extends ConsumerStatefulWidget {
  final Job job;
  final String? distributorName;

  const PrintMapView({
    super.key,
    required this.job,
    this.distributorName,
  });

  @override
  ConsumerState<PrintMapView> createState() => _PrintMapViewState();
}

class _PrintMapViewState extends ConsumerState<PrintMapView> {
  static const double _printSelectionInset = 24.0;
  static const double _printSelectionHandleSize = 18.0;
  static const double _printSelectionMinWidth = 180.0;
  static const double _printSelectionMinHeight = 140.0;

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
  late Job _job;
  String _jobSignature = '';
  String? _pendingJobSignature;
  bool _isPrintingMap = false;
  String _printProgressMessage = '';
  bool _isCapturingPrintMap = false;
  final bool _capturePrintMapLandscape = false;
  bool _printSelectionVisible = false;
  bool _isShiftPressed = false;
  bool _isDraggingPrintSelection = false;
  bool _isBrowserScreenshotCaptureActive = false;
  Offset _printSelectionPosition = Offset.zero;
  Size _printSelectionSize = Size.zero;
  Size _lastMapSize = Size.zero;
  _PrintSelectionHandle? _activePrintSelectionHandle;

  // Editable polygon labels (client names) overlaid on each polygon.
  // Keyed by the polygon's index in `_job.workMaps`. Created lazily so that
  // existing anchor/text edits are preserved across rebuilds.
  final Map<int, _PolygonLabel> _polygonLabels = {};
  bool _showPolygonLabels = true;
  int? _editingLabelIndex;
  int? _draggingLabelIndex;
  TextEditingController? _labelEditController;
  FocusNode? _labelEditFocus;
  // Tracks the current camera so labels can be projected to screen
  // synchronously (matches the track-editor pattern – avoids async lag on
  // every camera frame).
  CameraPosition _currentCamera = const CameraPosition(
    target: LatLng(-33.925, 18.425),
    zoom: 12,
  );

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handlePrintSelectionKey);
    _job = widget.job;
    _jobSignature = _signatureFor(_job);
    _initializeMap();
    _createMarkerIcons();
  }

  @override
  void didUpdateWidget(covariant PrintMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.job.id != widget.job.id || oldWidget.job != widget.job) {
      _replaceJob(widget.job);
    }
  }

  void _replaceJob(Job job) {
    _job = job;
    _jobSignature = _signatureFor(job);
    _dropOffPoint =
        job.dropOffPoint ?? Job.estimateDropOffPointFromWorkMaps(job.workMaps);
    _updateMapView();
  }

  void _syncLiveJob(Job liveJob) {
    if (_isEditingVertices) return;
    final signature = _signatureFor(liveJob);
    if (signature == _jobSignature || signature == _pendingJobSignature) {
      return;
    }
    _pendingJobSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isEditingVertices) return;
      setState(() {
        _pendingJobSignature = null;
        _replaceJob(liveJob);
      });
    });
  }

  String _signatureFor(Job job) {
    final drop = job.dropOffPoint == null
        ? ''
        : '${job.dropOffPoint!.latitude.toStringAsFixed(7)},${job.dropOffPoint!.longitude.toStringAsFixed(7)}';
    final maps = job.workMaps.map((wm) {
      final points = wm.points
          .map((p) =>
              '${p.latitude.toStringAsFixed(7)},${p.longitude.toStringAsFixed(7)}')
          .join('|');
      return [
        wm.name,
        wm.description,
        wm.type.name,
        wm.pointCategory.id,
        wm.color.toARGB32().toString(),
        wm.fillOpacity.toString(),
        wm.strokeWidth.toString(),
        wm.isDashed.toString(),
        wm.letterBoxEstimate.toString(),
        points,
      ].join('~');
    }).join('#');
    return [
      job.id,
      job.distributorId,
      job.date.toIso8601String(),
      job.clients.join(','),
      job.workingAreas.join(','),
      job.statusId,
      drop,
      maps,
    ].join('|');
  }

  bool _handlePrintSelectionKey(KeyEvent event) {
    final shiftNow = HardwareKeyboard.instance.isShiftPressed;
    if (shiftNow != _isShiftPressed && mounted) {
      setState(() => _isShiftPressed = shiftNow);
    }

    if (shiftNow && event is KeyDownEvent) {
      _showPrintSelection();
    }

    return false;
  }

  void _togglePrintSelection() {
    setState(() {
      if (!_printSelectionVisible) {
        _ensurePrintSelectionForMap(_lastMapSize);
      }
      _printSelectionVisible = !_printSelectionVisible;
      _isDraggingPrintSelection = false;
      _activePrintSelectionHandle = null;
    });
  }

  void _showPrintSelection() {
    if (_lastMapSize.width <= 0 || _lastMapSize.height <= 0) return;
    if (_printSelectionVisible) return;

    setState(() {
      _ensurePrintSelectionForMap(_lastMapSize);
      _printSelectionVisible = true;
    });
  }

  void _ensurePrintSelectionForMap(Size mapSize) {
    if (mapSize.width <= 0 || mapSize.height <= 0) return;

    final inset = min(
      _printSelectionInset,
      min(mapSize.width, mapSize.height) * 0.12,
    );
    final minimumWidth = min(_printSelectionMinWidth, mapSize.width);
    final minimumHeight = min(_printSelectionMinHeight, mapSize.height);
    final selectionIsMissing = _printSelectionSize.width <= 0 ||
        _printSelectionSize.height <= 0 ||
        _printSelectionPosition.dx >= mapSize.width ||
        _printSelectionPosition.dy >= mapSize.height;

    if (selectionIsMissing) {
      final width = max(mapSize.width - (inset * 2), minimumWidth);
      final height = max(mapSize.height - (inset * 2), minimumHeight);
      _printSelectionSize = Size(
        min(width, mapSize.width),
        min(height, mapSize.height),
      );
      _printSelectionPosition = Offset(
        ((mapSize.width - _printSelectionSize.width) / 2)
            .clamp(0.0, mapSize.width)
            .toDouble(),
        ((mapSize.height - _printSelectionSize.height) / 2)
            .clamp(0.0, mapSize.height)
            .toDouble(),
      );
      return;
    }

    final width = _printSelectionSize.width
        .clamp(
          min(minimumWidth, mapSize.width),
          mapSize.width,
        )
        .toDouble();
    final height = _printSelectionSize.height
        .clamp(
          min(minimumHeight, mapSize.height),
          mapSize.height,
        )
        .toDouble();
    _printSelectionSize = Size(width, height);
    _printSelectionPosition = Offset(
      _printSelectionPosition.dx.clamp(0.0, mapSize.width - width).toDouble(),
      _printSelectionPosition.dy.clamp(0.0, mapSize.height - height).toDouble(),
    );
  }

  Rect? _selectedPrintViewportRect() {
    final mapContext = _mapKey.currentContext;
    final renderObject = mapContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;

    _ensurePrintSelectionForMap(renderObject.size);
    final topLeft = renderObject.localToGlobal(_printSelectionPosition);
    return topLeft & _printSelectionSize;
  }

  Future<void> _initializeMap() async {
    try {
      _dropOffPoint = _job.dropOffPoint ??
          Job.estimateDropOffPointFromWorkMaps(_job.workMaps);
      // Initialize map view with all work maps
      _updateMapView();
    } catch (e) {
      debugPrint('Error initializing map: $e');
      // Set a default center if initialization fails
      _center = const LatLng(-33.925, 18.425); // Cape Town city center
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Color _strokeColorForWorkMap(int index, CustomPolygon workMap) {
    final override = _polygonOverrides['workmap_$index'];
    if (override != null) return override.strokeColor;
    return _useBlackBorders ? Colors.black : workMap.color;
  }

  int _strokeWidthForWorkMap(int index) {
    return _polygonOverrides['workmap_$index']?.strokeWidth ??
        _globalBorderWidth;
  }

  List<LatLng> _pointsForWorkMap(int index, CustomPolygon workMap) {
    return (_editingPolygonIndex == index && _editingPoints != null)
        ? _editingPoints!
        : workMap.points;
  }

  void _updateMapView() {
    _polygons.clear();
    _polylines.clear();
    _customPointMarkers.clear();

    // Refresh editable polygon labels for the current polygon set.
    _ensurePolygonLabels();

    // Show all work maps with their respective colors
    if (_job.workMaps.isNotEmpty) {
      for (int i = 0; i < _job.workMaps.length; i++) {
        final workMap = _job.workMaps[i];

        // Handle point/marker-type elements
        if (workMap.isPoint && workMap.points.isNotEmpty) {
          if (workMap.pointCategory == PointCategory.dropoff) {
            _dropOffPoint = workMap.points.first;
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
        final strokeColor = _strokeColorForWorkMap(i, workMap);
        final strokeWidth = _strokeWidthForWorkMap(i);
        final points = _pointsForWorkMap(i, workMap);

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
        icon: _pointIcons?[PointCategory.dropoff] ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
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
    if (_job.workMaps.isNotEmpty) {
      // Calculate bounds for all polygons
      double minLat = 90;
      double maxLat = -90;
      double minLng = 180;
      double maxLng = -180;

      // Iterate through all work maps to find overall bounds
      for (final workMap in _job.workMaps) {
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
          debugPrint('Error animating camera: $e');
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
          debugPrint('Error setting default camera position: $e');
        }
      }
    }
  }

  // ── Polygon label helpers ─────────────────────────────────────────

  /// Default label text for a polygon. Prefers the first non-empty client
  /// name, falling back to the work-map's own name.
  String _defaultLabelText(CustomPolygon workMap) {
    for (final c in _job.clients) {
      if (c.trim().isNotEmpty) return c.trim();
    }
    return workMap.name;
  }

  /// Geometric centroid (average of vertices) – good enough for label
  /// placement on the convex shapes used here.
  LatLng _polygonCentroid(List<LatLng> pts) {
    if (pts.isEmpty) return _center;
    double lat = 0, lng = 0;
    for (final p in pts) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / pts.length, lng / pts.length);
  }

  /// Make sure `_polygonLabels` has an entry for every polygon currently
  /// shown. Existing entries (with user edits) are preserved; stale entries
  /// for removed/non-polygon indices are dropped.
  void _ensurePolygonLabels() {
    final validIndices = <int>{};
    for (var i = 0; i < _job.workMaps.length; i++) {
      final wm = _job.workMaps[i];
      if (!wm.isPolygon || wm.points.length < 3) continue;
      validIndices.add(i);
      _polygonLabels.putIfAbsent(
        i,
        () => _PolygonLabel(
          text: _defaultLabelText(wm),
          anchor: _polygonCentroid(wm.points),
        ),
      );
    }
    _polygonLabels.removeWhere((k, _) => !validIndices.contains(k));
  }

  /// Project a LatLng to a screen pixel offset using the current camera.
  /// Matches the synchronous Web-Mercator math used in the track-editor
  /// page so labels stay glued to their anchor without async lag.
  Offset _labelLatLngToScreen(LatLng point, Size screen) {
    double worldX(double lng) => (lng + 180) / 360 * 256;
    double worldY(double lat) {
      final s = sin(lat * pi / 180).clamp(-0.9999, 0.9999);
      return (0.5 - log((1 + s) / (1 - s)) / (4 * pi)) * 256;
    }

    final scale = pow(2, _currentCamera.zoom).toDouble();
    final cx = worldX(_currentCamera.target.longitude) * scale;
    final cy = worldY(_currentCamera.target.latitude) * scale;
    final px = worldX(point.longitude) * scale;
    final py = worldY(point.latitude) * scale;
    return Offset(
      screen.width / 2 + (px - cx),
      screen.height / 2 + (py - cy),
    );
  }

  /// Inverse of [_labelLatLngToScreen] – converts a screen offset back to
  /// the geographic anchor (used while dragging a label around).
  LatLng _labelScreenToLatLng(Offset offset, Size screen) {
    final scale = pow(2, _currentCamera.zoom).toDouble();
    double worldX(double lng) => (lng + 180) / 360 * 256;
    double worldY(double lat) {
      final s = sin(lat * pi / 180).clamp(-0.9999, 0.9999);
      return (0.5 - log((1 + s) / (1 - s)) / (4 * pi)) * 256;
    }

    final cx = worldX(_currentCamera.target.longitude) * scale;
    final cy = worldY(_currentCamera.target.latitude) * scale;
    final px = cx + (offset.dx - screen.width / 2);
    final py = cy + (offset.dy - screen.height / 2);

    final lng = (px / scale) / 256 * 360 - 180;
    final n = pi - 2 * pi * (py / scale) / 256;
    final lat = (180 / pi) * atan((exp(n) - exp(-n)) / 2);
    return LatLng(lat, lng);
  }

  void _commitLabelTextEdit() {
    final idx = _editingLabelIndex;
    final ctrl = _labelEditController;
    if (idx != null && ctrl != null && _polygonLabels.containsKey(idx)) {
      _polygonLabels[idx]!.text = ctrl.text;
    }
    _labelEditController?.dispose();
    _labelEditFocus?.dispose();
    _labelEditController = null;
    _labelEditFocus = null;
    _editingLabelIndex = null;
  }

  void _beginLabelTextEdit(int index) {
    final label = _polygonLabels[index];
    if (label == null) return;
    // If another label was being edited, commit it first.
    if (_editingLabelIndex != null && _editingLabelIndex != index) {
      _commitLabelTextEdit();
    }
    _labelEditController = TextEditingController(text: label.text);
    _labelEditFocus = FocusNode();
    _editingLabelIndex = index;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _labelEditFocus?.requestFocus();
      _labelEditController?.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _labelEditController!.text.length,
      );
    });
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
    if (mounted) {
      setState(() {
        _updateMapView();
      });
    }
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
    final workMap = _job.workMaps[polygonIndex];
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
    final old = _job.workMaps[idx];
    final updatedMaps = List<CustomPolygon>.from(_job.workMaps);
    updatedMaps[idx] = old.copyWith(points: List<LatLng>.from(_editingPoints!));
    _job = _job.copyWith(workMaps: updatedMaps);

    // Keep drop-off point aligned to updated work areas.
    if (_dropOffPoint == null ||
        !Job.isPointInsideAnyWorkArea(_dropOffPoint!, _job.workMaps)) {
      _dropOffPoint = Job.estimateDropOffPointFromWorkMaps(_job.workMaps);
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
    if (_isPrintingMap) return;

    final printBounds = _calculatePrintBounds();
    final messenger = ScaffoldMessenger.of(context);
    String? errorMessage;

    try {
      _ensurePrintSelectionForMap(_lastMapSize);
      final selectedViewportRect = _selectedPrintViewportRect();
      if (selectedViewportRect == null) {
        throw Exception('Print area is not ready yet.');
      }
      final isLandscape =
          selectedViewportRect.width >= selectedViewportRect.height;

      setState(() {
        _isPrintingMap = true;
        _printProgressMessage = kIsWeb
            ? 'Choose this browser tab in the capture prompt...'
            : 'Preparing detailed map bounds...';
      });

      if (kIsWeb && !isBrowserScreenshotSupported) {
        throw Exception('browser screen capture is not supported.');
      }

      final imageBytes = kIsWeb
          ? await _captureSelectedBrowserMap(selectedViewportRect)
          : await _loadStaticPrintMapImage(
              bounds: printBounds,
              isLandscape: isLandscape,
            );

      if (!mounted) return;

      setState(() {
        _isBrowserScreenshotCaptureActive = false;
        _printProgressMessage = 'Building print PDF...';
      });

      final pdfBytes = await compute(
        generateDistributionMapPdfFromData,
        distributionMapPdfPayload(
          mapImageBytes: imageBytes,
          job: _job,
          distributorName: widget.distributorName,
          isLandscape: isLandscape,
        ),
        debugLabel: 'distribution-map-pdf',
      );

      if (!mounted) return;

      _setPrintProgress('Opening print preview...');
      setState(() {
        _isPrintingMap = false;
        _printProgressMessage = '';
      });

      await Printing.layoutPdf(
        name: _printMapDocumentName(),
        onLayout: (_) async => pdfBytes,
      );
    } catch (e) {
      errorMessage = 'Error preparing map: ${_friendlyPrintError(e)}';
    } finally {
      if (mounted) {
        setState(() {
          _isPrintingMap = false;
          _printProgressMessage = '';
          _isCapturingPrintMap = false;
          _isBrowserScreenshotCaptureActive = false;
        });
      }
    }

    if (errorMessage != null && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<Uint8List> _captureSelectedBrowserMap(Rect selectedViewportRect) {
    setState(() => _isBrowserScreenshotCaptureActive = true);
    return captureBrowserViewportArea(selectedViewportRect);
  }

  String _friendlyPrintError(Object error) {
    final message = error.toString();
    if (message.contains('NotAllowedError') ||
        message.contains('Permission denied')) {
      return 'browser capture was cancelled or blocked. Choose the current browser tab when prompted.';
    }
    if (message.contains('NotFoundError')) {
      return 'no browser capture source was selected.';
    }
    return message.replaceFirst('Exception: ', '');
  }

  void _setPrintProgress(String message) {
    if (!mounted) return;
    setState(() => _printProgressMessage = message);
  }

  Future<Uint8List> _loadStaticPrintMapImage({
    required _MapPrintBounds? bounds,
    required bool isLandscape,
  }) async {
    _setPrintProgress('Requesting detailed Static Maps image...');

    final mapSize = _staticPrintMapSize(isLandscape);
    final center = bounds?.staticMapCenter ?? _center;
    const printPaddingPixels = 12.0;
    final zoom = bounds?.staticMapZoom(mapSize, printPaddingPixels) ?? 12;
    final url = MapThumbnailService.buildThumbnailUrl(
      center: center,
      zoom: zoom,
      polygons: _staticMapPolygons(),
      polylines: _staticMapPolylines(),
      markers: _staticMapMarkers(),
      width: mapSize.width.round(),
      height: mapSize.height.round(),
      detailedRoads: true,
      maxPolygonPoints: 80,
      maxPolylinePoints: 100,
    );

    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception(_staticMapError(response));
    }

    final imageBytes = response.bodyBytes;
    if (imageBytes.isEmpty) {
      throw Exception('Static map returned an empty image.');
    }

    return imageBytes;
  }

  String _staticMapError(http.Response response) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (body.isEmpty) {
      return 'Static map request failed (${response.statusCode}).';
    }
    final compactBody = body.replaceAll(RegExp(r'\s+'), ' ');
    final details = compactBody.length > 220
        ? '${compactBody.substring(0, 220)}...'
        : compactBody;
    return 'Static map request failed (${response.statusCode}): $details';
  }

  Size _staticPrintMapSize(bool isLandscape) {
    return isLandscape ? const Size(640, 360) : const Size(512, 640);
  }

  List<ThumbnailPathData>? _staticMapPolygons() {
    final paths = <ThumbnailPathData>[];

    for (int i = 0; i < _job.workMaps.length; i++) {
      final workMap = _job.workMaps[i];
      final points = _pointsForWorkMap(i, workMap);
      if (!workMap.isPolygon || points.length < 3) continue;

      paths.add(
        ThumbnailPathData(
          points: points,
          color: _strokeColorForWorkMap(i, workMap),
          fillOpacity: 0,
          strokeWidth: _strokeWidthForWorkMap(i),
        ),
      );
    }

    return paths.isEmpty ? null : paths;
  }

  List<ThumbnailPathData>? _staticMapPolylines() {
    final paths = <ThumbnailPathData>[];

    for (final workMap in _job.workMaps) {
      if (!workMap.isPolyline || workMap.points.length < 2) continue;
      paths.add(
        ThumbnailPathData(
          points: workMap.points,
          color: workMap.color,
          fillOpacity: 0,
          strokeWidth: workMap.strokeWidth,
        ),
      );
    }

    return paths.isEmpty ? null : paths;
  }

  List<ThumbnailMarkerData>? _staticMapMarkers() {
    final markers = <ThumbnailMarkerData>[];

    for (final workMap in _job.workMaps) {
      if (!workMap.isPoint || workMap.points.isEmpty) continue;
      if (workMap.pointCategory == PointCategory.dropoff) continue;

      markers.add(
        ThumbnailMarkerData(
          position: workMap.points.first,
          color: workMap.pointCategory == PointCategory.generic
              ? workMap.color
              : workMap.pointCategory.color,
          label: _staticMarkerLabel(workMap.pointCategory),
        ),
      );
    }

    if (_dropOffPoint != null) {
      markers.add(
        ThumbnailMarkerData(
          position: _dropOffPoint!,
          color: PointCategory.dropoff.color,
          label: _staticMarkerLabel(PointCategory.dropoff),
        ),
      );
    }

    return markers.isEmpty ? null : markers;
  }

  String? _staticMarkerLabel(PointCategory category) {
    return switch (category) {
      PointCategory.dropoff => 'D',
      PointCategory.pickup => 'P',
      PointCategory.loading => 'L',
      PointCategory.offloading => 'O',
      PointCategory.cleaning => 'C',
      PointCategory.generic => null,
    };
  }

  _MapPrintBounds? _calculatePrintBounds() {
    final points = <LatLng>[];

    for (int i = 0; i < _job.workMaps.length; i++) {
      final workMap = _job.workMaps[i];
      if (_editingPolygonIndex == i && _editingPoints != null) {
        points.addAll(_editingPoints!);
      } else {
        points.addAll(workMap.points);
      }
    }

    if (_dropOffPoint != null) {
      points.add(_dropOffPoint!);
    }

    if (points.isEmpty) return null;
    return _MapPrintBounds.fromPoints(points);
  }

  Size _printCaptureSize(double availableWidth, double availableHeight) {
    if (!_isCapturingPrintMap) {
      return Size(availableWidth, availableHeight);
    }

    const a4AspectRatio = 1.41421356237;
    final targetAspectRatio =
        _capturePrintMapLandscape ? a4AspectRatio : 1 / a4AspectRatio;
    var width = availableWidth;
    var height = width / targetAspectRatio;

    if (height > availableHeight) {
      height = availableHeight;
      width = height * targetAspectRatio;
    }

    return Size(width, height);
  }

  void _movePrintSelection(DragUpdateDetails details, Size mapSize) {
    setState(() {
      final nextPosition = _printSelectionPosition + details.delta;
      _printSelectionPosition = Offset(
        nextPosition.dx
            .clamp(0.0, mapSize.width - _printSelectionSize.width)
            .toDouble(),
        nextPosition.dy
            .clamp(0.0, mapSize.height - _printSelectionSize.height)
            .toDouble(),
      );
    });
  }

  void _resizePrintSelection(
    _PrintSelectionHandle handle,
    DragUpdateDetails details,
    Size mapSize,
  ) {
    setState(() {
      final minimumWidth = min(_printSelectionMinWidth, mapSize.width);
      final minimumHeight = min(_printSelectionMinHeight, mapSize.height);
      var leftEdge = _printSelectionPosition.dx;
      var topEdge = _printSelectionPosition.dy;
      var rightEdge = _printSelectionPosition.dx + _printSelectionSize.width;
      var bottomEdge = _printSelectionPosition.dy + _printSelectionSize.height;

      switch (handle) {
        case _PrintSelectionHandle.topLeft:
          leftEdge = (leftEdge + details.delta.dx)
              .clamp(0.0, rightEdge - minimumWidth)
              .toDouble();
          topEdge = (topEdge + details.delta.dy)
              .clamp(0.0, bottomEdge - minimumHeight)
              .toDouble();
          break;
        case _PrintSelectionHandle.topRight:
          rightEdge = (rightEdge + details.delta.dx)
              .clamp(leftEdge + minimumWidth, mapSize.width)
              .toDouble();
          topEdge = (topEdge + details.delta.dy)
              .clamp(0.0, bottomEdge - minimumHeight)
              .toDouble();
          break;
        case _PrintSelectionHandle.bottomLeft:
          leftEdge = (leftEdge + details.delta.dx)
              .clamp(0.0, rightEdge - minimumWidth)
              .toDouble();
          bottomEdge = (bottomEdge + details.delta.dy)
              .clamp(topEdge + minimumHeight, mapSize.height)
              .toDouble();
          break;
        case _PrintSelectionHandle.bottomRight:
          rightEdge = (rightEdge + details.delta.dx)
              .clamp(leftEdge + minimumWidth, mapSize.width)
              .toDouble();
          bottomEdge = (bottomEdge + details.delta.dy)
              .clamp(topEdge + minimumHeight, mapSize.height)
              .toDouble();
          break;
      }

      _printSelectionPosition = Offset(leftEdge, topEdge);
      _printSelectionSize = Size(rightEdge - leftEdge, bottomEdge - topEdge);
    });
  }

  Widget _buildPrintSelectionOverlay(Size mapSize) {
    _ensurePrintSelectionForMap(mapSize);
    final selectionRect = _printSelectionPosition & _printSelectionSize;

    return Positioned(
      left: 0,
      top: 0,
      width: mapSize.width,
      height: mapSize.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _PrintSelectionScrimPainter(selectionRect),
              ),
            ),
          ),
          Positioned(
            left: _printSelectionPosition.dx,
            top: _printSelectionPosition.dy,
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) {
                  setState(() => _isDraggingPrintSelection = true);
                },
                onPanUpdate: (details) => _movePrintSelection(details, mapSize),
                onPanEnd: (_) {
                  setState(() => _isDraggingPrintSelection = false);
                },
                onPanCancel: () {
                  setState(() => _isDraggingPrintSelection = false);
                },
                child: Container(
                  width: _printSelectionSize.width,
                  height: _printSelectionSize.height,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1967D2).withValues(alpha: 0.06),
                    border: Border.all(
                      color: const Color(0xFF1967D2),
                      width: 2,
                    ),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _buildPrintSelectionHandle(
                        _PrintSelectionHandle.topLeft,
                        Alignment.topLeft,
                        mapSize,
                      ),
                      _buildPrintSelectionHandle(
                        _PrintSelectionHandle.topRight,
                        Alignment.topRight,
                        mapSize,
                      ),
                      _buildPrintSelectionHandle(
                        _PrintSelectionHandle.bottomLeft,
                        Alignment.bottomLeft,
                        mapSize,
                      ),
                      _buildPrintSelectionHandle(
                        _PrintSelectionHandle.bottomRight,
                        Alignment.bottomRight,
                        mapSize,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrintSelectionHandle(
    _PrintSelectionHandle handle,
    Alignment alignment,
    Size mapSize,
  ) {
    return Align(
      alignment: alignment,
      child: MouseRegion(
        cursor: _cursorForPrintSelectionHandle(handle),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            setState(() => _activePrintSelectionHandle = handle);
          },
          onPanUpdate: (details) {
            _resizePrintSelection(handle, details, mapSize);
          },
          onPanEnd: (_) {
            setState(() => _activePrintSelectionHandle = null);
          },
          onPanCancel: () {
            setState(() => _activePrintSelectionHandle = null);
          },
          child: Container(
            width: _printSelectionHandleSize,
            height: _printSelectionHandleSize,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(
                color: const Color(0xFF1967D2),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  SystemMouseCursor _cursorForPrintSelectionHandle(
    _PrintSelectionHandle handle,
  ) {
    return switch (handle) {
      _PrintSelectionHandle.topLeft ||
      _PrintSelectionHandle.bottomRight =>
        SystemMouseCursors.resizeUpLeftDownRight,
      _PrintSelectionHandle.topRight ||
      _PrintSelectionHandle.bottomLeft =>
        SystemMouseCursors.resizeUpRightDownLeft,
    };
  }

  String _printMapDocumentName() {
    final label = (widget.distributorName?.trim().isNotEmpty ?? false)
        ? widget.distributorName!.trim()
        : (_job.primaryClient.trim().isNotEmpty ? _job.primaryClient : 'Map');
    return 'Distribution Map $label ${DateFormat('yyyy-MM-dd').format(_job.date)}';
  }

  Future<void> _persistDropOffPoint(LatLng point) async {
    final scheduleProvider = ProviderScope.containerOf(context, listen: false)
        .read(scheduleRiverpod);
    final freshJob = scheduleProvider.jobs.firstWhere(
      (j) => j.id == _job.id,
      orElse: () => _job,
    );
    final updatedMaps = List<CustomPolygon>.from(freshJob.workMaps);
    final dropoffIndex = updatedMaps.indexWhere(
        (wm) => wm.isPoint && wm.pointCategory == PointCategory.dropoff);
    if (dropoffIndex != -1) {
      updatedMaps[dropoffIndex] =
          updatedMaps[dropoffIndex].copyWith(points: [point]);
    }
    final updatedJob = freshJob.copyWith(
      workMaps: updatedMaps,
      dropOffPoint: point,
    );
    await scheduleProvider.updateJobWithUndo(
        freshJob, updatedJob, freshJob.date);
  }

  Future<void> _persistWorkAreaChanges() async {
    final scheduleProvider = ProviderScope.containerOf(context, listen: false)
        .read(scheduleRiverpod);
    final freshJob = scheduleProvider.jobs.firstWhere(
      (j) => j.id == _job.id,
      orElse: () => _job,
    );
    final updatedJob = freshJob.copyWith(
      workMaps: List<CustomPolygon>.from(_job.workMaps),
      workingAreas: _job.workMaps
          .where((w) => w.isPolygon)
          .map((w) => w.name)
          .where((name) => name.isNotEmpty)
          .toList(),
      dropOffPoint: _dropOffPoint,
    );
    await scheduleProvider.updateJobWithUndo(
        freshJob, updatedJob, freshJob.date);
  }

  @override
  Widget build(BuildContext context) {
    final scheduleProvider = ref.watch(scheduleRiverpod);
    final liveJob = scheduleProvider.jobs.firstWhere(
      (j) => j.id == _job.id,
      orElse: () => _job,
    );
    _syncLiveJob(liveJob);

    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    // Use full screen dimensions unless the print flow is capturing an A4 map.
    final appBarHeight = AppBar().preferredSize.height;
    final availableMapWidth = screenWidth;
    final availableMapHeight = screenHeight - appBarHeight;
    final mapSize = _printCaptureSize(availableMapWidth, availableMapHeight);
    final mapWidth = mapSize.width;
    final mapHeight = mapSize.height;
    final mapLeft = _isCapturingPrintMap
        ? (availableMapWidth - mapWidth).clamp(0.0, availableMapWidth) / 2
        : 0.0;
    final mapTop = 0.0;
    final currentMapSize = Size(mapWidth, mapHeight);
    _lastMapSize = currentMapSize;
    if (_printSelectionVisible) {
      _ensurePrintSelectionForMap(currentMapSize);
    }
    final hideMapChrome = _isCapturingPrintMap ||
        _isBrowserScreenshotCaptureActive ||
        _printSelectionVisible;
    final selectionIsInteracting = _isDraggingPrintSelection ||
        _activePrintSelectionHandle != null ||
        _isShiftPressed;

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

          IconButton(
            icon: Icon(
              Icons.crop_free,
              color: _printSelectionVisible ? const Color(0xFF1967D2) : null,
            ),
            tooltip: _printSelectionVisible
                ? 'Hide print capture area'
                : 'Adjust print capture area',
            onPressed: _isPrintingMap ? null : _togglePrintSelection,
          ),

          // Toggle polygon-name labels (editable client name shown on each
          // polygon; included in the printed map).
          IconButton(
            icon: Icon(
              _showPolygonLabels ? Icons.label : Icons.label_off_outlined,
              color: _showPolygonLabels ? const Color(0xFF1967D2) : null,
            ),
            tooltip: _showPolygonLabels
                ? 'Hide polygon labels'
                : 'Show polygon labels',
            onPressed: () {
              setState(() {
                if (_showPolygonLabels && _editingLabelIndex != null) {
                  _commitLabelTextEdit();
                }
                _showPolygonLabels = !_showPolygonLabels;
              });
            },
          ),

          // Print button
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'Print Map',
            onPressed: _isPrintingMap ? null : _printMap,
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
                          debugPrint('Error in onMapCreated: $e');
                        }
                      },
                      initialCameraPosition:
                          CameraPosition(target: _center, zoom: 12),
                      onCameraMove: (pos) {
                        // Track the camera so polygon labels stay glued to
                        // their geographic anchors on pan/zoom.
                        _currentCamera = pos;
                        if (mounted &&
                            _polygonLabels.isNotEmpty &&
                            _showPolygonLabels) {
                          setState(() {});
                        }
                      },
                      polygons: _polygons,
                      polylines: _polylines,
                      markers: {
                        if (!hideMapChrome) ..._vertexMarkers,
                        ..._customPointMarkers,
                        if (_dropOffMarker != null) _dropOffMarker!,
                      },
                      mapType: MapType.normal,
                      mapId: "89c628d2bb3002712797ce42",
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                      myLocationButtonEnabled: false,
                      scrollGesturesEnabled: !_isDraggingInfoBox &&
                          !_isResizingInfoBox &&
                          !_isDraggingWorkAreasBox &&
                          !_isResizingWorkAreasBox &&
                          _draggingLabelIndex == null &&
                          !selectionIsInteracting,
                      zoomGesturesEnabled: !_isDraggingInfoBox &&
                          !_isResizingInfoBox &&
                          !_isDraggingWorkAreasBox &&
                          !_isResizingWorkAreasBox &&
                          _draggingLabelIndex == null &&
                          !selectionIsInteracting,
                      rotateGesturesEnabled: false,
                      tiltGesturesEnabled: false,
                    ),
                    // Loading overlay
                    if (_isLoading)
                      Container(
                        color: Colors.white.withValues(alpha: 0.8),
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                    // Editable client-name labels on each polygon. Drawn on
                    // top of the map (so they're included in the captured
                    // screenshot) but below other moveable info boxes.
                    if (_showPolygonLabels)
                      ..._buildPolygonLabelOverlays(currentMapSize),
                    // Information Box (rendered as part of the screenshot)
                    if (!hideMapChrome)
                      Positioned(
                        left: _infoBoxPosition.dx,
                        top: _infoBoxPosition.dy,
                        child: _buildInfoBox(),
                      ),
                    // Work Areas Box (only when multiple areas exist)
                    if (!hideMapChrome && _job.workMaps.length > 1)
                      Positioned(
                        left: _workAreasBoxPosition.dx,
                        top: _workAreasBoxPosition.dy,
                        child: _buildWorkAreasBox(),
                      ),
                    // Vertex editing toolbar
                    if (!hideMapChrome &&
                        _isEditingVertices &&
                        _editingPolygonIndex != null)
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
                                    'Editing: ${_job.workMaps[_editingPolygonIndex!].name}',
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
                    if (!hideMapChrome &&
                        _isEditingVertices &&
                        _editingPolygonIndex == null)
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
                    if (_printSelectionVisible &&
                        !_isBrowserScreenshotCaptureActive)
                      _buildPrintSelectionOverlay(currentMapSize),
                  ],
                ),
              ),
            ),
          ),

          // Movable Information Box (for positioning only - invisible)
          if (!hideMapChrome)
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
                              ? Colors.red.withValues(alpha: 0.8)
                              : Colors.blue.withValues(alpha: 0),
                          width: (_isDraggingInfoBox || _isResizingInfoBox)
                              ? 2
                              : 1,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.drag_handle,
                          color: (_isDraggingInfoBox || _isResizingInfoBox)
                              ? Colors.red.withValues(alpha: 0.7)
                              : Colors.blue.withValues(alpha: 0),
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
                            final maxSize =
                                Size(mapWidth * 0.4, mapHeight * 0.4);

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
                                ? Colors.red.withValues(alpha: 0.8)
                                : Colors.blue.withValues(
                                    alpha: _isDraggingInfoBox ? 0.6 : 0),
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
          if (!hideMapChrome && _job.workMaps.length > 1)
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
                              ? Colors.red.withValues(alpha: 0.8)
                              : Colors.blue.withValues(alpha: 0),
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
                              ? Colors.red.withValues(alpha: 0.7)
                              : Colors.blue.withValues(alpha: 0),
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
                                ? Colors.red.withValues(alpha: 0.8)
                                : Colors.blue.withValues(
                                    alpha: _isDraggingWorkAreasBox ? 0.6 : 0),
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
          if (_isPrintingMap && !_isBrowserScreenshotCaptureActive)
            Positioned.fill(
              child: AbsorbPointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.32),
                  child: Center(
                    child: Material(
                      color: Colors.white,
                      elevation: 8,
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 280,
                          maxWidth: 360,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  _printProgressMessage.isEmpty
                                      ? 'Preparing print...'
                                      : _printProgressMessage,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Build one Positioned widget per polygon label. Each label is rendered
  /// with a transparent background so the map underneath stays visible in
  /// the printout. Tapping a label switches it into a TextField for inline
  /// editing; dragging moves the label and re-anchors it to a new LatLng.
  List<Widget> _buildPolygonLabelOverlays(Size mapSize) {
    if (_polygonLabels.isEmpty || mapSize.width <= 0 || mapSize.height <= 0) {
      return const [];
    }
    final widgets = <Widget>[];
    final entries = _polygonLabels.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in entries) {
      final index = entry.key;
      final label = entry.value;
      final screen = _labelLatLngToScreen(label.anchor, mapSize);
      // Skip labels that have been panned off-screen entirely.
      if (screen.dx < -200 ||
          screen.dy < -100 ||
          screen.dx > mapSize.width + 200 ||
          screen.dy > mapSize.height + 100) {
        continue;
      }

      final isEditing = _editingLabelIndex == index;
      // Approximate dimensions used to centre the label on its anchor.
      const double approxWidth = 180;
      const double approxHeight = 36;
      final left = (screen.dx - approxWidth / 2).clamp(
        -approxWidth / 2,
        mapSize.width - approxWidth / 2,
      );
      final top = (screen.dy - approxHeight / 2).clamp(
        -approxHeight / 2,
        mapSize.height - approxHeight / 2,
      );

      widgets.add(
        Positioned(
          left: left,
          top: top,
          width: approxWidth,
          height: approxHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: isEditing ? null : () => _beginLabelTextEdit(index),
            onPanStart: isEditing
                ? null
                : (_) {
                    setState(() => _draggingLabelIndex = index);
                  },
            onPanUpdate: isEditing
                ? null
                : (details) {
                    final current =
                        _labelLatLngToScreen(label.anchor, mapSize);
                    final next = current + details.delta;
                    setState(() {
                      label.anchor = _labelScreenToLatLng(next, mapSize);
                    });
                  },
            onPanEnd: isEditing
                ? null
                : (_) {
                    setState(() => _draggingLabelIndex = null);
                  },
            child: Center(
              child: isEditing
                  ? _buildLabelEditor(index)
                  : _buildLabelText(label.text),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  /// Outlined text used for the label – the stroke keeps it readable on any
  /// background while the fill stays opaque so the colours print cleanly.
  Widget _buildLabelText(String text) {
    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    const fontSize = 13.0;
    final style = const TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.1,
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        // White outline for readability over varied map backgrounds.
        Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = Colors.white,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(color: Colors.black),
        ),
      ],
    );
  }

  Widget _buildLabelEditor(int index) {
    return Material(
      color: Colors.white.withValues(alpha: 0.85),
      elevation: 2,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: TextField(
          controller: _labelEditController,
          focusNode: _labelEditFocus,
          autofocus: true,
          textAlign: TextAlign.center,
          maxLines: 1,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            hintText: 'Label…',
          ),
          onSubmitted: (_) {
            setState(_commitLabelTextEdit);
          },
          onTapOutside: (_) {
            if (_editingLabelIndex == index) {
              setState(_commitLabelTextEdit);
            }
          },
        ),
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
            color: Colors.black.withValues(alpha: 0.2),
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
                _job.workMaps.isEmpty
                    ? '.'
                    : _job.workMaps.length == 1
                        ? _job.workMaps.first.name
                        : '${_job.workMaps.length} work areas'),

            // Date
            _buildInfoRow('Date:', dateFormatter.format(_job.date)),

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
            ..._job.clients.asMap().entries.map((entry) {
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

            if (_job.clients.isEmpty)
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
            color: Colors.black.withValues(alpha: 0.2),
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
              children: _job.workMaps.asMap().entries.map((entry) {
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
    HardwareKeyboard.instance.removeHandler(_handlePrintSelectionKey);
    _labelEditController?.dispose();
    _labelEditFocus?.dispose();
    try {
      _controller?.dispose();
    } catch (e) {
      debugPrint('Error disposing map controller: $e');
    }
    super.dispose();
  }
}

class _PrintSelectionScrimPainter extends CustomPainter {
  final Rect selectionRect;

  const _PrintSelectionScrimPainter(this.selectionRect);

  @override
  void paint(Canvas canvas, Size size) {
    final overlayPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(selectionRect);
    canvas.drawPath(
      overlayPath,
      Paint()..color = Colors.black.withValues(alpha: 0.22),
    );
  }

  @override
  bool shouldRepaint(covariant _PrintSelectionScrimPainter oldDelegate) {
    return oldDelegate.selectionRect != selectionRect;
  }
}
