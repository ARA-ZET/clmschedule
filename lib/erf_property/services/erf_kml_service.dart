import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:xml/xml.dart';

import '../../utils/web_file_download.dart';
import '../models/erf_list_entry.dart';
import '../models/erf_property.dart';

/// Builds and downloads KML for a set of ERF parcels.
///
/// The output is aimed at being useful outside this app: each parcel is a
/// Placemark carrying its polygon plus an `<ExtendedData>` block with the
/// cadastral attributes, so Google My Maps / Earth / QGIS all show the ERF
/// number, LPI code and area rather than just an unlabelled shape.
class ErfKmlService {
  /// Fill/outline for the parcels the user selected.
  static const Color highlightColor = Color(0xFFFF6D00);

  /// Fill/outline for surrounding parcels included as context.
  static const Color contextColor = Color(0xFF00897B);

  /// Build a KML document.
  ///
  /// [selected] is drawn in the highlight style inside a "Selected ERFs"
  /// folder. [context] parcels, when given, go into a second folder in a
  /// muted style so the selection is readable against its neighbours.
  /// [unmatched] entries are recorded as a comment folder note so nothing
  /// the user pasted disappears silently.
  static String buildKml({
    required String documentName,
    required List<ErfProperty> selected,
    List<ErfProperty> context = const [],
    List<ErfListEntry> unmatched = const [],
    String? description,
  }) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');

    builder.element('kml', nest: () {
      builder.attribute('xmlns', 'http://www.opengis.net/kml/2.2');

      builder.element('Document', nest: () {
        builder.element('name', nest: documentName);

        final summary = StringBuffer()
          ..write('${selected.length} selected ERF '
              '${selected.length == 1 ? 'parcel' : 'parcels'}');
        if (context.isNotEmpty) {
          summary.write(', ${context.length} surrounding parcels');
        }
        if (unmatched.isNotEmpty) {
          summary.write(', ${unmatched.length} unmatched entries');
        }
        if (description != null && description.isNotEmpty) {
          summary.write('\n$description');
        }
        builder.element('description', nest: summary.toString());

        _addStyle(builder, 'erfSelected', highlightColor, fillAlpha: 0x80,
            strokeWidth: 3);
        _addStyle(builder, 'erfContext', contextColor, fillAlpha: 0x33,
            strokeWidth: 1);

        _addFolder(
          builder,
          name: 'Selected ERFs',
          styleId: '#erfSelected',
          properties: selected,
        );

        if (context.isNotEmpty) {
          _addFolder(
            builder,
            name: 'Surrounding ERFs',
            styleId: '#erfContext',
            properties: context,
            visible: false,
          );
        }

        if (unmatched.isNotEmpty) {
          builder.element('Folder', nest: () {
            builder.element('name', nest: 'Unmatched entries');
            builder.element('visibility', nest: '0');
            builder.element(
              'description',
              nest: unmatched
                  .map((e) => 'Line ${e.lineNumber}: ${e.rawLine}')
                  .join('\n'),
            );
          });
        }
      });
    });

    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  /// Write [kml] to the user's device as [fileName].
  ///
  /// Returns the saved path on desktop/mobile, or null on web where the
  /// browser owns the destination.
  static Future<String?> download(String kml, String fileName) {
    final safeName =
        fileName.toLowerCase().endsWith('.kml') ? fileName : '$fileName.kml';
    return triggerFileDownload(
      Uint8List.fromList(utf8.encode(kml)),
      safeName,
      'application/vnd.google-earth.kml+xml',
    );
  }

  /// A filesystem-safe file name derived from [label].
  static String fileNameFor(String label) {
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final slug = label
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final base = slug.isEmpty ? 'erf_selection' : slug.toLowerCase();
    return '${base}_$stamp.kml';
  }

  // ── Builders ────────────────────────────────────────────────────────

