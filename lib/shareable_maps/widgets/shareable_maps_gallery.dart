import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/shareable_map.dart';
import '../providers/shareable_maps_gallery_provider.dart';
import '../providers/shareable_map_provider.dart';
import '../services/shareable_maps_firestore_service.dart';
import '../services/map_link_service.dart';
import '../adapters/firestore_adapter.dart';
import '../utils/url_updater.dart' as url_updater;
import 'shareable_map_editor.dart';

/// Gallery screen for viewing all shareable maps as tiles, grouped by month.
/// Modelled after the Google My Maps dashboard.
class ShareableMapsGallery extends StatefulWidget {
  const ShareableMapsGallery({super.key});

  @override
  State<ShareableMapsGallery> createState() => _ShareableMapsGalleryState();
}

class _ShareableMapsGalleryState extends State<ShareableMapsGallery> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Start listening for maps as soon as the gallery opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ShareableMapsGalleryProvider>().startListening();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(context),
      body: Consumer<ShareableMapsGalleryProvider>(
        builder: (context, gallery, _) {
          if (gallery.isLoading && gallery.allMaps.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (gallery.error != null && gallery.allMaps.isEmpty) {
            return _ErrorView(error: gallery.error!);
          }
          // Show empty state only when no maps loaded AND no unloaded months
          if (gallery.allMaps.isEmpty && gallery.unloadedMonths.isEmpty) {
            return const _EmptyGallery();
          }
          return _GalleryBody(
            monthGroups: gallery.filteredMonthGroups,
            filterTab: gallery.filterTab,
            unloadedMonths: gallery.unloadedMonths,
            loadingMonths: gallery.unloadedMonths
                .where((mk) => gallery.isMonthLoading(mk))
                .toSet(),
            onLoadMonth: gallery.loadMonth,
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'create_map',
        onPressed: () => _createNewMap(context),
        icon: const Icon(Icons.add),
        label: const Text('CREATE A NEW MAP'),
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      title: Row(
        children: [
          Icon(Icons.map, color: Colors.green.shade700),
          const SizedBox(width: 8),
          const Text('My Maps'),
          const SizedBox(width: 16),
          // Search field
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search maps...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            context
                                .read<ShareableMapsGalleryProvider>()
                                .setSearchQuery('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                ),
                onChanged: (value) {
                  context
                      .read<ShareableMapsGalleryProvider>()
                      .setSearchQuery(value);
                  setState(() {}); // Refresh suffix icon visibility
                },
              ),
            ),
          ),
        ],
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Consumer<ShareableMapsGalleryProvider>(
          builder: (context, gallery, _) {
            return _FilterTabs(
              selectedTab: gallery.filterTab,
              onTabChanged: (tab) => gallery.setFilterTab(tab),
            );
          },
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: () {
            context.read<ShareableMapsGalleryProvider>().startListening();
          },
        ),
      ],
    );
  }

  Future<void> _createNewMap(BuildContext context) async {
    final nameController = TextEditingController(
      text: 'Map ${DateFormat('d MMM yyyy').format(DateTime.now())}',
    );
    final descController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Map'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Map name',
                hintText: 'e.g. Deliveries March 2026',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx, {
                'name': nameController.text.trim(),
                'description': descController.text.trim(),
              });
            },
            child: const Text('CREATE'),
          ),
        ],
      ),
    );

    if (result == null || !context.mounted) return;

    final name = result['name']!.isEmpty ? 'Untitled Map' : result['name']!;
    final description = result['description'] ?? '';

    // Create a seed map and open the editor with a Firestore adapter.
    final seed = ShareableMap.createWithDefaultLayer(
      name: name,
      description: description,
    );
    final monthKey = ShareableMapsFirestoreService.monthKeyFor(DateTime.now());
    final service = ShareableMapsFirestoreService();
    final adapter = FirestoreMapAdapter.create(
      seed: seed,
      monthKey: monthKey,
      service: service,
    );

    final provider = context.read<ShareableMapProvider>();
    await provider.loadFromAdapter(adapter);

    // Persist immediately so the map shows up in the gallery.
    await provider.saveToAdapter();

    if (context.mounted) {
      // Update browser URL to the shareable link
      final docId = adapter.docId;
      if (docId != null) {
        final linkService = MapLinkService();
        final code = await linkService.getShareCodeForMap(monthKey, docId);
        if (code != null) {
          url_updater.updateBrowserUrl('/map/$code');
        }
      }

      if (context.mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
        );
        // Reset URL when returning from editor
        url_updater.resetBrowserUrl();
      }
    }
  }
}

// =============================================================================
// Filter Tabs
// =============================================================================

class _FilterTabs extends StatelessWidget {
  final String selectedTab;
  final ValueChanged<String> onTabChanged;

