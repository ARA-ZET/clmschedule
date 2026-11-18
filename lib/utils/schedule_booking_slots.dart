/// The main Schedule grid's Collection Schedule column.
///
/// The grid's distributor rows double as half-hour time rows for the vans:
/// row 1 is 08:00–08:30, row 2 is 08:30–09:00 … row 16 is 15:30–16:00 (the
/// time sits under each distributor's name). After every date comes a narrow
/// column with one lane per van; a van's lane is coloured in the rows its
/// bookings cover, like the Collection Schedule's own grid. Only dates from
/// today on have the column: it is for planning, not history.
///
/// Pure — no Flutter, no Firestore — so it is unit-tested directly.
library;

import 'dart:math' as math;

import '../models/collection_job.dart';
import 'appointment_slots.dart';

/// The time rows run 08:00 to 16:00: sixteen half hours.
const int kBookingWindowStart = 8 * 60;
const int kBookingWindowEnd = 16 * 60;
const int kMaxBookingTimeRows =
    (kBookingWindowEnd - kBookingWindowStart) ~/ kSlotMinutes;

/// How many of [rowCount] grid rows carry a time slot (at most 16).
int bookingTimeRows(int rowCount) =>
    math.max(0, math.min(rowCount, kMaxBookingTimeRows));

/// Start of grid row [row]'s half hour, in minutes after midnight.
int rowSlotStart(int row) => kBookingWindowStart + row * kSlotMinutes;

/// "08:00–08:30" for row 0; null for a row past the time rows.
String? rowSlotLabel(int row) => row >= 0 && row < kMaxBookingTimeRows
    ? slotRange(slotTime(rowSlotStart(row)), 1)
    : null;

/// One table column after the distributor names: the date it belongs to,
/// and whether it is that date's jobs column or its vans column.
typedef ScheduleGridColumn = ({int dateIndex, bool vans});

/// The grid's columns after the names. Every date keeps its jobs column; only
/// dates from [today] on get a vans column after it. The column is for
/// planning, so past days don't carry one (user rule 2026-11-18).
List<ScheduleGridColumn> scheduleGridColumns(
    List<DateTime> dates, DateTime today) {
  final from = DateTime(today.year, today.month, today.day);
  return [
    for (var i = 0; i < dates.length; i++) ...[
      (dateIndex: i, vans: false),
      if (!DateTime(dates[i].year, dates[i].month, dates[i].day).isBefore(from))
        (dateIndex: i, vans: true),
    ],
  ];
}

/// Whether [booking] holds its van: it has a start time and is not
/// cancelled. A start of 00:00 is `resolvedTimeSlot`'s "no time" — the
/// Collection Schedule grid leaves those out too.
bool occupiesVan(CollectionJob booking) {
  final start = slotMinutes(booking.timeSlot);
  if (start == null || start == 0) return false;
  return !booking.statusId.toLowerCase().contains('cancelled');
}

/// Start and end of [booking] in minutes after midnight; null without a time.
(int, int)? bookingMinutes(CollectionJob booking) {
  final start = slotMinutes(booking.timeSlot);
  if (start == null) return null;
  return (start, start + math.max(1, booking.timeSlots) * kSlotMinutes);
}

/// One day's van bookings, sorted by start time.
///
/// Value-equal over everything the column draws or says in a tooltip, so a
/// Job List change on another day (or to a field the column doesn't show)
/// does not repaint this day's cells.
class DayBookings {
  final List<CollectionJob> bookings;
  final List<String> _keys;

  DayBookings._(this.bookings, this._keys);

  factory DayBookings(Iterable<CollectionJob> bookings) {
    final sorted = bookings.toList()
      ..sort((a, b) {
        final am = bookingMinutes(a)?.$1 ?? 0;
        final bm = bookingMinutes(b)?.$1 ?? 0;
        if (am != bm) return am.compareTo(bm);
        final byVan = a.vehicleType.index.compareTo(b.vehicleType.index);
        return byVan != 0 ? byVan : a.id.compareTo(b.id);
      });
    return DayBookings._(
      List.unmodifiable(sorted),
      List.unmodifiable(sorted.map(_keyOf)),
    );
  }

