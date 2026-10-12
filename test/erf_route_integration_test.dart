import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:xml/xml.dart';

import 'package:clmschedule/erf_property/adapters/erf_route_adapter.dart';
import 'package:clmschedule/erf_property/models/erf_list_entry.dart';
import 'package:clmschedule/erf_property/models/erf_property.dart';
import 'package:clmschedule/models/address.dart';
import 'package:clmschedule/models/geocode_detail.dart';
import 'package:clmschedule/services/erf_import_service.dart';
import 'package:clmschedule/services/erf_route_bridge.dart';
import 'package:clmschedule/services/route_export_service.dart';
import 'package:clmschedule/services/route_planner_service.dart';
import 'package:clmschedule/shareable_maps/models/map_point.dart';
import 'package:clmschedule/shareable_maps/models/map_layer.dart';
import 'package:clmschedule/shareable_maps/models/shareable_map.dart';
import 'package:clmschedule/shareable_maps/services/map_export_service.dart';

ErfProperty parcel(
  String id,
  String tagValue, {
  double lat = -33.94,
  double lng = 18.49,
  String? street,
}) {
  return ErfProperty(
    id: id,
    erfNumber: int.tryParse(tagValue.replaceAll(RegExp(r'\D'), '')) ?? 0,
    tagValue: tagValue,
    lpiCode: id,
    majRegion: 'CAPE TOWN',
    majCode: 'C0',
    minRegion: 'CONSTANTIA',
    minCode: 'C012',
    province: 'Western Cape',
    area: 1024.5,
    polygon: [
      LatLng(lat, lng),
      LatLng(lat + 0.0005, lng),
      LatLng(lat + 0.0005, lng + 0.0005),
      LatLng(lat, lng + 0.0005),
    ],
    centroid: LatLng(lat + 0.00025, lng + 0.00025),
    streetAddress: street,
  );
}

ErfMatch matched(int line, ErfProperty p, {String? address, String? erf}) =>
    ErfMatch(
      entry: ErfListEntry(
        lineNumber: line,
        rawLine: address ?? 'ERF $erf',
        address: address,
        erfNumber: erf,
      ),
      status: ErfMatchStatus.matched,
      property: p,
    );

