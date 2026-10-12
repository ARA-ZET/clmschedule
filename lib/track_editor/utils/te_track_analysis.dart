// track_editor/utils/te_track_analysis.dart
//
// Turns a distributor's raw GPX tracklog + handout waypoints into the derived
// series and segments the Analysis view renders.
//
// Domain model: distributors hand flyers to motorists at intersections. The
// logger writes a trackpoint continuously for the whole shift; the distributor
// presses a button for every flyer handed out, which writes a waypoint. So:
//
//   * tracklog  -> where they were and how fast they were moving
//   * waypoints -> when a flyer actually left their hand
//
// Two kinds of logger show up in the wild and the analysis handles both:
//
//   * A **continuous** logger writes a point every few seconds no matter what,
//     so standing still reads as a dense cluster of points going nowhere.
//   * A **motion-triggered** logger stops writing when the distributor stops
//     moving, so standing still reads as a long GAP between two points that
//     are in the same place. On that device the silence IS the evidence.
//
// So the primary signal is the interval between consecutive trackpoints, paired
// with how far the distributor moved across it — see [TEInterval].
//
// The interesting questions ("was he working the robot or sitting in the shade?")
// all fall out of overlaying the two: a long stationary stretch WITH waypoints is
// productive time at an intersection; the same stretch WITHOUT waypoints is a
// break, a wait for the light to change, or an idle distributor.
//
// All timestamps are converted to SAST civil time via [toScheduleCivil] so the
// analysis reads the same wall clock on every device — matching the waypoint
// times shown on the map.
import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';

import '../../utils/schedule_time.dart';

/// Tunable thresholds for the analysis. Defaults are set for on-foot flyer
/// distribution at traffic intersections in Cape Town.
class TEAnalysisConfig {
  /// A run of trackpoints that never leaves this radius counts as "stationary".
  /// Sized to cover an intersection island plus normal GPS drift.
  final double stopRadiusM;

  /// A stationary run must last at least this long to be reported as a stop.
  /// Below this it is just a pause at a kerb and stays part of the walk.
  final Duration minStop;

  /// A stop with no handouts at least this long is reported as a break or
  /// lunch rather than as short idle time (standing at a light, waiting for
  /// a gap in traffic). Defaults to 10 minutes — the same floor the
  /// client-facing "Break and lunch" summary tile uses (see
  /// [TETrackAnalysis.breakAndLunchFloor]), so the detailed view and the
  /// summary agree out of the box.
  final Duration breakThreshold;

  /// How long a silence must run before a change of position counts as an
  /// unexplained gap rather than as ordinary sparse logging. Only applies
  /// when the distributor ended up more than [stopRadiusM] away — a silence
  /// that begins and ends in the same place is a dwell at any length past
  /// [minStop], however short.
  final Duration gapThreshold;

  /// Width of the centred window used to smooth instantaneous GPS speed.
  final Duration speedWindow;

  /// Width of the handout-rate histogram buckets.
  final Duration bucket;

  /// Waypoints within this radius of each other are merged into one hotspot,
  /// which in practice is one intersection.
  final double hotspotRadiusM;

  const TEAnalysisConfig({
    this.stopRadiusM = 35,
    this.minStop = const Duration(minutes: 2),
    this.breakThreshold = const Duration(minutes: 10),
    this.gapThreshold = const Duration(minutes: 4),
    this.speedWindow = const Duration(seconds: 45),
    this.bucket = const Duration(minutes: 15),
    this.hotspotRadiusM = 60,
  });

  TEAnalysisConfig copyWith({
    double? stopRadiusM,
    Duration? minStop,
    Duration? breakThreshold,
    Duration? gapThreshold,
    Duration? speedWindow,
    Duration? bucket,
    double? hotspotRadiusM,
  }) {
    return TEAnalysisConfig(
      stopRadiusM: stopRadiusM ?? this.stopRadiusM,
      minStop: minStop ?? this.minStop,
      breakThreshold: breakThreshold ?? this.breakThreshold,
      gapThreshold: gapThreshold ?? this.gapThreshold,
      speedWindow: speedWindow ?? this.speedWindow,
      bucket: bucket ?? this.bucket,
      hotspotRadiusM: hotspotRadiusM ?? this.hotspotRadiusM,
    );
  }
}

/// One trackpoint after cleaning, with the derived series attached.
class TESample {
  /// SAST civil time.
  final DateTime time;
  final double lat;
  final double lon;

  /// Smoothed ground speed in km/h (see [TEAnalysisConfig.speedWindow]).
  final double speedKmh;

  /// Distance walked from the first sample, in km.
  final double cumulativeKm;

  /// True for the zero-speed markers inserted at each end of a dwell.
  ///
  /// A motion-triggered logger writes NO points while the distributor stands
  /// still, so the raw series jumps straight from "walking at 5 km/h" to
  /// "walking at 5 km/h" across forty minutes of standing — and a chart drawn
  /// through those two points claims they walked the whole time. These
  /// markers put the speed on the floor where it belongs. They are not
  /// trackpoints and are excluded from [TETrackAnalysis.trackpointCount].
  final bool synthetic;

