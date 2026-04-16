// track_editor/models/styled_polygon.dart
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';

class TEKmlStyle {
  final Color strokeColor;
  final double strokeWidth;
  final Color fillColor;
  final bool fill;
  final bool outline;

  TEKmlStyle({
    required this.strokeColor,
    required this.strokeWidth,
    required this.fillColor,
    required this.fill,
    required this.outline,
  });
}

class TEStyledPolygon {
  final String id;
  final String name;
  final String clientName;
  final List<LatLng> points;
  final TEKmlStyle style;

  TEStyledPolygon({
    required this.id,
    required this.name,
    this.clientName = '',
    required this.points,
    required this.style,
  });

  TEStyledPolygon copyWith({
    String? name,
    String? clientName,
    List<LatLng>? points,
    TEKmlStyle? style,
  }) {
    return TEStyledPolygon(
      id: id,
      name: name ?? this.name,
      clientName: clientName ?? this.clientName,
      points: points ?? this.points,
      style: style ?? this.style,
    );
  }
}

class TETargetPolygon {
  final String name;
  final List<Wpt> waypoints;

  TETargetPolygon({
    required this.name,
    required this.waypoints,
  });
}
