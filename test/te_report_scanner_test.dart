// The pure grouping step of the folder scan: pairing, distributor/date
// resolution, and merging same-distributor-same-day pairs into one
// promoter day. No Firebase/Storage involved — see te_report_scanner.dart's
// split between the I/O wrapper and groupIntoPromoterDays.
import 'dart:typed_data';

import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/track_editor/models/te_gpx_file_entry.dart';
import 'package:clmschedule/track_editor/services/te_report_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

Distributor _d(String id, String name) =>
    Distributor(id: id, name: name, index: 0);

/// Builds a minimal but well-formed GPX document for one file, with however
/// many trackpoints/waypoints matter for the test.
String _gpx(
    {List<(double, double, DateTime?)> trkpts = const [], int waypoints = 0}) {
  final buf = StringBuffer('<?xml version="1.0"?><gpx version="1.1">');
  if (trkpts.isNotEmpty) {
    buf.write('<trk><trkseg>');
    for (final (lat, lon, time) in trkpts) {
      buf.write('<trkpt lat="$lat" lon="$lon">');
      if (time != null) buf.write('<time>${time.toIso8601String()}</time>');
      buf.write('</trkpt>');
    }
    buf.write('</trkseg></trk>');
  }
  for (var i = 0; i < waypoints; i++) {
    buf.write('<wpt lat="-33.9" lon="18.4"></wpt>');
  }
  buf.write('</gpx>');
  return buf.toString();
}

TEGpxFileEntry _entry(String filename, String gpxXml) =>
    TEGpxFileEntry.parse(filename, Uint8List.fromList(gpxXml.codeUnits));

void main() {
  final distributors = [_d('d1', 'Nolan Adams'), _d('d2', 'Thandiwe Seeff')];

  test('a matched track+waypoints pair becomes one promoter day', () {
    final entries = [
      _entry(
        'Track 11 May 2026 Nolan Adams Round1.gpx',
        _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 8))]),
      ),
      _entry(
        'Waypoints 11 May 2026 Nolan Adams Round1.gpx',
        _gpx(waypoints: 5),
      ),
    ];
    final result = groupIntoPromoterDays(entries, distributors);

    expect(result.unresolved, isEmpty);
    expect(result.promoterDays, hasLength(1));
    final day = result.promoterDays.single;
    expect(day.distributor.id, 'd1');
    expect(day.date, DateTime(2026, 5, 11));
    expect(day.waypoints, hasLength(5));
  });

  test(
      'two rounds by the same distributor on the same day merge into one '
      'promoter day', () {
    final entries = [
      _entry('Track 11 May 2026 Nolan Adams Round1.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 8))])),
      _entry(
          'Waypoints 11 May 2026 Nolan Adams Round1.gpx', _gpx(waypoints: 3)),
      _entry('Track 11 May 2026 Nolan Adams Round2.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 14))])),
      _entry(
          'Waypoints 11 May 2026 Nolan Adams Round2.gpx', _gpx(waypoints: 4)),
    ];
    final result = groupIntoPromoterDays(entries, distributors);

    expect(result.promoterDays, hasLength(1));
    final day = result.promoterDays.single;
    expect(day.tracks, hasLength(2)); // one Trk from each round
    expect(day.waypoints, hasLength(7)); // 3 + 4
  });

  test(
      'the same distributor on two different days stays as two promoter '
      'days', () {
    final entries = [
      _entry('Track 11 May 2026 Nolan Adams.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 8))])),
      _entry('Waypoints 11 May 2026 Nolan Adams.gpx', _gpx(waypoints: 1)),
      _entry('Track 12 May 2026 Nolan Adams.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 12, 8))])),
      _entry('Waypoints 12 May 2026 Nolan Adams.gpx', _gpx(waypoints: 1)),
    ];
    final result = groupIntoPromoterDays(entries, distributors);

    expect(result.promoterDays, hasLength(2));
    expect(result.promoterDays.map((d) => d.date),
        [DateTime(2026, 5, 11), DateTime(2026, 5, 12)]);
  });

  test(
      'two different distributors on the same day stay as two promoter '
      'days', () {
    final entries = [
      _entry('Track 11 May 2026 Nolan Adams.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 8))])),
      _entry('Waypoints 11 May 2026 Nolan Adams.gpx', _gpx(waypoints: 1)),
      _entry('Track 11 May 2026 Thandiwe Seeff.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 8))])),
      _entry('Waypoints 11 May 2026 Thandiwe Seeff.gpx', _gpx(waypoints: 1)),
    ];
    final result = groupIntoPromoterDays(entries, distributors);

    expect(result.promoterDays, hasLength(2));
    expect(
        result.promoterDays.map((d) => d.distributor.id).toSet(), {'d1', 'd2'});
  });

  test(
      'a file whose name matches no known distributor is unresolved, not '
      'silently dropped', () {
    final entries = [
      _entry('Track 11 May 2026 Unknown Person.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 8))])),
      _entry('Waypoints 11 May 2026 Unknown Person.gpx', _gpx(waypoints: 1)),
    ];
    final result = groupIntoPromoterDays(entries, distributors);

    expect(result.promoterDays, isEmpty);
    expect(result.unresolved, hasLength(1));
    expect(result.unresolved.single.missingDistributor, isTrue);
    expect(result.unresolved.single.missingDate, isFalse);
  });

  test(
      'a track file with no timestamps and no date in its name is '
      'unresolved for a missing date', () {
    final entries = [
      _entry(
          'Track Nolan Adams final.gpx', _gpx(trkpts: [(-33.9, 18.4, null)])),
      _entry('Waypoints Nolan Adams final.gpx', _gpx(waypoints: 1)),
    ];
    final result = groupIntoPromoterDays(entries, distributors);

    expect(result.promoterDays, isEmpty);
    expect(result.unresolved.single.missingDate, isTrue);
    expect(result.unresolved.single.missingDistributor, isFalse);
  });

  test(
      'a lone track file with no waypoints partner still resolves on its '
      'own, matching how a single unmatched file behaves elsewhere', () {
    final entries = [
      _entry('Track 11 May 2026 Nolan Adams.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 8))])),
    ];
    final result = groupIntoPromoterDays(entries, distributors);

    expect(result.unresolved, isEmpty);
    expect(result.promoterDays, hasLength(1));
    expect(result.promoterDays.single.waypoints, isEmpty);
  });

  test('sourcePaths are attached from the pathByName lookup', () {
    final entries = [
      _entry('Track 11 May 2026 Nolan Adams.gpx',
          _gpx(trkpts: [(-33.9, 18.4, DateTime.utc(2026, 5, 11, 8))])),
      _entry('Waypoints 11 May 2026 Nolan Adams.gpx', _gpx(waypoints: 1)),
    ];
    final result = groupIntoPromoterDays(entries, distributors, pathByName: {
      'Track 11 May 2026 Nolan Adams.gpx':
          'Distribution/2026/May 2026/Client/Round 1/Track 11 May 2026 Nolan Adams.gpx',
      'Waypoints 11 May 2026 Nolan Adams.gpx':
          'Distribution/2026/May 2026/Client/Round 1/Waypoints 11 May 2026 Nolan Adams.gpx',
    });
    expect(result.promoterDays.single.sourcePaths, hasLength(2));
  });

  test('empty input produces an empty result, not an error', () {
    final result = groupIntoPromoterDays(const [], distributors);
    expect(result.promoterDays, isEmpty);
    expect(result.unresolved, isEmpty);
  });
}
