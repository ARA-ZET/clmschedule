import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/address.dart';
import 'package:clmschedule/models/geocode_detail.dart';
import 'package:clmschedule/services/address_service_v2.dart';

void main() {
  group('Address.fromMap tolerates what production actually holds', () {
    test('reads a well-formed record', () {
      final address = Address.fromMap('pinelands-0', {
        'streetAddress': '30 Riverside Road',
        'suburb': 'Pinelands',
        'city': 'Cape Town',
        'postalCode': '7405',
        'latitude': -33.94,
        'longitude': 18.49,
        'isGeocoded': true,
      });

      expect(address.streetAddress, '30 Riverside Road');
      expect(address.latitude, -33.94);
      expect(address.isGeocoded, isTrue);
    });

    test('coordinates stored as strings still parse', () {
      // Older imports wrote these as text.
      final address = Address.fromMap('pinelands-0', {
        'streetAddress': '30 Riverside Road',
        'latitude': '-33.94',
        'longitude': '18.49',
        'isGeocoded': true,
      });

      expect(address.latitude, -33.94);
      expect(address.longitude, 18.49);
    });

    test('an unparseable coordinate is dropped, not thrown on', () {
      final address = Address.fromMap('pinelands-0', {
        'streetAddress': '30 Riverside Road',
        'latitude': 'not a number',
        'longitude': null,
      });

      expect(address.latitude, isNull);
      expect(address.longitude, isNull);
      expect(address.streetAddress, '30 Riverside Road');
    });

    test('a numeric postal code is read as text', () {
      final address = Address.fromMap('pinelands-0', {
        'streetAddress': '30 Riverside Road',
        'postalCode': 7405,
      });

      expect(address.postalCode, '7405');
    });

    test('a routeIndex stored as a string still orders the run', () {
      expect(
        Address.fromMap('a-0', {'routeIndex': '3'}).routeIndex,
        3,
      );
      expect(Address.fromMap('a-0', {'routeIndex': 3.0}).routeIndex, 3);
      expect(Address.fromMap('a-0', {'routeIndex': null}).routeIndex, isNull);
    });

    test('a truthy-looking non-bool does not fake a geocode', () {
      // Only a real `true` counts — a stray string must not make an
      // address with no coordinates look located.
      final address = Address.fromMap('a-0', {'isGeocoded': 'yes'});

      expect(address.isGeocoded, isFalse);
    });

    test('an empty record yields an empty address rather than throwing', () {
      final address = Address.fromMap('pinelands-0', {});

      expect(address.id, 'pinelands-0');
      expect(address.streetAddress, isEmpty);
      expect(address.isGeocoded, isFalse);
      expect(address.precision, GeocodePrecision.unknown);
      expect(address.notes, isNull);
    });

    test('an empty string field reads as absent, not as an empty note', () {
      final address = Address.fromMap('a-0', {'notes': '', 'placeId': ''});

      expect(address.notes, isNull);
      expect(address.placeId, isNull);
    });

    test('a record already carrying precision keeps it', () {
      final address = Address.fromMap('a-0', {
        'latitude': -33.94,
        'longitude': 18.49,
        'isGeocoded': true,
        'locationType': 'ROOFTOP',
      });

      expect(address.precision, GeocodePrecision.exact);
    });
  });

  group('one bad record must not blank the whole list', () {
    test('reads a normal suburb array', () {
      final addresses = AddressServiceV2.parseSuburbEntry('pinelands', [
        {'streetAddress': '30 Riverside Road', 'isGeocoded': true},
        {'streetAddress': '12 Central Square', 'isGeocoded': true},
      ]);

      expect(addresses, hasLength(2));
      expect(addresses.first.id, 'pinelands-0');
      expect(addresses.last.id, 'pinelands-1');
    });

    test('a non-list value is skipped instead of throwing', () {
      // A route cache or metadata blob stored under a plain key used to
      // throw here and empty out the entire document.
      expect(
        AddressServiceV2.parseSuburbEntry('suburbs_routes', {'foo': 'bar'}),
        isEmpty,
      );
      expect(AddressServiceV2.parseSuburbEntry('version', 3), isEmpty);
      expect(AddressServiceV2.parseSuburbEntry('note', 'hello'), isEmpty);
      expect(AddressServiceV2.parseSuburbEntry('empty', null), isEmpty);
    });

    test('metadata keys are ignored', () {
      expect(
        AddressServiceV2.parseSuburbEntry('_meta', [
          {'streetAddress': 'should not appear'}
        ]),
        isEmpty,
      );
    });

    test('a rogue entry costs that entry only', () {
      final addresses = AddressServiceV2.parseSuburbEntry('pinelands', [
        {'streetAddress': '30 Riverside Road', 'isGeocoded': true},
        'not a map',
        null,
        42,
        {'streetAddress': '12 Central Square', 'isGeocoded': true},
      ]);

      expect(addresses, hasLength(2));
      expect(
        addresses.map((a) => a.streetAddress),
        ['30 Riverside Road', '12 Central Square'],
      );
    });

    test('ids stay tied to the stored slot, gaps included', () {
      // Ids are positional and are what updates and deletes address, so
      // a skipped entry must not renumber the ones after it.
      final addresses = AddressServiceV2.parseSuburbEntry('pinelands', [
        {'streetAddress': 'first'},
        'rogue',
        {'streetAddress': 'third'},
      ]);

      expect(addresses.map((a) => a.id), ['pinelands-0', 'pinelands-2']);
    });

    test('an empty array is simply an empty suburb', () {
      expect(AddressServiceV2.parseSuburbEntry('pinelands', []), isEmpty);
    });

    test('a suburb whose name contains a dash still round-trips its id', () {
      final addresses = AddressServiceV2.parseSuburbEntry('kuils-river', [
        {'streetAddress': '1 Main Road'},
      ]);

      expect(addresses.single.id, 'kuils-river-0');
    });
  });
}
