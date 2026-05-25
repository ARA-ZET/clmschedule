import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import '../../config/flavor_config.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cloud_file_manager_provider.dart';
import '../providers/map_gesture_provider.dart';
import '../providers/shareable_map_provider.dart';
import '../adapters/firestore_adapter.dart';
import '../services/map_link_service.dart';
import '../models/map_layer.dart';
import '../../models/custom_polygon.dart';
import '../models/map_point.dart';
import '../models/map_polyline.dart';
import 'map_import_dialog.dart';

/// Sidebar widget for managing map layers - Google My Maps style
class MapLayersSidebar extends riverpod.ConsumerWidget {
  const MapLayersSidebar({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(shareableMapRiverpod);
    // In the Maps standalone flavor, any authenticated viewer is treated as
    // an admin and gets the full settings menu — matching the CLM flavor.
    final isAuthenticated = ref.watch(authRiverpod).isAuthenticated;
    final showAdminTools = !FlavorConfig.instance.isMaps || isAuthenticated;
    return Column(
      children: [
        _buildHeader(context, provider, showAdminTools: showAdminTools),
        _buildActionButtons(context, provider),
        const Divider(height: 1),
        Expanded(
          child: _buildLayersList(context, provider),
        ),
        _buildBaseMapSection(context, ref),
      ],
    );
  }

  Widget _buildHeader(
    BuildContext context,
    ShareableMapProvider provider, {
    required bool showAdminTools,
  }) {
    final map = provider.currentMap;
    final showMapSettings = showAdminTools;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  map?.name ?? 'Untitled Map',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF202124),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text('Rename map'),
                  ),
                  if (showMapSettings)
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('Map settings'),
                    ),
                  const PopupMenuItem(
                    value: 'statistics',
                    child: Text('Map statistics'),
                  ),
                ],
                onSelected: (value) {
                  if (value == 'rename') {
                    _showRenameMapDialog(context, provider);
                  } else if (value == 'settings' && showMapSettings) {
                    _showMapSettingsDialog(context, provider);
                  } else if (value == 'statistics') {
                    _showMapStatistics(context, provider);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.visibility, size: 12, color: Color(0xFF5F6368)),
              const SizedBox(width: 4),
              Text(
                '${_getViewCount()} views',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF5F6368),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Last edit was ${_getLastEditTime(map?.createdAt)}',
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF5F6368),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(
      BuildContext context, ShareableMapProvider provider) {
    final caps = provider.capabilities;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (caps.canManageLayers) ...[
            _buildActionButton(
              context,
              icon: Icons.add,
              label: 'Add layer',
              onPressed: () => _showAddLayerDialog(context, provider),
            ),
            const SizedBox(width: 8),
          ],
          _buildActionButton(
            context,
            icon: Icons.share_outlined,
            label: 'Share',
            onPressed: () => _copyShareLink(context, provider),
          ),
          const SizedBox(width: 8),
          _buildActionButton(
            context,
            icon: Icons.preview_outlined,
            label: 'Center',
            onPressed: () => provider.fitMapToBounds(),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.info_outline, size: 18),
            color: const Color(0xFF1967D2),
            tooltip: 'Letter box estimates',
            onPressed: () => _showPolygonInfoDialog(context, provider),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Flexible(
      flex: 1,
      child: SizedBox(
        height: 36,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            foregroundColor: const Color(0xFF1967D2),
            side: const BorderSide(color: Color(0xFFDADCE0)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLayersList(
      BuildContext context,
      ShareableMapProvider provider) {
    final layers = provider.layers;

    return CustomScrollView(
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 8)),
        for (final layer in layers)
          ..._buildLayerSlivers(context, provider, layer),
        const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
      ],
    );
  }

  List<Widget> _buildLayerSlivers(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
  ) {
    final isWaypointLayer = provider.isCloudWaypointsLayer(layer.id);

    final header = SliverToBoxAdapter(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Checkbox(
              value: layer.isVisible,
              onChanged: provider.isLayerToggling(layer.id)
                  ? null
                  : (_) => provider.toggleLayerVisibility(layer.id),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: InkWell(
                onTap: () => provider.toggleLayerExpanded(layer.id),
                child: Row(
                  children: [
                    Icon(
                      layer.isExpanded
                          ? Icons.expand_more
                          : Icons.chevron_right,
                      size: 20,
                      color: const Color(0xFF5F6368),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: layer.defaultColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        layer.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF202124),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isWaypointLayer) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${layer.points.length}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF5F6368),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert,
                  size: 18, color: Color(0xFF5F6368)),
              itemBuilder: (context) {
                if (!provider.isCloudOverlayLayer(layer.id)) {
                  return [
                    const PopupMenuItem(
                        value: 'edit', child: Text('Edit layer')),
                    const PopupMenuItem(
                        value: 'duplicate', child: Text('Duplicate')),
                    const PopupMenuItem(
                        value: 'delete', child: Text('Delete layer')),
                  ];
                }
                // Cloud overlay menu
                final folderPath = provider.cloudFolderForLayer(layer.id);
                final isWaypoints = provider.isCloudWaypointsLayer(layer.id);
                final isTracks = provider.isCloudTracksLayer(layer.id);
                final waypointsLoaded = folderPath != null &&
                    provider.cloudWaypointsLoadedFor(folderPath);
                final tracksLoaded = folderPath != null &&
                    provider.cloudTracksLoadedFor(folderPath);
                return [
                  const PopupMenuItem(
                      value: 'rename_cloud_layer', child: Text('Rename layer')),
                  if (isTracks)
                    const PopupMenuItem(
                        value: 'track_color', child: Text('Track color')),
                  if (isWaypoints && !waypointsLoaded)
                    const PopupMenuItem(
                        value: 'load_waypoints', child: Text('Load waypoints')),
                  if (isWaypoints && waypointsLoaded)
                    const PopupMenuItem(
                        value: 'reload_waypoints',
                        child: Text('Reload waypoints')),
                  if (isTracks && tracksLoaded)
                    const PopupMenuItem(
                        value: 'reload_tracks', child: Text('Reload tracks')),
                  if (isTracks && !tracksLoaded)
                    const PopupMenuItem(
                        value: 'load_tracks', child: Text('Load tracks')),
                  const PopupMenuItem(
                      value: 'info', child: Text('Cloud overlay (read-only)')),
                ];
              },
              onSelected: (value) {
                final folderPath = provider.cloudFolderForLayer(layer.id);
                if (value == 'edit') {
                  _showEditLayerDialog(context, provider, layer);
                } else if (value == 'duplicate') {
                  _duplicateLayer(provider, layer);
                } else if (value == 'delete') {
                  _deleteLayer(context, provider, layer);
                } else if (value == 'track_color') {
                  if (folderPath != null) {
                    _showCloudTrackColorDialog(context, provider, folderPath);
                  }
                } else if (value == 'load_waypoints') {
                  provider.loadCloudFolderWaypoints(folderPath: folderPath);
                } else if (value == 'reload_waypoints') {
                  provider.loadCloudFolderWaypoints(
                      folderPath: folderPath, force: true);
                } else if (value == 'load_tracks') {
                  provider.loadCloudFolderTracks(folderPath: folderPath);
                } else if (value == 'reload_tracks') {
                  provider.loadCloudFolderTracks(
                      folderPath: folderPath, force: true);
                } else if (value == 'rename_cloud_layer') {
                  _showRenameCloudLayerDialog(context, provider, layer);
                }
              },
            ),
          ],
        ),
      ),
    );

    if (!layer.isExpanded) return [header];

    final pointCount = layer.points.length;
    final polygonCount = layer.polygons.length;
    final polylineCount = layer.polylines.length;
    final totalCount = pointCount + polygonCount + polylineCount;

    if (totalCount == 0) {
      return [
        header,
        SliverToBoxAdapter(
          child: _buildEmptyLayerWidget(context, provider, layer),
        ),
      ];
    }

    return [
      header,
      SliverList.builder(
        itemCount: totalCount,
        itemBuilder: (context, index) {
          if (index < pointCount) {
            final point = layer.points[index];
            return _buildLayerItem(
              context,
              provider: provider,
              layer: layer,
              iconWidget: isWaypointLayer
                  ? Image.asset('assets/letterbox.png', width: 18, height: 18)
                  : Icon(Icons.place, size: 18, color: point.color),
              title: point.name,
              elementId: point.id,
              onTap: () => _selectElement(provider, point.id),
              onEdit: () =>
                  _showEditPointDialog(context, provider, layer, point),
              onDelete: () => _deletePoint(context, provider, layer, point.id),
              onMoveTo: (targetLayerId) =>
                  provider.movePointToLayer(layer, point.id, targetLayerId),
            );
          } else if (index < pointCount + polygonCount) {
            final polygonIndex = index - pointCount;
            final polygon = layer.polygons[polygonIndex];
            final elementId = '${layer.id}_polygon_$polygonIndex';
            return _buildLayerItem(
              context,
              provider: provider,
              layer: layer,
              iconWidget:
                  Icon(Icons.crop_square, size: 18, color: polygon.color),
              title: polygon.name,
              subtitle: 'Est. ${polygon.letterBoxEstimate} letter boxes',
              elementId: elementId,
              onTap: () {
                // Focus the map on the polygon AND open its info window,
                // using the same subtitle format as a direct map tap.
                final areaKm2 = _polygonAreaKm2(polygon.points);
                final perimeterKm = _pathLengthKm(polygon.points, closed: true);
                final subtitle =
                    '${_fmtKm2(areaKm2)}  ·  ${_fmtKm(perimeterKm)}';
                provider.focusOnPolygon(layer.id, polygonIndex);
                provider.openInfoWindow(InfoWindowData(
                  elementId: elementId,
                  layerId: layer.id,
                  title: polygon.name.isNotEmpty
                      ? polygon.name
                      : 'Unnamed Polygon',
                  description: polygon.description,
                  subtitle: subtitle,
                  type: 'polygon',
                  anchor: _centroid(polygon.points),
                  letterBoxEstimate: polygon.letterBoxEstimate,
                ));
              },
              onEdit: () => _showEditPolygonDialog(
                  context, provider, layer, polygonIndex, polygon),
              onDelete: () =>
                  _deletePolygon(context, provider, layer, polygonIndex),
              onMoveTo: (targetLayerId) => provider.movePolygonToLayer(
                  layer, polygonIndex, targetLayerId),
            );
          } else {
            final polylineIndex = index - pointCount - polygonCount;
            final polyline = layer.polylines[polylineIndex];
            return _buildLayerItem(
              context,
              provider: provider,
              layer: layer,
              iconWidget: Icon(Icons.timeline, size: 18, color: polyline.color),
              title: polyline.name,
              elementId: polyline.id,
              onTap: () => provider.focusOnPolyline(layer.id, polyline.id),
              onEdit: () =>
                  _showEditPolylineDialog(context, provider, layer, polyline),
              onDelete: () =>
                  _deletePolyline(context, provider, layer, polyline.id),
              onMoveTo: (targetLayerId) => provider.movePolylineToLayer(
                  layer, polyline.id, targetLayerId),
            );
          }
        },
      ),
    ];
  }

  Widget _buildEmptyLayerWidget(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
  ) {
    final folderPath = provider.cloudFolderForLayer(layer.id);
    if (folderPath != null &&
        provider.isCloudWaypointsLayer(layer.id) &&
        !provider.cloudWaypointsLoadedFor(folderPath)) {
      return Padding(
        padding: const EdgeInsets.only(left: 40, right: 16, bottom: 8),
        child: provider.isLoadingCloudWaypointsFor(folderPath)
            ? const Row(
                children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('Loading…',
                      style:
                          TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                ],
              )
            : InkWell(
                onTap: () =>
                    provider.loadCloudFolderWaypoints(folderPath: folderPath),
                child: Row(
                  children: [
                    Icon(Icons.cloud_download,
                        size: 16, color: Colors.blue[600]),
                    const SizedBox(width: 6),
                    Text('Tap to load waypoints',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blue[600],
                          fontStyle: FontStyle.italic,
                        )),
                  ],
                ),
              ),
      );
    } else if (folderPath != null &&
        provider.isCloudTracksLayer(layer.id) &&
        provider.isLoadingCloudTracksFor(folderPath)) {
      return const Padding(
        padding: EdgeInsets.only(left: 40, right: 16, bottom: 8),
        child: Row(
          children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('Loading tracks…',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 56, right: 16, bottom: 8),
      child: Text(
        'No places in this layer',
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey[600],
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  Widget _buildLayerItem(
    BuildContext context, {
    required ShareableMapProvider provider,
    required MapLayer layer,
    required Widget iconWidget,
    required String title,
    String? subtitle,
    required String elementId,
    required VoidCallback onTap,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
    required void Function(String targetLayerId) onMoveTo,
  }) {
    final isSelected = provider.selectedElementId == elementId;
    // Other layers this item can be moved to
    final otherLayers = provider.layers.where((l) => l.id != layer.id).toList();

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 56, right: 8, top: 4, bottom: 4),
        color: isSelected ? const Color(0xFFE8F0FE) : null,
        child: Row(
          children: [
            iconWidget,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title.isEmpty ? 'Untitled' : title,
                    style: TextStyle(
                      fontSize: 13,
                      color: const Color(0xFF202124),
                      fontWeight:
                          isSelected ? FontWeight.w500 : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: const Color(0xFF5F6368).withValues(alpha: 0.8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            MenuAnchor(
              builder: (context, controller, child) {
                return IconButton(
                  icon: const Icon(Icons.more_vert,
                      size: 16, color: Color(0xFF5F6368)),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                );
              },
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.edit, size: 18),
                  child: const Text('Edit'),
                  onPressed: () => onEdit(),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.copy, size: 18),
                  child: const Text('Duplicate'),
                  onPressed: () {
                    // TODO: Implement duplicate
                  },
                ),
                if (otherLayers.isNotEmpty)
                  SubmenuButton(
                    leadingIcon:
                        const Icon(Icons.drive_file_move_outline, size: 18),
                    menuChildren: otherLayers.map((targetLayer) {
                      return MenuItemButton(
                        leadingIcon: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: targetLayer.defaultColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        child: Text(
                          targetLayer.name,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onPressed: () => onMoveTo(targetLayer.id),
                      );
                    }).toList(),
                    child: const Text('Move to layer'),
                  ),
                const Divider(height: 8),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.delete,
                      size: 18, color: Color(0xFFD93025)),
                  child: const Text('Delete',
                      style: TextStyle(color: Color(0xFFD93025))),
                  onPressed: () => onDelete(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUntitledLayerSection(
      BuildContext context, ShareableMapProvider provider) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF7E0),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFF9AB00), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: true,
                onChanged: null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              const Text(
                'Untitled layer',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF202124),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => _showImportDialog(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.upload_file,
                            size: 16, color: Color(0xFF1967D2)),
                        const SizedBox(width: 8),
                        const Text(
                          'Import',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF1967D2),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Add places to this layer by drawing or importing data.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF5F6368),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBaseMapSection(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(shareableMapRiverpod);
    final selectedKey = provider.selectedBaseMap;
    final options = ShareableMapProvider.baseMapOptions;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFDADCE0), width: 1)),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.map, size: 20, color: Color(0xFF5F6368)),
        title: const Text(
          'Base map',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Color(0xFF202124),
          ),
        ),
        initiallyExpanded: false,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options.map((option) {
                final isSelected = selectedKey == option.key;
                return _BaseMapTile(
                  option: option,
                  isSelected: isSelected,
                  onTap: () => provider.setBaseMap(option.key),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // Helper methods
  int _getViewCount() {
    // Placeholder for analytics
    return 0;
  }

  String _getLastEditTime(DateTime? createdAt) {
    if (createdAt == null) return 'just now';

    final now = DateTime.now();
    final difference = now.difference(createdAt);

    if (difference.inSeconds < 60) return 'seconds ago';
    if (difference.inMinutes < 60) {
      return '${difference.inMinutes} minute${difference.inMinutes > 1 ? 's' : ''} ago';
    }
    if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
    }
    if (difference.inDays < 7) {
      return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
    }

    return DateFormat('MMM d, y').format(createdAt);
  }

  void _selectElement(ShareableMapProvider provider, String elementId) {
    provider.selectElement(elementId);
  }

  static LatLng _centroid(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(0, 0);
    double lat = 0, lng = 0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

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

  void _duplicateLayer(ShareableMapProvider provider, MapLayer layer) {
    // TODO: Implement layer duplication
  }

  void _deleteLayer(
      BuildContext context, ShareableMapProvider provider, MapLayer layer) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Layer'),
        content: Text('Are you sure you want to delete "${layer.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              provider.deleteLayer(layer.id);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
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

  void _showImportDialog(BuildContext context) {
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

  void _showRenameCloudLayerDialog(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
  ) {
    final controller = TextEditingController(text: layer.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Layer'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Layer name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                provider.renameCloudLayer(layer.id, controller.text.trim());
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showRenameMapDialog(
      BuildContext context, ShareableMapProvider provider) {
    final controller = TextEditingController(text: provider.currentMap?.name);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Map'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Map name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                provider.updateMapMetadata(name: controller.text);
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showMapSettingsDialog(
      BuildContext context, ShareableMapProvider provider) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final gestureProvider =
            riverpod.ProviderScope.containerOf(dialogContext)
                .read(mapGestureRiverpod);
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            final folders = provider.linkedCloudFolders;
            return Dialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: MouseRegion(
                onEnter: (_) => gestureProvider.disableMapGestures(),
                onExit: (_) => gestureProvider.enableMapGestures(),
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 560, maxHeight: 680),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                        child: Row(
                          children: [
                            const Icon(Icons.settings_outlined,
                                size: 20, color: Color(0xFF1967D2)),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text('Map Settings',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              onPressed: () => Navigator.pop(dialogContext),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(16),
                          children: [
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Load latest month on open'),
                              subtitle: const Text(
                                  'Automatically loads distributor movements for the newest linked month.'),
                              value: provider.autoLoadLatestCloudFolder,
                              onChanged: (value) {
                                provider.setAutoLoadLatestCloudFolder(value);
                                setState(() {});
                              },
                            ),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                  'Show cloud data inside polygons only'),
                              subtitle: const Text(
                                  'Filters letter boxes and track segments to the map polygons.'),
                              value: provider.clipCloudDataToPolygons,
                              onChanged: (value) {
                                provider.setClipCloudDataToPolygons(value);
                                setState(() {});
                              },
                            ),
                            const SizedBox(height: 12),
                            const Text('Linked cloud folders',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF202124))),
                            const SizedBox(height: 8),
                            if (folders.isEmpty)
                              _buildEmptyCloudFolderNotice()
                            else
                              ...folders.map((folder) =>
                                  _buildLinkedCloudFolderSettingsRow(
                                    provider,
                                    folder,
                                    setState,
                                  )),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: const Text('Choose cloud folder'),
                                onPressed: () async {
                                  final selectedPath =
                                      await _showCloudFolderPicker(
                                    dialogContext,
                                    initialPath:
                                        provider.latestLinkedCloudFolder,
                                  );
                                  if (selectedPath == null ||
                                      selectedPath.trim().isEmpty) {
                                    return;
                                  }
                                  provider.addCloudFolderLink(selectedPath);
                                  setState(() {});
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<String?> _showCloudFolderPicker(
    BuildContext context, {
    String? initialPath,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _CloudFolderPickerDialog(initialPath: initialPath),
    );
  }

  Widget _buildEmptyCloudFolderNotice() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDADCE0)),
      ),
      child: const Text(
        'No cloud folders linked to this map.',
        style: TextStyle(fontSize: 13, color: Color(0xFF5F6368)),
      ),
    );
  }

  Widget _buildLinkedCloudFolderSettingsRow(
    ShareableMapProvider provider,
    String folder,
    StateSetter setState,
  ) {
    final label = provider.cloudFolderMonthLabel(folder);
    final tracksLoaded = provider.cloudTracksLoadedFor(folder);
    final waypointsLoaded = provider.cloudWaypointsLoadedFor(folder);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDADCE0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_outlined,
                  size: 18, color: Color(0xFF5F6368)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    Text(folder,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF5F6368)),
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Unlink folder',
                icon: const Icon(Icons.link_off,
                    size: 18, color: Color(0xFFD93025)),
                onPressed: () {
                  provider.unlinkCloudFolder(folder);
                  setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Movements'),
                  value: tracksLoaded,
                  onChanged: (value) async {
                    if (value) {
                      await provider.loadCloudFolderTracks(
                          folderPath: folder, force: true);
                    } else {
                      provider.unloadCloudFolderTracks(folder);
                    }
                    setState(() {});
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Letter boxes'),
                  value: waypointsLoaded,
                  onChanged: (value) async {
                    if (value) {
                      await provider.loadCloudFolderWaypoints(
                          folderPath: folder, force: true);
                    } else {
                      provider.unloadCloudFolderWaypoints(folder);
                    }
                    setState(() {});
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showMapStatistics(BuildContext context, ShareableMapProvider provider) {
    final stats = provider.currentMap?.getStatistics();
    if (stats == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Map Statistics'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total Layers: ${stats['totalLayers']}'),
            const SizedBox(height: 8),
            Text('Total Polygons: ${stats['totalPolygons']}'),
            Text('Total Polylines: ${stats['totalPolylines']}'),
            Text('Total Points: ${stats['totalPoints']}'),
            const SizedBox(height: 8),
            Text('Total Elements: ${stats['totalElements']}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ── Polygon info helpers ──────────────────────────────────────────

  void _showPolygonInfoDialog(
      BuildContext context, ShareableMapProvider provider) {
    // Build editable rows — capture layerId + polygon index for write-back.
    final rows = <({
      String layerId,
      int index,
      String name,
      TextEditingController ctrl,
    })>[];
    for (final layer in provider.layers) {
      for (int i = 0; i < layer.polygons.length; i++) {
        final poly = layer.polygons[i];
        rows.add((
          layerId: layer.id,
          index: i,
          name: poly.name.isNotEmpty ? poly.name : 'Unnamed',
          ctrl: TextEditingController(
            text: poly.letterBoxEstimate > 0
                ? poly.letterBoxEstimate.toString()
                : '',
          ),
        ));
      }
    }

    void commitRow(int i, StateSetter setState) {
      final r = rows[i];
      final newEst = int.tryParse(r.ctrl.text.trim()) ?? 0;
      // Re-read layer from provider so we never overwrite sibling changes.
      final currentLayer =
          provider.layers.where((l) => l.id == r.layerId).firstOrNull;
      if (currentLayer == null || r.index >= currentLayer.polygons.length) {
        return;
      }
      provider.updatePolygon(
        currentLayer,
        r.index,
        currentLayer.polygons[r.index].copyWith(letterBoxEstimate: newEst),
      );
      setState(() {});
    }

    showDialog(
      context: context,
      builder: (ctx) {
        final gestureProvider =
            riverpod.ProviderScope.containerOf(ctx).read(mapGestureRiverpod);
        return StatefulBuilder(
          builder: (ctx, setState) {
            final total = rows.fold(
                0, (s, r) => s + (int.tryParse(r.ctrl.text.trim()) ?? 0));

            return Dialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: MouseRegion(
                onEnter: (_) => gestureProvider.disableMapGestures(),
                onExit: (_) => gestureProvider.enableMapGestures(),
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 400, maxHeight: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                        child: Row(
                          children: [
                            const Icon(Icons.markunread_mailbox_outlined,
                                size: 18, color: Color(0xFF1967D2)),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Letter Box Estimates',
                                style: TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => Navigator.pop(ctx),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      // Column headers
                      Container(
                        color: const Color(0xFFF8F9FA),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: const Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Text('Area Name',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF5F6368))),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text('Est. Letter Boxes',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF5F6368))),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      // Rows
                      Flexible(
                        child: rows.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.all(24),
                                child: Center(
                                    child: Text('No polygons on this map.',
                                        style: TextStyle(
                                            color: Color(0xFF5F6368)))),
                              )
                            : ListView.separated(
                                shrinkWrap: true,
                                itemCount: rows.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final r = rows[i];
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 6),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: Text(r.name,
                                              style:
                                                  const TextStyle(fontSize: 13),
                                              overflow: TextOverflow.ellipsis),
                                        ),
                                        Expanded(
                                          flex: 2,
                                          child: TextField(
                                            controller: r.ctrl,
                                            keyboardType: TextInputType.number,
                                            textAlign: TextAlign.right,
                                            style:
                                                const TextStyle(fontSize: 13),
                                            decoration: const InputDecoration(
                                              isDense: true,
                                              contentPadding:
                                                  EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 6),
                                              border: OutlineInputBorder(),
                                              hintText: '0',
                                            ),
                                            onChanged: (_) => setState(() {}),
                                            onSubmitted: (_) =>
                                                commitRow(i, setState),
                                            onEditingComplete: () =>
                                                commitRow(i, setState),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                      const Divider(height: 1),
                      // Totals footer
                      Container(
                        color: const Color(0xFFF8F9FA),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Text(
                                'Total  (${rows.length} area${rows.length == 1 ? '' : 's'})',
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                total > 0
                                    ? NumberFormat('#,###').format(total)
                                    : '—',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAddLayerDialog(
      BuildContext context, ShareableMapProvider provider) {
    final nameController = TextEditingController(
      text: 'Layer ${provider.layers.length + 1}',
    );
    final descController = TextEditingController();
    Color selectedColor = Colors.blue;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add Layer'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Layer Name',
                  hintText: 'Enter layer name',
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
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Color:'),
                  const SizedBox(width: 16),
                  Wrap(
                    spacing: 8,
                    children: [
                      Colors.blue,
                      Colors.red,
                      Colors.green,
                      Colors.orange,
                      Colors.purple,
                      Colors.teal,
                      Colors.pink,
                      Colors.brown,
                    ].map((color) {
                      return GestureDetector(
                        onTap: () => setState(() => selectedColor = color),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selectedColor == color
                                  ? Colors.black
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
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
                  provider.createLayer(
                    name: nameController.text.trim(),
                    description: descController.text.trim(),
                    color: selectedColor,
                  );
                  Navigator.pop(context);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCloudTrackColorDialog(
    BuildContext context,
    ShareableMapProvider provider,
    String folderPath,
  ) {
    Color selectedColor = provider.cloudTrackColorForFolder(folderPath);
    final label = provider.cloudFolderMonthLabel(folderPath);
    final colors = [
      const Color(0xFF1967D2),
      const Color(0xFFD93025),
      const Color(0xFF188038),
      const Color(0xFFF29900),
      const Color(0xFF9334E6),
      const Color(0xFF0097A7),
      const Color(0xFFE91E63),
      const Color(0xFF795548),
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.brown,
    ];

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text('$label track color'),
          content: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: colors.map((color) {
              final isSelected = color.toARGB32() == selectedColor.toARGB32();
              return Tooltip(
                message: 'Track color',
                child: InkWell(
                  onTap: () => setState(() => selectedColor = color),
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? Colors.black : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white, size: 18)
                        : null,
                  ),
                ),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                provider.setCloudTrackColor(folderPath, selectedColor);
                Navigator.pop(dialogContext);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditLayerDialog(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
  ) {
    final nameController = TextEditingController(text: layer.name);
    final descController = TextEditingController(text: layer.description);
    Color selectedColor = layer.defaultColor;
    final polygonCount = layer.polygons.where((p) => p.isPolygon).length;
    final polylineCount = layer.polylines.length +
        layer.polygons.where((p) => p.isPolyline).length;
    final markerCount =
        layer.points.length + layer.polygons.where((p) => p.isMarker).length;
    bool applyColorToPolygons = false;
    bool applyColorToPolylines = false;
    bool applyMarkerCategory = false;
    PointCategory selectedMarkerCategory = PointCategory.generic;
    if (layer.points.isNotEmpty) {
      selectedMarkerCategory = layer.points.first.pointCategory;
    } else {
      for (final polygon in layer.polygons) {
        if (polygon.isMarker) {
          selectedMarkerCategory = polygon.pointCategory;
          break;
        }
      }
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit Layer'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Layer Name'),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descController,
                  decoration: const InputDecoration(labelText: 'Description'),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 7),
                      child: Text('Color:'),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Colors.blue,
                          Colors.red,
                          Colors.green,
                          Colors.orange,
                          Colors.purple,
                          Colors.teal,
                          Colors.pink,
                          Colors.brown,
                        ].map((color) {
                          return GestureDetector(
                            onTap: () => setState(() => selectedColor = color),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selectedColor == color
                                      ? Colors.black
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
                if (polygonCount > 0 ||
                    polylineCount > 0 ||
                    markerCount > 0) ...[
                  const SizedBox(height: 16),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Apply to existing items',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (polygonCount > 0)
                    SwitchListTile.adaptive(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Polygons'),
                      subtitle: Text(
                          '$polygonCount area${polygonCount == 1 ? '' : 's'}'),
                      value: applyColorToPolygons,
                      onChanged: (value) =>
                          setState(() => applyColorToPolygons = value),
                    ),
                  if (polylineCount > 0)
                    SwitchListTile.adaptive(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Polylines'),
                      subtitle: Text(
                          '$polylineCount line${polylineCount == 1 ? '' : 's'}'),
                      value: applyColorToPolylines,
                      onChanged: (value) =>
                          setState(() => applyColorToPolylines = value),
                    ),
                  if (markerCount > 0) ...[
                    SwitchListTile.adaptive(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Marker icon'),
                      subtitle: Text(
                          '$markerCount marker${markerCount == 1 ? '' : 's'}'),
                      value: applyMarkerCategory,
                      onChanged: (value) =>
                          setState(() => applyMarkerCategory = value),
                    ),
                    DropdownButtonFormField<PointCategory>(
                      initialValue: selectedMarkerCategory,
                      decoration: const InputDecoration(
                        labelText: 'Marker icon',
                        border: OutlineInputBorder(),
                      ),
                      items: PointCategory.values.map((category) {
                        return DropdownMenuItem(
                          value: category,
                          child: Row(
                            children: [
                              Icon(category.icon,
                                  size: 18, color: category.color),
                              const SizedBox(width: 8),
                              Text(category.label),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: applyMarkerCategory
                          ? (category) {
                              if (category == null) return;
                              setState(() => selectedMarkerCategory = category);
                            }
                          : null,
                    ),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                provider.updateLayer(
                  layerId: layer.id,
                  name: nameController.text.trim(),
                  description: descController.text.trim(),
                  color: selectedColor,
                  applyColorToPolygons: applyColorToPolygons,
                  applyColorToPolylines: applyColorToPolylines,
                  applyMarkerCategory: applyMarkerCategory,
                  markerCategory: selectedMarkerCategory,
                );
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  // Polygon operations
  void _showEditPolygonDialog(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
    int polygonIndex,
    CustomPolygon polygon,
  ) {
    final nameController = TextEditingController(text: polygon.name);
    final descController = TextEditingController(text: polygon.description);
    Color selectedColor = polygon.color;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit Polygon'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Color:'),
                  const SizedBox(width: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      Colors.blue,
                      Colors.red,
                      Colors.green,
                      Colors.orange,
                      Colors.purple,
                      Colors.teal,
                      Colors.pink,
                      Colors.brown,
                    ].map((color) {
                      return GestureDetector(
                        onTap: () => setState(() => selectedColor = color),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selectedColor == color
                                  ? Colors.black
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
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
                final updatedPolygon = polygon.copyWith(
                  name: nameController.text.trim(),
                  description: descController.text.trim(),
                  color: selectedColor,
                );
                provider.updatePolygon(layer, polygonIndex, updatedPolygon);
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _deletePolygon(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
    int polygonIndex,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Polygon'),
        content: const Text('Are you sure you want to delete this polygon?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              provider.deletePolygon(layer, polygonIndex);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // Point operations
  void _showEditPointDialog(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
    MapPoint point,
  ) {
    final nameController = TextEditingController(text: point.name);
    final descController = TextEditingController(text: point.description);
    Color selectedColor = point.color;
    PointCategory selectedCategory = point.pointCategory;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit Point'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<PointCategory>(
                initialValue: selectedCategory,
                decoration: const InputDecoration(labelText: 'Point Type'),
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
                onChanged: (cat) {
                  if (cat == null) return;
                  setState(() {
                    selectedCategory = cat;
                    selectedColor = cat.color;
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Color:'),
                  const SizedBox(width: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      Colors.blue,
                      Colors.red,
                      Colors.green,
                      Colors.orange,
                      Colors.purple,
                      Colors.teal,
                      Colors.pink,
                      Colors.brown,
                    ].map((color) {
                      return GestureDetector(
                        onTap: () => setState(() => selectedColor = color),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selectedColor == color
                                  ? Colors.black
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
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
                final updatedPoint = point.copyWith(
                  name: nameController.text.trim(),
                  description: descController.text.trim(),
                  color: selectedColor,
                  pointCategory: selectedCategory,
                );
                provider.updatePoint(layer, point.id, updatedPoint);
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _deletePoint(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
    String pointId,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Point'),
        content: const Text('Are you sure you want to delete this point?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              provider.deletePoint(layer, pointId);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // Polyline operations
  void _showEditPolylineDialog(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
    MapPolyline polyline,
  ) {
    final nameController = TextEditingController(text: polyline.name);
    final descController = TextEditingController(text: polyline.description);
    Color selectedColor = polyline.color;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit Polyline'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Color:'),
                  const SizedBox(width: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      Colors.blue,
                      Colors.red,
                      Colors.green,
                      Colors.orange,
                      Colors.purple,
                      Colors.teal,
                      Colors.pink,
                      Colors.brown,
                    ].map((color) {
                      return GestureDetector(
                        onTap: () => setState(() => selectedColor = color),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selectedColor == color
                                  ? Colors.black
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
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
                final updatedPolyline = polyline.copyWith(
                  name: nameController.text.trim(),
                  description: descController.text.trim(),
                  color: selectedColor,
                );
                provider.updatePolyline(layer, polyline.id, updatedPolyline);
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _deletePolyline(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
    String polylineId,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Polyline'),
        content: const Text('Are you sure you want to delete this polyline?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              provider.deletePolyline(layer, polylineId);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _CloudFolderPickerDialog extends riverpod.ConsumerStatefulWidget {
  final String? initialPath;

  const _CloudFolderPickerDialog({this.initialPath});

  @override
  riverpod.ConsumerState<_CloudFolderPickerDialog> createState() =>
      _CloudFolderPickerDialogState();
}

class _CloudFolderPickerDialogState
    extends riverpod.ConsumerState<_CloudFolderPickerDialog> {
  final CloudFileManagerProvider _cloudProvider = CloudFileManagerProvider();

  @override
  void initState() {
    super.initState();
    _cloudProvider.addListener(_onCloudProviderChanged);
    final initialPath = widget.initialPath?.trim();
    if (initialPath != null && initialPath.isNotEmpty) {
      _cloudProvider.navigateToPath(initialPath);
    } else {
      _cloudProvider.loadCurrentFolder();
    }
  }

  @override
  void dispose() {
    _cloudProvider.removeListener(_onCloudProviderChanged);
    _cloudProvider.dispose();
    super.dispose();
  }

  void _onCloudProviderChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final gestureProvider = ref.read(mapGestureRiverpod);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: MouseRegion(
        onEnter: (_) => gestureProvider.disableMapGestures(),
        onExit: (_) => gestureProvider.enableMapGestures(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    const Icon(Icons.folder_open,
                        size: 20, color: Color(0xFF1967D2)),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Choose Cloud Folder',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: _buildBreadcrumbs(),
              ),
              const Divider(height: 1),
              Flexible(child: _buildFolderList()),
              const Divider(height: 1),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _cloudProvider.currentPath,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF5F6368)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(
                        _cloudProvider.isAtRoot
                            ? 'Select folder'
                            : 'Select "${_cloudProvider.currentName}"',
                      ),
                      onPressed: _cloudProvider.isAtRoot
                          ? null
                          : () => Navigator.pop(
                              context, _cloudProvider.currentPath),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBreadcrumbs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          InkWell(
            onTap: _cloudProvider.isAtRoot ? null : _cloudProvider.goToRoot,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.cloud,
                  size: 18,
                  color: _cloudProvider.isAtRoot
                      ? const Color(0xFF1967D2)
                      : const Color(0xFF5F6368)),
            ),
          ),
          for (int i = 0; i < _cloudProvider.breadcrumbs.length; i++) ...[
            const Icon(Icons.chevron_right, size: 16, color: Color(0xFF9AA0A6)),
            InkWell(
              onTap: i == _cloudProvider.breadcrumbs.length - 1
                  ? null
                  : () => _cloudProvider.goToBreadcrumb(i),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: Text(
                  _cloudProvider.breadcrumbs[i].name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: i == _cloudProvider.breadcrumbs.length - 1
                        ? FontWeight.w700
                        : FontWeight.normal,
                    color: i == _cloudProvider.breadcrumbs.length - 1
                        ? const Color(0xFF1967D2)
                        : const Color(0xFF5F6368),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFolderList() {
    if (_cloudProvider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_cloudProvider.error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          _cloudProvider.error!,
          style: const TextStyle(color: Color(0xFFD93025), fontSize: 13),
        ),
      );
    }
    if (_cloudProvider.folders.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No subfolders here. Select this folder if it contains the cloud files for this map.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFF5F6368)),
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _cloudProvider.folders.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final folder = _cloudProvider.folders[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.folder_outlined,
              size: 20, color: Color(0xFF5F6368)),
          title: Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            folder.fullPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _cloudProvider.openFolder(folder),
        );
      },
    );
  }
}

/// A small tile widget for the base map picker — shows an icon,
/// label, and an optional description tooltip.
class _BaseMapTile extends StatelessWidget {
  final MapBaseOption option;
  final bool isSelected;
  final VoidCallback onTap;

  const _BaseMapTile({
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: option.description ?? option.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF1967D2)
                  : const Color(0xFFDADCE0),
              width: isSelected ? 2 : 1,
            ),
            color: isSelected
                ? const Color(0xFF1967D2).withValues(alpha: 0.08)
                : Colors.transparent,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                option.icon,
                size: 24,
                color: isSelected
                    ? const Color(0xFF1967D2)
                    : const Color(0xFF5F6368),
              ),
              const SizedBox(height: 4),
              Text(
                option.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected
                      ? const Color(0xFF1967D2)
                      : const Color(0xFF202124),
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
