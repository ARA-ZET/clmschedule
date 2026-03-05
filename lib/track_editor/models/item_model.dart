// track_editor/models/item_model.dart
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

abstract class TELayerItem {
  String id;
  final String type;
  String title;

  TELayerItem({
    required this.id,
    required this.title,
    required this.type,
  });

  Map<String, dynamic> toJson();

  static TELayerItem fromJson(String id, Map<String, dynamic> json) {
    switch (json['type']) {
      case 'marker':
        return TEMarkerItem.fromJson(id, json);
      case 'polygon':
        return TEPolygonItem.fromJson(id, json);
      case 'polyline':
        return TEPolylineItem.fromJson(id, json);
      default:
        throw Exception('Unknown layer item type: ${json["type"]}');
    }
  }
}

class TEMarkerItem extends TELayerItem {
  LatLng position;
  final String description;

  TEMarkerItem({
    required super.id,
    required this.position,
    required super.title,
    required this.description,
  }) : super(type: 'marker');

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'marker',
        'position': {
          'latitude': position.latitude,
          'longitude': position.longitude,
        },
        'title': title,
        'description': description,
      };

  factory TEMarkerItem.fromJson(String id, Map<String, dynamic> json) {
    return TEMarkerItem(
      id: id,
      position: LatLng(
        json['position']['latitude'],
        json['position']['longitude'],
      ),
      title: json['title'] ?? '',
      description: json['description'] ?? '',
    );
  }
}

class TEPolygonItem extends TELayerItem {
  final List<LatLng> coordinates;
  final double opacity;
  final double strokeWidth;
  final Color fillColor;

  TEPolygonItem({
    required super.id,
    required super.title,
    required this.coordinates,
    this.opacity = 20,
    this.strokeWidth = 2,
    this.fillColor = Colors.red,
  }) : super(type: 'polygon');

  static String _colorToHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

  static Color _hexToColor(String hex) =>
      Color(int.parse(hex.replaceFirst('#', ''), radix: 16));

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'polygon',
        'coordinates': coordinates
            .map((c) => {'latitude': c.latitude, 'longitude': c.longitude})
            .toList(),
        'opacity': opacity,
        'strokeWidth': strokeWidth,
        'fillColor': _colorToHex(fillColor),
        'title': title,
      };

  factory TEPolygonItem.fromJson(String id, Map<String, dynamic> json) {
    return TEPolygonItem(
      id: id,
      title: json['title'] ?? 'Unnamed Polygon',
      coordinates: (json['coordinates'] as List)
          .map((c) => LatLng(c['latitude'], c['longitude']))
          .toList(),
      opacity: json['opacity']?.toDouble() ?? 20.0,
      strokeWidth: json['strokeWidth']?.toDouble() ?? 2.0,
      fillColor: json['fillColor'] != null
          ? _hexToColor(json['fillColor'])
          : _hexToColor('#fff44336'),
    );
  }

  TEPolygonItem copyWith({
    List<LatLng>? coordinates,
    double? opacity,
    Color? fillColor,
    double? strokeWidth,
    String? title,
  }) {
    return TEPolygonItem(
      id: id,
      coordinates: coordinates ?? this.coordinates,
      opacity: opacity ?? this.opacity,
      fillColor: fillColor ?? this.fillColor,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      title: title ?? this.title,
    );
  }
}

class TEPolylineItem extends TELayerItem {
  final List<LatLng> coordinates;
  final double width;
  final Color color;

  TEPolylineItem({
    required super.id,
    required super.title,
    required this.coordinates,
    this.width = 2,
    this.color = Colors.red,
  }) : super(type: 'Polyline');

  static String _colorToHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

  static Color _hexToColor(String hex) =>
      Color(int.parse(hex.replaceFirst('#', ''), radix: 16));

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'Polyline',
        'coordinates': coordinates
            .map((c) => {'latitude': c.latitude, 'longitude': c.longitude})
            .toList(),
        'width': width,
        'color': _colorToHex(color),
        'title': title,
      };

  factory TEPolylineItem.fromJson(String id, Map<String, dynamic> json) {
    return TEPolylineItem(
      id: id,
      title: json['title'] ?? 'Unnamed Polyline',
      coordinates: (json['coordinates'] as List)
          .map((c) => LatLng(c['latitude'], c['longitude']))
          .toList(),
      width: json['width']?.toDouble() ?? 2.0,
      color:
          json['color'] != null ? _hexToColor(json['color']) : Colors.red,
    );
  }
}
