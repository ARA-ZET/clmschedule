import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, Uint8List;
import 'package:flutter/material.dart' show Color;
import 'package:xml/xml.dart';
import '../models/shareable_map.dart';
import '../models/map_layer.dart';
import '../../models/custom_polygon.dart';
import '../models/map_polyline.dart';
import '../models/map_point.dart';

/// Service for exporting shareable maps to KML format
class MapExportService {
  /// Export a shareable map to KML string
  static String exportToKml(ShareableMap map) {
    final builder = XmlBuilder();

    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('kml', nest: () {
      builder.attribute('xmlns', 'http://www.opengis.net/kml/2.2');

      builder.element('Document', nest: () {
        // Map metadata
        builder.element('name', nest: map.name);
        if (map.description.isNotEmpty) {
          builder.element('description', nest: map.description);
        }

        // Styles for each layer
        for (final layer in map.layers) {
          _addStyle(builder, layer);
        }

        // Folders for each layer
        for (final layer in map.layers) {
          _addLayerFolder(builder, layer);
        }
      });
    });

    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  /// Add style definitions for a layer
  static void _addStyle(XmlBuilder builder, MapLayer layer) {
    final layerStyleId = 'style_${layer.id}';
    final color = layer.defaultColor;

    // Convert Flutter Color to KML color (AABBGGRR format)
    final kmlColor = _colorToKmlString(color);

    builder.element('Style', nest: () {
      builder.attribute('id', layerStyleId);

      // Polygon style
      builder.element('PolyStyle', nest: () {
        builder.element('color', nest: kmlColor);
        builder.element('fill', nest: '1');
        builder.element('outline', nest: '1');
      });

      // Line style
      builder.element('LineStyle', nest: () {
        builder.element('color', nest: kmlColor);
        builder.element('width', nest: '3');
      });

      // Icon style for points
      builder.element('IconStyle', nest: () {
        builder.element('color', nest: kmlColor);
        builder.element('scale', nest: '1.0');
      });
    });
  }

  /// Add a folder for a layer with all its elements
  static void _addLayerFolder(XmlBuilder builder, MapLayer layer) {
    builder.element('Folder', nest: () {
      builder.element('name', nest: layer.name);
      if (layer.description.isNotEmpty) {
        builder.element('description', nest: layer.description);
      }
      builder.element('visibility', nest: layer.isVisible ? '1' : '0');

      // Add polygons (skip marker-type entries)
      for (int i = 0; i < layer.polygons.length; i++) {
        final polygon = layer.polygons[i];
        if (polygon.isMarker) {
          _addMarkerPoint(builder, polygon, layer.id);
          continue;
        }
        _addPolygon(builder, polygon, '${layer.id}_polygon_$i', layer.id);
      }

      // Add polylines
      for (final polyline in layer.polylines) {
        _addPolyline(builder, polyline, layer.id);
      }

      // Add points
      for (final point in layer.points) {
        _addPoint(builder, point, layer.id);
      }
    });
  }

  /// Add a polygon placemark
  static void _addPolygon(
    XmlBuilder builder,
    CustomPolygon polygon,
    String id,
    String layerId,
  ) {
    builder.element('Placemark', nest: () {
      builder.element('name', nest: polygon.name);
      if (polygon.description.isNotEmpty) {
        builder.element('description', nest: polygon.description);
      }
      builder.element('styleUrl', nest: '#style_$layerId');

      builder.element('Polygon', nest: () {
        builder.element('outerBoundaryIs', nest: () {
          builder.element('LinearRing', nest: () {
            builder.element('coordinates', nest: () {
              for (final point in polygon.points) {
                builder.text('${point.longitude},${point.latitude},0\n');
              }
              // Close the polygon by repeating first point
              if (polygon.points.isNotEmpty) {
                final first = polygon.points.first;
                builder.text('${first.longitude},${first.latitude},0\n');
              }
            });
          });
        });
      });
    });
  }

  /// Add a polyline placemark
  static void _addPolyline(
    XmlBuilder builder,
    MapPolyline polyline,
    String layerId,
  ) {
    builder.element('Placemark', nest: () {
      builder.element('name', nest: polyline.name);
      if (polyline.description.isNotEmpty) {
        builder.element('description', nest: polyline.description);
      }
      builder.element('styleUrl', nest: '#style_$layerId');

      builder.element('LineString', nest: () {
        builder.element('coordinates', nest: () {
          for (final point in polyline.points) {
            builder.text('${point.longitude},${point.latitude},0\n');
          }
        });
      });
    });
  }

  /// Add a marker-type CustomPolygon as a Point placemark
  static void _addMarkerPoint(
    XmlBuilder builder,
    CustomPolygon marker,
    String layerId,
  ) {
    if (marker.points.isEmpty) return;
    final pos = marker.markerPosition!;
    builder.element('Placemark', nest: () {
      builder.element('name', nest: marker.name);
      if (marker.description.isNotEmpty) {
        builder.element('description', nest: marker.description);
      }
      builder.element('styleUrl', nest: '#style_$layerId');

      builder.element('Point', nest: () {
        builder.element('coordinates',
            nest: '${pos.longitude},${pos.latitude},0');
      });
    });
  }

  /// Add a point placemark
  static void _addPoint(
    XmlBuilder builder,
    MapPoint point,
    String layerId,
  ) {
    builder.element('Placemark', nest: () {
      builder.element('name', nest: point.name);
      if (point.description.isNotEmpty) {
        builder.element('description', nest: point.description);
      }
      builder.element('styleUrl', nest: '#style_$layerId');

      builder.element('Point', nest: () {
        builder.element('coordinates',
            nest: '${point.position.longitude},${point.position.latitude},0');
      });
    });
  }

  /// Convert Flutter Color to KML color string (AABBGGRR format)
  static String _colorToKmlString(Color color) {
    final a = (color.a * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
    final r = (color.r * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
    final g = (color.g * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
    final b = (color.b * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
    return '$a$b$g$r'; // KML uses AABBGGRR format
  }

  /// Download KML file (web and mobile)
  static Future<void> downloadKmlFile(String kmlString, String fileName) async {
    final bytes = Uint8List.fromList(utf8.encode(kmlString));

    if (kIsWeb) {
      // Web: Use blob and download link
      await _downloadForWeb(bytes, fileName);
    } else {
      // Mobile: Save to file system
      // TODO: Implement mobile file saving using path_provider
      throw UnimplementedError(
        'Mobile file download not yet implemented. Use share instead.',
      );
    }
  }

  /// Download file for web platform
  static Future<void> _downloadForWeb(Uint8List bytes, String fileName) async {
    // This requires dart:html on web
    // For now, we'll use a workaround that works in both web and non-web
    try {
      // For now, just log success in debug mode
      // TODO: Implement actual web download using dart:html
      // ignore: avoid_print
      if (kDebugMode) {
        print('KML generated successfully: $fileName (${bytes.length} bytes)');
      }
    } catch (e) {
      // ignore: avoid_print
      if (kDebugMode) {
        print('Error downloading file: $e');
      }
      rethrow;
    }
  }
}