  const TESample({
    required this.time,
    required this.lat,
    required this.lon,
    required this.speedKmh,
    required this.cumulativeKm,
    this.synthetic = false,
  });

  LatLng get position => LatLng(lat, lon);
}

/// What the distributor was doing during a stationary stretch.
enum TEStopKind {
  /// Standing still AND recording handouts — working an intersection.
  handout,

  /// Standing still with no handouts, shorter than the break threshold —
  /// waiting for traffic, walking back to the island, admin.
  idle,

  /// Standing still with no handouts for a long stretch — lunch or a break.
  breakTime,
}

extension TEStopKindLabel on TEStopKind {
  String get label => switch (this) {
        TEStopKind.handout => 'Working',
        TEStopKind.idle => 'Idle / waiting',
        TEStopKind.breakTime => 'Break',
      };
}

/// A stationary stretch of the shift.
class TEStop {
  final DateTime start;
  final DateTime end;
  final LatLng centre;

  /// Handout waypoints recorded between [start] and [end].
  final int handouts;
  final TEStopKind kind;

  /// True when this stop was found because the logger went SILENT — the
  /// device only writes points while moving, so the absence of trackpoints
  /// is what proves the distributor stood still. False when it was found the
  /// other way, from a dense cluster of points going nowhere.
  final bool fromSilence;

  const TEStop({
    required this.start,
    required this.end,
    required this.centre,
    required this.handouts,
    required this.kind,
    this.fromSilence = false,
  });

  Duration get duration => end.difference(start);

  /// Handouts per hour sustained during this stop; null when it is too short
  /// to extrapolate honestly.
  double? get handoutsPerHour {
    final s = duration.inSeconds;
    if (s < 60) return null;
    return handouts / (s / 3600);
  }
}

/// What a long silence between two trackpoints means.
enum TEIntervalKind {
  /// The logger's normal cadence — nothing to explain.
  normal,

  /// A long silence that ends up (near enough) where it started. On a
  /// motion-triggered logger this is the distributor standing still; on a
  /// continuous one it is the device dropping samples while parked. Either
  /// way, they did not go anywhere.
  dwell,

  /// A long silence that ends up somewhere else. Ground was covered that the
  /// tracklog cannot account for — logger switched off, flat battery, or no
  /// signal. This is the only kind that is genuinely unknown.
  gap,
}

extension TEIntervalKindLabel on TEIntervalKind {
  String get label => switch (this) {
        TEIntervalKind.normal => 'Logging normally',
        TEIntervalKind.dwell => 'Standing still',
        TEIntervalKind.gap => 'Unexplained',
      };
}

/// The silence between two consecutive trackpoints.
class TEInterval {
  final DateTime start;
  final DateTime end;
  final LatLng from;
  final LatLng to;

  /// Straight-line distance between the two points, in metres.
  final double displacementM;

  /// Handouts recorded during the silence. A dwell full of handouts is a
  /// distributor working an intersection; an empty one is a distributor
  /// standing about.
  final int handouts;

  final TEIntervalKind kind;

  const TEInterval({
    required this.start,
    required this.end,
    required this.from,
    required this.to,
    required this.displacementM,
    required this.handouts,
    required this.kind,
  });

  Duration get duration => end.difference(start);

  /// Average speed implied by going [displacementM] in [duration] — the test
  /// of whether a long silence could plausibly have been a walk.
  double? get impliedSpeedKmh {
    final s = duration.inMilliseconds / 1000;
    if (s <= 0) return null;
    return (displacementM / 1000) / (s / 3600);
  }
}

/// One column of the trackpoint-interval histogram.
class TEIntervalBucket {
  /// Inclusive lower bound, in seconds.
  final int fromSeconds;

  /// Exclusive upper bound, in seconds; null means "and up".
  final int? toSeconds;
  final int count;

  const TEIntervalBucket({
    required this.fromSeconds,
    this.toSeconds,
    required this.count,
  });

  String get label {
    String f(int s) => s < 60
        ? '${s}s'
        : (s % 3600 == 0 ? '${s ~/ 3600}h' : '${s ~/ 60}m');
    if (toSeconds == null) return '${f(fromSeconds)}+';
    if (fromSeconds == 0) return '<${f(toSeconds!)}';
    return '${f(fromSeconds)}–${f(toSeconds!)}';
  }
}

/// A hole in the tracklog — logger switched off, battery dead, or no signal.
class TEGap {
  final DateTime start;
  final DateTime end;

  /// How far the position jumped across the gap, in km.
  final double jumpKm;

  const TEGap({required this.start, required this.end, required this.jumpKm});

  Duration get duration => end.difference(start);
}

/// One column of the handout-rate histogram.
class TEBucket {
  final DateTime start;
  final DateTime end;
  final int handouts;

  const TEBucket({
    required this.start,
    required this.end,
    required this.handouts,
  });
}

/// One clock hour of the shift — 08:00–09:00, 09:00–10:00, and so on.
///
/// The first and last rows are usually partial: a shift that starts at 08:12
/// covers only 48 minutes of the 08:00 hour, so [covered] is what the rates
/// are computed against, not a flat 60 minutes.
class TEHourStat {
  /// The clock hour this row belongs to (minutes and seconds zeroed).
  final DateTime hourStart;

