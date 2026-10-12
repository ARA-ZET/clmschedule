import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:xml/xml.dart';

import '../models/address.dart';
import '../utils/polyline_codec.dart';
import 'route_planner_service.dart';

/// A cadastral parcel boundary to draw under a stop.
///
/// Deliberately not the ERF model itself — the exporter has no business
/// knowing about the cadastral register, and this keeps a route from any
/// source exportable with boundaries attached.
class RouteParcel {
  final String id;
  final String label;
  final List<LatLng> boundary;

  /// Square metres, when known.
  final double? areaSquareMetres;

  const RouteParcel({
    required this.id,
    required this.label,
    required this.boundary,
    this.areaSquareMetres,
  });
}

/// Turns a [PlannedRoute] into the files a delivery run actually needs:
/// a KML for Google Earth / My Maps, a spreadsheet for the office, and a
/// GPX for a handheld or vehicle unit.
class RouteExportService {
  static final DateFormat _timeFormat = DateFormat('HH:mm');
  static final DateFormat _stampFormat = DateFormat('yyyy-MM-dd HH:mm');
  static final DateFormat _fileStampFormat = DateFormat('yyyyMMdd-HHmm');

  // ── KML ────────────────────────────────────────────────────────────────

  /// Build a KML document for [route].
  ///
  /// The stops go in one folder as numbered placemarks — numbered so the
  /// order survives into Google My Maps, which sorts by name rather than
  /// document order — and the driven roads go in a second folder as a
  /// LineString per leg. Every placemark carries ExtendedData (sequence,
  /// coordinates, leg distance/duration, ETA, geocode precision) so the
  /// data is still queryable after the round trip through Earth.
  static String buildKml(
    PlannedRoute route, {
    required String name,
    String? description,
    bool includeRoadPath = true,
    double simplifyToleranceMeters = 4,
    Map<String, RouteParcel> parcels = const {},
  }) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');

    builder.element('kml', nest: () {
      builder.attribute('xmlns', 'http://www.opengis.net/kml/2.2');
      builder.element('Document', nest: () {
        builder.element('name', nest: name);
        builder.element('description',
            nest: description ?? _routeSummaryText(route));
        builder.element('open', nest: '1');

        _addKmlStyles(builder);

        // ── Parcels ──────────────────────────────────────────────────
        // Drawn before the stops so the numbered pins sit on top of the
        // boundaries rather than under them.
        if (parcels.isNotEmpty) {
          final drawn = <String>{};
          builder.element('Folder', nest: () {
            builder.element('name', nest: 'Delivery parcels');
            builder.element('open', nest: '0');

            for (final stop in route.stops) {
              final parcel = parcels[stop.address.erfId];
              if (parcel == null || parcel.boundary.length < 3) continue;
              if (!drawn.add(parcel.id)) continue;
              _addParcelPolygon(builder, parcel, stop);
            }
          });
        }

        // ── Stops ────────────────────────────────────────────────────
        builder.element('Folder', nest: () {
          builder.element('name', nest: 'Delivery stops');
          builder.element('open', nest: '1');

          final total = route.stops.length;
          for (var i = 0; i < total; i++) {
            final stop = route.stops[i];
            _addStopPlacemark(
              builder,
              stop,
              styleId: stop.isDepot
                  ? 'depot'
                  : i == total - 1
                      ? 'stopLast'
                      : i == 0
                          ? 'stopFirst'
                          : 'stop',
              totalStops: total,
            );
          }
        });

        // ── Roads ────────────────────────────────────────────────────
        if (includeRoadPath) {
          builder.element('Folder', nest: () {
            builder.element('name', nest: 'Route');
            builder.element('open', nest: '0');

            for (var i = 1; i < route.stops.length; i++) {
              final stop = route.stops[i];
              if (stop.pathFromPrevious.length < 2) continue;
              _addLegLineString(
                builder,
                legName: 'Leg $i → ${_stopLabel(route.stops[i])}',
                description: '${stop.legDistanceKm.toStringAsFixed(2)} km · '
                    '${stop.legDurationFormatted}',
                path: simplifyPath(stop.pathFromPrevious,
                    toleranceMeters: simplifyToleranceMeters),
              );
            }

            final back = route.returnLeg;
            if (back != null && back.pathFromPrevious.length >= 2) {
              _addLegLineString(
                builder,
                legName: 'Return to start',
                description: '${back.legDistanceKm.toStringAsFixed(2)} km · '
                    '${back.legDurationFormatted}',
                path: simplifyPath(back.pathFromPrevious,
                    toleranceMeters: simplifyToleranceMeters),
              );
            }
          });
        }
      });
    });

    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  static void _addKmlStyles(XmlBuilder builder) {
    // KML colours are AABBGGRR, not RRGGBB.
    void pinStyle(String id, String href, String lineColour) {
      builder.element('Style', nest: () {
        builder.attribute('id', id);
        builder.element('IconStyle', nest: () {
          builder.element('scale', nest: '1.1');
          builder.element('Icon', nest: () {
            builder.element('href', nest: href);
          });
        });
        builder.element('LabelStyle', nest: () {
          builder.element('scale', nest: '0.9');
        });
        builder.element('LineStyle', nest: () {
          builder.element('color', nest: lineColour);
          builder.element('width', nest: '4');
        });
      });
    }

    const base = 'https://maps.google.com/mapfiles/kml/paddle';
    pinStyle('depot', '$base/wht-blank.png', 'ff7d4b1e');
    pinStyle('stopFirst', '$base/grn-circle.png', 'ff2ea52e');
    pinStyle('stop', '$base/ylw-circle.png', 'ff1e90ff');
    pinStyle('stopLast', '$base/red-circle.png', 'ff2222dd');

    builder.element('Style', nest: () {
      builder.attribute('id', 'parcel');
      builder.element('PolyStyle', nest: () {
        builder.element('color', nest: '55ff901e'); // translucent blue fill
        builder.element('fill', nest: '1');
        builder.element('outline', nest: '1');
      });
      builder.element('LineStyle', nest: () {
        builder.element('color', nest: 'ffff901e');
        builder.element('width', nest: '2');
      });
    });

    builder.element('Style', nest: () {
      builder.attribute('id', 'roadLeg');
      builder.element('LineStyle', nest: () {
        builder.element('color', nest: 'ffff901e'); // opaque blue
        builder.element('width', nest: '5');
      });
    });
  }

