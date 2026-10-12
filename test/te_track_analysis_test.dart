// Synthetic flyer round, built to exercise every branch of the analysis:
// a walk-in, a worked intersection, a lunch break, an idle wait, a logger
// gap, and a walk-out.
import 'package:clmschedule/track_editor/utils/te_track_analysis.dart';
import 'package:clmschedule/utils/schedule_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';

/// Trackpoints are written as UTC instants, exactly as a GPX logger writes
/// them; the analysis converts to SAST civil time internally.
DateTime utcAt(int minutes) =>
    DateTime.utc(2026, 4, 14, 6, 0).add(Duration(minutes: minutes));

Wpt trkpt(double lat, double lon, DateTime t) =>
    Wpt(lat: lat, lon: lon, time: t);

void main() {
  _summaryGettersTests();
  _motionTriggeredTests();
  _hourlyTests();

  // Roughly 111 m per 0.001 degree of latitude at the equator.
  const base = -33.9;
  const lon = 18.42;

  Trk buildTrack() {
    final pts = <Wpt>[];

    // 0–10 min: walking in, ~0.0009 deg (100 m) per minute ≈ 6 km/h.
    for (var m = 0; m <= 10; m++) {
      pts.add(trkpt(base + m * 0.0009, lon, utcAt(m)));
    }
    final atStop = base + 10 * 0.0009;

    // 10–70 min: working the intersection — drifting inside a ~20 m circle.
    for (var m = 11; m <= 70; m++) {
      pts.add(trkpt(atStop + (m.isEven ? 0.00008 : -0.00008), lon, utcAt(m)));
    }

    // 70–100 min: lunch, 400 m away, no handouts.
    final lunch = atStop + 0.0036;
    for (var m = 71; m <= 100; m++) {
      pts.add(trkpt(lunch, lon, utcAt(m)));
    }

    // 100–110 min: back to the corner.
    for (var m = 101; m <= 110; m++) {
      pts.add(trkpt(lunch - (m - 100) * 0.00036, lon, utcAt(m)));
    }

    // 110–118 min: standing around, no handouts (idle, under the 20 min
    // break threshold).
    for (var m = 111; m <= 118; m++) {
      pts.add(trkpt(atStop, lon, utcAt(m)));
    }

    // 118–130 min: LOGGER OFF — no points at all.

    // 130–140 min: back on, 500 m from where the logger died, walking out.
    // The jump across the gap must not be counted as ground covered.
    final resume = atStop + 0.0045;
    for (var m = 130; m <= 140; m++) {
      pts.add(trkpt(resume + (m - 130) * 0.0009, lon, utcAt(m)));
    }

    return Trk(trksegs: [Trkseg(trkpts: pts)]);
  }

  /// One press per minute for the hour spent at the intersection.
  List<Wpt> buildHandouts() => [
        for (var m = 11; m <= 70; m++)
          Wpt(lat: base + 10 * 0.0009, lon: lon, time: utcAt(m), name: 'WPT$m'),
      ];

  late TETrackAnalysis a;

  setUp(() {
    a = TETrackAnalysis.from(
      tracks: [buildTrack()],
      waypoints: buildHandouts(),
    );
  });

  test('counts every handout and places them on the SAST clock', () {
    expect(a.totalHandouts, 60);
    expect(a.untimedHandouts, 0);
    // 06:00 UTC is 08:00 SAST.
    expect(a.start, toScheduleCivil(utcAt(0)));
    expect(a.start.hour, 8);
    expect(a.end, toScheduleCivil(utcAt(140)));
  });

  test('cumulative count is a step function over the shift', () {
    expect(a.cumulativeAt(a.start), 0);
    expect(a.cumulativeAt(toScheduleCivil(utcAt(40))), 30);
    expect(a.cumulativeAt(a.end), 60);
  });

  test('separates the worked stop, the break and the idle wait', () {
    final working = a.stops.where((s) => s.kind == TEStopKind.handout).toList();
    final breaks =
        a.stops.where((s) => s.kind == TEStopKind.breakTime).toList();
    final idle = a.stops.where((s) => s.kind == TEStopKind.idle).toList();

    expect(working, hasLength(1));
    expect(working.single.handouts, 60);
    expect(working.single.duration.inMinutes, closeTo(59, 2));

    expect(breaks, hasLength(1));
    expect(breaks.single.handouts, 0);
    expect(breaks.single.duration.inMinutes, closeTo(29, 2));

    // The 8-minute wait is stationary but too short to be a break.
    expect(idle, hasLength(1));
    expect(idle.single.duration.inMinutes, closeTo(7, 2));
  });

  test('finds the logger gap and keeps it out of tracked time', () {
    expect(a.gaps, hasLength(1));
    expect(a.gaps.single.duration.inMinutes, closeTo(12, 1));
    expect(a.elapsed.inMinutes, 140);
    expect(a.trackedTime.inMinutes, closeTo(128, 1));
  });

  test('rate while working is far higher than the shift average', () {
    // 60 handouts in ~59 minutes at the corner.
    expect(a.ratePerHourWorking, closeTo(61, 3));
    // 60 handouts across 140 minutes of shift.
    expect(a.ratePerHourOverall, closeTo(26, 2));
    expect(a.handoutsAtStops, 60);
    expect(a.handoutsOnTheMove, 0);
  });

  test('walking shows as speed, standing still does not', () {
    // 0.0009 deg of latitude a minute is ~100 m/min, i.e. ~6 km/h.
    final walking = a.sampleAt(toScheduleCivil(utcAt(5)))!;
    final parked = a.sampleAt(toScheduleCivil(utcAt(40)))!;
    expect(walking.speedKmh, closeTo(6, 1.5));
    expect(parked.speedKmh, lessThan(1.5));
  });

  test('the jump across a logger gap is not counted as ground covered', () {
    expect(a.gaps.single.jumpKm, closeTo(0.5, 0.05));
    // Same points, but with the gap threshold raised so high that the hole is
    // never recognised — the 500 m jump then lands in the distance total.
    final blind = TETrackAnalysis.from(
      tracks: [buildTrack()],
      waypoints: buildHandouts(),
      config: const TEAnalysisConfig(gapThreshold: Duration(hours: 1)),
    );
    expect(blind.gaps, isEmpty);
    expect(blind.distanceKm - a.distanceKm, closeTo(0.5, 0.05));
  });

  test('clusters the handouts onto one intersection', () {
    expect(a.hotspots, hasLength(1));
    expect(a.hotspots.single.handouts, 60);
  });

  test('reports warm-up and wind-down dead time', () {
    expect(a.warmUp!.inMinutes, 11);
    expect(a.windDown!.inMinutes, 70);
  });

  test('waypoints without a timestamp still count towards the total', () {
    final b = TETrackAnalysis.from(
      tracks: [buildTrack()],
      waypoints: [...buildHandouts(), Wpt(lat: base, lon: lon)],
    );
    expect(b.untimedHandouts, 1);
    expect(b.totalHandouts, 61);
    expect(b.handoutTimes, hasLength(60));
  });

  test('an empty tab produces an empty analysis rather than throwing', () {
    final e = TETrackAnalysis.from(tracks: const [], waypoints: const []);
    expect(e.isEmpty, isTrue);
    expect(e.totalHandouts, 0);
  });
}