  /// The part of the hour the shift actually covers.
  final DateTime from;
  final DateTime to;

  final int handouts;
  final Duration working;
  final Duration idle;
  final Duration breakTime;
  final Duration gap;

  const TEHourStat({
    required this.hourStart,
    required this.from,
    required this.to,
    required this.handouts,
    required this.working,
    required this.idle,
    required this.breakTime,
    required this.gap,
  });

  DateTime get hourEnd => hourStart.add(const Duration(hours: 1));

  /// How much of this clock hour the shift covers.
  Duration get covered => to.difference(from);

  /// True when the shift only covers part of the hour — the row's numbers
  /// cannot be compared with a full hour's without saying so.
  bool get isPartial => covered < const Duration(minutes: 59, seconds: 30);

  /// Walking time: whatever the hour covers that was not a stop or a hole.
  Duration get moving {
    final m = covered - working - idle - breakTime - gap;
    return m.isNegative ? Duration.zero : m;
  }

  /// Handouts extrapolated to a full hour, so a partial first or last hour
  /// can still be compared with the rest. Null when there is too little of
  /// the hour to extrapolate honestly.
  double? get ratePerFullHour {
    if (covered.inSeconds < 300) return null;
    return handouts / (covered.inSeconds / 3600);
  }
}

/// A cluster of handout waypoints — in practice, one intersection.
class TEHotspot {
  final LatLng centre;
  final int handouts;
  final DateTime first;
  final DateTime last;

  const TEHotspot({
    required this.centre,
    required this.handouts,
    required this.first,
    required this.last,
  });

  Duration get span => last.difference(first);
}

/// Everything the Analysis view needs, computed once per (tab, config).
class TETrackAnalysis {
  final TEAnalysisConfig config;

  /// Cleaned, time-ordered trackpoints with speed + cumulative distance.
  final List<TESample> samples;

  /// SAST civil times of every handout that carried a timestamp, sorted.
  final List<DateTime> handoutTimes;

  /// Positions of the timed handouts, index-aligned with [handoutTimes].
  final List<LatLng> handoutPositions;

  /// Handout waypoints with no `<time>` in the GPX. They still count towards
  /// the total but cannot be placed on the time axis.
  final int untimedHandouts;

  final List<TEStop> stops;
  final List<TEGap> gaps;

  /// Every silence between trackpoints long enough to be worth explaining,
  /// oldest first. This is the raw evidence behind [stops] on a
  /// motion-triggered logger.
  final List<TEInterval> longIntervals;

  /// Distribution of the interval between consecutive trackpoints — what this
  /// particular device actually does.
  final List<TEIntervalBucket> intervalHistogram;

  /// Median seconds between trackpoints: the logger's working cadence, robust
  /// to the long silences at either tail.
  final double medianIntervalSeconds;
  final List<TEBucket> buckets;

  /// Per-clock-hour breakdown, one row per hour the shift touches.
  final List<TEHourStat> hourly;
  final List<TEHotspot> hotspots;

  /// Left/right edge of the time axis: the union of the tracklog window and
  /// the handout window, so nothing recorded on the day falls off the chart.
  final DateTime start;
  final DateTime end;

  const TETrackAnalysis._({
    required this.config,
    required this.samples,
    required this.handoutTimes,
    required this.handoutPositions,
    required this.untimedHandouts,
    required this.stops,
    required this.gaps,
    required this.longIntervals,
    required this.intervalHistogram,
    required this.medianIntervalSeconds,
    required this.buckets,
    required this.hourly,
    required this.hotspots,
    required this.start,
    required this.end,
  });

  bool get isEmpty => samples.isEmpty && handoutTimes.isEmpty;

  // ── Headline numbers ──────────────────────────────────────────────────────

  int get totalHandouts => handoutTimes.length + untimedHandouts;

  /// First-to-last elapsed time across the whole shift, gaps included.
  Duration get elapsed => end.difference(start);

  Duration get gapTime =>
      gaps.fold(Duration.zero, (a, g) => a + g.duration);

  /// Elapsed time the logger was actually recording.
  Duration get trackedTime {
    final t = elapsed - gapTime;
    return t.isNegative ? Duration.zero : t;
  }

  Duration _stopTime(TEStopKind kind) => stops
      .where((s) => s.kind == kind)
      .fold(Duration.zero, (a, s) => a + s.duration);

  Duration get workingStopTime => _stopTime(TEStopKind.handout);
  Duration get idleTime => _stopTime(TEStopKind.idle);
  Duration get breakTime => _stopTime(TEStopKind.breakTime);

  Duration get stationaryTime => workingStopTime + idleTime + breakTime;

  /// Stationary time proven by the logger going quiet rather than by a
  /// cluster of points. On a motion-triggered device this is essentially all
  /// of [stationaryTime]; on a continuous one it should be near zero.
  Duration get silentStandingTime => stops
      .where((s) => s.fromSilence)
      .fold(Duration.zero, (a, s) => a + s.duration);

