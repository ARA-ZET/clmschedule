import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'dart:math' as math;
import 'dart:ui' as ui;
import '../../config/flavor_config.dart';
import '../../models/custom_polygon.dart';
import '../../models/work_area.dart';
import '../../providers/schedule_provider.dart';
import '../providers/shareable_map_provider.dart';
import '../providers/map_gesture_provider.dart';
import '../services/map_link_service.dart';
import '../adapters/firestore_adapter.dart';
import '../adapters/work_area_adapter.dart';
import '../utils/point_marker_icons.dart';
import '../utils/marker_clusterer.dart';
import 'map_layers_sidebar.dart';
import 'map_drawing_toolbar.dart';
import 'map_import_dialog.dart';
import 'work_area_picker_panel.dart';
import 'work_area_table_panel.dart';

/// Main map editor widget for the universal map editor.
/// Displays Google Maps with drawing tools and layer management.
/// UI elements are conditionally shown based on the active adapter's
/// [MapEditorCapabilities].
class ShareableMapEditor extends riverpod.ConsumerWidget {
  const ShareableMapEditor({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(shareableMapRiverpod);
    return Scaffold(
      appBar: const MapEditorAppBar(),
      body: Builder(
        builder: (context) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (provider.currentMap == null) {
            return const MapEditorEmptyState();
          }
          final caps = provider.capabilities;
          final isWorkAreaEditor =
              provider.adapter is WorkAreaCollectionAdapter;
          return Stack(
            children: [
              const MapViewWidget(),
              if (caps.canManageLayers) const MapSidebarWidget(),
              if (isWorkAreaEditor) const _WorkAreaTableSidebar(),
              if (caps.canDraw && !caps.readOnly)
                const MapDrawingToolbarWidget(),
              if (!caps.readOnly) const MapDrawingControlsWidget(),
              // Cloud tracks loading indicator
              if (provider.isLoadingCloudTracks)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 8),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('Loading cloud tracks…',
                              style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
              // Work area picker panel (positioned top-right under app bar)
              if (provider.isWorkAreaPickerVisible)
                Positioned(
                  top: 8,
                  right: 8,
                  child: WorkAreaPickerPanel(
                    onClose: () => provider.hideWorkAreaPicker(),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ============================================================================
// Extracted Widget Components
// ============================================================================

/// App bar for the map editor — capability-driven, with polygon search
class MapEditorAppBar extends riverpod.ConsumerStatefulWidget
    implements PreferredSizeWidget {
  const MapEditorAppBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  riverpod.ConsumerState<MapEditorAppBar> createState() =>
      _MapEditorAppBarState();
}

class _MapEditorAppBarState extends riverpod.ConsumerState<MapEditorAppBar> {
  // Reference to the Autocomplete's internal controller so we can clear it
  TextEditingController? _autocompleteController;
  FocusNode? _autocompleteFocusNode;

  void _onSearchResultSelected(
    ShareableMapProvider provider,
    CustomPolygon polygon,
    String layerId,
    int index,
  ) {
    // Focus camera on the polygon
    provider.focusOnPolygon(layerId, index);

    // Build the polygon ID to match the format used by the map
    final polygonId = '${layerId}_polygon_$index';

    // Open info window at centroid
    LatLng centroid = const LatLng(0, 0);
    if (polygon.points.isNotEmpty) {
      double lat = 0, lng = 0;
      for (final p in polygon.points) {
        lat += p.latitude;
        lng += p.longitude;
      }
      centroid =
          LatLng(lat / polygon.points.length, lng / polygon.points.length);
    }

    final areaKm2 = _polygonAreaKm2(polygon.points);
    final perimeterKm = _pathLengthKm(polygon.points, closed: true);
    final subtitle = '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}';

    provider.openInfoWindow(InfoWindowData(
      elementId: polygonId,
      layerId: layerId,
      title: polygon.name.isNotEmpty ? polygon.name : 'Unnamed Polygon',
      description: polygon.description,
      subtitle: subtitle,
      type: 'polygon',
      anchor: centroid,
      letterBoxEstimate: polygon.letterBoxEstimate,
    ));
  }

  // ── Measurement helpers (same as _MapViewWidgetState) ────────────────
  static double _haversineKm(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sinDLat = math.sin(dLat / 2);
    final sinDLng = math.sin(dLng / 2);
    final aVal = sinDLat * sinDLat +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sinDLng *
            sinDLng;
    return R * 2 * math.atan2(math.sqrt(aVal), math.sqrt(1 - aVal));
  }

  static double _pathLengthKm(List<LatLng> points, {bool closed = false}) {
    if (points.length < 2) return 0;
    double total = 0;
    for (int i = 0; i < points.length - 1; i++) {
      total += _haversineKm(points[i], points[i + 1]);
    }
    if (closed && points.length > 2) {
      total += _haversineKm(points.last, points.first);
    }
    return total;
  }

  static double _polygonAreaKm2(List<LatLng> points) {
    if (points.length < 3) return 0;
    double area = 0;
    for (int i = 0; i < points.length; i++) {
      final j = (i + 1) % points.length;
      area += points[i].longitude * points[j].latitude;
      area -= points[j].longitude * points[i].latitude;
    }
    area = area.abs() / 2;
    final lat =
        points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
    final latRad = lat * math.pi / 180;
    const metersPerDegLat = 111320.0;
    final metersPerDegLng = metersPerDegLat * math.cos(latRad);
    return area * metersPerDegLat * metersPerDegLng / 1e6;
  }

  static String _fmtKm(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(2)} km';
  }

  static String _fmtKm2(double km2) {
    if (km2 < 0.01) return '${(km2 * 1e6).round()} m²';
    return '${km2.toStringAsFixed(2)} km²';
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    final caps = provider.capabilities;
    final allPolygons = provider.getSearchablePolygons();

    final isMapsStandalone = FlavorConfig.instance.isMaps;

    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      leading: isMapsStandalone
          ? null
          : IconButton(
              icon: const Icon(Icons.arrow_back, color: Color(0xFF5F6368)),
              onPressed: () async {
                // Unfocus any active text field so pending edits
                // (e.g. estimate changes) are committed before saving.
                FocusManager.instance.primaryFocus?.unfocus();
                await Future.delayed(Duration.zero);

                // Auto-save on exit with thumbnail capture
                if (provider.hasUnsavedChanges && provider.hasAdapter) {
                  await provider.saveToAdapter(captureThumbnail: true);
                }
                if (context.mounted) Navigator.pop(context);
              },
            ),
      automaticallyImplyLeading: !isMapsStandalone,
      titleSpacing: isMapsStandalone ? 16 : 0,
      title: Row(
        children: [
          // Search field
          Flexible(
            child: Autocomplete<
                ({CustomPolygon polygon, String layerId, int index})>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text.isEmpty) return allPolygons;
                final query = textEditingValue.text.toLowerCase();
                return allPolygons.where((entry) {
                  final name = entry.polygon.name.toLowerCase();
                  final desc = entry.polygon.description.toLowerCase();
                  return name.contains(query) || desc.contains(query);
                });
              },
              displayStringForOption: (option) => option.polygon.name.isNotEmpty
                  ? option.polygon.name
                  : 'Unnamed Polygon',
              fieldViewBuilder: (context, textEditingController, focusNode,
                  onFieldSubmitted) {
                _autocompleteController = textEditingController;
                _autocompleteFocusNode = focusNode;
                return TextField(
                  controller: textEditingController,
                  focusNode: focusNode,
                  style:
                      const TextStyle(color: Color(0xFF202124), fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search work areas...',
                    hintStyle:
                        const TextStyle(color: Color(0xFF9AA0A6), fontSize: 14),
                    prefixIcon: const Icon(Icons.search,
                        size: 20, color: Color(0xFF9AA0A6)),
                    suffixIcon: textEditingController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close,
                                size: 18, color: Color(0xFF5F6368)),
                            onPressed: () {
                              textEditingController.clear();
                              // Trigger rebuild so suffix icon hides
                              // ignore: invalid_use_of_protected_member
                              (context as Element).markNeedsBuild();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: const Color(0xFFF1F3F4),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: const BorderSide(
                          color: Color(0xFF1967D2), width: 1.5),
                    ),
                  ),
                  onChanged: (_) {
                    // Force rebuild for suffix icon visibility
                    // ignore: invalid_use_of_protected_member
                    (context as Element).markNeedsBuild();
                  },
                  onSubmitted: (_) => onFieldSubmitted(),
                );
              },
              optionsViewBuilder: (context, onSelected, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 300,
                        maxWidth: 400,
                      ),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (context, i) {
                          final entry = options.elementAt(i);
                          final poly = entry.polygon;
                          final name = poly.name.isNotEmpty
                              ? poly.name
                              : 'Unnamed Polygon';
                          final areaKm2 = _polygonAreaKm2(poly.points);

                          return ListTile(
                            dense: true,
                            leading: Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: poly.color
                                    .withValues(alpha: poly.fillOpacity),
                                border: Border.all(
                                  color: poly.color,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              _fmtKm2(areaKm2),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF5F6368),
                              ),
                            ),
                            onTap: () => onSelected(entry),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
              onSelected: (entry) {
                _onSearchResultSelected(
                  provider,
                  entry.polygon,
                  entry.layerId,
                  entry.index,
                );
                // Clear the search field and dismiss keyboard
                _autocompleteController?.clear();
                _autocompleteFocusNode?.unfocus();
              },
            ),
          ),
          // Context title from adapter (distributor · date · clients)
          if (provider.adapter != null &&
              provider.adapter!.displayName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                provider.adapter!.displayName,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF5F6368),
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
        ],
      ),
      actions: [
        const SizedBox(width: 4),
        // Map tools
        IconButton(
          icon: const Icon(Icons.undo, size: 22, color: Color(0xFF5F6368)),
          tooltip: 'Undo',
          onPressed: () {
            // TODO: Implement undo
          },
        ),
        IconButton(
          icon: const Icon(Icons.redo, size: 22, color: Color(0xFF5F6368)),
          tooltip: 'Redo',
          onPressed: () {
            // TODO: Implement redo
          },
        ),
        const SizedBox(width: 8),
        // Work areas import toggle (admin only — hidden in Maps flavor)
        if (!isMapsStandalone)
          IconButton(
            icon: Icon(
              Icons.workspaces_outlined,
              size: 22,
              color: provider.isWorkAreaPickerVisible
                  ? const Color(0xFF1967D2)
                  : const Color(0xFF5F6368),
            ),
            tooltip: 'Import work areas',
            onPressed: () {
              provider.toggleWorkAreaPicker();
            },
          ),
        // Import button (admin only — hidden in Maps flavor)
        if (!isMapsStandalone && caps.canImport)
          IconButton(
            icon: const Icon(Icons.upload_file,
                size: 22, color: Color(0xFF5F6368)),
            tooltip: 'Import KML/GPX',
            onPressed: () => MapEditorDialogs.showImportDialog(context),
          ),
        // Layers toggle — only if layer management is enabled
        if (caps.canManageLayers)
          IconButton(
            icon: const Icon(Icons.layers_outlined,
                size: 22, color: Color(0xFF5F6368)),
            tooltip: 'Toggle layers',
            onPressed: () {
              provider.toggleSidebar();
            },
          ),

        // Share button — only for Firestore-backed maps
        if (provider.adapter is FirestoreMapAdapter)
          IconButton(
            icon: const Icon(Icons.share, size: 22, color: Color(0xFF5F6368)),
            tooltip: 'Copy share link',
            onPressed: () => _copyShareLink(context, provider),
          ),
        const SizedBox(width: 8),
      ],
    );
  }

  Future<void> _copyShareLink(
      BuildContext context, ShareableMapProvider provider) async {
    try {
      final adapter = provider.adapter;
      if (adapter is! FirestoreMapAdapter) return;

      final docId = adapter.docId;
      final monthKey = adapter.monthKey;
      if (docId == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Save the map first before sharing')),
          );
        }
        return;
      }

      final linkService = MapLinkService();
      final code = await linkService.createShareLink(
        monthKey: monthKey,
        mapId: docId,
        mapName: provider.currentMap?.name ?? '',
      );
      final url = MapLinkService.buildShareUrl(code);

      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('Link copied: $url')),
              ],
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create share link: $e')),
        );
      }
    }
  }
}

