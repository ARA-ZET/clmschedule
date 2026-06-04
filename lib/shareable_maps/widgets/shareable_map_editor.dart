import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:math' as math;
// Browser title update — web only, no-op on other platforms.
// ignore: avoid_web_libraries_in_flutter, depend_on_referenced_packages
import 'package:web/web.dart' as web show document;
import '../../config/flavor_config.dart';
import '../../models/custom_polygon.dart';
import '../../models/work_area.dart';
import '../../models/work_suburb.dart';
import '../../providers/auth_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../providers/unfinished_work_areas_provider.dart';
import '../providers/shareable_map_provider.dart';
import '../providers/map_gesture_provider.dart';
import '../services/map_bitmap_cache.dart';
import '../services/map_link_service.dart';
import '../adapters/firestore_adapter.dart';
import '../adapters/work_area_adapter.dart';
import '../adapters/work_suburbs_adapter.dart';
import 'map_layers_sidebar.dart';
import 'map_drawing_toolbar.dart';
import 'map_import_dialog.dart';
import 'shareable_maps_gallery.dart';
import 'work_area_picker_panel.dart';
import 'work_area_table_panel.dart';
import 'work_suburbs_table_panel.dart';
import '../../widgets/cloud_file_manager_screen.dart';
import '../../track_editor/pages/track_editor_screen.dart';

/// Width threshold below which the standalone Maps flavor enters a
/// touch-friendly viewer mode: sidebar hidden, drawing toolbars hidden,
/// markers non-draggable and all add/edit/delete buttons disabled so the
/// user can pan/zoom freely without accidentally triggering edits.
const double _mapsMobileBreakpoint = 700;

/// True when the editor should render in mobile viewer mode — Maps flavor
/// running on a narrow screen.
bool isMapsMobileViewer(BuildContext context) {
  if (!FlavorConfig.instance.isMaps) return false;
  return MediaQuery.sizeOf(context).width < _mapsMobileBreakpoint;
}

/// Main map editor widget for the universal map editor.
/// Displays Google Maps with drawing tools and layer management.
/// UI elements are conditionally shown based on the active adapter's
/// [MapEditorCapabilities].
class ShareableMapEditor extends riverpod.ConsumerStatefulWidget {
  const ShareableMapEditor({super.key});

  @override
  riverpod.ConsumerState<ShareableMapEditor> createState() =>
      _ShareableMapEditorState();
}