  /// True when this logger clearly stops writing while the distributor stands
  /// still — most of the stationary time was found from silence. Worth
  /// saying out loud, because it changes how the whole page should be read.
  bool get isMotionTriggered =>
      stationaryTime.inSeconds > 0 &&
      silentStandingTime.inSeconds * 2 > stationaryTime.inSeconds;

  /// The longest silence between two trackpoints.
  TEInterval? get longestInterval {
    if (longIntervals.isEmpty) return null;
    return longIntervals.reduce((a, b) => b.duration > a.duration ? b : a);
  }

  /// Time spent walking between stops.
  Duration get movingTime {
    final t = trackedTime - stationaryTime;
    return t.isNegative ? Duration.zero : t;
  }

  double get distanceKm =>
      samples.isEmpty ? 0 : samples.last.cumulativeKm;

  /// Handouts recorded while parked at a working stop.
  int get handoutsAtStops => stops
      .where((s) => s.kind == TEStopKind.handout)
      .fold(0, (a, s) => a + s.handouts);

  /// Handouts recorded on the move — walking the row of cars, or between
  /// intersections.
  int get handoutsOnTheMove {
    final n = handoutTimes.length - handoutsAtStops;
    return n < 0 ? 0 : n;
  }

  double? _perHour(int count, Duration d) {
    if (d.inSeconds < 60) return null;
    return count / (d.inSeconds / 3600);
  }

  /// Handouts per hour averaged over the whole shift.
  double? get ratePerHourOverall => _perHour(handoutTimes.length, elapsed);

  /// Handouts per hour while actually parked at an intersection — the rate
  /// the distributor sustains when working, stripped of walking and breaks.
  double? get ratePerHourWorking => _perHour(handoutsAtStops, workingStopTime);

  DateTime? get firstHandout =>
      handoutTimes.isEmpty ? null : handoutTimes.first;
  DateTime? get lastHandout => handoutTimes.isEmpty ? null : handoutTimes.last;

  /// Dead time between the tracklog starting and the first flyer going out.
  Duration? get warmUp => firstHandout?.difference(start);

  /// Dead time between the last flyer and the tracklog stopping.
  Duration? get windDown =>
      lastHandout == null ? null : end.difference(lastHandout!);

  TEStop? get longestStop {
    if (stops.isEmpty) return null;
    return stops.reduce((a, b) => b.duration > a.duration ? b : a);
  }

  TEBucket? get busiestBucket {
    if (buckets.isEmpty) return null;
    return buckets.reduce((a, b) => b.handouts > a.handouts ? b : a);
  }

  /// The single clock hour with the most handouts — a client report's
  /// headline number ("their best hour was 10–11am, 196 flyers").
  TEHourStat? get bestHour {
    if (hourly.isEmpty) return null;
    return hourly.reduce((a, b) => b.handouts > a.handouts ? b : a);
  }

  /// Genuine breaks and lunch: any stop with no handout activity that ran
  /// [breakAndLunchFloor] or longer — found either from a silence in the
  /// tracklog (no points at all) or from a cluster of points going nowhere
  /// (speed at or near zero), whichever the logger happened to produce.
  ///
  /// Deliberately a fixed floor rather than [TEAnalysisConfig.breakThreshold]
  /// — that slider only re-labels the detailed stop-by-stop chart/legend for
  /// an analyst's own review, and must not silently change the number that
  /// goes out to a client. Both start at the same 10 minutes, but only this
  /// one is guaranteed to stay there.
  static const Duration breakAndLunchFloor = Duration(minutes: 10);

  Duration get breakAndLunchTime => stops
      .where((s) =>
          s.kind != TEStopKind.handout && s.duration >= breakAndLunchFloor)
      .fold(Duration.zero, (a, s) => a + s.duration);

  /// Trackpoints actually present in the GPX, excluding the zero-speed
  /// markers woven in around each dwell.
  int get trackpointCount =>
      samples.where((s) => !s.synthetic).length;

  /// Peak smoothed speed, used to scale the speed axis.
  double get maxSpeedKmh =>
      samples.fold(0.0, (a, s) => math.max(a, s.speedKmh));