/// The hourly table is the row-by-row view a client reads, so the arithmetic
/// has to tie back exactly to the shift totals.
void _hourlyTests() {
  const base = -33.9;
  const lon = 18.42;

  test('hourly rows tile the shift and account for every handout', () {
    // Reuse the same synthetic round as the main suite: 08:00–10:20 SAST,
    // 60 handouts, one worked corner, a lunch break and a logger gap.
    final pts = <Wpt>[];
    for (var m = 0; m <= 10; m++) {
      pts.add(trkpt(base + m * 0.0009, lon, utcAt(m)));
    }
    final atStop = base + 10 * 0.0009;
    for (var m = 11; m <= 140; m++) {
      pts.add(trkpt(atStop + (m.isEven ? 0.00008 : -0.00008), lon, utcAt(m)));
    }
    final wpts = [
      for (var m = 11; m <= 70; m++) Wpt(lat: atStop, lon: lon, time: utcAt(m)),
    ];

    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: wpts,
    );

    // 08:00 → 10:20 SAST spans three clock hours.
    expect(a.hourly.map((h) => h.hourStart.hour), [8, 9, 10]);

    // Every timed handout lands in exactly one row.
    expect(
        a.hourly.fold<int>(0, (n, h) => n + h.handouts), a.handoutTimes.length);

    // Rows tile the shift with no overlap and no hole.
    expect(a.hourly.first.from, a.start);
    expect(a.hourly.last.to, a.end);
    for (var i = 1; i < a.hourly.length; i++) {
      expect(a.hourly[i].from, a.hourly[i - 1].to);
    }
    expect(a.hourly.fold(Duration.zero, (d, h) => d + h.covered), a.elapsed);

    // The first two hours are full; the tail is partial.
    expect(a.hourly[0].isPartial, isFalse);
    expect(a.hourly[2].isPartial, isTrue);
    expect(a.hourly[2].covered.inMinutes, 20);

    // Handouts run 08:11–09:10, so they straddle the first two rows.
    expect(a.hourly[0].handouts, 49);
    expect(a.hourly[1].handouts, 11);
    expect(a.hourly[2].handouts, 0);

    // A partial row still reports a comparable full-hour rate.
    expect(a.hourly[2].ratePerFullHour, 0);
    expect(a.hourly[0].ratePerFullHour, closeTo(49, 0.5));
  });

  test('a stop straddling an hour boundary is split across both rows', () {
    final pts = <Wpt>[];
    // Park in one place from 08:00 to 10:00 with no handouts at all.
    for (var m = 0; m <= 120; m++) {
      pts.add(trkpt(base, lon, utcAt(m)));
    }
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
    );

    // One long break, split 60/60 across the two clock hours it covers.
    expect(a.stops.single.kind, TEStopKind.breakTime);
    expect(a.hourly, hasLength(2));
    expect(a.hourly[0].breakTime.inMinutes, 60);
    expect(a.hourly[1].breakTime.inMinutes, 60);
    // And the split adds back up to the shift total.
    expect(
        a.hourly.fold(Duration.zero, (d, h) => d + h.breakTime), a.breakTime);
  });
}