void main() {
  group('ERF matches become routable stops', () {
    test('a matched parcel arrives already located', () {
      final result = ErfRouteBridge.fromMatches(
        [matched(1, parcel('C012_4673', '4673'), erf: '4673')],
        defaultSuburb: 'constantia',
      );

      expect(result.matchedCount, 1);
      expect(result.rawAddresses, hasLength(1));

      final row = result.rawAddresses.single;
      expect(row['erfId'], 'C012_4673');
      expect(row['erfNumber'], '4673');
      expect(row['isGeocoded'], 'true');
      expect(double.parse(row['latitude']!), closeTo(-33.93975, 0.0001));
      expect(result.parcels.keys, ['C012_4673']);
    });

    test('the pasted street address survives onto the stop', () {
      final result = ErfRouteBridge.fromMatches(
        [
          matched(1, parcel('C012_4673', '4673'),
              address: '14 Alphen Drive', erf: '4673')
        ],
        defaultSuburb: 'constantia',
      );

      expect(result.rawAddresses.single['streetAddress'], '14 Alphen Drive');
    });

    test('an unmatched line is kept for the geocoder, not dropped', () {
      final result = ErfRouteBridge.fromMatches(
        [
          ErfMatch(
            entry: const ErfListEntry(
              lineNumber: 1,
              rawLine: '99 Nowhere Road, ERF 999999',
              address: '99 Nowhere Road',
              erfNumber: '999999',
            ),
            status: ErfMatchStatus.notFound,
          ),
        ],
        defaultSuburb: 'constantia',
      );

      expect(result.unmatchedCount, 1);
      expect(result.matchedCount, 0);
      expect(result.rawAddresses, hasLength(1));

      final row = result.rawAddresses.single;
      expect(row['streetAddress'], '99 Nowhere Road');
      expect(row['isGeocoded'], isNull);
      expect(row['notes'], contains('not found'));
    });

    test('ambiguous lines are counted apart from outright misses', () {
      final result = ErfRouteBridge.fromMatches(
        [
          ErfMatch(
            entry: const ErfListEntry(
              lineNumber: 1,
              rawLine: 'ERF 1234',
              erfNumber: '1234',
            ),
            status: ErfMatchStatus.ambiguous,
            candidates: [parcel('a', '1234'), parcel('b', '1234')],
          ),
        ],
        defaultSuburb: 'constantia',
      );

      expect(result.ambiguousCount, 1);
      expect(result.unmatchedCount, 0);
    });

    test('a parcel-sourced stop reads as a trustworthy pin', () {
      final address = ErfRouteBridge.addressFromParcel(
        parcel('C012_4673', '4673'),
        id: 'constantia-0',
      );

      expect(address.isGeocoded, isTrue);
      expect(address.precision, GeocodePrecision.exact);
      expect(address.precision.needsReview, isFalse);
      expect(address.hasParcel, isTrue);
      expect(address.displayName, 'ERF 4673');
    });

    test('the ERF link survives a Firestore round trip', () {
      final address = ErfRouteBridge.addressFromParcel(
        parcel('C012_4673', 'RE/4673'),
        id: 'constantia-0',
      );
      final restored = Address.fromMap('constantia-0', address.toMap());

      expect(restored.erfId, 'C012_4673');
      expect(restored.erfNumber, 'RE/4673');
      expect(restored.hasParcel, isTrue);
    });
  });

  group('numbered pins on a shareable map', () {
    MapPoint stopPoint(int sequence) => MapPoint(
          id: 'stop_$sequence',
          name: 'Stop $sequence',
          position: LatLng(-33.94 + sequence / 1000, 18.49),
          color: const Color(0xFF2E7D32),
          routeSequence: sequence,
          createdAt: DateTime(2026, 8, 18),
          updatedAt: DateTime(2026, 8, 18),
        );

    test('routeSequence round-trips through the map', () {
      final restored = MapPoint.fromMap('stop_3', stopPoint(3).toMap());

      expect(restored.routeSequence, 3);
    });

    test('an ordinary point stores no sequence at all', () {
      final plain = MapPoint.create(
        name: 'Depot',
        position: const LatLng(-33.9, 18.5),
      );

      expect(plain.routeSequence, isNull);
      expect(plain.toMap().containsKey('routeSequence'), isFalse);
    });

    test('a per-point icon override beats the category icon', () {
      final layer = MapLayer(
        id: 'stops',
        name: 'Stops',
        order: 0,
        defaultColor: const Color(0xFF2E7D32),
        points: [stopPoint(1), stopPoint(2)],
        createdAt: DateTime(2026, 8, 18),
        updatedAt: DateTime(2026, 8, 18),
      );

      final override =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
      final markers = layer.getGoogleMapsMarkers(
        pointIconOverrides: {'stop_1': override},
      );

      expect(markers, hasLength(2));
      final first = markers.firstWhere((m) => m.markerId.value == 'stop_1');
      final second = markers.firstWhere((m) => m.markerId.value == 'stop_2');
      expect(first.icon, same(override));
      expect(second.icon, isNot(same(override)));
    });

    test('KML zero-pads stop numbers so My Maps sorts them in drive order', () {
      final layer = MapLayer(
        id: 'stops',
        name: 'Stops',
        order: 0,
        defaultColor: const Color(0xFF2E7D32),
        points: [for (var i = 1; i <= 12; i++) stopPoint(i)],
        createdAt: DateTime(2026, 8, 18),
        updatedAt: DateTime(2026, 8, 18),
      );
      final map = ShareableMap(
        id: 'm',
        name: 'Run',
        layers: [layer],
        defaultCenter: const LatLng(-33.9, 18.5),
        defaultZoom: 14,
        createdAt: DateTime(2026, 8, 18),
        updatedAt: DateTime(2026, 8, 18),
      );

      final doc = XmlDocument.parse(MapExportService.exportToKml(map));
      final names = doc
          .findAllElements('Placemark')
          .map((p) => p.getElement('name')!.innerText)
          .toList();

      expect(names.first, '01 · Stop 1');
      expect(names.last, '12 · Stop 12');
      // Alphabetical order must equal drive order.
      expect(List.of(names)..sort(), names);
    });
  });

  group('parcels in the route KML', () {
    PlannedRoute routeWithParcels() {
      final a = ErfRouteBridge.addressFromParcel(
        parcel('p1', '4673', street: '14 Alphen Drive'),
        id: 'c-0',
      );
      final b = ErfRouteBridge.addressFromParcel(
        parcel('p2', '4674', lat: -33.95, street: '16 Alphen Drive'),
        id: 'c-1',
      );

      PlannedStop stop(Address address, int seq) => PlannedStop(
            address: address,
            sequence: seq,
            isDepot: false,
            legDistanceMeters: seq == 1 ? 0 : 900,
            legDurationSeconds: seq == 1 ? 0 : 180,
            legDurationInTrafficSeconds: seq == 1 ? 0 : 180,
            pathFromPrevious: const [],
            cumulativeDistanceMeters: seq == 1 ? 0 : 900,
            cumulativeDrivingSeconds: seq == 1 ? 0 : 180,
          );

      return PlannedRoute(
        stops: [stop(a, 1), stop(b, 2)],
        totalDistanceMeters: 900,
        totalDrivingSeconds: 180,
        totalServiceSeconds: 600,
        usedRealRoads: true,
        algorithm: RouteAlgorithm.googleOptimized,
        options: const RoutePlanOptions(),
        plannedAt: DateTime(2026, 8, 18),
      );
    }

    Map<String, RouteParcel> parcelMap() => {
          'p1': RouteParcel(
            id: 'p1',
            label: 'ERF 4673',
            boundary: parcel('p1', '4673').polygon,
            areaSquareMetres: 1024.5,
          ),
          'p2': RouteParcel(
            id: 'p2',
            label: 'ERF 4674',
            boundary: parcel('p2', '4674', lat: -33.95).polygon,
            areaSquareMetres: 980,
          ),
        };

    test('boundaries land in their own folder, ahead of the stops', () {
      final doc = XmlDocument.parse(RouteExportService.buildKml(
        routeWithParcels(),
        name: 'Constantia run',
        parcels: parcelMap(),
      ));

      final folders = doc
          .findAllElements('Folder')
          .map((f) => f.getElement('name')?.innerText)
          .toList();
      expect(folders.first, 'Delivery parcels');
      expect(folders, contains('Delivery stops'));
      expect(doc.findAllElements('Polygon').length, 2);
    });

    test('each boundary ring is explicitly closed', () {
      final doc = XmlDocument.parse(RouteExportService.buildKml(
        routeWithParcels(),
        name: 'run',
        parcels: parcelMap(),
      ));

      final ring = doc
          .findAllElements('LinearRing')
          .first
          .getElement('coordinates')!
          .innerText
          .trim()
          .split(' ');

      // The source boundary has four corners; KML needs the first repeated.
      expect(ring, hasLength(5));
      expect(ring.first, ring.last);
    });

    test('a parcel placemark carries its stop number', () {
      final doc = XmlDocument.parse(RouteExportService.buildKml(
        routeWithParcels(),
        name: 'run',
        parcels: parcelMap(),
      ));

      final names = doc
          .findAllElements('Folder')
          .first
          .findElements('Placemark')
          .map((p) => p.getElement('name')!.innerText)
          .toList();

      expect(names, ['1. ERF 4673', '2. ERF 4674']);
    });

    test('a run with no parcels emits no parcel folder', () {
      final doc = XmlDocument.parse(RouteExportService.buildKml(
        routeWithParcels(),
        name: 'run',
      ));

      final folders = doc
          .findAllElements('Folder')
          .map((f) => f.getElement('name')?.innerText);
      expect(folders, isNot(contains('Delivery parcels')));
      expect(doc.findAllElements('Polygon'), isEmpty);
    });
  });

  group('run name becomes a suburb key', () {
    test('lower-cases and strips punctuation', () {
      expect(
        ErfImportService.suburbKeyFrom('Constantia Deliveries — Nov'),
        'constantia deliveries nov',
      );
    });

    test('collapses runs of whitespace', () {
      expect(
        ErfImportService.suburbKeyFrom('  Kuils   River  '),
        'kuils river',
      );
    });

    test('two spellings of the same name land on one key', () {
      expect(
        ErfImportService.suburbKeyFrom('Pinelands!'),
        ErfImportService.suburbKeyFrom('pinelands'),
      );
    });

    test('an unusable name falls back rather than yielding an empty key', () {
      // An empty Firestore field name would throw on write.
      expect(ErfImportService.suburbKeyFrom('***'), 'erf list');
      expect(ErfImportService.suburbKeyFrom(''), 'erf list');
    });
  });

  group('the published client map', () {
    PlannedRoute run() {
      final a = ErfRouteBridge.addressFromParcel(
        parcel('p1', '4673', street: '14 Alphen Drive'),
        id: 'c-0',
      );
      final b = ErfRouteBridge.addressFromParcel(
        parcel('p2', '4674', lat: -33.95, street: '16 Alphen Drive'),
        id: 'c-1',
      );
      final c = ErfRouteBridge.addressFromParcel(
        parcel('p3', '4675', lat: -33.96, street: '18 Alphen Drive'),
        id: 'c-2',
      );

      PlannedStop stop(Address address, int seq) => PlannedStop(
            address: address,
            sequence: seq,
            isDepot: false,
            legDistanceMeters: seq == 1 ? 0 : 800,
            legDurationSeconds: seq == 1 ? 0 : 160,
            legDurationInTrafficSeconds: seq == 1 ? 0 : 160,
            pathFromPrevious: seq == 1
                ? const []
                : const [LatLng(-33.94, 18.49), LatLng(-33.95, 18.50)],
            cumulativeDistanceMeters: (seq - 1) * 800,
            cumulativeDrivingSeconds: (seq - 1) * 160,
          );

      return PlannedRoute(
        stops: [stop(a, 1), stop(b, 2), stop(c, 3)],
        totalDistanceMeters: 1600,
        totalDrivingSeconds: 320,
        totalServiceSeconds: 900,
        usedRealRoads: true,
        algorithm: RouteAlgorithm.googleOptimized,
        options: const RoutePlanOptions(),
        plannedAt: DateTime(2026, 8, 18),
      );
    }

    Map<String, ErfProperty> parcels() => {
          'p1': parcel('p1', '4673'),
          'p2': parcel('p2', '4674', lat: -33.95),
          'p3': parcel('p3', '4675', lat: -33.96),
        };

    test('carries parcels, the route and numbered stops', () async {
      final map = await ErfRouteAdapter(
        route: run(),
        parcels: parcels(),
        title: 'CONSTANTIA delivery run',
      ).load();

      final names = map.layers.map((l) => l.name).toList();
      expect(names, contains('Delivery parcels'));
      expect(names, contains('Route'));
      expect(names, contains('Stops in order'));

      final stops = map.layers.firstWhere((l) => l.name == 'Stops in order');
      expect(stops.points, hasLength(3));
      expect(stops.points.map((p) => p.routeSequence), [1, 2, 3]);
    });

    test('stops are the topmost layer so numbers are never buried', () async {
      final map = await ErfRouteAdapter(
        route: run(),
        parcels: parcels(),
        title: 'run',
      ).load();

      expect(map.layers.last.name, 'Stops in order');
      final parcelLayer =
          map.layers.firstWhere((l) => l.name == 'Delivery parcels');
      final stopLayer = map.layers.last;
      expect(stopLayer.order, greaterThan(parcelLayer.order));
    });

    test('every parcel on the run gets a boundary', () async {
      final map = await ErfRouteAdapter(
        route: run(),
        parcels: parcels(),
        title: 'run',
      ).load();

      final parcelLayer =
          map.layers.firstWhere((l) => l.name == 'Delivery parcels');
      expect(parcelLayer.polygons, hasLength(3));
      expect(parcelLayer.polygons.first.name, startsWith('1.'));
    });

    test('a run with no parcels still publishes stops and a route', () async {
      final map = await ErfRouteAdapter(
        route: run(),
        title: 'run',
      ).load();

      final names = map.layers.map((l) => l.name).toList();
      expect(names, isNot(contains('Delivery parcels')));
      expect(names, contains('Stops in order'));
      expect(names, contains('Route'));
    });

    test('survives the Firestore round trip the gallery does', () async {
      final map = await ErfRouteAdapter(
        route: run(),
        parcels: parcels(),
        title: 'CONSTANTIA delivery run',
      ).load();

      final restored = ShareableMap.fromMap('doc1', map.toMap());
      final stops =
          restored.layers.firstWhere((l) => l.name == 'Stops in order');

      // The stop numbers must survive storage — they are what the numbered
      // pins and the KML ordering are built from.
      expect(stops.points.map((p) => p.routeSequence), [1, 2, 3]);
      expect(restored.name, 'CONSTANTIA delivery run');
    });
  });
}
