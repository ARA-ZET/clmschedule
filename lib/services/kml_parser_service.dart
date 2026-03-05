import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/custom_polygon.dart';
import '../shareable_maps/models/map_polyline.dart';
import '../shareable_maps/models/map_point.dart';

/// Exception thrown when KML parsing fails
class KmlParseException implements Exception {
  final String message;
  KmlParseException(this.message);

  @override
  String toString() => 'KmlParseException: $message';
}

/// Holds the result of parsing a KML/GPX file
class ParsedMapResult {
  final List<CustomPolygon> polygons;
  final List<MapPolyline> polylines;
  final List<MapPoint> points;

  const ParsedMapResult({
    required this.polygons,
    required this.polylines,
    required this.points,
  });

  int get totalCount => polygons.length + polylines.length + points.length;
  bool get isEmpty => totalCount == 0;
}

/// Service for parsing KML/GPX files into map elements (polygons, polylines, points)
class KmlParserService {
  /// Predefined colors for imported elements
  static const List<Color> elementColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.indigo,
    Colors.brown,
    Colors.cyan,
    Colors.lime,
    Colors.amber,
    Colors.deepOrange,
    Colors.lightBlue,
    Colors.lightGreen,
  ];

  static Color _colorAt(int index) =>
      elementColors[index % elementColors.length];

  /// Build a unique element ID from its type, display name, a per-import base
  /// timestamp (captured once per parse call) and a sequential counter.
  /// Using all four components guarantees uniqueness even when hundreds of
  /// elements with identical names are imported in the same millisecond.
  static String _makeId(String type, String name, int baseTs, int seq) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'(^_)|(_$)'), '');
    return '${type}_${slug.isEmpty ? type : slug}_${baseTs}_$seq';
  }

  /// Parse KML, KMZ, or GPX data and return structured map elements.
  /// This is the main entry point.
  static Future<ParsedMapResult> parseKmlData(
    Uint8List kmlData,
    String fileName,
  ) async {
    try {
      final lowerName = fileName.toLowerCase();

      // GPX file
      if (lowerName.endsWith('.gpx')) {
        return _parseGpx(kmlData, fileName);
      }

      // KMZ (ZIP archive containing KML)
      if (lowerName.endsWith('.kmz') || _isKmzData(kmlData)) {
        debugPrint('Detected KMZ file format, extracting...');
        kmlData = extractKmlFromKmz(kmlData);
      }

      return _parseKml(kmlData, fileName);
    } catch (e) {
      if (e is KmlParseException) rethrow;
      throw KmlParseException('Failed to parse data: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // KMZ helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Check if the data appears to be KMZ format
  static bool _isKmzData(Uint8List data) {
    // Check for ZIP file signature (PK header)
    return data.length > 4 && data[0] == 0x50 && data[1] == 0x4B;
  }

  /// Extracts KML content from KMZ (compressed) file
  static Uint8List extractKmlFromKmz(Uint8List kmzBytes) {
    try {
      debugPrint('Extracting KML from KMZ archive...');
      final archive = ZipDecoder().decodeBytes(kmzBytes);

      for (final file in archive) {
        if (file.name.toLowerCase().endsWith('.kml')) {
          debugPrint('Found KML file in archive: ${file.name}');
          return Uint8List.fromList(file.content as List<int>);
        }
      }

      for (final file in archive) {
        if (!file.isFile) continue;
        try {
          final content = utf8.decode(file.content as List<int>);
          if (content.toLowerCase().contains('<kml')) {
            debugPrint('Found KML content in file: ${file.name}');
            return Uint8List.fromList(file.content as List<int>);
          }
        } catch (_) {
          continue;
        }
      }

      throw KmlParseException('No KML content found in KMZ archive');
    } catch (e) {
      if (e is KmlParseException) rethrow;
      throw KmlParseException('Failed to extract KML from KMZ: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // KML parsing
  // ─────────────────────────────────────────────────────────────────────────

  static ParsedMapResult _parseKml(Uint8List fileBytes, String fileName) {
    try {
      final xmlString = utf8.decode(fileBytes, allowMalformed: true);
      final document = XmlDocument.parse(xmlString);

      final kmlRoot = document.findElements('kml').firstOrNull;
      final docRoot = kmlRoot != null
          ? (kmlRoot.findElements('Document').firstOrNull ?? kmlRoot)
          : document.findElements('Document').firstOrNull;

      if (docRoot == null && kmlRoot == null) {
        throw KmlParseException('No KML root element found');
      }

      final root = docRoot ?? kmlRoot!;
      final placemarks = _findAllPlacemarks(root);

      debugPrint('KML: found ${placemarks.length} placemarks');

      final polygons = <CustomPolygon>[];
      final polylines = <MapPolyline>[];
      final points = <MapPoint>[];
      int colorIdx = 0;
      final baseTs = DateTime.now().millisecondsSinceEpoch;
      int seq = 0;
      final importTime = DateTime.now();

      for (final pm in placemarks) {
        final name =
            pm.findElements('name').firstOrNull?.innerText.trim() ?? '';
        final desc =
            pm.findElements('description').firstOrNull?.innerText.trim() ?? '';

        // ── Point ─────────────────────────────────────────────────────────
        final pointEl = pm.findElements('Point').firstOrNull;
        if (pointEl != null) {
          final pos = _parseKmlPoint(pointEl);
          if (pos != null) {
            final ptName = name.isEmpty ? 'Point ${points.length + 1}' : name;
            points.add(MapPoint(
              id: _makeId('point', ptName, baseTs, seq++),
              name: ptName,
              description: desc,
              position: pos,
              color: Colors.red,
              createdAt: importTime,
              updatedAt: importTime,
            ));
          }
          continue;
        }

        // ── LineString ────────────────────────────────────────────────────
        final lineEl = pm.findElements('LineString').firstOrNull;
        if (lineEl != null) {
          final pts = _parseCoordinatesFromElement(
              lineEl.findElements('coordinates').first);
          if (pts != null && pts.length >= 2) {
            final plName =
                name.isEmpty ? 'Track ${polylines.length + 1}' : name;
            polylines.add(MapPolyline(
              id: _makeId('polyline', plName, baseTs, seq++),
              name: plName,
              description: desc,
              points: pts,
              color: Colors.blue,
              strokeWidth: 2.0,
              createdAt: importTime,
              updatedAt: importTime,
            ));
          }
          continue;
        }

        // ── Polygon ───────────────────────────────────────────────────────
        final polyEl = pm.findElements('Polygon').firstOrNull;
        if (polyEl != null) {
          final pts = _parsePolygonCoordinates(polyEl);
          if (pts != null && pts.length >= 3) {
            polygons.add(CustomPolygon(
              name: name.isEmpty ? 'Polygon ${polygons.length + 1}' : name,
              description: desc,
              points: pts,
              color: _colorAt(colorIdx++),
            ));
          }
          continue;
        }

        // ── MultiGeometry ─────────────────────────────────────────────────
        final multiEl = pm.findElements('MultiGeometry').firstOrNull;
        if (multiEl != null) {
          int subIdx = 0;
          for (final child in multiEl.childElements) {
            final subName = name.isEmpty
                ? '${child.name.local} ${subIdx + 1}'
                : '$name (${subIdx + 1})';
            if (child.name.local == 'Polygon') {
              final pts = _parsePolygonCoordinates(child);
              if (pts != null && pts.length >= 3) {
                polygons.add(CustomPolygon(
                  name: subName,
                  description: desc,
                  points: pts,
                  color: _colorAt(colorIdx++),
                ));
                subIdx++;
              }
            } else if (child.name.local == 'LineString') {
              final coordEl = child.findElements('coordinates').firstOrNull;
              if (coordEl != null) {
                final pts = _parseCoordinatesFromElement(coordEl);
                if (pts != null && pts.length >= 2) {
                  polylines.add(MapPolyline(
                    id: _makeId('polyline', subName, baseTs, seq++),
                    name: subName,
                    description: desc,
                    points: pts,
                    color: Colors.blue,
                    strokeWidth: 2.0,
                    createdAt: importTime,
                    updatedAt: importTime,
                  ));
                  subIdx++;
                }
              }
            } else if (child.name.local == 'Point') {
              final pos = _parseKmlPoint(child);
              if (pos != null) {
                points.add(MapPoint(
                  id: _makeId('point', subName, baseTs, seq++),
                  name: subName,
                  description: desc,
                  position: pos,
                  color: Colors.red,
                  createdAt: importTime,
                  updatedAt: importTime,
                ));
                subIdx++;
              }
            }
          }
        }
      }

      debugPrint('KML parsed: ${polygons.length} polygons, '
          '${polylines.length} polylines, ${points.length} points');
      return ParsedMapResult(
          polygons: polygons, polylines: polylines, points: points);
    } catch (e) {
      throw KmlParseException('Failed to parse KML file "$fileName": $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // GPX parsing
  // ─────────────────────────────────────────────────────────────────────────

  static ParsedMapResult _parseGpx(Uint8List fileBytes, String fileName) {
    try {
      final xmlString = utf8.decode(fileBytes, allowMalformed: true);
      final document = XmlDocument.parse(xmlString);

      final gpx = document.findElements('gpx').firstOrNull;
      if (gpx == null) {
        throw KmlParseException('No <gpx> root element found');
      }

      final polygons = <CustomPolygon>[];
      final polylines = <MapPolyline>[];
      final points = <MapPoint>[];
      final baseTs = DateTime.now().millisecondsSinceEpoch;
      int seq = 0;
      final importTime = DateTime.now();

      // ── Waypoints (wpt) ────────────────────────────────────────────────
      for (final wpt in gpx.findElements('wpt')) {
        final pos = _parseGpxPoint(wpt);
        if (pos == null) continue;
        final name =
            wpt.findElements('name').firstOrNull?.innerText.trim() ?? '';
        final desc =
            wpt.findElements('desc').firstOrNull?.innerText.trim() ?? '';
        final wptName = name.isEmpty ? 'Waypoint ${points.length + 1}' : name;
        points.add(MapPoint(
          id: _makeId('point', wptName, baseTs, seq++),
          name: wptName,
          description: desc,
          position: pos,
          color: Colors.red,
          createdAt: importTime,
          updatedAt: importTime,
        ));
      }

      // ── Tracks (trk > trkseg > trkpt) ─────────────────────────────────
      int trkIdx = 0;
      for (final trk in gpx.findElements('trk')) {
        trkIdx++;
        final trkName =
            trk.findElements('name').firstOrNull?.innerText.trim() ?? '';
        final trkDesc =
            trk.findElements('desc').firstOrNull?.innerText.trim() ?? '';

        int segIdx = 0;
        for (final seg in trk.findElements('trkseg')) {
          segIdx++;
          final segPts = seg
              .findElements('trkpt')
              .map(_parseGpxPoint)
              .whereType<LatLng>()
              .toList();

          if (segPts.length < 2) continue;

          final segName = trkName.isEmpty
              ? 'Track $trkIdx'
              : (segIdx > 1 ? '$trkName (seg $segIdx)' : trkName);

          polylines.add(MapPolyline(
            id: _makeId('polyline', segName, baseTs, seq++),
            name: segName,
            description: trkDesc,
            points: segPts,
            color: Colors.blue,
            strokeWidth: 2.0,
            createdAt: importTime,
            updatedAt: importTime,
          ));
        }
      }

      // ── Routes (rte > rtept) ───────────────────────────────────────────
      int rteIdx = 0;
      for (final rte in gpx.findElements('rte')) {
        rteIdx++;
        final rteName =
            rte.findElements('name').firstOrNull?.innerText.trim() ?? '';
        final rteDesc =
            rte.findElements('desc').firstOrNull?.innerText.trim() ?? '';

        final rtePts = rte
            .findElements('rtept')
            .map(_parseGpxPoint)
            .whereType<LatLng>()
            .toList();

        if (rtePts.length < 2) continue;

        final rName = rteName.isEmpty ? 'Route $rteIdx' : rteName;
        polylines.add(MapPolyline(
          id: _makeId('polyline', rName, baseTs, seq++),
          name: rName,
          description: rteDesc,
          points: rtePts,
          color: Colors.blue,
          strokeWidth: 2.0,
          createdAt: importTime,
          updatedAt: importTime,
        ));
      }

      debugPrint('GPX parsed: ${polygons.length} polygons, '
          '${polylines.length} polylines, ${points.length} points');
      return ParsedMapResult(
          polygons: polygons, polylines: polylines, points: points);
    } catch (e) {
      throw KmlParseException('Failed to parse GPX file "$fileName": $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Shared helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Find all Placemark elements recursively through Folder/Document containers
  static List<XmlElement> _findAllPlacemarks(XmlElement element) {
    final placemarks = <XmlElement>[];
    placemarks.addAll(element.findElements('Placemark'));
    for (final folder in element.findElements('Folder')) {
      placemarks.addAll(_findAllPlacemarks(folder));
    }
    for (final doc in element.findElements('Document')) {
      placemarks.addAll(_findAllPlacemarks(doc));
    }
    return placemarks;
  }

  /// Parse a KML <Point> element into LatLng
  static LatLng? _parseKmlPoint(XmlElement pointEl) {
    final coordEl = pointEl.findElements('coordinates').firstOrNull;
    if (coordEl == null) return null;
    final parts = coordEl.innerText.trim().split(',');
    if (parts.length < 2) return null;
    try {
      final lon = double.parse(parts[0]);
      final lat = double.parse(parts[1]);
      return LatLng(lat, lon);
    } catch (_) {
      return null;
    }
  }

  /// Parse polygon outer boundary from a <Polygon> element
  static List<LatLng>? _parsePolygonCoordinates(XmlElement polygonElement) {
    final outerBoundary = polygonElement
        .findElements('outerBoundaryIs')
        .firstOrNull
        ?.findElements('LinearRing')
        .firstOrNull;

    if (outerBoundary != null) {
      final coordEl = outerBoundary.findElements('coordinates').firstOrNull;
      if (coordEl != null) return _parseCoordinatesFromElement(coordEl);
    }

    // Fallback
    final coordEl = polygonElement.findElements('coordinates').firstOrNull;
    if (coordEl != null) return _parseCoordinatesFromElement(coordEl);
    return null;
  }

  /// Parse KML <coordinates> text (lon,lat,alt tuples separated by whitespace)
  static List<LatLng>? _parseCoordinatesFromElement(XmlElement el) {
    try {
      final text = el.innerText.trim();
      if (text.isEmpty) return null;
      final pts = <LatLng>[];
      for (final token
          in text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty)) {
        final parts = token.split(',');
        if (parts.length >= 2) {
          try {
            pts.add(LatLng(double.parse(parts[1]), double.parse(parts[0])));
          } catch (_) {
            continue;
          }
        }
      }
      return pts.isNotEmpty ? pts : null;
    } catch (_) {
      return null;
    }
  }

  /// Parse a GPX point element (wpt / trkpt / rtept) into LatLng
  static LatLng? _parseGpxPoint(XmlElement el) {
    try {
      final lat = double.parse(el.getAttribute('lat') ?? '');
      final lon = double.parse(el.getAttribute('lon') ?? '');
      return LatLng(lat, lon);
    } catch (_) {
      return null;
    }
  }
}
