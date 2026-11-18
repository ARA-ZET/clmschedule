import 'package:clmschedule/undo/undo_history.dart';
import 'package:flutter_test/flutter_test.dart';

/// A counter whose steps are recorded as undoable entries.
class _Counter {
  int value = 0;

  UndoEntry step(int by, {String? coalesceKey, DateTime? at}) {
    final before = value;
    value += by;
    return _entry('+$by', before, value, coalesceKey, at);
  }

  /// A step from [before] to [after]. [_befores] remembers each step's
  /// "before" so [UndoEntry.mergeOnto] can span from an older step.
  UndoEntry _entry(
      String label, int before, int after, String? coalesceKey, DateTime? at) {
    final entry = UndoEntry(
      label: label,
      coalesceKey: coalesceKey,
      at: at,
      mergeOnto: (previous) =>
          _entry(label, _befores[previous]!, after, coalesceKey, at),
      undo: () async {
        if (value != after) throw const UndoConflict('changed since');
        value = before;
      },
      redo: () async {
        if (value != before) throw const UndoConflict('changed since');
        value = after;
      },
    );
    _befores[entry] = before;
    return entry;
  }

  final Map<UndoEntry, int> _befores = {};
}

void main() {
  test('undo and redo walk back and forth', () async {
    final h = ScreenUndoHistory(UndoKey.schedule);
    final c = _Counter();
    h.record(c.step(1));
    h.record(c.step(2));
    expect(c.value, 3);

    expect((await h.undo()).applied, isTrue);
    expect(c.value, 1);
    expect(h.redoLabel, '+2');

    expect((await h.redo()).applied, isTrue);
    expect(c.value, 3);
    expect(h.canRedo, isFalse);
  });

  test('keeps only the last kUndoDepth steps', () async {
    final h = ScreenUndoHistory(UndoKey.jobList);
    final c = _Counter();
    for (var i = 0; i < kUndoDepth + 5; i++) {
      h.record(c.step(1));
    }
    expect(h.undoCount, kUndoDepth);
    while (h.canUndo) {
      await h.undo();
    }
    expect(c.value, 5); // the 5 oldest steps fell off
  });

  test('a new step clears redo', () async {
    final h = ScreenUndoHistory(UndoKey.schedule);
    final c = _Counter();
    h.record(c.step(1));
    await h.undo();
    expect(h.canRedo, isTrue);
    h.record(c.step(5));
    expect(h.canRedo, isFalse);
  });

  test('same coalesceKey within the window merges into one step', () async {
    final h = ScreenUndoHistory(const UndoKey(UndoScope.clientMap, 'm1'));
    final c = _Counter();
    final t0 = DateTime(2026, 1, 1, 12);
    h.record(c.step(1, coalesceKey: 'style:p1', at: t0));
    h.record(c.step(1,
        coalesceKey: 'style:p1',
        at: t0.add(const Duration(milliseconds: 300))));
    h.record(c.step(1,
        coalesceKey: 'style:p1',
        at: t0.add(const Duration(milliseconds: 600))));
    expect(h.undoCount, 1);
    await h.undo();
    expect(c.value, 0);
    await h.redo();
    expect(c.value, 3);
  });

  test('coalescing stops once the window has passed', () {
    final h = ScreenUndoHistory(const UndoKey(UndoScope.clientMap, 'm1'));
    final c = _Counter();
    final t0 = DateTime(2026, 1, 1, 12);
    h.record(c.step(1, coalesceKey: 'k', at: t0));
    h.record(c.step(1, coalesceKey: 'k', at: t0.add(kUndoCoalesceWindow)));
    expect(h.undoCount, 2);
  });

  test('a conflict drops the step instead of overwriting', () async {
    final h = ScreenUndoHistory(UndoKey.schedule);
    final c = _Counter();
    h.record(c.step(1));
    c.value = 42; // someone else changed it
    final r = await h.undo();
    expect(r.kind, UndoResultKind.conflict);
    expect(c.value, 42);
    expect(h.canUndo, isFalse);
    expect(h.canRedo, isFalse);
  });

  test('a failure keeps the step so it can be retried', () async {
    final h = ScreenUndoHistory(UndoKey.schedule);
    var fail = true;
    h.record(UndoEntry(
      label: 'flaky',
      undo: () async {
        if (fail) throw Exception('offline');
      },
      redo: () async {},
    ));
    expect((await h.undo()).kind, UndoResultKind.failed);
    expect(h.undoLabel, 'flaky');
    fail = false;
    expect((await h.undo()).applied, isTrue);
  });

  test('steps recorded while an undo runs are ignored', () async {
    final h = ScreenUndoHistory(UndoKey.schedule);
    h.record(UndoEntry(
      label: 'outer',
      undo: () async {
        expect(h.isApplying, isTrue);
        // The provider's own write path would try to record this.
        h.record(
            UndoEntry(label: 'echo', undo: () async {}, redo: () async {}));
      },
      redo: () async {},
    ));
    await h.undo();
    expect(h.undoCount, 0);
    expect(h.redoLabel, 'outer');
  });

  test('UndoKey compares by value', () {
    expect(const UndoKey(UndoScope.clientMap, 'a'),
        const UndoKey(UndoScope.clientMap, 'a'));
    expect(
        const UndoKey(UndoScope.clientMap, 'a') ==
            const UndoKey(UndoScope.clientMap, 'b'),
        isFalse);
  });
}
