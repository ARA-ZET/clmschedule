import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/collection_job.dart';
import '../providers/job_type_provider.dart';
import '../providers/schedule_bookings_provider.dart';
import '../utils/appointment_slots.dart';
import '../utils/schedule_booking_slots.dart';
import '../utils/vehicle_colors.dart';

// The main Schedule grid's Collection Schedule column, after every date.
// The distributor rows double as half-hour time rows (the slot is written
// under each name: row 1 = 08:00–08:30 …), the header shows one initial per
// van, and each cell has one lane per van, coloured where that van is
// booked. Just blocks — hover for the details. See schedule_booking_slots.

/// Horizontal inset of the lanes, shared by the header and the cells so
/// each initial sits over its lane.
const double _kInset = 3;
const double _kLaneGap = 3;

String _typeLabel(CollectionJob b) =>
    JobTypeProvider.instance?.getJobTypeLabel(b.jobType) ?? b.jobType;

/// "10:00–11:30 · Mrs Smith · Junk Collection".
String _bookingLine(CollectionJob b) {
  final client = b.clients.where((c) => c.trim().isNotEmpty).join(', ');
  return [
    slotRange(b.timeSlot, b.timeSlots),
    if (client.isNotEmpty)
      client
    else if (b.location.trim().isNotEmpty)
      b.location.trim(),
    _typeLabel(b),
  ].join(' · ');
}

/// "Hyundai\n10:00–11:30 · Mrs Smith · Junk Collection" (one line each).
String _vanTooltip(VehicleType van, Iterable<CollectionJob> bookings,
    {String? note}) {
  return [
    van.displayName,
    ...bookings.map(_bookingLine),
    if (note != null) note,
  ].join('\n');
}

/// The column's header: one coloured initial per van (H M N), faded when
/// that van has no booking on [date]. Hover an initial for its bookings.
class BookingColumnHeader extends riverpod.ConsumerWidget {
  final DateTime date;
  final bool isToday;

