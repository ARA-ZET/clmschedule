// The main Schedule grid's Collection Schedule column: distributor rows are
// half-hour time rows (row 1 = 08:00–08:30 …), one lane per van, coloured
// where the van is booked.
import 'package:clmschedule/models/collection_job.dart';
import 'package:clmschedule/providers/schedule_bookings_provider.dart';
import 'package:clmschedule/utils/schedule_booking_slots.dart';
import 'package:clmschedule/widgets/schedule_booking_column.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _date = DateTime(2026, 11, 20);

CollectionJob _booking(
  String id,
  String start,
  int slots, {
  VehicleType van = VehicleType.hyundai,
  String client = 'Mrs Smith',
  String status = 'scheduled',
}) =>
    CollectionJob(
      id: id,
      location: '12 Main Rd',
      vehicleType: van,
      trailerType: TrailerType.noTrailer,
      date: _date,
      timeSlot: start,
      timeSlots: slots,
      assignedStaff: const [],
      staffCount: 2,
      jobType: 'junkCollection',
      statusId: status,
      clients: [client],
    );

/// Rows 0..15 of [car]'s lane, as one letter each: '.' free, 'B' booked,
/// '^' arrow up (before 08:00), 'v' arrow down (after the last row).
String _lane(DayBookings day, VehicleType car, {int timeRows = 16}) => [
      for (var r = 0; r < timeRows; r++)
        () {
          final s = carSlotFor(day, car, r, timeRows);
          if (s.isBooked) return 'B';
          if (s.earlier.isNotEmpty) return '^';
          if (s.later.isNotEmpty) return 'v';
          return '.';
        }(),
    ].join();