  static void _addStopPlacemark(
    XmlBuilder builder,
    PlannedStop stop, {
    required String styleId,
    required int totalStops,
  }) {
    final address = stop.address;
    // Zero-padded so My Maps' alphabetical sort matches the drive order.
    final width = totalStops.toString().length;
    final seq = stop.sequence.toString().padLeft(width, '0');
    final label =
        stop.isDepot ? 'START · ${_stopLabel(stop)}' : '$seq · ${_stopLabel(stop)}';

    builder.element('Placemark', nest: () {
      builder.element('name', nest: label);
      builder.element('description', nest: _stopDescription(stop));
      builder.element('styleUrl', nest: '#$styleId');

      builder.element('ExtendedData', nest: () {
        void data(String key, String value) {
          builder.element('Data', nest: () {
            builder.attribute('name', key);
            builder.element('value', nest: value);
          });
        }

        data('sequence', stop.isDepot ? 'start' : stop.sequence.toString());
        data('street', address.streetAddress);
        data('suburb', address.suburb);
        data('city', address.city);
        data('postalCode', address.postalCode);
        data('province', address.province);
        data('country', address.country);
        data('latitude', address.latitude?.toStringAsFixed(6) ?? '');
        data('longitude', address.longitude?.toStringAsFixed(6) ?? '');
        data('geocodePrecision', address.precision.label);
        data('legDistanceKm', stop.legDistanceKm.toStringAsFixed(2));
        data('legDuration', stop.legDurationFormatted);
        data('cumulativeKm', stop.cumulativeDistanceKm.toStringAsFixed(2));
        if (stop.arrival != null) data('eta', _timeFormat.format(stop.arrival!));
        if (address.notes?.isNotEmpty ?? false) data('notes', address.notes!);
      });

      builder.element('Point', nest: () {
        builder.element('coordinates',
            nest: '${address.longitude},${address.latitude},0');
      });
    });
  }

  static void _addParcelPolygon(
    XmlBuilder builder,
    RouteParcel parcel,
    PlannedStop stop,
  ) {
    builder.element('Placemark', nest: () {
      builder.element('name',
          nest: stop.isDepot
              ? 'Start · ${parcel.label}'
              : '${stop.sequence}. ${parcel.label}');
      builder.element('description', nest: [
        if (!stop.isDepot) 'Stop ${stop.sequence}',
        stop.address.fullAddress,
        if (parcel.areaSquareMetres != null)
          '${parcel.areaSquareMetres!.toStringAsFixed(0)} m²',
      ].where((l) => l.trim().isNotEmpty).join('\n'));
      builder.element('styleUrl', nest: '#parcel');

      builder.element('Polygon', nest: () {
        builder.element('tessellate', nest: '1');
        builder.element('outerBoundaryIs', nest: () {
          builder.element('LinearRing', nest: () {
            final ring = [
              ...parcel.boundary,
              // KML requires the ring to close on itself.
              if (parcel.boundary.first != parcel.boundary.last)
                parcel.boundary.first,
            ];
            builder.element('coordinates',
                nest: ring
                    .map((p) =>
                        '${p.longitude.toStringAsFixed(7)},${p.latitude.toStringAsFixed(7)},0')
                    .join(' '));
          });
        });
      });
    });
  }

