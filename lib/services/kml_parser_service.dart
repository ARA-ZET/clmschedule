import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/custom_polygon.dart';

/// Exception thrown when KML parsing fails
class KmlParseException implements Exception {
  final String message;
  KmlParseException(this.message);

  @override
  String toString() => 'KmlParseException: $message';
}

/// Service for parsing KML files and creating custom polygons
class KmlParserService {
  /// Predefined colors for KML polygons
  static const List<Color> polygonColors = [
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

  /// Parse KML or KMZ data and return list of CustomPolygon objects
  /// This is the main entry point for parsing KML data
  static Future<List<CustomPolygon>> parseKmlData(
    Uint8List kmlData,
    String fileName,
  ) async {
    try {
      // Check if the data is KMZ (compressed) by looking at file extension or content
      if (fileName.toLowerCase().endsWith('.kmz') || _isKmzData(kmlData)) {
        debugPrint('Detected KMZ file format, extracting...');
        kmlData = extractKmlFromKmz(kmlData);
      }

      // Parse KML from bytes
      return parseKmlFromBytes(kmlData, fileName);
    } catch (e) {
      if (e is KmlParseException) {
        rethrow;
      }
      throw KmlParseException('Failed to parse KML data: $e');
    }
  }

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

      // Look for KML files in the archive
      for (final file in archive) {
        if (file.name.toLowerCase().endsWith('.kml')) {
          debugPrint('Found KML file in archive: ${file.name}');
          return Uint8List.fromList(file.content as List<int>);
        }
      }

      // If no .kml file found, look for the main document (usually doc.kml or similar)
      for (final file in archive) {
        if (!file.isFile) continue;
        try {
          final content = utf8.decode(file.content as List<int>);
          if (content.toLowerCase().contains('<kml')) {
            debugPrint('Found KML content in file: ${file.name}');
            return Uint8List.fromList(file.content as List<int>);
          }
        } catch (e) {
          // Skip files that can't be decoded as UTF-8
          continue;
        }
      }

      throw KmlParseException('No KML content found in KMZ archive');
    } catch (e) {
      if (e is KmlParseException) rethrow;
      throw KmlParseException(
          'Failed to extract KML from KMZ: ${e.toString()}');
    }
  }

  /// Parse KML file from bytes and return list of CustomPolygon objects
  static Future<List<CustomPolygon>> parseKmlFromBytes(
    Uint8List fileBytes,
    String fileName,
  ) async {
    try {
      // Convert bytes to string
      final xmlString = String.fromCharCodes(fileBytes);

      // Parse XML
      final document = XmlDocument.parse(xmlString);

      // Find KML root element
      final kmlElement = document.findElements('kml').firstOrNull ??
          document.findElements('Document').firstOrNull;

      if (kmlElement == null) {
        throw KmlParseException('No KML root element found');
      }

      // Extract all placemarks containing polygons
      final polygons = <CustomPolygon>[];
      final placemarks = _findAllPlacemarks(kmlElement);

      // Filter placemarks to only include those with Polygon elements
      final polygonPlacemarks = placemarks.where((placemark) {
        return placemark.findElements('Polygon').isNotEmpty;
      }).toList();

      debugPrint(
          "Found ${placemarks.length} total placemarks, ${polygonPlacemarks.length} contain polygons");

      for (int index = 0; index < polygonPlacemarks.length; index++) {
        final placemark = polygonPlacemarks[index];
        final polygon = _parsePlacemark(placemark, index);
        if (polygon != null) {
          polygons.add(polygon);
        }
      }

      return polygons;
    } catch (e) {
      throw KmlParseException('Failed to parse KML file "$fileName": $e');
    }
  }

  /// Find all placemark elements recursively
  static List<XmlElement> _findAllPlacemarks(XmlElement element) {
    final placemarks = <XmlElement>[];

    // Direct placemarks
    placemarks.addAll(element.findElements('Placemark'));

    // Placemarks in folders/documents
    for (final folder in element.findElements('Folder')) {
      placemarks.addAll(_findAllPlacemarks(folder));
    }

    for (final document in element.findElements('Document')) {
      placemarks.addAll(_findAllPlacemarks(document));
    }

    return placemarks;
  }

  /// Parse a single placemark element to extract polygon data
  static CustomPolygon? _parsePlacemark(XmlElement placemark, int index) {
    try {
      // Get placemark name
      final nameElement = placemark.findElements('name').firstOrNull;
      final name = nameElement?.innerText.trim() ?? 'Polygon ${index + 1}';

      // Get placemark description
      final descElement = placemark.findElements('description').firstOrNull;
      final description = descElement?.innerText.trim() ?? '';

      // Look for polygon coordinates - only process Polygon elements
      final polygonElement = placemark.findElements('Polygon').firstOrNull;
      if (polygonElement == null) {
        debugPrint("Skipping placemark '$name' - no Polygon element found");
        return null;
      }

      final coordinates = _parsePolygonCoordinates(polygonElement);
      if (coordinates == null || coordinates.length < 3) {
        debugPrint(
            "Skipping placemark '$name' - insufficient coordinates (${coordinates?.length ?? 0})");
        return null; // Need at least 3 points for a polygon
      }

      // Assign color based on index
      final color = polygonColors[index % polygonColors.length];

      return CustomPolygon(
        name: name,
        description: description,
        points: coordinates,
        color: color,
      );
    } catch (e) {
      print('Error parsing placemark: $e');
      return null;
    }
  }

  /// Parse polygon coordinates from Polygon element
  static List<LatLng>? _parsePolygonCoordinates(XmlElement polygonElement) {
    // Look for outer boundary
    final outerBoundary = polygonElement
        .findElements('outerBoundaryIs')
        .firstOrNull
        ?.findElements('LinearRing')
        .firstOrNull;

    if (outerBoundary != null) {
      return _parseCoordinatesString(outerBoundary);
    }

    // Fallback: look for any coordinates element
    final coordinatesElement =
        polygonElement.findElements('coordinates').firstOrNull;
    if (coordinatesElement != null) {
      return _parseCoordinatesFromElement(coordinatesElement);
    }

    return null;
  }

  /// Parse coordinates from LinearRing or similar element
  static List<LatLng>? _parseCoordinatesString(XmlElement element) {
    final coordinatesElement = element.findElements('coordinates').firstOrNull;
    if (coordinatesElement != null) {
      return _parseCoordinatesFromElement(coordinatesElement);
    }
    return null;
  }

  /// Parse coordinates from a coordinates element
  static List<LatLng>? _parseCoordinatesFromElement(
      XmlElement coordinatesElement) {
    try {
      final coordinatesText = coordinatesElement.innerText.trim();
      if (coordinatesText.isEmpty) return null;

      final points = <LatLng>[];

      // Split by whitespace or newlines
      final coordinatesList = coordinatesText
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();

      for (final coordinateString in coordinatesList) {
        final parts = coordinateString.split(',');
        if (parts.length >= 2) {
          try {
            final longitude = double.parse(parts[0]);
            final latitude = double.parse(parts[1]);
            // Note: KML uses longitude,latitude,altitude format
            // Google Maps uses latitude,longitude format
            points.add(LatLng(latitude, longitude));
          } catch (e) {
            print('Error parsing coordinate: $coordinateString - $e');
            continue;
          }
        }
      }

      return points.isNotEmpty ? points : null;
    } catch (e) {
      print('Error parsing coordinates: $e');
      return null;
    }
  }
}
