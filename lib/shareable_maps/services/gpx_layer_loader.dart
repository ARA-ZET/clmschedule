// shareable_maps/services/gpx_layer_loader.dart
//
// Loads GPX files from Cloud Storage and converts them to MapLayer objects
// for display in ShareableMap.
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';
import '../../services/gpx_storage_service.dart';
import '../models/map_layer.dart';
import '../models/map_point.dart';
import '../models/map_polyline.dart';

class GpxLayerLoader {
  final GpxStorageService _storage;

  GpxLayerLoader({GpxStorageService? storage})
      : _storage = storage ?? GpxStorageService();

  /// Load all GPX files from [folderPath] and convert to [MapLayer] list.
  /// Each GPX file becomes one layer.
  Future<List<MapLayer>> loadLayersFromFolder(String folderPath) async {
    final files = await _storage.listFiles(folderPath);
    if (files.isEmpty) return [];

    final layers = <MapLayer>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final content = await _storage.downloadGpxFile(file.fullPath);
      if (content == null || content.isEmpty) continue;

      try {
        final gpx = GpxReader().fromString(content);
        final layer = _gpxToLayer(file.name, gpx, layers.length);
        if (layer != null) layers.add(layer);
      } catch (e) {
        debugPrint('GpxLayerLoader: failed to parse ${file.name}: $e');
      }
    }
    return layers;
  }

  /// Convert a parsed GPX to a MapLayer.
  MapLayer? _gpxToLayer(String fileName, Gpx gpx, int order) {
    final now = DateTime.now();
    final polylines = <MapPolyline>[];
    final points = <MapPoint>[];

    // Convert tracks to polylines
    for (var ti = 0; ti < gpx.trks.length; ti++) {
      final trk = gpx.trks[ti];
      for (var si = 0; si < trk.trksegs.length; si++) {
        final seg = trk.trksegs[si];
        if (seg.trkpts.isEmpty) continue;
        final latlngs = seg.trkpts
            .where((p) => p.lat != null && p.lon != null)
            .map((p) => LatLng(p.lat!, p.lon!))
            .toList();
        if (latlngs.length < 2) continue;
        polylines.add(MapPolyline(
          id: 'gpx_trk_${ti}_$si',
          name: trk.name ?? 'Track ${ti + 1}',
          points: latlngs,
          color: Colors.blue,
          strokeWidth: 3.0,
          createdAt: now,
          updatedAt: now,
        ));
      }
    }

    // Convert waypoints to points
    for (var wi = 0; wi < gpx.wpts.length; wi++) {
      final wpt = gpx.wpts[wi];
      if (wpt.lat == null || wpt.lon == null) continue;
      points.add(MapPoint(
        id: 'gpx_wpt_$wi',
        name: wpt.name ?? 'Waypoint ${wi + 1}',
        description: wpt.desc ?? '',
        position: LatLng(wpt.lat!, wpt.lon!),
        color: Colors.red,
        createdAt: now,
        updatedAt: now,
      ));
    }

    if (polylines.isEmpty && points.isEmpty) return null;

    // Strip .gpx extension for layer name
    final layerName =
        fileName.replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '');

    return MapLayer(
      id: 'cloud_${fileName.hashCode}',
      name: layerName,
      description: 'Loaded from cloud: $fileName',
      order: order,
      defaultColor: Colors.blue,
      polylines: polylines,
      points: points,
      createdAt: now,
      updatedAt: now,
    );
  }
}
