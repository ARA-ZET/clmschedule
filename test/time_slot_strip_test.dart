// The time slot is picked in one go: drag across the half-hour times (press
// on the start, let go on the end), or tap a time to move the booking there
// at the same length. It works inside a scrolling form like Add/Edit Job.
import 'package:clmschedule/widgets/time_slot_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 26 half-hour cells (07:30 … 20:00) across 520 px: 20 px each.
const _width = 520.0;
const _cell = 20.0;

/// The centre of the cell for [hhmm], relative to the strip's top-left.
Offset _at(String hhmm) {
  final p = hhmm.split(':');
  final minutes = int.parse(p[0]) * 60 + int.parse(p[1]);
  final index = (minutes - (7 * 60 + 30)) ~/ 30;
  return Offset(index * _cell + _cell / 2, 17);
}

class _Picked {
  String? start;
  int? slots;
  int calls = 0;
}

Future<_Picked> _pump(
  WidgetTester tester, {
  String? start,
  int? slots,
  bool enabled = true,
  bool inScrollView = false,
  List<SlotBooking> booked = const [],
}) async {
  final picked = _Picked();
  Widget strip = SizedBox(
    width: _width,
    child: TimeSlotStrip(
      start: start,
      slots: slots,
      enabled: enabled,
      booked: booked,
      onChanged: (s, n) {
        picked
          ..start = s
          ..slots = n
          ..calls += 1;
      },
    ),
  );
  if (inScrollView) {
    strip = SingleChildScrollView(
      child: Column(children: [
        const SizedBox(height: 200),
        strip,
        const SizedBox(height: 2000),
      ]),
    );
  }
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Align(alignment: Alignment.topLeft, child: strip)),
  ));
  return picked;
}

Offset _origin(WidgetTester tester) => tester
    .getTopLeft(find.byKey(const ValueKey('timeSlotStripCells')));

void main() {
  testWidgets('one drag books the whole slot: 10:00 to 11:30', (tester) async {
    final picked = await _pump(tester);
    final o = _origin(tester);
    // Press on 10:00, let go on the 11:00 cell (which ends at 11:30).
    await tester.dragFrom(o + _at('10:00'), _at('11:00') - _at('10:00'));
    await tester.pump();
    expect(picked.calls, 1);
    expect(picked.start, '10:00');
    expect(picked.slots, 3);
  });

  testWidgets('dragging backwards works too', (tester) async {
    final picked = await _pump(tester);
    final o = _origin(tester);
    await tester.dragFrom(o + _at('15:00'), _at('13:30') - _at('15:00'));
    await tester.pump();
    expect(picked.start, '13:30');
    expect(picked.slots, 4);
  });

  testWidgets('a tap moves the booking there, keeping its length',
      (tester) async {
    final picked = await _pump(tester, start: '10:00', slots: 3);
    await tester.tapAt(_origin(tester) + _at('14:00'));
    await tester.pump();
    expect(picked.start, '14:00');
    expect(picked.slots, 3);
  });

  testWidgets('a first tap books half an hour', (tester) async {
    final picked = await _pump(tester);
    await tester.tapAt(_origin(tester) + _at('09:00'));
    await tester.pump();
    expect(picked.start, '09:00');
    expect(picked.slots, 1);
  });

  testWidgets('a tap near the end shortens it to fit by 20:30',
      (tester) async {
    final picked = await _pump(tester, start: '10:00', slots: 4);
    await tester.tapAt(_origin(tester) + _at('19:30'));
    await tester.pump();
    expect(picked.start, '19:30');
    expect(picked.slots, 2);
  });

  testWidgets('works inside a scrolling form', (tester) async {
    final picked = await _pump(tester, inScrollView: true);
    final o = _origin(tester);
    await tester.dragFrom(o + _at('08:00'), _at('09:30') - _at('08:00'));
    await tester.pump();
    expect(picked.start, '08:00');
    expect(picked.slots, 4);
  });

  testWidgets('other bookings are shown, with who they are for',
      (tester) async {
    await _pump(tester, booked: const [
      (start: '11:00', slots: 2, label: 'Mrs Smith'),
    ]);
    expect(find.byTooltip('Mrs Smith · 11:00–12:00'), findsNWidgets(2));
  });

  testWidgets('does nothing while saving', (tester) async {
    final picked = await _pump(tester, enabled: false);
    final o = _origin(tester);
    await tester.tapAt(o + _at('10:00'));
    await tester.dragFrom(o + _at('10:00'), const Offset(60, 0));
    await tester.pump();
    expect(picked.calls, 0);
  });
}