/// Empty state when no map is loaded
class MapEditorEmptyState extends StatelessWidget {
  const MapEditorEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.map_outlined, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No map loaded',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Create a new map or import from KML/GPX',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => MapEditorDialogs.showCreateMapDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('Create New Map'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => MapEditorDialogs.showImportDialog(context),
            icon: const Icon(Icons.upload_file),
            label: const Text('Import KML/GPX'),
          ),
        ],
      ),
    );
  }
}

/// Google Maps view with drawing capabilities
class MapViewWidget extends riverpod.ConsumerStatefulWidget {
  const MapViewWidget({super.key});

  @override
  riverpod.ConsumerState<MapViewWidget> createState() => _MapViewWidgetState();
}

class _MapViewWidgetState extends riverpod.ConsumerState<MapViewWidget> {
  // Custom marker icons for vertex editing
  BitmapDescriptor? _vertexMarkerIcon;
  BitmapDescriptor? _midpointMarkerIcon;
  BitmapDescriptor? _firstVertexMarkerIcon;

  // Cached point category bitmap descriptors
  Map<PointCategory, BitmapDescriptor>? _pointIcons;

  // Letterbox icon for cloud waypoints
  BitmapDescriptor? _waypointIcon;

  // Pre-rendered cluster icons (letterbox + count badge) keyed by bucketed count
  Map<int, BitmapDescriptor> _clusterIconCache = {};

  // Live camera position – updated on every onCameraMove so the info window
  // overlay can be reprojected synchronously on each frame.
  CameraPosition? _currentCamera;
  // Last pointer-down position in local widget coordinates.
  // Used to anchor the info window at the tapped location for polygon/polyline.
  Offset? _lastPointerDown;
  // Cached map widget size – set inside LayoutBuilder each build.
  Size _mapSize = Size.zero;
  // Timestamp of the last info-window action button press. Used to guard
  // against GoogleMap.onTap firing concurrently on web (platform view
  // limitation where the underlying HTML element also receives the click).
  DateTime? _lastInfoWindowAction;

  // ── Hover tooltip state ────────────────────────────────────────────────
  /// Current mouse position in local coordinates (null when outside map).
  Offset? _hoverPosition;

  /// Data to display in the hover tooltip (null when not hovering a polygon).
  _HoverTooltipData? _hoverTooltipData;

  @override
  void initState() {
    super.initState();
    _createMarkerIcons();
  }

  // ── Marker icon creation ───────────────────────────────────────────────

  Future<void> _createMarkerIcons() async {
    try {
      _vertexMarkerIcon = await _createCircleMarkerIcon(
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
      _midpointMarkerIcon = await _createMidpointMarkerIcon();
    } catch (_) {
      _midpointMarkerIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    }

    try {
      _firstVertexMarkerIcon = await _createCircleMarkerIcon(
        size: 20.0,
        fillColor: Colors.green,
        borderColor: Colors.white,
        borderWidth: 2.0,
      );
    } catch (_) {
      _firstVertexMarkerIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
    }

    // Preload point category icons
    try {
      await PointMarkerIcons.preload();
      _pointIcons = PointMarkerIcons.allCached;
    } catch (_) {
      _pointIcons = null;
    }

    // Load letterbox icon for cloud waypoints
    try {
      final data = await rootBundle.load('assets/letterbox.png');
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: 16,
      );
      final fi = await codec.getNextFrame();
      final byteData =
          await fi.image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        _waypointIcon = BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      }
    } catch (_) {
      _waypointIcon = null;
    }

    // Pre-render cluster icons (letterbox + count badge) for common buckets
    try {
      await MarkerClusterer.loadBaseImage();
      _clusterIconCache = await MarkerClusterer.warmUpClusterIcons();
    } catch (_) {}

