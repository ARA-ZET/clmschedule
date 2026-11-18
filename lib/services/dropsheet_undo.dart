// services/dropsheet_undo.dart
//
// Undo / Redo for a dropsheet day (UndoKey(dropsheet, dayId)). Every edit
// writes the whole day, so a step is a (before → after) pair of days; undo
// puts back only the driver sections the step changed, after checking each
// still matches what the step left — a section changed since (a schedule
// sync, another user) makes the step a conflict, skipped rather than
// overwritten.
import '../models/dropsheet_day.dart';
import '../undo/undo_history.dart' show UndoConflict;
import 'schedule_mutation_types.dart' show deepEquals;

bool _sameSection(DropsheetDriverSection? a, DropsheetDriverSection? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return deepEquals(a.toMap(), b.toMap());
}

/// Ids of sections added, removed or changed between [a] and [b].
Set<String> changedSectionIds(DropsheetDay a, DropsheetDay b) {
  final byA = {for (final s in a.sections) s.id: s};
  final byB = {for (final s in b.sections) s.id: s};
  return {
    for (final id in {...byA.keys, ...byB.keys})
      if (!_sameSection(byA[id], byB[id])) id,
  };
}

/// [current] with the sections in [ids] put back as they are in [target].
/// Throws [UndoConflict] when any of them no longer matches [expected].
DropsheetDay restoreSections({
  required DropsheetDay current,
  required DropsheetDay expected,
  required DropsheetDay target,
  required Set<String> ids,
}) {
  final cur = {for (final s in current.sections) s.id: s};
  final exp = {for (final s in expected.sections) s.id: s};
  for (final id in ids) {
    if (!_sameSection(cur[id], exp[id])) {
      throw const UndoConflict('that driver\'s sheet was changed since');
    }
  }
  final tgt = {for (final s in target.sections) s.id: s};
  final sections = [
    for (final s in current.sections)
      if (!ids.contains(s.id))
        s
      else if (tgt[s.id] != null)
        tgt[s.id]!,
  ];
  final present = {for (final s in sections) s.id};
  for (var i = 0; i < target.sections.length; i++) {
    final s = target.sections[i];
    if (ids.contains(s.id) && !present.contains(s.id)) {
      sections.insert(i.clamp(0, sections.length), s);
    }
  }
  return current.copyWith(sections: sections);
}

/// One dropsheet undo step. [after] is updated in place when a background
/// follow-up (intersection names, refreshed coordinates) changes the
/// sections it left, so that follow-up doesn't read as a conflict.
class DropsheetStep {
  final String dayId;
  final DropsheetDay before;
  DropsheetDay after;

  DropsheetStep(this.dayId, this.before, this.after);

  /// Folds a background change ([previous] → [updated]) into this step for
  /// every section the step left exactly as [previous] has it.
  void fold(DropsheetDay previous, DropsheetDay updated) {
    final ids = changedSectionIds(before, after);
    final prev = {for (final s in previous.sections) s.id: s};
    final next = {for (final s in updated.sections) s.id: s};
    final mine = {for (final s in after.sections) s.id: s};
    var sections = after.sections;
    for (final id in ids) {
      if (!_sameSection(mine[id], prev[id]) || next[id] == null) continue;
      sections = [
        for (final s in sections) s.id == id ? next[id]! : s,
      ];
    }
    after = after.copyWith(sections: sections);
  }
}
