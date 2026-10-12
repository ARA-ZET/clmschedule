// Pure matching logic shared by Processing mode and the client Report
// feature — real filenames from this codebase's own naming convention:
//   `Track 11 May 2026 Nolan Seeff Round1.gpx`
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/track_editor/services/te_gpx_matching.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';

Distributor _d(String id, String name) =>
    Distributor(id: id, name: name, index: 0);

void main() {
  group('extractTrackDate', () {
    test('reads the first timestamped trackpoint', () {
      final trk = Trk(trksegs: [
        Trkseg(trkpts: [
          Wpt(lat: -33.9, lon: 18.4), // no time — skipped
          Wpt(lat: -33.9, lon: 18.4, time: DateTime.utc(2026, 5, 11, 8)),
          Wpt(lat: -33.9, lon: 18.4, time: DateTime.utc(2026, 5, 11, 9)),
        ]),
      ]);
      expect(extractTrackDate([trk]), DateTime.utc(2026, 5, 11, 8).toLocal());
    });

    test('null when no point carries a time', () {
      final trk = Trk(trksegs: [
        Trkseg(trkpts: [Wpt(lat: -33.9, lon: 18.4)]),
      ]);
      expect(extractTrackDate([trk]), isNull);
    });

    test('null with no tracks at all', () {
      expect(extractTrackDate(const []), isNull);
    });
  });

  group('extractDateFromText', () {
    test('parses "DD Mon YYYY"', () {
      expect(extractDateFromText('11 may 2026 nolan seeff round1'),
          DateTime(2026, 5, 11));
    });

    test('parses a full month name', () {
      expect(
          extractDateFromText('3 September 2026 team'), DateTime(2026, 9, 3));
    });

    test('parses ISO-ish dates', () {
      // `\b` needs a real word boundary before the digits — an underscore
      // is itself a word character, so "backup_2026" would not match; a
      // space does.
      expect(extractDateFromText('backup 2026-05-11 final'),
          DateTime(2026, 5, 11));
    });

    test('rejects an impossible date rather than silently rolling over', () {
      // Day 32 has no valid DateTime — must not become 1 June.
      expect(extractDateFromText('32 may 2026 team'), isNull);
    });

    test('null when there is nothing date-shaped', () {
      expect(extractDateFromText('track final v2'), isNull);
    });
  });

  group('resolveDate', () {
    test('prefers the real trackpoint timestamp over the filename', () {
      final trk = Trk(trksegs: [
        Trkseg(trkpts: [
          Wpt(lat: -33.9, lon: 18.4, time: DateTime.utc(2026, 1, 1, 8)),
        ]),
      ]);
      // Filename says May; the track itself says January — trust the track.
      final d = resolveDate(
          [trk], '11 may 2026 nolan seeff', 'Track 11 May 2026 Nolan.gpx');
      expect(d, DateTime.utc(2026, 1, 1, 8).toLocal());
    });

    test('falls back to the match key, then the raw filename', () {
      expect(
        resolveDate(const [], 'no date here', 'Track 11 May 2026 Nolan.gpx'),
        DateTime(2026, 5, 11),
      );
      expect(
        resolveDate(const [], 'no date here', 'no date here either.gpx'),
        isNull,
      );
    });
  });

  group('matchDistributor', () {
    final distributors = [
      _d('d1', 'Nolan Adams'),
      _d('d2', 'Thandiwe Seeff'),
      _d('d3', 'Ben Nolan'), // shares a token with d1's first name
    ];

    test('picks the distributor with the most overlapping name tokens', () {
      final m = matchDistributor(
          '11 may 2026 nolan adams seeff round1', distributors);
      // "nolan" + "adams" both match d1; d3 only matches "nolan".
      expect(m?.id, 'd1');
    });

    test('a single shared token still wins over no match', () {
      final m = matchDistributor('11 may 2026 ben team', distributors);
      expect(m?.id, 'd3');
    });

    test('null when nothing overlaps at all', () {
      final m = matchDistributor('11 may 2026 unknown person', distributors);
      expect(m, isNull);
    });

    test('null with an empty distributor list', () {
      expect(matchDistributor('anything', const []), isNull);
    });

    test('is case-insensitive and separator-insensitive', () {
      final m = matchDistributor('THANDIWE_SEEFF-round2', distributors);
      expect(m?.id, 'd2');
    });
  });
}