  static final DayBookings empty = DayBookings(const []);

  static String _keyOf(CollectionJob b) => [
        b.id,
        b.vehicleType.name,
        b.timeSlot,
        b.timeSlots,
        b.jobType,
        b.statusId,
        b.location,
        b.clients.join('\u0001'),
      ].join('\u0000');

  bool get isEmpty => bookings.isEmpty;

  /// This day's bookings on [vehicle], by start time.
  List<CollectionJob> forVehicle(VehicleType vehicle) => [
        for (final b in bookings)
          if (b.vehicleType == vehicle) b
      ];

  @override
  bool operator ==(Object other) =>
      other is DayBookings &&
      other._keys.length == _keys.length &&
      Iterable<int>.generate(_keys.length)
          .every((i) => other._keys[i] == _keys[i]);

  @override
  int get hashCode => Object.hashAll(_keys);
}

/// What one van's lane shows in one time row.
class CarSlot {
  /// Bookings on this van covering this half hour, by start time.
  final List<CollectionJob> bookings;

  /// A booking here carries on from the row above / into the row below, so
  /// the block is drawn joined to its neighbour.
  final bool joinsAbove;
  final bool joinsBelow;

  /// A booking here began before 08:00 (first row) or runs past the last
  /// time row: that end is drawn pointed ("carries on").
  final bool cutTop;
  final bool cutBottom;

  /// Bookings wholly before 08:00 (first row only) or wholly after the last
  /// time row (last row only): drawn as a small arrow at that edge.
  final List<CollectionJob> earlier;
  final List<CollectionJob> later;

  const CarSlot({
    this.bookings = const [],
    this.joinsAbove = false,
    this.joinsBelow = false,
    this.cutTop = false,
    this.cutBottom = false,
    this.earlier = const [],
    this.later = const [],
  });

  static const CarSlot empty = CarSlot();

  bool get isBooked => bookings.isNotEmpty;

  /// Two bookings on one van in the same half hour.
  bool get clash => bookings.length > 1;

  bool get isEmpty => bookings.isEmpty && earlier.isEmpty && later.isEmpty;
}

/// What [car]'s lane shows in grid row [row] on [day], when the first
/// [timeRows] rows carry time slots (08:00 onwards).
CarSlot carSlotFor(
  DayBookings day,
  VehicleType car,
  int row,
  int timeRows,
) {
  if (row < 0 || row >= timeRows || day.isEmpty) return CarSlot.empty;
  final s0 = rowSlotStart(row);
  final e0 = s0 + kSlotMinutes;
  final windowEnd = rowSlotStart(timeRows);
  final isFirst = row == 0;
  final isLast = row == timeRows - 1;

  final covering = <CollectionJob>[];
  final earlier = <CollectionJob>[];
  final later = <CollectionJob>[];
  var fromAbove = false;
  var intoBelow = false;
  for (final b in day.bookings) {
    if (b.vehicleType != car || !occupiesVan(b)) continue;
    final m = bookingMinutes(b);
    if (m == null) continue;
    final (bs, be) = m;
    if (bs < e0 && s0 < be) {
      covering.add(b);
      if (bs < s0) fromAbove = true;
      if (be > e0) intoBelow = true;
    } else if (isFirst && be <= kBookingWindowStart) {
      earlier.add(b);
    } else if (isLast && bs >= windowEnd) {
      later.add(b);
    }
  }
  return CarSlot(
    bookings: covering,
    joinsAbove: fromAbove && !isFirst,
    joinsBelow: intoBelow && !isLast,
    cutTop: fromAbove && isFirst,
    cutBottom: intoBelow && isLast,
    earlier: earlier,
    later: later,
  );
}