    if (mounted) setState(() {});
  }

  Future<BitmapDescriptor> _createCircleMarkerIcon({
    required double size,
    required Color fillColor,
    required Color borderColor,
    required double borderWidth,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final double radius = size / 2;

    final paint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(radius, radius), radius - borderWidth, paint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;
    canvas.drawCircle(
        Offset(radius, radius), radius - borderWidth, borderPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (pngBytes == null) {
      throw Exception('toByteData returned null for vertex icon');
    }
    return BitmapDescriptor.bytes(pngBytes.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _createMidpointMarkerIcon() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const double size = 12.0;
    const double radius = size / 2;

    final paint = Paint()
      ..color = Colors.orange
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(radius, radius), radius - 1.0, paint);

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(const Offset(radius, radius), radius - 1.0, borderPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (pngBytes == null) {
      throw Exception('toByteData returned null for midpoint icon');
    }
    return BitmapDescriptor.bytes(pngBytes.buffer.asUint8List());
  }

  // ── Midpoint / editing marker helpers ──────────────────────────────────

  List<LatLng> _calculateMidpoints(List<LatLng> points,
      {bool isPolygon = false}) {
    if (points.length < 2) return [];
    final int edgeCount = isPolygon ? points.length : points.length - 1;
    final List<LatLng> midpoints = [];
    for (int i = 0; i < edgeCount; i++) {
      final current = points[i];
      final next = points[(i + 1) % points.length];
      midpoints.add(LatLng(
        (current.latitude + next.latitude) / 2,
        (current.longitude + next.longitude) / 2,
      ));
    }
    return midpoints;
  }

  void _showDeleteVertexDialog(
      BuildContext context, ShareableMapProvider provider, int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Vertex'),
        content: Text(
            'Remove vertex ${index + 1} of ${provider.editingPoints!.length}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              provider.removeEditingPoint(index);
              if (mounted) setState(() {});
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Set<Marker> _buildEditingMarkers(
      BuildContext context, ShareableMapProvider provider) {
    if (!provider.isEditingVertices || provider.editingPoints == null) {
      return {};
    }

    final editingPoints = provider.editingPoints!;
    final markers = <Marker>{};

    final vertexIcon = _vertexMarkerIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    final midpointIcon = _midpointMarkerIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

    final minPoints = provider.isEditingPolygon ? 3 : 2;

    for (int i = 0; i < editingPoints.length; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('vertex_$i'),
          icon: vertexIcon,
          position: editingPoints[i],
          draggable: true,
          consumeTapEvents: true,
          onTap: () {
            if (editingPoints.length <= minPoints) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Minimum $minPoints vertices required'),
                  duration: const Duration(seconds: 2),
                ),
              );
              return;
            }
            _showDeleteVertexDialog(context, provider, i);
          },
          onDrag: (newPosition) => provider.updateEditingPoint(i, newPosition),
          onDragEnd: (newPosition) =>
              provider.updateEditingPoint(i, newPosition),
        ),
      );
    }

    if (editingPoints.length >= 2) {
      final isPolygon = provider.isEditingPolygon;
      final midpoints =
          _calculateMidpoints(editingPoints, isPolygon: isPolygon);
      for (int i = 0; i < midpoints.length; i++) {
        markers.add(
          Marker(
            markerId: MarkerId('midpoint_$i'),
            icon: midpointIcon,
            position: midpoints[i],
            draggable: true,
            anchor: const Offset(0.5, 0.5),
            onDragEnd: (newPosition) {
              provider.insertEditingPoint(i + 1, newPosition);
              if (mounted) setState(() {});
            },
          ),
        );
      }
    }

    return markers;
  }

  // ── Drawing markers (circle bitmaps, first-marker-tap to close) ────────

  Set<Marker> _buildDrawingMarkers(
      BuildContext context, ShareableMapProvider provider) {
    if (!provider.isDrawing || provider.drawingPoints.isEmpty) {
      return {};
    }

    final points = provider.drawingPoints;
    final canClose =
        provider.drawingMode == DrawingMode.polygon && points.length >= 3;

    final normalIcon = _vertexMarkerIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    final firstIcon = canClose
        ? (_firstVertexMarkerIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen))
        : normalIcon;

    return points.asMap().entries.map((entry) {
      final index = entry.key;
      final point = entry.value;
      final isFirst = index == 0;

      return Marker(
        markerId: MarkerId('drawing_point_$index'),
        position: point,
        icon: isFirst ? firstIcon : normalIcon,
        anchor: const Offset(0.5, 0.5),
        zIndex: isFirst ? 1001 : 1000,
        draggable: false,
        consumeTapEvents: isFirst && canClose,
        onTap: isFirst && canClose
            ? () {
                // User tapped the first marker — complete the polygon
                provider.setDialogOpen(true);
                MapEditorDialogs.showElementNameDialog(context, provider)
                    .then((_) => provider.setDialogOpen(false));
              }
            : null,
      );
    }).toSet();
  }

  // ── Info window helpers ────────────────────────────────────────────────

  void _dismissInfoWindow() {
    final provider = ref.read(shareableMapRiverpod);
    if (provider.infoWindowData != null) {
      ref.read(mapGestureRiverpod).enableMapGestures();
      provider.dismissInfoWindow();
    }
  }

  /// Centroid of a list of LatLng points.
  static LatLng _centroid(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(0, 0);
    double lat = 0, lng = 0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  /// Converts a [LatLng] to a screen [Offset] using synchronous Mercator math.
  /// Mirrors the same helper in track_editor_map.dart.
  static Offset _latLngToScreen(
      LatLng point, CameraPosition camera, Size size) {
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

    return Offset(
      size.width / 2 + (px - cx),
      size.height / 2 + (py - cy),
    );
  }

  /// Inverse of [_latLngToScreen]: converts a screen pixel offset back to LatLng.
  static LatLng _screenToLatLng(
      Offset screen, CameraPosition camera, Size size) {
    double worldX(double lng) => (lng + 180) / 360 * 256;
    double worldY(double lat) {
      final s = math.sin(lat * math.pi / 180);
      return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * 256;
    }

    final scale = math.pow(2, camera.zoom).toDouble();
    final cx = worldX(camera.target.longitude) * scale;
    final cy = worldY(camera.target.latitude) * scale;
    // World-pixel coordinates of the tapped screen point
    final px = cx + screen.dx - size.width / 2;
    final py = cy + screen.dy - size.height / 2;
    // Inverse Mercator
    final lng = px / (256 * scale) * 360 - 180;
    final n = 0.5 - py / (256 * scale);
    final expVal = math.exp(4 * math.pi * n);
    final sinLat = (expVal - 1) / (expVal + 1);
    final lat = math.asin(sinLat.clamp(-1.0, 1.0)) * 180 / math.pi;
    return LatLng(lat, lng);
  }

  /// Estimate the visible map region from the current camera + widget size.
  /// Uses 20% padding so markers near edges don't pop in/out abruptly.
  LatLngBounds? _estimateVisibleBounds() {
    final cam = _currentCamera;
    if (cam == null || _mapSize == Size.zero) return null;
    const padding = 1.2;
    final sw = _screenToLatLng(
      Offset(-_mapSize.width * (padding - 1), _mapSize.height * padding),
      cam,
      _mapSize,
    );
    final ne = _screenToLatLng(
      Offset(_mapSize.width * padding, -_mapSize.height * (padding - 1)),
      cam,
      _mapSize,
    );
    return LatLngBounds(southwest: sw, northeast: ne);
  }

  /// Returns the LatLng of the last pointer-down, falling back to [fallback].
  LatLng _tapAnchor(LatLng fallback) {
    if (_lastPointerDown == null ||
        _currentCamera == null ||
        _mapSize == Size.zero) {
      return fallback;
    }
    return _screenToLatLng(_lastPointerDown!, _currentCamera!, _mapSize);
  }

  /// Haversine distance between two points in km
  static double _haversineKm(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sinDLat = math.sin(dLat / 2);
    final sinDLng = math.sin(dLng / 2);
    final aVal = sinDLat * sinDLat +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sinDLng *
            sinDLng;
    return R * 2 * math.atan2(math.sqrt(aVal), math.sqrt(1 - aVal));
  }

  /// Total path length in km
  static double _pathLengthKm(List<LatLng> points, {bool closed = false}) {
    if (points.length < 2) return 0;
    double total = 0;
    for (int i = 0; i < points.length - 1; i++) {
      total += _haversineKm(points[i], points[i + 1]);
    }
    if (closed && points.length > 2) {
      total += _haversineKm(points.last, points.first);
    }
    return total;
  }

  /// Approximate polygon area in km² using shoelace + unit conversion
  static double _polygonAreaKm2(List<LatLng> points) {
    if (points.length < 3) return 0;
    double area = 0;
    for (int i = 0; i < points.length; i++) {
      final j = (i + 1) % points.length;
      area += points[i].longitude * points[j].latitude;
      area -= points[j].longitude * points[i].latitude;
    }
    area = area.abs() / 2;
    // Convert degrees² to km² using approximate scale at centroid latitude
    final lat =
        points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
    final latRad = lat * math.pi / 180;
    const metersPerDegLat = 111320.0;
    final metersPerDegLng = metersPerDegLat * math.cos(latRad);
    return area * metersPerDegLat * metersPerDegLng / 1e6;
  }

  /// Format km value: < 1 → "XXX m", ≥ 1 → "X.XX km"
  static String _fmtKm(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(2)} km';
  }

  /// Format km² value
  static String _fmtKm2(double km2) {
    if (km2 < 0.01) return '${(km2 * 1e6).round()} m²';
    return '${km2.toStringAsFixed(2)} km²';
  }

  // ── Hover tooltip helpers ──────────────────────────────────────────────

  /// Ray-casting point-in-polygon test.
  static bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    bool inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].latitude, yi = polygon[i].longitude;
      final xj = polygon[j].latitude, yj = polygon[j].longitude;
      if (((yi > point.longitude) != (yj > point.longitude)) &&
          (point.latitude <
              (xj - xi) * (point.longitude - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// Handle mouse hover: convert screen position to LatLng, then hit-test
  /// against all visible polygon boundaries.
  void _onHover(Offset localPosition, ShareableMapProvider provider) {
    if (_currentCamera == null || _mapSize == Size.zero) return;
    // Don't show hover tooltip when an info window is already open or drawing
    if (provider.infoWindowData != null ||
        provider.isDrawing ||
        provider.isEditingVertices) {
      if (_hoverTooltipData != null) {
        setState(() {
          _hoverTooltipData = null;
          _hoverPosition = null;
        });
      }
      return;
    }

    final hoverLatLng =
        _screenToLatLng(localPosition, _currentCamera!, _mapSize);

    // Walk visible layers / polygons and test hit
    for (final layer in provider.layers) {
      if (!layer.isVisible) continue;
      for (int i = 0; i < layer.polygons.length; i++) {
        final polygon = layer.polygons[i];
        if (polygon.points.length < 3) continue;
        if (_pointInPolygon(hoverLatLng, polygon.points)) {
          final areaKm2 = _polygonAreaKm2(polygon.points);
          final perimeterKm = _pathLengthKm(polygon.points, closed: true);
          final data = _HoverTooltipData(
            name: polygon.name.isNotEmpty ? polygon.name : 'Unnamed Polygon',
            description: polygon.description,
            stats: '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
            color: polygon.color,
          );
          if (_hoverTooltipData?.name != data.name ||
              _hoverPosition != localPosition) {
            setState(() {
              _hoverTooltipData = data;
              _hoverPosition = localPosition;
            });
          }
          return;
        }
      }
    }

    // Not hovering over any polygon
    if (_hoverTooltipData != null) {
      setState(() {
        _hoverTooltipData = null;
        _hoverPosition = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    final map = provider.currentMap!;
    final iw = provider.infoWindowData;

    // All visible layers (persisted + cloud overlays) sorted by draw order
    final visibleLayers = provider.layers
        .where((layer) => layer.isVisible)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    // All layers sorted by draw order (including hidden ones for stable
    // marker IDs — hidden layers use markerVisible: false so Google Maps
    // hides them natively instead of removing from DOM).
    final allLayersSorted = provider.layers.toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    // Combine completed polygons with drawing preview (or editing preview)
    final polygons = <Polygon>{
      ...visibleLayers.expand((layer) => layer.getGoogleMapsPolygons(
            selectedElementId: provider.selectedElementId,
            editingElementId: provider.editingElementId,
            onTap: provider.isEditingVertices
                ? null
                : (polygonId) =>
                    _handlePolygonTap(context, provider, polygonId),
          )),
      if (provider.isEditingVertices && provider.getEditingPolygon() != null)
        provider.getEditingPolygon()!,
    };

    // When work area picker is visible, overlay ghost polygons for all
    // unimported work areas so the user can tap them on the map to add.
    if (provider.isWorkAreaPickerVisible) {
      final workAreas = ref.watch(scheduleRiverpod).workAreas;
      for (final wa in workAreas) {
        if (provider.isWorkAreaImported(wa.name)) continue;
        if (wa.polygonPoints.length < 3) continue;
        polygons.add(Polygon(
          polygonId: PolygonId('preview_wa_${wa.name}'),
          points: wa.polygonPoints,
          strokeColor: Colors.blue.withValues(alpha: 0.7),
          strokeWidth: 2,
          fillColor: Colors.blue.withValues(alpha: 0.10),
          consumeTapEvents: true,
          onTap: () => _handlePreviewWorkAreaTap(context, provider, wa),
        ));
      }
    }

    // Combine completed polylines with drawing preview (or editing preview)
    final polylines = <Polyline>{
      ...visibleLayers.expand((layer) => layer.getGoogleMapsPolylines(
            selectedElementId: provider.selectedElementId,
            editingElementId: provider.editingElementId,
            onTap: provider.isEditingVertices
                ? null
                : (polylineId) =>
                    _handlePolylineTap(context, provider, polylineId),
          )),
      if (provider.isEditingVertices && provider.getEditingPolyline() != null)
        provider.getEditingPolyline()!,
      if (provider.getDrawingPolyline() != null) provider.getDrawingPolyline()!,
    };

    // Combine completed markers with drawing/editing markers
    final isDraggable = !provider.capabilities.readOnly &&
        !provider.isDrawing &&
        !provider.isEditingVertices;
    // Build a special pointIcons map for the cloud waypoints layer
    // so that its generic markers use the letterbox bitmap.
    Map<PointCategory, BitmapDescriptor>? waypointPointIcons;
    if (_waypointIcon != null) {
      waypointPointIcons = {
        if (_pointIcons != null) ..._pointIcons!,
        PointCategory.generic: _waypointIcon!,
      };
    }

    // Viewport bounds and zoom for clustering large layers.
    final viewBounds = _estimateVisibleBounds();
    final currentZoom = _currentCamera?.zoom ?? map.defaultZoom;

    final markers = <Marker>{
      if (!provider.isEditingVertices) ...[
        // Small layers: render all markers directly
        ...visibleLayers
            .where((layer) => layer.points.length <= 200)
            .expand((layer) {
          final isWaypointLayer =
              layer.name == ShareableMapProvider.waypointsLayerName;
          return layer.getGoogleMapsMarkers(
            selectedElementId: provider.selectedElementId,
            onTap: (pointId) => _handleMarkerTap(context, provider, pointId),
            draggable: isDraggable,
            onDragEnd: isDraggable
                ? (pointId, newPos) => provider.moveMarker(pointId, newPos)
                : null,
            pointIcons: isWaypointLayer
                ? (waypointPointIcons ?? _pointIcons)
                : _pointIcons,
          );
        }),
        // Large layers: always include (visible or not) with markerVisible
        // flag so Google Maps hides/shows natively without add/remove churn.
        ...allLayersSorted
            .where((layer) => layer.points.length > 200)
            .expand((layer) {
          return MarkerClusterer.clusterSync(
            points: layer.points,
            zoom: currentZoom,
            visibleBounds: viewBounds,
            selectedElementId: provider.selectedElementId,
            onTap: (pointId) => _handleMarkerTap(context, provider, pointId),
            draggable: isDraggable && layer.isVisible,
            onDragEnd: isDraggable && layer.isVisible
                ? (pointId, newPos) => provider.moveMarker(pointId, newPos)
                : null,
            customIcon: _waypointIcon,
            clusterIcons: _clusterIconCache,
            markerVisible: layer.isVisible,
          );
        }),
      ],
      ..._buildDrawingMarkers(context, provider),
      ..._buildEditingMarkers(context, provider),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final mapSize = Size(constraints.maxWidth, constraints.maxHeight);
        _mapSize = mapSize;
        // Reproject anchor LatLng → screen pixel on every frame so the
        // overlay tracks the geographic point during pan and zoom.
        final infoScreen = iw != null && _currentCamera != null
            ? _latLngToScreen(iw.anchor, _currentCamera!, mapSize)
            : null;

        return MouseRegion(
          onHover: (event) => _onHover(event.localPosition, provider),
          onExit: (_) {
            if (_hoverTooltipData != null) {
              setState(() {
                _hoverTooltipData = null;
                _hoverPosition = null;
              });
            }
          },
          child: Listener(
            onPointerDown: (e) => _lastPointerDown = e.localPosition,
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: map.defaultCenter,
                    zoom: map.defaultZoom,
                  ),
                  onMapCreated: (controller) {
                    provider.setMapController(controller);
                  },
                  onCameraMove: (pos) => setState(() => _currentCamera = pos),
                  webGestureHandling:
                      ref.watch(mapGestureRiverpod).gestureHandling,
                  onTap: (position) {
                    // Guard: ignore map tap when user is interacting with
                    // a UI overlay (gestures disabled by MouseRegion/Listener).
                    if (ref.read(mapGestureRiverpod).gestureHandling ==
                        WebGestureHandling.none) {
                      return;
                    }
                    // Guard: on web, both the Flutter overlay InkWell and
                    // the underlying GoogleMap HTML element can receive the
                    // same click. Ignore the map tap if an info-window
                    // action button was pressed within the last 300 ms.
                    if (_lastInfoWindowAction != null &&
                        DateTime.now()
                                .difference(_lastInfoWindowAction!)
                                .inMilliseconds <
                            300) {
                      return;
                    }
                    // Dismiss hover tooltip on tap
                    setState(() {
                      _hoverTooltipData = null;
                      _hoverPosition = null;
                    });
                    _dismissInfoWindow();
                    _handleMapTap(context, provider, position);
                  },
                  polygons: polygons,
                  polylines: polylines,
                  markers: markers,
                  mapType: provider.mapType,
                  style: provider.mapStyle,
                  myLocationButtonEnabled: true,
                  myLocationEnabled: true,
                  zoomControlsEnabled: true,
                  mapToolbarEnabled: false,
                ),
                if (provider.showStylePanel && infoScreen != null)
                  _MapStylePanel(screen: infoScreen),
                if (infoScreen != null)
                  _InfoWindowOverlay(
                    screen: infoScreen,
                    mapSize: mapSize,
                    data: iw!,
                    onDismiss: _dismissInfoWindow,
                    onStyle: iw.type != 'point'
                        ? () {
                            _lastInfoWindowAction = DateTime.now();
                            provider.toggleStylePanel();
                          }
                        : null,
                    onEditVertices: () {
                      _lastInfoWindowAction = DateTime.now();
                      final elementId = iw.elementId;
                      final type = iw.type;
                      _dismissInfoWindow();
                      if (type == 'polygon' || type == 'polyline') {
                        provider.startVertexEditing(elementId);
                      }
                    },
                    onPhoto: null,
                    onDelete: () {
                      _lastInfoWindowAction = DateTime.now();
                      // Use explicit IDs from the info window data —
                      // selectedElementId may already be cleared by a
                      // concurrent web tap-through.
                      final elementId = iw.elementId;
                      final layerId = iw.layerId;
                      _dismissInfoWindow();
                      provider.deleteElement(elementId, layerId);
                    },
                  ),
                // Hover tooltip overlay
                if (_hoverTooltipData != null &&
                    _hoverPosition != null &&
                    iw == null)
                  _HoverTooltip(
                    data: _hoverTooltipData!,
                    position: _hoverPosition!,
                    mapSize: mapSize,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static void _handleMapTap(
      BuildContext context, ShareableMapProvider provider, LatLng position) {
    if (provider.isEditingVertices) {
      if (provider.shouldIgnoreNextTap()) return;
      provider.saveVertexEditing();
      return;
    }
    if (provider.shouldIgnoreNextTap()) return;

    switch (provider.drawingMode) {
      case DrawingMode.polygon:
        if (!provider.isDrawing) provider.startDrawing();
        provider.addDrawingPoint(position);
        break;
      case DrawingMode.polyline:
        if (!provider.isDrawing) provider.startDrawing();
        provider.addDrawingPoint(position);
        break;
      case DrawingMode.point:
        if (!provider.isDrawing) provider.startDrawing();
        provider.addDrawingPoint(position);
        provider.setDialogOpen(true);
        MapEditorDialogs.showElementNameDialog(context, provider)
            .then((_) => provider.setDialogOpen(false));
        break;
      case DrawingMode.none:
        provider.selectElement('');
        break;
      case DrawingMode.edit:
        break;
    }
  }

  Future<void> _handlePolygonTap(BuildContext context,
      ShareableMapProvider provider, String polygonId) async {
    // Ignore element taps when gestures are disabled (user is over a UI overlay)
    if (ref.read(mapGestureRiverpod).gestureHandling ==
        WebGestureHandling.none) {
      return;
    }
    // Guard against tap-through from the info window overlay on web.
    // If the info window is open, dismiss it and swallow the tap.
    if (provider.infoWindowData != null) {
      _dismissInfoWindow();
      return;
    }
    if (provider.isDrawing || provider.isEditingVertices) return;

    final match = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(polygonId);
    if (match == null) return;
    final layerId = match.group(1)!;
    final idx = int.parse(match.group(2)!);

    final layer = provider.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null || idx >= layer.polygons.length) return;
    final polygon = layer.polygons[idx];

    final areaKm2 = _polygonAreaKm2(polygon.points);
    final perimeterKm = _pathLengthKm(polygon.points, closed: true);
    final subtitle = '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}';

    provider.openInfoWindow(InfoWindowData(
      elementId: polygonId,
      layerId: layerId,
      title: polygon.name.isNotEmpty ? polygon.name : 'Unnamed Polygon',
      description: polygon.description,
      subtitle: subtitle,
      type: 'polygon',
      anchor: _tapAnchor(_centroid(polygon.points)),
      letterBoxEstimate: polygon.letterBoxEstimate,
    ));
  }

  /// Handle tap on a preview (ghost) work-area polygon shown during import
  /// mode. Shows a confirmation dialog letting the user add it to the map.
  void _handlePreviewWorkAreaTap(
      BuildContext context, ShareableMapProvider provider, WorkArea wa) {
    final areaKm2 = _polygonAreaKm2(wa.polygonPoints);
    final perimeterKm = _pathLengthKm(wa.polygonPoints, closed: true);

    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(wa.name, style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (wa.description.isNotEmpty) ...[
              Text(wa.description,
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF5F6368))),
              const SizedBox(height: 8),
            ],
            Text(
              '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA0A6)),
            ),
            if (wa.letterBoxEstimate > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '~${wa.letterBoxEstimate} letter boxes',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA0A6)),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add to Map'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        provider.addWorkAreaToMap(wa);
      }
    });
  }

  void _handlePolylineTap(
      BuildContext context, ShareableMapProvider provider, String polylineId) {
    if (ref.read(mapGestureRiverpod).gestureHandling ==
        WebGestureHandling.none) {
      return;
    }
    if (provider.infoWindowData != null) {
      _dismissInfoWindow();
      return;
    }
    if (provider.isDrawing || provider.isEditingVertices) return;

    for (final layer in provider.layers) {
      final found =
          layer.polylines.where((p) => p.id == polylineId).firstOrNull;
      if (found != null) {
        // Build subtitle with track metadata if available
        String subtitle;
        if (found.hasTrackMetadata) {
          final parts = <String>[found.formattedDistance];
          if (found.formattedTimeRange.isNotEmpty) {
            parts.add(found.formattedTimeRange);
          }
          if (found.formattedDuration.isNotEmpty) {
            parts.add(found.formattedDuration);
          }
          subtitle = parts.join(' · ');
        } else {
          final lengthKm = _pathLengthKm(found.points);
          subtitle = _fmtKm(lengthKm);
        }

        provider.openInfoWindow(InfoWindowData(
          elementId: polylineId,
          layerId: layer.id,
          title: found.name.isNotEmpty ? found.name : 'Unnamed Polyline',
          description: found.description,
          subtitle: subtitle,
          type: 'polyline',
          anchor: _tapAnchor(_centroid(found.points)),
        ));
        return;
      }
    }
  }

  void _handleMarkerTap(
      BuildContext context, ShareableMapProvider provider, String pointId) {
    if (ref.read(mapGestureRiverpod).gestureHandling ==
        WebGestureHandling.none) {
      return;
    }
    if (provider.infoWindowData != null) {
      _dismissInfoWindow();
      return;
    }
    for (final layer in provider.layers) {
      final found = layer.points.where((p) => p.id == pointId).firstOrNull;
      if (found != null) {
        provider.openInfoWindow(InfoWindowData(
          elementId: pointId,
          layerId: layer.id,
          title: found.name.isNotEmpty ? found.name : 'Unnamed Point',
          description: found.description,
          subtitle: '',
          type: 'point',
          anchor: found.position,
        ));
        return;
      }
    }
  }
}

/// Sidebar widget with layer management
class MapSidebarWidget extends riverpod.ConsumerWidget {
  const MapSidebarWidget({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(shareableMapRiverpod);
    if (!provider.isSidebarVisible) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 300,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(2, 0),
            ),
          ],
        ),
        child: MouseRegion(
          onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
          onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
          child: const MapLayersSidebar(),
        ),
      ),
    );
  }
}

