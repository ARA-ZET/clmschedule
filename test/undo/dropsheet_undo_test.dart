import 'package:clmschedule/models/dropsheet_day.dart';
import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/services/dropsheet_undo.dart';
import 'package:clmschedule/undo/undo_history.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 10, 7);

DropsheetDriverSection _section(String id, List<String> taskIds) =>
    DropsheetDriverSection(
      id: id,
      driverId: id,
      driverName: 'Driver $id',
      tasks: [for (final t in taskIds) DropsheetTask(id: t)],
    );

DropsheetDay _sheet(List<DropsheetDriverSection> sections) =>
    DropsheetDay(date: _day, sections: sections);

List<String> _tasks(DropsheetDay d, String sectionId) => [
      for (final t in d.sections.firstWhere((s) => s.id == sectionId).tasks)
        t.id,
    ];

void main() {
  test('only the sections an edit touched are part of the step', () {
    final before = _sheet([_section('a', ['1']), _section('b', ['2'])]);
    final after = _sheet([_section('a', ['1', '3']), before.sections[1]]);
    expect(changedSectionIds(before, after), {'a'});
  });

  test('undo restores the edited section and keeps the others', () {
    final before = _sheet([_section('a', ['1']), _section('b', ['2'])]);
    final after = _sheet([_section('a', ['1', '3']), before.sections[1]]);
    // Since then a sync added a task to driver b.
    final current = _sheet([after.sections[0], _section('b', ['2', '9'])]);

    final restored = restoreSections(
      current: current,
      expected: after,
      target: before,
      ids: changedSectionIds(before, after),
    );
    expect(_tasks(restored, 'a'), ['1']);
    expect(_tasks(restored, 'b'), ['2', '9']);
  });

  test('a section changed since is a conflict', () {
    final before = _sheet([_section('a', ['1'])]);
    final after = _sheet([_section('a', ['1', '3'])]);
    final current = _sheet([_section('a', ['1', '3', '4'])]);
    expect(
      () => restoreSections(
          current: current,
          expected: after,
          target: before,
          ids: changedSectionIds(before, after)),
      throwsA(isA<UndoConflict>()),
    );
  });

  test('removing a driver undoes back into its old place', () {
    final before = _sheet(
        [_section('a', []), _section('b', []), _section('c', [])]);
    final after = _sheet([before.sections[0], before.sections[2]]);
    final restored = restoreSections(
      current: after,
      expected: after,
      target: before,
      ids: changedSectionIds(before, after),
    );
    expect(restored.sections.map((s) => s.id), ['a', 'b', 'c']);
  });

  test('a background follow-up joins the step instead of conflicting', () {
    final before = _sheet([_section('a', ['1'])]);
    final after = _sheet([_section('a', ['1', '3'])]);
    final step = DropsheetStep(before.docId, before, after);
    // Intersection names arrive for the new stop.
    final named = _sheet([_section('a', ['1', '3', 'named'])]);
    step.fold(after, named);

    final restored = restoreSections(
      current: named,
      expected: step.after,
      target: step.before,
      ids: changedSectionIds(step.before, step.after),
    );
    expect(_tasks(restored, 'a'), ['1']);
  });
}