  static void _addLegLineString(
    XmlBuilder builder, {
    required String legName,
    required String description,
    required List<LatLng> path,
  }) {
    builder.element('Placemark', nest: () {
      builder.element('name', nest: legName);
      builder.element('description', nest: description);
      builder.element('styleUrl', nest: '#roadLeg');
      builder.element('LineString', nest: () {
        builder.element('tessellate', nest: '1');
        builder.element('coordinates',
            nest: path
                .map((p) =>
                    '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)},0')
                .join(' '));
      });
    });
  }

  static String _stopDescription(PlannedStop stop) {
    final a = stop.address;
    final lines = <String>[
      a.fullAddress,
      if ((a.formattedAddress?.isNotEmpty ?? false) &&
          a.formattedAddress != a.fullAddress)
        'Matched: ${a.formattedAddress}',
      'Geocode precision: ${a.precision.label}',
      if (!stop.isDepot)
        'Leg: ${stop.legDistanceKm.toStringAsFixed(2)} km · '
            '${stop.legDurationFormatted}',
      'Cumulative: ${stop.cumulativeDistanceKm.toStringAsFixed(2)} km',
      if (stop.arrival != null) 'ETA: ${_timeFormat.format(stop.arrival!)}',
      if (a.notes?.isNotEmpty ?? false) 'Notes: ${a.notes}',
    ];
    return lines.join('\n');
  }

  static String _stopLabel(PlannedStop stop) => stop.address.displayName;

  static String _routeSummaryText(PlannedRoute route) {
    return [
      '${route.deliveryStops.length} stops',
      route.totalDistanceFormatted,
      'driving ${route.totalDrivingFormatted}',
      'ordered by ${route.algorithm.label}',
      route.usedRealRoads ? 'real road distances' : 'straight-line estimates',
      'planned ${_stampFormat.format(route.plannedAt)}',
    ].join(' · ');
  }

  // ── Spreadsheet ────────────────────────────────────────────────────────

  /// Column headings for the spreadsheet exports, in order.
  static const List<String> sheetHeaders = [
    'Stop',
    'Type',
    'Street Address',
    'Suburb',
    'City',
    'Postal Code',
    'Province',
    'Country',
    'Latitude',
    'Longitude',
    'Geocode Precision',
    'Matched Address',
    'Leg km',
    'Leg Time',
    'Cumulative km',
    'Cumulative Time',
    'ETA',
    'Depart',
    'Notes',
    'Maps Link',
  ];

  static List<List<String>> _sheetRows(PlannedRoute route) {
    final rows = <List<String>>[];

    void addRow(PlannedStop stop, {bool isReturn = false}) {
      final a = stop.address;
      rows.add([
        isReturn
            ? 'Return'
            : stop.isDepot
                ? 'Start'
                : stop.sequence.toString(),
        isReturn
            ? 'Return to start'
            : stop.isDepot
                ? 'Depot'
                : 'Delivery',
        a.streetAddress,
        a.suburb,
        a.city,
        a.postalCode,
        a.province,
        a.country,
        a.latitude?.toStringAsFixed(6) ?? '',
        a.longitude?.toStringAsFixed(6) ?? '',
        a.precision.label,
        a.formattedAddress ?? '',
        stop.legDistanceKm.toStringAsFixed(2),
        stop.legDurationFormatted,
        stop.cumulativeDistanceKm.toStringAsFixed(2),
        stop.cumulativeDurationFormatted,
        stop.arrival == null ? '' : _timeFormat.format(stop.arrival!),
        stop.departure == null ? '' : _timeFormat.format(stop.departure!),
        a.notes ?? '',
        mapsPinUrl(a),
      ]);
    }

    for (final stop in route.stops) {
      addRow(stop);
    }
    if (route.returnLeg != null) addRow(route.returnLeg!, isReturn: true);

    return rows;
  }

  /// CSV of the route in driving order — opens directly in Google Sheets
  /// via File ▸ Import, and in Excel and Numbers.
  static String buildCsv(PlannedRoute route) {
    final buffer = StringBuffer();
    buffer.writeln(sheetHeaders.map(_csvCell).join(','));
    for (final row in _sheetRows(route)) {
      buffer.writeln(row.map(_csvCell).join(','));
    }
    return buffer.toString();
  }

  /// Tab-separated version of the same table.
  ///
  /// Copied to the clipboard this pastes straight into a Google Sheet as
  /// proper columns — no import step, no upload, no delimiter dialog.
  static String buildTsv(PlannedRoute route) {
    String cell(String value) =>
        value.replaceAll('\t', ' ').replaceAll('\n', ' ').trim();

    final buffer = StringBuffer();
    buffer.writeln(sheetHeaders.map(cell).join('\t'));
    for (final row in _sheetRows(route)) {
      buffer.writeln(row.map(cell).join('\t'));
    }
    return buffer.toString();
  }

