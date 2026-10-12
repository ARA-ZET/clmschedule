import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:xml/xml.dart';

import 'package:clmschedule/models/address.dart';
import 'package:clmschedule/services/route_export_service.dart';
import 'package:clmschedule/services/route_planner_service.dart';

Address _address(
  String id,
  String street, {
  double lat = -33.94,
  double lng = 18.49,
  String locationType = 'ROOFTOP',
  String? notes,
}) {
  return Address(
    id: id,
    streetAddress: street,
    suburb: 'Pinelands',
    city: 'Cape Town',
    postalCode: '7405',
    province: 'Western Cape',
    country: 'South Africa',
    latitude: lat,
    longitude: lng,
    isGeocoded: true,
    locationType: locationType,
    notes: notes,
  );
}

PlannedStop _stop(
  Address address,
  int sequence, {
  bool isDepot = false,
  double legKm = 0,
  int legSeconds = 0,
  double cumulativeKm = 0,
  DateTime? arrival,
  List<LatLng> path = const [],
}) {
  return PlannedStop(
    address: address,
    sequence: sequence,
    isDepot: isDepot,
    legDistanceMeters: legKm * 1000,
    legDurationSeconds: legSeconds,
    legDurationInTrafficSeconds: legSeconds,
    pathFromPrevious: path,
    cumulativeDistanceMeters: cumulativeKm * 1000,
    cumulativeDrivingSeconds: legSeconds,
    arrival: arrival,
    departure: arrival?.add(const Duration(minutes: 5)),
  );
}

PlannedRoute _route({bool withPaths = true}) {
  final start = DateTime(2026, 8, 18, 8);
  return PlannedRoute(
    stops: [
      _stop(_address('a', '30 Riverside Road'), 1, arrival: start),
      _stop(
        _address('b', '12 Central Square', lat: -33.95, lng: 18.50),
        2,
        legKm: 1.4,
        legSeconds: 300,
        cumulativeKm: 1.4,
        arrival: start.add(const Duration(minutes: 10)),
        path: withPaths
            ? const [LatLng(-33.94, 18.49), LatLng(-33.95, 18.50)]
            : const [],
      ),
      _stop(
        _address('c', '8 Forest Drive',
            lat: -33.96, lng: 18.51, notes: 'Ring the bell'),
        3,
        legKm: 2.1,
        legSeconds: 420,
        cumulativeKm: 3.5,
        arrival: start.add(const Duration(minutes: 22)),
        path: withPaths
            ? const [LatLng(-33.95, 18.50), LatLng(-33.96, 18.51)]
            : const [],
      ),
    ],
    totalDistanceMeters: 3500,
    totalDrivingSeconds: 720,
    totalServiceSeconds: 900,
    usedRealRoads: true,
    algorithm: RouteAlgorithm.googleOptimized,
    options: const RoutePlanOptions(),
    plannedAt: DateTime(2026, 8, 18, 7, 30),
  );
}

