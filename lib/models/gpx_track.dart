import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Represents a single track point in a GPX track
class GpxTrackPoint {
  final double latitude;
  final double longitude;
  final double? elevation;
  final DateTime? time;

  const GpxTrackPoint({
    required this.latitude,
    required this.longitude,
    this.elevation,
    this.time,
  });

  /// Convert to LatLng for Google Maps
  LatLng toLatLng() => LatLng(latitude, longitude);

  @override
  String toString() {
    return 'GpxTrackPoint(lat: $latitude, lng: $longitude, ele: $elevation, time: $time)';
  }
}

/// Represents a track segment (continuous line of track points)
class GpxTrackSegment {
  final List<GpxTrackPoint> points;

  const GpxTrackSegment({required this.points});

  /// Convert track points to LatLng list for polylines
  List<LatLng> toLatLngs() => points.map((point) => point.toLatLng()).toList();

  bool get isEmpty => points.isEmpty;
  bool get isNotEmpty => points.isNotEmpty;
  int get length => points.length;
}

/// Represents a complete GPX track with metadata
class GpxTrack {
  final String name;
  final String? description;
  final List<GpxTrackSegment> segments;
  final Color color;
  final bool isVisible;
  final String fileName;

  const GpxTrack({
    required this.name,
    this.description,
    required this.segments,
    required this.color,
    this.isVisible = true,
    required this.fileName,
  });

  /// Get all track points from all segments
  List<GpxTrackPoint> get allPoints {
    return segments.expand((segment) => segment.points).toList();
  }

  /// Get all LatLng points for map display
  List<LatLng> get allLatLngs {
    return allPoints.map((point) => point.toLatLng()).toList();
  }

  /// Create polylines for each segment with the track's color
  List<Polyline> toPolylines() {
    final polylines = <Polyline>[];

    for (int i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.isNotEmpty && isVisible) {
        polylines.add(
          Polyline(
            polylineId: PolylineId('${fileName}_track_${name}_segment_$i'),
            points: segment.toLatLngs(),
            color: color,
            width: 3,
            patterns: [], // Solid line
          ),
        );
      }
    }

    return polylines;
  }

  /// Calculate bounding box for all track points
  LatLngBounds? get bounds {
    final allPoints = this.allLatLngs;
    if (allPoints.isEmpty) return null;

    double minLat = allPoints.first.latitude;
    double maxLat = allPoints.first.latitude;
    double minLng = allPoints.first.longitude;
    double maxLng = allPoints.first.longitude;

    for (final point in allPoints) {
      minLat = minLat < point.latitude ? minLat : point.latitude;
      maxLat = maxLat > point.latitude ? maxLat : point.latitude;
      minLng = minLng < point.longitude ? minLng : point.longitude;
      maxLng = maxLng > point.longitude ? maxLng : point.longitude;
    }

    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  /// Create a copy with modified visibility
  GpxTrack copyWith({
    String? name,
    String? description,
    List<GpxTrackSegment>? segments,
    Color? color,
    bool? isVisible,
    String? fileName,
  }) {
    return GpxTrack(
      name: name ?? this.name,
      description: description ?? this.description,
      segments: segments ?? this.segments,
      color: color ?? this.color,
      isVisible: isVisible ?? this.isVisible,
      fileName: fileName ?? this.fileName,
    );
  }

  @override
  String toString() {
    final pointCount = allPoints.length;
    return 'GpxTrack(name: $name, segments: ${segments.length}, points: $pointCount, visible: $isVisible)';
  }
}

/// Container for multiple GPX tracks from potentially multiple files
class GpxData {
  final List<GpxTrack> tracks;

  const GpxData({required this.tracks});

  /// Get all visible tracks
  List<GpxTrack> get visibleTracks =>
      tracks.where((track) => track.isVisible).toList();

  /// Get all polylines from visible tracks
  List<Polyline> get allPolylines {
    return visibleTracks.expand((track) => track.toPolylines()).toList();
  }

  /// Calculate combined bounds for all visible tracks
  LatLngBounds? get combinedBounds {
    final visibleTrackList = visibleTracks;
    if (visibleTrackList.isEmpty) return null;

    LatLngBounds? combinedBounds;

    for (final track in visibleTrackList) {
      final trackBounds = track.bounds;
      if (trackBounds != null) {
        if (combinedBounds == null) {
          combinedBounds = trackBounds;
        } else {
          // Expand bounds to include this track
          final newSouthwest = LatLng(
            combinedBounds.southwest.latitude < trackBounds.southwest.latitude
                ? combinedBounds.southwest.latitude
                : trackBounds.southwest.latitude,
            combinedBounds.southwest.longitude < trackBounds.southwest.longitude
                ? combinedBounds.southwest.longitude
                : trackBounds.southwest.longitude,
          );
          final newNortheast = LatLng(
            combinedBounds.northeast.latitude > trackBounds.northeast.latitude
                ? combinedBounds.northeast.latitude
                : trackBounds.northeast.latitude,
            combinedBounds.northeast.longitude > trackBounds.northeast.longitude
                ? combinedBounds.northeast.longitude
                : trackBounds.northeast.longitude,
          );
          combinedBounds = LatLngBounds(
            southwest: newSouthwest,
            northeast: newNortheast,
          );
        }
      }
    }

    return combinedBounds;
  }

  bool get isEmpty => tracks.isEmpty;
  bool get isNotEmpty => tracks.isNotEmpty;
  int get trackCount => tracks.length;
  int get visibleTrackCount => visibleTracks.length;
}
