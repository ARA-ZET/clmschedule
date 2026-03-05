// track_editor/utils/te_track_stats.dart
//
// Computes summary statistics for a GPX track.
import 'dart:math' as math;
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';

class TETrackStats {
  /// Total distance in kilometres.
  final double distanceKm;

  /// Elapsed time from first to last trackpoint.
  final Duration? duration;

  /// Average speed in km/h (null when duration is zero or unknown).
  final double? avgSpeedKmh;

  /// Total number of trackpoints across all segments.
  final int trackpointCount;

  /// Timestamp of the first trackpoint with a time value.
  final DateTime? startTime;

  /// Timestamp of the last trackpoint with a time value.
  final DateTime? endTime;

  const TETrackStats({
    required this.distanceKm,
    required this.duration,
    required this.avgSpeedKmh,
    required this.trackpointCount,
    this.startTime,
    this.endTime,
  });

  /// Compute stats from a [Trk].
  factory TETrackStats.fromTrack(Trk trk) {
    final allPts = trk.trksegs.expand((seg) => seg.trkpts).toList();

    if (allPts.isEmpty) {
      return const TETrackStats(
          distanceKm: 0, duration: null, avgSpeedKmh: null, trackpointCount: 0);
    }

    // ── Distance ──────────────────────────────────────────────────────────
    double distM = 0;
    for (var i = 1; i < allPts.length; i++) {
      final a = allPts[i - 1];
      final b = allPts[i];
      if (a.lat != null && a.lon != null && b.lat != null && b.lon != null) {
        distM += _haversineM(a.lat!, a.lon!, b.lat!, b.lon!);
      }
    }

    // ── Duration / Start / End ────────────────────────────────────────────
    DateTime? first;
    DateTime? last;
    for (final pt in allPts) {
      if (pt.time != null) {
        first ??= pt.time;
        last = pt.time;
      }
    }
    final dur = (first != null && last != null && last.isAfter(first))
        ? last.difference(first)
        : null;

    // ── Speed ─────────────────────────────────────────────────────────────
    double? speed;
    if (dur != null && dur.inSeconds > 0) {
      speed = (distM / 1000) / (dur.inSeconds / 3600);
    }

    return TETrackStats(
      distanceKm: distM / 1000,
      duration: dur,
      avgSpeedKmh: speed,
      trackpointCount: allPts.length,
      startTime: first,
      endTime: last,
    );
  }

  // ── Haversine formula ─────────────────────────────────────────────────────
  static double _haversineM(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180;

  // ── Formatting helpers ────────────────────────────────────────────────────

  String get distanceLabel {
    if (distanceKm >= 1) return '${distanceKm.toStringAsFixed(2)} km';
    return '${(distanceKm * 1000).toStringAsFixed(0)} m';
  }

  String get durationLabel {
    final d = duration;
    if (d == null) return '—';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h}h ${m}m ${s}s' : '${m}m ${s}s';
  }

  String get speedLabel {
    final sp = avgSpeedKmh;
    if (sp == null) return '—';
    return '${sp.toStringAsFixed(1)} km/h';
  }

  static final _timeFmt = DateFormat('HH:mm:ss');

  String get startTimeLabel =>
      startTime != null ? _timeFmt.format(startTime!.toLocal()) : '—';

  String get endTimeLabel =>
      endTime != null ? _timeFmt.format(endTime!.toLocal()) : '—';
}