/// Left sidebar for the work-areas editor: table of polygons with name + estimate.
class _WorkAreaTableSidebar extends riverpod.ConsumerWidget {
  const _WorkAreaTableSidebar();

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(2, 0),
            ),
          ],
        ),
        child: MouseRegion(
          onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
          onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
          child: const WorkAreaTablePanel(),
        ),
      ),
    );
  }
}

/// Drawing toolbar with tool selection buttons
class MapDrawingToolbarWidget extends riverpod.ConsumerWidget {
  const MapDrawingToolbarWidget({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    return Positioned(
      right: 16,
      top: 16,
      child: MouseRegion(
        onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
        onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
        child: const MapDrawingToolbar(),
      ),
    );
  }
}

/// Drawing controls panel shown during drawing
class MapDrawingControlsWidget extends riverpod.ConsumerWidget {
  const MapDrawingControlsWidget({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(shareableMapRiverpod);
    if (!provider.isDrawing) {
      return const SizedBox.shrink();
    }

    final pointCount = provider.drawingPoints.length;
    final canComplete = _canCompleteDrawing(provider);

    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: MouseRegion(
            onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
            onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFDADCE0)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Status text
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _getDrawingModeIcon(provider.drawingMode),
                        size: 20,
                        color: const Color(0xFF1967D2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Drawing ${_getDrawingModeLabel(provider.drawingMode)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF202124),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0FE),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$pointCount ${pointCount == 1 ? 'point' : 'points'}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1967D2),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Action buttons
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Undo last point
                      OutlinedButton.icon(
                        onPressed: pointCount > 0
                            ? () {
                                provider.removeLastDrawingPoint();
                                provider.markIgnoreNextTap();
                              }
                            : null,
                        icon: const Icon(Icons.undo, size: 18),
                        label: const Text('Undo'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF5F6368),
                          side: const BorderSide(color: Color(0xFFDADCE0)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Cancel
                      OutlinedButton.icon(
                        onPressed: () => provider.cancelDrawing(),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Cancel'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFD93025),
                          side: const BorderSide(color: Color(0xFFDADCE0)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Complete
                      ElevatedButton.icon(
                        onPressed: canComplete
                            ? () {
                                // Block drawing while dialog is open
                                provider.setDialogOpen(true);
                                MapEditorDialogs.showElementNameDialog(
                                        context, provider)
                                    .then((_) {
                                  // Unblock drawing when dialog closes
                                  provider.setDialogOpen(false);
                                });
                              }
                            : null,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Complete'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1967D2),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFE8EAED),
                          disabledForegroundColor: const Color(0xFF80868B),
                        ),
                      ),
                    ],
                  ),
                  // Hint text with more guidance
                  if (!canComplete)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _getDrawingHint(provider.drawingMode, pointCount),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF5F6368),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  // Progress indicator for polygons and polylines
                  if (provider.drawingMode == DrawingMode.polygon ||
                      provider.drawingMode == DrawingMode.polyline)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 12,
                            color: Colors.grey[600],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Click map to add points, then complete',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _canCompleteDrawing(ShareableMapProvider provider) {
    final pointCount = provider.drawingPoints.length;
    switch (provider.drawingMode) {
      case DrawingMode.polygon:
        return pointCount >= 3;
      case DrawingMode.polyline:
        return pointCount >= 2;
      case DrawingMode.point:
        return pointCount >= 1;
      default:
        return false;
    }
  }

