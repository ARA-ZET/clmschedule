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

  // 1) Build style map — also index StyleMap normal-style references.
  final styles = <String, TEKmlStyle>{};
  final styleMapNormal = <String, String>{};

  for (final smNode in doc.findAllElements('StyleMap', namespace: kmlNs)) {
    final smId = smNode.getAttribute('id');
    if (smId == null) continue;
    for (final pair in smNode.findAllElements('Pair', namespace: kmlNs)) {
      final key = pair.getElement('key', namespace: kmlNs)?.innerText;
      final url = pair
          .getElement('styleUrl', namespace: kmlNs)
          ?.innerText
          .replaceFirst('#', '');
      if (key == 'normal' && url != null) styleMapNormal[smId] = url;
    }
  }

  for (final styleNode in doc.findAllElements('Style', namespace: kmlNs)) {
    final styleId = styleNode.getAttribute('id')!;
    Color strokeColor = Colors.black;
    double strokeWidth = 1.0;
    Color fillColor = Colors.transparent;
    bool fill = true;
    bool outline = true;

    final lineStyle = styleNode.getElement('LineStyle', namespace: kmlNs);
    if (lineStyle != null) {
      final c = lineStyle.getElement('color', namespace: kmlNs)?.innerText;
      if (c != null && c.isNotEmpty) strokeColor = _kmlColorToFlutter(c);
      final w = lineStyle.getElement('width', namespace: kmlNs)?.innerText;
      if (w != null) strokeWidth = double.tryParse(w) ?? 1.0;
    }

    final polyStyle = styleNode.getElement('PolyStyle', namespace: kmlNs);
    if (polyStyle != null) {
      final c = polyStyle.getElement('color', namespace: kmlNs)?.innerText;
      if (c != null && c.isNotEmpty) fillColor = _kmlColorToFlutter(c);
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

  // Resolve StyleMap references so a styleUrl pointing at a StyleMap gets the
  // correct underlying Style object.
  TEKmlStyle resolveStyle(String? rawUrl) {
    if (rawUrl == null) {
      return TEKmlStyle(
        strokeColor: Colors.black,
        strokeWidth: 1,
        fillColor: Colors.transparent,
        fill: false,
        outline: true,
      );
    }
    final id = rawUrl.replaceFirst('#', '');
    // Direct style hit
    if (styles.containsKey(id)) return styles[id]!;
    // StyleMap → resolve normal style
    final normalId = styleMapNormal[id];
    if (normalId != null && styles.containsKey(normalId)) {
      return styles[normalId]!;
    }
    return TEKmlStyle(
      strokeColor: Colors.black,
      strokeWidth: 1,
      fillColor: Colors.transparent,
      fill: false,
      outline: true,
    );
  }

  /// Extract coordinate points from a <Polygon> element.
  List<LatLng>? parsePolygonCoords(XmlElement polyEl) {
    final coordNode =
        polyEl.findAllElements('coordinates', namespace: kmlNs).firstOrNull;
    if (coordNode == null) return null;
    final coordsText = coordNode.innerText.trim();
    final points = coordsText
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .map((line) {
          final parts = line.split(',');
          if (parts.length < 2) return null;
          final lon = double.tryParse(parts[0]);
          final lat = double.tryParse(parts[1]);
          if (lon == null || lat == null) return null;
          return LatLng(lat, lon);
        })
        .whereType<LatLng>()
        .toList();
    return points.length >= 3 ? points : null;
  }

  // 2) Parse each Placemark → TEStyledPolygon(s)
  final polygons = <TEStyledPolygon>[];
  int seq = 0;
  for (final pm in doc.findAllElements('Placemark', namespace: kmlNs)) {
    final name =
        pm.getElement('name', namespace: kmlNs)?.innerText.trim() ?? 'polygon';
    final styleUrl =
        pm.getElement('styleUrl', namespace: kmlNs)?.innerText.trim();
    final style = resolveStyle(styleUrl);

    // ── Direct <Polygon> ──────────────────────────────────────────────────
    for (final polyEl in pm.findAllElements('Polygon', namespace: kmlNs)) {
      final pts = parsePolygonCoords(polyEl);
      if (pts == null) continue;
      final polyName =
          polygons.any((p) => p.id == name) ? '$name (${++seq})' : name;
      polygons.add(TEStyledPolygon(
        id: polyName,
        name: polyName,
        points: pts,
        style: style,
      ));
    }

    // ── <MultiGeometry> containing polygons ───────────────────────────────
    for (final mg in pm.findAllElements('MultiGeometry', namespace: kmlNs)) {
      int sub = 0;
      for (final child in mg.childElements) {
        if (child.name.local != 'Polygon') continue;
        final pts = parsePolygonCoords(child);
        if (pts == null) continue;
        sub++;
        final subName = '$name ($sub)';
        polygons.add(TEStyledPolygon(
          id: subName,
          name: subName,
          points: pts,
          style: style,
        ));
      }
    }
  }

  return polygons;
}
