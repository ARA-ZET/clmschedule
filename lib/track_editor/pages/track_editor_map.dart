// track_editor/pages/track_editor_map.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../providers/te_tabs_provider.dart';
import '../providers/te_map_layer_provider.dart';
import '../providers/te_mode_provider.dart';
import '../providers/te_tools_provider.dart';
import '../utils/te_track_stats.dart';

class TEMap extends riverpod.ConsumerStatefulWidget {
  const TEMap({super.key});

  @override
  riverpod.ConsumerState<TEMap> createState() => _TEMapState();
}

class _TEMapState extends riverpod.ConsumerState<TEMap> {
  final Completer<GoogleMapController> _controller =
      Completer<GoogleMapController>();

  BitmapDescriptor? _waypointIcon;
  BitmapDescriptor? _selectedWptIcon;
  BitmapDescriptor? _vertexIcon;

  // ── Track info overlay state ──────────────────────────────────────────────
  LatLng? _infoAnchor;
  String? _infoName;
  TETrackStats? _infoStats;

  // ── Waypoint info overlay state ───────────────────────────────────────────
  LatLng? _wptAnchor;
  String? _wptName;
  String? _wptCoords;
  int? _wptIndex; // index in tabData.waypoints for the tapped waypoint

  // ── Polygon info overlay state ────────────────────────────────────────────
  LatLng? _polyAnchor;
  String? _polyName;
  Color? _polyColor;
  int? _polyIndex; // index in tabData.polygons for the tapped polygon

  // ── Vertex editing state ──────────────────────────────────────────────────
  int? _editingPolyIndex; // index of the polygon being edited in the active tab
  List<LatLng>? _editingPoints; // mutable working copy of its vertices
  Color? _editingPolyColor;
  String? _editingPolyName;

  // ── Selected track state ──────────────────────────────────────────────────
  int? _selectedTrackIndex;

  // ── Scissors cursor state ──────────────────────────────────────────────────
  Offset? _mousePosition;

  // ── Shift + drag rectangle selection state ──────────────────────────────────
  bool _isShiftHeld = false;
  Offset? _selectStart;
  Offset? _selectEnd;
  BitmapDescriptor? _multiSelectWptIcon;

  // Live camera position – updated on every onCameraMove for smooth reprojection.
  CameraPosition _currentCamera = _defaultPosition;

  // Track last-seen tab index AND mode so we fit bounds when either changes.
  int _lastTab = -1;
  TEMode? _lastMode;

  @override
  void initState() {
    super.initState();
    _loadWaypointIcon();
    _loadSelectedWptIcon();
    _loadVertexIcon();
    _loadMultiSelectWptIcon();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    final shiftNow = HardwareKeyboard.instance.isShiftPressed;
    if (shiftNow != _isShiftHeld) {
      setState(() => _isShiftHeld = shiftNow);
    }
    return false; // don't consume the event
  }

