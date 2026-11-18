// The route map for each promoter on the client report. The street map comes
// from Google and the route is drawn over it in the PDF, so the two only line
// up if the frame's Web Mercator maths matches Google's exactly.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/services/te_report_maps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';

TEPromoterDay _day(List<List<Wpt>> files, {List<Wpt> flyers = const []}) =>
    TEPromoterDay(
      distributor: Distributor(id: 'd1', name: 'Nolan', index: 0),
      date: DateTime(2026, 5, 11),
      tracks: [
        for (final pts in files) Trk(trksegs: [Trkseg(trkpts: pts)]),
      ],
      waypoints: flyers,
      sourcePaths: const [],
    );

Wpt _pt(double lat, double lon, [int minute = 0]) => Wpt(
    lat: lat, lon: lon, time: DateTime.utc(2026, 5, 11, 6).add(Duration(minutes: minute)));

void main() {
  test('the frame centre is the image centre, and zoom 0 matches Google', () {
    final frame = teMapFrame(const [(0.0, 0.0)])!;
    final (x, y) = frame.toPixel(0, 0);
    expect(x, closeTo(teMapWidth / 2, 1e-6));
    expect(y, closeTo(teMapHeight / 2, 1e-6));

    // Google's world at zoom 0 is 256 px: the antimeridian sits 128 px left
    // of a map centred on 0,0.
    const world = TEMapFrame(centreX: 0.5, centreY: 0.5, zoom: 0);
    expect(world.toPixel(0, -180).$1, closeTo(teMapWidth / 2 - 128, 1e-6));
    expect(world.toPixel(0, 180).$1, closeTo(teMapWidth / 2 + 128, 1e-6));
  });

  test('fits the whole route inside the map with a margin, as close as it can',
      () {
    const route = TEMapRoute(segments: [
      [(-33.92, 18.42), (-33.93, 18.44)],
    ], flyers: [
      (-33.925, 18.43),
    ]);
    final frame = teMapFrame(route.allPoints)!;
    for (final p in route.allPoints) {
      final (x, y) = frame.toPixel(p.$1, p.$2);
      expect(x, inInclusiveRange(teMapWidth * 0.07, teMapWidth * 0.93));
      expect(y, inInclusiveRange(teMapHeight * 0.07, teMapHeight * 0.93));
    }
    // One zoom closer would no longer fit.
    final closer = TEMapFrame(
        centreX: frame.centreX, centreY: frame.centreY, zoom: frame.zoom + 1);
    final a = closer.toPixel(-33.92, 18.42), b = closer.toPixel(-33.93, 18.44);
    expect(
        (b.$1 - a.$1).abs() > teMapWidth * 0.84 ||
            (b.$2 - a.$2).abs() > teMapHeight * 0.84,
        isTrue);
  });

  test('nothing to show gives no map', () {
    expect(teReportMaps(teMapRoute(_day(const []))), isEmpty);
  });

  test('two rounds merge in time order and the route breaks at a jump', () {
    // The afternoon file is listed first; a 1 km jump splits the morning.
    final day = _day([
      [_pt(-33.9300, 18.4300, 300), _pt(-33.9301, 18.4301, 301)],
      [
        _pt(-33.9200, 18.4200, 0),
        _pt(-33.9201, 18.4201, 1),
        _pt(-33.9290, 18.4200, 2), // ~1 km south
        _pt(-33.9291, 18.4201, 3),
      ],
    ], flyers: [
      _pt(-33.9200, 18.4200),
      Wpt(), // no position: left off the map
    ]);
    final route = teMapRoute(day);
    expect(route.segments, hasLength(3));
    expect(route.segments.first.first, (-33.9200, 18.4200));
    expect(route.segments.last.last, (-33.9301, 18.4301));
    expect(route.flyers, [(-33.9200, 18.4200)]);
  });

  group('positions', () {
    // ~1 m in degrees at Cape Town; a corner's flyers within a few metres.
    const m = 1 / 93000;
    List<(double, double)> corner(double lat, double lon, int n) =>
        [for (var i = 0; i < n; i++) (lat + (i % 5) * 3 * m, lon + i * 2 * m)];

    test('two corners far apart get a zoomed-in map each, busiest first', () {
      final route = TEMapRoute(segments: const [], flyers: [
        ...corner(-33.9200, 18.4200, 40),
        ...corner(-33.9400, 18.4500, 90), // ~3.5 km away
        (-33.9300, 18.4350), // a stray press while walking between them
      ]);
      final positions = teMapPositions(route);
      expect([for (final p in positions) p.flyers.length], [90, 40]);

      final maps = teReportMaps(route);
      expect(maps, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(maps[i].frame.zoom, 17, reason: 'zoomed right in on a corner');
        final (x, y) = maps[i].frame.toPixel(
            positions[i].centre.$1, positions[i].centre.$2);
        expect(x, closeTo(teMapWidth / 2, 2));
        expect(y, closeTo(teMapHeight / 2, 2));
      }
    });

    test('flyers along one block are a single position', () {
      final route = TEMapRoute(segments: const [], flyers: [
        ...corner(-33.9200, 18.4200, 30),
        ...corner(-33.9205, 18.4215, 30), // ~150 m along the road
      ]);
      expect(teMapPositions(route), hasLength(1));
      expect(teReportMaps(route), hasLength(1));
    });

    test('at most two maps, however many positions', () {
      final route = TEMapRoute(segments: const [], flyers: [
        ...corner(-33.90, 18.40, 30),
        ...corner(-33.92, 18.42, 30),
        ...corner(-33.94, 18.44, 30),
      ]);
      expect(teMapPositions(route), hasLength(3));
      expect(teReportMaps(route), hasLength(teMaxMapsPerPromoter));
    });

    test('a day without flyers gets one map of the whole route', () {
      const route = TEMapRoute(segments: [
        [(-33.92, 18.42), (-33.93, 18.43)],
      ], flyers: []);
      final maps = teReportMaps(route);
      expect(maps, hasLength(1));
      expect(maps.single.position, isNull);
    });
  });

  test('the street map URL asks for a JPEG of exactly this frame', () {
    const frame = TEMapFrame(centreX: 0.5, centreY: 0.5, zoom: 15);
    final url = Uri.parse(frame.staticUrl);
    expect(url.path, '/maps/api/staticmap');
    expect(url.queryParameters['zoom'], '15');
    expect(url.queryParameters['size'], '${teMapWidth}x$teMapHeight');
    expect(url.queryParameters['format'], 'jpg');
    expect(url.queryParameters['visible'], isNull);
  });
}