  /// Number of handouts recorded at or before [t].
  int cumulativeAt(DateTime t) {
    var lo = 0;
    var hi = handoutTimes.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (handoutTimes[mid].isAfter(t)) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// Sample nearest to [t], or null when there is no tracklog.
  TESample? sampleAt(DateTime t) {
    if (samples.isEmpty) return null;
    var lo = 0;
    var hi = samples.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].time.isBefore(t)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) {
      final prev = samples[lo - 1];
      final cur = samples[lo];
      final dPrev = t.difference(prev.time).abs();
      final dCur = cur.time.difference(t).abs();
      if (dPrev < dCur) return prev;
    }
    return samples[lo];
  }

  /// The stop covering [t], if any.
  TEStop? stopAt(DateTime t) {
    for (final s in stops) {
      if (!t.isBefore(s.start) && !t.isAfter(s.end)) return s;
    }
    return null;
  }

  /// True when a genuine gap sits between two consecutive sample times — the
  /// signal to lift the pen rather than draw a line through unknown ground.
  bool spansGap(DateTime a, DateTime b) {
    for (final g in gaps) {
      if (!g.start.isBefore(a) && !g.end.isAfter(b)) return true;
    }
    return false;
  }

  /// The gap covering [t], if any.
  TEGap? gapAt(DateTime t) {
    for (final g in gaps) {
      if (!t.isBefore(g.start) && !t.isAfter(g.end)) return g;
    }
    return null;
  }

  // ── Construction ──────────────────────────────────────────────────────────

  /// An analysis with nothing in it — used before any GPX is loaded.
  /// [DateTime] has no const constructor, so this is built lazily rather than
  /// declared const.
  static TETrackAnalysis get empty {
    final t = DateTime.fromMillisecondsSinceEpoch(0);
    return TETrackAnalysis._(
      config: const TEAnalysisConfig(),
      samples: const [],
      handoutTimes: const [],
      handoutPositions: const [],
      untimedHandouts: 0,
      stops: const [],
      gaps: const [],
      longIntervals: const [],
      intervalHistogram: const [],
      medianIntervalSeconds: 0,
      buckets: const [],
      hourly: const [],
      hotspots: const [],
      start: t,
      end: t,
    );
  }

  factory TETrackAnalysis.from({
    required List<Trk> tracks,
    required List<Wpt> waypoints,
    TEAnalysisConfig config = const TEAnalysisConfig(),
  }) {
    // ── 1. Clean the tracklog ───────────────────────────────────────────────
    final raw = <_Pt>[];
    for (final trk in tracks) {
      for (final seg in trk.trksegs) {
        for (final p in seg.trkpts) {
          final lat = p.lat, lon = p.lon, t = p.time;
          if (lat == null || lon == null || t == null) continue;
          raw.add(_Pt(toScheduleCivil(t), lat, lon));
        }
      }
    }
    raw.sort((a, b) => a.time.compareTo(b.time));
    // Drop duplicate timestamps — some loggers repeat the last fix.
    final pts = <_Pt>[];
    for (final p in raw) {
      if (pts.isNotEmpty && !p.time.isAfter(pts.last.time)) continue;
      pts.add(p);
    }

    // ── 2. Handouts ─────────────────────────────────────────────────────────
    final timed = <_Pt>[];
    var untimed = 0;
    for (final w in waypoints) {
      if (w.time == null) {
        untimed++;
        continue;
      }
      timed.add(_Pt(toScheduleCivil(w.time!), w.lat ?? 0, w.lon ?? 0));
    }
    timed.sort((a, b) => a.time.compareTo(b.time));
    final handoutTimes = timed.map((p) => p.time).toList(growable: false);
    final handoutPositions =
        timed.map((p) => LatLng(p.lat, p.lon)).toList(growable: false);

    if (pts.isEmpty && handoutTimes.isEmpty) return empty;

    // ── 3. Axis window: union of tracklog and handouts ──────────────────────
    DateTime start;
    DateTime end;
    if (pts.isEmpty) {
      start = handoutTimes.first;
      end = handoutTimes.last;
    } else if (handoutTimes.isEmpty) {
      start = pts.first.time;
      end = pts.last.time;
    } else {
      start = pts.first.time.isBefore(handoutTimes.first)
          ? pts.first.time
          : handoutTimes.first;
      end = pts.last.time.isAfter(handoutTimes.last)
          ? pts.last.time
          : handoutTimes.last;
    }
    if (!end.isAfter(start)) end = start.add(const Duration(minutes: 1));

    // ── 4. Classify every interval, then distance + gaps ────────────────────
    //
    // This is the heart of it. A long silence is a dwell when the distributor
    // is still in the same place at the far end of it, and a genuine gap when
    // they are not. On a motion-triggered logger nearly every stop arrives
    // here as a dwell, because the device simply stopped writing.
    final kinds = List<TEIntervalKind>.filled(
        pts.isEmpty ? 0 : pts.length - 1, TEIntervalKind.normal);
    final cum = List<double>.filled(pts.length, 0);
    final gaps = <TEGap>[];
    final longIntervals = <TEInterval>[];
    final deltas = <int>[]; // seconds between consecutive points

    // Contiguous runs, split wherever the tracklog cannot be trusted to
    // describe continuous movement, so radius clustering never stitches
    // across one.
    final runStarts = <int>[if (pts.isNotEmpty) 0];

    for (var i = 1; i < pts.length; i++) {
      final d =
          haversineM(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
      final dt = pts[i].time.difference(pts[i - 1].time);
      deltas.add(dt.inSeconds);

      // Stayed put for long enough -> they were standing there.
      // Went somewhere, over a silence too long to be ordinary sparse
      // logging -> ground we cannot account for.
      // Everything else, including a slow leg on a thin log, is normal
      // movement and keeps its distance.
      final stayedPut = d <= config.stopRadiusM;
      final TEIntervalKind kind;
      if (stayedPut && dt >= config.minStop) {
        kind = TEIntervalKind.dwell;
      } else if (!stayedPut && dt >= config.gapThreshold) {
        kind = TEIntervalKind.gap;
      } else {
        kind = TEIntervalKind.normal;
      }
      kinds[i - 1] = kind;

      if (kind != TEIntervalKind.normal) {
        runStarts.add(i);
        longIntervals.add(TEInterval(
          start: pts[i - 1].time,
          end: pts[i].time,
          from: LatLng(pts[i - 1].lat, pts[i - 1].lon),
          to: LatLng(pts[i].lat, pts[i].lon),
          displacementM: d,
          handouts: _countBetween(handoutTimes, pts[i - 1].time, pts[i].time),
          kind: kind,
        ));
      }

      if (kind == TEIntervalKind.gap) {
        gaps.add(TEGap(
          start: pts[i - 1].time,
          end: pts[i].time,
          jumpKm: d / 1000,
        ));
        // The straight line across a gap is not ground we saw them cover.
        cum[i] = cum[i - 1];
      } else {
        // A dwell's few metres are GPS drift; counting them is harmless and
        // keeps the distance series monotonic.
        cum[i] = cum[i - 1] + d / 1000;
      }
    }

    // ── 5. Smoothed speed over a centred time window ────────────────────────
    final speeds = List<double>.filled(pts.length, 0);
    final half = config.speedWindow ~/ 2;
    var lo = 0, hi = 0;
    for (var i = 0; i < pts.length; i++) {
      final from = pts[i].time.subtract(half);
      final to = pts[i].time.add(half);
      while (lo < i && pts[lo].time.isBefore(from)) {
        lo++;
      }
      while (hi + 1 < pts.length && !pts[hi + 1].time.isAfter(to)) {
        hi++;
      }
      // Local copies: `lo`/`hi` are monotonic cursors shared across the loop
      // and must not be dragged backwards by the fallback below.
      var w0 = lo, w1 = hi;
      if (w1 <= w0) {
        // The smoothing window is narrower than this logger's sample
        // interval, so it caught only the point itself. Reach out to the
        // neighbours — but only across intervals that describe real
        // movement. Averaging the last moving point together with the
        // twenty-minute dwell that follows it would report a walking
        // distributor as standing still.
        if (i > 0 && kinds[i - 1] == TEIntervalKind.normal) w0 = i - 1;
        if (i < pts.length - 1 && kinds[i] == TEIntervalKind.normal) {
          w1 = i + 1;
        }
        if (w1 <= w0) {
          // Both sides are silence: the distributor was standing here.
          speeds[i] = 0;
          continue;
        }
      }
      final secs = pts[w1].time.difference(pts[w0].time).inMilliseconds / 1000;
      if (secs <= 0) {
        speeds[i] = 0;
        continue;
      }
      final km = cum[w1] - cum[w0];
      speeds[i] = (km / (secs / 3600)).clamp(0, 60);
    }

    final samples = <TESample>[];
    for (var i = 0; i < pts.length; i++) {
      samples.add(TESample(
        time: pts[i].time,
        lat: pts[i].lat,
        lon: pts[i].lon,
        speedKmh: speeds[i],
        cumulativeKm: cum[i],
      ));
      // Pin the speed to zero across a dwell. Inset by a second at each end
      // so the drop and the recovery are visibly instant, and so no two
      // samples share a timestamp. Dwells run at least [minStop], so the
      // two-second inset can never invert the pair.
      if (i < pts.length - 1 && kinds[i] == TEIntervalKind.dwell) {
        const inset = Duration(seconds: 1);
        for (final t in [
          pts[i].time.add(inset),
          pts[i + 1].time.subtract(inset),
        ]) {
          samples.add(TESample(
            time: t,
            lat: pts[i].lat,
            lon: pts[i].lon,
            speedKmh: 0,
            cumulativeKm: cum[i],
            synthetic: true,
          ));
        }
      }
    }

    // ── 6. Stops, from both directions ──────────────────────────────────────
    final stops = _detectStops(
        pts, runStarts, kinds, longIntervals, handoutTimes, config);

    // ── 7. Rate histogram ───────────────────────────────────────────────────
    final buckets = <TEBucket>[];
    final bucketMs = config.bucket.inMilliseconds;
    if (bucketMs > 0) {
      var cursor = start;
      var idx = 0;
      while (cursor.isBefore(end)) {
        final next = cursor.add(config.bucket);
        var n = 0;
        while (idx < handoutTimes.length && handoutTimes[idx].isBefore(next)) {
          n++;
          idx++;
        }
        buckets.add(TEBucket(start: cursor, end: next, handouts: n));
        cursor = next;
      }
    }

    // ── 8. Handout hotspots ─────────────────────────────────────────────────
    final hotspots = _clusterHandouts(timed, config.hotspotRadiusM);

    return TETrackAnalysis._(
      config: config,
      samples: samples,
      handoutTimes: handoutTimes,
      handoutPositions: handoutPositions,
      untimedHandouts: untimed,
      stops: stops,
      gaps: gaps,
      longIntervals: longIntervals,
      intervalHistogram: _intervalHistogram(deltas),
      medianIntervalSeconds: _median(deltas),
      buckets: buckets,
      hourly: _hourly(start, end, handoutTimes, stops, gaps),
      hotspots: hotspots,
      start: start,
      end: end,
    );
  }

  /// Stops arrive from two directions, because two kinds of logger exist.
  ///
  ///   1. **Silence.** A dwell interval — a long wait between two trackpoints
  ///      that begins and ends in the same place — IS a stop. This is the only
  ///      evidence a motion-triggered logger leaves behind.
  ///   2. **Clustering.** Within each run of normally-logged points, a stretch
  ///      that never leaves [TEAnalysisConfig.stopRadiusM] of its anchor for
  ///      at least [TEAnalysisConfig.minStop] is a stop. This is what a
  ///      continuous logger leaves behind.
  ///
  /// Both are collected, then merged, so a tab full of files from either kind
  /// of device — or a mix — reads the same way.
  static List<TEStop> _detectStops(
    List<_Pt> pts,
    List<int> runStarts,
    List<TEIntervalKind> kinds,
    List<TEInterval> longIntervals,
    List<DateTime> handoutTimes,
    TEAnalysisConfig config,
  ) {
    final raw = <TEStop>[];

    // ── 1. Silence ──────────────────────────────────────────────────────────
    for (final iv in longIntervals) {
      if (iv.kind != TEIntervalKind.dwell) continue;
      raw.add(TEStop(
        start: iv.start,
        end: iv.end,
        // They stood at the near end; the far point is the same spot plus
        // whatever the GPS drifted.
        centre: LatLng(
          (iv.from.latitude + iv.to.latitude) / 2,
          (iv.from.longitude + iv.to.longitude) / 2,
        ),
        handouts: iv.handouts,
        kind: _classify(iv.handouts, iv.duration, config),
        fromSilence: true,
      ));
    }

    // ── 2. Clustering, within each normally-logged run ──────────────────────
    for (var r = 0; r < runStarts.length; r++) {
      final runFrom = runStarts[r];
      final runTo =
          r + 1 < runStarts.length ? runStarts[r + 1] - 1 : pts.length - 1;
      var i = runFrom;
      while (i <= runTo) {
        var j = i;
        while (j + 1 <= runTo &&
            haversineM(pts[i].lat, pts[i].lon, pts[j + 1].lat,
                    pts[j + 1].lon) <=
                config.stopRadiusM) {
          j++;
        }
        final span = pts[j].time.difference(pts[i].time);
        if (span >= config.minStop) {
          var lat = 0.0, lon = 0.0;
          for (var k = i; k <= j; k++) {
            lat += pts[k].lat;
            lon += pts[k].lon;
          }
          final n = j - i + 1;
          final handouts =
              _countBetween(handoutTimes, pts[i].time, pts[j].time);
          raw.add(TEStop(
            start: pts[i].time,
            end: pts[j].time,
            centre: LatLng(lat / n, lon / n),
            handouts: handouts,
            kind: _classify(handouts, span, config),
          ));
          i = j + 1;
        } else {
          i++;
        }
      }
    }

    return _merge(raw, handoutTimes, config);
  }

  static TEStopKind _classify(
      int handouts, Duration span, TEAnalysisConfig config) {
    if (handouts > 0) return TEStopKind.handout;
    return span >= config.breakThreshold
        ? TEStopKind.breakTime
        : TEStopKind.idle;
  }

  /// Fold overlapping or touching stops into one. A dwell that ends exactly
  /// where a cluster begins is one stop the distributor took, not two, and
  /// double-counting it would inflate every stationary total on the page.
  static List<TEStop> _merge(
    List<TEStop> raw,
    List<DateTime> handoutTimes,
    TEAnalysisConfig config,
  ) {
    if (raw.isEmpty) return const [];
    raw.sort((a, b) => a.start.compareTo(b.start));
    final out = <TEStop>[raw.first];
    for (var i = 1; i < raw.length; i++) {
      final cur = raw[i];
      final prev = out.last;
      // A motion-triggered logger sometimes coughs out a stray drift point
      // in the middle of a long wait, splitting one stop into two. Bridge
      // them when the gap between is shorter than a stop could be and they
      // are in the same place — otherwise the round reads as twice as many
      // stops, each half as long as the distributor actually stood there.
      final apart = cur.start.difference(prev.end);
      final sameSpot = haversineM(prev.centre.latitude, prev.centre.longitude,
              cur.centre.latitude, cur.centre.longitude) <=
          config.stopRadiusM;
      if (apart > Duration.zero && !(apart < config.minStop && sameSpot)) {
        out.add(cur);
        continue;
      }
      final end = cur.end.isAfter(prev.end) ? cur.end : prev.end;
      final handouts = _countBetween(handoutTimes, prev.start, end);
      out[out.length - 1] = TEStop(
        start: prev.start,
        end: end,
        // Keep the centre of whichever half ran longer — the merged stop is
        // reported where the distributor actually spent the time.
        centre: prev.duration >= cur.duration ? prev.centre : cur.centre,
        handouts: handouts,
        kind: _classify(handouts, end.difference(prev.start), config),
        fromSilence: prev.fromSilence || cur.fromSilence,
      );
    }
    return out;
  }

  /// Interval histogram over fixed, human-readable buckets. The boundaries are
  /// chosen to separate a logger's normal cadence (seconds) from the silences
  /// that mean something (minutes).
  static List<TEIntervalBucket> _intervalHistogram(List<int> deltas) {
    if (deltas.isEmpty) return const [];
    const bounds = [0, 5, 10, 30, 60, 120, 300, 900];
    final counts = List<int>.filled(bounds.length, 0);
    for (final d in deltas) {
      var slot = bounds.length - 1;
      for (var i = 1; i < bounds.length; i++) {
        if (d < bounds[i]) {
          slot = i - 1;
          break;
        }
      }
      counts[slot]++;
    }
    return [
      for (var i = 0; i < bounds.length; i++)
        TEIntervalBucket(
          fromSeconds: bounds[i],
          toSeconds: i + 1 < bounds.length ? bounds[i + 1] : null,
          count: counts[i],
        ),
    ];
  }

  static double _median(List<int> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid].toDouble()
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// Slice the shift into clock hours and attribute every handout, stop and
  /// logging hole to the hour it falls in. Stops that straddle an hour
  /// boundary are split across both rows rather than landing wholly in one.
  static List<TEHourStat> _hourly(
    DateTime start,
    DateTime end,
    List<DateTime> handoutTimes,
    List<TEStop> stops,
    List<TEGap> gaps,
  ) {
    final out = <TEHourStat>[];
    var hour = DateTime(start.year, start.month, start.day, start.hour);
    while (hour.isBefore(end)) {
      final hourEnd = hour.add(const Duration(hours: 1));
      final from = hour.isBefore(start) ? start : hour;
      final to = hourEnd.isAfter(end) ? end : hourEnd;

      Duration timeIn(TEStopKind kind) => stops
          .where((s) => s.kind == kind)
          .fold(Duration.zero, (a, s) => a + _overlap(s.start, s.end, from, to));

      out.add(TEHourStat(
        hourStart: hour,
        from: from,
        to: to,
        // Half-open [from, to) so a press landing exactly on an hour
        // boundary is counted once, in the hour it starts. The final row
        // closes at the end of the shift and does include its endpoint.
        handouts: _countHalfOpen(handoutTimes, from, to,
            includeEnd: !to.isBefore(end)),
        working: timeIn(TEStopKind.handout),
        idle: timeIn(TEStopKind.idle),
        breakTime: timeIn(TEStopKind.breakTime),
        gap: gaps.fold(
            Duration.zero, (a, g) => a + _overlap(g.start, g.end, from, to)),
      ));
      hour = hourEnd;
    }
    return out;
  }

  static int _countHalfOpen(
    List<DateTime> sorted,
    DateTime from,
    DateTime to, {
    required bool includeEnd,
  }) {
    var n = 0;
    for (final t in sorted) {
      if (t.isBefore(from)) continue;
      if (t.isAfter(to)) break;
      if (t.isAtSameMomentAs(to) && !includeEnd) break;
      n++;
    }
    return n;
  }

  /// Length of the intersection of two time intervals.
  static Duration _overlap(
      DateTime a1, DateTime a2, DateTime b1, DateTime b2) {
    final lo = a1.isAfter(b1) ? a1 : b1;
    final hi = a2.isBefore(b2) ? a2 : b2;
    return hi.isAfter(lo) ? hi.difference(lo) : Duration.zero;
  }

  static int _countBetween(List<DateTime> sorted, DateTime a, DateTime b) {
    var n = 0;
    for (final t in sorted) {
      if (t.isBefore(a)) continue;
      if (t.isAfter(b)) break;
      n++;
    }
    return n;
  }

  /// Greedy spatial clustering of handout waypoints — good enough to collapse
  /// a shift's worth of button presses into the handful of intersections the
  /// distributor actually worked.
  static List<TEHotspot> _clusterHandouts(List<_Pt> timed, double radiusM) {
    final used = List<bool>.filled(timed.length, false);
    final out = <TEHotspot>[];
    for (var i = 0; i < timed.length; i++) {
      if (used[i]) continue;
      used[i] = true;
      var lat = timed[i].lat, lon = timed[i].lon;
      var n = 1;
      var first = timed[i].time, last = timed[i].time;
      for (var j = i + 1; j < timed.length; j++) {
        if (used[j]) continue;
        if (haversineM(lat / n, lon / n, timed[j].lat, timed[j].lon) <=
            radiusM) {
          used[j] = true;
          lat += timed[j].lat;
          lon += timed[j].lon;
          n++;
          if (timed[j].time.isBefore(first)) first = timed[j].time;
          if (timed[j].time.isAfter(last)) last = timed[j].time;
        }
      }
      out.add(TEHotspot(
        centre: LatLng(lat / n, lon / n),
        handouts: n,
        first: first,
        last: last,
      ));
    }
    out.sort((a, b) => b.handouts.compareTo(a.handouts));
    return out;
  }
}

/// Great-circle distance in metres.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class _Pt {
  final DateTime time;
  final double lat;
  final double lon;
  const _Pt(this.time, this.lat, this.lon);
}
