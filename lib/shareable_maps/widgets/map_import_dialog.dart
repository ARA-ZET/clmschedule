import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:file_picker/file_picker.dart';
import '../../models/custom_polygon.dart';
import '../models/map_point.dart';
import '../models/map_polyline.dart';
import '../providers/shareable_map_provider.dart';
import '../services/map_link_service.dart';
import '../services/shareable_maps_firestore_service.dart';
import '../../providers/cloud_file_manager_provider.dart';
import '../../services/gpx_storage_service.dart';
import '../../services/kml_parser_service.dart';
import '../../widgets/mymaps_kml_downloader.dart';

/// Dialog for importing KML/GPX files into shareable maps
class MapImportDialog extends riverpod.ConsumerStatefulWidget {
  const MapImportDialog({super.key});

  @override
  riverpod.ConsumerState<MapImportDialog> createState() =>
      _MapImportDialogState();
}

class _MapImportDialogState extends riverpod.ConsumerState<MapImportDialog> {
  bool _isLoading = false;
  String? _errorMessage;
  int _selectedImportType = 0; // 0 = File, 1 = URL / Link, 2 = Cloud

  // URL import state
  final TextEditingController _urlController = TextEditingController();
  _LinkType? _detectedLinkType;
  String? _clmMapName;
  List<_ImportableElement> _clmElements = [];