/// The reason all of this exists: a logger that stops writing trackpoints the
/// moment the distributor stops walking. On that device a stop leaves NO
/// points at all — the silence between two trackpoints in the same place is
/// the only evidence there is.
void _motionTriggeredTests() {
  const base = -33.9;
  const lon = 18.42;

  /// Walks in for [walkMin] minutes at ~6 km/h, then the logger goes quiet for
  /// [silentMin] minutes, then writes again [metresAway] from where it stopped
  /// and walks on.
  TETrackAnalysis run({
    int walkMin = 10,
    int silentMin = 40,
    double metresAway = 8,
    int handoutsDuringSilence = 0,
  }) {
    final pts = <Wpt>[];
    // 10 s cadence while moving, which is what these devices actually do.
    for (var s = 0; s <= walkMin * 60; s += 10) {
      pts.add(trkpt(
          base + (s / 60) * 0.0009, lon, utcAt(0).add(Duration(seconds: s))));
    }
    final standAt = base + walkMin * 0.0009;
    final resumeAt = utcAt(walkMin + silentMin);
    // …silence… then the log picks up again a few metres away.
    for (var s = 0; s <= 600; s += 10) {
      pts.add(trkpt(
        standAt + metresAway / 111000 + (s / 60) * 0.0009,
        lon,
        resumeAt.add(Duration(seconds: s)),
      ));
    }

    final wpts = [
      for (var k = 0; k < handoutsDuringSilence; k++)
        Wpt(
          lat: standAt,
          lon: lon,
          time: utcAt(walkMin).add(Duration(seconds: 30 + k * 30)),
        ),
    ];

    return TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: wpts,
    );
  }

  test('silence in one place is a stop, not a hole in the data', () {
    final a = run(handoutsDuringSilence: 40);

    expect(a.stops, hasLength(1));
    final stop = a.stops.single;
    expect(stop.fromSilence, isTrue);
    expect(stop.duration.inMinutes, 40);
    expect(stop.handouts, 40);
    expect(stop.kind, TEStopKind.handout);

    // The silence is working time, NOT an unexplained gap.
    expect(a.gaps, isEmpty);
    expect(a.gapTime, Duration.zero);
    expect(a.workingStopTime.inMinutes, 40);
    expect(a.trackedTime, a.elapsed);
    expect(a.isMotionTriggered, isTrue);
  });

  test('silence with no handouts is a break, not working time', () {
    final a = run(silentMin: 35);
    expect(a.stops.single.kind, TEStopKind.breakTime);
    expect(a.workingStopTime, Duration.zero);
    expect(a.breakTime.inMinutes, 35);
    expect(a.gaps, isEmpty);
  });

  test('silence that ends somewhere else is still an unexplained gap', () {
    // 2 km away at the far end: they went somewhere the log cannot account for.
    final a = run(metresAway: 2000);
    expect(a.stops, isEmpty);
    expect(a.gaps, hasLength(1));
    expect(a.gaps.single.jumpKm, closeTo(2.0, 0.1));
    expect(a.gapTime.inMinutes, 40);
    // Ground we did not see them cover is not added to the distance.
    expect(a.distanceKm, closeTo(2.0, 0.2));
  });

  test('the last point before a silence still reads as walking', () {
    // The regression this guards: averaging the final moving point together
    // with the 40-minute dwell that follows reports a walker as stationary.
    final a = run();
    final dwell = a.longIntervals.single;
    final lastMoving = a.samples
        .lastWhere((s) => !s.synthetic && !s.time.isAfter(dwell.start));
    expect(lastMoving.time, dwell.start);
    expect(lastMoving.speedKmh, closeTo(6, 1.5));

    final firstAfter = a.samples
        .firstWhere((s) => !s.synthetic && !s.time.isBefore(dwell.end));
    expect(firstAfter.speedKmh, closeTo(6, 1.5));
  });

  test('the speed series is pinned to zero across a silence', () {
    // With no trackpoints inside a dwell, a chart drawn straight from the
    // last moving point to the next one claims the distributor walked for
    // forty minutes. Zero-speed markers at each end stop that.
    final a = run();
    final dwell = a.longIntervals.single;
    final inside = a.samples
        .where((s) => s.time.isAfter(dwell.start) && s.time.isBefore(dwell.end))
        .toList();

    expect(inside, hasLength(2));
    expect(inside.every((s) => s.synthetic), isTrue);
    expect(inside.every((s) => s.speedKmh == 0), isTrue);
    // They bracket the silence, so the line is flat on the floor across it.
    expect(inside.first.time.difference(dwell.start).inSeconds, 1);
    expect(dwell.end.difference(inside.last.time).inSeconds, 1);
    // And they add no distance — the distributor did not go anywhere.
    expect(inside.first.cumulativeKm, inside.last.cumulativeKm);

    // Markers are not trackpoints and must not be counted as such.
    expect(a.trackpointCount, a.samples.length - 2);
  });

  test('reports the logger cadence and the long silences behind it', () {
    final a = run(handoutsDuringSilence: 12);

    // 10 s between points while moving is the device's working cadence; the
    // one 40-minute silence must not drag the median around.
    expect(a.medianIntervalSeconds, 10);

    expect(a.longIntervals, hasLength(1));
    final iv = a.longIntervals.single;
    expect(iv.kind, TEIntervalKind.dwell);
    expect(iv.duration.inMinutes, 40);
    expect(iv.handouts, 12);
    expect(iv.displacementM, closeTo(8, 2));
    expect(iv.impliedSpeedKmh, lessThan(0.1));
    expect(a.longestInterval, same(iv));

    // Histogram: everything in the 5–10 s bucket bar the single long one.
    final tenSec = a.intervalHistogram
        .firstWhere((b) => b.fromSeconds == 10 && b.toSeconds == 30);
    expect(tenSec.count, a.trackpointCount - 2);
    expect(a.intervalHistogram.last.fromSeconds, 900);
    expect(a.intervalHistogram.last.count, 1);
    // The histogram covers every interval between real trackpoints.
    expect(a.intervalHistogram.fold<int>(0, (n, b) => n + b.count),
        a.trackpointCount - 1);
  });

  test('a stray drift point does not split one wait into two stops', () {
    // 30 minutes of standing, broken by a single point the logger coughs out
    // halfway through, a few metres from where the distributor is standing.
    final pts = <Wpt>[];
    for (var s = 0; s <= 300; s += 10) {
      pts.add(trkpt(
          base + (s / 60) * 0.0009, lon, utcAt(0).add(Duration(seconds: s))));
    }
    final standAt = base + 5 * 0.0009;
    pts.add(trkpt(standAt + 0.0001, lon, utcAt(20))); // stray drift point
    pts.add(trkpt(standAt, lon, utcAt(35))); // log resumes
    for (var s = 10; s <= 300; s += 10) {
      pts.add(trkpt(standAt + (s / 60) * 0.0009, lon,
          utcAt(35).add(Duration(seconds: s))));
    }

    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
    );

    expect(a.longIntervals, hasLength(2)); // the raw evidence is still two
    expect(a.stops, hasLength(1)); // but it was one wait
    expect(a.stops.single.duration.inMinutes, 30);
    expect(a.stops.single.kind, TEStopKind.breakTime);
  });

  test('a sparse but genuine walking leg is not called a gap', () {
    // Three minutes between points, 250 m apart: a thin log of a real walk,
    // well under the 4-minute gap threshold.
    final pts = <Wpt>[
      trkpt(base, lon, utcAt(0)),
      trkpt(base + 0.00225, lon, utcAt(3)),
      trkpt(base + 0.0045, lon, utcAt(6)),
    ];
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
    );
    expect(a.gaps, isEmpty);
    expect(a.stops, isEmpty);
    expect(a.longIntervals, isEmpty);
    // Its distance counts towards the round.
    expect(a.distanceKm, closeTo(0.5, 0.05));
  });
}

