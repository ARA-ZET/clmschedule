// Caching rules for the office (depot) coordinates.
//
// The office is geocoded once per address and reused forever after; a stale
// cache would silently route every driver from the wrong start point, while a
// cache that never counts as valid would send the user back to the Task
// manager before every ETA run. Both failures live in these pure predicates.
import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/dropsheet_task_type_config.dart';

void main() {
  group('DepotConfig geocode cache', () {
    test('coordinates count as current for the address they came from', () {
      const depot = DepotConfig(
        address: '27 7th Ave, Kensington, Cape Town',
        lat: -33.93,
        lng: 18.53,
        geocodedAddress: '27 7th Ave, Kensington, Cape Town',
      );
      expect(depot.isGeocoded, isTrue);
      expect(depot.needsGeocoding, isFalse);
    });

    test('whitespace and casing differences do not invalidate the cache', () {
      const depot = DepotConfig(
        address: '  27 7th Ave,   Kensington, Cape Town ',
        lat: -33.93,
        lng: 18.53,
        geocodedAddress: '27 7th ave, Kensington, Cape Town',
      );
      expect(depot.needsGeocoding, isFalse);
    });

    test('a changed address makes the stored coordinates stale', () {
      const depot = DepotConfig(
        address: '1 Long Street, Cape Town',
        lat: -33.93,
        lng: 18.53,
        geocodedAddress: '27 7th Ave, Kensington, Cape Town',
      );
      expect(depot.isGeocoded, isFalse);
      expect(depot.needsGeocoding, isTrue);
    });

    test('coordinates without a recorded address are not trusted', () {
      const depot = DepotConfig(
        address: '27 7th Ave, Kensington, Cape Town',
        lat: -33.93,
        lng: 18.53,
      );
      expect(depot.needsGeocoding, isTrue);
    });

    test('an empty address is never geocoded', () {
      const depot = DepotConfig(address: '   ');
      expect(depot.needsGeocoding, isFalse);
    });

    test('legacy configs adopt their coordinates instead of re-geocoding', () {
      // Written before `geocodedAddress` existed: lat/lng belong to `address`.
      final depot = DepotConfig.fromMap({
        'address': '27 7th Ave, Kensington, Cape Town',
        'lat': -33.93,
        'lng': 18.53,
        'startTime': '07:30',
      });
      expect(depot.geocodedAddress, '27 7th Ave, Kensington, Cape Town');
      expect(depot.needsGeocoding, isFalse);
    });

    test('a legacy config with no coordinates still needs geocoding', () {
      final depot = DepotConfig.fromMap({
        'address': '27 7th Ave, Kensington, Cape Town',
        'startTime': '07:30',
      });
      expect(depot.needsGeocoding, isTrue);
    });

    test('the cache survives a round-trip through Firestore mapping', () {
      const depot = DepotConfig(
        address: '27 7th Ave, Kensington, Cape Town',
        lat: -33.93,
        lng: 18.53,
        geocodedAddress: '27 7th Ave, Kensington, Cape Town',
      );
      final restored = DepotConfig.fromMap(depot.toMap());
      expect(restored.needsGeocoding, isFalse);
      expect(restored.lat, -33.93);
      expect(restored.lng, 18.53);
    });

    test('value equality distinguishes a geocoded config from a bare one', () {
      // The Task manager re-syncs its working copy by comparing configs, so
      // identity equality here would make it re-sync on every rebuild and
      // never settle.
      const bare = DepotConfig(address: '27 7th Ave, Kensington, Cape Town');
      const geocoded = DepotConfig(
        address: '27 7th Ave, Kensington, Cape Town',
        lat: -33.93,
        lng: 18.53,
        geocodedAddress: '27 7th Ave, Kensington, Cape Town',
      );
      expect(bare == geocoded, isFalse);
      expect(geocoded == DepotConfig.fromMap(geocoded.toMap()), isTrue);
      expect(
        geocoded.hashCode,
        DepotConfig.fromMap(geocoded.toMap()).hashCode,
      );
    });

    test('editing only the address invalidates the cache', () {
      const depot = DepotConfig(
        address: '27 7th Ave, Kensington, Cape Town',
        lat: -33.93,
        lng: 18.53,
        geocodedAddress: '27 7th Ave, Kensington, Cape Town',
      );
      final edited = depot.copyWith(address: '1 Long Street, Cape Town');
      expect(edited.needsGeocoding, isTrue);
      // Old coordinates are kept as a fallback until the new ones arrive.
      expect(edited.hasCoordinates, isTrue);
    });
  });
}