void main() {
  group('time rows', () {
    test('row 1 is 08:00–08:30, row 16 is 15:30–16:00, then none', () {
      expect(rowSlotLabel(0), '08:00–08:30');
      expect(rowSlotLabel(1), '08:30–09:00');
      expect(rowSlotLabel(15), '15:30–16:00');
      expect(rowSlotLabel(16), isNull);
      expect(rowSlotLabel(-1), isNull);
    });

    test('at most 16 rows carry a time; fewer distributors, fewer rows', () {
      expect(bookingTimeRows(25), 16);
      expect(bookingTimeRows(16), 16);
      expect(bookingTimeRows(5), 5);
      expect(bookingTimeRows(0), 0);
    });
  });

  group('grid columns (vans from today on only)', () {
    final nov = [for (var d = 1; d <= 30; d++) DateTime(2026, 11, d)];
    String layout(List<ScheduleGridColumn> cols) =>
        cols.map((c) => '${c.dateIndex + 1}${c.vans ? 'v' : ''}').join(' ');

    test('past days keep their jobs column but get no vans column', () {
      final cols = scheduleGridColumns(nov, DateTime(2026, 11, 28));
      expect(layout(cols).split(' ').take(3), ['1', '2', '3']);
      expect(
          layout(cols).split(' ').skip(27).join(' '), '28 28v 29 29v 30 30v');
      // Every date is still there; only today on has a vans column.
      expect(cols.where((c) => !c.vans), hasLength(30));
      expect(
          cols.where((c) => c.vans).map((c) => c.dateIndex + 1), [28, 29, 30]);
    });

    test('today counts as forward, whatever the time of day', () {
      final cols = scheduleGridColumns(nov, DateTime(2026, 11, 30, 17, 45));
      expect(cols.where((c) => c.vans).map((c) => c.dateIndex + 1), [30]);
    });

    test('a past month has no vans columns at all', () {
      final oct = [for (var d = 1; d <= 31; d++) DateTime(2026, 10, d)];
      final cols = scheduleGridColumns(oct, DateTime(2026, 11, 18));
      expect(cols.any((c) => c.vans), isFalse);
      expect(cols, hasLength(31));
    });

    test('a future month has a vans column after every date', () {
      final dec = [for (var d = 1; d <= 31; d++) DateTime(2026, 12, d)];
      final cols = scheduleGridColumns(dec, DateTime(2026, 11, 18));
      expect(cols, hasLength(62));
      expect(layout(cols).startsWith('1 1v 2 2v'), isTrue);
    });

    test('this month running into next month (Schedule shows both)', () {
      final days = [
        for (var d = 0; d < 61; d++)
          DateTime(2026, 11, 1).add(Duration(days: d))
      ];
      final cols = scheduleGridColumns(days, DateTime(2026, 11, 18));
      // 17 past days, then 44 days (18 Nov – 31 Dec) with both columns.
      expect(cols, hasLength(17 + 44 * 2));
      expect(cols.firstWhere((c) => c.vans).dateIndex, 17);
    });
  });

  group('occupiesVan', () {
    test('a timed, live booking holds its van', () {
      expect(occupiesVan(_booking('a', '10:00', 2)), isTrue);
      expect(
          occupiesVan(_booking('a', '10:00', 2, status: 'job_done')), isTrue);
      expect(occupiesVan(_booking('a', '10:00', 2, status: 'standby')), isTrue);
    });

    test('no time (00:00) and cancelled bookings do not', () {
      expect(occupiesVan(_booking('a', '00:00', 2)), isFalse);
      expect(occupiesVan(_booking('a', '', 2)), isFalse);
      expect(
          occupiesVan(_booking('a', '10:00', 2, status: 'cancelled')), isFalse);
      expect(
          occupiesVan(_booking('a', '10:00', 2, status: 'Cancelled by client')),
          isFalse);
    });
  });

  group('DayBookings', () {
    test('same bookings in any order are equal', () {
      final a =
          DayBookings([_booking('x', '10:00', 1), _booking('y', '12:00', 1)]);
      final b =
          DayBookings([_booking('y', '12:00', 1), _booking('x', '10:00', 1)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a moved time or another van is a change', () {
      final base = DayBookings([_booking('x', '10:00', 1)]);
      expect(base, isNot(DayBookings([_booking('x', '10:30', 1)])));
      expect(
          base,
          isNot(DayBookings(
              [_booking('x', '10:00', 1, van: VehicleType.nissan)])));
    });

    test('forVehicle filters by van', () {
      final day = DayBookings([
        _booking('h', '10:00', 1),
        _booking('n', '11:00', 1, van: VehicleType.nissan),
      ]);
      expect(day.forVehicle(VehicleType.nissan).map((b) => b.id), ['n']);
      expect(day.forVehicle(VehicleType.mahindra), isEmpty);
    });
  });

  group('carSlotFor', () {
    test('a booking colours its van lane in the rows it covers', () {
      // 09:00–10:30 → rows 2, 3, 4 (09:00, 09:30, 10:00).
      final day = DayBookings([_booking('a', '09:00', 3)]);
      expect(_lane(day, VehicleType.hyundai), '..BBB...........');
      expect(_lane(day, VehicleType.mahindra), '................');
      expect(_lane(day, VehicleType.nissan), '................');
    });

    test('rows of one booking join; its ends do not', () {
      final day = DayBookings([_booking('a', '09:00', 3)]);
      final first = carSlotFor(day, VehicleType.hyundai, 2, 16);
      final middle = carSlotFor(day, VehicleType.hyundai, 3, 16);
      final last = carSlotFor(day, VehicleType.hyundai, 4, 16);
      expect((first.joinsAbove, first.joinsBelow), (false, true));
      expect((middle.joinsAbove, middle.joinsBelow), (true, true));
      expect((last.joinsAbove, last.joinsBelow), (true, false));
      expect(
          [first, middle, last].any((s) => s.cutTop || s.cutBottom), isFalse);
    });

    test('back-to-back bookings do not join or clash', () {
      final day = DayBookings([
        _booking('a', '09:00', 1),
        _booking('b', '09:30', 1, client: 'Mr Jones'),
      ]);
      final a = carSlotFor(day, VehicleType.hyundai, 2, 16);
      final b = carSlotFor(day, VehicleType.hyundai, 3, 16);
      expect(a.bookings.single.id, 'a');
      expect(b.bookings.single.id, 'b');
      expect(a.joinsBelow || b.joinsAbove, isFalse);
      expect(a.clash || b.clash, isFalse);
    });

    test('two bookings on one van in the same half hour clash', () {
      final day = DayBookings([
        _booking('a', '09:00', 4), // 09:00–11:00
        _booking('b', '10:00', 2, client: 'Mr Jones'), // 10:00–11:00
      ]);
      expect(carSlotFor(day, VehicleType.hyundai, 3, 16).clash, isFalse);
      expect(carSlotFor(day, VehicleType.hyundai, 4, 16).clash, isTrue);
      expect(carSlotFor(day, VehicleType.hyundai, 5, 16).clash, isTrue);
    });

    test('vans are independent: the same time on two vans is no clash', () {
      final day = DayBookings([
        _booking('a', '10:00', 2),
        _booking('b', '10:00', 2, van: VehicleType.nissan),
      ]);
      expect(_lane(day, VehicleType.hyundai), '....BB..........');
      expect(_lane(day, VehicleType.nissan), '....BB..........');
      expect(carSlotFor(day, VehicleType.hyundai, 4, 16).clash, isFalse);
    });

    test('a booking from before 08:00 is cut (pointed) at the first row', () {
      final day = DayBookings([_booking('a', '07:30', 2)]); // 07:30–08:30
      final s = carSlotFor(day, VehicleType.hyundai, 0, 16);
      expect(s.isBooked, isTrue);
      expect(s.cutTop, isTrue);
      expect(s.joinsAbove, isFalse);
      expect(_lane(day, VehicleType.hyundai), 'B...............');
    });

    test('a booking past 16:00 is cut (pointed) at the last row', () {
      final day = DayBookings([_booking('a', '15:30', 2)]); // 15:30–16:30
      final s = carSlotFor(day, VehicleType.hyundai, 15, 16);
      expect(s.isBooked, isTrue);
      expect(s.cutBottom, isTrue);
      expect(s.joinsBelow, isFalse);
    });

    test('bookings wholly outside 08:00–16:00 are edge arrows', () {
      final day = DayBookings([
        _booking('dawn', '07:30', 1), // 07:30–08:00
        _booking('evening', '17:00', 2),
      ]);
      expect(_lane(day, VehicleType.hyundai), '^..............v');
      expect(carSlotFor(day, VehicleType.hyundai, 0, 16).earlier.single.id,
          'dawn');
      expect(carSlotFor(day, VehicleType.hyundai, 15, 16).later.single.id,
          'evening');
    });

    test('with fewer distributors the time rows end earlier', () {
      // 10 rows → 08:00–13:00.
      final day = DayBookings([
        _booking('a', '12:30', 2), // 12:30–13:30: row 9, cut at the bottom
        _booking('b', '14:00', 1), // after the last row: arrow
      ]);
      expect(_lane(day, VehicleType.hyundai, timeRows: 10), '.........B');
      final last = carSlotFor(day, VehicleType.hyundai, 9, 10);
      expect(last.cutBottom, isTrue);
      expect(last.later.single.id, 'b');
    });

    test('rows past the time rows show nothing', () {
      final day = DayBookings([_booking('a', '09:00', 2)]);
      expect(carSlotFor(day, VehicleType.hyundai, 16, 16).isEmpty, isTrue);
      expect(carSlotFor(day, VehicleType.hyundai, 3, 3).isEmpty, isTrue);
    });

    test('cancelled and untimed bookings are not drawn', () {
      final day = DayBookings([
        _booking('a', '10:00', 1, status: 'cancelled'),
        _booking('b', '00:00', 1),
      ]);
      expect(_lane(day, VehicleType.hyundai), '................');
    });
  });

  group('widgets', () {
    final day = DayBookings([
      _booking('a', '09:00', 2),
      _booking('b', '13:00', 2, van: VehicleType.nissan, client: 'Mr Jones'),
    ]);

    Widget scope(Widget child) => ProviderScope(
          overrides: [dayBookingsRiverpod.overrideWith((ref, _) => day)],
          child: MaterialApp(home: Scaffold(body: child)),
        );

    Widget sized(double w, double h, Widget child) => Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: w, height: h, child: child),
        );

    testWidgets('header shows the van initials, faded when not booked',
        (tester) async {
      await tester.pumpWidget(scope(
          sized(84, 40, BookingColumnHeader(date: _date, isToday: true))));
      expect(tester.takeException(), isNull);
      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(texts.map((t) => t.data), ['H', 'M', 'N']);
      expect(texts[0].style!.color!.a, 1.0);
      expect(texts[1].style!.color!.a, lessThan(0.5));
      expect(texts[2].style!.color!.a, 1.0);
      final tips = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((t) => t.message)
          .toList();
      expect(tips[1], 'Mahindra: free');
      expect(tips[0], 'Hyundai\n09:00–10:00 · Mrs Smith · junkCollection');
    });

    for (final h in [28.0, 40.0, 92.0, 119.6]) {
      testWidgets('a booked row draws without overflow (row height $h)',
          (tester) async {
        // Row 2 = 09:00–09:30: Hyundai booked, the others free.
        await tester.pumpWidget(scope(sized(
            84, h, BookingColumnCell(date: _date, row: 2, timeRows: 16))));
        expect(tester.takeException(), isNull);
        final tips = tester
            .widgetList<Tooltip>(find.byType(Tooltip))
            .map((t) => t.message)
            .toList();
        expect(tips, ['Hyundai\n09:00–10:00 · Mrs Smith · junkCollection']);
      });
    }

    testWidgets('an empty row is one painter, with no hover areas',
        (tester) async {
      // Row 0 = 08:00–08:30: nothing booked on any van.
      await tester.pumpWidget(scope(
          sized(84, 48, BookingColumnCell(date: _date, row: 0, timeRows: 16))));
      final inCell = find.descendant(
          of: find.byType(BookingColumnCell),
          matching: find.byType(CustomPaint));
      expect(inCell, findsOneWidget);
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('hovering a booked lane shows its booking; a free lane nothing',
        (tester) async {
      await tester.pumpWidget(scope(
          sized(84, 48, BookingColumnCell(date: _date, row: 2, timeRows: 16))));
      // Lanes: 3 px inset, 3 px gaps → (84 - 12) / 3 = 24 px each.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(3 + 12, 24));
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Hyundai\n09:00–10:00 · Mrs Smith · junkCollection'),
          findsOneWidget);

      await mouse.moveTo(const Offset(3 + 24 + 3 + 12, 24)); // Mahindra
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Hyundai\n'), findsNothing);
      expect(find.textContaining('Mahindra'), findsNothing);
    });

    // The name cell as the grid builds it: a Card (margin 4) with 8 px
    // side padding around the name row; collapsed rows are 48 high.
    Widget nameCell(double rowHeight, String? label) => MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 150,
                height: rowHeight,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: NameWithSlotLabel(
                      slotLabel: label,
                      name: const Row(children: [
                        Text('1.', style: TextStyle(fontSize: 16, height: 1.5)),
                        SizedBox(width: 8),
                        Expanded(child: Text('Sipho')),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    for (final (label, rowHeight) in [
      ('collapsed', 48.0),
      ('expanded', 92.0)
    ]) {
      testWidgets('name keeps its size with the time under it ($label)',
          (tester) async {
        await tester.pumpWidget(nameCell(rowHeight, '08:00–08:30'));
        expect(tester.takeException(), isNull);
        expect(find.text('Sipho'), findsOneWidget);
        expect(find.text('08:00–08:30'), findsOneWidget);
        // Nothing is scaled down.
        expect(find.byType(FittedBox), findsNothing);
        expect(tester.getSize(find.text('1.')).height, 24);
        // The time sits under the name.
        expect(tester.getTopLeft(find.text('08:00–08:30')).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(find.text('1.')).dy));
      });
    }

    testWidgets('a row too short for both keeps the name, drops the time',
        (tester) async {
      // Zoomed out: 48 x 0.7.
      await tester.pumpWidget(nameCell(48 * 0.7, '08:00–08:30'));
      expect(tester.takeException(), isNull);
      expect(find.text('Sipho'), findsOneWidget);
      expect(find.text('08:00–08:30'), findsNothing);
      expect(tester.getSize(find.text('1.')).height, 24);
    });

    testWidgets('zooming text up re-measures: a tight row drops the time',
        (tester) async {
      await tester.pumpWidget(nameCell(48, '08:00–08:30'));
      expect(find.text('08:00–08:30'), findsOneWidget);
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: nameCell(48, '08:00–08:30'),
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('Sipho'), findsOneWidget);
      expect(find.text('08:00–08:30'), findsNothing);
    });

    testWidgets('rows past the time rows show the name alone', (tester) async {
      await tester.pumpWidget(nameCell(48, null));
      expect(tester.takeException(), isNull);
      expect(find.text('Sipho'), findsOneWidget);
    });

    testWidgets('a row past the time rows is blank', (tester) async {
      await tester.pumpWidget(scope(sized(
          84, 40, BookingColumnCell(date: _date, row: 16, timeRows: 16))));
      expect(tester.takeException(), isNull);
      expect(
          find.descendant(
              of: find.byType(BookingColumnCell),
              matching: find.byType(CustomPaint)),
          findsNothing);
    });
  });
}
