import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import '../providers/shareable_map_provider.dart';
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
    return Column(
      children: [
        _buildHeader(context, provider),
        _buildActionButtons(context, provider),
        const Divider(height: 1),
        Expanded(
          child: _buildLayersList(context, provider),
        ),
        _buildBaseMapSection(context, ref),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, ShareableMapProvider provider) {
    final map = provider.currentMap;

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
                  const PopupMenuItem(
                    value: 'statistics',
                    child: Text('Map statistics'),
                  ),
                ],
                onSelected: (value) {
                  if (value == 'rename') {
                    _showRenameMapDialog(context, provider);
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
            onPressed: () => _showShareDialog(context),
          ),
          const SizedBox(width: 8),
          _buildActionButton(
            context,
            icon: Icons.preview_outlined,
            label: 'Preview',
            onPressed: () => provider.fitMapToBounds(),
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

  Widget _buildLayersList(BuildContext context, ShareableMapProvider provider) {
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
    final isWaypointLayer = provider.isCloudOverlayLayer(layer.id) &&
        layer.name == ShareableMapProvider.waypointsLayerName;

    final header = SliverToBoxAdapter(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Checkbox(
              value: layer.isVisible,
              onChanged: (_) => provider.toggleLayerVisibility(layer.id),
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
                final isWaypoints =
                    layer.name == ShareableMapProvider.waypointsLayerName;
                final isTracks =
                    layer.name == ShareableMapProvider.tracksLayerName;
                return [
                  if (isWaypoints && !provider.cloudWaypointsLoaded)
                    const PopupMenuItem(
                        value: 'load_waypoints', child: Text('Load waypoints')),
                  if (isWaypoints && provider.cloudWaypointsLoaded)
                    const PopupMenuItem(
                        value: 'reload_waypoints',
                        child: Text('Reload waypoints')),
                  if (isTracks && provider.cloudTracksLoaded)
                    const PopupMenuItem(
                        value: 'reload_tracks', child: Text('Reload tracks')),
                  const PopupMenuItem(
                      value: 'info', child: Text('Cloud overlay (read-only)')),
                ];
              },
              onSelected: (value) {
                if (value == 'edit') {
                  _showEditLayerDialog(context, provider, layer);
                } else if (value == 'duplicate') {
                  _duplicateLayer(provider, layer);
                } else if (value == 'delete') {
                  _deleteLayer(context, provider, layer);
                } else if (value == 'load_waypoints') {
                  provider.loadCloudFolderWaypoints();
                } else if (value == 'reload_waypoints') {
                  provider.loadCloudFolderWaypoints(force: true);
                } else if (value == 'reload_tracks') {
                  provider.loadCloudFolderTracks(force: true);
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
              elementId: elementId,
              onTap: () => _selectElement(provider, elementId),
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
              onTap: () => _selectElement(provider, polyline.id),
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
    if (provider.isCloudOverlayLayer(layer.id) &&
        layer.name == ShareableMapProvider.waypointsLayerName &&
        !provider.cloudWaypointsLoaded) {
      return Padding(
        padding: const EdgeInsets.only(left: 40, right: 16, bottom: 8),
        child: provider.isLoadingCloudWaypoints
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
                onTap: () => provider.loadCloudFolderWaypoints(),
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
    } else if (provider.isCloudOverlayLayer(layer.id) &&
        layer.name == ShareableMapProvider.tracksLayerName &&
        provider.isLoadingCloudTracks) {
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
              child: Text(
                title.isEmpty ? 'Untitled' : title,
                style: TextStyle(
                  fontSize: 13,
                  color: const Color(0xFF202124),
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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

  void _showShareDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share Map'),
        content:
            const Text('Sharing functionality will be available in Phase 2.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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

  void _showEditLayerDialog(
    BuildContext context,
    ShareableMapProvider provider,
    MapLayer layer,
  ) {
    final nameController = TextEditingController(text: layer.name);
    final descController = TextEditingController(text: layer.description);
    Color selectedColor = layer.defaultColor;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit Layer'),
          content: Column(
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
                provider.updateLayer(
                  layerId: layer.id,
                  name: nameController.text.trim(),
                  description: descController.text.trim(),
                  color: selectedColor,
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