class _ShareableMapEditorState
    extends riverpod.ConsumerState<ShareableMapEditor> {
  String? _lastTitle;

  /// Update the browser tab title to the map name (Maps flavor only).
  void _syncBrowserTitle(String? mapName) {
    if (!FlavorConfig.instance.isMaps) return;
    final title =
        (mapName != null && mapName.isNotEmpty) ? mapName : 'CLM Maps';
    if (_lastTitle == title) return;
    _lastTitle = title;
    web.document.title = title;
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    // Keep browser tab title in sync with the open map.
    _syncBrowserTitle(provider.currentMap?.name);
    final mobileViewer = isMapsMobileViewer(context);
    final isMaps = FlavorConfig.instance.isMaps;
    final isAuthenticated = ref.watch(authRiverpod).isAuthenticated;
    final canEditInThisView = !isMaps || (isAuthenticated && !mobileViewer);
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
          final isWorkSuburbsEditor = provider.adapter is WorkSuburbsAdapter;
          return Stack(
            children: [
              const MapViewWidget(),
              if (caps.canManageLayers) const MapSidebarWidget(),
              if (isWorkAreaEditor && !mobileViewer)
                const _WorkAreaTableSidebar(),
              if (isWorkSuburbsEditor && !mobileViewer)
                const _WorkSuburbsTableSidebar(),
              if (caps.canDraw && !caps.readOnly && canEditInThisView)
                const MapDrawingToolbarWidget(),
              if (!caps.readOnly && canEditInThisView)
                const MapDrawingControlsWidget(),
              // Cloud tracks loading indicator
              if (provider.isLoadingCloudTracks)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: MouseRegion(
                    onEnter: (_) =>
                        ref.read(mapGestureRiverpod).disableMapGestures(),
                    onExit: (_) =>
                        ref.read(mapGestureRiverpod).enableMapGestures(),
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                            SizedBox(width: 8),
                            Text('Loading cloud tracks…',
                                style: TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Work area picker panel (positioned top-right under app bar)
              if (provider.isWorkAreaPickerVisible)
                Positioned(
                  top: 8,
                  right: 8,
                  child: MouseRegion(
                    onEnter: (_) =>
                        ref.read(mapGestureRiverpod).disableMapGestures(),
                    onExit: (_) =>
                        ref.read(mapGestureRiverpod).enableMapGestures(),
                    child: WorkAreaPickerPanel(
                      onClose: () => provider.hideWorkAreaPicker(),
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

    final isMaps = FlavorConfig.instance.isMaps;
    // In the standalone Maps flavor, treat any authenticated viewer as an
    // admin and unlock the full editing toolbar. Non-authenticated viewers
    // still see the read-only / limited UI.
    final isAuthenticated = ref.watch(authRiverpod).isAuthenticated;
    // On narrow screens (mobile / tablet portrait) in the Maps flavor we
    // collapse to a touch-friendly viewer so users can pan/zoom freely
    // without admin buttons crowding the UI or accidental edits.
    final mobileViewer = isMapsMobileViewer(context);
    // Hide the back button only for unauthenticated maps viewers (they have
    // no gallery / navigation history to go back to). Authenticated users in
    // the maps flavor get a back button that takes them to the gallery.
    final hideBackButton = isMaps && !isAuthenticated;
    final showAdminTools = !isMaps || (isAuthenticated && !mobileViewer);
    final showPolygonSearch = !isMaps;

    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      // ── Leading button ────────────────────────────────────────────────
      // Maps flavor uses labelled action buttons so client-facing controls are
      // self-explanatory. Non-maps keeps the standard back button here.
      leading: isMaps
          ? null
          : (hideBackButton
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back, color: Color(0xFF5F6368)),
                  onPressed: () async {
                    FocusManager.instance.primaryFocus?.unfocus();
                    await Future.delayed(Duration.zero);
                    if (provider.hasUnsavedChanges && provider.hasAdapter) {
                      await provider.saveToAdapter(captureThumbnail: true);
                    }
                    if (!context.mounted) return;
                    Navigator.pop(context);
                  },
                )),
      automaticallyImplyLeading: false,
      titleSpacing: isMaps ? 16 : 0,
      title: showPolygonSearch
          ? _buildSearchTitle(provider, allPolygons)
          : _buildMapsTitle(provider, isAuthenticated),
      actions: [
        // Maps flavor: back button moves to actions so layers toggle can own
        // the leading slot. Non-maps back button lives in leading (see above).
        if (isMaps && !hideBackButton)
          _AppBarLabelAction(
            icon: Icons.arrow_back_rounded,
            label: 'Gallery',
            onPressed: () async {
              FocusManager.instance.primaryFocus?.unfocus();
              await Future.delayed(Duration.zero);
              if (provider.hasUnsavedChanges && provider.hasAdapter) {
                await provider.saveToAdapter(captureThumbnail: true);
              }
              if (!context.mounted) return;
              final navigator = Navigator.of(context);
              if (navigator.canPop()) {
                navigator.pop();
              } else {
                navigator.pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => const ShareableMapsGallery(),
                  ),
                );
              }
            },
          ),
        if (isMaps && caps.canManageLayers)
          _AppBarLabelAction(
            icon: Icons.layers_outlined,
            label: 'Layers',
            selected: provider.isSidebarVisible,
            tooltip: provider.isSidebarVisible ? 'Hide layers' : 'Show layers',
            onPressed: () => provider.toggleSidebar(),
          ),
        const SizedBox(width: 4),
        // Map tools
        if (showAdminTools) ...[
          _mapAwareAction(
            isMaps: isMaps,
            icon: Icons.undo,
            label: '',
            tooltip: 'Undo',
            onPressed: () {
              // TODO: Implement undo
            },
          ),
          _mapAwareAction(
            isMaps: isMaps,
            icon: Icons.redo,
            label: '',
            tooltip: 'Redo',
            onPressed: () {
              // TODO: Implement redo
            },
          ),
          const SizedBox(width: 8),
        ],
        // Work areas import toggle (admin only — hidden in Maps viewer mode)
        if (showAdminTools)
          _mapAwareAction(
            isMaps: isMaps,
            icon: Icons.webhook_rounded,
            label: 'Work areas Layer',
            tooltip: 'Import work areas',
            selected: provider.isWorkAreaPickerVisible,
            onPressed: () {
              provider.toggleWorkAreaPicker();
            },
          ),
        // Import button (admin only — hidden in Maps viewer mode)
        if (showAdminTools && caps.canImport)
          _mapAwareAction(
            isMaps: isMaps,
            icon: Icons.upload_file,
            label: 'Import',
            tooltip: 'Import KML/GPX',
            onPressed: () => MapEditorDialogs.showImportDialog(context),
          ),
        // Layers toggle — non-maps only; maps flavor uses a dedicated action above.
        if (!isMaps && caps.canManageLayers)
          _AppBarLabelAction(
            icon: Icons.layers_outlined,
            label: 'Layers',
            selected: provider.isSidebarVisible,
            tooltip: provider.isSidebarVisible ? 'Hide layers' : 'Show layers',
            onPressed: () => provider.toggleSidebar(),
          ),

        // Polygon draw toggle — draw polygon and save to unfinished work areas
        if (showAdminTools)
          _mapAwareAction(
            isMaps: isMaps,
            icon: Icons.pentagon_outlined,
            label: provider.drawingMode == DrawingMode.polygon &&
                    provider.isDrawingForUnfinished
                ? 'Cancel draw'
                : 'Draw Gaps',
            tooltip: provider.drawingMode == DrawingMode.polygon &&
                    provider.isDrawingForUnfinished
                ? 'Cancel polygon drawing'
                : 'Draw polygon (save to unfinished)',
            selected: provider.drawingMode == DrawingMode.polygon &&
                provider.isDrawingForUnfinished,
            onPressed: () {
              if (provider.drawingMode == DrawingMode.polygon &&
                  provider.isDrawingForUnfinished) {
                provider.cancelDrawing();
              } else {
                provider.startDrawingForUnfinished();
              }
            },
          ),

        // Cloud files — jump to the folder linked to this map, or fall back
        // to the month folder matching the map's creation date.
        if (showAdminTools && provider.adapter is FirestoreMapAdapter)
          _mapAwareAction(
            isMaps: isMaps,
            icon: Icons.folder_open,
            label: 'Files',
            tooltip: 'Open cloud files folder',
            onPressed: () => _openCloudFolder(context, provider),
          ),
        // Share link — copy a client-shareable URL to clipboard.
        if (showAdminTools && provider.adapter is FirestoreMapAdapter)
          _mapAwareAction(
            isMaps: isMaps,
            icon: Icons.share_outlined,
            label: 'Share',
            tooltip: 'Copy share link',
            onPressed: () => _copyShareLink(context, provider),
          ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildMapsTitle(ShareableMapProvider provider, bool isAuthenticated) {
    final mapName = provider.currentMap?.name.trim();
    final title = mapName != null && mapName.isNotEmpty ? mapName : 'CLM Maps';

    return Row(
      children: [
        Icon(
          Icons.map_outlined,
          color: isAuthenticated
              ? const Color(0xFF1967D2)
              : const Color(0xFF5F6368),
          size: 22,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF202124),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              Text(
                isAuthenticated ? 'Admin map editor' : 'Client map',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF5F6368),
                  fontSize: 11,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchTitle(
    ShareableMapProvider provider,
    List<({CustomPolygon polygon, String layerId, int index})> allPolygons,
  ) {
    return Row(
      children: [
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
            fieldViewBuilder:
                (context, textEditingController, focusNode, onFieldSubmitted) {
              _autocompleteController = textEditingController;
              _autocompleteFocusNode = focusNode;
              return TextField(
                controller: textEditingController,
                focusNode: focusNode,
                style: const TextStyle(
                  color: Color(0xFF202124),
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: 'Search work areas...',
                  hintStyle: const TextStyle(
                    color: Color(0xFF9AA0A6),
                    fontSize: 14,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 20,
                    color: Color(0xFF9AA0A6),
                  ),
                  suffixIcon: textEditingController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(
                            Icons.close,
                            size: 18,
                            color: Color(0xFF5F6368),
                          ),
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
                      color: Color(0xFF1967D2),
                      width: 1.5,
                    ),
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
              _autocompleteController?.clear();
              _autocompleteFocusNode?.unfocus();
            },
          ),
        ),
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
    );
  }

  Widget _mapAwareAction({
    required bool isMaps,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    String? tooltip,
    bool selected = false,
  }) {
    return _AppBarLabelAction(
      icon: icon,
      label: label,
      tooltip: tooltip,
      selected: selected,
      onPressed: onPressed,
    );
  }

  /// Resolve the folder path to open in the Cloud File Manager:
  /// prefer the map's linked [storageFolderPath]; otherwise fall back to
  /// `Distribution/<year>/<MMM yyyy>` derived from the map's [createdAt].
  String _resolveCloudFolderPath(ShareableMapProvider provider) {
    final map = provider.currentMap;
    final linked = map?.primaryCloudFolderPath;
    if (linked != null && linked.trim().isNotEmpty) {
      return linked.trim();
    }
    final created = map?.createdAt ?? DateTime.now();
    final year = created.year.toString();
    final month = DateFormat('MMM yyyy').format(created);
    return 'Distribution/$year/$month';
  }

  void _openCloudFolder(BuildContext context, ShareableMapProvider provider) {
    final path = _resolveCloudFolderPath(provider);
    final navigator = Navigator.of(context);
    navigator.push(
      MaterialPageRoute(
        builder: (_) => CloudFileManagerScreen(
          initialPath: path,
          onOpenInTrackEditor: (fileName, bytes, sourcePath) {
            // Close the cloud browser, then launch the Track Editor with
            // the file pre-loaded in Update mode. Without this handler the
            // default behaviour pops the route and returns data here,
            // which would leave the user sitting back on the map.
            final container =
                riverpod.ProviderScope.containerOf(navigator.context);
            navigator.pop();
            navigator.push(
              MaterialPageRoute(
                builder: (_) => const TrackEditorScreen(),
              ),
            );
            loadCloudFileIntoTrackEditor(
              container: container,
              fileName: fileName,
              bytes: bytes,
              sourcePath: sourcePath,
            );
          },
        ),
      ),
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

class _AppBarLabelAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool selected;

  const _AppBarLabelAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final foreground =
        selected ? const Color(0xFF1967D2) : const Color(0xFF5F6368);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: tooltip ?? label,
        child: TextButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            minimumSize: const Size(0, 40),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
    );
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
  static const bool _advancedMarkersEnabled = bool.fromEnvironment(
    'ENABLE_ADVANCED_MARKERS',
    defaultValue: false,
  );

  static const String _googleMapsWebMapId = String.fromEnvironment(
    'GOOGLE_MAPS_WEB_MAP_ID',
    defaultValue: '89c628d2bb3002712797ce42',
  );

  // Custom bitmap descriptors are owned by [MapBitmapCache] and shared
  // across every editor instance / hot-reload. We hold a reference here
  // so the rest of the widget code can read them synchronously without
  // touching the cache singleton on every build.
  final MapBitmapCache _bitmapCache = MapBitmapCache.instance;

  // Live camera position – updated on every onCameraMove so the info window
  // overlay can be reprojected synchronously on each frame.
  //
  // Stored in a ValueNotifier instead of plain state so that high-frequency
  // camera updates during pan/zoom don't trigger setState on the whole
  // GoogleMap subtree (which would re-run the marker clustering pass for
  // 12k+ waypoints every frame and freeze the UI). Marker rebuilds are
  // instead driven by [GoogleMap.onCameraIdle], which fires once when the
  // gesture settles. Overlays that need to track the camera continuously
  // (info-window anchor, style panel anchor) listen to this notifier via
  // ValueListenableBuilder.
  final ValueNotifier<CameraPosition?> _cameraNotifier =
      ValueNotifier<CameraPosition?>(null);
  CameraPosition? get _currentCamera => _cameraNotifier.value;

  // Debounce timer for [GoogleMap.onCameraIdle] — the idle event can fire
  // several times in rapid succession (especially with trackpad / multi-
  // touch gestures). Without coalescing, each fire triggers a full
  // setState() which rebuilds the marker set (including grid clustering
  // for 12k+ waypoint layers) and pushes thousands of marker objects
  // across the JS-interop boundary on web, freezing the page.
  Timer? _cameraIdleDebounce;

  // ── Large-layer cluster cache ─────────────────────────────────────────
  // `MarkerClusterer.clusterSync` is O(n) over every point in a layer and
  // is invoked from build(). Every provider notify (auto-save toggle,
  // info window open/close, drawing tick …) rebuilds the widget, so
  // without memoization the same 12k-point waypoint layer is re-clustered
  // dozens of times per second and its thousands of resulting Marker
  // objects are diff-ed across the google_maps_flutter_web JS bridge,
  // freezing the page. We cache the result per-layer keyed by the inputs
  // that actually affect the output; cache misses are unavoidable when
  // zoom/bounds/visibility/selection change.
  final Map<String, List<Marker>> _largeLayerMarkerCache = {};
  final Map<String, String> _largeLayerCacheKey = {};
  // Stable polygon and polyline set caches.
  // GoogleMap.didUpdateWidget compares polygon/polyline sets with !=
  // (Dart Set identity), so reusing the same object reference skips the
  // entire JS-bridge diff on unrelated provider notifies.
  Set<Polygon>? _stablePolygons;
  String? _stablePolygonsKey;
  Set<Polyline>? _stablePolylines;
  String? _stablePolylinesKey;
  // Last pointer-down position in local widget coordinates.
  // Used to anchor the info window at the tapped location for polygon/polyline.
  Offset? _lastPointerDown;
  // Cached map widget size – set inside LayoutBuilder each build.
  Size _mapSize = Size.zero;
  // Timestamp of the last info-window action button press. Used to guard
  // against GoogleMap.onTap firing concurrently on web (platform view
  // limitation where the underlying HTML element also receives the click).
  DateTime? _lastInfoWindowAction;

  // Selected preview work area while its info window is open.
  WorkArea? _previewWorkAreaForInfoWindow;

  // ── Hover tooltip state ────────────────────────────────────────────────
  /// Current mouse position in local coordinates (null when outside map).
  Offset? _hoverPosition;

  /// Data to display in the hover tooltip (null when not hovering a polygon).
  _HoverTooltipData? _hoverTooltipData;
  // Throttle: timestamp of last hover hit-test execution.
  DateTime? _lastHoverTime;

  bool get _useAdvancedMarkers =>
      kIsWeb && _advancedMarkersEnabled && _googleMapsWebMapId.isNotEmpty;

  Marker _buildMapMarker({
    required MarkerId markerId,
    required LatLng position,
    required BitmapDescriptor icon,
    Offset anchor = const Offset(0.5, 1.0),
    double alpha = 1.0,
    bool consumeTapEvents = false,
    bool draggable = false,
    bool visible = true,
    int zIndexInt = 0,
    InfoWindow infoWindow = InfoWindow.noText,
    VoidCallback? onTap,
    ValueChanged<LatLng>? onDrag,
    ValueChanged<LatLng>? onDragEnd,
  }) {
    if (_useAdvancedMarkers) {
      return AdvancedMarker(
        markerId: markerId,
        position: position,
        icon: icon,
        anchor: anchor,
        alpha: alpha,
        consumeTapEvents: consumeTapEvents,
        draggable: draggable,
        visible: visible,
        zIndex: zIndexInt,
        infoWindow: infoWindow,
        onTap: onTap,
        onDrag: onDrag,
        onDragEnd: onDragEnd,
      );
    }

    return Marker(
      markerId: markerId,
      position: position,
      icon: icon,
      anchor: anchor,
      alpha: alpha,
      consumeTapEvents: consumeTapEvents,
      draggable: draggable,
      visible: visible,
      zIndexInt: zIndexInt,
      infoWindow: infoWindow,
      onTap: onTap,
      onDrag: onDrag,
      onDragEnd: onDragEnd,
    );
  }

  BitmapDescriptor _fallbackMarkerIcon(Color color) {
    if (_useAdvancedMarkers) {
      return BitmapDescriptor.pinConfig(
        backgroundColor: color,
        borderColor: Colors.white,
        glyph: const CircleGlyph(color: Colors.white),
      );
    }
    return BitmapDescriptor.defaultMarkerWithHue(HSLColor.fromColor(color).hue);
  }

  @override
  void initState() {
    super.initState();
    _ensureBitmapsLoaded();
  }

  @override
  void dispose() {
    _cameraIdleDebounce?.cancel();
    _cameraIdleDebounce = null;
    _largeLayerMarkerCache.clear();
    _largeLayerCacheKey.clear();
    _cameraNotifier.dispose();
    super.dispose();
  }

  // ── Marker icon loading ────────────────────────────────────────────────

  /// Trigger the shared [MapBitmapCache] load. If the cache is already
  /// populated (this is not the first editor open of the session) the
  /// future resolves synchronously and no rebuild is needed.
  Future<void> _ensureBitmapsLoaded() async {
    if (_bitmapCache.isLoaded) return;
    await _bitmapCache.ensureLoaded();
    if (mounted) setState(() {});
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
      builder: (ctx) => _gestureAwareOverlay(
        ctx,
        child: AlertDialog(
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

    final cacheVertex = _bitmapCache.vertex;
    final cacheMidpoint = _bitmapCache.midpoint;
    final vertexIcon = cacheVertex ?? _fallbackMarkerIcon(Colors.blue);
    final midpointIcon = cacheMidpoint ?? _fallbackMarkerIcon(Colors.orange);
    debugPrint('[WASM-DEBUG] _buildEditingMarkers: editingPoints='
        '${editingPoints.length} '
        'cacheLoaded=${_bitmapCache.isLoaded} '
        'vertexIcon=${cacheVertex == null ? "FALLBACK" : "cached"} '
        'midpointIcon=${cacheMidpoint == null ? "FALLBACK" : "cached"}');

    final minPoints = provider.isEditingPolygon ? 3 : 2;

    for (int i = 0; i < editingPoints.length; i++) {
      markers.add(
        _buildMapMarker(
          markerId: MarkerId('vertex_$i'),
          position: editingPoints[i],
          icon: vertexIcon,
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
          _buildMapMarker(
            markerId: MarkerId('midpoint_$i'),
            position: midpoints[i],
            icon: midpointIcon,
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

    final cacheVertex = _bitmapCache.vertex;
    final cacheFirst = _bitmapCache.firstVertex;
    final normalIcon = cacheVertex ?? _fallbackMarkerIcon(Colors.blue);
    final firstIcon = canClose
      ? (cacheFirst ?? _fallbackMarkerIcon(Colors.green))
        : normalIcon;
    debugPrint('[WASM-DEBUG] _buildDrawingMarkers: points=${points.length} '
        'mode=${provider.drawingMode} canClose=$canClose '
        'cacheLoaded=${_bitmapCache.isLoaded} '
        'normalIcon=${cacheVertex == null ? "FALLBACK" : "cached"} '
        'firstIcon=${cacheFirst == null ? "FALLBACK" : "cached"}');

    return points.asMap().entries.map((entry) {
      final index = entry.key;
      final point = entry.value;
      final isFirst = index == 0;

      return _buildMapMarker(
        markerId: MarkerId('drawing_point_$index'),
        position: point,
        icon: isFirst ? firstIcon : normalIcon,
        anchor: const Offset(0.5, 0.5),
        zIndexInt: isFirst ? 1001 : 1000,
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
    _previewWorkAreaForInfoWindow = null;
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
  // ignore: unused_element
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

  /// Tracks whether the most recent call to [_markersForLayer] returned a
  /// cached list (true) or recomputed the markers (false). Read once per
  /// `expand` callback so build() can log how many layers were reused.
  bool _layerMarkerCacheReused = false;

  /// Build (or reuse) the [Marker] list for a single visible layer.
  ///
  /// We do NOT cluster and we do NOT cull by viewport — those two
  /// passes were O(n) over every point on every camera idle and were
  /// the direct cause of the page freeze when panning so far that
  /// everything fell outside the visible bounds (every point still had
  /// to be tested by `bounds.contains`). Instead we render every point
  /// of every visible layer directly and memoize the result per-layer
  /// on a key that does NOT include the camera, so panning/zooming
  /// returns the cached `List<Marker>` instantly without any work.
  ///
  /// Cache invalidates only when the layer's data identity changes —
  /// point count, visibility, draggable flag, or the currently selected
  /// element id (which affects the highlighted marker icon).
  List<Marker> _markersForLayer({
    required dynamic layer,
    required ShareableMapProvider provider,
    required bool isDraggable,
    required Map<PointCategory, BitmapDescriptor>? pointIcons,
    required Map<PointCategory, BitmapDescriptor>? waypointPointIcons,
  }) {
    final layerId = layer.id as String;
    final pointCount = (layer.points as List).length;
    final isVisible = layer.isVisible as bool;
    final selected = provider.selectedElementId ?? '';
    final isWaypoint = provider.isCloudWaypointsLayer(layerId);
    // Markers for hidden layers are still built (with visible: false) so
    // toggling visibility is a cheap native-visibility update on the JS
    // bridge rather than a mass add/remove of thousands of markers.
    final canDrag = isDraggable && isVisible;

    final key = '$pointCount|$isVisible|$canDrag|$selected|$isWaypoint';

    if (_largeLayerCacheKey[layerId] == key) {
      final cached = _largeLayerMarkerCache[layerId];
      if (cached != null) {
        _layerMarkerCacheReused = true;
        return cached;
      }
    }

    final renderSw = Stopwatch()..start();
    final markers = layer.getGoogleMapsMarkers(
      selectedElementId: provider.selectedElementId,
      onTap: (pointId) => _handleMarkerTap(context, provider, pointId),
      draggable: canDrag,
      onDragEnd: canDrag
          ? (pointId, newPos) => provider.moveMarker(pointId, newPos)
          : null,
      pointIcons: isWaypoint ? (waypointPointIcons ?? pointIcons) : pointIcons,
      useAdvancedMarkers: _useAdvancedMarkers,
      markerVisible: isVisible,
    ) as List<Marker>;

    debugPrint(
        '[MapView] rebuilt layer "$layerId" markers: $pointCount points -> '
        '${markers.length} markers in ${renderSw.elapsedMilliseconds}ms');

    _largeLayerCacheKey[layerId] = key;
    _largeLayerMarkerCache[layerId] = markers;
    _layerMarkerCacheReused = false;
    return markers;
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

  /// Closest distance from [p] to the line segment [a]→[b] in km.
  static double _distToSegmentKm(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    if (dx == 0 && dy == 0) return _haversineKm(p, a);
    final t =
        ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
            (dx * dx + dy * dy);
    final clamped = t.clamp(0.0, 1.0);
    return _haversineKm(
        p, LatLng(a.latitude + clamped * dy, a.longitude + clamped * dx));
  }

  /// Minimum distance from [p] to any segment of the polyline [pts] in km.
  static double _minDistToPolylineKm(LatLng p, List<LatLng> pts) {
    double best = double.infinity;
    for (int i = 0; i < pts.length - 1; i++) {
      final d = _distToSegmentKm(p, pts[i], pts[i + 1]);
      if (d < best) best = d;
    }
    return best;
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
    // Throttle polygon hit-testing to ~25 fps — avoids O(n·v) work on
    // every raw pointer-move event for maps with many complex polygons.
    final hoverNow = DateTime.now();
    if (_lastHoverTime != null &&
        hoverNow.difference(_lastHoverTime!).inMilliseconds < 40) {
      return;
    }
    _lastHoverTime = hoverNow;

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

    // Pre-watch overlay schedule data so Riverpod tracks the dependency on
    // every build, including cache-hit builds where the inner if-blocks skip.
    final overlaySchedule = (provider.isWorkAreaPickerVisible ||
            provider.showWorkAreasOverlay ||
            provider.showSuburbsOverlay)
        ? ref.watch(scheduleRiverpod)
        : null;
    final overlayWorkAreas = overlaySchedule?.workAreas ?? const <WorkArea>[];
    final overlaySuburbs = overlaySchedule?.workSuburbs ?? const <WorkSuburb>[];

    // Stable polygon set cache.
    // GoogleMap.didUpdateWidget uses != (Dart Set identity) so passing the
    // same object reference on unchanged builds skips the entire JS diff.
    final polyKeyBuf = StringBuffer()
      ..write(provider.selectedElementId ?? '_')
      ..write('|')
      ..write(provider.editingElementId ?? '_')
      ..write('|')
      ..write(provider.isEditingVertices)
      ..write('|')
      ..write(provider.isWorkAreaPickerVisible)
      ..write('|')
      ..write(provider.pickerWorkAreasVisible)
      ..write('|')
      ..write(provider.pickerSuburbsVisible)
      ..write('|')
      ..write(provider.showWorkAreasOverlay)
      ..write('|')
      ..write(provider.showSuburbsOverlay)
      ..write('|wa${overlayWorkAreas.length}|sub${overlaySuburbs.length}|');
    for (final wa in overlayWorkAreas) {
      polyKeyBuf.write(
        'wa:${wa.id}:${wa.polygonPoints.length}:${wa.color.toARGB32()};',
      );
    }
    for (final suburb in overlaySuburbs) {
      polyKeyBuf.write(
        'sub:${suburb.id}:${suburb.polygonPoints.length}:${suburb.color.toARGB32()};',
      );
    }
    for (final l in visibleLayers) {
      polyKeyBuf.write('${l.id}:${l.polygons.length}:');
      for (final polygon in l.polygons) {
        polyKeyBuf.write(
          '${polygon.id ?? polygon.name}:${polygon.points.length}:${polygon.color.toARGB32()};',
        );
      }
    }
    final polyKey = polyKeyBuf.toString();

    final Set<Polygon> polygons;
    if (polyKey == _stablePolygonsKey && _stablePolygons != null) {
      polygons = _stablePolygons!;
    } else {
      final polys = <Polygon>{
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
      // Preview work areas (import picker).
      if (provider.isWorkAreaPickerVisible && provider.pickerWorkAreasVisible) {
        for (final wa in overlayWorkAreas) {
          if (provider.isWorkAreaImported(wa.name)) continue;
          if (wa.polygonPoints.length < 3) continue;
          final color = wa.color;
          polys.add(Polygon(
            polygonId: PolygonId('preview_wa_${wa.name}'),
            points: wa.polygonPoints,
            strokeColor: color.withValues(alpha: 0.7),
            strokeWidth: 2,
            fillColor: color.withValues(alpha: 0.10),
            consumeTapEvents: true,
            onTap: () => _handlePreviewWorkAreaTap(context, provider, wa),
          ));
        }
      }
      // Preview suburbs (import picker).
      if (provider.isWorkAreaPickerVisible && provider.pickerSuburbsVisible) {
        for (final suburb in overlaySuburbs) {
          if (provider.isSuburbImported(suburb.name)) continue;
          if (suburb.polygonPoints.length < 3) continue;
          final color = suburb.color;
          polys.add(Polygon(
            polygonId: PolygonId('preview_suburb_${suburb.id}'),
            points: suburb.polygonPoints,
            strokeColor: color.withValues(alpha: 0.7),
            strokeWidth: 2,
            fillColor: color.withValues(alpha: 0.10),
            consumeTapEvents: true,
            onTap: () => _handleSuburbOverlayTap(context, provider, suburb),
          ));
        }
      }
      // Work Areas overlay.
      if (provider.showWorkAreasOverlay) {
        for (final wa in overlayWorkAreas) {
          if (wa.polygonPoints.length < 3) continue;
          final color = wa.color;
          polys.add(Polygon(
            polygonId: PolygonId('overlay_wa_${wa.name}'),
            points: wa.polygonPoints,
            strokeColor: color.withValues(alpha: 0.85),
            strokeWidth: 2,
            fillColor: color.withValues(alpha: 0.08),
            consumeTapEvents: true,
            onTap: () => _handleWorkAreaOverlayTap(context, provider, wa),
          ));
        }
      }
      // Work Suburbs overlay.
      if (provider.showSuburbsOverlay) {
        for (final suburb in overlaySuburbs) {
          if (suburb.polygonPoints.length < 3) continue;
          final color = suburb.color;
          polys.add(Polygon(
            polygonId: PolygonId('overlay_suburb_${suburb.id}'),
            points: suburb.polygonPoints,
            strokeColor: color.withValues(alpha: 0.85),
            strokeWidth: 2,
            fillColor: color.withValues(alpha: 0.08),
            consumeTapEvents: true,
            onTap: () => _handleSuburbOverlayTap(context, provider, suburb),
          ));
        }
      }
      polygons = polys;
      _stablePolygons = polys;
      _stablePolygonsKey = polyKey;
    }

    // Stable polyline set cache (same identity-equality trick as polygons).
    final lineKeyBuf = StringBuffer()
      ..write(provider.selectedElementId ?? '_')
      ..write('|')
      ..write(provider.editingElementId ?? '_')
      ..write('|')
      ..write(provider.isEditingVertices)
      ..write('|')
      ..write(provider.isDrawing)
      ..write('|')
      ..write(provider.drawingPoints.length)
      ..write('|')
      ..write(provider.isLassoSelectActive)
      ..write('|')
      ..write(provider.lassoPoints.length)
      ..write('|');
    for (final l in visibleLayers) {
      lineKeyBuf.write('${l.id}:${l.polylines.length},');
    }
    final lineKey = lineKeyBuf.toString();

    final Set<Polyline> polylines;
    if (lineKey == _stablePolylinesKey && _stablePolylines != null) {
      polylines = _stablePolylines!;
    } else {
      final lines = <Polyline>{
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
        if (provider.getDrawingPolyline() != null)
          provider.getDrawingPolyline()!,
        // Lasso-select preview: dashed orange polygon outline.
        if (provider.isLassoSelectActive && provider.lassoPoints.length >= 2)
          Polyline(
            polylineId: const PolylineId('lasso_preview'),
            points: [
              ...provider.lassoPoints,
              // Close the loop visually once we have ≥3 points.
              if (provider.lassoPoints.length >= 3) provider.lassoPoints.first,
            ],
            color: Colors.orange.withValues(alpha: 0.85),
            width: 3,
            patterns: [PatternItem.dash(16), PatternItem.gap(8)],
            geodesic: true,
          ),
      };
      polylines = lines;
      _stablePolylines = lines;
      _stablePolylinesKey = lineKey;
    }

    // Combine completed markers with drawing/editing markers
    final isMaps = FlavorConfig.instance.isMaps;
    final isAuthenticated = ref.watch(authRiverpod).isAuthenticated;
    final canEditInThisView =
        !isMaps || (isAuthenticated && !isMapsMobileViewer(context));
    final isDraggable = canEditInThisView &&
        !provider.capabilities.readOnly &&
        !provider.isDrawing &&
        !provider.isEditingVertices;
    final pointIcons = _bitmapCache.pointCategoryIcons;
    final waypointIcon = _bitmapCache.waypoint;
    // Build a special pointIcons map for the cloud waypoints layer
    // so that its generic markers use the letterbox bitmap.
    Map<PointCategory, BitmapDescriptor>? waypointPointIcons;
    if (waypointIcon != null) {
      waypointPointIcons = {
        if (pointIcons != null) ...pointIcons,
        PointCategory.generic: waypointIcon,
      };
    }

    // Viewport bounds and zoom are no longer used for marker rendering —
    // clustering and visible-bounds culling were causing the page to
    // freeze when panning large waypoint layers because every camera
    // movement re-ran an O(n) pass over 12k+ points. We now render
    // every visible layer's markers directly and rely on the per-layer
    // identity cache below to keep the resulting Set stable across
    // unrelated provider notifies (auto-save, info window, drawing, …).
    final currentZoom = _currentCamera?.zoom ?? map.defaultZoom;

    final markerSw = Stopwatch()..start();
    int totalRenderedMarkers = 0;
    int reusedLayers = 0;
    int rebuiltLayers = 0;

    final markers = <Marker>{
      if (!provider.isEditingVertices) ...[
        // Iterate ALL layers (visible + hidden) so the marker set stays
        // stable when toggling visibility. Hidden layers contribute
        // markers with visible:false so the JS bridge only diffs the
        // visibility property instead of removing/re-adding thousands
        // of markers — keeps the UI responsive for 15k+ waypoint layers.
        ...allLayersSorted.expand((layer) {
          final result = _markersForLayer(
            layer: layer,
            provider: provider,
            isDraggable: isDraggable,
            pointIcons: pointIcons,
            waypointPointIcons: waypointPointIcons,
          );
          totalRenderedMarkers += result.length;
          if (_layerMarkerCacheReused) {
            reusedLayers++;
          } else {
            rebuiltLayers++;
          }
          return result;
        }),
      ],
      ..._buildDrawingMarkers(context, provider),
      ..._buildEditingMarkers(context, provider),
    };

    if (markerSw.elapsedMilliseconds > 5 ||
        rebuiltLayers > 0 ||
        totalRenderedMarkers > 500) {
      debugPrint('[MapView] markers built in ${markerSw.elapsedMilliseconds}ms '
          '(total=$totalRenderedMarkers, reusedLayers=$reusedLayers, '
          'rebuiltLayers=$rebuiltLayers, zoom=${currentZoom.toStringAsFixed(1)})');
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final mapSize = Size(constraints.maxWidth, constraints.maxHeight);
        _mapSize = mapSize;

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
                  mapId: _useAdvancedMarkers ? _googleMapsWebMapId : null,
                  markerType: _useAdvancedMarkers
                      ? GoogleMapMarkerType.advancedMarker
                      : GoogleMapMarkerType.marker,
                  initialCameraPosition: CameraPosition(
                    target: map.defaultCenter,
                    zoom: map.defaultZoom,
                  ),
                  onMapCreated: (controller) {
                    provider.setMapController(controller);
                  },
                  // Update the live camera notifier on every move so overlays
                  // (info window / style panel) can reproject smoothly via
                  // ValueListenableBuilder — but DO NOT call setState here
                  // or the entire marker set (incl. 12k-point clustering)
                  // would rebuild every frame during pan/zoom.
                  onCameraMove: (pos) => _cameraNotifier.value = pos,
                  // No onCameraIdle handler: marker rendering no longer
                  // depends on the viewport, so panning/zooming does not
                  // need to trigger a rebuild. Info-window/style-panel
                  // overlays still track the camera continuously via the
                  // _cameraNotifier ValueListenable above.
                  webGestureHandling:
                      ref.watch(mapGestureRiverpod).gestureHandling,
                  onTap: (position) {
                    debugPrint('[MapTap] background tap at $position '
                        'infoOpen=${provider.infoWindowData?.elementId}');
                    // Guard: ignore map tap when user is interacting with
                    // a UI overlay (gestures disabled by MouseRegion/Listener).
                    if (ref.read(mapGestureRiverpod).gestureHandling ==
                        WebGestureHandling.none) {
                      debugPrint('[MapTap] BAIL — gestures disabled');
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
                      debugPrint('[MapTap] BAIL — recent info-window action');
                      return;
                    }
                    // Dismiss hover tooltip on tap
                    setState(() {
                      _hoverTooltipData = null;
                      _hoverPosition = null;
                    });
                    debugPrint(
                        '[MapTap] dismissing info window + handleMapTap');
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
                // Camera-driven overlays. Listening to the camera notifier
                // here means only this subtree (a few small Positioned
                // widgets) rebuilds on each camera move — the GoogleMap
                // and its 12k+ markers stay untouched.
                ValueListenableBuilder<CameraPosition?>(
                  valueListenable: _cameraNotifier,
                  builder: (context, cam, _) {
                    final infoScreen = iw != null && cam != null
                        ? _latLngToScreen(iw.anchor, cam, mapSize)
                        : null;
                    if (infoScreen == null) {
                      return const SizedBox.shrink();
                    }
                    return Stack(
                      children: [
                        if (provider.showStylePanel && canEditInThisView)
                          _MapStylePanel(screen: infoScreen),
                        _InfoWindowOverlay(
                          screen: infoScreen,
                          mapSize: mapSize,
                          data: iw!,
                          canEdit: canEditInThisView &&
                              !provider.capabilities.readOnly,
                          onDismiss: _dismissInfoWindow,
                          onStyle: canEditInThisView &&
                                  (iw.type == 'polygon' ||
                                      iw.type == 'polyline')
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
                          onAddToMap: canEditInThisView &&
                                  iw.type == 'preview_work_area'
                              ? () {
                                  _lastInfoWindowAction = DateTime.now();
                                  final selected =
                                      _previewWorkAreaForInfoWindow;
                                  if (selected != null) {
                                    provider.addWorkAreaToMap(selected);
                                    _dismissInfoWindow();
                                  }
                                }
                              : null,
                        ),
                      ],
                    );
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
    debugPrint('[WASM-DEBUG] _handleMapTap: '
        'pos=(${position.latitude.toStringAsFixed(5)},'
        '${position.longitude.toStringAsFixed(5)}) '
        'mode=${provider.drawingMode} '
        'isDrawing=${provider.isDrawing} '
        'isEditingVertices=${provider.isEditingVertices}');
    if (provider.isEditingVertices) {
      if (provider.shouldIgnoreNextTap()) {
        debugPrint(
            '[WASM-DEBUG] _handleMapTap BAIL — shouldIgnoreNextTap (editing)');
        return;
      }
      provider.saveVertexEditing();
      return;
    }
    if (provider.shouldIgnoreNextTap()) {
      debugPrint('[WASM-DEBUG] _handleMapTap BAIL — shouldIgnoreNextTap');
      return;
    }

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
        MapEditorDialogs.showElementNameDialog(context, provider);
        break;
      case DrawingMode.none:
        provider.selectElement('');
        break;
      case DrawingMode.edit:
        break;
      case DrawingMode.lassoSelect:
        // Accumulate lasso boundary points on each tap.
        provider.addLassoPoint(position);
        break;
    }
  }

  void _handleWorkAreaOverlayTap(
      BuildContext context, ShareableMapProvider provider, WorkArea wa) {
    if (ref.read(mapGestureRiverpod).gestureHandling ==
        WebGestureHandling.none) {
      return;
    }
    if (provider.infoWindowData != null) {
      _cycleElementsAtTap(context, provider);
      return;
    }
    final areaKm2 = _polygonAreaKm2(wa.polygonPoints);
    final perimeterKm = _pathLengthKm(wa.polygonPoints, closed: true);
    provider.openInfoWindow(InfoWindowData(
      elementId: 'overlay_wa_${wa.name}',
      layerId: '__overlay_work_areas__',
      title: wa.name,
      description: wa.description,
      subtitle: '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
      type: 'overlay_work_area',
      anchor: _tapAnchor(_centroid(wa.polygonPoints)),
      letterBoxEstimate: wa.letterBoxEstimate,
    ));
  }

  void _handleSuburbOverlayTap(
      BuildContext context, ShareableMapProvider provider, WorkSuburb suburb) {
    if (ref.read(mapGestureRiverpod).gestureHandling ==
        WebGestureHandling.none) {
      return;
    }
    if (provider.infoWindowData != null) {
      _cycleElementsAtTap(context, provider);
      return;
    }
    final areaKm2 = _polygonAreaKm2(suburb.polygonPoints);
    final perimeterKm = _pathLengthKm(suburb.polygonPoints, closed: true);
    provider.openInfoWindow(InfoWindowData(
      elementId: 'overlay_suburb_${suburb.id}',
      layerId: '__overlay_suburbs__',
      title: suburb.name,
      description: suburb.description,
      subtitle: '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
      type: 'overlay_suburb',
      anchor: _tapAnchor(_centroid(suburb.polygonPoints)),
      letterBoxEstimate: suburb.letterBoxEstimate,
    ));
  }

  /// True when the user is holding Shift, Ctrl, or Meta (Cmd on macOS) —
  /// triggers "cycle through overlapping elements" on tap.
  bool get _isCycleModifierHeld {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shift) ||
        keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight) ||
        keys.contains(LogicalKeyboardKey.control) ||
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.meta) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
  }

  /// When Shift/Ctrl/Meta is held and the user taps any element, collect ALL
  /// polygons, polylines and markers at the tap screen position and open the
  /// info window for the next element relative to the currently selected one.
  void _cycleElementsAtTap(
      BuildContext context, ShareableMapProvider provider) {
    if (_lastPointerDown == null ||
        _currentCamera == null ||
        _mapSize == Size.zero) {
      debugPrint('[Cycle] BAIL — lastPointerDown=$_lastPointerDown '
          'camera=$_currentCamera mapSize=$_mapSize');
      return;
    }

    final tapLatLng =
        _screenToLatLng(_lastPointerDown!, _currentCamera!, _mapSize);

    // Tap tolerance: ~20 screen pixels converted to km at current zoom.
    final zoom = _currentCamera!.zoom;
    final degsPerPx = 360.0 / (256.0 * math.pow(2, zoom));
    final threshKm = 20.0 * degsPerPx * 111.32;

    debugPrint('[Cycle] tapScreen=$_lastPointerDown '
        'tapLatLng=(${tapLatLng.latitude.toStringAsFixed(5)},'
        '${tapLatLng.longitude.toStringAsFixed(5)}) '
        'zoom=${zoom.toStringAsFixed(1)} threshKm=${threshKm.toStringAsFixed(4)}');

    // Collect all elements at the tap position.
    // Order: markers (top) → polylines → polygons (bottom).
    // Within each type, higher-order layers come first.
    final visibleLayers = provider.layers.where((l) => l.isVisible).toList()
      ..sort((a, b) => b.order.compareTo(a.order));

    debugPrint('[Cycle] visibleLayers=${visibleLayers.map((l) => '\'${l.id}\' '
        '(${l.polygons.length}poly ${l.polylines.length}line '
        '${l.points.length}pt)').join(', ')}');

    final hits = <({String elementId, String layerId, String type})>[];

    for (final layer in visibleLayers) {
      for (final pt in layer.points) {
        if (_haversineKm(tapLatLng, pt.position) <= threshKm) {
          hits.add((elementId: pt.id, layerId: layer.id, type: 'point'));
        }
      }
    }
    for (final layer in visibleLayers) {
      for (final pl in layer.polylines) {
        if (pl.points.length >= 2 &&
            _minDistToPolylineKm(tapLatLng, pl.points) <= threshKm) {
          hits.add((elementId: pl.id, layerId: layer.id, type: 'polyline'));
        }
      }
    }
    for (final layer in visibleLayers) {
      for (int i = 0; i < layer.polygons.length; i++) {
        final poly = layer.polygons[i];
        if (poly.points.length >= 3 &&
            _pointInPolygon(tapLatLng, poly.points)) {
          hits.add((
            elementId: '${layer.id}_polygon_$i',
            layerId: layer.id,
            type: 'polygon',
          ));
        }
      }
    }

    // Overlay work areas (shown when showWorkAreasOverlay is active).
    if (provider.showWorkAreasOverlay) {
      final schedule = ref.read(scheduleRiverpod);
      for (final wa in schedule.workAreas) {
        if (wa.polygonPoints.length >= 3 &&
            _pointInPolygon(tapLatLng, wa.polygonPoints)) {
          hits.add((
            elementId: 'overlay_wa_${wa.name}',
            layerId: '__overlay_work_areas__',
            type: 'overlay_work_area',
          ));
        }
      }
    }

    // Overlay suburbs (shown when showSuburbsOverlay is active).
    if (provider.showSuburbsOverlay) {
      final schedule = ref.read(scheduleRiverpod);
      for (final suburb in schedule.workSuburbs) {
        if (suburb.polygonPoints.length >= 3 &&
            _pointInPolygon(tapLatLng, suburb.polygonPoints)) {
          hits.add((
            elementId: 'overlay_suburb_${suburb.id}',
            layerId: '__overlay_suburbs__',
            type: 'overlay_suburb',
          ));
        }
      }
    }

    // Preview work areas (shown when the work area picker is open).
    if (provider.isWorkAreaPickerVisible) {
      final schedule = ref.read(scheduleRiverpod);
      for (final wa in schedule.workAreas) {
        if (provider.isWorkAreaImported(wa.name)) continue;
        if (wa.polygonPoints.length >= 3 &&
            _pointInPolygon(tapLatLng, wa.polygonPoints)) {
          hits.add((
            elementId: 'preview_wa_${wa.name}',
            layerId: '__preview_work_areas__',
            type: 'preview_work_area',
          ));
        }
      }
    }

    debugPrint('[Cycle] hits(${hits.length}): '
        '${hits.map((h) => '${h.type}:${h.elementId}').join(', ')}');

    if (hits.isEmpty) {
      debugPrint('[Cycle] BAIL — no hits at tap point');
      return;
    }

    // Advance past the currently selected element, wrapping around.
    final currentId = provider.selectedElementId ?? '';
    final currentIdx = hits.indexWhere((h) => h.elementId == currentId);
    final nextIdx = (currentIdx + 1) % hits.length;
    final hit = hits[nextIdx];

    debugPrint('[Cycle] currentId=\'$currentId\' currentIdx=$currentIdx '
        '→ nextIdx=$nextIdx hit=${hit.type}:${hit.elementId}');

    if (hit.type == 'polygon') {
      final match = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(hit.elementId);
      if (match == null) return;
      final layer =
          provider.layers.where((l) => l.id == hit.layerId).firstOrNull;
      final idx = int.parse(match.group(2)!);
      if (layer == null || idx >= layer.polygons.length) return;
      final polygon = layer.polygons[idx];
      final areaKm2 = _polygonAreaKm2(polygon.points);
      final perimeterKm = _pathLengthKm(polygon.points, closed: true);
      provider.openInfoWindow(InfoWindowData(
        elementId: hit.elementId,
        layerId: hit.layerId,
        title: polygon.name.isNotEmpty ? polygon.name : 'Unnamed Polygon',
        description: polygon.description,
        subtitle: '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
        type: 'polygon',
        anchor: _tapAnchor(_centroid(polygon.points)),
        letterBoxEstimate: polygon.letterBoxEstimate,
      ));
    } else if (hit.type == 'polyline') {
      final layer =
          provider.layers.where((l) => l.id == hit.layerId).firstOrNull;
      final found =
          layer?.polylines.where((p) => p.id == hit.elementId).firstOrNull;
      if (found == null) return;
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
        subtitle = _fmtKm(_pathLengthKm(found.points));
      }
      provider.openInfoWindow(InfoWindowData(
        elementId: hit.elementId,
        layerId: hit.layerId,
        title: found.name.isNotEmpty ? found.name : 'Unnamed Polyline',
        description: found.description,
        subtitle: subtitle,
        type: 'polyline',
        anchor: _tapAnchor(_centroid(found.points)),
      ));
    } else if (hit.type == 'point') {
      final layer =
          provider.layers.where((l) => l.id == hit.layerId).firstOrNull;
      final found =
          layer?.points.where((p) => p.id == hit.elementId).firstOrNull;
      if (found == null) return;
      provider.openInfoWindow(InfoWindowData(
        elementId: hit.elementId,
        layerId: hit.layerId,
        title: found.name.isNotEmpty ? found.name : 'Unnamed Point',
        description: found.description,
        subtitle: '',
        type: 'point',
        anchor: found.position,
      ));
    } else if (hit.type == 'overlay_work_area') {
      final schedule = ref.read(scheduleRiverpod);
      final wa = schedule.workAreas
          .where((w) => 'overlay_wa_${w.name}' == hit.elementId)
          .firstOrNull;
      if (wa == null) return;
      final areaKm2 = _polygonAreaKm2(wa.polygonPoints);
      final perimeterKm = _pathLengthKm(wa.polygonPoints, closed: true);
      provider.openInfoWindow(InfoWindowData(
        elementId: hit.elementId,
        layerId: hit.layerId,
        title: wa.name,
        description: wa.description,
        subtitle: '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
        type: 'overlay_work_area',
        anchor: _tapAnchor(_centroid(wa.polygonPoints)),
        letterBoxEstimate: wa.letterBoxEstimate,
      ));
    } else if (hit.type == 'overlay_suburb') {
      final schedule = ref.read(scheduleRiverpod);
      final suburb = schedule.workSuburbs
          .where((s) => 'overlay_suburb_${s.id}' == hit.elementId)
          .firstOrNull;
      if (suburb == null) return;
      final areaKm2 = _polygonAreaKm2(suburb.polygonPoints);
      final perimeterKm = _pathLengthKm(suburb.polygonPoints, closed: true);
      provider.openInfoWindow(InfoWindowData(
        elementId: hit.elementId,
        layerId: hit.layerId,
        title: suburb.name,
        description: suburb.description,
        subtitle: '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
        type: 'overlay_suburb',
        anchor: _tapAnchor(_centroid(suburb.polygonPoints)),
        letterBoxEstimate: suburb.letterBoxEstimate,
      ));
    } else if (hit.type == 'preview_work_area') {
      final schedule = ref.read(scheduleRiverpod);
      final wa = schedule.workAreas
          .where((w) => 'preview_wa_${w.name}' == hit.elementId)
          .firstOrNull;
      if (wa == null) return;
      final areaKm2 = _polygonAreaKm2(wa.polygonPoints);
      final perimeterKm = _pathLengthKm(wa.polygonPoints, closed: true);
      setState(() => _previewWorkAreaForInfoWindow = wa);
      provider.openInfoWindow(InfoWindowData(
        elementId: hit.elementId,
        layerId: hit.layerId,
        title: wa.name,
        description: wa.description,
        subtitle: '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
        type: 'preview_work_area',
        anchor: _tapAnchor(_centroid(wa.polygonPoints)),
        letterBoxEstimate: wa.letterBoxEstimate,
      ));
    }
  }

  Future<void> _handlePolygonTap(BuildContext context,
      ShareableMapProvider provider, String polygonId) async {
    debugPrint('[PolyTap] polygonId=$polygonId '
        'gestureHandling=${ref.read(mapGestureRiverpod).gestureHandling} '
        'isDrawing=${provider.isDrawing} '
        'isEditing=${provider.isEditingVertices} '
        'isCycleMod=$_isCycleModifierHeld '
        'infoOpen=${provider.infoWindowData?.elementId}');
    // Ignore element taps when gestures are disabled (user is over a UI overlay)
    if (ref.read(mapGestureRiverpod).gestureHandling ==
        WebGestureHandling.none) {
      debugPrint('[PolyTap] BAIL — gestures disabled');
      return;
    }
    if (provider.isDrawing || provider.isEditingVertices) return;
    // Shift/Ctrl/Meta+click: cycle through overlapping elements.
    if (_isCycleModifierHeld) {
      debugPrint('[PolyTap] cycleModifier held → cycling');
      _dismissInfoWindow();
      _cycleElementsAtTap(context, provider);
      return;
    }
    // Re-tapping while an info window is open cycles to the next overlapping
    // element rather than closing — lets the user reach polygons below.
    if (provider.infoWindowData != null) {
      debugPrint('[PolyTap] infoWindow open → cycling');
      _cycleElementsAtTap(context, provider);
      return;
    }
    debugPrint('[PolyTap] opening info window for $polygonId');

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
  /// mode. Opens the map info window with Add/Cancel actions.
  void _handlePreviewWorkAreaTap(
      BuildContext context, ShareableMapProvider provider, WorkArea wa) {
    if (provider.shouldIgnoreNextTap()) return;
    if (ref.read(mapGestureRiverpod).gestureHandling ==
        WebGestureHandling.none) {
      return;
    }
    if (provider.infoWindowData != null) {
      _cycleElementsAtTap(context, provider);
      return;
    }

    final areaKm2 = _polygonAreaKm2(wa.polygonPoints);
    final perimeterKm = _pathLengthKm(wa.polygonPoints, closed: true);
    setState(() {
      _previewWorkAreaForInfoWindow = wa;
    });

    provider.openInfoWindow(InfoWindowData(
      elementId: 'preview_wa_${wa.name}',
      layerId: '__preview_work_areas__',
      title: wa.name,
      description: wa.description,
      subtitle: '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}',
      type: 'preview_work_area',
      anchor: _tapAnchor(_centroid(wa.polygonPoints)),
      letterBoxEstimate: wa.letterBoxEstimate,
    ));
  }

  void _handlePolylineTap(
      BuildContext context, ShareableMapProvider provider, String polylineId) {
    if (ref.read(mapGestureRiverpod).gestureHandling ==
        WebGestureHandling.none) {
      return;
    }
    if (provider.isDrawing || provider.isEditingVertices) return;
    // Shift/Ctrl/Meta+click: cycle through overlapping elements.
    if (_isCycleModifierHeld) {
      _dismissInfoWindow();
      _cycleElementsAtTap(context, provider);
      return;
    }
    // Re-tapping while an info window is open cycles to next overlapping element.
    if (provider.infoWindowData != null) {
      _cycleElementsAtTap(context, provider);
      return;
    }

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
    // Shift/Ctrl/Meta+click: cycle through overlapping elements.
    if (_isCycleModifierHeld) {
      _dismissInfoWindow();
      _cycleElementsAtTap(context, provider);
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

/// Sidebar widget with layer management.
///
/// In the Maps standalone flavor, the sidebar is hidden by default on narrow
/// screens (mobile) and the user can toggle it with the leading app-bar button.
class MapSidebarWidget extends riverpod.ConsumerStatefulWidget {
  const MapSidebarWidget({super.key});

  @override
  riverpod.ConsumerState<MapSidebarWidget> createState() =>
      _MapSidebarWidgetState();
}

class _MapSidebarWidgetState extends riverpod.ConsumerState<MapSidebarWidget> {
  @override
  void initState() {
    super.initState();
    // On the first frame, auto-hide the sidebar when running as the Maps
    // standalone flavor on a narrow screen so mobile users get a clean
    // full-screen map view by default (they can still open it via the
    // leading toggle button).
    if (FlavorConfig.instance.isMaps) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final isMobile =
            MediaQuery.sizeOf(context).width < _mapsMobileBreakpoint;
        if (isMobile) {
          ref.read(shareableMapRiverpod).setSidebarVisible(false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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

/// Left sidebar for the work-suburbs editor: table of polygons with name + estimate.
class _WorkSuburbsTableSidebar extends riverpod.ConsumerWidget {
  const _WorkSuburbsTableSidebar();

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
          child: const WorkSuburbsTablePanel(),
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

    final isLasso = provider.drawingMode == DrawingMode.lassoSelect;
    // Lasso mode tracks its own point list; regular drawing uses drawingPoints.
    final pointCount =
        isLasso ? provider.lassoPoints.length : provider.drawingPoints.length;
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
                        color:
                            isLasso ? Colors.orange : const Color(0xFF1967D2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isLasso
                            ? 'Lasso Select'
                            : 'Drawing ${_getDrawingModeLabel(provider.drawingMode)}',
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
                          color: isLasso
                              ? Colors.orange.withValues(alpha: 0.12)
                              : const Color(0xFFE8F0FE),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$pointCount ${pointCount == 1 ? 'point' : 'points'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: isLasso
                                ? Colors.orange.shade800
                                : const Color(0xFF1967D2),
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
                                if (isLasso) {
                                  provider.removeLastLassoPoint();
                                } else {
                                  provider.removeLastDrawingPoint();
                                  provider.markIgnoreNextTap();
                                }
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
                        onPressed: () {
                          if (isLasso) {
                            provider.cancelLassoSelect();
                          } else {
                            provider.cancelDrawing();
                          }
                        },
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
                                if (isLasso) {
                                  // Perform the lasso selection — find all
                                  // work areas (and/or suburbs, depending on
                                  // which picker layers are visible) whose
                                  // centroid falls inside the drawn polygon.
                                  final workAreas =
                                      ref.read(scheduleRiverpod).workAreas;
                                  final suburbs =
                                      ref.read(scheduleRiverpod).workSuburbs;

                                  int addedCount = 0;

                                  if (provider.pickerWorkAreasVisible) {
                                    final matched =
                                        provider.completeLassoSelect(workAreas);
                                    if (matched.isNotEmpty) {
                                      provider.addWorkAreasToMap(matched);
                                      addedCount += matched.length;
                                    }
                                  }

                                  if (provider.pickerSuburbsVisible) {
                                    final matchedSuburbs = provider
                                        .completeLassoSelectSuburbs(suburbs);
                                    if (matchedSuburbs.isNotEmpty) {
                                      provider.addSuburbsToMap(matchedSuburbs);
                                      addedCount += matchedSuburbs.length;
                                    }
                                  }

                                  provider.finishLassoSelect();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(addedCount == 0
                                          ? 'No areas found inside the lasso'
                                          : 'Added $addedCount ${addedCount == 1 ? 'area' : 'areas'}'),
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                                } else {
                                  // Regular polygon/polyline/point completion.
                                  provider.setDialogOpen(true);
                                  MapEditorDialogs.showElementNameDialog(
                                          context, provider)
                                      .then((_) {
                                    provider.setDialogOpen(false);
                                  });
                                }
                              }
                            : null,
                        icon: Icon(isLasso ? Icons.gesture : Icons.check,
                            size: 18),
                        label: Text(isLasso ? 'Select' : 'Complete'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              isLasso ? Colors.orange : const Color(0xFF1967D2),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFE8EAED),
                          disabledForegroundColor: const Color(0xFF80868B),
                        ),
                      ),
                    ],
                  ),
                  // Hint text
                  if (!canComplete)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        isLasso
                            ? 'Tap the map to draw the lasso boundary (need ${3 - pointCount} more ${(3 - pointCount) == 1 ? 'point' : 'points'})'
                            : _getDrawingHint(provider.drawingMode, pointCount),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF5F6368),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  // Progress indicator for polygons and polylines (not lasso)
                  if (!isLasso &&
                      (provider.drawingMode == DrawingMode.polygon ||
                          provider.drawingMode == DrawingMode.polyline))
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
    if (provider.drawingMode == DrawingMode.lassoSelect) {
      return provider.lassoPoints.length >= 3;
    }
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
      case DrawingMode.lassoSelect:
        return Icons.gesture;
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

Widget _gestureAwareOverlay(BuildContext context, {required Widget child}) {
  final gestureProvider =
      riverpod.ProviderScope.containerOf(context).read(mapGestureRiverpod);
  return MouseRegion(
    onEnter: (_) => gestureProvider.disableMapGestures(),
    onExit: (_) => gestureProvider.enableMapGestures(),
    child: child,
  );
}

/// Utility class for showing various map editor dialogs
class MapEditorDialogs {
  MapEditorDialogs._();

  static void showCreateMapDialog(BuildContext context) {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => _gestureAwareOverlay(
        context,
        child: AlertDialog(
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
      ),
    );
  }

  static void showImportDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) =>
          _gestureAwareOverlay(context, child: const MapImportDialog()),
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
    // When drawing for unfinished work areas, show the dedicated simpler dialog.
    if (provider.isDrawingForUnfinished) {
      return _showUnfinishedWorkAreaDialog(context, provider);
    }

    final nameController = TextEditingController();
    final descController = TextEditingController();
    final isPoint = provider.drawingMode == DrawingMode.point;
    PointCategory selectedCategory = PointCategory.generic;

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _gestureAwareOverlay(
        dialogContext,
        child: StatefulBuilder(
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
      ),
    );
  }

  /// Simplified dialog shown when drawing a polygon via the app-bar
  /// "draw to unfinished" button. Asks for polygon name and client name with
  /// autocomplete suggestions (matching the track editor UX) and also shows
  /// overlapping existing work areas. Saves to the unfinished work areas list.
  static Future<void> _showUnfinishedWorkAreaDialog(
      BuildContext context, ShareableMapProvider provider) {
    final nameController = TextEditingController();
    final clientController = TextEditingController();

    final container = riverpod.ProviderScope.containerOf(context);
    final scheduleProvider = container.read(scheduleRiverpod);
    final workAreas = scheduleProvider.workAreas;
    final drawingPoints = List<LatLng>.from(provider.drawingPoints);

    // Overlap: existing work areas that contain any drawing vertex.
    final overlapping = <String>[];
    for (final wa in workAreas) {
      if (wa.polygonPoints.isEmpty) continue;
      for (final dp in drawingPoints) {
        if (_pointInPoly(dp, wa.polygonPoints)) {
          overlapping.add(wa.name);
          break;
        }
      }
    }

    // Client suggestions from all jobs.
    final clientSuggestions = <String>{};
    for (final job in scheduleProvider.jobs) {
      for (final c in job.clients) {
        if (c.isNotEmpty) clientSuggestions.add(c);
      }
    }
    final sortedClients = clientSuggestions.toList()..sort();

    // Work area name suggestions for polygon name field.
    final workAreaNames = workAreas
        .map((wa) => wa.name)
        .where((n) => n.isNotEmpty)
        .toList()
      ..sort();

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _gestureAwareOverlay(
        dialogContext,
        child: AlertDialog(
          title: const Text('Unfinished Area', style: TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Autocomplete<String>(
                  optionsBuilder: (textEditingValue) {
                    if (textEditingValue.text.isEmpty) return workAreaNames;
                    final q = textEditingValue.text.toLowerCase();
                    return workAreaNames
                        .where((n) => n.toLowerCase().contains(q));
                  },
                  fieldViewBuilder: (ctx, controller, focusNode, onSubmitted) {
                    controller.addListener(() {
                      if (nameController.text != controller.text) {
                        nameController.text = controller.text;
                      }
                    });
                    nameController.addListener(() {
                      if (controller.text != nameController.text) {
                        controller.text = nameController.text;
                      }
                    });
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Polygon Name',
                        hintText: 'e.g. Block A, Zone 3',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    );
                  },
                  onSelected: (val) => nameController.text = val,
                ),
                const SizedBox(height: 12),
                Autocomplete<String>(
                  optionsBuilder: (textEditingValue) {
                    if (textEditingValue.text.isEmpty) return sortedClients;
                    final q = textEditingValue.text.toLowerCase();
                    return sortedClients
                        .where((c) => c.toLowerCase().contains(q));
                  },
                  fieldViewBuilder: (ctx, controller, focusNode, onSubmitted) {
                    clientController.addListener(() {
                      if (controller.text != clientController.text) {
                        controller.text = clientController.text;
                      }
                    });
                    controller.addListener(() {
                      if (clientController.text != controller.text) {
                        clientController.text = controller.text;
                      }
                    });
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        labelText: 'Client Name',
                        hintText: 'Type or select from list',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    );
                  },
                  onSelected: (val) => clientController.text = val,
                ),
                if (overlapping.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.teal.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.layers,
                                size: 14, color: Colors.teal.shade700),
                            const SizedBox(width: 6),
                            Text(
                              'Overlapping Work Areas',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.teal.shade700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ...overlapping.map((name) => Padding(
                              padding: const EdgeInsets.only(left: 20, top: 2),
                              child: Text('• $name',
                                  style: const TextStyle(fontSize: 11)),
                            )),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '${drawingPoints.length} vertices drawn',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                provider.cancelDrawing();
                Navigator.pop(dialogContext);
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final clientName = clientController.text.trim();

                provider.completeDrawing(name: name);

                if (drawingPoints.length >= 3) {
                  final customPoly = CustomPolygon(
                    name: name,
                    description: clientName,
                    points: drawingPoints,
                    color: Colors.indigo.shade600,
                  );
                  container.read(unfinishedWorkAreasRiverpod).addItem(
                    clients: clientName.isNotEmpty ? [clientName] : const [],
                    workingAreas: [name],
                    workMaps: [customPoly],
                  );
                }

                Navigator.pop(dialogContext);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  /// Ray-casting point-in-polygon test (local helper for the unfinished
  /// work area dialog overlap detection).
  static bool _pointInPoly(LatLng point, List<LatLng> polygon) {
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
  final bool canEdit;
  final VoidCallback onDismiss;

  /// Called when the style/paint-bucket button is tapped (fill color, stroke).
  final VoidCallback? onStyle;

  /// Called when the edit-vertices (pencil) button is tapped.
  final VoidCallback onEditVertices;

  /// Called when the camera/photo button is tapped.
  final VoidCallback? onPhoto;

  /// Called when the delete button is confirmed.
  final VoidCallback onDelete;

  /// Called for preview work-area windows to add the selected area to map.
  final VoidCallback? onAddToMap;

  final Offset screen;

  /// Size of the parent Stack (map widget). Used to correctly position the
  /// Positioned widget so Flutter's platform-view pointer-event blocker covers
  /// the actual card area (not just the untranslated layout rect).
  final Size mapSize;

  const _InfoWindowOverlay({
    required this.screen,
    required this.mapSize,
    required this.data,
    required this.canEdit,
    required this.onDismiss,
    required this.onStyle,
    required this.onEditVertices,
    required this.onPhoto,
    required this.onDelete,
    this.onAddToMap,
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

  late TextEditingController _estimateController;
  late FocusNode _estimateFocusNode;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.data.title);
    _titleFocusNode = FocusNode();
    _titleFocusNode.addListener(_onFocusChanged);
    _estimateController = TextEditingController(
      text: widget.data.letterBoxEstimate > 0
          ? widget.data.letterBoxEstimate.toString()
          : '',
    );
    _estimateFocusNode = FocusNode();
    _estimateFocusNode.addListener(_onEstimateFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _InfoWindowOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update controller text if the data changed externally (different element)
    if (oldWidget.data.elementId != widget.data.elementId) {
      _titleController.text = widget.data.title;
      _isEditingTitle = false;
      _estimateController.text = widget.data.letterBoxEstimate > 0
          ? widget.data.letterBoxEstimate.toString()
          : '';
    } else if (oldWidget.data.letterBoxEstimate !=
            widget.data.letterBoxEstimate &&
        !_estimateFocusNode.hasFocus) {
      _estimateController.text = widget.data.letterBoxEstimate > 0
          ? widget.data.letterBoxEstimate.toString()
          : '';
    }
  }

  @override
  void dispose() {
    _titleFocusNode.removeListener(_onFocusChanged);
    _titleFocusNode.dispose();
    _titleController.dispose();
    _estimateFocusNode.removeListener(_onEstimateFocusChanged);
    _estimateFocusNode.dispose();
    _estimateController.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_titleFocusNode.hasFocus && _isEditingTitle) {
      _commitTitle();
    }
  }

  void _onEstimateFocusChanged() {
    if (!_estimateFocusNode.hasFocus) {
      _commitEstimate();
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

  /// Parse the estimate text field and persist it on the underlying polygon
  /// via the provider. Only applies to polygon-type info windows.
  void _commitEstimate() {
    if (widget.data.type != 'polygon') return;
    final text = _estimateController.text.trim();
    final newVal = text.isEmpty ? 0 : int.tryParse(text);
    if (newVal == null) {
      // Invalid input — revert.
      _estimateController.text = widget.data.letterBoxEstimate > 0
          ? widget.data.letterBoxEstimate.toString()
          : '';
      return;
    }
    if (newVal == widget.data.letterBoxEstimate) return;

    final match =
        RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(widget.data.elementId);
    if (match == null) return;
    final layerId = match.group(1)!;
    final idx = int.parse(match.group(2)!);

    final provider = ref.read(shareableMapRiverpod);
    final layer = provider.layers.where((l) => l.id == layerId).firstOrNull;
    if (layer == null || idx >= layer.polygons.length) return;

    final updated = layer.polygons[idx].copyWith(letterBoxEstimate: newVal);
    provider.updatePolygon(layer, idx, updated);
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
    final provider = ref.watch(shareableMapRiverpod);
    final letterBoxesReached = data.type == 'polygon'
        ? provider.letterBoxesReachedForPolygon(data.layerId, data.elementId)
        : null;
    final hasSubtitle = data.subtitle.isNotEmpty;
    final hasDesc = data.description.isNotEmpty;
    final isShapeable = data.type == 'polygon' || data.type == 'polyline';
    final isPreviewWorkArea = data.type == 'preview_work_area';

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
                      child: _isEditingTitle && !isPreviewWorkArea
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
                              onTap: isPreviewWorkArea
                                  ? null
                                  : () {
                                      setState(() => _isEditingTitle = true);
                                      // Request focus after the frame so the
                                      // TextField is mounted.
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                        _titleFocusNode.requestFocus();
                                        _titleController.selection =
                                            TextSelection(
                                          baseOffset: 0,
                                          extentOffset:
                                              _titleController.text.length,
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
                      onTap: () {
                        ref.read(shareableMapRiverpod).markIgnoreNextTap();
                        widget.onDismiss();
                      },
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
            if (widget.canEdit && data.type == 'point') _buildCategoryRow(data),

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
                  data.type,
                  data.subtitle,
                  data.letterBoxEstimate,
                  letterBoxesReached,
                ),
              ),
            ],

            // ── Action buttons ─────────────────────────────────────
            if (widget.canEdit) ...[
              const Divider(height: 1, thickness: 1, color: Color(0xFFE8EAED)),
              SizedBox(
                height: 42,
                child: isPreviewWorkArea
                    ? _buildPreviewActionsRow(context)
                    : _buildActionsRow(context, isShapeable),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewActionsRow(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: MouseRegion(
            onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
            onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
            child: TextButton(
              onPressed: () {
                // Guard against web tap-through to underlying preview polygon.
                ref.read(shareableMapRiverpod).markIgnoreNextTap();
                widget.onDismiss();
              },
              child: const Text('Cancel'),
            ),
          ),
        ),
        Container(width: 1, height: 24, color: const Color(0xFFE8EAED)),
        Expanded(
          child: MouseRegion(
            onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
            onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
            child: FilledButton.icon(
              onPressed: () {
                // Guard against web tap-through to underlying preview polygon.
                ref.read(shareableMapRiverpod).markIgnoreNextTap();
                widget.onAddToMap?.call();
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add to Map'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditableEstimateRow() {
    return MouseRegion(
      onEnter: (_) => ref.read(mapGestureRiverpod).disableMapGestures(),
      onExit: (_) => ref.read(mapGestureRiverpod).enableMapGestures(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.markunread_mailbox_outlined,
              size: 14, color: Color(0xFF5F6368)),
          const SizedBox(width: 6),
          const Text('~',
              style: TextStyle(fontSize: 12, color: Color(0xFF5F6368))),
          IntrinsicWidth(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 20, maxWidth: 80),
              child: TextField(
                controller: _estimateController,
                focusNode: _estimateFocusNode,
                style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  isDense: true,
                  isCollapsed: true,
                  hintText: '0',
                  hintStyle:
                      TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  _commitEstimate();
                  _estimateFocusNode.unfocus();
                },
              ),
            ),
          ),
          const SizedBox(width: 4),
          const Text('letter boxes',
              style: TextStyle(fontSize: 12, color: Color(0xFF5F6368))),
        ],
      ),
    );
  }

  Widget _buildStatsRow(
    String type,
    String subtitle,
    int letterBoxEstimate,
    int? letterBoxesReached,
  ) {
    if (type == 'polygon' ||
        type == 'preview_work_area' ||
        type == 'overlay_work_area' ||
        type == 'overlay_suburb') {
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
          if (type == 'polygon') ...[
            const SizedBox(height: 4),
            _buildEditableEstimateRow(),
            if (letterBoxesReached != null) ...[
              const SizedBox(height: 4),
              _StatItem(
                icon: const Icon(Icons.fact_check_outlined,
                    size: 14, color: Color(0xFF5F6368)),
                label:
                    '$letterBoxesReached letter box${letterBoxesReached == 1 ? '' : 'es'} reached',
              ),
            ],
          ] else ...[
            const SizedBox(height: 4),
            _StatItem(
              icon: const Icon(Icons.markunread_mailbox_outlined,
                  size: 14, color: Color(0xFF5F6368)),
              label: letterBoxEstimate > 0
                  ? '~$letterBoxEstimate letter boxes'
                  : '~ letter boxes (not set)',
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
      builder: (dialogContext) => _gestureAwareOverlay(
        dialogContext,
        child: AlertDialog(
          title: const Text('Delete element?'),
          content:
              Text('Delete "${widget.data.title}"? This cannot be undone.'),
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