  const _FilterTabs({
    required this.selectedTab,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    const tabs = [
      {'key': 'all', 'label': 'ALL'},
      {'key': 'recent', 'label': 'RECENT'},
    ];

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: tabs.map((tab) {
        final isSelected = selectedTab == tab['key'];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: InkWell(
            onTap: () => onTabChanged(tab['key']!),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: Text(
                tab['label']!,
                style: TextStyle(
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.6),
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// Gallery Body (scrollable grid grouped by month)
// =============================================================================

class _GalleryBody extends StatelessWidget {
  final List<MonthGroup> monthGroups;
  final String filterTab;
  final List<String> unloadedMonths;
  final Set<String> loadingMonths;
  final Future<void> Function(String monthKey) onLoadMonth;

  const _GalleryBody({
    required this.monthGroups,
    required this.filterTab,
    required this.unloadedMonths,
    required this.loadingMonths,
    required this.onLoadMonth,
  });

  @override
  Widget build(BuildContext context) {
    // If filter is 'recent', show a flat grid without month headers.
    if (filterTab == 'recent') {
      final gallery = context.read<ShareableMapsGalleryProvider>();
      final items = gallery.filteredMaps;
      if (items.isEmpty) {
        return const Center(
          child: Text('No recently updated maps.'),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(16),
        child: _MapGrid(items: items),
      );
    }

    // Show the next unloadable month (first in the list).
    final nextMonth = unloadedMonths.isNotEmpty ? unloadedMonths.first : null;
    final totalItems = monthGroups.length + (nextMonth != null ? 1 : 0);

    // Grouped by month + optional load-more button at the bottom.
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: totalItems,
      itemBuilder: (context, index) {
        if (index < monthGroups.length) {
          return _MonthSection(group: monthGroups[index]);
        }
        // Load-more button for the next unloaded month.
        return _LoadMonthTile(
          monthKey: nextMonth!,
          label: ShareableMapsGalleryProvider.formatMonthLabel(nextMonth),
          isLoading: loadingMonths.contains(nextMonth),
          onLoad: () => onLoadMonth(nextMonth),
        );
      },
    );
  }
}

// =============================================================================
// Month Section
// =============================================================================

class _MonthSection extends StatelessWidget {
  final MonthGroup group;

  const _MonthSection({required this.group});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            group.label,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade700,
                ),
          ),
        ),
        _MapGrid(items: group.maps),
        const SizedBox(height: 8),
        const Divider(),
      ],
    );
  }
}

// =============================================================================
// Load Month Tile (progressive disclosure for older months)
// =============================================================================

class _LoadMonthTile extends StatelessWidget {
  final String monthKey;
  final String label;
  final bool isLoading;
  final VoidCallback onLoad;

  const _LoadMonthTile({
    required this.monthKey,
    required this.label,
    required this.isLoading,
    required this.onLoad,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: isLoading
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Loading $label…',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ],
              )
            : OutlinedButton.icon(
                onPressed: onLoad,
                icon: const Icon(Icons.expand_more),
                label: Text('Load $label'),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
      ),
    );
  }
}

// =============================================================================
// Map Grid (responsive tile layout)
// =============================================================================

class _MapGrid extends StatelessWidget {
  final List<MapGalleryItem> items;

  const _MapGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate number of columns based on available width.
        final width = constraints.maxWidth;
        int crossAxisCount;
        if (width > 1200) {
          crossAxisCount = 6;
        } else if (width > 900) {
          crossAxisCount = 4;
        } else if (width > 600) {
          crossAxisCount = 3;
        } else {
          crossAxisCount = 2;
        }

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            return _MapTile(item: items[index]);
          },
        );
      },
    );
  }
}

// =============================================================================
// Map Tile
// =============================================================================

class _MapTile extends StatelessWidget {
  final MapGalleryItem item;