void main() {
  group('KML', () {
    test('is well-formed with a stop folder and a route folder', () {
      final doc = XmlDocument.parse(
        RouteExportService.buildKml(_route(), name: 'Pinelands route'),
      );

      final folders = doc.findAllElements('Folder').toList();
      expect(folders.map((f) => f.getElement('name')?.innerText),
          ['Delivery stops', 'Route']);

      final stopFolder = folders.first;
      expect(stopFolder.findElements('Placemark').length, 3);
    });

    test('numbers the stops so an alphabetical sort matches drive order', () {
      final doc = XmlDocument.parse(
        RouteExportService.buildKml(_route(), name: 'Pinelands route'),
      );

      final names = doc
          .findAllElements('Folder')
          .first
          .findElements('Placemark')
          .map((p) => p.getElement('name')!.innerText)
          .toList();

      expect(names, [
        '1 · 30 Riverside Road',
        '2 · 12 Central Square',
        '3 · 8 Forest Drive',
      ]);
      expect(List.of(names)..sort(), names);
    });

    test('writes coordinates as lon,lat,alt', () {
      final doc = XmlDocument.parse(
        RouteExportService.buildKml(_route(), name: 'r'),
      );

      final first = doc
          .findAllElements('Point')
          .first
          .getElement('coordinates')!
          .innerText;
      expect(first, '18.49,-33.94,0');
    });

    test('carries per-stop data through as ExtendedData', () {
      final doc = XmlDocument.parse(
        RouteExportService.buildKml(_route(), name: 'r'),
      );

      final last = doc.findAllElements('Placemark').toList()[2];
      final data = {
        for (final d in last.findAllElements('Data'))
          d.getAttribute('name')!: d.getElement('value')!.innerText,
      };

      expect(data['sequence'], '3');
      expect(data['legDistanceKm'], '2.10');
      expect(data['cumulativeKm'], '3.50');
      expect(data['eta'], '08:22');
      expect(data['notes'], 'Ring the bell');
      expect(data['geocodePrecision'], 'Rooftop');
    });

    test('stops-only export leaves the road geometry out', () {
      final doc = XmlDocument.parse(
        RouteExportService.buildKml(_route(),
            name: 'r', includeRoadPath: false),
      );

      expect(doc.findAllElements('LineString'), isEmpty);
      expect(doc.findAllElements('Point').length, 3);
    });
  });

  group('spreadsheet', () {
    test('CSV keeps the header and one row per stop', () {
      final lines = RouteExportService.buildCsv(_route()).trim().split('\n');

      expect(lines.first.split(',').first, 'Stop');
      expect(lines, hasLength(4)); // header + 3 stops
      expect(lines[1], startsWith('1,Delivery,30 Riverside Road'));
    });

    test('CSV quotes a cell containing a comma', () {
      final route = _route();
      final withComma = PlannedRoute(
        stops: [
          _stop(_address('a', 'Unit 4, Culemborg'), 1),
          ...route.stops.skip(1),
        ],
        totalDistanceMeters: route.totalDistanceMeters,
        totalDrivingSeconds: route.totalDrivingSeconds,
        totalServiceSeconds: route.totalServiceSeconds,
        usedRealRoads: true,
        algorithm: route.algorithm,
        options: route.options,
        plannedAt: route.plannedAt,
      );

      final csv = RouteExportService.buildCsv(withComma);
      expect(csv, contains('"Unit 4, Culemborg"'));
    });

    test('CSV defuses a cell that would be read as a formula', () {
      final route = PlannedRoute(
        stops: [_stop(_address('a', '=cmd|calc'), 1)],
        totalDistanceMeters: 0,
        totalDrivingSeconds: 0,
        totalServiceSeconds: 0,
        usedRealRoads: true,
        algorithm: RouteAlgorithm.keepOrder,
        options: const RoutePlanOptions(),
        plannedAt: DateTime(2026, 8, 18),
      );

      expect(RouteExportService.buildCsv(route), contains("'=cmd|calc"));
    });

    test('TSV is tab-delimited in the same drive order', () {
      final lines = RouteExportService.buildTsv(_route()).trim().split('\n');

      expect(lines.first.split('\t'),
          hasLength(RouteExportService.sheetHeaders.length));
      expect(lines[1].split('\t')[2], '30 Riverside Road');
      expect(lines[3].split('\t')[2], '8 Forest Drive');
    });
  });

  group('GPX', () {
    test('emits one waypoint per stop plus a track', () {
      final doc = XmlDocument.parse(
        RouteExportService.buildGpx(_route(), name: 'Pinelands'),
      );

      expect(doc.findAllElements('wpt').length, 3);
      expect(doc.findAllElements('trk').length, 1);
      expect(doc.findAllElements('trkpt').length, greaterThanOrEqualTo(2));
    });
  });

  group('Google Maps links', () {
    test('one link covers a short run', () {
      final urls = RouteExportService.mapsDirectionsUrls(_route());

      expect(urls, hasLength(1));
      expect(urls.single, contains('origin=-33.94,18.49'));
      expect(urls.single, contains('destination=-33.96,18.51'));
      expect(urls.single, contains('waypoints='));
    });

    test('a long run is split rather than silently truncated', () {
      final stops = [
        for (var i = 0; i < 40; i++)
          _stop(_address('s$i', 'Stop $i', lat: -33.9 - i / 1000), i + 1),
      ];
      final route = PlannedRoute(
        stops: stops,
        totalDistanceMeters: 0,
        totalDrivingSeconds: 0,
        totalServiceSeconds: 0,
        usedRealRoads: true,
        algorithm: RouteAlgorithm.keepOrder,
        options: const RoutePlanOptions(),
        plannedAt: DateTime(2026, 8, 18),
      );

      final urls = RouteExportService.mapsDirectionsUrls(route);
      expect(urls.length, greaterThan(1));
      // Consecutive links must overlap so no leg goes missing.
      expect(urls[1], contains('origin=-33.924'));
    });

    test('fewer than two points yields no link', () {
      final route = PlannedRoute(
        stops: [_stop(_address('a', 'Only stop'), 1)],
        totalDistanceMeters: 0,
        totalDrivingSeconds: 0,
        totalServiceSeconds: 0,
        usedRealRoads: true,
        algorithm: RouteAlgorithm.keepOrder,
        options: const RoutePlanOptions(),
        plannedAt: DateTime(2026, 8, 18),
      );

      expect(RouteExportService.mapsDirectionsUrls(route), isEmpty);
    });
  });

  test('file names are sortable and safe', () {
    final name = RouteExportService.fileName(
      'Pinelands / North',
      'kml',
      DateTime(2026, 8, 18, 7, 30),
    );
    expect(name, 'pinelands-north-route-20260818-0730.kml');
  });
}
