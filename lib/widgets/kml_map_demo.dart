import 'dart:math' show min, max;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../services/kml_parser_service.dart';
import '../models/custom_polygon.dart';
import '../widgets/mymaps_kml_downloader.dart';

/// Demo widget showing how to use MyMapsKmlDownloader with KmlParserService
/// to download KML files and display custom polygons on a map
class KmlMapDemo extends StatefulWidget {
  const KmlMapDemo({super.key});

  @override
  State<KmlMapDemo> createState() => _KmlMapDemoState();
}

class _KmlMapDemoState extends State<KmlMapDemo> {
  GoogleMapController? _controller;
  List<CustomPolygon> _customPolygons = [];
  Set<Polygon> _mapPolygons = {};
  String? _statusMessage;
  bool _isProcessing = false;

  // Cape Town coordinates
  static const LatLng _kCapeTeam = LatLng(-33.9249, 18.4241);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KML Map Integration Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // KML Downloader Section
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                MyMapsKmlDownloader(
                  onKmlDataRetrieved: _handleKmlData,
                ),
                if (_statusMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _isProcessing
                          ? Colors.blue.withOpacity(0.1)
                          : Colors.green.withOpacity(0.1),
                      border: Border.all(
                        color: _isProcessing ? Colors.blue : Colors.green,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        if (_isProcessing)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          const Icon(Icons.check_circle, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _statusMessage!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_customPolygons.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Loaded Polygons (${_customPolygons.length}):',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        ...(_customPolygons.take(5).map((polygon) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                children: [
                                  Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      color: polygon.color,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      polygon.name,
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    '${polygon.points.length} pts',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: Colors.grey[600],
                                        ),
                                  ),
                                ],
                              ),
                            ))),
                        if (_customPolygons.length > 5)
                          Text(
                            '... and ${_customPolygons.length - 5} more',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.grey[600],
                                    ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Map Section
          Expanded(
            child: GoogleMap(
              initialCameraPosition: const CameraPosition(
                target: _kCapeTeam,
                zoom: 10,
              ),
              polygons: _mapPolygons,
              onMapCreated: (GoogleMapController controller) {
                _controller = controller;
              },
              mapType: MapType.hybrid,
            ),
          ),
        ],
      ),
    );
  }

  /// Handle KML data retrieved from MyMapsKmlDownloader
  void _handleKmlData(Uint8List kmlBytes, String fileName) async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Processing KML file: $fileName...';
    });

    try {
      // Parse KML data using KmlParserService
      final polygons = await KmlParserService.parseKmlData(kmlBytes, fileName);

      setState(() {
        _customPolygons = polygons;
        _statusMessage =
            'Successfully loaded ${polygons.length} polygons from $fileName';
        _isProcessing = false;
      });

      // Convert CustomPolygon objects to Google Maps Polygon objects
      _updateMapPolygons();

      // Move camera to show all polygons
      if (polygons.isNotEmpty) {
        _fitCameraToPolygons();
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error processing KML: ${e.toString()}';
        _isProcessing = false;
      });

      // Show error dialog
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('KML Processing Error'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  /// Update map polygons from custom polygons
  void _updateMapPolygons() {
    final mapPolygons = <Polygon>{};

    for (int i = 0; i < _customPolygons.length; i++) {
      final customPolygon = _customPolygons[i];

      mapPolygons.add(
        Polygon(
          polygonId: PolygonId('polygon_$i'),
          points: customPolygon.points,
          strokeColor: customPolygon.color,
          strokeWidth: 2,
          fillColor: customPolygon.color.withOpacity(0.3),
          consumeTapEvents: true,
          onTap: () => _showPolygonInfo(customPolygon),
        ),
      );
    }

    setState(() {
      _mapPolygons = mapPolygons;
    });
  }

  /// Show polygon information dialog
  void _showPolygonInfo(CustomPolygon polygon) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(polygon.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (polygon.description.isNotEmpty) ...[
              const Text('Description:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(polygon.description),
              const SizedBox(height: 16),
            ],
            const Text('Details:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Points: ${polygon.points.length}'),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Color: '),
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: polygon.color,
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Fit camera to show all polygons
  void _fitCameraToPolygons() async {
    if (_controller == null || _customPolygons.isEmpty) return;

    double minLat = double.infinity;
    double maxLat = -double.infinity;
    double minLng = double.infinity;
    double maxLng = -double.infinity;

    // Find bounds of all polygons
    for (final polygon in _customPolygons) {
      for (final point in polygon.points) {
        minLat = min(minLat, point.latitude);
        maxLat = max(maxLat, point.latitude);
        minLng = min(minLng, point.longitude);
        maxLng = max(maxLng, point.longitude);
      }
    }

    // Add padding
    const padding = 0.01;
    final bounds = LatLngBounds(
      northeast: LatLng(maxLat + padding, maxLng + padding),
      southwest: LatLng(minLat - padding, minLng - padding),
    );

    await _controller!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 50.0),
    );
  }
}
