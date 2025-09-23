import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/work_area.dart';
import '../models/custom_polygon.dart';

class WorkAreaConverter {
  /// Convert a WorkArea to a CustomPolygon
  static CustomPolygon workAreaToCustomPolygon(
    WorkArea workArea, {
    Color? color,
  }) {
    return CustomPolygon(
      name: workArea.name,
      description: workArea.description,
      points: workArea.polygonPoints,
      color: color ?? Colors.blue,
    );
  }

  /// Convert multiple WorkAreas to CustomPolygons
  static List<CustomPolygon> workAreasToCustomPolygons(
    List<WorkArea> workAreas, {
    Color? defaultColor,
  }) {
    return workAreas.map((workArea) {
      return workAreaToCustomPolygon(
        workArea,
        color: defaultColor ?? Colors.blue,
      );
    }).toList();
  }

  /// Create a CustomPolygon from polygon points directly
  static CustomPolygon createCustomPolygonFromPoints(
    List<LatLng> points, {
    required String name,
    String? description,
    Color? color,
  }) {
    return CustomPolygon(
      name: name,
      description: description ?? 'Custom work area',
      points: points,
      color: color ?? Colors.blue,
    );
  }

  /// Generate different colors for multiple polygons
  static List<Color> generatePolygonColors(int count) {
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.indigo,
      Colors.brown,
      Colors.pink,
    ];

    if (count <= colors.length) {
      return colors.take(count).toList();
    }

    // If we need more colors, generate additional ones
    final result = List<Color>.from(colors);
    for (int i = colors.length; i < count; i++) {
      // Generate colors by varying hue
      final hue = (i * 360.0 / count) % 360.0;
      result.add(HSVColor.fromAHSV(1.0, hue, 0.7, 0.8).toColor());
    }

    return result;
  }
}
