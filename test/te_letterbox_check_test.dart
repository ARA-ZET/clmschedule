import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';

import 'package:clmschedule/letterbox/services/letterbox_count_service.dart';
import 'package:clmschedule/letterbox/utils/letterbox_clusters.dart';
import 'package:clmschedule/track_editor/models/styled_polygon.dart';
import 'package:clmschedule/track_editor/models/tab_item.dart';
import 'package:clmschedule/track_editor/providers/te_letterbox_check_provider.dart';
import 'package:clmschedule/track_editor/providers/te_mode_provider.dart';
import 'package:clmschedule/track_editor/providers/te_tabs_provider.dart';

/// A distributor's round is judged on these numbers, so the arithmetic behind
/// "short", "over" and the coverage percentage is worth pinning down — and so
/// is the refusal to judge at all when the expected count isn't trustworthy.
class _FakeCountService extends LetterboxCountService {
  _FakeCountService({
    required this.perPolygon,
    required this.unionResult,
  });

  final List<LetterboxCount> perPolygon;
  final LetterboxUnionResult unionResult;
  int countInEachCalls = 0;

  @override
  Future<List<LetterboxCount>> countInEach(List<List<LatLng>> polygons) async {
    countInEachCalls++;
    return perPolygon;
  }

  @override
  Future<LetterboxUnionResult> countUnion(
    List<List<LatLng>> polygons, {
    double gapToleranceMetres = LetterboxCountService.defaultGapToleranceMetres,
  }) async =>
      unionResult;
}

Wpt _wpt(double lat, double lon) => Wpt(lat: lat, lon: lon);

const _square = [
  LatLng(-34.0, 18.0),
  LatLng(-34.0, 18.1),
  LatLng(-33.9, 18.1),
  LatLng(-33.9, 18.0),
];

TETargetPolygon _target(String name, int drops, {List<LatLng>? points}) =>
    TETargetPolygon(
      name: name,
      waypoints: [for (var i = 0; i < drops; i++) _wpt(-33.95, 18.05)],
      points: points ?? _square,
    );

LetterboxCount _count(int n, {List<String> unverified = const []}) =>
    LetterboxCount(
      count: n,
      unverifiedSuburbs: unverified,
      breakdown: LetterboxBreakdown(
          total: n, houses: n, apartmentBoxes: 0, apartmentBlocks: 0),
    );

