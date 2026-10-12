import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:clmschedule/models/address.dart';
import 'package:clmschedule/models/geocode_detail.dart';
import 'package:clmschedule/models/route_data.dart';
import 'package:clmschedule/services/route_planner_service.dart';
import 'package:clmschedule/utils/polyline_codec.dart';

void main() {
  group('request batching', () {
    test('a run inside one chunk costs a single request', () {
      expect(RoutePlannerService.chunkCountFor(2), 1);
      expect(RoutePlannerService.chunkCountFor(25), 1);
    });

    test('chunks overlap by one stop so no leg is skipped', () {
      // 25 stops per request, sharing an endpoint: 26 stops needs 2.
      expect(RoutePlannerService.chunkCountFor(26), 2);
      expect(RoutePlannerService.chunkCountFor(49), 2);
      expect(RoutePlannerService.chunkCountFor(50), 3);
    });

    test('batching beats one request per leg by a wide margin', () {
      const stops = 200;
      final batched = RoutePlannerService.chunkCountFor(stops);
      expect(batched, lessThan(stops - 1));
      expect(batched, lessThanOrEqualTo(10));
    });

    test('fewer than two stops needs no request at all', () {
      expect(RoutePlannerService.chunkCountFor(0), 0);
      expect(RoutePlannerService.chunkCountFor(1), 0);
    });
  });

  group('duration formatting', () {
    test('reads in minutes below the hour', () {
      expect(formatDuration(0), '0 min');
      expect(formatDuration(59), '0 min');
      expect(formatDuration(300), '5 min');
    });

    test('splits into hours and minutes above it', () {
      expect(formatDuration(3600), '1h');
      expect(formatDuration(5400), '1h 30m');
      expect(formatDuration(7260), '2h 1m');
    });
  });

  group('planned route totals', () {
    PlannedStop stop(String id,
        {double km = 0, int seconds = 0, bool depot = false}) {
      return PlannedStop(
        address: Address(
          id: id,
          streetAddress: id,
          suburb: 'Pinelands',
          city: 'Cape Town',
          postalCode: '',
          province: '',
          country: '',
          latitude: -33.9,
          longitude: 18.5,
          isGeocoded: true,
        ),
        sequence: depot ? 0 : 1,
        isDepot: depot,
        legDistanceMeters: km * 1000,
        legDurationSeconds: seconds,
        legDurationInTrafficSeconds: seconds,
        pathFromPrevious: const [LatLng(-33.9, 18.5), LatLng(-33.91, 18.51)],
        cumulativeDistanceMeters: km * 1000,
        cumulativeDrivingSeconds: seconds,
      );
    }

    PlannedRoute route(List<PlannedStop> stops) => PlannedRoute(
          stops: stops,
          totalDistanceMeters: 12500,
          totalDrivingSeconds: 2700,
          totalServiceSeconds: 900,
          usedRealRoads: true,
          algorithm: RouteAlgorithm.twoOpt,
          options: const RoutePlanOptions(),
          plannedAt: DateTime(2026, 8, 18),
        );

    test('the depot is not counted as a delivery', () {
      final r = route([stop('yard', depot: true), stop('a'), stop('b')]);

      expect(r.stops, hasLength(3));
      expect(r.deliveryStops, hasLength(2));
    });

    test('elapsed time adds service time to driving time', () {
      final r = route([stop('a'), stop('b')]);

      expect(r.totalDrivingSeconds, 2700);
      expect(r.totalElapsedSeconds, 3600);
      expect(r.totalElapsedFormatted, '1h');
      expect(r.totalDistanceFormatted, '12.5 km');
    });

    test('the full path stitches every leg together', () {
      final r = route([stop('a'), stop('b'), stop('c')]);
      expect(r.fullPath, hasLength(6));
    });

    test('converting to the cached shape yields one segment per leg', () {
      final r = route([stop('a'), stop('b'), stop('c')]);
      final cached = r.toSuburbRouteData('pinelands');

      expect(cached.segments, hasLength(2));
      expect(cached.suburb, 'pinelands');
      expect(cached.algorithm, 'twoOpt_actual');
    });

    test('an estimated route is labelled as such in the cache', () {
      final r = PlannedRoute(
        stops: [stop('a'), stop('b')],
        totalDistanceMeters: 100,
        totalDrivingSeconds: 60,
        totalServiceSeconds: 0,
        usedRealRoads: false,
        algorithm: RouteAlgorithm.nearestNeighbour,
        options: const RoutePlanOptions(),
        plannedAt: DateTime(2026, 8, 18),
      );

      expect(r.toSuburbRouteData('x').algorithm, 'nearestNeighbour_estimated');
    });
  });

  group('plan options', () {
    test('copyWith leaves untouched fields alone', () {
      const original = RoutePlanOptions(
        returnToStart: true,
        serviceTimePerStop: Duration(minutes: 8),
        algorithm: RouteAlgorithm.twoOpt,
      );

      final updated = original.copyWith(algorithm: RouteAlgorithm.keepOrder);

      expect(updated.algorithm, RouteAlgorithm.keepOrder);
      expect(updated.returnToStart, isTrue);
      expect(updated.serviceTimePerStop, const Duration(minutes: 8));
    });

    test('copyWith can clear a nullable field explicitly', () {
      final original = RoutePlanOptions(departAt: DateTime(2026, 8, 18, 8));

      expect(original.copyWith().departAt, isNotNull);
      expect(original.copyWith(departAt: null).departAt, isNull);
    });
  });

  group('polyline handling', () {
    test('decodes the documented Google example', () {
      final points = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');

      expect(points, hasLength(3));
      expect(points.first.latitude, closeTo(38.5, 0.0001));
      expect(points.first.longitude, closeTo(-120.2, 0.0001));
      expect(points.last.latitude, closeTo(43.252, 0.0001));
      expect(points.last.longitude, closeTo(-126.453, 0.0001));
    });

    test('simplify drops points that sit on a straight line', () {
      final straight = [
        for (var i = 0; i <= 10; i++) LatLng(-33.9 + i * 0.001, 18.5),
      ];

      final simplified = simplifyPath(straight, toleranceMeters: 5);
      expect(simplified, hasLength(2));
      expect(simplified.first, straight.first);
      expect(simplified.last, straight.last);
    });

    test('simplify keeps a genuine corner', () {
      const corner = [
        LatLng(-33.900, 18.500),
        LatLng(-33.905, 18.500),
        LatLng(-33.905, 18.510),
      ];

      expect(simplifyPath(corner, toleranceMeters: 5), hasLength(3));
    });

    test('paths too short to simplify come back untouched', () {
      const two = [LatLng(-33.9, 18.5), LatLng(-33.91, 18.51)];
      expect(simplifyPath(two), two);
    });
  });

  group('address geocode state', () {
    Address base() => Address(
          id: 'a',
          streetAddress: '30 Riverside Road',
          suburb: 'Pinelands',
          city: 'Cape Town',
          postalCode: '7405',
          province: 'Western Cape',
          country: 'South Africa',
        );

    test('applying a geocode clears a previous failure', () {
      final failed = base().withGeocodeFailure('No match found');
      expect(failed.geocodingError, 'No match found');
      expect(failed.isGeocoded, isFalse);

      final fixed = failed.withGeocode(const GeocodeDetail(
        latitude: -33.94,
        longitude: 18.49,
        locationType: 'ROOFTOP',
        formattedAddress: '30 Riverside Rd, Pinelands, Cape Town, 7405',
      ));

      expect(fixed.isGeocoded, isTrue);
      expect(fixed.geocodingError, isNull);
      expect(fixed.latitude, -33.94);
      expect(fixed.precision, GeocodePrecision.exact);
    });

    test('copyWith preserves an error unless it is explicitly cleared', () {
      final failed = base().withGeocodeFailure('No match found');

      // The old copyWith wiped the error on any unrelated change.
      expect(failed.copyWith(routeIndex: 3).geocodingError, 'No match found');
      expect(failed.copyWith(geocodingError: null).geocodingError, isNull);
    });

    test('a partial match is flagged for review however precise it claims', () {
      final address = base().withGeocode(const GeocodeDetail(
        latitude: -33.94,
        longitude: 18.49,
        locationType: 'ROOFTOP',
        partialMatch: true,
      ));

      expect(address.precision, GeocodePrecision.low);
      expect(address.precision.needsReview, isTrue);
    });

    test('a hand-placed pin outranks anything Google returns', () {
      final address = base().copyWith(
        latitude: -33.94,
        longitude: 18.49,
        isGeocoded: true,
        locationType: GeocodePrecision.manualLocationType,
      );

      expect(address.precision, GeocodePrecision.manual);
      expect(address.precision.needsReview, isFalse);
    });

    test('a suburb centroid is flagged for review', () {
      final address = base().withGeocode(const GeocodeDetail(
        latitude: -33.94,
        longitude: 18.49,
        locationType: 'APPROXIMATE',
      ));

      expect(address.precision, GeocodePrecision.low);
      expect(address.precision.needsReview, isTrue);
    });

    test('addresses geocoded before precision existed read as unknown', () {
      final legacy = Address.fromMap('pinelands-0', {
        'streetAddress': '30 Riverside Road',
        'suburb': 'Pinelands',
        'latitude': -33.94,
        'longitude': 18.49,
        'isGeocoded': true,
      });

      expect(legacy.isGeocoded, isTrue);
      expect(legacy.precision, GeocodePrecision.unknown);
      expect(legacy.partialMatch, isFalse);
    });

    test('round-trips through the Firestore map', () {
      final address = base()
          .withGeocode(const GeocodeDetail(
            latitude: -33.94,
            longitude: 18.49,
            locationType: 'RANGE_INTERPOLATED',
            placeId: 'abc123',
            formattedAddress: '30 Riverside Rd',
          ))
          .copyWith(notes: 'Gate code 4711', routeIndex: 2);

      final restored = Address.fromMap('a', address.toMap());

      expect(restored.latitude, address.latitude);
      expect(restored.locationType, 'RANGE_INTERPOLATED');
      expect(restored.placeId, 'abc123');
      expect(restored.notes, 'Gate code 4711');
      expect(restored.routeIndex, 2);
      expect(restored.precision, GeocodePrecision.interpolated);
    });
  });

  group('restoring a cached route', () {
    Address at(String id, double lat) => Address(
          id: id,
          streetAddress: id,
          suburb: 'Pinelands',
          city: 'Cape Town',
          postalCode: '',
          province: '',
          country: '',
          latitude: lat,
          longitude: 18.5,
          isGeocoded: true,
        );

    RouteSegmentData segment(String from, String to, double metres) =>
        RouteSegmentData(
          fromAddressId: from,
          toAddressId: to,
          distanceMeters: metres,
          durationSeconds: (metres / 10).round(),
          polylinePoints: const [LatLng(-33.9, 18.5), LatLng(-33.91, 18.5)],
        );

    SuburbRouteData cache(List<RouteSegmentData> segments,
            {String algorithm = 'googleOptimized_actual'}) =>
        SuburbRouteData(
          suburb: 'pinelands',
          algorithm: algorithm,
          optimizedAt: DateTime(2026, 8, 18, 7),
          segments: segments,
          totalDistanceMeters:
              segments.fold(0, (sum, s) => sum + s.distanceMeters),
          totalDurationSeconds:
              segments.fold(0, (sum, s) => sum + s.durationSeconds),
        );

    test('rebuilds the run with cumulative distances', () {
      final ordered = [at('a', -33.90), at('b', -33.91), at('c', -33.92)];
      final restored = PlannedRoute.fromCache(
        ordered,
        cache([segment('a', 'b', 1000), segment('b', 'c', 2000)]),
      )!;

      expect(restored.stops, hasLength(3));
      expect(restored.stops[0].legDistanceMeters, 0);
      expect(restored.stops[1].legDistanceMeters, 1000);
      expect(restored.stops[2].cumulativeDistanceMeters, 3000);
      expect(restored.totalDistanceMeters, 3000);
      expect(restored.usedRealRoads, isTrue);
      expect(restored.algorithm, RouteAlgorithm.googleOptimized);
    });

    test('an extra trailing segment is read as the leg home', () {
      final ordered = [at('a', -33.90), at('b', -33.91), at('c', -33.92)];
      final restored = PlannedRoute.fromCache(
        ordered,
        cache([
          segment('a', 'b', 1000),
          segment('b', 'c', 2000),
          segment('c', 'a', 2500),
        ]),
      )!;

      expect(restored.returnLeg, isNotNull);
      expect(restored.returnLeg!.address.id, 'a');
      expect(restored.totalDistanceMeters, 5500);
      expect(restored.options.returnToStart, isTrue);
    });

    test('an estimated cache is reported as estimated', () {
      final restored = PlannedRoute.fromCache(
        [at('a', -33.90), at('b', -33.91)],
        cache([segment('a', 'b', 1000)],
            algorithm: 'nearestNeighbour_estimated'),
      )!;

      expect(restored.usedRealRoads, isFalse);
      expect(restored.algorithm, RouteAlgorithm.nearestNeighbour);
    });

    test('a cache that no longer matches keeps the order, drops the legs', () {
      // Three stops need two legs; a cache holding one has drifted. The
      // measurements are discarded, but the delivery order is not — it is
      // the part a driver may already be working from.
      final restored = PlannedRoute.fromCache(
        [at('a', -33.90), at('b', -33.91), at('c', -33.92)],
        cache([segment('a', 'b', 1000)]),
      )!;

      expect(restored.stops.map((s) => s.address.id), ['a', 'b', 'c']);
      expect(restored.needsRemeasure, isTrue);
      expect(restored.totalDistanceMeters, 0);
    });

    test('fewer than two stops has no route to restore', () {
      expect(PlannedRoute.fromCache([at('a', -33.9)], cache([])), isNull);
    });

    test('a depot leading the list is not counted as a delivery', () {
      final depot = at('yard', -33.89);
      final restored = PlannedRoute.fromCache(
        [depot, at('a', -33.90), at('b', -33.91)],
        cache([segment('yard', 'a', 500), segment('a', 'b', 1000)]),
        depot: depot,
      )!;

      expect(restored.stops.first.isDepot, isTrue);
      expect(restored.stops.first.sequence, 0);
      expect(restored.deliveryStops, hasLength(2));
      expect(restored.stops[1].sequence, 1);
    });

    test('a planned route survives a round trip through the cache', () {
      final ordered = [at('a', -33.90), at('b', -33.91), at('c', -33.92)];
      final original = PlannedRoute.fromCache(
        ordered,
        cache([segment('a', 'b', 1400), segment('b', 'c', 2100)]),
      )!;

      final restored = PlannedRoute.fromCache(
          ordered, original.toSuburbRouteData('pinelands'))!;

      expect(restored.totalDistanceMeters, original.totalDistanceMeters);
      expect(restored.stops.map((s) => s.address.id),
          original.stops.map((s) => s.address.id));
      expect(restored.usedRealRoads, original.usedRealRoads);
      expect(restored.algorithm, original.algorithm);
    });
  });

  group('a saved delivery order survives', () {
    Address at(String id, double lat, {int? routeIndex}) => Address(
          id: id,
          streetAddress: id,
          suburb: 'Pinelands',
          city: 'Cape Town',
          postalCode: '',
          province: '',
          country: '',
          latitude: lat,
          longitude: 18.5,
          isGeocoded: true,
          routeIndex: routeIndex,
        );

    RouteSegmentData seg(String from, String to, double metres) =>
        RouteSegmentData(
          fromAddressId: from,
          toAddressId: to,
          distanceMeters: metres,
          durationSeconds: (metres / 10).round(),
          polylinePoints: const [LatLng(-33.9, 18.5), LatLng(-33.91, 18.5)],
        );

    SuburbRouteData cache(List<RouteSegmentData> segments) => SuburbRouteData(
          suburb: 'pinelands',
          algorithm: 'googleOptimized_actual',
          optimizedAt: DateTime(2026, 8, 18, 7),
          segments: segments,
          totalDistanceMeters:
              segments.fold(0, (sum, s) => sum + s.distanceMeters),
          totalDurationSeconds:
              segments.fold(0, (sum, s) => sum + s.durationSeconds),
        );

    test('stale distances do not take the order down with them', () {
      // A stop was deleted since the run was measured, so the legs no
      // longer describe the list. The order must still come back — losing
      // it would force a re-optimise and renumber the whole run.
      final ordered = [at('a', -33.90), at('b', -33.91), at('c', -33.92)];
      final restored = PlannedRoute.fromCache(
          ordered,
          cache([
            seg('a', 'b', 1000),
            seg('b', 'c', 2000),
            seg('c', 'd', 1500),
            seg('d', 'e', 900),
          ]))!;

      expect(restored.stops.map((s) => s.address.id), ['a', 'b', 'c']);
      expect(restored.needsRemeasure, isTrue);
      expect(restored.usedRealRoads, isFalse);
      expect(restored.warning, contains('re-measure'));
    });

    test('the order comes back even with no cached measurements at all', () {
      final ordered = [at('a', -33.90), at('b', -33.91)];
      final restored = PlannedRoute.fromCache(ordered, null)!;

      expect(restored.stops.map((s) => s.address.id), ['a', 'b']);
      expect(restored.needsRemeasure, isTrue);
    });

    test('a deleted stop is not mistaken for a round trip', () {
      // Three stops and three legs used to satisfy the old count check and
      // invent a leg home that was never planned.
      final ordered = [at('a', -33.90), at('b', -33.91), at('c', -33.92)];
      final restored = PlannedRoute.fromCache(
          ordered,
          cache([
            seg('a', 'b', 1000),
            seg('b', 'c', 2000),
            seg('c', 'x', 3000),
          ]))!;

      expect(restored.returnLeg, isNull);
      expect(restored.needsRemeasure, isTrue);
    });

    test('a genuine round trip is still recognised by its closing leg', () {
      final ordered = [at('a', -33.90), at('b', -33.91), at('c', -33.92)];
      final restored = PlannedRoute.fromCache(
          ordered,
          cache([
            seg('a', 'b', 1000),
            seg('b', 'c', 2000),
            seg('c', 'a', 2500),
          ]))!;

      expect(restored.returnLeg, isNotNull);
      expect(restored.needsRemeasure, isFalse);
      expect(restored.totalDistanceMeters, 5500);
    });

    test('matching measurements restore fully, with no re-measure needed', () {
      final ordered = [at('a', -33.90), at('b', -33.91), at('c', -33.92)];
      final restored = PlannedRoute.fromCache(
        ordered,
        cache([seg('a', 'b', 1000), seg('b', 'c', 2000)]),
      )!;

      expect(restored.needsRemeasure, isFalse);
      expect(restored.usedRealRoads, isTrue);
      expect(restored.totalDistanceMeters, 3000);
      expect(restored.warning, isNull);
    });

    test('routeIndex is what carries the order, not array position', () {
      // Firestore hands the addresses back in storage order; the run is
      // whatever routeIndex says, so a saved order is immune to the array
      // being rewritten underneath it.
      final stored = [
        at('c', -33.92, routeIndex: 0),
        at('a', -33.90, routeIndex: 2),
        at('b', -33.91, routeIndex: 1),
      ];

      final ordered = stored.where((a) => a.routeIndex != null).toList()
        ..sort((x, y) => x.routeIndex!.compareTo(y.routeIndex!));

      expect(ordered.map((a) => a.id), ['c', 'b', 'a']);

      final restored = PlannedRoute.fromCache(ordered, null)!;
      expect(restored.stops.map((s) => s.address.id), ['c', 'b', 'a']);
      expect(restored.stops.map((s) => s.sequence), [1, 2, 3]);
    });

    test('a fully measured run reports nothing to re-measure', () {
      final ordered = [at('a', -33.90), at('b', -33.91)];
      final restored =
          PlannedRoute.fromCache(ordered, cache([seg('a', 'b', 1200)]))!;

      expect(restored.needsRemeasure, isFalse);
      expect(restored.stops[1].legDistanceMeters, 1200);
    });
  });
}
