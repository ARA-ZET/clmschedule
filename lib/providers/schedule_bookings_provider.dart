import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/collection_job.dart';
import '../utils/schedule_booking_slots.dart';
import 'collection_schedule_provider.dart';

/// The main Schedule grid's van bookings, by day.
///
/// No listener of its own: it is a view over the one Collection Schedule
/// sync ([collectionScheduleRiverpod]), which the grid asks to serve its
/// months via [CollectionScheduleProvider.showOnScheduleGrid]. So the
/// Collection Schedule tab and the grid always show the same bookings.

int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

/// Every served booking that holds its van, grouped by day. Recomputed only
/// when the sync rebuilds its jobs (a new list), not on its other
/// notifications (loading flags and the like).
final _bookingsByDayRiverpod =
    riverpod.Provider.autoDispose<Map<int, DayBookings>>((ref) {
  final jobs =
      ref.watch(collectionScheduleRiverpod.select((p) => p.allCollectionJobs));
  final byDay = <int, List<CollectionJob>>{};
  for (final booking in jobs) {
    if (!occupiesVan(booking)) continue;
    byDay.putIfAbsent(_dayKey(booking.date), () => []).add(booking);
  }
  return {
    for (final e in byDay.entries) e.key: DayBookings(e.value),
  };
});

/// The van bookings on [day] (a civil date; the time is ignored).
///
/// [DayBookings] is value-equal, so a change on another day leaves this
/// day's cells alone.
final dayBookingsRiverpod =
    riverpod.Provider.autoDispose.family<DayBookings, DateTime>((ref, day) {
  final key = _dayKey(day);
  return ref.watch(_bookingsByDayRiverpod
      .select((byDay) => byDay[key] ?? DayBookings.empty));
});