  // Cloud browser state
  final CloudFileManagerProvider _cloudProvider = CloudFileManagerProvider();
  bool _cloudInitialized = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import Map Data'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Import type selector
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('File'),
                  icon: Icon(Icons.upload_file),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('URL / Link'),
                  icon: Icon(Icons.link),
                ),
                ButtonSegment(
                  value: 2,
                  label: Text('Cloud Files'),
                  icon: Icon(Icons.cloud),
                ),
              ],
              selected: {_selectedImportType},
              onSelectionChanged: (Set<int> selection) {
                setState(() {
                  _selectedImportType = selection.first;
                  _errorMessage = null;
                });
              },
            ),
            const SizedBox(height: 24),

            // Import content based on type
            if (_selectedImportType == 0)
              _buildFileImportSection()
            else if (_selectedImportType == 1)
              _buildUrlImportSection()
            else
              _buildCloudImportSection(),

            // Error message
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Loading indicator
            if (_isLoading) ...[
              const SizedBox(height: 16),
              const Center(
                child: CircularProgressIndicator(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildFileImportSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select a KML or GPX file to import',
          style: TextStyle(fontSize: 14, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        Center(
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _pickAndImportFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose File'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Supported formats: .kml, .kmz, .gpx',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Widget _buildUrlImportSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Paste a CLM Maps or Google My Maps link',
          style: TextStyle(fontSize: 14, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        // URL input + Load button
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Map link',
                  hintText:
                      'https://clm-maps.web.app/map/... or Google My Maps link',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _resolveUrl(),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _isLoading ? null : _resolveUrl,
              child: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Load'),
            ),
          ],
        ),
        // CLM Maps element list with checkboxes
        if (_detectedLinkType == _LinkType.clmMaps &&
            _clmElements.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '$_clmMapName — ${_clmElements.length} element(s)',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () {
                  final allSelected = _clmElements.every((e) => e.selected);
                  setState(() {
                    for (final e in _clmElements) {
                      e.selected = !allSelected;
                    }
                  });
                },
                child: Text(
                  _clmElements.every((e) => e.selected)
                      ? 'Deselect all'
                      : 'Select all',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const Divider(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _clmElements.length,
              itemBuilder: (context, index) {
                final el = _clmElements[index];
                return CheckboxListTile(
                  value: el.selected,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  secondary: Icon(el.icon, size: 18, color: el.color),
                  title: Text(el.name, style: const TextStyle(fontSize: 12)),
                  subtitle: Text('${el.typeLabel} · ${el.layerName}',
                      style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  onChanged: (v) {
                    setState(() => el.selected = v ?? false);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: _clmElements.any((e) => e.selected)
                  ? _importSelectedClmElements
                  : null,
              child: Text(
                'Import (${_clmElements.where((e) => e.selected).length})',
              ),
            ),
          ),
        ],
        // Google My Maps downloader (shown after detection)
        if (_detectedLinkType == _LinkType.googleMyMaps) ...[
          const SizedBox(height: 16),
          MyMapsKmlDownloader(
            initialUrl: _urlController.text.trim(),
            onKmlDataRetrieved: (kmlBytes, fileName) {
              _handleKmlData(kmlBytes, fileName);
            },
          ),
        ],
      ],
    );
  }

  /// Detect link type from URL and act accordingly.
  Future<void> _resolveUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _errorMessage = 'Please enter a link');
      return;
    }

    // Check for CLM Maps link
    String? shareCode = MapLinkService.extractShareCode(url);
    // Also accept a raw share code (short alphanumeric, no slashes)
    shareCode ??= (url.length <= 12 && !url.contains('/')) ? url : null;

    if (shareCode != null) {
      await _loadClmMap(shareCode);
      return;
    }

    // Check for Google My Maps link
    try {
      final uri = Uri.parse(url);
      if (uri.host.contains('google.com') || uri.host.contains('google.co')) {
        setState(() {
          _detectedLinkType = _LinkType.googleMyMaps;
          _errorMessage = null;
          _clmElements = [];
        });
        return;
      }
    } catch (_) {}

    // Unrecognized
    setState(() {
      _errorMessage =
          'Unrecognized link format. Use a CLM Maps link (clm-maps.web.app/map/...) or a Google My Maps link.';
      _detectedLinkType = null;
      _clmElements = [];
    });
  }

  /// Resolve a CLM Maps share code → load map → extract elements.
  Future<void> _loadClmMap(String shareCode) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _detectedLinkType = _LinkType.clmMaps;
      _clmElements = [];
      _clmMapName = null;
    });

    try {
      final linkData = await MapLinkService().resolveShareCode(shareCode);
      if (!mounted) return;
      if (linkData == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Share link not found';
        });
        return;
      }

      final map = await ShareableMapsFirestoreService()
          .getMap(linkData.monthKey, linkData.mapId);
      if (!mounted) return;
      if (map == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Map not found';
        });
        return;
      }

      final elements = <_ImportableElement>[];
      for (final layer in map.layers) {
        for (final poly in layer.polygons) {
          elements.add(_ImportableElement(
            layerName: layer.name,
            name: poly.name.isNotEmpty ? poly.name : 'Unnamed polygon',
            typeLabel: 'Polygon',
            icon: Icons.pentagon_outlined,
            color: poly.color,
            polygon: poly,
            polyline: null,
            point: null,
          ));
        }
        for (final pl in layer.polylines) {
          elements.add(_ImportableElement(
            layerName: layer.name,
            name: pl.name.isNotEmpty ? pl.name : 'Unnamed polyline',
            typeLabel: 'Polyline',
            icon: Icons.timeline,
            color: pl.color,
            polygon: null,
            polyline: pl,
            point: null,
          ));
        }
        for (final pt in layer.points) {
          elements.add(_ImportableElement(
            layerName: layer.name,
            name: pt.name.isNotEmpty ? pt.name : 'Unnamed point',
            typeLabel: 'Point',
            icon: Icons.place,
            color: pt.color,
            polygon: null,
            polyline: null,
            point: pt,
          ));
        }
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _clmMapName = map.name;
        _clmElements = elements;
        if (elements.isEmpty) {
          _errorMessage = 'Map has no elements to import';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load map: $e';
      });
    }
  }

  /// Import selected CLM elements into the shareable map.
  void _importSelectedClmElements() {
    final selected = _clmElements.where((e) => e.selected).toList();
    if (selected.isEmpty) return;

    final provider = ref.read(shareableMapRiverpod);

    if (provider.currentMap == null) {
      provider.createNewMap(
        name: _clmMapName ?? 'Imported Map',
        description: 'Imported from CLM Maps link',
      );
    }

    provider.createLayer(
      name: 'Imported - ${_clmMapName ?? 'CLM Maps'}',
      description: 'Imported on ${DateTime.now()}',
    );

    final layer = provider.selectedLayer;
    if (layer == null || provider.currentMap == null) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to create import layer';
        });
      }
      return;
    }

    var updatedLayer = layer;
    for (final el in selected) {
      if (el.polygon != null) {
        updatedLayer = updatedLayer.addPolygon(el.polygon!);
      } else if (el.polyline != null) {
        updatedLayer = updatedLayer.addPolyline(el.polyline!);
      } else if (el.point != null) {
        updatedLayer = updatedLayer.addPoint(el.point!);
      }
    }

    final updatedMap = provider.currentMap!.updateLayer(layer.id, updatedLayer);
    provider.loadMap(updatedMap);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported ${selected.length} element(s) from CLM Maps'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context, true);
    }
  }

  Widget _buildCloudImportSection() {
    // Lazy-init the cloud provider on first show
    if (!_cloudInitialized) {
      _cloudInitialized = true;
      _cloudProvider.addListener(() {
        if (mounted) setState(() {});
      });
      _cloudProvider.loadCurrentFolder();
    }

    final provider = ref.read(shareableMapRiverpod);
    final linkedFolder = provider.currentMap?.storageFolderPath;
    final hasLink = linkedFolder != null && linkedFolder.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Linked folder status
        if (hasLink) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Row(
              children: [
                const Icon(Icons.link, color: Colors.green, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Linked Folder',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.green)),
                      Text(linkedFolder,
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[600]),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.link_off, color: Colors.red, size: 18),
                  tooltip: 'Unlink folder',
                  onPressed: () {
                    provider.unlinkCloudFolder();
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        const Text(
          'Browse Cloud Storage to link a folder or import files',
          style: TextStyle(fontSize: 14, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        // Breadcrumbs
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              InkWell(
                onTap: _cloudProvider.isAtRoot
                    ? null
                    : () => _cloudProvider.goToRoot(),
                child: Icon(Icons.cloud,
                    size: 18,
                    color: _cloudProvider.isAtRoot
                        ? Colors.blue
                        : Colors.grey[600]),
              ),
              for (int i = 0; i < _cloudProvider.breadcrumbs.length; i++) ...[
                Icon(Icons.chevron_right, size: 16, color: Colors.grey[400]),
                InkWell(
                  onTap: i == _cloudProvider.breadcrumbs.length - 1
                      ? null
                      : () => _cloudProvider.goToBreadcrumb(i),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      _cloudProvider.breadcrumbs[i].name,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: i == _cloudProvider.breadcrumbs.length - 1
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: i == _cloudProvider.breadcrumbs.length - 1
                            ? Colors.blue
                            : Colors.grey[700],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 12),
        // Link folder button (only when inside a folder, not at root)
        if (!_cloudProvider.isAtRoot) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.link, size: 18),
              label: Text(
                'Link "${_cloudProvider.breadcrumbs.last.name}" to this map',
                style: const TextStyle(fontSize: 13),
              ),
              onPressed: () {
                final folderName = _cloudProvider.breadcrumbs.last.name;
                provider.linkCloudFolder(_cloudProvider.currentPath);
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Folder linked: $folderName'),
                    backgroundColor: Colors.green,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        // Contents
        if (_cloudProvider.isLoading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_cloudProvider.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_cloudProvider.error!,
                style: TextStyle(color: Colors.red[700], fontSize: 13)),
          )
        else
          SizedBox(
            height: 220,
            child: _cloudProvider.folders.isEmpty &&
                    _cloudProvider.files.isEmpty
                ? Center(
                    child: Text('Empty folder',
                        style: TextStyle(color: Colors.grey[500])),
                  )
                : ListView(
                    children: [
                      for (final folder in _cloudProvider.folders)
                        Material(
                          type: MaterialType.transparency,
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder,
                                color: Colors.amber, size: 24),
                            title: Text(folder.name,
                                style: const TextStyle(fontSize: 13)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () => _cloudProvider.openFolder(folder),
                          ),
                        ),
                      for (final file in _cloudProvider.files)
                        _buildCloudFileTile(file),
                    ],
                  ),
          ),
      ],
    );
  }

  Widget _buildCloudFileTile(StorageFileItem file) {
    final ext = file.extension;
    final canImport = ['gpx', 'kml', 'kmz'].contains(ext);
    final icon = ext == 'gpx'
        ? Icons.route
        : ext == 'kml' || ext == 'kmz'
            ? Icons.map
            : Icons.insert_drive_file;
    final color = canImport ? Colors.green : Colors.grey;

    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        dense: true,
        leading: Icon(icon, color: color, size: 22),
        title: Text(file.name, style: const TextStyle(fontSize: 13)),
        subtitle: Text(ext.toUpperCase(),
            style: TextStyle(fontSize: 10, color: Colors.grey[500])),
        trailing: canImport
            ? TextButton.icon(
                icon: const Icon(Icons.download, size: 16),
                label: const Text('Import', style: TextStyle(fontSize: 12)),
                onPressed: _isLoading ? null : () => _importCloudFile(file),
              )
            : null,
        onTap: canImport && !_isLoading ? () => _importCloudFile(file) : null,
      ),
    );
  }

  Future<void> _importCloudFile(StorageFileItem file) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final bytes = await _cloudProvider.downloadFile(file);
      if (bytes == null) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Failed to download ${file.name}';
            _isLoading = false;
          });
        }
        return;
      }
      await _handleKmlData(bytes, file.name);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error loading cloud file: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _pickAndImportFile() async {
    // Don't show spinner yet — wait until we actually have a file to parse
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['kml', 'kmz', 'gpx'],
        withData: true,
      );

      if (!mounted) return;

      if (result == null || result.files.isEmpty) {
        // User cancelled — nothing to do
        return;
      }

      final file = result.files.first;
      if (file.bytes == null) {
        setState(() {
          _errorMessage = 'Could not read file data';
        });
        return;
      }

      await _handleKmlData(file.bytes!, file.name);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error importing file: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleKmlData(Uint8List kmlBytes, String fileName) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    bool dialogWillClose = false;
    try {
      // Parse KML/GPX data
      final result = await KmlParserService.parseKmlData(kmlBytes, fileName);

      if (!mounted) return;

      if (result.isEmpty) {
        setState(() {
          _errorMessage = 'No map elements found in file';
          _isLoading = false;
        });
        return;
      }

      // Show import preview — stop spinner while user reviews
      setState(() => _isLoading = false);

      final shouldImport = await _showImportPreview(result, fileName);

      if (!mounted) return;

      if (shouldImport != true) return; // user cancelled

      // Commit import
      setState(() => _isLoading = true);
      final provider = ref.read(shareableMapRiverpod);

      if (provider.currentMap == null) {
        provider.createNewMap(
          name: fileName.replaceAll(RegExp(r'\.(kml|kmz|gpx)$'), ''),
          description: 'Imported from $fileName',
        );
      }

      provider.createLayer(
        name: 'Imported - $fileName',
        description: 'Imported on ${DateTime.now()}',
      );

      final layer = provider.selectedLayer;
      if (layer != null) {
        var updatedLayer = layer;
        for (final polygon in result.polygons) {
          updatedLayer = updatedLayer.addPolygon(polygon);
        }
        for (final polyline in result.polylines) {
          updatedLayer = updatedLayer.addPolyline(polyline);
        }
        for (final point in result.points) {
          updatedLayer = updatedLayer.addPoint(point);
        }

        final updatedMap =
            provider.currentMap!.updateLayer(layer.id, updatedLayer);
        provider.loadMap(updatedMap);

        final parts = [
          if (result.polygons.isNotEmpty)
            '${result.polygons.length} polygon(s)',
          if (result.polylines.isNotEmpty)
            '${result.polylines.length} track(s)/polyline(s)',
          if (result.points.isNotEmpty) '${result.points.length} point(s)',
        ];

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported ${parts.join(', ')} from $fileName'),
            backgroundColor: Colors.green,
          ),
        );
      }

      dialogWillClose = true;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error parsing file: $e';
          _isLoading = false;
        });
      }
    } finally {
      // Only reset loading if we're still showing the dialog
      if (mounted && !dialogWillClose) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<bool?> _showImportPreview(ParsedMapResult result, String fileName) {
    // Build a flat list of items for display
    final items = [
      ...result.polygons.map((e) => _PreviewItem(
            icon: Icons.pentagon_outlined,
            color: Colors.blue,
            label: e.name.isEmpty ? 'Unnamed Polygon' : e.name,
            detail: '${e.points.length} pts',
          )),
      ...result.polylines.map((e) => _PreviewItem(
            icon: Icons.polyline_outlined,
            color: Colors.green,
            label: e.name.isEmpty ? 'Unnamed Track' : e.name,
            detail: '${e.points.length} pts',
          )),
      ...result.points.map((e) => _PreviewItem(
            icon: Icons.place_outlined,
            color: Colors.red,
            label: e.name.isEmpty ? 'Unnamed Point' : e.name,
            detail: '',
          )),
    ];

    final visibleCount = items.length.clamp(0, 12);
    // Use a fixed height to avoid asking the ListView for intrinsic dimensions,
    // which causes RenderShrinkWrappingViewport assertion errors.
    final listHeight = (visibleCount * 52.0).clamp(0.0, 220.0);

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Preview'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'File: $fileName',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              // Summary chips
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (result.polygons.isNotEmpty)
                    _SummaryChip(
                      icon: Icons.pentagon_outlined,
                      label: '${result.polygons.length} Polygon(s)',
                      color: Colors.blue,
                    ),
                  if (result.polylines.isNotEmpty)
                    _SummaryChip(
                      icon: Icons.polyline_outlined,
                      label:
                          '${result.polylines.length} Track(s) / Polyline(s)',
                      color: Colors.green,
                    ),
                  if (result.points.isNotEmpty)
                    _SummaryChip(
                      icon: Icons.place_outlined,
                      label: '${result.points.length} Point(s)',
                      color: Colors.red,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: listHeight,
                child: ListView.builder(
                  itemCount: visibleCount,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(item.icon, size: 16, color: item.color),
                      title: Text(item.label,
                          style: const TextStyle(fontSize: 13)),
                      trailing: item.detail.isNotEmpty
                          ? Text(item.detail,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey))
                          : null,
                    );
                  },
                ),
              ),
              if (items.length > 12)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '... and ${items.length - 12} more',
                    style: const TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: Colors.grey),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Import ${result.totalCount} element(s)'),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Small helper types used only by this file
// ────────────────────────────────────────────────────────────────────────────

class _PreviewItem {
  final IconData icon;
  final Color color;
  final String label;
  final String detail;
  const _PreviewItem(
      {required this.icon,
      required this.color,
      required this.label,
      required this.detail});
}

class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _SummaryChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 14, color: color),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}

enum _LinkType { clmMaps, googleMyMaps }

class _ImportableElement {
  final String layerName;
  final String name;
  final String typeLabel;
  final IconData icon;
  final Color color;
  final CustomPolygon? polygon;
  final MapPolyline? polyline;
  final MapPoint? point;
  bool selected = true;

  _ImportableElement({
    required this.layerName,
    required this.name,
    required this.typeLabel,
    required this.icon,
    required this.color,
    required this.polygon,
    required this.polyline,
    required this.point,
  });
}