  static void _addStyle(
    XmlBuilder builder,
    String id,
    Color color, {
    required int fillAlpha,
    required int strokeWidth,
  }) {
    builder.element('Style', nest: () {
      builder.attribute('id', id);
      builder.element('LineStyle', nest: () {
        builder.element('color', nest: _kmlColor(color, 0xFF));
        builder.element('width', nest: '$strokeWidth');
      });
      builder.element('PolyStyle', nest: () {
        builder.element('color', nest: _kmlColor(color, fillAlpha));
        builder.element('fill', nest: '1');
        builder.element('outline', nest: '1');
      });
    });
  }

  static void _addFolder(
    XmlBuilder builder, {
    required String name,
    required String styleId,
    required List<ErfProperty> properties,
    bool visible = true,
  }) {
    builder.element('Folder', nest: () {
      builder.element('name', nest: name);
      if (!visible) builder.element('visibility', nest: '0');
      for (final property in properties) {
        _addPlacemark(builder, property, styleId);
      }
    });
  }

  static void _addPlacemark(
    XmlBuilder builder,
    ErfProperty property,
    String styleId,
  ) {
    builder.element('Placemark', nest: () {
      builder.element('name', nest: property.displayLabel);
      builder.element('description', nest: _describe(property));
      builder.element('styleUrl', nest: styleId);

      builder.element('ExtendedData', nest: () {
        _data(builder, 'erfNumber', property.tagValue.isNotEmpty
            ? property.tagValue
            : '${property.erfNumber}');
        _data(builder, 'lpiCode', property.lpiCode);
        _data(builder, 'streetAddress', property.streetAddress ?? '');
        _data(builder, 'suburb', property.suburb ?? property.minRegion);
        _data(builder, 'minRegion', property.minRegion);
        _data(builder, 'minCode', property.minCode);
        _data(builder, 'majRegion', property.majRegion);
        _data(builder, 'province', property.province);
        _data(builder, 'areaSqm', property.area.toStringAsFixed(1));
        _data(builder, 'centroidLat', '${property.centroid.latitude}');
        _data(builder, 'centroidLng', '${property.centroid.longitude}');
      });

      if (property.polygon.length >= 3) {
        builder.element('Polygon', nest: () {
          builder.element('tessellate', nest: '1');
          builder.element('outerBoundaryIs', nest: () {
            builder.element('LinearRing', nest: () {
              builder.element('coordinates', nest: _coordinates(property));
            });
          });
        });
      } else {
        // No usable geometry — still place a pin so the entry is findable.
        builder.element('Point', nest: () {
          builder.element(
            'coordinates',
            nest: '${property.centroid.longitude},'
                '${property.centroid.latitude},0',
          );
        });
      }
    });
  }

  static void _data(XmlBuilder builder, String name, String value) {
    builder.element('Data', nest: () {
      builder.attribute('name', name);
      builder.element('value', nest: value);
    });
  }

  static String _describe(ErfProperty property) {
    final lines = <String>[
      'ERF ${property.tagValue.isNotEmpty ? property.tagValue : property.erfNumber}',
      if (property.streetAddress != null && property.streetAddress!.isNotEmpty)
        property.streetAddress!,
      if (property.minRegion.isNotEmpty) property.minRegion,
      if (property.majRegion.isNotEmpty) property.majRegion,
      if (property.province.isNotEmpty) property.province,
      '${property.area.toStringAsFixed(1)} m²',
      if (property.lpiCode.isNotEmpty) 'LPI: ${property.lpiCode}',
    ];
    return lines.join('\n');
  }

  /// KML rings are lng,lat,alt and must close on their first point.
  static String _coordinates(ErfProperty property) {
    final points = List.of(property.polygon);
    if (points.first.latitude != points.last.latitude ||
        points.first.longitude != points.last.longitude) {
      points.add(points.first);
    }
    return points.map((p) => '${p.longitude},${p.latitude},0').join(' ');
  }

  /// KML colours are AABBGGRR, the reverse byte order of Flutter's ARGB.
  static String _kmlColor(Color color, int alpha) {
    String hex(int v) => v.toRadixString(16).padLeft(2, '0');
    final r = (color.r * 255).round();
    final g = (color.g * 255).round();
    final b = (color.b * 255).round();
    return '${hex(alpha)}${hex(b)}${hex(g)}${hex(r)}';
  }
}
