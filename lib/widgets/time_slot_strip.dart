import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../utils/appointment_slots.dart';

/// Another job's booking shown on the strip (the same vehicle, the same
/// day): when it starts, how many half-hours, and who it is for.
typedef SlotBooking = ({String start, int slots, String label});

/// An appointment's time slot picked in one go, on the Collection
/// Schedule's half-hour rows (07:30 to 20:30):
///
/// * **drag** across the times to book them — press on the start, let go
///   on the end;
/// * **tap** a time to move the booking there, keeping its length (a first
///   booking is half an hour).
///
/// [booked] shades other bookings in orange; overlapping them is allowed.
class TimeSlotStrip extends StatefulWidget {
  const TimeSlotStrip({
    super.key,
    required this.start,
    required this.slots,
    required this.onChanged,
    this.booked = const [],
    this.enabled = true,
  });

  /// The booked start ("10:00"), or null when none is picked yet.
  final String? start;

  /// The booked length in half-hours, or null when none is picked yet.
  final int? slots;

  final List<SlotBooking> booked;
  final bool enabled;
  final void Function(String start, int slots) onChanged;

  @override
  State<TimeSlotStrip> createState() => _TimeSlotStripState();
}

class _TimeSlotStripState extends State<TimeSlotStrip> {
  static final List<String> _times = appointmentStartTimes();

  /// The drag in progress: where it started and where it is now (cells).
  int? _anchor;
  int? _current;

  int _cellAt(double dx, double width) =>
      (dx / (width / _times.length)).floor().clamp(0, _times.length - 1);

  void _tap(int cell) {
    final start = _times[cell];
    final most = slotLengthOptions(start).last;
    widget.onChanged(start, math.min(widget.slots ?? 1, most));
  }

  void _endDrag() {
    final a = _anchor;
    final c = _current;
    setState(() {
      _anchor = null;
      _current = null;
    });
    if (a == null || c == null) return;
    final lo = math.min(a, c);
    widget.onChanged(_times[lo], (a - c).abs() + 1);
  }

  bool _isSelected(int cell) {
    final a = _anchor;
    final c = _current;
    if (a != null && c != null) {
      return cell >= math.min(a, c) && cell <= math.max(a, c);
    }
    final start = widget.start;
    final slots = widget.slots;
    if (start == null || slots == null) return false;
    return slotsOverlap(_times[cell], 1, start, slots);
  }

  SlotBooking? _bookingAt(int cell) {
    for (final b in widget.booked) {
      if (slotsOverlap(_times[cell], 1, b.start, b.slots)) return b;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.enabled;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final cellWidth = width / _times.length;
      // A label every hour when there is room for it, else every two.
      final labelEveryMinutes = cellWidth >= 18 ? 60 : 120;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
            child: GestureDetector(
              key: const ValueKey('timeSlotStripCells'),
              behavior: HitTestBehavior.opaque,
              // The anchor is where the finger went down, not where the
              // drag was recognised a few pixels later.
              dragStartBehavior: DragStartBehavior.down,
              onTapUp: enabled
                  ? (d) => _tap(_cellAt(d.localPosition.dx, width))
                  : null,
              onHorizontalDragStart: enabled
                  ? (d) {
                      final cell = _cellAt(d.localPosition.dx, width);
                      setState(() {
                        _anchor = cell;
                        _current = cell;
                      });
                    }
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (d) {
                      final cell = _cellAt(d.localPosition.dx, width);
                      if (cell != _current) setState(() => _current = cell);
                    }
                  : null,
              onHorizontalDragEnd: enabled ? (_) => _endDrag() : null,
              onHorizontalDragCancel: enabled
                  ? () => setState(() {
                        _anchor = null;
                        _current = null;
                      })
                  : null,
              child: SizedBox(
                height: 34,
                child: Row(
                  children: [
                    for (var i = 0; i < _times.length; i++)
                      Expanded(child: _cell(i, theme)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 14,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < _times.length; i++)
                  if ((slotMinutes(_times[i])! % labelEveryMinutes) == 0)
                    Positioned(
                      left: i * cellWidth,
                      top: 0,
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, 0),
                        child: Text(
                          _times[i],
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget _cell(int i, ThemeData theme) {
    final selected = _isSelected(i);
    final booking = _bookingAt(i);
    final scheme = theme.colorScheme;
    final color = selected
        ? (widget.enabled ? scheme.primary : scheme.primary.withValues(alpha: 0.4))
        : booking != null
            ? Colors.orange.withValues(alpha: 0.3)
            : scheme.surfaceContainerHighest;
    // A wider gap after each hour's second half groups the cells by hour.
    final endsHour = _times[i].endsWith(':30');
    Widget box = Container(
      margin: EdgeInsets.only(right: endsHour ? 3 : 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
        border: selected && booking != null
            ? Border.all(color: Colors.orange.shade800, width: 2)
            : null,
      ),
    );
    if (booking != null) {
      box = Tooltip(
        message: '${booking.label} · ${slotRange(booking.start, booking.slots)}',
        child: box,
      );
    }
    return box;
  }
}
