import 'package:clmschedule/widgets/app_toast.dart';
import 'dart:math' show atan, cos, exp, log, max, min, pi, pow, sin;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../providers/schedule_provider.dart';
import '../services/job_client_bookings.dart';
import '../services/job_cloud_map_data_service.dart';
import '../shareable_maps/models/map_polyline.dart';
import '../shareable_maps/services/map_thumbnail_service.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import '../utils/map_pdf.dart';
import '../utils/map_pin_icons.dart';
import '../utils/print_map_renderer.dart';
import '../utils/vertex_delete_key.dart';
import 'job_map_link.dart';
import 'print_map_distributor_tabs.dart';
import '../shareable_maps/providers/map_gesture_provider.dart';
import '../shareable_maps/widgets/map_overlay.dart';

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
  /// Cloud map style shared by the on-screen map and the printed map.
  static const String _mapId = '89c628d2bb3002712797ce42';

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
  int _globalBorderWidth = 4;

  // Position and size of the movable info box
  Offset _infoBoxPosition = const Offset(20, 20);
  Size _infoBoxSize = const Size(250, 300); // Default size
  double _fontScale = 1.0; // Font scale factor

  // Indices (into _job.clients) of clients hidden from the distributor info
  // box. Hidden clients are excluded from the on-screen box (and screenshots)
  // and the printed PDF, but can be brought back from the visibility dialog.
  final Set<int> _hiddenClientIndices = {};

  // Global key for capturing the map widget
  final GlobalKey _mapKey = GlobalKey();

  // Vertex editing state
  bool _isEditingVertices = false;
  int? _editingPolygonIndex; // which workmap polygon is being edited
  List<LatLng>? _editingPoints; // mutable copy of the polygon's points
  Set<Marker> _vertexMarkers = {};
  BitmapDescriptor? _vertexMarkerIcon;
  BitmapDescriptor? _midpointMarkerIcon;
  // Job type and appointment time of each client's Job List job, so a pin
  // can show the work done there — a bin for a junk collection, a sofa for
  // a furniture move, the time of a booked call-out. Loaded per job; none
  // until it arrives.
  JobClientBookings _bookings = JobClientBookings.none;
  String? _clientJobTypesKey;
  late Job _job;
  // Distributor of the job shown. Changes when another distributor's tab
  // is picked in the top bar.
  String? _distributorName;
  String _jobSignature = '';
  String? _pendingJobSignature;

  // Linked-map overlay data (recorded tracks + polygons), populated when the
  // job has linked maps (`_job.effectiveLinkedMaps`). Fetched live from the
  // full ShareableMap documents each time the links change — not cached on
  // the Job — so this always reflects the linked maps' current state.
  List<MapPolyline> _linkedMapTracks = [];
  List<CustomPolygon> _linkedMapPolygons = [];
  bool _isLoadingCloudMapData = false;
  bool _showCloudTracks = true;
  // Tracks which "jobId::mapId::monthKey" combination the overlay data above
  // was last loaded for, so re-linking a different map triggers a refetch.
  String? _cloudMapDataLoadedForJobId;
  bool _isPrintingMap = false;
  String _printProgressMessage = '';

  // Editable polygon labels (client names) overlaid on each polygon.
  // Keyed by the polygon's index in `_job.workMaps`. Created lazily so that
  // existing anchor/text edits are preserved across rebuilds.
  final Map<int, _PolygonLabel> _polygonLabels = {};
  bool _showPolygonLabels = false;
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
  // Clockwise quarter turns applied to the map layer itself. The map ID is a
  // raster map, which ignores camera heading, so the widget is turned
  // instead — 90° steps, enough to fit a tall area on a wide page.
  int _mapQuarterTurns = 0;

  @override
  void initState() {
    super.initState();
    _job = widget.job;
    _distributorName = widget.distributorName;
    _jobSignature = _signatureFor(_job);
    _initializeMap();
    _createMarkerIcons();
    _maybeLoadCloudMapData();
    _loadClientJobTypes();
  }

  @override
  void didUpdateWidget(covariant PrintMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.job.id != widget.job.id) {
      _switchToJob(widget.job, widget.distributorName);
    } else if (oldWidget.job != widget.job) {
      _replaceJob(widget.job);
    }
  }

  /// Show another job (another distributor's tab). Edits made for the
  /// previous job — border tweaks, labels, hidden clients, rotation — are
  /// tied to its work areas, so they start fresh, and the map re-frames.
  void _switchToJob(Job job, String? distributorName) {
    if (job.id == _job.id) return;
    setState(() {
      if (_editingLabelIndex != null) _commitLabelTextEdit();
      _cancelVertexEditing();
      _isEditingVertices = false;
      _polygonOverrides.clear();
      _polygonLabels.clear();
      _hiddenClientIndices.clear();
      _draggingLabelIndex = null;
      _mapQuarterTurns = 0;
      _pendingJobSignature = null;
      _linkedMapTracks = [];
      _linkedMapPolygons = [];
      _cloudMapDataLoadedForJobId = null;
      _isLoadingCloudMapData = false;
      _distributorName = distributorName;
      _replaceJob(job);
      if (_showPolygonLabels) _ensurePolygonLabels();
    });
    _updateMapCenter();
  }

  /// Every job on this job's date with work areas, one tab each, in the
  /// schedule's distributor order. The job shown is always included.
  List<({Job job, String name})> _sameDateJobs(ScheduleProvider schedule) {
    final order = <String, int>{
      for (var i = 0; i < schedule.distributors.length; i++)
        schedule.distributors[i].id: i,
    };
    final jobs = schedule
        .getJobsForDate(_job.date)
        .where((j) => j.workMaps.isNotEmpty || j.id == _job.id)
        .toList();
    if (!jobs.any((j) => j.id == _job.id)) jobs.add(_job);
    jobs.sort((a, b) {
      final byDistributor = (order[a.distributorId] ?? 1 << 20)
          .compareTo(order[b.distributorId] ?? 1 << 20);
      return byDistributor != 0 ? byDistributor : a.id.compareTo(b.id);
    });
    return [
      for (final job in jobs)
        (job: job, name: _distributorNameFor(schedule, job)),
    ];
  }

  String _distributorNameFor(ScheduleProvider schedule, Job job) {
    if (job.id == _job.id && (_distributorName?.trim().isNotEmpty ?? false)) {
      return _distributorName!.trim();
    }
    for (final d in schedule.distributors) {
      if (d.id == job.distributorId) return d.name;
    }
    return 'Unknown';
  }

  Widget _buildDistributorTabs(ScheduleProvider schedule) {
    final entries = _sameDateJobs(schedule);
    // A distributor with two jobs that day gets "Name 1", "Name 2".
    final counts = <String, int>{};
    for (final e in entries) {
      counts[e.job.distributorId] = (counts[e.job.distributorId] ?? 0) + 1;
    }
    final seen = <String, int>{};
    final tabs = [
      for (final e in entries)
        PrintMapTabItem(
          jobId: e.job.id,
          label: (counts[e.job.distributorId] ?? 1) > 1
              ? '${e.name} ${seen[e.job.distributorId] = (seen[e.job.distributorId] ?? 0) + 1}'
              : e.name,
        ),
    ];
    return PrintMapDistributorTabs(
      tabs: tabs,
      selectedJobId: _job.id,
      onSelected: _isPrintingMap
          ? null
          : (jobId) {
              final entry = entries.firstWhere((e) => e.job.id == jobId);
              _switchToJob(entry.job, entry.name);
            },
    );
  }

  void _replaceJob(Job job) {
    _job = job;
    _jobSignature = _signatureFor(job);
    _dropOffPoint =
        job.dropOffPoint ?? Job.estimateDropOffPointFromWorkMaps(job.workMaps);
    _updateMapView();
    _maybeLoadCloudMapData();
    _loadClientJobTypes();
  }

  /// Fetch the linked map's polygons and (if it has a Cloud Storage folder)
  /// its compiled GPS tracks. No-op (and the overlay UI stays entirely
  /// hidden) when no map is linked.
  Future<void> _maybeLoadCloudMapData() async {
    if (!_job.hasLinkedMaps) {
      if (_linkedMapTracks.isNotEmpty || _linkedMapPolygons.isNotEmpty) {
        setState(() {
          _linkedMapTracks = [];
          _linkedMapPolygons = [];
          _cloudMapDataLoadedForJobId = null;
          _updateMapView();
        });
      }
      return;
    }
    final loadKey = [
      _job.id,
      for (final link in _job.effectiveLinkedMaps)
        '${link.mapId}:${link.monthKey}',
    ].join('::');
    if (_cloudMapDataLoadedForJobId == loadKey) return;
    final loadingJobId = _job.id;

    setState(() => _isLoadingCloudMapData = true);
    var tracks = <MapPolyline>[];
    var polygons = <CustomPolygon>[];
    try {
      for (final link in _job.effectiveLinkedMaps) {
        final linkedMap = await ShareableMapsFirestoreService()
            .getMap(link.monthKey, link.mapId);
        if (linkedMap == null) continue;
        polygons.addAll(linkedMap.layers.expand((l) => l.polygons));
        final folderPath = linkedMap.cloudFolderPaths.isNotEmpty
            ? linkedMap.cloudFolderPaths.first
            : linkedMap.storageFolderPath;
        if (folderPath != null && folderPath.isNotEmpty) {
          tracks.addAll(
              await JobCloudMapDataService().fetchCompiledTracks(folderPath));
        }
      }
    } catch (_) {
      // Keep whatever loaded if a linked map fails to fetch/parse.
    }
    if (!mounted) return;
    // Another distributor's tab was picked while this loaded.
    if (_job.id != loadingJobId) return;
    setState(() {
      _linkedMapTracks = tracks;
      _linkedMapPolygons = polygons;
      _isLoadingCloudMapData = false;
      _cloudMapDataLoadedForJobId = loadKey;
      _updateMapView();
    });
  }

  List<MapPolyline> _currentCloudTracks() {
    if (!_showCloudTracks) return const [];
    return _linkedMapTracks;
  }

  List<CustomPolygon> _currentLinkedMapPolygons() {
    if (!_showCloudTracks) return const [];
    return _linkedMapPolygons;
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
      job.effectiveLinkedMaps.map((m) => '${m.mapId}:${m.monthKey}').join(','),
      drop,
      maps,
    ].join('|');
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
          final style = _pinStyleFor(workMap);
          final name = workMap.name.trim();
          _customPointMarkers.add(_pinMarker(
            markerId: 'workmap_marker_$i',
            position: workMap.points.first,
            style: style,
            zIndex: _bookings.layerFor(workMap),
            infoWindow: InfoWindow(
              title: name.isNotEmpty ? name : style.label,
              snippet: name.isNotEmpty ? style.label : null,
            ),
          ));
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
              if (ref.read(mapGestureRiverpod).isHeld) return;
              if (_isEditingVertices) {
                _selectPolygonForEditing(i);
              }
            },
          ),
        );
      }
    }

    // Linked-map overlay: recorded GPS tracks + the linked map's own polygons.
    final cloudTracks = _currentCloudTracks();
    for (int i = 0; i < cloudTracks.length; i++) {
      final track = cloudTracks[i];
      if (track.points.length < 2) continue;
      _polylines.add(
        Polyline(
          polylineId: PolylineId('cloud_track_$i'),
          points: track.points,
          color: Colors.blueAccent,
          width: 3,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
        ),
      );
    }

    final linkedMapPolygons = _currentLinkedMapPolygons();
    for (int i = 0; i < linkedMapPolygons.length; i++) {
      final polygon = linkedMapPolygons[i];
      if (polygon.points.length < 3) continue;
      _polygons.add(
        Polygon(
          polygonId: PolygonId('linked_map_polygon_$i'),
          points: polygon.points,
          fillColor: Colors.transparent,
          strokeColor: polygon.color,
          strokeWidth: 5,
        ),
      );
    }

    if (_dropOffPoint != null) {
      _dropOffMarker = _pinMarker(
        markerId: 'dropoff_point',
        position: _dropOffPoint!,
        style: MapPinStyle.dropOff,
        zIndex: PinLayer.dropOff,
        draggable: true,
        infoWindow: const InfoWindow(title: 'Drop-off Point'),
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
    final cloudTracks = _currentCloudTracks();
    final linkedMapPolygons = _currentLinkedMapPolygons();
    final hasBoundsSource = _job.workMaps.isNotEmpty ||
        cloudTracks.isNotEmpty ||
        linkedMapPolygons.isNotEmpty;

    if (hasBoundsSource) {
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
      // Include recorded tracks so the map frames the full covered route.
      for (final track in cloudTracks) {
        for (final point in track.points) {
          minLat = min(minLat, point.latitude);
          maxLat = max(maxLat, point.latitude);
          minLng = min(minLng, point.longitude);
          maxLng = max(maxLng, point.longitude);
        }
      }
      // Include the linked map's own polygons too.
      for (final polygon in linkedMapPolygons) {
        for (final point in polygon.points) {
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
    // The map layer is turned clockwise by _mapQuarterTurns × 90°.
    final d = _rotateOffset(Offset(px - cx, py - cy), _mapQuarterTurns * 90.0);
    return Offset(screen.width / 2 + d.dx, screen.height / 2 + d.dy);
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
    final d = _rotateOffset(
      Offset(offset.dx - screen.width / 2, offset.dy - screen.height / 2),
      -_mapQuarterTurns * 90.0,
    );
    final px = cx + d.dx;
    final py = cy + d.dy;

    final lng = (px / scale) / 256 * 360 - 180;
    final n = pi - 2 * pi * (py / scale) / 256;
    final lat = (180 / pi) * atan((exp(n) - exp(-n)) / 2);
    return LatLng(lat, lng);
  }

  /// Rotates [v] clockwise by [degrees] in screen (y-down) coordinates.
  static Offset _rotateOffset(Offset v, double degrees) {
    final r = degrees * pi / 180;
    final c = cos(r), s = sin(r);
    return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
  }

  /// Web-Mercator world pixel (zoom 0, 256px world) for [p].
  static Offset _worldPixel(LatLng p) {
    final s = sin(p.latitude * pi / 180).clamp(-0.9999, 0.9999);
    return Offset(
      (p.longitude + 180) / 360 * 256,
      (0.5 - log((1 + s) / (1 - s)) / (4 * pi)) * 256,
    );
  }

  static LatLng _latLngFromWorldPixel(Offset w) {
    final lng = w.dx / 256 * 360 - 180;
    final n = pi - 2 * pi * w.dy / 256;
    final lat = (180 / pi) * atan((exp(n) - exp(-n)) / 2);
    return LatLng(lat, lng);
  }

  /// Every point the print map frames: work maps, recorded tracks and the
  /// linked maps' polygons.
  List<LatLng> _framingPoints() => [
        for (final workMap in _job.workMaps) ...workMap.points,
        for (final track in _currentCloudTracks()) ...track.points,
        for (final polygon in _currentLinkedMapPolygons()) ...polygon.points,
      ];

  /// Turn the map layer by [turns] clockwise quarter turns. The camera
  /// target stays on the frame centre, so the view turns in place.
  void _rotateMapBy(int turns) {
    setState(() => _mapQuarterTurns = (_mapQuarterTurns + turns) % 4);
  }

  // Drag state for the turned map: the camera at drag start plus the total
  // pointer movement since, applied at most once per frame.
  CameraPosition? _turnedPanStart;
  Offset _turnedPanDelta = Offset.zero;
  bool _turnedPanFrameScheduled = false;

  void _startTurnedPan() {
    _turnedPanStart = _currentCamera;
    _turnedPanDelta = Offset.zero;
  }

  void _updateTurnedPan(Offset screenDelta, Size frame) {
    if (_turnedPanStart == null || ref.read(mapGestureRiverpod).isHeld) return;
    _turnedPanDelta += screenDelta;
    if (_turnedPanFrameScheduled) return;
    _turnedPanFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _turnedPanFrameScheduled = false;
      _applyTurnedPan(frame);
    });
  }

  void _endTurnedPan(Size frame) {
    _applyTurnedPan(frame);
    _turnedPanStart = null;
  }

  /// Move the turned map so its content follows the pointer on screen.
  ///
  /// The web plugin's pan calls (panBy/panTo) animate, and a fresh animation
  /// per pointer event stutters. fitBounds jumps without animating, so the
  /// camera is set with bounds 90% of the viewport around the new centre —
  /// on a whole-level raster map that keeps the zoom unchanged.
  void _applyTurnedPan(Size frame) {
    final start = _turnedPanStart;
    final controller = _controller;
    if (start == null || controller == null || !mounted) return;
    final scale = pow(2, start.zoom).toDouble();
    // Total movement in the map's own (unturned) frame, in world pixels.
    final moved =
        _rotateOffset(_turnedPanDelta, -_mapQuarterTurns * 90.0) / scale;
    final centre = _worldPixel(start.target) - moved;
    // RotatedBox hands the map a swapped size on odd turns.
    final own =
        _mapQuarterTurns.isOdd ? Size(frame.height, frame.width) : frame;
    final half = Offset(own.width, own.height) * (0.45 / scale);
    controller.moveCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: _latLngFromWorldPixel(
            Offset(centre.dx - half.dx, centre.dy + half.dy)),
        northeast: _latLngFromWorldPixel(
            Offset(centre.dx + half.dx, centre.dy - half.dy)),
      ),
      0,
    ));
  }

  DateTime _lastWheelZoom = DateTime(0);

  /// Wheel zoom on the turned map, one whole level per notch (raster maps
  /// take no fractional zoom), keeping the point under the cursor fixed.
  void _zoomTurnedMap(PointerScrollEvent event, Size frame) {
    final controller = _controller;
    final dy = event.scrollDelta.dy;
    if (controller == null || dy == 0) return;
    if (ref.read(mapGestureRiverpod).isHeld) return;
    // Trackpads send a burst of small events per swipe.
    final now = DateTime.now();
    if (now.difference(_lastWheelZoom) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastWheelZoom = now;

    final current = _currentCamera.zoom.roundToDouble();
    final zoom = (current + (dy < 0 ? 1 : -1)).clamp(2.0, 21.0);
    if (zoom == current) return;
    final focus = _worldPixel(_labelScreenToLatLng(event.localPosition, frame));
    final target = _worldPixel(_currentCamera.target);
    final k = pow(2, _currentCamera.zoom - zoom).toDouble();
    controller.moveCamera(CameraUpdate.newLatLngZoom(
      _latLngFromWorldPixel(focus + (target - focus) * k),
      zoom,
    ));
  }

  /// Pick upright or sideways — whichever lets the job's area fill the
  /// print frame (the capture area when shown, otherwise the whole map) at
  /// the higher zoom — then zoom in as far as that allows. A tall area on a
  /// wide page gets turned on its side, so the roads print in more detail.
  void _rotateToFit() {
    final controller = _controller;
    final mapContext = _mapKey.currentContext;
    final box = mapContext?.findRenderObject();
    if (controller == null || box is! RenderBox || !box.hasSize) return;

    final points = _framingPoints();
    if (points.length < 2) return;
    final origin = _worldPixel(points.first);
    final world = [for (final p in points) _worldPixel(p) - origin];

    final mapSize = box.size;
    final frame = Offset.zero & mapSize;
    const padding = 32.0;
    final frameW = max(frame.width - padding * 2, 40.0);
    final frameH = max(frame.height - padding * 2, 40.0);

    double fitScale(Rect b) => min(
          frameW / max(b.width, 1e-9),
          frameH / max(b.height, 1e-9),
        );
    Rect screenBounds(int turns) {
      var minX = double.infinity, minY = double.infinity;
      var maxX = -double.infinity, maxY = -double.infinity;
      for (final w in world) {
        final q = _rotateOffset(w, turns * 90.0);
        minX = min(minX, q.dx);
        maxX = max(maxX, q.dx);
        minY = min(minY, q.dy);
        maxY = max(maxY, q.dy);
      }
      return Rect.fromLTRB(minX, minY, maxX, maxY);
    }

    // Stay north-up unless sideways is clearly tighter. Sideways keeps the
    // current direction if already turned, else turns clockwise.
    final upright = screenBounds(0);
    final sidewaysTurns = _mapQuarterTurns == 3 ? 3 : 1;
    final sideways = screenBounds(sidewaysTurns);
    final turnSideways = fitScale(sideways) > fitScale(upright) * 1.03;
    final turns = turnSideways ? sidewaysTurns : 0;
    final bounds = turnSideways ? sideways : upright;

    // Raster maps only take whole zoom levels; round down so it still fits.
    final zoom =
        (log(fitScale(bounds)) / log(2)).floorToDouble().clamp(2.0, 21.0);
    final appliedScale = pow(2, zoom).toDouble();
    // Put the area's centre on the frame centre, which sits off the map
    // centre when the capture area is shown.
    final frameOffset = frame.center - mapSize.center(Offset.zero);
    final targetScreen = bounds.center - frameOffset / appliedScale;
    final target = _latLngFromWorldPixel(
      _rotateOffset(targetScreen, -turns * 90.0) + origin,
    );

    setState(() => _mapQuarterTurns = turns);
    controller.animateCamera(CameraUpdate.newLatLngZoom(target, zoom));
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

  // ── Descriptive pins ──────────────────────────────────────────────

  /// Looks up the Job List jobs of this job's clients, so pins can show the
  /// work done at them. Fetched once per job and client list.
  Future<void> _loadClientJobTypes() async {
    final job = _job;
    final key = '${job.id}|${job.date.toIso8601String()}|'
        '${job.clients.join(',')}';
    if (key == _clientJobTypesKey) return;
    _clientJobTypesKey = key;
    if (job.clients.every((c) => c.trim().isEmpty)) {
      if (_bookings.typeIds.isNotEmpty) {
        setState(() {
          _bookings = JobClientBookings.none;
          _updateMapView();
        });
      }
      return;
    }

    final JobClientBookings bookings;
    try {
      bookings = (await JobClientBookings.load([job]))[job.id] ??
          JobClientBookings.none;
    } catch (e) {
      // Pins fall back to their category pictures.
      debugPrint('PrintMapView: client job types lookup failed: $e');
      if (_clientJobTypesKey == key) _clientJobTypesKey = null;
      return;
    }
    if (!mounted || _clientJobTypesKey != key) return;
    _bookings = bookings;
    await _preparePinIcons();
    if (!mounted || _clientJobTypesKey != key) return;
    setState(_updateMapView);
  }

  MapPinStyle _pinStyleFor(CustomPolygon point) => _bookings.styleFor(point);

  /// Every pin this job shows, drop-off first, one per picture and label.
  List<MapPinStyle> _pinStylesInUse() {
    final styles = <MapPinStyle>{
      if (_dropOffPoint != null) MapPinStyle.dropOff,
      for (final wm in _job.workMaps)
        if (wm.isPoint &&
            wm.points.isNotEmpty &&
            wm.pointCategory != PointCategory.dropoff)
          _pinStyleFor(wm),
    };
    return styles.toList();
  }

  /// Rasterises the pins this job needs, for the on-screen markers.
  Future<void> _preparePinIcons() async {
    try {
      await Future.wait(_pinStylesInUse().map(MapPinIcons.bitmap));
    } catch (e) {
      // Default markers stand in; no retrying on every rebuild.
      _pinIconsFailed = true;
      debugPrint('PrintMapView: pin icons failed: $e');
    }
  }

  /// A marker showing [style], tip on [position], stacked by [zIndex]
  /// ([PinLayer]). Until its picture is ready it is a default marker of the
  /// same colour.
  Marker _pinMarker({
    required String markerId,
    required LatLng position,
    required MapPinStyle style,
    int zIndex = PinLayer.point,
    InfoWindow infoWindow = InfoWindow.noText,
    bool draggable = false,
    ValueChanged<LatLng>? onDragEnd,
  }) {
    final pin = MapPinIcons.cached(style);
    if (pin == null) _preparePinIconsLater();
    return Marker(
      markerId: MarkerId(markerId),
      position: position,
      icon: pin?.$1 ??
          BitmapDescriptor.defaultMarkerWithHue(
              HSLColor.fromColor(style.color).hue),
      anchor: pin?.$2 ?? const Offset(0.5, 1.0),
      zIndexInt: zIndex,
      infoWindow: infoWindow,
      draggable: draggable,
      onDragEnd: onDragEnd,
    );
  }

  bool _pinIconsPending = false;
  bool _pinIconsFailed = false;

  /// A pin appeared whose picture is not drawn yet (a point added while
  /// the map is open): draw it and refresh the markers.
  void _preparePinIconsLater() {
    if (_pinIconsPending || _pinIconsFailed) return;
    _pinIconsPending = true;
    Future.microtask(() async {
      await _preparePinIcons();
      _pinIconsPending = false;
      if (mounted) setState(_updateMapView);
    });
  }

  /// The printed key to the pins on the map, black and white like them.
  /// Plain unnamed points need no explaining and are left out.
  Future<List<DistributionMapPinLegendEntry>> _pinLegend() async {
    final entries = <DistributionMapPinLegendEntry>[];
    final seen = <String>{};
    for (final style in _pinStylesInUse()) {
      if (style.shape == PinShape.dot || !seen.add(style.label)) continue;
      entries.add(DistributionMapPinLegendEntry(
        pngBytes: await MapPinIcons.png(style.withoutTime, mono: true),
        label: style.label,
      ));
    }
    return entries;
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
    await _preparePinIcons();
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
        // Hold Delete / Backspace and click to remove the point.
        onTap: () {
          if (isVertexDeleteHeld()) _deleteVertex(i);
        },
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

  /// Remove the vertex at [index] from the edit in progress — no
  /// confirmation, for fast cleanup. Cancel brings it back.
  void _deleteVertex(int index) {
    final points = _editingPoints;
    if (points == null || index < 0 || index >= points.length) return;
    if (points.length <= 3) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentToast()
        ..showToast(const SnackBar(
          content: Text('An area needs at least 3 points'),
          duration: Duration(seconds: 2),
        ));
      return;
    }
    points.removeAt(index);
    setState(() {
      _rebuildVertexMarkers();
      _updateMapView();
    });
  }

  void _saveVertexEditing() {
    if (_editingPolygonIndex == null || _editingPoints == null) return;
    final idx = _editingPolygonIndex!;
    final old = _job.workMaps[idx];
    final updatedMaps = List<CustomPolygon>.from(_job.workMaps);
    updatedMaps[idx] = old.copyWith(points: List<LatLng>.from(_editingPoints!));
    _job = _job.copyWith(workMaps: updatedMaps);

    // Keep drop-off point aligned to updated work areas. One save carries
    // both: _persistDropOffPoint alone rebuilt the job from the stored
    // (pre-edit) polygons, so the vertex edit was lost whenever the
    // drop-off had to move.
    if (_dropOffPoint == null ||
        !Job.isPointInsideAnyWorkArea(_dropOffPoint!, _job.workMaps)) {
      _dropOffPoint = Job.estimateDropOffPointFromWorkMaps(_job.workMaps);
    }
    _persistWorkAreaChanges();

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

    final messenger = ScaffoldMessenger.of(context);
    String? errorMessage;

    try {
      if (_printAreas().isEmpty && _dropOffPoint == null) {
        throw Exception('this job has no work areas to print.');
      }

      setState(() {
        _isPrintingMap = true;
        _printProgressMessage = 'Fetching Google map...';
      });

      // Built from Google Static Maps: one page fitted to the work areas,
      // or an overview plus zoomed-in sections when that is the only way
      // to keep street names readable. No screen capture, so no prompt.
      final pages = await PrintMapRenderer.renderBook(
        areas: _printAreas(),
        extraFitPoints: [if (_dropOffPoint != null) _dropOffPoint!],
        polygons: _staticMapPolygons() ?? const [],
        polylines: _staticMapPolylines() ?? const [],
        markers: _staticMapMarkers() ?? const [],
        labels: _printLabels(),
        mapId: _mapId,
        onProgress: _setPrintProgress,
      );

      final pinLegend = await _pinLegend();
      if (!mounted) return;
      _setPrintProgress(pages.length > 1
          ? 'Building ${pages.length}-page print PDF...'
          : 'Building print PDF...');

      final pdfBytes = await compute(
        generateDistributionMapPdfFromData,
        distributionMapPdfPayload(
          pages: [
            for (final page in pages)
              DistributionMapPdfPage(
                imageBytes: page.pngBytes,
                isLandscape: page.isLandscape,
                section: page.section,
                sectionCount: page.sectionCount,
              ),
          ],
          job: _job,
          distributorName: _distributorName,
          hiddenClientIndices: _hiddenClientIndices,
          hasCloudTracks: _currentCloudTracks().isNotEmpty,
          pinLegend: pinLegend,
        ),
        debugLabel: 'distribution-map-pdf',
      );

      if (!mounted) return;

      setState(() {
        _isPrintingMap = false;
        _printProgressMessage = '';
      });

      await Printing.layoutPdf(
        name: _printMapDocumentName(),
        onLayout: (_) async => pdfBytes,
      );
    } catch (e) {
      errorMessage =
          'Error preparing map: ${e.toString().replaceFirst(RegExp(r'^(Exception|Bad state): '), '')}';
    } finally {
      if (mounted) {
        setState(() {
          _isPrintingMap = false;
          _printProgressMessage = '';
        });
      }
    }

    if (errorMessage != null && mounted) {
      messenger.showToast(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _setPrintProgress(String message) {
    if (!mounted) return;
    setState(() => _printProgressMessage = message);
  }

  /// Each work area's points (an edit in progress taken as it stands).
  /// They decide the printed framing and any zoomed-in sections. Drop-off
  /// pins are left out: the drop-off is framed on the overview only.
  List<List<LatLng>> _printAreas() => [
        for (int i = 0; i < _job.workMaps.length; i++)
          if (!(_job.workMaps[i].isPoint &&
              _job.workMaps[i].pointCategory == PointCategory.dropoff))
            _pointsForWorkMap(i, _job.workMaps[i]),
      ];

  /// Polygon name labels, when shown, print where they sit on screen.
  List<PrintMapLabel> _printLabels() {
    if (!_showPolygonLabels) return const [];
    final entries = _polygonLabels.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (final entry in entries)
        PrintMapLabel(anchor: entry.value.anchor, text: entry.value.text),
    ];
  }

  /// Printed borders are black and thick so they read clearly on a
  /// black-and-white printer, whatever colours the screen uses.
  static const Color _printBorderColor = Colors.black;
  static const int _printBorderWidth = 5;

  List<ThumbnailPathData>? _staticMapPolygons() {
    final paths = <ThumbnailPathData>[];

    for (int i = 0; i < _job.workMaps.length; i++) {
      final workMap = _job.workMaps[i];
      final points = _pointsForWorkMap(i, workMap);
      if (!workMap.isPolygon || points.length < 3) continue;

      paths.add(
        ThumbnailPathData(
          points: points,
          color: _printBorderColor,
          fillOpacity: 0,
          strokeWidth: _printBorderWidth,
        ),
      );
    }

    for (final polygon in _currentLinkedMapPolygons()) {
      if (polygon.points.length < 3) continue;
      paths.add(
        ThumbnailPathData(
          points: polygon.points,
          color: _printBorderColor,
          fillOpacity: 0,
          strokeWidth: _printBorderWidth,
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

    for (final track in _currentCloudTracks()) {
      if (track.points.length < 2) continue;
      paths.add(
        ThumbnailPathData(
          points: track.points,
          color: Colors.blueAccent,
          fillOpacity: 0,
          strokeWidth: 3,
        ),
      );
    }

    return paths.isEmpty ? null : paths;
  }

  /// The printed map's pins, back to front — it paints them in this order,
  /// so the drop-off goes first and Junk & Stuff / Happy Sun pins last
  /// (the same stacking as the on-screen map).
  List<ThumbnailMarkerData>? _staticMapMarkers() {
    final points = <ThumbnailMarkerData>[];
    final callOuts = <ThumbnailMarkerData>[];

    for (final workMap in _job.workMaps) {
      if (!workMap.isPoint || workMap.points.isEmpty) continue;
      if (workMap.pointCategory == PointCategory.dropoff) continue;

      final style = _pinStyleFor(workMap);
      (_bookings.layerFor(workMap) == PinLayer.callOut ? callOuts : points)
          .add(
        ThumbnailMarkerData(
          position: workMap.points.first,
          color: style.color,
          pin: style,
        ),
      );
    }

    final markers = [
      if (_dropOffPoint != null)
        ThumbnailMarkerData(
          position: _dropOffPoint!,
          color: MapPinStyle.dropOff.color,
          pin: MapPinStyle.dropOff,
        ),
      ...points,
      ...callOuts,
    ];
    return markers.isEmpty ? null : markers;
  }

  String _printMapDocumentName() {
    final label = (_distributorName?.trim().isNotEmpty ?? false)
        ? _distributorName!.trim()
        : (_job.primaryClient.trim().isNotEmpty ? _job.primaryClient : 'Map');
    return 'Distribution Map $label ${DateFormat('yyyy-MM-dd').format(_job.date)}';
  }

  Job _freshJob() {
    return ProviderScope.containerOf(context, listen: false)
        .read(scheduleRiverpod)
        .jobs
        .firstWhere((j) => j.id == _job.id, orElse: () => _job);
  }

  Future<void> _saveJob(Job freshJob, Job updatedJob) async {
    final scheduleProvider = ProviderScope.containerOf(context, listen: false)
        .read(scheduleRiverpod);
    await scheduleProvider.updateJobWithUndo(
        freshJob, updatedJob, freshJob.date);
  }

  Future<void> _handleLinkMapTap() async {
    final scheduleProvider = ref.read(scheduleRiverpod);
    // One dialog for every case: no maps linked yet goes straight to the
    // picker, otherwise it lists what's linked with add/unlink per map.
    await showLinkedMapsDialog(context, scheduleProvider, _job);
  }

  Future<void> _persistDropOffPoint(LatLng point) async {
    final freshJob = _freshJob();
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
    await _saveJob(freshJob, updatedJob);
  }

  Future<void> _persistWorkAreaChanges() async {
    final freshJob = _freshJob();
    final updatedJob = freshJob.copyWith(
      workMaps: List<CustomPolygon>.from(_job.workMaps),
      workingAreas: _job.workMaps
          .where((w) => w.isPolygon)
          .map((w) => w.name)
          .where((name) => name.isNotEmpty)
          .toList(),
      dropOffPoint: _dropOffPoint,
    );
    await _saveJob(freshJob, updatedJob);
  }

  @override
  Widget build(BuildContext context) {
    final schedule = ref.watch(scheduleRiverpod);
    final liveJob = schedule.jobs.firstWhere(
          (j) => j.id == _job.id,
          orElse: () => _job,
        );
    _syncLiveJob(liveJob);

    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    final appBarHeight = AppBar().preferredSize.height;
    final mapWidth = screenWidth;
    final mapHeight = screenHeight - appBarHeight;
    const mapLeft = 0.0;
    const mapTop = 0.0;
    final currentMapSize = Size(mapWidth, mapHeight);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        titleSpacing: 4,
        // One tab per distributor working this date, so each map can be
        // printed without leaving this view.
        title: Row(
          children: [
            Expanded(child: _buildDistributorTabs(schedule)),
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
                ScaffoldMessenger.of(context).showToast(
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
                    ScaffoldMessenger.of(context).showToast(
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
              ScaffoldMessenger.of(context).showToast(
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

          // Rotate the map so a tall area fits a wide page (or vice versa)
          // at a higher zoom.
          PopupMenuButton<String>(
            icon: Icon(
              Icons.screen_rotation_alt,
              color: _mapQuarterTurns != 0 ? const Color(0xFF1967D2) : null,
            ),
            tooltip: 'Rotate map',
            onSelected: (value) {
              switch (value) {
                case 'fit':
                  _rotateToFit();
                case 'cw90':
                  _rotateMapBy(1);
                case 'ccw90':
                  _rotateMapBy(3);
                case 'north':
                  setState(() => _mapQuarterTurns = 0);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'fit',
                child: ListTile(
                  leading: Icon(Icons.fit_screen),
                  title: Text('Rotate to fit area'),
                  subtitle: Text('Turn and zoom for the most detail'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'cw90',
                child: ListTile(
                  leading: Icon(Icons.rotate_right),
                  title: Text('Rotate 90° clockwise'),
                ),
              ),
              PopupMenuItem(
                value: 'ccw90',
                child: ListTile(
                  leading: Icon(Icons.rotate_left),
                  title: Text('Rotate 90° anticlockwise'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'north',
                child: ListTile(
                  leading: Icon(Icons.north),
                  title: Text('Reset to north up'),
                ),
              ),
            ],
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

          // Client visibility (hide/show clients in the info box)
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: Icon(
                  _hiddenClientIndices.isEmpty
                      ? Icons.people_outline
                      : Icons.people,
                  color: _hiddenClientIndices.isEmpty
                      ? null
                      : const Color(0xFF1967D2),
                ),
                tooltip: _hiddenClientIndices.isEmpty
                    ? 'Show/hide clients in info box'
                    : '${_hiddenClientIndices.length} client(s) hidden',
                onPressed: _showClientVisibilityDialog,
              ),
              if (_hiddenClientIndices.isNotEmpty)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                    ),
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      '${_hiddenClientIndices.length}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          // Link an existing map (always available — provides the recorded
          // tracks overlay below once linked).
          IconButton(
            icon: Icon(
              _job.hasLinkedMaps ? Icons.link : Icons.link_off,
              color: _job.hasLinkedMaps ? const Color(0xFF1967D2) : null,
            ),
            tooltip: _job.hasLinkedMaps
                ? 'Maps linked — tap to add polygons, unlink or link another'
                : 'Link an existing map',
            onPressed: _handleLinkMapTap,
          ),

          // Linked-map overlay toggle (tracks + polygons) — only shown once
          // a map is linked and its data has loaded (or is loading).
          if (_job.hasLinkedMaps) ...[
            IconButton(
              icon: _isLoadingCloudMapData
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.route,
                      color: _showCloudTracks ? const Color(0xFF1967D2) : null,
                    ),
              tooltip: _showCloudTracks
                  ? 'Hide linked map data'
                  : 'Show linked map data',
              onPressed: _isLoadingCloudMapData
                  ? null
                  : () {
                      setState(() {
                        _showCloudTracks = !_showCloudTracks;
                        _updateMapView();
                      });
                    },
            ),
          ],

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
                    // Google Map, turned as a whole (see _mapQuarterTurns).
                    // RotatedBox swaps its child's width/height, so a
                    // sideways map still fills the frame exactly.
                    RotatedBox(
                      quarterTurns: _mapQuarterTurns,
                      child: GoogleMap(
                        // Turned, Google would pan along its own unturned
                        // axes, so it takes no input and the layer below
                        // pans/zooms instead.
                        webGestureHandling: _mapQuarterTurns != 0
                            ? WebGestureHandling.none
                            : ref.watch(mapGestureRiverpod).gestureHandling,
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
                          ..._vertexMarkers,
                          ..._customPointMarkers,
                          if (_dropOffMarker != null) _dropOffMarker!,
                        },
                        mapType: MapType.normal,
                        mapId: _mapId,
                        zoomControlsEnabled: false,
                        mapToolbarEnabled: false,
                        myLocationButtonEnabled: false,
                        scrollGesturesEnabled: !_isDraggingInfoBox &&
                            !_isResizingInfoBox &&
                            _draggingLabelIndex == null,
                        zoomGesturesEnabled: !_isDraggingInfoBox &&
                            !_isResizingInfoBox &&
                            _draggingLabelIndex == null,
                        rotateGesturesEnabled: false,
                        tiltGesturesEnabled: false,
                      ),
                    ),
                    // Pan/zoom for the turned map, with the pointer movement
                    // turned to match. Off while editing points so vertex
                    // drags don't also pan.
                    if (_mapQuarterTurns != 0 && !_isEditingVertices)
                      Positioned.fill(
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerSignal: (event) {
                            if (event is PointerScrollEvent) {
                              _zoomTurnedMap(event, currentMapSize);
                            }
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => _startTurnedPan(),
                            onPanUpdate: (details) =>
                                _updateTurnedPan(details.delta, currentMapSize),
                            onPanEnd: (_) => _endTurnedPan(currentMapSize),
                            onPanCancel: () => _turnedPanStart = null,
                          ),
                        ),
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
                    // Information Box (on screen only; the PDF prints its
                    // own header and footer with the same details)
                    Positioned(
                        left: _infoBoxPosition.dx,
                        top: _infoBoxPosition.dy,
                        child: MapOverlay(
                          child: GestureDetector(
                            onPanStart: (_) =>
                                setState(() => _isDraggingInfoBox = true),
                            onPanUpdate: (details) {
                              setState(() {
                                final newX =
                                    _infoBoxPosition.dx + details.delta.dx;
                                final newY =
                                    _infoBoxPosition.dy + details.delta.dy;
                                _infoBoxPosition = Offset(
                                  newX.clamp(0, mapWidth - _infoBoxSize.width),
                                  newY.clamp(0, mapHeight - 60),
                                );
                              });
                            },
                            onPanEnd: (_) =>
                                setState(() => _isDraggingInfoBox = false),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                _buildInfoBox(),
                                // Resize handle (width only — height is content-driven)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: GestureDetector(
                                    onPanStart: (_) => setState(
                                        () => _isResizingInfoBox = true),
                                    onPanUpdate: (details) {
                                      setState(() {
                                        final newWidth = _infoBoxSize.width +
                                            details.delta.dx;
                                        const minWidth = 150.0;
                                        final maxWidth = mapWidth * 0.45;
                                        _infoBoxSize = Size(
                                          newWidth.clamp(minWidth, maxWidth),
                                          _infoBoxSize.height,
                                        );
                                        final sizeRatio =
                                            _infoBoxSize.width / 250;
                                        _fontScale = sizeRatio.clamp(0.6, 2.0);
                                        _infoBoxPosition = Offset(
                                          _infoBoxPosition.dx.clamp(
                                              0, mapWidth - _infoBoxSize.width),
                                          _infoBoxPosition.dy,
                                        );
                                      });
                                    },
                                    onPanEnd: (_) => setState(
                                        () => _isResizingInfoBox = false),
                                    child: Container(
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: _isResizingInfoBox
                                            ? Colors.red.withValues(alpha: 0.8)
                                            : Colors.blue.withValues(
                                                alpha: _isDraggingInfoBox
                                                    ? 0.6
                                                    : 0.25),
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
                      ),
                    // Vertex editing toolbar
                    if (_isEditingVertices &&
                        _editingPolygonIndex != null)
                      Positioned(
                        bottom: 16,
                        left: 0,
                        right: 0,
                        child: MapOverlay(
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
                      ),
                    // Edit mode hint (when no polygon selected yet)
                    if (_isEditingVertices &&
                        _editingPolygonIndex == null)
                      Positioned(
                        bottom: 16,
                        left: 0,
                        right: 0,
                        child: MapOverlay(
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
                      ),
                  ],
                ),
              ),
            ),
          ),

          if (_isPrintingMap)
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
          child: MapOverlay(
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

  /// Clients that should appear in the distributor info box, paired with their
  /// original index in `_job.clients`. Excludes blank names and any client the
  /// user has hidden via the visibility dialog.
  List<MapEntry<int, String>> _visibleClientEntries() {
    return _job.clients
        .asMap()
        .entries
        .where((e) =>
            e.value.trim().isNotEmpty && !_hiddenClientIndices.contains(e.key))
        .toList();
  }

  /// Dialog listing every client with a checkbox. Unticking hides the client
  /// from the info box (and printout); re-ticking brings it back.
  Future<void> _showClientVisibilityDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void toggle(int index, bool visible) {
              setState(() {
                if (visible) {
                  _hiddenClientIndices.remove(index);
                } else {
                  _hiddenClientIndices.add(index);
                }
              });
              setDialogState(() {});
            }

            final entries = _job.clients
                .asMap()
                .entries
                .where((e) => e.value.trim().isNotEmpty)
                .toList();

            return AlertDialog(
              title: const Text('Clients in info box'),
              content: SizedBox(
                width: 360,
                child: entries.isEmpty
                    ? const Text('This job has no clients.')
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Untick a client to hide it from the map info '
                              'box. Re-tick to bring it back.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Flexible(
                            child: ListView(
                              shrinkWrap: true,
                              children: entries.map((entry) {
                                final visible =
                                    !_hiddenClientIndices.contains(entry.key);
                                return CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: visible,
                                  title: Text(
                                    entry.value.trim(),
                                    style: TextStyle(
                                      decoration: visible
                                          ? null
                                          : TextDecoration.lineThrough,
                                      color: visible ? null : Colors.grey,
                                    ),
                                  ),
                                  onChanged: (v) =>
                                      toggle(entry.key, v ?? true),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
              ),
              actions: [
                if (_hiddenClientIndices.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      setState(() => _hiddenClientIndices.clear());
                      setDialogState(() {});
                    },
                    child: const Text('Show all'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildInfoBox() {
    final dateFormatter = DateFormat('dd MMM yyyy');

    return Container(
      width: _infoBoxSize.width,
      padding: EdgeInsets.all(8 * _fontScale),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Name (Distributor)
          _buildInfoRow('Name:', _distributorName ?? '.'),

          // Map (Working Areas) - the first 3 names, "..." past that.
          //   Exclude point-type entries (dropoff, pickup) from the label.
          Builder(builder: (context) {
            final names = [
              for (final (i, wm)
                  in _job.workMaps.where((wm) => !wm.isPoint).indexed)
                wm.name.trim().isEmpty ? 'Area ${i + 1}' : wm.name.trim(),
            ];
            return _buildInfoRow(
                'Map:',
                names.isEmpty
                    ? '.'
                    : names.length > 3
                        ? '${names.take(3).join(', ')}, ...'
                        : names.join(', '));
          }),

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
          ..._visibleClientEntries().asMap().entries.map((display) {
            final displayNumber = display.key + 1;
            final i = display.value.key;
            final client = display.value.value;
            final instruction = i < _job.clientInstructions.length
                ? _job.clientInstructions[i].trim()
                : '';
            return Padding(
              padding:
                  EdgeInsets.only(left: 8 * _fontScale, bottom: 2 * _fontScale),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$displayNumber. ',
                    style: TextStyle(
                      fontSize: 10 * _fontScale,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: client,
                            style: TextStyle(
                              fontSize: 10 * _fontScale,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (instruction.isNotEmpty)
                            TextSpan(
                              text: '  — $instruction',
                              style: TextStyle(
                                fontSize: 8.5 * _fontScale,
                                fontStyle: FontStyle.italic,
                                fontWeight: FontWeight.normal,
                                color: Colors.black87,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),

          if (_visibleClientEntries().isEmpty)
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

          // Map instructions (if set)
          if (_job.mapInstructions.trim().isNotEmpty) ...[
            SizedBox(height: 5 * _fontScale),
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                  horizontal: 6 * _fontScale, vertical: 5 * _fontScale),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Instructions:',
                    style: TextStyle(
                      fontSize: 10 * _fontScale,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 3 * _fontScale),
                  Text(
                    _job.mapInstructions.trim(),
                    style: TextStyle(
                      fontSize: 9.5 * _fontScale,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
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