  IconData _getDrawingModeIcon(DrawingMode mode) {
    switch (mode) {
      case DrawingMode.polygon:
        return Icons.pentagon_outlined;
      case DrawingMode.polyline:
        return Icons.timeline;
      case DrawingMode.point:
        return Icons.place_outlined;
      default:
        return Icons.edit;
    }
  }

  String _getDrawingModeLabel(DrawingMode mode) {
    switch (mode) {
      case DrawingMode.polygon:
        return 'Polygon';
      case DrawingMode.polyline:
        return 'Polyline';
      case DrawingMode.point:
        return 'Point';
      default:
        return 'Element';
    }
  }

  String _getDrawingHint(DrawingMode mode, int pointCount) {
    switch (mode) {
      case DrawingMode.polygon:
        final needed = 3 - pointCount;
        return needed > 0
            ? 'Add $needed more ${needed == 1 ? 'point' : 'points'} to complete polygon'
            : 'Click to add more points or complete';
      case DrawingMode.polyline:
        final needed = 2 - pointCount;
        return needed > 0
            ? 'Add $needed more ${needed == 1 ? 'point' : 'points'} to complete line'
            : 'Click to add more points or complete';
      case DrawingMode.point:
        return pointCount == 0 ? 'Click on the map to place point' : '';
      default:
        return 'Click on the map to add points';
    }
  }
}

// ============================================================================
// Dialog Utilities
// ============================================================================

/// Utility class for showing various map editor dialogs
class MapEditorDialogs {
  MapEditorDialogs._();