  static String _csvCell(String value) {
    // Excel and Sheets both read a leading =, +, - or @ as a formula.
    final guarded = value.isNotEmpty && '=+-@'.contains(value[0])
        ? "'$value"
        : value;
    if (guarded.contains(RegExp(r'[",\n\r]'))) {
      return '"${guarded.replaceAll('"', '""')}"';
    }
    return guarded;
  }

  // ── GPX ────────────────────────────────────────────────────────────────

  /// GPX with each stop as a numbered waypoint and the roads as a track,
  /// for handheld GPS units and most in-cab navigation apps.
  static String buildGpx(PlannedRoute route, {required String name}) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('gpx', nest: () {
      builder.attribute('version', '1.1');
      builder.attribute('creator', 'CLM Schedule route planner');
      builder.attribute('xmlns', 'http://www.topografix.com/GPX/1/1');

      builder.element('metadata', nest: () {
        builder.element('name', nest: name);
        builder.element('desc', nest: _routeSummaryText(route));
        builder.element('time', nest: route.plannedAt.toUtc().toIso8601String());
      });

      for (final stop in route.stops) {
        final a = stop.address;
        if (a.latitude == null || a.longitude == null) continue;
        builder.element('wpt', nest: () {
          builder.attribute('lat', a.latitude!.toStringAsFixed(6));
          builder.attribute('lon', a.longitude!.toStringAsFixed(6));
          builder.element('name',
              nest: stop.isDepot
                  ? 'START ${a.displayName}'
                  : '${stop.sequence}. ${a.displayName}');
          builder.element('desc', nest: a.fullAddress);
          builder.element('type', nest: stop.isDepot ? 'depot' : 'delivery');
        });
      }

      final path = simplifyPath(route.fullPath, toleranceMeters: 4);
      if (path.length >= 2) {
        builder.element('trk', nest: () {
          builder.element('name', nest: '$name route');
          builder.element('trkseg', nest: () {
            for (final p in path) {
              builder.element('trkpt', nest: () {
                builder.attribute('lat', p.latitude.toStringAsFixed(6));
                builder.attribute('lon', p.longitude.toStringAsFixed(6));
              });
            }
          });
        });
      }
    });

    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  // ── Links ──────────────────────────────────────────────────────────────

  /// A Google Maps pin for one address.
  static String mapsPinUrl(Address address) {
    if (address.latitude == null || address.longitude == null) {
      return 'https://www.google.com/maps/search/?api=1&query='
          '${Uri.encodeComponent(address.fullAddress)}';
    }
    return 'https://www.google.com/maps/search/?api=1&query='
        '${address.latitude},${address.longitude}';
  }

  /// Turn-by-turn directions for the whole run, opened in Google Maps.
  ///
  /// Maps accepts at most 25 points in a directions link, so longer runs
  /// come back as several links — one per leg of the day — rather than a
  /// single silently-truncated one.
  static List<String> mapsDirectionsUrls(PlannedRoute route) {
    final points = [
      for (final s in route.stops)
        if (s.address.latitude != null && s.address.longitude != null)
          '${s.address.latitude},${s.address.longitude}',
      if (route.returnLeg != null &&
          route.stops.isNotEmpty &&
          route.stops.first.address.latitude != null)
        '${route.stops.first.address.latitude},'
            '${route.stops.first.address.longitude}',
    ];
    if (points.length < 2) return const [];

    const maxPointsPerLink = 25;
    final urls = <String>[];
    var cursor = 0;
    while (cursor < points.length - 1) {
      final end = (cursor + maxPointsPerLink).clamp(0, points.length);
      final slice = points.sublist(cursor, end);
      final waypoints = slice.length > 2
          ? slice.sublist(1, slice.length - 1).join('|')
          : '';
      urls.add([
        'https://www.google.com/maps/dir/?api=1',
        'origin=${slice.first}',
        'destination=${slice.last}',
        if (waypoints.isNotEmpty) 'waypoints=${Uri.encodeComponent(waypoints)}',
        'travelmode=driving',
      ].join('&'));
      cursor = end - 1;
    }
    return urls;
  }

  // ── File helpers ───────────────────────────────────────────────────────

  static Uint8List toBytes(String content) =>
      Uint8List.fromList(utf8.encode(content));

  /// `pinelands-route-20260818-0730.kml` — sortable and self-describing.
  static String fileName(String base, String extension, DateTime when) {
    final safe = base
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final stem = safe.isEmpty ? 'route' : safe;
    return '$stem-route-${_fileStampFormat.format(when)}.$extension';
  }
}
