import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/shareable_map_provider.dart';
import '../../services/kml_parser_service.dart';
import '../../widgets/mymaps_kml_downloader.dart';

/// Dialog for importing KML/GPX files into shareable maps
class MapImportDialog extends StatefulWidget {
  const MapImportDialog({super.key});

  @override
  State<MapImportDialog> createState() => _MapImportDialogState();
}

class _MapImportDialogState extends State<MapImportDialog> {
  bool _isLoading = false;
  String? _errorMessage;
  int _selectedImportType = 0; // 0 = File, 1 = Google My Maps URL

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
                  label: Text('Google My Maps'),
                  icon: Icon(Icons.link),
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
            else
              _buildUrlImportSection(),

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
          'Import from Google My Maps URL',
          style: TextStyle(fontSize: 14, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        MyMapsKmlDownloader(
          onKmlDataRetrieved: (kmlBytes, fileName) {
            _handleKmlData(kmlBytes, fileName);
          },
        ),
      ],
    );
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
      final provider = context.read<ShareableMapProvider>();

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