  static void showCreateMapDialog(BuildContext context) {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Map'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Map Name',
                hintText: 'Enter map name',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'Enter description',
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                riverpod.ProviderScope.containerOf(context)
                    .read(shareableMapRiverpod)
                    .createNewMap(
                      name: nameController.text.trim(),
                      description: descController.text.trim(),
                    );
                Navigator.pop(context);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  static void showImportDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const MapImportDialog(),
    ).then((imported) {
      if (imported == true && context.mounted) {
        // Fit map to show imported data
        riverpod.ProviderScope.containerOf(context)
            .read(shareableMapRiverpod)
            .fitMapToBounds();
      }
    });
  }

  static Future<void> showElementNameDialog(
      BuildContext context, ShareableMapProvider provider) {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final isPoint = provider.drawingMode == DrawingMode.point;
    PointCategory selectedCategory = PointCategory.generic;

    return showDialog(
      context: context,
      barrierDismissible: false, // Prevent dismissing by clicking outside
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Name ${_getDrawingModeLabel(provider.drawingMode)}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isPoint) ...[
                DropdownButtonFormField<PointCategory>(
                  initialValue: selectedCategory,
                  decoration: const InputDecoration(
                    labelText: 'Point Type',
                  ),
                  items: PointCategory.values.map((cat) {
                    return DropdownMenuItem(
                      value: cat,
                      child: Row(
                        children: [
                          Icon(cat.icon, color: cat.color, size: 20),
                          const SizedBox(width: 8),
                          Text(cat.label),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => selectedCategory = val);
                      if (nameController.text.isEmpty ||
                          PointCategory.values
                              .any((c) => c.label == nameController.text)) {
                        nameController.text = val.label;
                      }
                    }
                  },
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Enter name',
                ),
                autofocus: !isPoint,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'Enter description',
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                provider.cancelDrawing();
                Navigator.pop(dialogContext);
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim().isNotEmpty
                    ? nameController.text.trim()
                    : (isPoint ? selectedCategory.label : null);
                if (name != null && name.isNotEmpty) {
                  provider.completeDrawing(
                    name: name,
                    description: descController.text.trim(),
                    pointCategory: isPoint ? selectedCategory : null,
                  );
                  Navigator.pop(dialogContext);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  static String _getDrawingModeLabel(DrawingMode mode) {
    switch (mode) {
      case DrawingMode.polygon:
        return 'Polygon';
      case DrawingMode.polyline:
        return 'Polyline';
      case DrawingMode.point:
        return 'Point';
      default:
        return 'Element';
    }
  }
}

// ============================================================================
// Custom Info Window
// ============================================================================

/// Style panel widget (proper StatelessWidget instead of widget function).
/// Reads info window data from the provider and delegates style changes.
class _MapStylePanel extends riverpod.ConsumerWidget {
  final Offset screen;
  const _MapStylePanel({required this.screen});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.read(shareableMapRiverpod);
    final iw = provider.infoWindowData;
    if (iw == null) return const SizedBox.shrink();

    Color initialColor = Colors.blue;
    double initialFillOpacity = 0.35;
    double initialStrokeWidth = 2.0;

    if (iw.type == 'polygon') {
      final match = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(iw.elementId);
      if (match != null) {
        final idx = int.parse(match.group(2)!);
        final layer =
            provider.layers.where((l) => l.id == iw.layerId).firstOrNull;
        if (layer != null && idx < layer.polygons.length) {
          final poly = layer.polygons[idx];
          initialColor = poly.color;
          initialFillOpacity = poly.fillOpacity;
          initialStrokeWidth = poly.strokeWidth.toDouble();
        }
      }
    } else if (iw.type == 'polyline') {
      final layer =
          provider.layers.where((l) => l.id == iw.layerId).firstOrNull;
      final found =
          layer?.polylines.where((p) => p.id == iw.elementId).firstOrNull;
      if (found != null) {
        initialColor = found.color;
        initialStrokeWidth = found.strokeWidth;
      }
    }

    return _StylePanelOverlay(
      key: ValueKey('style_${iw.elementId}'),
      screen: screen,
      type: iw.type,
      initialColor: initialColor,
      initialFillOpacity: initialFillOpacity,
      initialStrokeWidth: initialStrokeWidth,
      onClose: () => provider.closeStylePanel(),
      onColorChanged: (c) {
        if (iw.type == 'polygon') {
          provider.updatePolygonStyle(iw.layerId, iw.elementId, color: c);
        } else if (iw.type == 'polyline') {
          provider.updatePolylineStyle(iw.layerId, iw.elementId, color: c);
        }
      },
      onFillOpacityChanged: (v) {
        if (iw.type == 'polygon') {
          provider.updatePolygonStyle(iw.layerId, iw.elementId, fillOpacity: v);
        }
      },
      onStrokeWidthChanged: (v) {
        if (iw.type == 'polygon') {
          provider.updatePolygonStyle(iw.layerId, iw.elementId,
              strokeWidth: v.round());
        } else if (iw.type == 'polyline') {
          provider.updatePolylineStyle(iw.layerId, iw.elementId,
              strokeWidth: v);
        }
      },
    );
  }
}

// ─── Hover tooltip ──────────────────────────────────────────────────────

/// Data model for the lightweight hover tooltip.
class _HoverTooltipData {
  final String name;
  final String description;
  final String stats;
  final Color color;

  const _HoverTooltipData({
    required this.name,
    required this.description,
    required this.stats,
    required this.color,
  });
}

/// Lightweight tooltip that follows the cursor when hovering over a polygon.
/// Shows the polygon name, description snippet, and area/perimeter stats.
class _HoverTooltip extends StatelessWidget {
  final _HoverTooltipData data;
  final Offset position;
  final Size mapSize;

  static const double _tooltipWidth = 220.0;
  static const double _cursorOffset = 16.0;

  const _HoverTooltip({
    required this.data,
    required this.position,
    required this.mapSize,
  });

  @override
  Widget build(BuildContext context) {
    // Position tooltip to the right of and slightly below the cursor.
    // Flip left if it would overflow the right edge.
    double left = position.dx + _cursorOffset;
    if (left + _tooltipWidth > mapSize.width - 8) {
      left = position.dx - _tooltipWidth - _cursorOffset;
    }
    // Clamp vertically
    double top = position.dy + _cursorOffset;
    if (top + 80 > mapSize.height) {
      top = position.dy - 80 - _cursorOffset;
    }

    return Positioned(
      left: left.clamp(4.0, mapSize.width - _tooltipWidth - 4),
      top: top.clamp(4.0, mapSize.height - 28),
      child: IgnorePointer(
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(6),
          color: const Color(0xFF3C4043),
          child: Container(
            width: _tooltipWidth,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Name with color indicator
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: data.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        data.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (data.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    data.description,
                    style: const TextStyle(
                      color: Color(0xFFBDC1C6),
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (data.stats.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    data.stats,
                    style: const TextStyle(
                      color: Color(0xFF8AB4F8),
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Info window overlay that appears at the tap location, matching Google My Maps style.
class _InfoWindowOverlay extends riverpod.ConsumerStatefulWidget {
  final InfoWindowData data;
  final VoidCallback onDismiss;

  /// Called when the style/paint-bucket button is tapped (fill color, stroke).
  final VoidCallback? onStyle;

  /// Called when the edit-vertices (pencil) button is tapped.
  final VoidCallback onEditVertices;

  /// Called when the camera/photo button is tapped.
  final VoidCallback? onPhoto;

  /// Called when the delete button is confirmed.
  final VoidCallback onDelete;

  final Offset screen;

  /// Size of the parent Stack (map widget). Used to correctly position the
  /// Positioned widget so Flutter's platform-view pointer-event blocker covers
  /// the actual card area (not just the untranslated layout rect).
  final Size mapSize;

  const _InfoWindowOverlay({
    required this.screen,
    required this.mapSize,
    required this.data,
    required this.onDismiss,
    required this.onStyle,
    required this.onEditVertices,
    required this.onPhoto,
    required this.onDelete,
  });

  @override
  riverpod.ConsumerState<_InfoWindowOverlay> createState() =>
      _InfoWindowOverlayState();
}

class _InfoWindowOverlayState
    extends riverpod.ConsumerState<_InfoWindowOverlay> {
  static const double _cardWidth = 260.0;
  static const double _tailHalfWidth = 10.0;
  static const double _tailH = 8.0;
  static const double _flipThreshold = 160.0;

  late TextEditingController _titleController;
  late FocusNode _titleFocusNode;
  bool _isEditingTitle = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.data.title);
    _titleFocusNode = FocusNode();
    _titleFocusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _InfoWindowOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update controller text if the data changed externally (different element)
    if (oldWidget.data.elementId != widget.data.elementId) {
      _titleController.text = widget.data.title;
      _isEditingTitle = false;
    }
  }

  @override
  void dispose() {
    _titleFocusNode.removeListener(_onFocusChanged);
    _titleFocusNode.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_titleFocusNode.hasFocus && _isEditingTitle) {
      _commitTitle();
    }
  }

  void _commitTitle() {
    final newName = _titleController.text.trim();
    if (newName.isNotEmpty && newName != widget.data.title) {
      ref.read(shareableMapRiverpod).renameElement(
            widget.data.layerId,
            widget.data.elementId,
            widget.data.type,
            newName,
          );
    } else if (newName.isEmpty) {
      // Revert to original if empty
      _titleController.text = widget.data.title;
    }
    setState(() => _isEditingTitle = false);
  }

  @override
  Widget build(BuildContext context) {
    final offset = widget.screen;
    final screenWidth = MediaQuery.of(context).size.width;

    // Horizontal clamping so card stays on screen.
    final idealLeft = offset.dx - _cardWidth / 2;
    final left = idealLeft.clamp(8.0, screenWidth - _cardWidth - 8.0);
    final tailCenterX =
        (offset.dx - left).clamp(_tailHalfWidth, _cardWidth - _tailHalfWidth);

    // Flip below the tap point when too close to the top edge.
    final tailBelow = offset.dy >= _flipThreshold;

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!tailBelow)
          SizedBox(
            width: _cardWidth,
            child: CustomPaint(
              size: Size(_cardWidth, _tailH),
              painter:
                  _InfoWindowTailPainter(centerX: tailCenterX, pointUp: true),
            ),
          ),
        _buildCard(context),
        if (tailBelow)
          SizedBox(
            width: _cardWidth,
            child: CustomPaint(
              size: Size(_cardWidth, _tailH),
              painter:
                  _InfoWindowTailPainter(centerX: tailCenterX, pointUp: false),
            ),
          ),
      ],
    );

    return tailBelow
        ? Positioned(
            left: left,
            bottom: widget.mapSize.height - offset.dy,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) =>
                  ref.read(mapGestureRiverpod).disableMapGestures(),
              onPointerUp: (_) {
                // Keep gestures disabled briefly so the platform view
                // doesn't fire GoogleMap.onTap concurrently.
                Future.delayed(const Duration(milliseconds: 350), () {
                  if (context.mounted) {
                    ref.read(mapGestureRiverpod).enableMapGestures();
                  }
                });
              },
              child: MouseRegion(
                onEnter: (_) =>
                    ref.read(mapGestureRiverpod).disableMapGestures(),
                onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
                child: column,
              ),
            ),
          )
        : Positioned(
            left: left,
            top: offset.dy,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) =>
                  ref.read(mapGestureRiverpod).disableMapGestures(),
              onPointerUp: (_) {
                Future.delayed(const Duration(milliseconds: 350), () {
                  if (context.mounted) {
                    ref.read(mapGestureRiverpod).enableMapGestures();
                  }
                });
              },
              child: MouseRegion(
                onEnter: (_) =>
                    ref.read(mapGestureRiverpod).disableMapGestures(),
                onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
                child: column,
              ),
            ),
          );
  }

  Widget _buildCard(BuildContext context) {
    final data = widget.data;
    final hasSubtitle = data.subtitle.isNotEmpty;
    final hasDesc = data.description.isNotEmpty;
    final isShapeable = data.type == 'polygon' || data.type == 'polyline';

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: Colors.white,
      shadowColor: Colors.black26,
      child: SizedBox(
        width: _cardWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Title row ──────────────────────────────────────────
            MouseRegion(
              cursor: SystemMouseCursors.text,
              onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
              onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _isEditingTitle
                          ? TextField(
                              controller: _titleController,
                              focusNode: _titleFocusNode,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF202124),
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 4),
                                border: OutlineInputBorder(),
                                focusedBorder: OutlineInputBorder(
                                  borderSide: BorderSide(
                                      color: Color(0xFF4285F4), width: 1.5),
                                ),
                              ),
                              maxLines: 1,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _commitTitle(),
                            )
                          : GestureDetector(
                              onTap: () {
                                setState(() => _isEditingTitle = true);
                                // Request focus after the frame so the
                                // TextField is mounted.
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  _titleFocusNode.requestFocus();
                                  _titleController.selection = TextSelection(
                                    baseOffset: 0,
                                    extentOffset: _titleController.text.length,
                                  );
                                });
                              },
                              child: Text(
                                data.title,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF202124),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: widget.onDismiss,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close,
                            size: 18, color: Color(0xFF80868B)),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Point category selector (points only) ──────────────
            if (data.type == 'point') _buildCategoryRow(data),

            // ── Description (optional) ─────────────────────────────
            if (hasDesc)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                child: Text(
                  data.description,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF5F6368)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

            // ── Stats row (area/perimeter or length) ───────────────
            if (hasSubtitle) ...[
              const Divider(height: 1, thickness: 1, color: Color(0xFFE8EAED)),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: _buildStatsRow(
                    data.type, data.subtitle, data.letterBoxEstimate),
              ),
            ],

