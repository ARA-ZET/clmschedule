// Reading intersection names out of an Overpass answer. The fixture is a real
// response for 100 m around a corner in Bellville, Cape Town: Voortrekker Rd
// runs past it and Teddington Rd meets Vrede St about 57 m away.
import 'dart:convert';
import 'dart:io';

import 'package:clmschedule/track_editor/services/te_place_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, dynamic> bellville;

  setUpAll(() async {
    bellville = json.decode(
      await File('test/fixtures/overpass_bellville_vrede_st.json')
          .readAsString(),
    ) as Map<String, dynamic>;
  });

  test('names the nearest junction of two different roads, shortened', () {
    expect(intersectionNear(bellville, -33.9006, 18.6293),
        'Teddington Rd & Vrede St');
  });

  test('nothing in range gives no name', () {
    expect(intersectionNear(bellville, -33.95, 18.70), isNull);
  });

  test('the bigger road leads', () {
    Map<String, dynamic> way(
            int id, String name, String highway, List<int> nodes) =>
        {
          'type': 'way',
          'id': id,
          'nodes': nodes,
          'tags': {'name': name, 'highway': highway}
        };
    final answer = {
      'elements': [
        way(1, 'Alpha Street', 'residential', [10, 11]),
        way(2, 'Main Road', 'primary', [11, 12]),
        // A footpath meeting at the same node is not a road a client means.
        way(3, 'Aardvark Path', 'footway', [11, 13]),
        {'type': 'node', 'id': 10, 'lat': -33.9000, 'lon': 18.6000},
        {'type': 'node', 'id': 11, 'lat': -33.9001, 'lon': 18.6001},
        {'type': 'node', 'id': 12, 'lat': -33.9002, 'lon': 18.6002},
        {'type': 'node', 'id': 13, 'lat': -33.9003, 'lon': 18.6003},
      ],
    };
    expect(intersectionNear(answer, -33.9001, 18.6001), 'Main Rd & Alpha St');
  });

  test('without a junction nearby, a close road is named on its own', () {
    final answer = {
      'elements': [
        {
          'type': 'way',
          'id': 1,
          'nodes': [10, 11],
          'tags': {'name': 'Durban Road', 'highway': 'secondary'}
        },
        {'type': 'node', 'id': 10, 'lat': -33.9000, 'lon': 18.6000},
        {'type': 'node', 'id': 11, 'lat': -33.9010, 'lon': 18.6000},
      ],
    };
    expect(intersectionNear(answer, -33.9002, 18.6001), 'Durban Rd');
  });

  test('keys agree to 4 decimals', () {
    expect(tePlaceKey(-33.900612, 18.629349), tePlaceKey(-33.90064, 18.62931));
  });
}
