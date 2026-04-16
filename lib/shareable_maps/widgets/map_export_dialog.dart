import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../providers/shareable_map_provider.dart';
import '../services/map_export_service.dart';

/// Dialog for exporting shareable maps to KML format
class MapExportDialog extends riverpod.ConsumerStatefulWidget {
  const MapExportDialog({super.key});

  @override
  riverpod.ConsumerState<MapExportDialog> createState() =>
      _MapExportDialogState();
}

class _MapExportDialogState extends riverpod.ConsumerState<MapExportDialog> {
  bool _isExporting = false;
  String? _errorMessage;
  final Set<String> _selectedLayerIds = {};
  bool _selectAll = true;

  @override
  void initState() {
    super.initState();
    // Select all layers by default
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = ref.read(shareableMapRiverpod);
      if (provider.currentMap != null) {
        setState(() {
          _selectedLayerIds.addAll(
            provider.currentMap!.layers.map((layer) => layer.id),
          );
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    final map = provider.currentMap;

    if (map == null) {
      return AlertDialog(
        title: const Text('Export Map'),
        content: const Text('No map to export'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Export Map'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Export "${map.name}" to KML format',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // Select All/None
            CheckboxListTile(
              title: const Text('Select All Layers'),
              value: _selectAll,
              onChanged: (value) {
                setState(() {
                  _selectAll = value ?? false;
                  if (_selectAll) {
                    _selectedLayerIds.addAll(
                      map.layers.map((layer) => layer.id),
                    );
                  } else {
                    _selectedLayerIds.clear();
                  }
                });
              },
            ),
            const Divider(),

            // Layer selection
            const Text(
              'Select layers to export:',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 8),

            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: map.layers.length,
                itemBuilder: (context, index) {
                  final layer = map.layers[index];
                  final isSelected = _selectedLayerIds.contains(layer.id);

                  return CheckboxListTile(
                    dense: true,
                    title: Text(layer.name),
                    subtitle: Text(
                      '${layer.elementCount} element(s)',
                      style: const TextStyle(fontSize: 12),
                    ),
                    secondary: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: layer.defaultColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.grey),
                      ),
                    ),
                    value: isSelected,
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selectedLayerIds.add(layer.id);
                        } else {
                          _selectedLayerIds.remove(layer.id);
                        }
                        _selectAll =
                            _selectedLayerIds.length == map.layers.length;
                      });
                    },
                  );
                },
              ),
            ),

            // Export info
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Exported KML can be imported into Google My Maps, Google Earth, and other mapping applications.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

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
            if (_isExporting) ...[
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
          onPressed: _isExporting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed:
              _isExporting || _selectedLayerIds.isEmpty ? null : _exportMap,
          icon: const Icon(Icons.download),
          label: const Text('Export KML'),
        ),
      ],
    );
  }

  Future<void> _exportMap() async {
    setState(() {
      _isExporting = true;
      _errorMessage = null;
    });

    try {
      final provider = ref.read(shareableMapRiverpod);
      final map = provider.currentMap!;

      // Filter selected layers
      final selectedLayers = map.layers
          .where((layer) => _selectedLayerIds.contains(layer.id))
          .toList();

      // Export to KML
      final kmlString = MapExportService.exportToKml(
        map.copyWith(layers: selectedLayers),
      );

      // Download file
      await MapExportService.downloadKmlFile(
        kmlString,
        '${map.name.replaceAll(' ', '_')}.kml',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported ${selectedLayers.length} layer(s) to KML'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error exporting map: $e';
        _isExporting = false;
      });
    }
  }
}