void main() {
  group('TELetterboxComparison', () {
    test('a full round reports no shortfall and no over-delivery', () {
      final c = TELetterboxComparison(dropped: 500, expected: _count(500));
      expect(c.shortfall, 0);
      expect(c.overDelivery, 0);
      expect(c.coverage, 1.0);
    });

    test('an under-delivered round reports the shortfall', () {
      final c = TELetterboxComparison(dropped: 400, expected: _count(500));
      expect(c.shortfall, 100);
      expect(c.overDelivery, 0);
      expect(c.coverage, closeTo(0.8, 1e-9));
    });

    test('more drops than letterboxes reads as over-delivery, not coverage',
        () {
      // The inflated-number signal: either boxes were hit twice or the
      // waypoints are not genuine. It must not simply show as ">100% done".
      final c = TELetterboxComparison(dropped: 650, expected: _count(500));
      expect(c.overDelivery, 150);
      expect(c.shortfall, 0);
      expect(c.coverage, closeTo(1.3, 1e-9));
    });

    test('an area with no curated letterboxes yields no percentage', () {
      // Reporting 0% here would read as a failed round when in truth the
      // area simply has not been curated yet.
      final c = TELetterboxComparison(dropped: 120, expected: _count(0));
      expect(c.coverage, isNull);
      expect(c.shortfall, 0);
      expect(c.overDelivery, 120);
    });

    test('trust follows the expected count', () {
      final trusted = TELetterboxComparison(dropped: 1, expected: _count(10));
      final not = TELetterboxComparison(
          dropped: 1, expected: _count(10, unverified: ['Kenilworth']));
      expect(trusted.isTrusted, isTrue);
      expect(not.isTrusted, isFalse);
    });
  });

  group('TELetterboxCheckProvider', () {
    test('pairs each polygon with its own expected count', () async {
      final tab = _tab([_target('North', 400), _target('South', 90)]);
      final provider = TELetterboxCheckProvider(
        service: _FakeCountService(
          perPolygon: [_count(500), _count(100)],
          unionResult: const LetterboxUnionResult(count: 600),
        ),
      );

      await provider.recheck(tab);

      final check = tab.letterboxCheck;
      final polygons = tab.targetPolygons;
      expect(check.resultFor(polygons[0])!.expectedCount, 500);
      expect(check.resultFor(polygons[0])!.dropped, 400);
      expect(check.resultFor(polygons[1])!.expectedCount, 100);
      expect(check.resultFor(polygons[1])!.shortfall, 10);
      expect(check.union!.count, 600);
      expect(check.error, isNull);
      expect(provider.isStale(tab), isFalse);
    });

    test('polygons sharing a name keep their own results', () async {
      // Mixing up two same-named work areas is exactly the error this screen
      // exists to catch, so they are told apart by boundary as well as name.
      final a = _target('Round 1', 10);
      final b = _target('Round 1', 20, points: _otherSquare);
      final tab = _tab([a, b]);
      final provider = TELetterboxCheckProvider(
        service: _FakeCountService(
          perPolygon: [_count(10), _count(40)],
          unionResult: const LetterboxUnionResult(count: 50),
        ),
      );
      await provider.recheck(tab);
      expect(tab.letterboxCheck.resultFor(a)!.expectedCount, 10);
      expect(tab.letterboxCheck.resultFor(b)!.expectedCount, 40);
    });

    test('a result is found again for an equal copy of the polygon', () async {
      // Grouping runs through `compute`, which copies on native platforms.
      final tab = _tab([_target('North', 5)]);
      final provider = TELetterboxCheckProvider(
        service: _FakeCountService(
          perPolygon: [_count(8)],
          unionResult: const LetterboxUnionResult(count: 8),
        ),
      );
      await provider.recheck(tab);
      final copy = TETargetPolygon(
          name: 'North', waypoints: const [], points: List.of(_square));
      expect(tab.letterboxCheck.resultFor(copy)!.expectedCount, 8);
    });

    test('polygons with no boundary are reported, never counted as zero',
        () async {
      // "We could not check this" and "nothing was delivered here" must never
      // look the same on a performance review.
      final noGeometry = TETargetPolygon(
          name: 'Legacy', waypoints: [_wpt(-33.9, 18.4)], points: const []);
      final tab = _tab([noGeometry]);
      final provider = TELetterboxCheckProvider(
        service: _FakeCountService(
          perPolygon: const [],
          unionResult: LetterboxUnionResult.empty,
        ),
      );

      await provider.recheck(tab);

      final check = tab.letterboxCheck;
      expect(check.resultFor(noGeometry), isNull);
      expect(check.hasResults, isFalse);
      expect(check.error, contains('re-run the trim'));
    });

    test('a tab with nothing to compare is not an error', () async {
      final tab = _tab(const []);
      final provider = TELetterboxCheckProvider(
        service: _FakeCountService(
          perPolygon: const [],
          unionResult: LetterboxUnionResult.empty,
        ),
      );
      await provider.recheck(tab);
      expect(tab.letterboxCheck.error, isNull);
      expect(tab.letterboxCheck.hasResults, isFalse);
      expect(provider.isStale(tab), isFalse);
    });

    test('a failing count surfaces the error instead of inventing numbers',
        () async {
      final tab = _tab([_target('North', 10)]);
      final provider = TELetterboxCheckProvider(service: _ThrowingService());
      await provider.recheck(tab);
      expect(tab.letterboxCheck.hasResults, isFalse);
      expect(tab.letterboxCheck.error, contains('storage unreachable'));
      expect(tab.letterboxCheck.isChecking, isFalse);
      // Not retried in a loop by the background sweep.
      expect(provider.isStale(tab), isFalse);
    });
  });

  group('background checking', () {
    test('every opened tab is counted, and kept on the tab', () async {
      final service = _FakeCountService(
        perPolygon: [_count(50)],
        unionResult: const LetterboxUnionResult(count: 50),
      );
      final provider = TELetterboxCheckProvider(service: service);
      final tabs = TETabsProvider();
      final opened = [
        _tab([_target('A', 10)]),
        _tab([_target('B', 20)]),
      ];
      tabs.addTabsBatch(opened);

      provider.scheduleSweep(tabs);
      await _settle();

      for (final tab in opened) {
        expect(tab.letterboxCheck.hasResults, isTrue);
        expect(provider.isStale(tab), isFalse);
      }
      final calls = service.countInEachCalls;

      // Switching tabs changes nothing that was counted: no recount.
      tabs.selectTab(1);
      provider.scheduleSweep(tabs);
      await _settle();
      expect(service.countInEachCalls, calls);

      // A rename copies the tab but keeps its numbers.
      tabs.renameTab(1, 'Renamed');
      expect(tabs.tabs[1].letterboxCheck.hasResults, isTrue);
    });

    test('a saved polygon edit is rechecked', () async {
      final service = _FakeCountService(
        perPolygon: [_count(50)],
        unionResult: const LetterboxUnionResult(count: 50),
      );
      final provider = TELetterboxCheckProvider(service: service);
      final tabs = TETabsProvider();
      tabs.addTabsBatch([
        TETabItem(
          title: 'Round',
          polygons: [_styled('North', _square)],
          tracks: [],
          waypoints: [_wpt(-33.95, 18.05), _wpt(-33.5, 18.5)],
          targetPolygons: [],
        ),
      ]);
      provider.scheduleSweep(tabs);
      await _settle();

      final tab = tabs.tabs[tabs.currentTab];
      final before = tab.letterboxCheck.polygons.single;
      expect(before.waypoints, hasLength(1));
      final calls = service.countInEachCalls;

      // Grow the polygon so the second waypoint falls inside it.
      tabs.updatePolygonPoints(tabs.currentTab, 0, _bigSquare);
      expect(provider.isStale(tab), isTrue);
      provider.scheduleSweep(tabs);
      await _settle();

      expect(service.countInEachCalls, calls + 1);
      expect(provider.isStale(tab), isFalse);
      final after = tab.letterboxCheck.polygons.single;
      expect(after.waypoints, hasLength(2));
      expect(tab.letterboxCheck.resultFor(after)!.dropped, 2);
    });

    test('an index update marks every tab stale and recounts', () async {
      final service = _FakeCountService(
        perPolygon: [_count(50)],
        unionResult: const LetterboxUnionResult(count: 50),
      );
      final provider = TELetterboxCheckProvider(service: service);
      final tabs = TETabsProvider();
      tabs.addTabsBatch([
        _tab([_target('A', 10)])
      ]);
      provider.scheduleSweep(tabs);
      await _settle();
      final tab = tabs.tabs[tabs.currentTab];
      final calls = service.countInEachCalls;

      provider.invalidateSuburbs(['kenilworth']);
      expect(provider.isStale(tab), isTrue);
      // Old numbers stay on screen until the recount lands.
      expect(tab.letterboxCheck.hasResults, isTrue);
      await _settle();

      expect(service.countInEachCalls, calls + 1);
      expect(provider.isStale(tab), isFalse);
    });

    test('import-mode tabs are left alone', () async {
      final service = _FakeCountService(
        perPolygon: [_count(50)],
        unionResult: const LetterboxUnionResult(count: 50),
      );
      final provider = TELetterboxCheckProvider(service: service);
      final tabs = TETabsProvider()..setActiveMode(TEMode.import);
      tabs.addTabsBatch([
        _tab([_target('A', 10)])
      ]);
      provider.scheduleSweep(tabs);
      await _settle();
      expect(service.countInEachCalls, 0);
    });
  });
}

Future<void> _settle() => Future<void>.delayed(const Duration(seconds: 1));

TETabItem _tab(List<TETargetPolygon> targets) => TETabItem(
      title: 'Round',
      polygons: [],
      tracks: [],
      waypoints: [],
      targetPolygons: targets,
    );

TEStyledPolygon _styled(String name, List<LatLng> points) => TEStyledPolygon(
      id: name,
      name: name,
      points: points,
      style: TEKmlStyle(
        strokeColor: const Color(0xFF000000),
        strokeWidth: 2,
        fillColor: const Color(0xFF000000),
        fill: false,
        outline: true,
      ),
    );

const _otherSquare = [
  LatLng(-34.2, 18.2),
  LatLng(-34.2, 18.3),
  LatLng(-34.1, 18.3),
  LatLng(-34.1, 18.2),
];

const _bigSquare = [
  LatLng(-34.0, 18.0),
  LatLng(-34.0, 18.6),
  LatLng(-33.4, 18.6),
  LatLng(-33.4, 18.0),
];

class _ThrowingService extends LetterboxCountService {
  @override
  Future<List<LetterboxCount>> countInEach(List<List<LatLng>> polygons) async {
    throw StateError('storage unreachable');
  }
}