/// The two getters behind the client-facing "Shift summary": [bestHour] and
/// [TETrackAnalysis.breakAndLunchTime].
void _summaryGettersTests() {
  const base = -33.9;
  const lon = 18.42;

  test('bestHour picks the clock hour with the most handouts', () {
    final pts = <Wpt>[];
    for (var m = 0; m <= 130; m++) {
      pts.add(trkpt(base + (m.isEven ? 0.00008 : -0.00008), lon, utcAt(m)));
    }
    // 08:xx (SAST) gets 10 handouts, 09:xx gets 40 — 09:xx should win even
    // though it starts later.
    final wpts = [
      for (var m = 5; m < 15; m++) Wpt(lat: base, lon: lon, time: utcAt(m)),
      for (var m = 65; m < 105; m++) Wpt(lat: base, lon: lon, time: utcAt(m)),
    ];
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: wpts,
    );
    expect(a.bestHour, isNotNull);
    expect(a.bestHour!.hourStart.hour, 9);
    expect(a.bestHour!.handouts, 40);
  });

  test('bestHour is null with no tracklog window to divide into hours', () {
    expect(TETrackAnalysis.empty.bestHour, isNull);
  });

  test('breakAndLunchTime counts a long stop with zero handouts', () {
    final pts = <Wpt>[
      for (var m = 0; m <= 25; m++) trkpt(base, lon, utcAt(m)),
    ];
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
    );
    expect(a.stops.single.duration.inMinutes, 25);
    expect(a.stops.single.handouts, 0);
    expect(a.breakAndLunchTime, a.stops.single.duration);
    expect(a.breakAndLunchTime.inMinutes, 25);
  });

  test('breakAndLunchTime ignores a stop shorter than the 10-minute floor', () {
    final pts = <Wpt>[
      for (var m = 0; m <= 6; m++) trkpt(base, lon, utcAt(m)),
    ];
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
    );
    expect(a.stops.single.duration.inMinutes, 6);
    expect(a.breakAndLunchTime, Duration.zero);
  });

  test(
      'breakAndLunchTime excludes a long stop that has ANY handouts, even '
      'a single sparse one — a working stop is not a break', () {
    final pts = <Wpt>[
      for (var m = 0; m <= 25; m++) trkpt(base, lon, utcAt(m)),
    ];
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      // One press, 15 minutes into a 25-minute stop.
      waypoints: [Wpt(lat: base, lon: lon, time: utcAt(15))],
    );
    expect(a.stops.single.kind, TEStopKind.handout);
    expect(a.stops.single.duration.inMinutes, 25);
    expect(a.breakAndLunchTime, Duration.zero);
  });

  test('breakAndLunchTime sums several separate long stops', () {
    // 12 minutes at `base`, an 800 m walk (never a time gap — every point is
    // a minute apart, so nothing here is silence-based), then 12 more
    // minutes at the far end. Two stops, both zero handouts.
    final pts = <Wpt>[
      for (var m = 0; m <= 12; m++) trkpt(base, lon, utcAt(m)),
      for (var m = 13; m <= 20; m++)
        trkpt(base + (m - 12) * 0.0009, lon, utcAt(m)),
      for (var m = 21; m <= 32; m++) trkpt(base + 8 * 0.0009, lon, utcAt(m)),
    ];
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
    );
    expect(a.stops, hasLength(2));
    expect(a.stops[0].duration.inMinutes, 12);
    expect(a.stops[1].duration.inMinutes, 12);
    expect(a.breakAndLunchTime.inMinutes, 24); // 12 + 12
  });

  test(
      'breakAndLunchTime stays at its own 10-minute floor even when the '
      'analyst turns the breakThreshold slider up for their own review', () {
    final pts = <Wpt>[
      for (var m = 0; m <= 12; m++) trkpt(base, lon, utcAt(m)),
    ];
    // An analyst reviewing the raw data might widen the threshold so only
    // REALLY long stops get labelled "break" on the detailed chart — but
    // that must never quietly change the number a client report shows.
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
      config: const TEAnalysisConfig(breakThreshold: Duration(minutes: 25)),
    );
    // Below the widened config threshold, so the detailed view would have
    // labelled it "idle" rather than "break" — but the summary still counts
    // it, because it never reads that config value at all.
    expect(a.stops.single.kind, TEStopKind.idle);
    expect(a.breakAndLunchTime.inMinutes, 12);
  });

  test(
      'the default breakThreshold agrees with the 10-minute floor out of '
      'the box — a client report and the detailed chart start in sync', () {
    final pts = <Wpt>[
      for (var m = 0; m <= 12; m++) trkpt(base, lon, utcAt(m)),
    ];
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
    );
    expect(a.config.breakThreshold, TETrackAnalysis.breakAndLunchFloor);
    expect(a.stops.single.kind, TEStopKind.breakTime);
    expect(a.breakAndLunchTime.inMinutes, 12);
  });

  test(
      'a stop just under 10 minutes with no handouts reads as idle, not '
      'a break', () {
    final pts = <Wpt>[
      for (var m = 0; m <= 8; m++) trkpt(base, lon, utcAt(m)),
    ];
    final a = TETrackAnalysis.from(
      tracks: [
        Trk(trksegs: [Trkseg(trkpts: pts)])
      ],
      waypoints: const [],
    );
    expect(a.stops.single.kind, TEStopKind.idle);
    expect(a.breakAndLunchTime, Duration.zero);
  });
}