            // ── Action buttons ─────────────────────────────────────
            const Divider(height: 1, thickness: 1, color: Color(0xFFE8EAED)),
            SizedBox(
              height: 42,
              child: _buildActionsRow(context, isShapeable),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsRow(String type, String subtitle, int letterBoxEstimate) {
    if (type == 'polygon') {
      // subtitle format: "X.XX km²  ·  X.XX km"
      final parts = subtitle.split('·');
      final areaPart = parts.isNotEmpty ? parts[0].trim() : subtitle;
      final perimPart = parts.length > 1 ? parts[1].trim() : '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatItem(
                icon: _AreaIcon(),
                label: areaPart,
              ),
              if (perimPart.isNotEmpty) ...[
                const SizedBox(width: 16),
                _StatItem(
                  icon: const Icon(Icons.crop_square,
                      size: 14, color: Color(0xFF5F6368)),
                  label: perimPart,
                ),
              ],
            ],
          ),
          if (letterBoxEstimate > 0) ...[
            const SizedBox(height: 4),
            _StatItem(
              icon: const Icon(Icons.markunread_mailbox_outlined,
                  size: 14, color: Color(0xFF5F6368)),
              label: '~$letterBoxEstimate letter boxes',
            ),
          ],
        ],
      );
    } else {
      // polyline: subtitle may contain "distance · timeRange · duration"
      final parts = subtitle.split('·').map((s) => s.trim()).toList();
      final distance = parts.isNotEmpty ? parts[0] : subtitle;
      final timeRange = parts.length > 1 ? parts[1] : '';
      final duration = parts.length > 2 ? parts[2] : '';

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatItem(
            icon:
                const Icon(Icons.timeline, size: 14, color: Color(0xFF5F6368)),
            label: distance,
          ),
          if (timeRange.isNotEmpty) ...[
            const SizedBox(height: 4),
            _StatItem(
              icon: const Icon(Icons.schedule,
                  size: 14, color: Color(0xFF5F6368)),
              label: timeRange,
            ),
          ],
          if (duration.isNotEmpty) ...[
            const SizedBox(height: 4),
            _StatItem(
              icon: const Icon(Icons.timer_outlined,
                  size: 14, color: Color(0xFF5F6368)),
              label: duration,
            ),
          ],
        ],
      );
    }
  }

  Widget _buildActionsRow(BuildContext context, bool isShapeable) {
    final actions = <_IconAction>[
      _IconAction(
        icon: Icons.format_paint_outlined,
        tooltip: 'Style',
        onTap: widget.onStyle,
      ),
      _IconAction(
        icon: Icons.edit_outlined,
        tooltip: 'Edit vertices',
        onTap: isShapeable ? widget.onEditVertices : null,
        enabled: isShapeable,
      ),
      _IconAction(
        icon: Icons.photo_camera_outlined,
        tooltip: 'Add photo',
        onTap: widget.onPhoto,
      ),
      _IconAction(
        icon: Icons.delete_outline,
        tooltip: 'Delete',
        onTap: () => _confirmDelete(context),
        color: const Color(0xFFD93025),
      ),
    ];

    return Row(
      children: actions.asMap().entries.map((entry) {
        final i = entry.key;
        final a = entry.value;
        return Expanded(
          child: Row(
            children: [
              if (i > 0)
                Container(width: 1, height: 24, color: const Color(0xFFE8EAED)),
              Expanded(
                child: _ActionIconButton(action: a),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  /// Row of category chips shown for point-type elements.
  Widget _buildCategoryRow(InfoWindowData data) {
    // Look up the current point from the provider to get its category.
    final provider = ref.watch(shareableMapRiverpod);
    final map = provider.currentMap;
    PointCategory current = PointCategory.generic;
    if (map != null) {
      for (final layer in map.layers) {
        if (layer.id != data.layerId) continue;
        for (final pt in layer.points) {
          if (pt.id == data.elementId) {
            current = pt.pointCategory;
            break;
          }
        }
      }
    }

    return MouseRegion(
      onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
      onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<PointCategory>(
            value: current,
            isDense: true,
            isExpanded: true,
            icon: const Icon(Icons.arrow_drop_down,
                size: 18, color: Color(0xFF80868B)),
            style: const TextStyle(fontSize: 12, color: Color(0xFF202124)),
            items: PointCategory.values.map((cat) {
              return DropdownMenuItem(
                value: cat,
                child: Row(
                  children: [
                    Icon(cat.icon, size: 16, color: cat.color),
                    const SizedBox(width: 8),
                    Text(cat.label),
                  ],
                ),
              );
            }).toList(),
            onChanged: (cat) {
              if (cat != null) {
                ref
                    .read(shareableMapRiverpod)
                    .updatePointCategory(data.layerId, data.elementId, cat);
              }
            },
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete element?'),
        content: Text('Delete "${widget.data.title}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    ).then((ok) {
      if (ok == true) widget.onDelete();
    });
  }
}

/// A small stat item: [icon] + [label]
class _StatItem extends StatelessWidget {
  final Widget icon;
  final String label;
  const _StatItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
        ),
      ],
    );
  }
}

/// Custom area icon: a small square with diagonal hatching lines
class _AreaIcon extends StatelessWidget {
  const _AreaIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(14, 14),
      painter: _AreaIconPainter(),
    );
  }
}

class _AreaIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final linePaint = Paint()
      ..color = const Color(0xFF5F6368)
      ..strokeWidth = 0.9;

    // Draw "/" diagonal hatch lines across the square
    const step = 3.5;
    for (double d = step; d < size.width + size.height; d += step) {
      double x0, y0, x1, y1;
      if (d <= size.height) {
        x0 = 0;
        y0 = size.height - d;
      } else {
        x0 = d - size.height;
        y0 = 0;
      }
      if (d <= size.width) {
        x1 = d;
        y1 = 0;
      } else {
        x1 = size.width;
        y1 = d - size.width;
      }
      if ((x1 - x0).abs() < 0.01 && (y1 - y0).abs() < 0.01) continue;
      canvas.drawLine(Offset(x0, y0), Offset(x1, y1), linePaint);
    }

    // Draw border on top
    final borderPaint = Paint()
      ..color = const Color(0xFF5F6368)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(
        Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1), borderPaint);
  }

  @override
  bool shouldRepaint(_) => false;
}

