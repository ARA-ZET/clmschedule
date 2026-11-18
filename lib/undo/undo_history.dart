// undo/undo_history.dart
//
// Per-screen undo/redo history. Each screen (Schedule, Job List, a client
// map, a dropsheet day, a payroll week) owns its own [ScreenUndoHistory], looked up
// by [UndoKey] through [undoHistoryRiverpod] — there is deliberately no
// app-wide undo, so Ctrl+Z on one screen never reverts work done on another.
//
// Histories live until the app closes (the family is not autoDispose), so a
// screen's steps survive switching tabs and coming back.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

/// Steps kept per history. The oldest step drops off when a 21st is recorded.
const int kUndoDepth = 20;

/// Edits that land on the same [UndoEntry.coalesceKey] within this window
/// merge into one step (one slider drag, one burst of nudges).
const Duration kUndoCoalesceWindow = Duration(seconds: 1);

enum UndoScope { schedule, jobList, clientMap, dropsheet, payroll }

/// Identifies one history: a [scope] plus an [id] within it — `''` for the
/// Schedule and Job List, the map id for a client map, the day key for a
/// dropsheet, the week start for payroll.
@immutable
class UndoKey {
  final UndoScope scope;
  final String id;
  const UndoKey(this.scope, [this.id = '']);

  static const schedule = UndoKey(UndoScope.schedule);
  static const jobList = UndoKey(UndoScope.jobList);

  @override
  bool operator ==(Object other) =>
      other is UndoKey && other.scope == scope && other.id == id;

  @override
  int get hashCode => Object.hash(scope, id);

  @override
  String toString() => 'UndoKey(${scope.name}, $id)';
}

/// Thrown by an entry's [UndoEntry.undo] / [UndoEntry.redo] when what it
/// would revert has changed since (another user, another tab, a background
/// sync). The step is skipped rather than overwriting the newer change.
class UndoConflict implements Exception {
  final String message;
  const UndoConflict(this.message);

  @override
  String toString() => message;
}

/// One reversible step.
///
/// [undo] and [redo] run later, possibly after more edits, so they must work
/// from values captured when the step was recorded — never from live objects
/// that may have changed since. Each checks the target still matches what it
/// expects and throws [UndoConflict] if not.
class UndoEntry {
  final String label;
  final Future<void> Function() undo;
  final Future<void> Function() redo;

  /// With [mergeOnto], lets consecutive steps on the same thing (one slider
  /// drag, a burst of nudges) collapse into one — see [ScreenUndoHistory.record].
  final String? coalesceKey;

  /// Builds the single step that spans [previous]'s "before" to this step's
  /// "after". Required for coalescing: the two steps' own closures can't just
  /// be paired, because [previous]'s undo checks against its own "after",
  /// which this step has already changed.
  final UndoEntry Function(UndoEntry previous)? mergeOnto;

  final DateTime at;

  UndoEntry({
    required this.label,
    required this.undo,
    required this.redo,
    this.coalesceKey,
    this.mergeOnto,
    DateTime? at,
  }) : at = at ?? DateTime.now();
}

enum UndoResultKind { applied, conflict, failed, nothing }

/// What happened to an undo or redo, for the screen to report.
class UndoResult {
  final UndoResultKind kind;
  final String label;
  final Object? error;

  const UndoResult._(this.kind, this.label, [this.error]);

  bool get applied => kind == UndoResultKind.applied;
}

final undoHistoryRiverpod =
    riverpod.ChangeNotifierProvider.family<ScreenUndoHistory, UndoKey>(
  (ref, key) => ScreenUndoHistory(key),
);

class ScreenUndoHistory extends ChangeNotifier {
  final UndoKey key;
  final List<UndoEntry> _undo = [];
  final List<UndoEntry> _redo = [];
  bool _busy = false;

  ScreenUndoHistory(this.key);

  bool get canUndo => _undo.isNotEmpty && !_busy;
  bool get canRedo => _redo.isNotEmpty && !_busy;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;
  int get undoCount => _undo.length;
  int get redoCount => _redo.length;

  /// Whether [entry] is the step the next undo would revert.
  bool isNewest(UndoEntry entry) => _undo.isNotEmpty && identical(_undo.last, entry);

  /// True while an undo or redo is running. Providers check it so the writes
  /// an undo makes are never recorded as new steps.
  bool get isApplying => _busy;

  /// Records a step that has already been applied. Clears redo, coalesces
  /// with the previous step when [UndoEntry.coalesceKey] matches within
  /// [kUndoCoalesceWindow] (measured from the previous step, so a long drag
  /// stays one step), and trims to [kUndoDepth].
  void record(UndoEntry entry) {
    if (_busy) return;
    final top = _undo.isEmpty ? null : _undo.last;
    if (top != null &&
        entry.mergeOnto != null &&
        entry.coalesceKey != null &&
        top.coalesceKey == entry.coalesceKey &&
        entry.at.difference(top.at) < kUndoCoalesceWindow) {
      _undo[_undo.length - 1] = entry.mergeOnto!(top);
    } else {
      _undo.add(entry);
      if (_undo.length > kUndoDepth) _undo.removeAt(0);
    }
    _redo.clear();
    notifyListeners();
  }

  Future<UndoResult> undo() => _step(_undo, _redo, (e) => e.undo());

  Future<UndoResult> redo() => _step(_redo, _undo, (e) => e.redo());

  Future<UndoResult> _step(
    List<UndoEntry> from,
    List<UndoEntry> to,
    Future<void> Function(UndoEntry) run,
  ) async {
    if (_busy || from.isEmpty) {
      return const UndoResult._(UndoResultKind.nothing, '');
    }
    _busy = true;
    final entry = from.removeLast();
    notifyListeners();
    try {
      await run(entry);
      to.add(entry);
      if (to.length > kUndoDepth) to.removeAt(0);
      return UndoResult._(UndoResultKind.applied, entry.label);
    } on UndoConflict catch (e) {
      // Dropped: the change it would revert no longer exists as recorded.
      return UndoResult._(UndoResultKind.conflict, entry.label, e);
    } catch (e) {
      // Put it back so the user can try again (e.g. after reconnecting).
      from.add(entry);
      debugPrint('Undo/redo "${entry.label}" failed: $e');
      return UndoResult._(UndoResultKind.failed, entry.label, e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void clear() {
    if (_undo.isEmpty && _redo.isEmpty) return;
    _undo.clear();
    _redo.clear();
    notifyListeners();
  }
}
