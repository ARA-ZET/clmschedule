import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../utils/shared_drop_points.dart' show distanceMeters;

/// Booked appointments (collections, window cleaning… — see
/// `DropsheetTask.appointmentTime`) in route timing.
///
/// A driver who gets to a booked stop early waits: the job starts at the
/// booked time and everything after it moves later. One who can't make it
/// in time is late by the difference, flagged on the task. Every timing path
/// (Optimise, Calculate, the Leave / Arrive time replays) uses these rules.

/// "10:00" → 600; null when blank or malformed.
int? hhmmToMinutes(String? hhmm) {
  final parts = (hhmm ?? '').trim().split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
    return null;
  }
  return h * 60 + m;
}

/// When work at a stop reached at [arrival] starts, given its booking.
({DateTime start, int waitMinutes, int lateMinutes}) meetAppointment(
    DateTime arrival, int? appointmentMinutes) {
  if (appointmentMinutes == null) {
    return (start: arrival, waitMinutes: 0, lateMinutes: 0);
  }
  final booked = DateTime(arrival.year, arrival.month, arrival.day)
      .add(Duration(minutes: appointmentMinutes));
  if (arrival.isBefore(booked)) {
    return (
      start: booked,
      waitMinutes: booked.difference(arrival).inMinutes,
      lateMinutes: 0,
    );
  }
  return (
    start: arrival,
    waitMinutes: 0,
    lateMinutes: arrival.difference(booked).inMinutes,
  );
}

/// Driving time between two points without a Directions call: straight
/// line × 1.4 for the road network, at 35 km/h across town. Only used to
/// judge whether a stop still fits in before a booking.
int estimateDriveSeconds(LatLng a, LatLng b) =>
    (distanceMeters(a, b) * 1.4 / (35000 / 3600)).round();

/// A stop the optimiser could drive to next.
typedef NextStopOption = ({
  int travelSeconds,
  int serviceMinutes,
  int? appointmentMinutes,
  LatLng position,
});

/// Which of [options] to drive to next at [clock], or null when none.
///
/// Without bookings: the nearest. With them, the earliest pending booking
/// is the deadline: the nearest unbooked stop is taken only if the driver
/// can still get from it to that booking in time; otherwise, or once the
/// booking is due, the driver goes to the booking (waiting there if early).
int? chooseNextStop(List<NextStopOption> options, DateTime clock) {
  if (options.isEmpty) return null;
  int nearestOf(Iterable<int> indexes) => indexes.reduce((a, b) =>
      options[b].travelSeconds < options[a].travelSeconds ? b : a);

  final all = List.generate(options.length, (i) => i);
  final booked = all.where((i) => options[i].appointmentMinutes != null);
  if (booked.isEmpty) return nearestOf(all);

  // The earliest booking (nearest first on a tie) sets the deadline.
  final next = booked.reduce((a, b) {
    final ta = options[a].appointmentMinutes!;
    final tb = options[b].appointmentMinutes!;
    if (ta != tb) return tb < ta ? b : a;
    return options[b].travelSeconds < options[a].travelSeconds ? b : a;
  });
  final deadline = DateTime(clock.year, clock.month, clock.day)
      .add(Duration(minutes: options[next].appointmentMinutes!));

  final unbooked =
      all.where((i) => options[i].appointmentMinutes == null).toList();
  if (unbooked.isEmpty) return next;
  // Due now: going anywhere else first makes the driver late.
  final direct = clock.add(Duration(seconds: options[next].travelSeconds));
  if (!direct.isBefore(deadline)) return next;

  final fits = unbooked.where((i) {
    final o = options[i];
    final done = clock.add(Duration(
        seconds: o.travelSeconds +
            o.serviceMinutes * 60 +
            estimateDriveSeconds(o.position, options[next].position)));
    return !done.isAfter(deadline);
  });
  return fits.isEmpty ? next : nearestOf(fits);
}

/// One stop of a fixed-order run: the leg driven to reach it, the time
/// spent there and its booking (minutes after midnight), if any.
typedef TimedStop = ({int legSeconds, int serviceMinutes, int? appointment});

/// Times for a fixed-order run.
typedef RunTimes = ({
  List<int> startSeconds, // work starts, seconds after midnight
  List<int> waitMinutes,
  List<int> lateMinutes,
  int endSeconds, // back at the office (after [returnLegSeconds])
});

/// Times for [stops] driven in order, leaving at [departSeconds] (seconds
/// after midnight). Work at each stop starts at the later of arrival and
/// its booking.
RunTimes timeRunForward(List<TimedStop> stops, int departSeconds,
    {int returnLegSeconds = 0}) {
  final starts = <int>[];
  final waits = <int>[];
  final lates = <int>[];
  var clock = departSeconds;
  for (final s in stops) {
    clock += s.legSeconds;
    final booked = s.appointment == null ? null : s.appointment! * 60;
    var wait = 0;
    var late = 0;
    if (booked != null && clock < booked) {
      wait = (booked - clock) ~/ 60;
      clock = booked;
    } else if (booked != null) {
      late = (clock - booked) ~/ 60;
    }
    starts.add(clock);
    waits.add(wait);
    lates.add(late);
    clock += s.serviceMinutes * 60;
  }
  return (
    startSeconds: starts,
    waitMinutes: waits,
    lateMinutes: lates,
    endSeconds: clock + returnLegSeconds,
  );
}

/// Times for an afternoon run that should end back at the office at
/// [arriveSeconds]. Worked backwards from that target (the latest the run
/// can start); moved earlier when that would miss a booking; then timed
/// forwards, so a wait for a booking that can't be avoided makes the driver
/// back later than the target rather than a booking being missed.
RunTimes timeRunToArrive(
    List<TimedStop> stops, int arriveSeconds, int returnLegSeconds) {
  var total = returnLegSeconds;
  for (final s in stops) {
    total += s.legSeconds + s.serviceMinutes * 60;
  }
  final latestDepart = arriveSeconds - total;
  // Start earlier by the most any booking would be missed (times without
  // waiting, so each stop's arrival on the latest plan).
  var early = 0;
  var reached = latestDepart;
  for (final s in stops) {
    reached += s.legSeconds;
    if (s.appointment != null) {
      early = math.max(early, reached - s.appointment! * 60);
    }
    reached += s.serviceMinutes * 60;
  }
  return timeRunForward(stops, latestDepart - early,
      returnLegSeconds: returnLegSeconds);
}

/// "HH:mm" for [seconds] after midnight, clamped to the day.
String secondsToHHmm(int seconds) {
  final m = (seconds ~/ 60).clamp(0, 23 * 60 + 59);
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}
