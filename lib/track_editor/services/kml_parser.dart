// track_editor/services/kml_parser.dart
import 'dart:typed_data';
import 'package:xml/xml.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/styled_polygon.dart';

/// Convert KML color string (aabbggrr) → Flutter Color (ARGB).
Color _kmlColorToFlutter(String kmlColor) {
  final abgr = kmlColor.padLeft(8, '0');
  final aa = abgr.substring(0, 2);
  final bb = abgr.substring(2, 4);
  final gg = abgr.substring(4, 6);
  final rr = abgr.substring(6, 8);
  return Color(int.parse('0x$aa$rr$gg$bb'));
}

/// Parse a .kml file's bytes and return all polygons with their styles.
List<TEStyledPolygon> parseKmlWithStyles(Uint8List bytes) {
  final doc = XmlDocument.parse(String.fromCharCodes(bytes));
  const kmlNs = 'http://www.opengis.net/kml/2.2';

  // 1) Build style map
  final styles = <String, TEKmlStyle>{};
  for (final styleNode in doc.findAllElements('Style', namespace: kmlNs)) {
    final styleId = styleNode.getAttribute('id')!;
    Color strokeColor = Colors.black;
    double strokeWidth = 1.0;
    Color fillColor = Colors.transparent;
    bool fill = true;
    bool outline = true;

    final lineStyle = styleNode.getElement('LineStyle', namespace: kmlNs);
    if (lineStyle != null) {
      final c = lineStyle.getElement('color', namespace: kmlNs)?.value;
      if (c != null) strokeColor = _kmlColorToFlutter(c);
      final w = lineStyle.getElement('width', namespace: kmlNs)?.value;
      if (w != null) strokeWidth = double.tryParse(w) ?? 1.0;
    }

    final polyStyle = styleNode.getElement('PolyStyle', namespace: kmlNs);
    if (polyStyle != null) {
      final c = polyStyle.getElement('color', namespace: kmlNs)?.innerText;
      if (c != null) fillColor = _kmlColorToFlutter(c);
      fill = polyStyle.getElement('fill', namespace: kmlNs)?.innerText == '1';
      outline =
          polyStyle.getElement('outline', namespace: kmlNs)?.innerText == '1';
    }

    styles[styleId] = TEKmlStyle(
      strokeColor: strokeColor,
      strokeWidth: strokeWidth,
      fillColor: fillColor,
      fill: fill,
      outline: outline,
    );
  }

  // 2) Parse each Placemark → TEStyledPolygon
  final polygons = <TEStyledPolygon>[];
  for (final pm in doc.findAllElements('Placemark', namespace: kmlNs)) {
    final name = pm.getElement('name', namespace: kmlNs)?.value ?? 'polygon';
    final styleUrl = pm
        .getElement('styleUrl', namespace: kmlNs)
        ?.value
        ?.replaceFirst('#', '');
    final style = styles[styleUrl] ??
        TEKmlStyle(
          strokeColor: Colors.black,
          strokeWidth: 1,
          fillColor: Colors.transparent,
          fill: false,
          outline: true,
        );

    final coordNode = pm
        .findAllElements('Polygon', namespace: kmlNs)
        .expand((poly) => poly.findAllElements('coordinates', namespace: kmlNs))
        .firstOrNull;
    if (coordNode == null) continue;

    final coordsText = coordNode.innerText.trim();
    final points =
        coordsText.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).map((line) {
      final parts = line.split(',');
      final lon = double.parse(parts[0]);
      final lat = double.parse(parts[1]);
      return LatLng(lat, lon);
    }).toList();

    polygons.add(TEStyledPolygon(
      id: name,
      name: name,
      points: points,
      style: style,
    ));
  }

  return polygons;
}
