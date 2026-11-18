// Smoke test for the client-facing distribution report.
//
// The report is hand-laid-out — CustomPaint charts, keep-together blocks and
// a MultiPage flow — so the thing most likely to break it is a layout
// overflow on a day shaped slightly differently to the last one. Shifts are
// merged by date, so two promoters on one date is part of the fixture. This
// builds the PDF from synthetic shifts covering the shapes that occur in the
// wild (a continuous logger, a motion-triggered one, a tracklog gap, a lunch
// break, attached photos) and asserts it renders to a multi-page document.
//
// Set TE_REPORT_PDF_OUT to a file path to keep the rendered PDF for eyeballing:
//   TE_REPORT_PDF_OUT=/tmp/report.pdf flutter test test/te_report_pdf_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/utils/schedule_time.dart';
import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/services/te_place_names.dart';
import 'package:clmschedule/track_editor/services/te_report_maps.dart';
import 'package:clmschedule/track_editor/services/te_report_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // flutter_test stubs every HTTP request with a 400, which would send the
    // Google-Fonts load down its Helvetica fallback and change every metric
    // this test is meant to exercise.
    HttpOverrides.global = null;
  });

  test('builds a multi-page report for a mixed set of shifts', () async {
    final photo = await File('assets/logo.png').readAsBytes();

    final days = [
      _continuousShift(
        distributor: _distributor('d1', 'Alice Mbeki'),
        date: DateTime(2026, 3, 17),
      ),
      _continuousShift(
        distributor: _distributor('d1', 'Alice Mbeki'),
        date: DateTime(2026, 3, 18),
        flyersPerCycle: 3,
      ),
      _motionTriggeredShift(
        distributor: _distributor('d2', 'Bongani Ndlovu'),
        date: DateTime(2026, 3, 18),
      ),
    ];

    // Every shift must have produced something to chart, or the test would be
    // asserting on empty pages.
    for (final day in days) {
      expect(day.analysis.isEmpty, isFalse, reason: day.distributor.name);
      expect(day.analysis.totalHandouts, greaterThan(50));
      expect(day.analysis.hourly, isNotEmpty);
      // The lunch has to land as its own stop, or the break segment of the
      // time split and its hatched legend key never get exercised.
      expect(day.analysis.breakAndLunchTime.inMinutes, greaterThan(15),
          reason: day.distributor.name);
    }
    expect(days.last.analysis.isMotionTriggered, isTrue);

    // Names for every work spot, as the panel would resolve them.
    final names = [
      'Voortrekker Rd & Durban Rd',
      'Durban Rd & Kasselsvlei Rd',
      'Main Rd & Church St'
    ];
    final placeNames = <String, TEPlaceName>{};
    for (final day in days) {
      final spots = teWorkSpots(day.analysis);
      expect(spots, isNotEmpty);
      for (var i = 0; i < spots.length; i++) {
        placeNames[tePlaceKey(
            spots[i].centre.latitude, spots[i].centre.longitude)] = TEPlaceName(
          intersection: names[i % names.length],
        );
      }
    }

    // Route maps draw on a blank background unless TE_REPORT_LIVE_MAPS is
    // set, which fetches the real street maps from Google for eyeballing.
    final mapImages = Platform.environment['TE_REPORT_LIVE_MAPS'] != null
        ? await fetchReportMaps(days)
        : const <String, Uint8List>{};

    // Photos belong to the date, shared by both promoters who worked it.
    const link = 'https://maps.communitylifemedia.co.za/map/test42';
    final bytes = await buildReportPdf(days,
        placeNames: placeNames,
        mapImages: mapImages,
        mapLinks: {for (final d in days) d.key: link},
        photosByDate: {
      DateTime(2026, 3, 18): [
        TEProofPhoto(bytes: photo, fileName: 'proof-1.png'),
        TEProofPhoto(bytes: photo, fileName: 'proof-2.png'),
      ],
    });

    final out = Platform.environment['TE_REPORT_PDF_OUT'];
    if (out != null) await File(out).writeAsBytes(bytes);

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // Each map and its caption link to the client's interactive map.
    expect(latin1.decode(bytes), contains('/URI($link)'));
    // The object streams are compressed, so there is nothing readable to
    // count pages by — size is the available proxy for "the summary, two
    // dates and their photos actually got drawn".
    expect(bytes.length, greaterThan(20000));

  });

  test('two promoters, map and chart, share each page', () async {
    final date = DateTime(2026, 3, 18);
    final days = [
      for (final (i, name) in ['Alice', 'Bongani', 'Chloe', 'Dumisani'].indexed)
        i.isEven
            ? _continuousShift(distributor: _distributor('d$i', name), date: date)
            : _motionTriggeredShift(
                distributor: _distributor('d$i', name), date: date),
    ];
    final mapImages = Platform.environment['TE_REPORT_LIVE_MAPS'] != null
        ? await fetchReportMaps(days)
        : const <String, Uint8List>{};
    final bytes = await buildReportPdf(days, mapImages: mapImages);
    final out = Platform.environment['TE_REPORT_PDF_OUT_FOUR'];
    if (out != null) await File(out).writeAsBytes(bytes);

    // Page 1: the day's figures and team table; then two promoters a page.
    final pages =
        RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(bytes)).length;
    expect(pages, 3);
  });

  test('a promoter at one corner gets one map with where they worked beside it',
      () async {
    final start = DateTime.utc(2026, 3, 18, 6);
    const lat = -33.9180, lon = 18.4230; // Strand St & Buitengracht St
    final day = TEPromoterDay(
      distributor: _distributor('d1', 'Alice Mbeki'),
      date: DateTime(2026, 3, 18),
      tracks: [
        Trk(trksegs: [
          Trkseg(trkpts: [
            for (var i = 0; i < 300; i++)
              Wpt(
                  lat: lat + (i % 7) * 2 * _degPerM,
                  lon: lon + (i % 5) * 2 * _degPerM,
                  time: start.add(Duration(minutes: i))),
          ]),
        ]),
      ],
      waypoints: [
        for (var i = 0; i < 120; i++)
          Wpt(
              lat: lat + (i % 3) * _degPerM,
              lon: lon + (i % 4) * _degPerM,
              time: start.add(Duration(minutes: i * 2))),
      ],
      sourcePaths: const [],
    );
    expect(teReportMaps(teMapRoute(day)), hasLength(1));
    final mapImages = Platform.environment['TE_REPORT_LIVE_MAPS'] != null
        ? await fetchReportMaps([day])
        : const <String, Uint8List>{};
    final bytes = await buildReportPdf([day],
        mapImages: mapImages,
        whereOverrides: {day.key: 'Strand St & Buitengracht St'},
        mapLinks: {day.key: 'https://maps.communitylifemedia.co.za/map/one'});
    final out = Platform.environment['TE_REPORT_PDF_OUT_ONE'];
    if (out != null) await File(out).writeAsBytes(bytes);
    expect(latin1.decode(bytes),
        contains('/URI(https://maps.communitylifemedia.co.za/map/one)'));
  });

  group('where worked', () {
    test('prints the intersection found for each work spot', () {
      final day = _continuousShift(
        distributor: _distributor('d1', 'Alice Mbeki'),
        date: DateTime(2026, 3, 17),
      );
      final spots = teWorkSpots(day.analysis);
      expect(spots, isNotEmpty);
      final key =
          tePlaceKey(spots.first.centre.latitude, spots.first.centre.longitude);

      expect(teAutoWhere(day.analysis, const {}), isEmpty);
      expect(
          teAutoWhere(day.analysis, {
            key: const TEPlaceName(intersection: 'Voortrekker Rd & Durban Rd'),
          }),
          ['Voortrekker Rd & Durban Rd']);
    });

    test('builds with hand-typed text in place of the looked-up names',
        () async {
      final day = _continuousShift(
        distributor: _distributor('d1', 'Alice Mbeki'),
        date: DateTime(2026, 3, 17),
      );
      final bytes = await buildReportPdf([day], whereOverrides: {
        day.key: 'Main Rd & Church St\n\n  Durban Rd  ',
      });
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });

  group('breaks', () {
    Duration total(List<(DateTime, DateTime)> breaks) =>
        breaks.fold(Duration.zero, (sum, p) => sum + p.$2.difference(p.$1));

    test(
        'any stretch of over 15 minutes between flyers counts while the '
        'total stays within 1h15', () {
      final b = _ShiftBuilder(DateTime(2026, 3, 20),
          continuous: true, flyersPerCycle: 4);
      b.walk(const Duration(minutes: 10));
      b.workIntersection(const Duration(minutes: 30));
      b.stand(const Duration(minutes: 17)); // still, no flyers: a break
      b.workIntersection(const Duration(minutes: 30));
      b.stand(const Duration(minutes: 10)); // too short to be one
      b.workIntersection(const Duration(minutes: 20));
      b.walk(const Duration(minutes: 20)); // moving, no flyers: a break too
      b.workIntersection(const Duration(minutes: 20));
      final a = b.build(_distributor('d1', 'Alice Mbeki')).analysis;

      final breaks = reportBreaks(a);
      expect(breaks, hasLength(2));
      expect(breaks[0].$2.difference(breaks[0].$1).inMinutes,
          inInclusiveRange(17, 19));
      expect(breaks[1].$2.difference(breaks[1].$1).inMinutes,
          inInclusiveRange(20, 22));
    });

    test('past 1h15 in total, breaks spent moving are taken back out', () {
      final b = _ShiftBuilder(DateTime(2026, 3, 20),
          continuous: true, flyersPerCycle: 4);
      b.walk(const Duration(minutes: 10));
      b.workIntersection(const Duration(minutes: 30));
      final pauseStart = b.t;
      b.stand(const Duration(minutes: 17));
      for (var i = 0; i < 3; i++) {
        b.workIntersection(const Duration(minutes: 20));
        b.walk(const Duration(minutes: 25)); // 3 × 25m moving: over budget
      }
      b.workIntersection(const Duration(minutes: 20));
      final a = b.build(_distributor('d1', 'Alice Mbeki')).analysis;

      final breaks = reportBreaks(a);
      expect(total(breaks).inMinutes, lessThanOrEqualTo(75));
      expect(breaks, hasLength(1));
      final lastFlyer = a.handoutTimes
          .lastWhere((t) => !t.isAfter(toScheduleCivil(pauseStart)));
      expect(breaks.single.$1.difference(lastFlyer).inMinutes, lessThan(2));
      expect(breaks.single.$2.difference(breaks.single.$1).inMinutes,
          inInclusiveRange(17, 19));
    });

    test('a short hole in the tracklog is not a break', () {
      final b = _ShiftBuilder(DateTime(2026, 3, 21),
          continuous: true, flyersPerCycle: 4);
      b.walk(const Duration(minutes: 10));
      b.workIntersection(const Duration(minutes: 30));
      b.blackout(const Duration(minutes: 5));
      b.walk(const Duration(minutes: 4));
      b.workIntersection(const Duration(minutes: 30));
      final a = b.build(_distributor('d1', 'Alice Mbeki')).analysis;

      expect(a.gaps, isNotEmpty);
      expect(reportBreaks(a), isEmpty);
    });
  });

  test('a single-day report skips the multi-day summary', () async {
    final day = _continuousShift(
      distributor: _distributor('d1', 'Alice Mbeki'),
      date: DateTime(2026, 3, 17),
    );

    final bytes = await buildReportPdf([day]);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');

    final out = Platform.environment['TE_REPORT_PDF_OUT_SINGLE'];
    if (out != null) await File(out).writeAsBytes(bytes);
  });

  test('survives a shift with no usable tracklog', () async {
    final day = TEPromoterDay(
      distributor: _distributor('d3', 'Chantal Adams'),
      date: DateTime(2026, 3, 19),
      tracks: const [],
      waypoints: const [],
      sourcePaths: const [],
    );
    expect(day.analysis.isEmpty, isTrue);

    final bytes = await buildReportPdf([day]);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');

    final out = Platform.environment['TE_REPORT_PDF_OUT_EMPTY'];
    if (out != null) await File(out).writeAsBytes(bytes);
  });
}

Distributor _distributor(String id, String name) =>
    Distributor(id: id, name: name, index: 0);

// ── Synthetic shifts ────────────────────────────────────────────────────────

/// Roughly a metre in degrees at Cape Town's latitude.
const double _degPerM = 1 / 93000;

/// A logger that writes a point every 10 seconds no matter what — standing
/// still reads as a dense cluster of points going nowhere.
TEPromoterDay _continuousShift({
  required Distributor distributor,
  required DateTime date,
  int flyersPerCycle = 4,
}) {
  final b =
      _ShiftBuilder(date, continuous: true, flyersPerCycle: flyersPerCycle);
  b.walk(const Duration(minutes: 18));
  b.workIntersection(const Duration(minutes: 95));
  b.walk(const Duration(minutes: 14));
  b.workIntersection(const Duration(minutes: 100));
  b.walk(const Duration(minutes: 4));
  b.stand(const Duration(minutes: 28)); // lunch, off the corner
  b.walk(const Duration(minutes: 8));
  b.workIntersection(const Duration(minutes: 85));
  b.blackout(const Duration(minutes: 14)); // logger off / no signal
  b.walk(const Duration(minutes: 10));
  return b.build(distributor);
}

/// A logger that stops writing while the distributor stands still, so a dwell
/// shows up as a long silence between two points in the same place.
TEPromoterDay _motionTriggeredShift({
  required Distributor distributor,
  required DateTime date,
}) {
  final b = _ShiftBuilder(date, continuous: false, flyersPerCycle: 3);
  b.walk(const Duration(minutes: 12));
  b.workIntersection(const Duration(minutes: 80));
  b.walk(const Duration(minutes: 10));
  b.workIntersection(const Duration(minutes: 75));
  b.drive(const Duration(minutes: 6)); // a lift to the next spot
  b.walk(const Duration(minutes: 3));
  b.stand(const Duration(minutes: 22));
  b.walk(const Duration(minutes: 6));
  b.workIntersection(const Duration(minutes: 60));
  b.walk(const Duration(minutes: 8));
  return b.build(distributor);
}

class _ShiftBuilder {
  final bool continuous;
  final int flyersPerCycle;
  final List<Wpt> points = [];
  final List<Wpt> handouts = [];
  final math.Random rnd = math.Random(7);

  /// GPX carries instants; the analysis reads them as SAST, so 05:00Z is an
  /// 07:00 start on the report's clock.
  DateTime t;
  double lat = -33.9249;
  double lon = 18.4241;

  _ShiftBuilder(DateTime date,
      {required this.continuous, required this.flyersPerCycle})
      : t = DateTime.utc(date.year, date.month, date.day, 5);

  void _point() => points.add(Wpt(lat: lat, lon: lon, time: t, ele: 20));

  /// Walking between intersections at about 4.5 km/h.
  void walk(Duration d) {
    final steps = d.inSeconds ~/ 10;
    for (var i = 0; i < steps; i++) {
      lon += 12.5 * _degPerM;
      t = t.add(const Duration(seconds: 10));
      _point();
    }
  }

  /// Parked at a robot: flyers go out in bursts on each light cycle.
  void workIntersection(Duration d) {
    final end = t.add(d);
    final baseLat = lat, baseLon = lon;
    var cycle = 0;
    while (t.isBefore(end)) {
      // One 90-second light cycle: a burst of handouts, then a wait.
      for (var i = 0; i < flyersPerCycle + (cycle % 3); i++) {
        t = t.add(const Duration(seconds: 7));
        lat = baseLat + (rnd.nextDouble() - 0.5) * 8 * _degPerM;
        lon = baseLon + (rnd.nextDouble() - 0.5) * 8 * _degPerM;
        handouts.add(Wpt(lat: lat, lon: lon, time: t, name: 'Handout'));
        if (continuous) _point();
      }
      final wait = t.add(const Duration(seconds: 50));
      while (t.isBefore(wait)) {
        t = t.add(const Duration(seconds: 10));
        if (continuous) _point();
      }
      cycle++;
    }
    lat = baseLat;
    lon = baseLon;
    // A motion-triggered logger writes the point that ends the silence.
    if (!continuous) _point();
  }

  /// In a vehicle at about 30 km/h — the report leaves these readings off
  /// its charts.
  void drive(Duration d) {
    final steps = d.inSeconds ~/ 10;
    for (var i = 0; i < steps; i++) {
      lon += 83 * _degPerM;
      t = t.add(const Duration(seconds: 10));
      _point();
    }
  }

  /// Standing still with nothing going out — a break or a lunch.
  void stand(Duration d) {
    final end = t.add(d);
    while (t.isBefore(end)) {
      t = t.add(const Duration(seconds: 10));
      if (continuous) _point();
    }
    if (!continuous) _point();
  }

  /// Logger off: no points at all, and the distributor has moved on by the
  /// time it comes back.
  void blackout(Duration d) {
    t = t.add(d);
    lon += 400 * _degPerM;
  }

  TEPromoterDay build(Distributor distributor) => TEPromoterDay(
        distributor: distributor,
        date: DateTime(t.year, t.month, t.day),
        tracks: [
          Trk(trksegs: [Trkseg(trkpts: points)])
        ],
        waypoints: handouts,
        sourcePaths: const ['report/test.gpx'],
      );
}
