import 'dart:ui' show Color;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../../env.dart';

/// A path (polygon or polyline) with its display color for thumbnail rendering.
class ThumbnailPathData {
  final List<LatLng> points;
  final Color color;
  final double fillOpacity;

  const ThumbnailPathData({
    required this.points,
    required this.color,
    this.fillOpacity = 0.35,
  });
}

/// Hybrid thumbnail service: generates a Google Maps Static API URL,
/// fetches the image **once**, uploads it to Firebase Storage, and returns
/// the Storage download URL. Gallery views then load from Storage (free
/// egress) instead of hitting the Static API on every page load.
///
/// Storage path: `mapThumbnails/{monthKey}_{docId}.jpg`
class MapThumbnailService {
  final FirebaseStorage _storage;

  MapThumbnailService({FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  /// Default image dimensions for thumbnails.
  static const int _width = 400;
  static const int _height = 300;

  /// Base URL for the Static Maps API.
  static const String _baseUrl =
      'https://maps.googleapis.com/maps/api/staticmap';

  /// Storage folder.
  static const String _folder = 'mapThumbnails';

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Generate a Static Maps image, download it, upload to Firebase Storage,
  /// and return the Storage download URL.
  ///
  /// Returns `null` if any step fails (non-fatal).
  Future<String?> generateAndUploadThumbnail({
    required String monthKey,
    required String docId,
    required LatLng center,
    required double zoom,
    LatLngBounds? bounds,
    List<ThumbnailPathData>? polygons,
    List<ThumbnailPathData>? polylines,
  }) async {
    try {
      // 1. Build the Static Maps URL.
      final staticUrl = buildThumbnailUrl(
        center: center,
        zoom: zoom,
        bounds: bounds,
        polygons: polygons,
        polylines: polylines,
      );

      // 2. Download the image bytes from Google.
      final response = await http.get(Uri.parse(staticUrl));
      if (response.statusCode != 200) {
        debugPrint('[MapThumbnail] Static API returned ${response.statusCode}');
        return null;
      }
      final imageBytes = response.bodyBytes;
      if (imageBytes.isEmpty) return null;

      // 3. Upload to Firebase Storage.
      final path = '$_folder/${monthKey}_$docId.png';
      final ref = _storage.ref().child(path);
      await ref.putData(
        Uint8List.fromList(imageBytes),
        SettableMetadata(
          contentType: 'image/png',
          cacheControl: 'public, max-age=86400', // cache 24h
        ),
      );

      // 4. Return the Storage download URL.
      final downloadUrl = await ref.getDownloadURL();
      debugPrint('[MapThumbnail] Uploaded thumbnail ($path) '
          '– ${imageBytes.length} bytes');
      return downloadUrl;
    } catch (e) {
      debugPrint('[MapThumbnail] Generate+upload failed: $e');
      return null;
    }
  }

  /// Delete the thumbnail image from Storage (e.g. when a map is deleted).
  Future<void> deleteThumbnail({
    required String monthKey,
    required String docId,
  }) async {
    try {
      final path = '$_folder/${monthKey}_$docId.png';
      await _storage.ref().child(path).delete();
      debugPrint('[MapThumbnail] Deleted thumbnail: $path');
    } catch (e) {
      // May fail if the file doesn't exist – that's fine.
      debugPrint('[MapThumbnail] Delete skipped/failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Static Maps URL builder
  // ---------------------------------------------------------------------------

  /// Build a Google Maps Static API thumbnail URL for a map with the given
  /// [center], [zoom], and optional visible [bounds].
  ///
  /// If [bounds] is provided the API will auto-fit the viewport; otherwise
  /// [center] + [zoom] are used.
  ///
  /// Optionally pass simplified [polygonPoints] and [polylinePoints] to render
  /// lightweight path overlays on the thumbnail. Points are simplified (every
  /// Nth vertex) to stay well within the ~8192-char URL limit.
  static String buildThumbnailUrl({
    required LatLng center,
    required double zoom,
    LatLngBounds? bounds,
    List<ThumbnailPathData>? polygons,
    List<ThumbnailPathData>? polylines,
    int width = _width,
    int height = _height,
  }) {
    final apiKey = Env.googleMapsApiKey;

    final params = <String>[
      'size=${width}x$height',
      'scale=2', // retina
      'maptype=roadmap',
      'key=$apiKey',
      // Clean map style — minimal look for thumbnails
      'style=feature:poi|visibility:off',
      'style=feature:poi.park|element:geometry|visibility:on|color:0xc8e6c9',
      'style=feature:transit|visibility:off',
      'style=feature:road|element:labels.icon|visibility:off',
      'style=feature:road.highway|element:geometry.fill|color:0xffd54f',
      'style=feature:road.highway|element:geometry.stroke|color:0xffca28',
      'style=feature:road.arterial|element:geometry.fill|color:0xffffff',
      'style=feature:road.local|element:geometry.fill|color:0xf5f5f5',
      'style=feature:water|element:geometry|color:0xbbdefb',
      'style=feature:landscape|element:geometry|color:0xf5f5f5',
      'style=element:labels.text.fill|color:0x616161',
      'style=element:labels.text.stroke|color:0xffffff',
    ];

    // Use bounds if available for auto-fit, otherwise center + zoom.
    if (bounds != null) {
      // The Static Maps API supports "visible" to auto-fit.
      params.add(
        'visible=${bounds.southwest.latitude},${bounds.southwest.longitude}'
        '|${bounds.northeast.latitude},${bounds.northeast.longitude}',
      );
    } else {
      params.add('center=${center.latitude},${center.longitude}');
      params.add('zoom=${zoom.round()}');
    }

    // Add polygon paths (simplified) — filled areas with actual colors
    if (polygons != null) {
      for (final poly in polygons) {
        final simplified = _simplifyPath(poly.points, maxPoints: 30);
        if (simplified.length < 3) continue;
        final pathStr =
            simplified.map((p) => '${p.latitude},${p.longitude}').join('|');
        final strokeHex = _colorToHex(poly.color, 0.8);
        final fillHex = _colorToHex(poly.color, poly.fillOpacity);
        params.add(
          'path=color:$strokeHex|fillcolor:$fillHex|weight:2|$pathStr',
        );
      }
    }

    // Add polyline paths (simplified) with actual colors
    if (polylines != null) {
      for (final line in polylines) {
        final simplified = _simplifyPath(line.points, maxPoints: 40);
        if (simplified.length < 2) continue;
        final pathStr =
            simplified.map((p) => '${p.latitude},${p.longitude}').join('|');
        final hex = _colorToHex(line.color, 1.0);
        params.add('path=color:$hex|weight:3|$pathStr');
      }
    }

    final url = '$_baseUrl?${params.join('&')}';

    // Safety: if the URL exceeds the limit, fall back to center-only.
    if (url.length > 8100) {
      debugPrint('[MapThumbnail] URL too long (${url.length}), '
          'falling back to center-only thumbnail');
      return _centerOnlyUrl(center, zoom, width, height, apiKey);
    }

    return url;
  }

  /// Convert a [Color] to a hex string for the Static Maps API.
  /// Format: `0xRRGGBBAA` where AA is the [opacity] mapped to 0-255.
  static String _colorToHex(Color color, double opacity) {
    final r = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
    final g = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
    final b = (color.b * 255).round().toRadixString(16).padLeft(2, '0');
    final a = (opacity.clamp(0.0, 1.0) * 255)
        .round()
        .toRadixString(16)
        .padLeft(2, '0');
    return '0x$r$g$b$a';
  }

  /// Minimal fallback URL with just center + zoom (no paths).
  static String _centerOnlyUrl(
    LatLng center,
    double zoom,
    int width,
    int height,
    String apiKey,
  ) {
    return '$_baseUrl'
        '?center=${center.latitude},${center.longitude}'
        '&zoom=${zoom.round()}'
        '&size=${width}x$height'
        '&scale=2'
        '&maptype=roadmap'
        '&key=$apiKey';
  }

  // ---------------------------------------------------------------------------
  // Path simplification
  // ---------------------------------------------------------------------------

  /// Reduce a list of points to at most [maxPoints] by taking every Nth point.
  /// Always keeps the first and last point.
  static List<LatLng> _simplifyPath(List<LatLng> points, {int maxPoints = 30}) {
    if (points.length <= maxPoints) return points;
    final step = (points.length / maxPoints).ceil();
    final result = <LatLng>[];
    for (var i = 0; i < points.length; i += step) {
      result.add(points[i]);
    }
    // Always include the last point to close polygons properly.
    if (result.last != points.last) {
      result.add(points.last);
    }
    return result;
  }
}
