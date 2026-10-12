import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode, Uint8List;
import 'package:flutter/material.dart' show Color;
import 'package:xml/xml.dart';
import '../models/shareable_map.dart';
import '../models/map_layer.dart';
import '../../models/custom_polygon.dart';
import '../models/map_polyline.dart';
import '../models/map_point.dart';
import '../../utils/web_file_download.dart';

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
        _addPoint(builder, point, layer.id, layer.points.length);
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
    int layerPointCount,
  ) {
    builder.element('Placemark', nest: () {
      builder.element('name', nest: _pointName(point, layerPointCount));
      if (point.description.isNotEmpty) {
        builder.element('description', nest: point.description);
      }
      builder.element('styleUrl', nest: '#style_$layerId');

      if (point.routeSequence != null) {
        builder.element('ExtendedData', nest: () {
          builder.element('Data', nest: () {
            builder.attribute('name', 'stop');
            builder.element('value', nest: '${point.routeSequence}');
          });
        });
      }

      builder.element('Point', nest: () {
        builder.element('coordinates',
            nest: '${point.position.longitude},${point.position.latitude},0');
      });
    });
  }

  /// Prefix a routed point's name with its zero-padded stop number.
  ///
  /// Google My Maps orders a layer's placemarks alphabetically, not by
  /// document order, so an unpadded "10" would sort before "2" and the
  /// imported run would read out of sequence. Padding to the layer's width
  /// makes the alphabetical order the drive order.
  static String _pointName(MapPoint point, int layerPointCount) {
    final sequence = point.routeSequence;
    if (sequence == null) return point.name;

    final width = layerPointCount.toString().length;
    final label = sequence.toString().padLeft(width, '0');
    return point.name.isEmpty ? label : '$label · ${point.name}';
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

  /// Download a KML file.
  ///
  /// On web this hands the bytes to the browser's download flow; on
  /// desktop/mobile it writes to the downloads folder. Returns the saved
  /// path where there is one, and null on web.
  static Future<String?> downloadKmlFile(
      String kmlString, String fileName) async {
    final bytes = Uint8List.fromList(utf8.encode(kmlString));
    final safeName =
        fileName.toLowerCase().endsWith('.kml') ? fileName : '$fileName.kml';

    final path = await triggerFileDownload(
      bytes,
      safeName,
      'application/vnd.google-earth.kml+xml',
    );

    if (kDebugMode) {
      // ignore: avoid_print
      print('KML export: $safeName (${bytes.length} bytes)'
          '${path == null ? '' : ' → $path'}');
    }
    return path;
  }
}