  const _MapTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: () => _openMap(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail area  — static map preview placeholder
            Expanded(
              flex: 4,
              child: _MapThumbnail(item: item),
            ),
            // Info area
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          DateFormat('d MMM yyyy  HH:mm')
                              .format(item.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color.fromARGB(255, 63, 63, 63),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          DateFormat('d MMM yyyy  HH:mm')
                              .format(item.updatedAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color.fromARGB(255, 63, 63, 63),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        _CopyLinkButton(item: item),
                        _TilePopupMenu(item: item),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMap(BuildContext context) async {
    final service = ShareableMapsFirestoreService();
    final adapter = FirestoreMapAdapter.existing(
      docId: item.docId,
      monthKey: item.monthKey,
      service: service,
    );

    final provider = context.read<ShareableMapProvider>();
    try {
      await provider.loadFromAdapter(adapter);
      if (context.mounted) {
        // Update browser URL to the shareable link
        final linkService = MapLinkService();
        final code =
            await linkService.getShareCodeForMap(item.monthKey, item.docId);
        if (code != null) {
          url_updater.updateBrowserUrl('/map/$code');
        }

        if (context.mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
          );
          // Reset URL when returning from editor
          url_updater.resetBrowserUrl();
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open map: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }
}

// =============================================================================
// Map Thumbnail (placeholder with icon + stats)
// =============================================================================

class _MapThumbnail extends StatelessWidget {
  final MapGalleryItem item;

  const _MapThumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Background: real thumbnail or gradient fallback
        if (item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty)
          Image.network(
            item.thumbnailUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _GradientPlaceholder(docId: item.docId),
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return Stack(
                fit: StackFit.expand,
                children: [
                  _GradientPlaceholder(docId: item.docId),
                  Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: loadingProgress.expectedTotalBytes != null
                            ? loadingProgress.cumulativeBytesLoaded /
                                loadingProgress.expectedTotalBytes!
                            : null,
                      ),
                    ),
                  ),
                ],
              );
            },
          )
        else
          _GradientPlaceholder(docId: item.docId),

        // Element count badge
        if (item.elementCount > 0)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${item.elementCount} element${item.elementCount == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        // Layer count badge
        if (item.layerCount > 0)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.layers, size: 12, color: Colors.white),
                  const SizedBox(width: 4),
                  Text(
                    '${item.layerCount}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Deterministic colour based on the map ID for visual variety.
  static Color _colorForMap(String id) {
    final palette = [
      Colors.blue,
      Colors.teal,
      Colors.orange,
      Colors.purple,
      Colors.green,
      Colors.red,
      Colors.indigo,
      Colors.amber,
    ];
    return palette[id.hashCode.abs() % palette.length];
  }
}

/// Gradient + icon fallback when no thumbnail image is available.
class _GradientPlaceholder extends StatelessWidget {
  final String docId;
  const _GradientPlaceholder({required this.docId});

  @override
  Widget build(BuildContext context) {
    final color = _MapThumbnail._colorForMap(docId);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.3),
            color.withValues(alpha: 0.1),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.map_rounded,
          size: 48,
          color: color.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

// =============================================================================
// Copy Link Button (quick copy shareable URL)
// =============================================================================

class _CopyLinkButton extends StatelessWidget {
  final MapGalleryItem item;

  const _CopyLinkButton({required this.item});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.link, size: 18, color: Colors.grey.shade600),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      tooltip: 'Copy shareable link',
      onPressed: () => _copyLink(context),
    );
  }

  Future<void> _copyLink(BuildContext context) async {
    try {
      final linkService = MapLinkService();
      final code = await linkService.createShareLink(
        monthKey: item.monthKey,
        mapId: item.docId,
        mapName: item.name,
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
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to copy link: $e')),
        );
      }
    }
  }
}

// =============================================================================
// Tile Popup Menu (share / delete)
// =============================================================================

class _TilePopupMenu extends StatelessWidget {
  final MapGalleryItem item;

  const _TilePopupMenu({required this.item});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: Colors.grey.shade600),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'share', child: Text('Share link')),
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
      onSelected: (value) async {
        switch (value) {
          case 'share':
            await _shareMap(context);
            break;
          case 'rename':
            await _renameMap(context);
            break;
          case 'delete':
            await _deleteMap(context);
            break;
        }
      },
    );
  }

  Future<void> _shareMap(BuildContext context) async {
    try {
      final linkService = MapLinkService();
      // Get or create share code
      final code = await linkService.createShareLink(
        monthKey: item.monthKey,
        mapId: item.docId,
        mapName: item.name,
      );
      final url = MapLinkService.buildShareUrl(code);

      if (!context.mounted) return;

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
            action: SnackBarAction(
              label: 'OK',
              textColor: Colors.white,
              onPressed: () {},
            ),
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

  Future<void> _renameMap(BuildContext context) async {
    final controller = TextEditingController(text: item.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Map'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Map name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('RENAME'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || !context.mounted) return;

    try {
      final service = ShareableMapsFirestoreService();
      await service
          .updateMapFields(item.monthKey, item.docId, {'name': newName});
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $e')),
        );
      }
    }
  }

  Future<void> _deleteMap(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Map'),
        content: Text('Delete "${item.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );

    if (confirm != true || !context.mounted) return;

    try {
      await context
          .read<ShareableMapsGalleryProvider>()
          .deleteMap(item.monthKey, item.docId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }
}

// =============================================================================
// Empty / Error States
// =============================================================================

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.map_outlined, size: 80, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'No maps yet',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.grey.shade600,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap the button below to create your first shareable map.',
            style: TextStyle(color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;

  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(
              'Failed to load maps',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                context.read<ShareableMapsGalleryProvider>().startListening();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
