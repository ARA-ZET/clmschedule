import 'dart:convert';

import 'package:clmschedule/letterbox/services/letterbox_seed_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A `_compiled_waypoints.json` payload in the shape the GPX compiler writes.
Uint8List folderPayload(List<List<double>> latLons) {
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'version': 1,
    'waypointCount': latLons.length,
    'waypoints': [
      for (final p in latLons)
        {'name': '', 'desc': '', 'lat': p[0], 'lon': p[1]},
    ],
  })));
}

SeedSuburb square(String id, double minLat, double minLng, double size) {
  return SeedSuburb(
    id: id,
    name: id,
    polygon: [
      LatLng(minLat, minLng),
      LatLng(minLat, minLng + size),
      LatLng(minLat + size, minLng + size),
      LatLng(minLat + size, minLng),
    ],
  );
}

LetterboxSeedAllResult run(
  List<Uint8List> payloads,
  List<SeedSuburb> suburbs, {
  double snap = LetterboxSeedService.defaultSnapDegrees,
}) {
  return seedAllFromPayloads(SeedAllInput(payloads, suburbs, snap));
}

void main() {
  group('seedAllFromPayloads', () {
    // Two adjacent 0.01-degree squares, west and east of lng 18.43.
    final west = square('west', -33.93, 18.42, 0.01);
    final east = square('east', -33.93, 18.43, 0.01);

    test('assigns each drop to the suburb that contains it', () {
      final result = run([
        folderPayload([
          [-33.925, 18.425], // west
          [-33.926, 18.426], // west
          [-33.925, 18.435], // east
        ])
      ], [
        west,
        east
      ]);

      expect(result.bySuburb['west'], hasLength(2));
      expect(result.bySuburb['east'], hasLength(1));
      expect(result.insideDrops, 3);
      expect(result.unmatchedDrops, 0);
    });

    test('counts drops outside every suburb as unmatched, not as belonging',
        () {
      final result = run([
        folderPayload([
          [-33.925, 18.425], // west
          [-34.500, 19.900], // nowhere near
          [-33.000, 18.000], // nowhere near
        ])
      ], [
        west,
        east
      ]);

      expect(result.totalDrops, 3);
      expect(result.insideDrops, 1);
      expect(result.unmatchedDrops, 2);
      expect(result.bySuburb.keys, ['west']);
    });

    test('collapses repeat monthly visits to one candidate', () {
      // The same letterbox delivered to on four separate rounds, with GPS
      // jitter between them. A round is a folder, so these are four folders
      // each holding one drop — NOT one folder holding four, which would mean
      // four boxes at one entrance.
      final result = run([
        folderPayload([
          [-33.9250000, 18.4250000]
        ]),
        folderPayload([
          [-33.9250100, 18.4250100]
        ]),
        folderPayload([
          [-33.9250150, 18.4250050]
        ]),
        folderPayload([
          [-33.9250050, 18.4250120]
        ]),
      ], [
        west
      ]);

      expect(result.insideDrops, 4, reason: 'all four are real drops');
      expect(result.bySuburb['west'], hasLength(1),
          reason: 'but they are one physical letterbox, visited four times');
    });

    test('keeps genuinely distinct neighbouring letterboxes apart', () {
      // ~22 m apart — comfortably beyond the snap grid.
      final result = run([
        folderPayload([
          [-33.9250, 18.4250],
          [-33.9252, 18.4250],
          [-33.9254, 18.4250],
        ])
      ], [
        west
      ]);

      expect(result.bySuburb['west'], hasLength(3));
    });

    test('dedupes across folders, not just within one', () {
      // The same letterbox visited in two different months.
      final result = run([
        folderPayload([
          [-33.9250, 18.4250]
        ]),
        folderPayload([
          [-33.92500, 18.42501]
        ]),
      ], [
        west
      ]);

      expect(result.insideDrops, 2);
      expect(result.bySuburb['west'], hasLength(1));
    });

    test('a suburb with no drops gets no entry at all', () {
      final result = run([
        folderPayload([
          [-33.925, 18.425]
        ])
      ], [
        west,
        east
      ]);

      expect(result.bySuburb.containsKey('east'), isFalse);
    });

    test('skips malformed payloads without losing the good ones', () {
      final broken = Uint8List.fromList(utf8.encode('not json at all'));
      final result = run([
        broken,
        folderPayload([
          [-33.925, 18.425]
        ]),
      ], [
        west
      ]);

      expect(result.bySuburb['west'], hasLength(1));
    });

    test('ignores waypoints with missing or non-numeric coordinates', () {
      final payload = Uint8List.fromList(utf8.encode(jsonEncode({
        'waypoints': [
          {'lat': -33.925, 'lon': 18.425},
          {'lat': null, 'lon': 18.425},
          {'lon': 18.425},
          {'lat': -33.925},
          {},
        ],
      })));

      final result = run([payload], [west]);

      expect(result.totalDrops, 1);
      expect(result.bySuburb['west'], hasLength(1));
    });

    test('a block of flats survives seeding — the max-per-round rule', () {
      // One address with 8 boxes, delivered to on 3 separate rounds.
      // Collapsing to one address (the old rule) would report 1 letterbox;
      // summing every drop would report 24. The truth is 8.
      final entrance = [
        for (var i = 0; i < 8; i++) [-33.9250 + i * 0.000005, 18.4250],
      ];
      final result = run([
        folderPayload(entrance),
        folderPayload(entrance),
        folderPayload(entrance),
      ], [
        west
      ]);

      expect(result.insideDrops, 24, reason: '3 rounds x 8 boxes were logged');
      expect(result.bySuburb['west'], hasLength(8),
          reason: 'but the address holds 8 boxes, not 1 and not 24');
    });

    test('a house visited many times is still one letterbox', () {
      final house = [
        [-33.9260, 18.4260]
      ];
      final result = run([
        folderPayload(house),
        folderPayload(house),
        folderPayload(house),
        folderPayload(house),
      ], [
        west
      ]);

      expect(result.insideDrops, 4);
      expect(result.bySuburb['west'], hasLength(1));
    });

    test('the most complete round wins when rounds disagree', () {
      // A distributor who missed boxes on one round must not shrink the
      // address; the fullest observation is taken as the truth.
      final addr = 18.4270;
      final result = run([
        folderPayload([
          [-33.9270, addr],
          [-33.92701, addr],
        ]),
        folderPayload([
          [-33.9270, addr],
          [-33.92701, addr],
          [-33.92702, addr],
          [-33.92703, addr],
        ]),
        folderPayload([
          [-33.9270, addr],
        ]),
      ], [
        west
      ]);

      expect(result.bySuburb['west'], hasLength(4));
    });

    test('houses and a block in the same suburb both come through', () {
      final result = run([
        folderPayload([
          [-33.9250, 18.4250],
          [-33.92501, 18.4250],
          [-33.92502, 18.4250],
          [-33.9280, 18.4280],
          [-33.9290, 18.4290],
        ]),
      ], [
        west
      ]);

      expect(result.bySuburb['west'], hasLength(5),
          reason: '3 boxes at one entrance plus 2 separate houses');
    });

    test('scales without testing every waypoint against every suburb', () {
      // 400 suburbs in a grid, 2 000 drops. If the bounding-box grid were not
      // doing its job this would be 800 000 polygon tests and visibly slow.
      final suburbs = [
        for (var i = 0; i < 20; i++)
          for (var j = 0; j < 20; j++)
            square('s_${i}_$j', -34.0 + i * 0.01, 18.3 + j * 0.01, 0.01),
      ];
      final drops = [
        for (var n = 0; n < 2000; n++)
          [-34.0 + (n % 20) * 0.01 + 0.005, 18.3 + (n % 17) * 0.01 + 0.005],
      ];

      final sw = Stopwatch()..start();
      final result = run([folderPayload(drops)], suburbs);
      sw.stop();

      expect(result.unmatchedDrops, 0);
      expect(result.insideDrops, 2000);
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  _gpxTests();
}

/// A minimal GPX document with waypoints, a route and a track.
String gpxDoc({
  List<List<double>> waypoints = const [],
  List<List<double>> routePoints = const [],
  List<List<double>> trackPoints = const [],
}) {
  String pts(String tag, List<List<double>> ps) => ps
      .map((p) => '<$tag lat="${p[0]}" lon="${p[1]}"><name>x</name></$tag>')
      .join();
  return '<?xml version="1.0"?>'
      '<gpx version="1.1" creator="test">'
      '${pts('wpt', waypoints)}'
      '${routePoints.isEmpty ? '' : '<rte>${pts('rtept', routePoints)}</rte>'}'
      '${trackPoints.isEmpty ? '' : '<trk><trkseg>${pts('trkpt', trackPoints)}</trkseg></trk>'}'
      '</gpx>';
}

Uint8List gpxBytes(String xml) => Uint8List.fromList(utf8.encode(xml));

/// Payloads only, for the tests that just care about extraction.
List<Uint8List> scan(List<Uint8List> files, {bool includeTracks = false}) =>
    scanGpxBytes(GpxScanInput(files, includeTracks)).payloads;

void _gpxTests() {
  group('scanGpxBytes (device upload)', () {
    test('extracts waypoints from an uploaded GPX file', () {
      final payloads = scan([
        gpxBytes(gpxDoc(waypoints: [
          [-33.925, 18.425],
          [-33.926, 18.426],
        ]))
      ]);

      expect(payloads, hasLength(1));
      final decoded = jsonDecode(utf8.decode(payloads.first));
      expect(decoded['waypoints'], hasLength(2));
      expect(decoded['waypoints'][0]['lat'], closeTo(-33.925, 1e-9));
      expect(decoded['waypoints'][0]['lon'], closeTo(18.425, 1e-9));
    });

    test('includes route points, which some exports use for drops', () {
      final payloads = scan([
        gpxBytes(gpxDoc(routePoints: [
          [-33.925, 18.425]
        ]))
      ]);

      final decoded = jsonDecode(utf8.decode(payloads.first));
      expect(decoded['waypoints'], hasLength(1));
    });

    test('EXCLUDES track points — those are the walking path, not deliveries',
        () {
      // Including them would inflate every letterbox count with the route the
      // distributor walked between drops.
      final payloads = scan([
        gpxBytes(gpxDoc(
          waypoints: [
            [-33.925, 18.425]
          ],
          trackPoints: [
            [-33.9251, 18.4251],
            [-33.9252, 18.4252],
            [-33.9253, 18.4253],
          ],
        ))
      ]);

      final decoded = jsonDecode(utf8.decode(payloads.first));
      expect(decoded['waypoints'], hasLength(1),
          reason: 'only the wpt should survive, not the three trkpts');
    });

    test('a file with no waypoints yields no payload', () {
      final payloads = scan([
        gpxBytes(gpxDoc(trackPoints: [
          [-33.925, 18.425]
        ]))
      ]);
      expect(payloads, isEmpty);
    });

    test('one unreadable file does not abort the rest of the upload', () {
      final payloads = scan([
        gpxBytes('this is not gpx at all'),
        gpxBytes(gpxDoc(waypoints: [
          [-33.925, 18.425]
        ])),
      ]);

      expect(payloads, hasLength(1));
    });

    test('reports what it found, so "nothing happened" is explainable', () {
      final result = scanGpxBytes(GpxScanInput([
        gpxBytes(gpxDoc(
          waypoints: [
            [-33.925, 18.425]
          ],
          routePoints: [
            [-33.926, 18.426]
          ],
          trackPoints: [
            [-33.9271, 18.4271],
            [-33.9272, 18.4272],
          ],
        ))
      ], false));

      expect(result.waypointCount, 1);
      expect(result.routePointCount, 1);
      expect(result.trackPointCount, 2);
      expect(result.failedFiles, 0);
      expect(result.onlyTrackPoints, isFalse);
    });

    test('flags a tracks-only upload instead of silently doing nothing', () {
      // The exact case that produced an empty map with no explanation.
      final result = scanGpxBytes(GpxScanInput([
        gpxBytes(gpxDoc(trackPoints: [
          [-33.925, 18.425],
          [-33.926, 18.426],
        ]))
      ], false));

      expect(result.payloads, isEmpty);
      expect(result.trackPointCount, 2);
      expect(result.onlyTrackPoints, isTrue,
          reason: 'the UI keys its "include track points?" offer off this');
    });

    test('includeTrackPoints turns a tracks-only file into usable drops', () {
      final result = scanGpxBytes(GpxScanInput([
        gpxBytes(gpxDoc(trackPoints: [
          [-33.925, 18.425],
          [-33.926, 18.426],
        ]))
      ], true));

      expect(result.payloads, hasLength(1));
      final decoded = jsonDecode(utf8.decode(result.payloads.first));
      expect(decoded['waypoints'], hasLength(2));
    });

    test('counts files that failed to parse', () {
      final result = scanGpxBytes(GpxScanInput([
        gpxBytes('not gpx'),
        gpxBytes('also not gpx'),
      ], false));

      expect(result.failedFiles, 2);
      expect(result.payloads, isEmpty);
      expect(result.onlyTrackPoints, isFalse,
          reason: 'unreadable files must not be reported as a tracks problem');
    });

    test('device upload feeds the same classification as the cloud path', () {
      // The point of converting to the compiled shape: one code path.
      final west = square('west', -33.93, 18.42, 0.01);
      final payloads = scan([
        gpxBytes(gpxDoc(waypoints: [
          [-33.925, 18.425], // inside
          [-34.500, 19.900], // outside every suburb
        ]))
      ]);

      final result = run(payloads, [west]);

      expect(result.bySuburb['west'], hasLength(1));
      expect(result.unmatchedDrops, 1);
    });
  });
}
