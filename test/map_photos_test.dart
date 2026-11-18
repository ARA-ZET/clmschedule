import 'dart:convert';
import 'dart:typed_data';

import 'package:clmschedule/shareable_maps/providers/shareable_map_provider.dart'
    show parseCompiledWaypointsForTest;
import 'package:clmschedule/shareable_maps/services/map_photos.dart';
import 'package:clmschedule/shareable_maps/widgets/map_photo_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A waypoint on a poster map finds the photo taken there, by the waypoint's
/// name and the distributor and day its track file names.

MapPhoto photo(String who, String what, String date, String time,
        {String id = ''}) =>
    MapPhoto(
      id: id.isEmpty ? '$who-$what-$date-$time' : id,
      who: who,
      what: what,
      date: date,
      time: time,
      thumbUrl: 'https://x/thumb',
      fullUrl: 'https://x/img',
      downloadUrl: 'https://x/img?download=1',
    );

const petrosFile =
    'Waypoints   22 Oct 2026   Petros   Chand   Claremont   41 fulltrack.gpx';

void main() {
  group('matchWaypointPhoto', () {
    test('name and distributor find the photo', () {
      final photos = [
        photo('Petros', 'Poster 501', '2026-10-22', '12:37:26'),
        photo('Petros', 'Poster 502', '2026-10-22', '12:40:00'),
      ];
      expect(matchWaypointPhoto('Poster 501', petrosFile, photos)?.what,
          'Poster 501');
    });

    test('another distributor\'s "Poster 3" is not this one', () {
      final photos = [
        photo('Francis', 'Poster 3', '2026-10-22', '10:00:00', id: 'francis'),
        photo('Petros', 'Poster 3', '2026-10-22', '11:00:00', id: 'petros'),
      ];
      expect(matchWaypointPhoto('Poster 3', petrosFile, photos)?.id, 'petros');
    });

    test('numbers restart each session: the track\'s day decides', () {
      final photos = [
        photo('Petros', 'Poster 3', '2026-10-21', '09:00:00', id: 'yesterday'),
        photo('Petros', 'Poster 3', '2026-10-22', '09:00:00', id: 'today'),
      ];
      expect(matchWaypointPhoto('Poster 3', petrosFile, photos)?.id, 'today');
    });

    test('a photo taken again: the later one', () {
      final photos = [
        photo('Petros', 'Poster 7', '2026-10-22', '09:00:00', id: 'first'),
        photo('Petros', 'Poster 7', '2026-10-22', '09:02:10', id: 'retake'),
      ];
      expect(matchWaypointPhoto('Poster 7', petrosFile, photos)?.id, 'retake');
    });

    test('no photo for the waypoint, or no name: nothing', () {
      final photos = [photo('Petros', 'Poster 1', '2026-10-22', '09:00:00')];
      expect(matchWaypointPhoto('Poster 9', petrosFile, photos), isNull);
      expect(matchWaypointPhoto('', petrosFile, photos), isNull);
      // A free-form phone photo name never matches a waypoint.
      expect(
          matchWaypointPhoto('Poster 1', petrosFile,
              [photo('', 'IMG_2041', '', '')]),
          isNull);
    });

    test('a file naming no distributor still matches on name and day', () {
      final photos = [
        photo('Petros', 'Delivery point 12', '2026-10-22', '09:00:00')
      ];
      expect(
          matchWaypointPhoto('Delivery point 12', 'claremont.gpx', photos)?.what,
          'Delivery point 12');
    });
  });

  test('the index is read from the photos host, as absolute URLs', () async {
    late Uri asked;
    final client = MockClient((req) async {
      asked = req.url;
      return http.Response(
          jsonEncode({
            'photos': [
              {
                'id': 'abc',
                'who': 'Petros',
                'what': 'Poster 501',
                'date': '2026-10-22',
                'time': '12:37:26',
                'thumb': '/photos/POST1/thumb/abc',
                'src': '/photos/POST1/img/abc',
                'download': '/photos/POST1/img/abc?download=1',
              }
            ]
          }),
          200);
    });
    final index = await MapPhotosService(client: client).load('POST1');
    expect(asked.path, '/photos/POST1/index.json');
    final p = index.forWaypoint('Poster 501', petrosFile)!;
    expect(p.thumbUrl, startsWith('https://'));
    expect(p.thumbUrl, endsWith('/photos/POST1/thumb/abc'));
    expect(p.fullUrl, endsWith('/photos/POST1/img/abc'));
    // Never a Storage address.
    expect(p.fullUrl, isNot(contains('firebasestorage')));
  });

  test('an unreadable index is just no photos', () async {
    final client = MockClient((_) async => http.Response('nope', 503));
    expect((await MapPhotosService(client: client).load('X')).photos, isEmpty);
  });

  test('compiled waypoints keep the file each came from', () {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'sourceFiles': [petrosFile, 'Waypoints   21 Oct 2026   Francis   Chand   3 fulltrack.gpx'],
      'waypoints': [
        {'name': 'Poster 501', 'lat': -33.97, 'lon': 18.46, 'fi': 0},
        {'name': 'Poster 1', 'lat': -33.98, 'lon': 18.47, 'fi': 1},
        {'name': 'Old style', 'lat': -33.99, 'lon': 18.48, 'file': 'legacy.gpx'},
        {'name': 'No file', 'lat': -33.99, 'lon': 18.49},
      ],
    })));
    final parsed = parseCompiledWaypointsForTest(bytes);
    final byName = {for (final p in parsed.points) p.name: parsed.sources[p.id]};
    expect(byName['Poster 501'], petrosFile);
    expect(byName['Poster 1'], contains('Francis'));
    expect(byName['Old style'], 'legacy.gpx');
    expect(byName['No file'], isNull);
  });

  testWidgets('the viewer fits a phone and zooms with its buttons',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showMapPhotoViewer(
              context, photo('Petros', 'Poster 501', '2026-10-22', '12:37:26')),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Poster 501'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(find.text('150%'), findsOneWidget);
    await tester.tap(find.byTooltip('Zoom out'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Poster 501'), findsNothing);
  });
}
