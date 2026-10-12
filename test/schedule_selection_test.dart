import 'package:clmschedule/providers/schedule_selection_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Rows a..c, one job per cell named "<row><day>" on 1–5 Oct.
  const rows = ['a', 'b', 'c'];
  Iterable<String> jobsIn(String row, DateTime date) =>
      date.day <= 5 ? ['$row${date.day}'] : const [];
  DateTime oct(int d) => DateTime(2026, 10, d);

  void shiftClick(ScheduleSelectionProvider s, String row, int day) =>
      s.selectRangeTo('$row$day',
          distributorId: row, date: oct(day), rowOrder: rows, jobsIn: jobsIn);

  test('shift-click selects the rectangle from the last clicked job', () {
    final s = ScheduleSelectionProvider();
    s.toggle('a2', distributorId: 'a', date: oct(2));
    shiftClick(s, 'b', 4);
    expect(s.ids, {'a2', 'a3', 'a4', 'b2', 'b3', 'b4'});
  });

  test('works backwards and replaces the previous range', () {
    final s = ScheduleSelectionProvider();
    s.toggle('b3', distributorId: 'b', date: oct(3));
    shiftClick(s, 'c', 5);
    shiftClick(s, 'a', 2); // re-aimed from the same anchor
    expect(s.ids, {'a2', 'a3', 'b2', 'b3'});
  });

  test('ctrl-picked jobs survive a shift range', () {
    final s = ScheduleSelectionProvider();
    s.toggle('c5', distributorId: 'c', date: oct(5));
    s.toggle('a1', distributorId: 'a', date: oct(1));
    shiftClick(s, 'a', 2);
    expect(s.ids, {'c5', 'a1', 'a2'});
  });

  test('shift-click without an anchor selects just the job', () {
    final s = ScheduleSelectionProvider();
    shiftClick(s, 'b', 2);
    expect(s.ids, {'b2'});
  });
}