  Future<void> _loadWaypointIcon() async {
    final ByteData data = await rootBundle.load('assets/letterbox.png');
    final ui.Codec codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: 16,
    );
    final ui.FrameInfo fi = await codec.getNextFrame();
    final byteData = await fi.image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null && mounted) {
      setState(() {
        _waypointIcon = BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      });
    }
  }

  Future<void> _loadSelectedWptIcon() async {
    const double size = 24.0;
    const double radius = 10.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);
    canvas.drawCircle(center, radius + 2, Paint()..color = Colors.white);
    canvas.drawCircle(center, radius, Paint()..color = Colors.orange);
    // Inner dot
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (mounted && data != null) {
      setState(() {
        _selectedWptIcon = BitmapDescriptor.bytes(data.buffer.asUint8List());
      });
    }
  }

  Future<void> _loadMultiSelectWptIcon() async {
    const double size = 24.0;
    const double radius = 10.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);
    canvas.drawCircle(center, radius + 2, Paint()..color = Colors.white);
    canvas.drawCircle(center, radius, Paint()..color = Colors.red);
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (mounted && data != null) {
      setState(() {
        _multiSelectWptIcon = BitmapDescriptor.bytes(data.buffer.asUint8List());
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  /// Clear all overlay and editing state so stale info doesn't bleed across tabs.
  void _clearOverlayState() {
    _infoAnchor = null;
    _infoName = null;
    _infoStats = null;
    _wptAnchor = null;
    _wptName = null;
    _wptCoords = null;
    _polyAnchor = null;
    _polyName = null;
    _polyColor = null;
    _polyIndex = null;
    _editingPolyIndex = null;
    _editingPoints = null;
    _editingPolyColor = null;
    _editingPolyName = null;
    _selectStart = null;
    _selectEnd = null;
  }

  Future<void> _fitTabBounds(TETabsProvider tabsProvider) async {
    final tabData = tabsProvider.tabs[tabsProvider.currentTab];
    final points = <LatLng>[];

    for (final trk in tabData.tracks) {
      for (final seg in trk.trksegs) {
        for (final pt in seg.trkpts) {
          if (pt.lat != null && pt.lon != null) {
            points.add(LatLng(pt.lat!, pt.lon!));
          }
        }
      }
    }
    for (final wpt in tabData.waypoints) {
      if (wpt.lat != null && wpt.lon != null) {
        points.add(LatLng(wpt.lat!, wpt.lon!));
      }
    }

    if (points.isEmpty) return;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    final ctrl = await _controller.future;
    if (mounted) {
      ctrl.animateCamera(CameraUpdate.newLatLngBounds(bounds, 48));
    }
  }

  void _openInfoWindow(
      LatLng anchor, String name, TETrackStats stats, int trackIndex) {
    setState(() {
      _infoAnchor = anchor;
      _infoName = name;
      _infoStats = stats;
      _selectedTrackIndex = trackIndex;
      // close other overlays
      _wptAnchor = null;
      _wptName = null;
      _wptCoords = null;
      _polyAnchor = null;
      _polyName = null;
      _polyColor = null;
      _polyIndex = null;
    });
  }

  void _closeInfoWindow() {
    setState(() {
      _infoAnchor = null;
      _infoName = null;
      _infoStats = null;
      _selectedTrackIndex = null;
    });
  }

  void _openWptInfoWindow(
      LatLng anchor, String name, String coords, int wptIdx) {
    setState(() {
      _wptAnchor = anchor;
      _wptName = name;
      _wptCoords = coords;
      _wptIndex = wptIdx;
      // close other overlays
      _infoAnchor = null;
      _infoName = null;
      _infoStats = null;
      _polyAnchor = null;
      _polyName = null;
      _polyColor = null;
      _polyIndex = null;
    });
  }

  void _closeWptInfoWindow() {
    setState(() {
      _wptAnchor = null;
      _wptName = null;
      _wptCoords = null;
      _wptIndex = null;
    });
  }

  void _openPolyInfoWindow(
      LatLng anchor, String name, Color color, int polyIdx) {
    setState(() {
      _polyAnchor = anchor;
      _polyName = name;
      _polyColor = color;
      _polyIndex = polyIdx;
      // close other overlays
      _infoAnchor = null;
      _infoName = null;
      _infoStats = null;
      _wptAnchor = null;
      _wptName = null;
      _wptCoords = null;
    });
  }

  void _closePolyInfoWindow() {
    setState(() {
      _polyAnchor = null;
      _polyName = null;
      _polyColor = null;
      _polyIndex = null;
    });
  }

  // ── Vertex editing ─────────────────────────────────────────────────────────

  Future<void> _loadVertexIcon() async {
    const double size = 20.0;
    const double radius = 7.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);
    // White outline for contrast against dark map tiles
    canvas.drawCircle(center, radius + 1.5, Paint()..color = Colors.white);
    // Solid deep-purple fill
    canvas.drawCircle(center, radius, Paint()..color = Colors.deepPurple);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (mounted && data != null) {
      setState(() {
        _vertexIcon = BitmapDescriptor.bytes(data.buffer.asUint8List());
      });
    }
  }

  void _startEditPolygon(
      int polyIndex, List<LatLng> points, Color color, String name) {
    setState(() {
      _editingPolyIndex = polyIndex;
      _editingPoints = List<LatLng>.from(points);
      _editingPolyColor = color;
      _editingPolyName = name;
      // close info overlay
      _polyAnchor = null;
      _polyName = null;
      _polyColor = null;
      _polyIndex = null;
    });
  }

  void _cancelEditPolygon() {
    setState(() {
      _editingPolyIndex = null;
      _editingPoints = null;
      _editingPolyColor = null;
      _editingPolyName = null;
    });
  }

  void _saveEditPolygon(TETabsProvider tabsProvider, int tabIndex) {
    if (_editingPolyIndex == null || _editingPoints == null) return;
    tabsProvider.updatePolygonPoints(
        tabIndex, _editingPolyIndex!, List<LatLng>.from(_editingPoints!));
    setState(() {
      _editingPolyIndex = null;
      _editingPoints = null;
      _editingPolyColor = null;
      _editingPolyName = null;
    });
  }

  Future<bool> _confirmDelete(
      BuildContext context, String type, String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $type?', style: const TextStyle(fontSize: 15)),
        content: Text('Are you sure you want to delete "$name"?',
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _moveVertex(int vertexIndex, LatLng newPos) {
    if (_editingPoints == null) return;
    setState(() => _editingPoints![vertexIndex] = newPos);
  }

  void _deletePolygon(
      TETabsProvider tabsProvider, int tabIndex, int polyIndex) {
    _closePolyInfoWindow();
    tabsProvider.removePolygon(tabIndex, polyIndex);
  }

  // ── Scissors mode ─────────────────────────────────────────────────────────

  /// Handle a map tap in scissors mode: find the nearest track point and split.
  void _handleScissorsTap(LatLng tapPos, int currentTab) {
    final tabsProvider = ref.read(teTabsRiverpod);
    final tracks = tabsProvider.tabs[currentTab].tracks;
    if (tracks.isEmpty) return;

    int? bestTrackIdx;
    int? bestGlobalIdx;
    double bestDist = double.infinity;

    for (int ti = 0; ti < tracks.length; ti++) {
      final trk = tracks[ti];
      int globalIdx = 0;
      for (final seg in trk.trksegs) {
        for (final pt in seg.trkpts) {
          if (pt.lat == null || pt.lon == null) {
            globalIdx++;
            continue;
          }
          final d = _haversineDistance(
              tapPos.latitude, tapPos.longitude, pt.lat!, pt.lon!);
          if (d < bestDist) {
            bestDist = d;
            bestTrackIdx = ti;
            bestGlobalIdx = globalIdx;
          }
          globalIdx++;
        }
      }
    }

    if (bestTrackIdx == null || bestGlobalIdx == null) return;

    // Only split if within ~200m of the track — prevents accidental splits.
    if (bestDist > 0.2) return;

    final success =
        tabsProvider.splitTrack(currentTab, bestTrackIdx, bestGlobalIdx);
    if (success) {
      // Exit scissors mode and select the first of the two resulting tracks.
      ref.read(teToolsRiverpod).disableScissors();
      setState(() {
        _mousePosition = null;
        _selectedTrackIndex = bestTrackIdx;
      });
    }
  }

  /// Haversine distance in km between two lat/lon points.
  static double _haversineDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0; // Earth radius in km
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  Future<void> _openRenameDialog(
      BuildContext context,
      TETabsProvider tabsProvider,
      int tabIndex,
      int polyIndex,
      String currentName) async {
    final ctrl = TextEditingController(text: currentName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename area', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Area name',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result != null && result.isNotEmpty) {
      tabsProvider.renamePolygon(tabIndex, polyIndex, result);
      // Keep overlay open but update name
      setState(() => _polyName = result);
    }
  }

  /// Converts a [LatLng] to screen [Offset] using Mercator math synchronously.
  /// Works for maps with no bearing/tilt (standard view).
  static Offset _latLngToScreen(
      LatLng point, CameraPosition camera, Size screen) {
    double worldX(double lng) => (lng + 180) / 360 * 256;
    double worldY(double lat) {
      final s = math.sin(lat * math.pi / 180);
      return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * 256;
    }

    final scale = math.pow(2, camera.zoom).toDouble();
    final cx = worldX(camera.target.longitude) * scale;
    final cy = worldY(camera.target.latitude) * scale;
    final px = worldX(point.longitude) * scale;
    final py = worldY(point.latitude) * scale;

    // Account for device pixel ratio – getScreenCoordinate returns logical px
    return Offset(
      screen.width / 2 + (px - cx),
      screen.height / 2 + (py - cy),
    );
  }

  static const CameraPosition _defaultPosition = CameraPosition(
    target: LatLng(-33.915265, 18.514862),
    zoom: 14.4746,
  );

  /// Finish rectangle selection: find waypoints inside the rect.
  void _completeRectangleSelection(Size mapSize, int currentTab) {
    if (_selectStart == null || _selectEnd == null) return;

    final rect = Rect.fromPoints(_selectStart!, _selectEnd!);
    final tabData = ref.read(teTabsRiverpod).tabs[currentTab];
    final selectedIndices = <int>{};

    // Check which visible waypoints fall inside the selection rectangle
    final showWaypoints =
        ref.read(teMapLayerRiverpod).waypointsVisible(currentTab);
    if (showWaypoints) {
      final filter = ref
          .read(teMapLayerRiverpod)
          .waypointFilter(currentTab)
          .toLowerCase()
          .trim();
      for (int i = 0; i < tabData.waypoints.length; i++) {
        final wpt = tabData.waypoints[i];
        if (wpt.lat == null || wpt.lon == null) continue;
        if (filter.isNotEmpty) {
          final name = (wpt.name ?? '').toLowerCase();
          if (!name.contains(filter)) continue;
        }
        final screen = _latLngToScreen(
            LatLng(wpt.lat!, wpt.lon!), _currentCamera, mapSize);
        if (rect.contains(screen)) {
          selectedIndices.add(i);
        }
      }
    }

    ref
        .read(teMapLayerRiverpod)
        .setMultiSelectedWaypoints(currentTab, selectedIndices);

    setState(() {
      _selectStart = null;
      _selectEnd = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentTab = ref.watch(teTabsRiverpod).currentTab;
    final tabData = ref.watch(teTabsRiverpod).tabs[currentTab];
    final scissorsMode = ref.watch(teToolsRiverpod).scissorsMode;

    // Detect tab or mode switch and fit map bounds to the new tab's content.
    final activeMode = ref.watch(teTabsRiverpod).activeMode;
    if (currentTab != _lastTab || activeMode != _lastMode) {
      _lastTab = currentTab;
      _lastMode = activeMode;
      _clearOverlayState();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fitTabBounds(ref.read(teTabsRiverpod));
      });
    }
    final showWaypoints =
        ref.watch(teMapLayerRiverpod).waypointsVisible(currentTab);
    final showPolygons =
        ref.watch(teMapLayerRiverpod).polygonsVisible(currentTab);
    final selectedWptIdx =
        ref.watch(teMapLayerRiverpod).selectedWaypoint(currentTab);
    final multiSelectedWpts =
        ref.watch(teMapLayerRiverpod).multiSelectedWaypoints(currentTab);
    final waypointFilter = ref
        .watch(teMapLayerRiverpod)
        .waypointFilter(currentTab)
        .toLowerCase()
        .trim();

    final Set<Polygon> mapPolygons = !showPolygons
        ? <Polygon>{}
        : tabData.polygons.asMap().entries.map((e) {
            final idx = e.key;
            final sp = e.value;
            final bool isEditing = _editingPolyIndex == idx;
            final List<LatLng> points = isEditing ? _editingPoints! : sp.points;
            // Compute centroid as anchor for the info window
            final LatLng centroid = sp.points.isEmpty
                ? const LatLng(0, 0)
                : LatLng(
                    sp.points.map((p) => p.latitude).reduce((a, b) => a + b) /
                        sp.points.length,
                    sp.points.map((p) => p.longitude).reduce((a, b) => a + b) /
                        sp.points.length,
                  );
            final Color overlayColor =
                sp.style.fill ? sp.style.fillColor : sp.style.strokeColor;
            return Polygon(
              polygonId: PolygonId('poly_${currentTab}_$idx'),
              points: points,
              strokeColor: isEditing ? Colors.deepPurple : sp.style.strokeColor,
              strokeWidth: isEditing ? 3 : sp.style.strokeWidth.toInt(),
              fillColor: isEditing
                  ? Colors.deepPurple.withAlpha(40)
                  : (sp.style.fill
                      ? sp.style.fillColor.withAlpha(100)
                      : Colors.transparent),
              consumeTapEvents: true,
              onTap: isEditing
                  ? null
                  : () => _openPolyInfoWindow(
                        centroid,
                        sp.name,
                        overlayColor,
                        idx,
                      ),
            );
          }).toSet();

    // Draggable vertex markers for polygon being edited
    final Set<Marker> vertexMarkers =
        (_editingPolyIndex != null && _editingPoints != null)
            ? _editingPoints!.asMap().entries.map((e) {
                final vtxIdx = e.key;
                final pt = e.value;
                return Marker(
                  markerId: MarkerId('vtx_${currentTab}_$vtxIdx'),
                  position: pt,
                  draggable: true,
                  anchor: const Offset(0.5, 0.5),
                  icon: _vertexIcon ??
                      BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueViolet),
                  infoWindow: InfoWindow.noText,
                  zIndex: 10,
                  onDragEnd: (newPos) => _moveVertex(vtxIdx, newPos),
                );
              }).toSet()
            : <Marker>{};

    final Set<Marker> mapMarkers = tabData.waypoints.asMap().entries.where((e) {
      if (!showWaypoints) return false;
      if (waypointFilter.isEmpty) return true;
      final name = (e.value.name ?? '').toLowerCase();
      return name.contains(waypointFilter);
    }).map((e) {
      final idx = e.key;
      final wpt = e.value;
      final coords =
          'Lat: ${wpt.lat?.toStringAsFixed(5)},  Lon: ${wpt.lon?.toStringAsFixed(5)}';
      final isSelected = idx == selectedWptIdx;
      final isMultiSelected = multiSelectedWpts.contains(idx);
      return Marker(
        markerId: MarkerId('wpt_${currentTab}_$idx'),
        position: LatLng(wpt.lat!, wpt.lon!),
        anchor: const Offset(0.5, 0.5),
        zIndex: isMultiSelected ? 6 : (isSelected ? 5 : 1),
        icon: isMultiSelected
            ? (_multiSelectWptIcon ??
                BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed))
            : isSelected
                ? (_selectedWptIcon ??
                    BitmapDescriptor.defaultMarkerWithHue(
                        BitmapDescriptor.hueOrange))
                : (_waypointIcon ?? BitmapDescriptor.defaultMarker),
        infoWindow: InfoWindow.noText,
        onTap: () {
          ref.read(teMapLayerRiverpod).selectWaypoint(currentTab, idx);
          _openWptInfoWindow(
            LatLng(wpt.lat!, wpt.lon!),
            wpt.name ?? 'Waypoint ${idx + 1}',
            coords,
            idx,
          );
        },
      );
    }).toSet();

    final Set<Polyline> polylines = tabData.tracks.asMap().entries.map((e) {
      final idx = e.key;
      final track = e.value;
      final stats = TETrackStats.fromTrack(track);
      final rawName = track.name?.trim() ?? '';
      final trackName = rawName.isNotEmpty ? rawName : 'Track ${idx + 1}';
      final allPts = track.trksegs
          .expand((seg) => seg.trkpts)
          .where((p) => p.lat != null && p.lon != null)
          .toList();
      final midPt = allPts.isNotEmpty ? allPts[allPts.length ~/ 2] : null;
      final isSelected = _selectedTrackIndex == idx;
      return Polyline(
        polylineId: PolylineId('track_${currentTab}_$idx'),
        points: allPts.map((p) => LatLng(p.lat!, p.lon!)).toList(),
        color: scissorsMode
            ? Colors.orange
            : isSelected
                ? Colors.red
                : Colors.blue,
        width: isSelected ? 7 : 5,
        consumeTapEvents: !scissorsMode,
        onTap: scissorsMode
            ? null
            : () {
                if (midPt != null) {
                  _openInfoWindow(
                      LatLng(midPt.lat!, midPt.lon!), trackName, stats, idx);
                }
              },
      );
    }).toSet();

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final mapSize = Size(constraints.maxWidth, constraints.maxHeight);
          final infoScreen = _infoAnchor != null
              ? _latLngToScreen(_infoAnchor!, _currentCamera, mapSize)
              : null;

          return Stack(
            children: [
              MouseRegion(
                  cursor: scissorsMode
                      ? SystemMouseCursors.none
                      : MouseCursor.defer,
                  onHover: scissorsMode
                      ? (event) =>
                          setState(() => _mousePosition = event.localPosition)
                      : null,
                  onExit: scissorsMode
                      ? (_) => setState(() => _mousePosition = null)
                      : null,
                  child: GoogleMap(
                    initialCameraPosition: _defaultPosition,
                    scrollGesturesEnabled:
                        !_isShiftHeld && _selectStart == null,
                    zoomGesturesEnabled: !_isShiftHeld && _selectStart == null,
                    rotateGesturesEnabled:
                        !_isShiftHeld && _selectStart == null,
                    tiltGesturesEnabled: !_isShiftHeld && _selectStart == null,
                    onMapCreated: (controller) {
                      if (!_controller.isCompleted) {
                        _controller.complete(controller);
                        // Fit bounds now that the controller is ready.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _fitTabBounds(ref.read(teTabsRiverpod));
                        });
                      }
                    },
                    onTap: (latLng) {
                      if (scissorsMode) {
                        _handleScissorsTap(latLng, currentTab);
                      } else {
                        _closeInfoWindow();
                        _closeWptInfoWindow();
                        _closePolyInfoWindow();
                      }
                    },
                    onCameraMove: (pos) => setState(() => _currentCamera = pos),
                    polygons: mapPolygons,
                    markers: {...mapMarkers, ...vertexMarkers},
                    polylines: polylines,
                    cloudMapId: '29325755824913c4',
                  )),
              // ── Shift+drag selection interceptor ─────────────────────────
              if (_isShiftHeld || _selectStart != null)
                Positioned.fill(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.precise,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) {
                        setState(() {
                          _selectStart = e.localPosition;
                          _selectEnd = e.localPosition;
                          // Close any open overlays
                          _closeInfoWindow();
                          _closeWptInfoWindow();
                          _closePolyInfoWindow();
                        });
                        // Clear previous multi-selection
                        ref
                            .read(teMapLayerRiverpod)
                            .clearMultiSelection(currentTab);
                      },
                      onPointerMove: (e) {
                        if (_selectStart != null) {
                          setState(() => _selectEnd = e.localPosition);
                        }
                      },
                      onPointerUp: (e) {
                        _completeRectangleSelection(mapSize, currentTab);
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              // ── Selection rectangle drawing ──────────────────────────────
              if (_selectStart != null && _selectEnd != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter:
                          _SelectionRectPainter(_selectStart!, _selectEnd!),
                    ),
                  ),
                ),
              // ── Shift selection hint banner ──────────────────────────────
              if (_isShiftHeld && _selectStart == null)
                Positioned(
                  top: 12,
                  left: 0,
                  right: 60,
                  child: Center(
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(20),
                      color: Colors.blue.shade700,
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'Drag to select waypoints',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ),
                ),
              // ── Multi-select waypoint info overlay ───────────────────────
              if (multiSelectedWpts.isNotEmpty)
                Positioned(
                  top: 12,
                  right: 12,
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.select_all,
                                  size: 16, color: Colors.red.shade600),
                              const SizedBox(width: 8),
                              Text(
                                '${multiSelectedWpts.length} waypoint${multiSelectedWpts.length == 1 ? '' : 's'} selected',
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 12),
                              GestureDetector(
                                onTap: () => ref
                                    .read(teMapLayerRiverpod)
                                    .clearMultiSelection(currentTab),
                                child: Icon(Icons.close,
                                    size: 16, color: Colors.grey.shade500),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 32,
                                child: TextButton.icon(
                                  onPressed: () => ref
                                      .read(teMapLayerRiverpod)
                                      .clearMultiSelection(currentTab),
                                  icon: const Icon(Icons.deselect, size: 14),
                                  label: const Text('Clear',
                                      style: TextStyle(fontSize: 12)),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.blueGrey,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                height: 32,
                                child: FilledButton.icon(
                                  onPressed: () async {
                                    final count = multiSelectedWpts.length;
                                    final confirm = await _confirmDelete(
                                        context,
                                        'waypoints',
                                        '$count waypoint${count == 1 ? '' : 's'}');
                                    if (!confirm) return;
                                    ref.read(teTabsRiverpod).removeWaypoints(
                                        currentTab, multiSelectedWpts);
                                    ref
                                        .read(teMapLayerRiverpod)
                                        .clearMultiSelection(currentTab);
                                    ref
                                        .read(teMapLayerRiverpod)
                                        .selectWaypoint(currentTab, null);
                                  },
                                  icon: const Icon(Icons.delete_outline,
                                      size: 14),
                                  label: Text(
                                      'Delete ${multiSelectedWpts.length}',
                                      style: const TextStyle(fontSize: 12)),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              // ── Scissors floating cursor icon ────────────────────────────
              if (scissorsMode && _mousePosition != null)
                Positioned(
                  left: _mousePosition!.dx + 6,
                  top: _mousePosition!.dy + 6,
                  child: const IgnorePointer(
                    child: Icon(
                      Icons.content_cut,
                      size: 26,
                      color: Colors.orange,
                      shadows: [
                        Shadow(
                          color: Colors.black54,
                          blurRadius: 4,
                          offset: Offset(1, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              // ── Scissors mode hint banner ───────────────────────────────
              if (scissorsMode)
                Positioned(
                  top: 12,
                  left: 0,
                  right: 60,
                  child: Center(
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(20),
                      color: Colors.orange.shade700,
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'Tap on or near a track to split it',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ),
                ),
              // ── Floating track info overlay ────────────────────────────────
              if (infoScreen != null && _infoStats != null)
                _TrackInfoOverlay(
                  screen: infoScreen,
                  name: _infoName ?? '',
                  stats: _infoStats!,
                  onClose: _closeInfoWindow,
                  onDelete: _selectedTrackIndex != null
                      ? () async {
                          final confirm = await _confirmDelete(
                              context, 'track', _infoName ?? 'this track');
                          if (!confirm) return;
                          final ti = _selectedTrackIndex!;
                          _closeInfoWindow();
                          ref.read(teTabsRiverpod).removeTrack(currentTab, ti);
                        }
                      : null,
                ),
              // ── Floating waypoint info overlay ────────────────────────────
              if (_wptAnchor != null && _wptName != null)
                _WaypointInfoOverlay(
                  screen: _latLngToScreen(_wptAnchor!, _currentCamera, mapSize),
                  name: _wptName!,
                  coords: _wptCoords ?? '',
                  onClose: _closeWptInfoWindow,
                  onDelete: _wptIndex != null
                      ? () async {
                          final confirm = await _confirmDelete(
                              context, 'waypoint', _wptName ?? 'this waypoint');
                          if (!confirm) return;
                          final wi = _wptIndex!;
                          _closeWptInfoWindow();
                          ref
                              .read(teTabsRiverpod)
                              .removeWaypoint(currentTab, wi);
                          ref
                              .read(teMapLayerRiverpod)
                              .selectWaypoint(currentTab, null);
                        }
                      : null,
                ),
              // ── Floating polygon info overlay ─────────────────────────────
              if (_polyAnchor != null && _polyName != null)
                _PolygonInfoOverlay(
                  screen:
                      _latLngToScreen(_polyAnchor!, _currentCamera, mapSize),
                  name: _polyName!,
                  color: _polyColor ?? Colors.deepPurple,
                  onClose: _closePolyInfoWindow,
                  onEditName: _polyIndex != null
                      ? () => _openRenameDialog(
                            context,
                            ref.read(teTabsRiverpod),
                            currentTab,
                            _polyIndex!,
                            _polyName!,
                          )
                      : null,
                  onEditPoints: _polyIndex != null
                      ? () => _startEditPolygon(
                            _polyIndex!,
                            tabData.polygons[_polyIndex!].points,
                            _polyColor ?? Colors.deepPurple,
                            _polyName!,
                          )
                      : null,
                  onDelete: _polyIndex != null
                      ? () => _deletePolygon(
                            ref.read(teTabsRiverpod),
                            currentTab,
                            _polyIndex!,
                          )
                      : null,
                ),
              // ── Vertex edit toolbar ────────────────────────────────────────────
              if (_editingPolyIndex != null)
                Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Material(
                      elevation: 8,
                      borderRadius: BorderRadius.circular(28),
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _editingPolyColor ?? Colors.deepPurple,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 140),
                              child: Text(
                                _editingPolyName ?? 'Polygon',
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w500),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 12),
                            TextButton.icon(
                              onPressed: _cancelEditPolygon,
                              icon: const Icon(Icons.close, size: 16),
                              label: const Text('Cancel'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.grey.shade700,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                              ),
                            ),
                            const SizedBox(width: 4),
                            FilledButton.icon(
                              onPressed: () => _saveEditPolygon(
                                ref.read(teTabsRiverpod),
                                currentTab,
                              ),
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Save'),
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.deepPurple,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ── Floating info overlay – mimics native InfoWindow ─────────────────────────
class _TrackInfoOverlay extends StatelessWidget {
  final Offset screen;
  final String name;
  final TETrackStats stats;
  final VoidCallback onClose;
  final VoidCallback? onDelete;

  const _TrackInfoOverlay({
    required this.screen,
    required this.name,
    required this.stats,
    required this.onClose,
    this.onDelete,
  });

  static const double _cardWidth = 240;
  static const double _tailH = 10.0;
  static const double _estimatedHeight = 148;

  @override
  Widget build(BuildContext context) {
    final double left = screen.dx - _cardWidth / 2;
    final double top = screen.dy - _estimatedHeight - _tailH;

    return Positioned(
      left: left,
      top: top,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(10),
            color: Colors.white,
            child: SizedBox(
              width: _cardWidth,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.route,
                            size: 14, color: Colors.blueGrey),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: onClose,
                          child: Icon(Icons.close,
                              size: 14, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                    const Divider(height: 10),
                    _InfoRow(Icons.straighten, stats.distanceLabel),
                    _InfoRow(Icons.timer_outlined, stats.durationLabel),
                    _InfoRow(Icons.speed, stats.speedLabel),
                    _InfoRow(Icons.play_circle_outline, stats.startTimeLabel),
                    _InfoRow(Icons.stop_circle_outlined, stats.endTimeLabel),
                    if (onDelete != null) ...[
                      const Divider(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 28,
                        child: TextButton.icon(
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline, size: 14),
                          label: const Text('Delete track',
                              style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red.shade600,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          CustomPaint(
            size: const Size(16, _tailH),
            painter: _TailPainter(),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String value;
  const _InfoRow(this.icon, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        spacing: 6,
        children: [
          Icon(icon, size: 11, color: Colors.blueGrey.shade400),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _TailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawShadow(path, Colors.black26, 2, false);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TailPainter old) => false;
}

// ── Polygon info overlay ──────────────────────────────────────────────────────
class _PolygonInfoOverlay extends StatelessWidget {
  final Offset screen;
  final String name;
  final Color color;
  final VoidCallback onClose;
  final VoidCallback? onEditName;
  final VoidCallback? onEditPoints;
  final VoidCallback? onDelete;

  const _PolygonInfoOverlay({
    required this.screen,
    required this.name,
    required this.color,
    required this.onClose,
    this.onEditName,
    this.onEditPoints,
    this.onDelete,
  });

  static const double _cardWidth = 200;
  static const double _tailH = 10.0;
  static const double _estimatedHeight = 116;

  @override
  Widget build(BuildContext context) {
    final double left = screen.dx - _cardWidth / 2;
    final double top = screen.dy - _estimatedHeight - _tailH;

    return Positioned(
      left: left,
      top: top,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(10),
            color: Colors.white,
            child: SizedBox(
              width: _cardWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Name row ──────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 9, 8, 6),
                    child: Row(
                      spacing: 6,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: color.withAlpha(180),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: color.withAlpha(220), width: 1.5),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: onClose,
                          child: Icon(Icons.close,
                              size: 14, color: Colors.grey.shade400),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // ── Actions ───────────────────────────────────────────
                  _ActionRow(
                    icon: Icons.drive_file_rename_outline,
                    label: 'Edit name',
                    color: Colors.blueGrey.shade700,
                    onTap: onEditName,
                  ),
                  const Divider(height: 1, indent: 36),
                  _ActionRow(
                    icon: Icons.polyline_outlined,
                    label: 'Edit points',
                    color: Colors.deepPurple,
                    onTap: onEditPoints,
                  ),
                  const Divider(height: 1, indent: 36),
                  _ActionRow(
                    icon: Icons.delete_outline,
                    label: 'Delete',
                    color: Colors.red.shade600,
                    onTap: onDelete,
                  ),
                  const SizedBox(height: 2),
                ],
              ),
            ),
          ),
          CustomPaint(
            size: const Size(16, _tailH),
            painter: _TailPainter(),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          spacing: 10,
          children: [
            Icon(icon,
                size: 16, color: onTap != null ? color : Colors.grey.shade300),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: onTap != null ? color : Colors.grey.shade300,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Waypoint info overlay ─────────────────────────────────────────────────────
class _WaypointInfoOverlay extends StatelessWidget {
  final Offset screen;
  final String name;
  final String coords;
  final VoidCallback onClose;
  final VoidCallback? onDelete;

  const _WaypointInfoOverlay({
    required this.screen,
    required this.name,
    required this.coords,
    required this.onClose,
    this.onDelete,
  });

  static const double _cardWidth = 220;
  static const double _tailH = 10.0;
  static const double _estimatedHeight = 72;

  @override
  Widget build(BuildContext context) {
    final double left = screen.dx - _cardWidth / 2;
    final double top = screen.dy - _estimatedHeight - _tailH;

    return Positioned(
      left: left,
      top: top,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(10),
            color: Colors.white,
            child: SizedBox(
              width: _cardWidth,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.place, size: 14, color: Colors.teal),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: onClose,
                          child: Icon(Icons.close,
                              size: 14, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      coords,
                      style: TextStyle(
                          fontSize: 11, color: Colors.blueGrey.shade500),
                    ),
                    if (onDelete != null) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        height: 28,
                        child: TextButton.icon(
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline, size: 14),
                          label: const Text('Delete'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red.shade700,
                            backgroundColor: Colors.red.shade50,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(fontSize: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          CustomPaint(
            size: const Size(16, _tailH),
            painter: _TailPainter(),
          ),
        ],
      ),
    );
  }
}

// ── Selection rectangle painter ───────────────────────────────────────────────
class _SelectionRectPainter extends CustomPainter {
  final Offset start;
  final Offset end;
  _SelectionRectPainter(this.start, this.end);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(start, end);

    // Semi-transparent blue fill
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blue.withAlpha(30)
        ..style = PaintingStyle.fill,
    );

    // Dashed blue border
    final borderPaint = Paint()
      ..color = Colors.blue.shade600
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    const double dashLen = 8.0;
    const double gapLen = 4.0;
    final path = Path()..addRect(rect);
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final nextDash = math.min(distance + dashLen, metric.length);
        canvas.drawPath(
          metric.extractPath(distance, nextDash),
          borderPaint,
        );
        distance = nextDash + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_SelectionRectPainter old) =>
      old.start != start || old.end != end;
}