  const BookingColumnHeader({
    super.key,
    required this.date,
    required this.isToday,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final theme = Theme.of(context);
    final day = ref
        .watch(dayBookingsRiverpod(DateTime(date.year, date.month, date.day)));
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 1),
      color: isToday ? theme.primaryColor.withValues(alpha: 0.2) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _kInset - 1),
        child: Row(
          children: [
            for (final (i, van) in VehicleType.values.indexed) ...[
              if (i > 0) const SizedBox(width: _kLaneGap),
              Expanded(child: _initial(theme, van, day.forVehicle(van))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _initial(
      ThemeData theme, VehicleType van, List<CollectionJob> bookings) {
    final color = vehicleColor(van);
    return Tooltip(
      message: bookings.isEmpty
          ? '${van.displayName}: free'
          : _vanTooltip(van, bookings),
      child: Center(
        child: Text(
          van.displayName.substring(0, 1),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: bookings.isEmpty ? color.withValues(alpha: 0.3) : color,
          ),
        ),
      ),
    );
  }
}

/// One grid row of the column: the half hour that row stands for, one lane
/// per van, coloured where the van is booked. Rows past the time rows (more
/// than 16 distributors) are blank. Sized by the row like the job cards.
///
/// Built for a grid of hundreds of these: one painter draws all three lanes,
/// and hover areas are only added over lanes that have something to say.
class BookingColumnCell extends riverpod.ConsumerWidget {
  final DateTime date;

  /// The grid row (0 = first distributor = 08:00–08:30).
  final int row;

  /// How many rows carry a time slot ([bookingTimeRows]).
  final int timeRows;

  const BookingColumnCell({
    super.key,
    required this.date,
    required this.row,
    required this.timeRows,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    if (row >= timeRows) return const SizedBox.shrink();
    // Value-equal per day: only this date's cells repaint on a change.
    final day = ref
        .watch(dayBookingsRiverpod(DateTime(date.year, date.month, date.day)));
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final slots = [
      for (final van in VehicleType.values) carSlotFor(day, van, row, timeRows),
    ];
    final painter = _CellPainter(
      lanes: [
        for (final (i, van) in VehicleType.values.indexed)
          _laneLook(vehicleColor(van), slots[i]),
      ],
      track: onSurface.withValues(alpha: 0.05),
      // A faint line on the hour (rows starting on :00), so the lanes read
      // as a timetable without labels in the cells.
      hourLine: rowSlotStart(row) % 60 == 0
          ? onSurface.withValues(alpha: 0.12)
          : null,
    );

    // Most cells are empty: just the painter.
    if (slots.every((s) => s.isEmpty)) {
      return CustomPaint(painter: painter, child: const SizedBox.expand());
    }
    final slotLabel = rowSlotLabel(row) ?? '';
    return CustomPaint(
      painter: painter,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _kInset),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, van) in VehicleType.values.indexed) ...[
              if (i > 0) const SizedBox(width: _kLaneGap),
              Expanded(
                child: slots[i].isEmpty
                    ? const SizedBox.shrink()
                    : Tooltip(
                        message: _laneTooltip(van, slots[i], slotLabel),
                        child: const SizedBox.expand(),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _laneTooltip(VehicleType van, CarSlot slot, String slotLabel) => [
      if (slot.isBooked)
        _vanTooltip(van, slot.bookings,
            note: slot.clash ? 'Two bookings at $slotLabel' : null),
      if (slot.earlier.isNotEmpty)
        _vanTooltip(van, slot.earlier, note: 'Before 08:00'),
      if (slot.later.isNotEmpty)
        _vanTooltip(van, slot.later, note: 'Later in the day'),
    ].join('\n\n');

/// What one van lane shows in one row. A record, so it is value-equal and
/// the painter repaints only when a lane actually changes.
typedef _LaneLook = ({
  Color color,
  bool booked,
  bool joinsAbove,
  bool joinsBelow,
  bool cutTop,
  bool cutBottom,
  bool clash,
  bool arrowUp,
  bool arrowDown,
});

_LaneLook _laneLook(Color color, CarSlot slot) => (
      color: color,
      booked: slot.isBooked,
      joinsAbove: slot.joinsAbove,
      joinsBelow: slot.joinsBelow,
      cutTop: slot.cutTop,
      cutBottom: slot.cutBottom,
      clash: slot.clash,
      arrowUp: slot.earlier.isNotEmpty,
      arrowDown: slot.later.isNotEmpty,
    );

/// One row of the column: for each van lane a faint track, the booked block
/// (joined to the rows above/below when the booking carries on; pointed
/// where it was cut at 08:00 or the last time row), a red outline on a
/// clash, and small arrows for bookings wholly before or after the rows.
class _CellPainter extends CustomPainter {
  final List<_LaneLook> lanes;
  final Color track;
  final Color? hourLine;

  _CellPainter({
    required this.lanes,
    required this.track,
    required this.hourLine,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = lanes.length;
    final laneWidth = (size.width - 2 * _kInset - (n - 1) * _kLaneGap) / n;
    if (laneWidth <= 0 || size.height <= 0) return;
    final laneSize = Size(laneWidth, size.height);
    for (var i = 0; i < n; i++) {
      canvas.save();
      canvas.translate(_kInset + i * (laneWidth + _kLaneGap), 0);
      _paintLane(canvas, laneSize, lanes[i]);
      canvas.restore();
    }
  }

  void _paintLane(Canvas canvas, Size size, _LaneLook lane) {
    final w = size.width;
    final h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    final line = hourLine;
    if (line != null) {
      canvas.drawLine(
          Offset.zero,
          Offset(w, 0),
          Paint()
            ..color = line
            ..strokeWidth = 1);
    }

    if (lane.booked) {
      // A block that starts or ends in this row leaves a small gap there;
      // one that carries on runs to the cell edge and meets its neighbour.
      final gap = math.min(2.0, h * 0.08);
      final top = lane.joinsAbove || lane.cutTop ? 0.0 : gap;
      final bottom = lane.joinsBelow || lane.cutBottom ? h : h - gap;
      final r = math.min(3.0, w / 3);
      final tip = math.min(w / 2, math.max(2.0, (bottom - top) * 0.25));
      final path = Path();
      if (lane.cutTop) {
        path
          ..moveTo(0, top + tip)
          ..lineTo(w / 2, top)
          ..lineTo(w, top + tip);
      } else if (lane.joinsAbove) {
        path
          ..moveTo(0, top)
          ..lineTo(w, top);
      } else {
        path
          ..moveTo(0, top + r)
          ..quadraticBezierTo(0, top, r, top)
          ..lineTo(w - r, top)
          ..quadraticBezierTo(w, top, w, top + r);
      }
      if (lane.cutBottom) {
        path
          ..lineTo(w, bottom - tip)
          ..lineTo(w / 2, bottom)
          ..lineTo(0, bottom - tip);
      } else if (lane.joinsBelow) {
        path
          ..lineTo(w, bottom)
          ..lineTo(0, bottom);
      } else {
        path
          ..lineTo(w, bottom - r)
          ..quadraticBezierTo(w, bottom, w - r, bottom)
          ..lineTo(r, bottom)
          ..quadraticBezierTo(0, bottom, 0, bottom - r);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = lane.color);
      if (lane.clash) {
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.red.shade700
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    // Wholly before 08:00 / after the last time row: a small arrow at that
    // edge of the lane, pointing out of the timetable.
    final aw = math.min(w * 0.7, 10.0);
    final ah = math.min(h * 0.3, aw * 0.6);
    final arrow = Paint()..color = lane.color;
    if (lane.arrowUp) {
      canvas.drawPath(
        Path()
          ..moveTo(w / 2 - aw / 2, ah + 1)
          ..lineTo(w / 2, 1)
          ..lineTo(w / 2 + aw / 2, ah + 1)
          ..close(),
        arrow,
      );
    }
    if (lane.arrowDown) {
      canvas.drawPath(
        Path()
          ..moveTo(w / 2 - aw / 2, h - ah - 1)
          ..lineTo(w / 2, h - 1)
          ..lineTo(w / 2 + aw / 2, h - ah - 1)
          ..close(),
        arrow,
      );
    }
  }

  @override
  bool shouldRepaint(_CellPainter old) =>
      old.track != track ||
      old.hourLine != hourLine ||
      !listEquals(old.lanes, lanes);
}

/// A distributor's name cell: the name row exactly as before, and under it
/// the half hour the row stands for in the Collection Schedule columns.
///
/// The name is never shrunk (user rule 2026-11-18: names stay readable).
/// Collapsed rows are tall enough for both; if a row is still too short
/// (zoomed far out) the time label is left out instead.
class NameWithSlotLabel extends StatelessWidget {
  final Widget name;
  final String? slotLabel;

  const NameWithSlotLabel(
      {super.key, required this.name, required this.slotLabel});

  // Name + label height per text style. Every name cell asks on every grid
  // rebuild, so measure once per style instead of laying text out each time.
  static final Map<(TextStyle?, TextStyle?, TextScaler, TextDirection),
      double> _neededCache = {};

  static double _neededHeight(TextStyle? name, TextStyle? label,
      TextScaler scaler, TextDirection direction) {
    double lineHeight(TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: '08', style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    if (_neededCache.length > 32) _neededCache.clear(); // theme/zoom churn
    return _neededCache.putIfAbsent((name, label, scaler, direction),
        () => lineHeight(name) + lineHeight(label));
  }

  @override
  Widget build(BuildContext context) {
    final label = slotLabel;
    if (label == null) return name;
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.1,
    );
    // The name row's tallest text is the "1." index in titleMedium.
    final needed = _neededHeight(
      theme.textTheme.titleMedium,
      labelStyle,
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
    );

    return LayoutBuilder(builder: (context, box) {
      if (box.maxHeight < needed) return name;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          name,
          Text(label, style: labelStyle, maxLines: 1),
        ],
      );
    });
  }
}
