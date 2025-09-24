import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';
import '../models/gpx_track.dart';

/// Service for parsing GPX files and converting them to GpxTrack objects
class GpxParserService {
  /// Predefined colors for GPX tracks
  static const List<Color> trackColors = [
    Colors.red,
    Colors.blue,
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
  ];

  /// Parse GPX file from bytes and return GpxData
  static Future<GpxData> parseGpxFile(
    Uint8List fileBytes,
    String fileName,
  ) async {
    try {
      // Convert bytes to string
      final xmlString = String.fromCharCodes(fileBytes);

      // Parse XML
      final document = XmlDocument.parse(xmlString);

      // Find GPX root element
      final gpxElement = document.findElements('gpx').first;

      // Extract all tracks
      final tracks = <GpxTrack>[];
      final trackElements = gpxElement.findElements('trk');

      for (int trackIndex = 0;
          trackIndex < trackElements.length;
          trackIndex++) {
        final trackElement = trackElements.elementAt(trackIndex);
        final track = _parseTrack(trackElement, fileName, trackIndex);
        if (track != null) {
          tracks.add(track);
        }
      }

      return GpxData(tracks: tracks);
    } catch (e) {
      throw GpxParseException('Failed to parse GPX file "$fileName": $e');
    }
  }

  /// Parse a single track element
  static GpxTrack? _parseTrack(
    XmlElement trackElement,
    String fileName,
    int trackIndex,
  ) {
    try {
      // Get track name
      final nameElement = trackElement.findElements('name').firstOrNull;
      final trackName =
          nameElement?.innerText.trim() ?? 'Track ${trackIndex + 1}';

      // Get track description
      final descElement = trackElement.findElements('desc').firstOrNull;
      final description = descElement?.innerText.trim();

      // Parse all track segments
      final segments = <GpxTrackSegment>[];
      final segmentElements = trackElement.findElements('trkseg');

      for (final segmentElement in segmentElements) {
        final segment = _parseTrackSegment(segmentElement);
        if (segment != null && segment.isNotEmpty) {
          segments.add(segment);
        }
      }

      if (segments.isEmpty) {
        return null; // No valid segments found
      }

      // Assign color based on track index
      final color = trackColors[trackIndex % trackColors.length];

      return GpxTrack(
        name: trackName,
        description: description,
        segments: segments,
        color: color,
        fileName: fileName,
      );
    } catch (e) {
      print('Error parsing track in $fileName: $e');
      return null;
    }
  }

  /// Parse a track segment element
  static GpxTrackSegment? _parseTrackSegment(XmlElement segmentElement) {
    try {
      final points = <GpxTrackPoint>[];
      final pointElements = segmentElement.findElements('trkpt');

      for (final pointElement in pointElements) {
        final point = _parseTrackPoint(pointElement);
        if (point != null) {
          points.add(point);
        }
      }

      return points.isNotEmpty ? GpxTrackSegment(points: points) : null;
    } catch (e) {
      print('Error parsing track segment: $e');
      return null;
    }
  }

  /// Parse a track point element
  static GpxTrackPoint? _parseTrackPoint(XmlElement pointElement) {
    try {
      // Get latitude and longitude (required)
      final latStr = pointElement.getAttribute('lat');
      final lonStr = pointElement.getAttribute('lon');

      if (latStr == null || lonStr == null) {
        return null; // Invalid point without coordinates
      }

      final latitude = double.tryParse(latStr);
      final longitude = double.tryParse(lonStr);

      if (latitude == null || longitude == null) {
        return null; // Invalid coordinate values
      }

      // Validate coordinate ranges
      if (latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        return null; // Coordinates out of valid range
      }

      // Get elevation (optional)
      double? elevation;
      final eleElement = pointElement.findElements('ele').firstOrNull;
      if (eleElement != null) {
        elevation = double.tryParse(eleElement.innerText.trim());
      }

      // Get time (optional)
      DateTime? time;
      final timeElement = pointElement.findElements('time').firstOrNull;
      if (timeElement != null) {
        try {
          time = DateTime.parse(timeElement.innerText.trim());
        } catch (e) {
          // Ignore invalid time format
        }
      }

      return GpxTrackPoint(
        latitude: latitude,
        longitude: longitude,
        elevation: elevation,
        time: time,
      );
    } catch (e) {
      print('Error parsing track point: $e');
      return null;
    }
  }

  /// Validate if the file content looks like a GPX file
  static bool isValidGpxContent(String content) {
    try {
      final document = XmlDocument.parse(content);
      final gpxElements = document.findElements('gpx');
      return gpxElements.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Extract metadata from GPX file (name, description, etc.)
  static Map<String, String> extractMetadata(String xmlContent) {
    final metadata = <String, String>{};

    try {
      final document = XmlDocument.parse(xmlContent);
      final gpxElement = document.findElements('gpx').first;

      // Get metadata element
      final metadataElement = gpxElement.findElements('metadata').firstOrNull;
      if (metadataElement != null) {
        final nameElement = metadataElement.findElements('name').firstOrNull;
        if (nameElement != null) {
          metadata['name'] = nameElement.innerText.trim();
        }

        final descElement = metadataElement.findElements('desc').firstOrNull;
        if (descElement != null) {
          metadata['description'] = descElement.innerText.trim();
        }

        final authorElement =
            metadataElement.findElements('author').firstOrNull;
        if (authorElement != null) {
          final authorName = authorElement.findElements('name').firstOrNull;
          if (authorName != null) {
            metadata['author'] = authorName.innerText.trim();
          }
        }
      }

      // Count tracks and points
      final trackElements = gpxElement.findElements('trk');
      metadata['trackCount'] = trackElements.length.toString();

      int totalPoints = 0;
      for (final trackElement in trackElements) {
        final segments = trackElement.findElements('trkseg');
        for (final segment in segments) {
          totalPoints += segment.findElements('trkpt').length;
        }
      }
      metadata['pointCount'] = totalPoints.toString();
    } catch (e) {
      print('Error extracting GPX metadata: $e');
    }

    return metadata;
  }
}

/// Exception thrown when GPX parsing fails
class GpxParseException implements Exception {
  final String message;

  const GpxParseException(this.message);

  @override
  String toString() => 'GpxParseException: $message';
}

/// Extension to add firstOrNull method to Iterable
extension IterableExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