/// Data for a single action button in the info window toolbar
class _IconAction {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final bool enabled;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.enabled = true,
  });
}

class _ActionIconButton extends riverpod.ConsumerWidget {
  final _IconAction action;
  const _ActionIconButton({required this.action});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final active = action.enabled && action.onTap != null;
    final color = active
        ? (action.color ?? const Color(0xFF444746))
        : const Color(0xFFBDC1C6);

    return Tooltip(
      message: action.tooltip,
      child: MouseRegion(
        cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
        onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
        child: InkWell(
          onTap: active ? action.onTap : null,
          borderRadius: BorderRadius.circular(4),
          child: SizedBox.expand(
            child: Icon(action.icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}

class _InfoWindowTailPainter extends CustomPainter {
  final double centerX;

  /// [pointUp] true → triangle points upward (tail above card); false → downward
  final bool pointUp;
  const _InfoWindowTailPainter({required this.centerX, required this.pointUp});

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = const Color(0xFFDADCE0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final path = pointUp
        ? (Path()
          ..moveTo(centerX - 10, size.height)
          ..lineTo(centerX + 10, size.height)
          ..lineTo(centerX, 0)
          ..close())
        : (Path()
          ..moveTo(centerX - 10, 0)
          ..lineTo(centerX + 10, 0)
          ..lineTo(centerX, size.height)
          ..close());

    canvas.drawPath(path, fill);
    canvas.drawPath(path, border);
  }

  @override
  bool shouldRepaint(covariant _InfoWindowTailPainter old) =>
      old.centerX != centerX || old.pointUp != pointUp;
}

// ─────────────────────────────────────────────────────────────────────────────
// Style panel
// ─────────────────────────────────────────────────────────────────────────────

/// Floating style editor panel (colour, opacity, stroke width) for polygons
/// and polylines. Positioned near the info window's tap anchor.
class _StylePanelOverlay extends riverpod.ConsumerStatefulWidget {
  final Offset screen;
  final String type; // 'polygon' | 'polyline'
  final Color initialColor;
  final double initialFillOpacity;
  final double initialStrokeWidth;
  final VoidCallback onClose;
  final void Function(Color) onColorChanged;
  final void Function(double) onFillOpacityChanged;
  final void Function(double) onStrokeWidthChanged;

  const _StylePanelOverlay({
    super.key,
    required this.screen,
    required this.type,
    required this.initialColor,
    required this.initialFillOpacity,
    required this.initialStrokeWidth,
    required this.onClose,
    required this.onColorChanged,
    required this.onFillOpacityChanged,
    required this.onStrokeWidthChanged,
  });

  @override
  riverpod.ConsumerState<_StylePanelOverlay> createState() =>
      _StylePanelOverlayState();
}

class _StylePanelOverlayState
    extends riverpod.ConsumerState<_StylePanelOverlay> {
  late Color _color;
  late double _fillOpacity;
  late double _strokeWidth;

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
    _fillOpacity = widget.initialFillOpacity;
    _strokeWidth = widget.initialStrokeWidth.clamp(1.0, 8.0);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    const panelW = 260.0;

    // Prefer to the right of the info window; clamp to screen edges.
    final infoLeft =
        (widget.screen.dx - 130.0).clamp(8.0, screenSize.width - 260.0 - 8.0);
    final rightPos = infoLeft + 264.0;
    final left = rightPos + panelW <= screenSize.width - 8.0
        ? rightPos
        : (infoLeft - panelW - 4.0).clamp(8.0, screenSize.width - panelW - 8.0);
    final top = (widget.screen.dy - 50.0).clamp(8.0, screenSize.height - 8.0);

    return Positioned(
      left: left,
      top: top,
      child: MouseRegion(
        onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
        onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {}, // absorb taps so GoogleMap.onTap doesn't fire
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            color: Colors.white,
            shadowColor: Colors.black38,
            child: SizedBox(
              width: panelW,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header ──────────────────────────────────────────
                    Row(children: [
                      const Expanded(
                        child: Text('Style',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF202124))),
                      ),
                      GestureDetector(
                        onTap: widget.onClose,
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close,
                              size: 16, color: Color(0xFF80868B)),
                        ),
                      ),
                    ]),

                    const SizedBox(height: 10),

                    // ── Colour ───────────────────────────────────────────
                    const Text('Colour',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF5F6368))),
                    const SizedBox(height: 6),
                    _ColorGrid(
                      selected: _color,
                      onSelected: (c) {
                        setState(() => _color = c);
                        widget.onColorChanged(c);
                      },
                    ),

                    // ── Polygon transparency ─────────────────────────────
                    if (widget.type == 'polygon') ...[
                      const SizedBox(height: 10),
                      const Text('Polygon transparency',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF5F6368))),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7),
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 14),
                          trackHeight: 3,
                        ),
                        child: Slider(
                          value: _fillOpacity,
                          min: 0.0,
                          max: 1.0,
                          divisions: 20,
                          activeColor: const Color(0xFF4285F4),
                          inactiveColor: const Color(0xFFDADCE0),
                          onChanged: (v) {
                            setState(() => _fillOpacity = v);
                            widget.onFillOpacityChanged(v);
                          },
                        ),
                      ),
                    ],

                    // ── Border width ─────────────────────────────────────
                    const SizedBox(height: 4),
                    const Text('Border width',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF5F6368))),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 7),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 14),
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: _strokeWidth,
                        min: 1.0,
                        max: 8.0,
                        divisions: 7,
                        activeColor: const Color(0xFF4285F4),
                        inactiveColor: const Color(0xFFDADCE0),
                        onChanged: (v) {
                          setState(() => _strokeWidth = v);
                          widget.onStrokeWidthChanged(v);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ), // GestureDetector
      ), // MouseRegion
    );
  }
}

/// Compact colour swatch grid matching Google My Maps style.
class _ColorGrid extends StatelessWidget {
  final Color selected;
  final void Function(Color) onSelected;

  static const List<Color> _palette = [
    // Row 1 — vivid spectrum
    Color(0xFFE53935), Color(0xFFD81B60), Color(0xFF8E24AA), Color(0xFF5E35B1),
    Color(0xFF3949AB), Color(0xFF1E88E5), Color(0xFF039BE5), Color(0xFF00ACC1),
    // Row 2 — greens / yellows / warm
    Color(0xFF00897B), Color(0xFF43A047), Color(0xFF7CB342), Color(0xFFEABE00),
    Color(0xFFFFB300), Color(0xFFFB8C00), Color(0xFFF4511E), Color(0xFFBF360C),
    // Row 3 — earthy / grey
    Color(0xFF795548), Color(0xFF546E7A), Color(0xFF78909C), Color(0xFF90A4AE),
    Color(0xFFBDBDBD), Color(0xFF757575), Color(0xFF424242), Color(0xFF000000),
    // Row 4 — light pastel (top)
    Color(0xFFEF9A9A), Color(0xFFF48FB1), Color(0xFFCE93D8), Color(0xFFB39DDB),
    Color(0xFF9FA8DA), Color(0xFF90CAF9), Color(0xFF80DEEA), Color(0xFFA5D6A7),
    // Row 5 — light pastel (bottom)
    Color(0xFFC5E1A5), Color(0xFFFFF176), Color(0xFFFFE082), Color(0xFFFFCC80),
    Color(0xFFFFAB91), Color(0xFFBCAAA4), Color(0xFFEEEEEE), Color(0xFFFFFFFF),
  ];

  const _ColorGrid({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: _palette.map((c) {
        final isSel = c.toARGB32() == selected.toARGB32();
        return GestureDetector(
          onTap: () => onSelected(c),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: c,
              border: Border.all(
                color:
                    isSel ? const Color(0xFF333333) : const Color(0xFFDADCE0),
                width: isSel ? 2.0 : 0.5,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }).toList(),
    );
  }
}
