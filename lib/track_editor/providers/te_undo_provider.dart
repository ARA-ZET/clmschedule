// track_editor/providers/te_undo_provider.dart
//
// Per-(mode, tab) command stack used by the Track Editor for Ctrl+Z /
// Ctrl+Y and the app-bar Undo/Redo buttons. Commands are simple closure
// pairs so call sites can keep their existing mutation code and just
// register an inverse operation alongside it.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'te_mode_provider.dart';

/// A single reversible action.
///
/// **Invariant for callers**: [doFn] and [undoFn] are stored verbatim and
/// will be invoked later — possibly after the user has continued editing
/// the underlying data. Closures must therefore **not** capture references
/// to mutable structures (e.g. a [Trk], [Wpt] or [List<LatLng>]) and rely
/// on them being unchanged at undo/redo time. Snapshot anything you need
/// to restore. For example:
///
/// ```dart
/// // GOOD: snapshot the polygon points before mutation.
/// final oldPoints = List<LatLng>.from(polygon.points);
/// undo.run(mode, tabIndex, TECommand(
///   description: 'Move vertex',
///   doFn: () => provider.updatePolygonPoints(t, p, newPoints),
///   undoFn: () => provider.updatePolygonPoints(t, p, oldPoints),
/// ));
///
/// // BAD: closure captures the live `polygon.points`, which will already
/// // be the mutated list at undo time.
/// undoFn: () => provider.updatePolygonPoints(t, p, polygon.points);
/// ```
class TECommand {
  final String description;
  final void Function() doFn;
  final void Function() undoFn;
  TECommand({
    required this.description,
    required this.doFn,
    required this.undoFn,
  });
}

class _Stack {
  final List<TECommand> undo = [];
  final List<TECommand> redo = [];
}

/// Maximum number of commands kept per tab to bound memory growth.
const int _kMaxStackDepth = 50;

final teUndoRiverpod = riverpod.ChangeNotifierProvider<TEUndoProvider>(
  (ref) => TEUndoProvider(),
);

class TEUndoProvider extends ChangeNotifier {
  // Keyed by mode then tab index. Tab indices shift when tabs are removed
  // (see [removeTab]).
  final Map<TEMode, Map<int, _Stack>> _stacks = {
    for (final m in TEMode.values) m: <int, _Stack>{},
  };

  _Stack _stackFor(TEMode mode, int tabIndex) {
    return _stacks[mode]!.putIfAbsent(tabIndex, () => _Stack());
  }

  bool canUndo(TEMode mode, int tabIndex) =>
      _stacks[mode]?[tabIndex]?.undo.isNotEmpty ?? false;

  bool canRedo(TEMode mode, int tabIndex) =>
      _stacks[mode]?[tabIndex]?.redo.isNotEmpty ?? false;

  String? nextUndoDescription(TEMode mode, int tabIndex) {
    final s = _stacks[mode]?[tabIndex];
    if (s == null || s.undo.isEmpty) return null;
    return s.undo.last.description;
  }

  String? nextRedoDescription(TEMode mode, int tabIndex) {
    final s = _stacks[mode]?[tabIndex];
    if (s == null || s.redo.isEmpty) return null;
    return s.redo.last.description;
  }

  /// Run [command.doFn] immediately and remember it for undo.
  void run(TEMode mode, int tabIndex, TECommand command) {
    command.doFn();
    final s = _stackFor(mode, tabIndex);
    s.undo.add(command);
    if (s.undo.length > _kMaxStackDepth) s.undo.removeAt(0);
    s.redo.clear();
    notifyListeners();
  }

  /// Push a command that has *already* been applied externally — only
  /// the undo/redo closures are recorded.
  void push(TEMode mode, int tabIndex, TECommand command) {
    final s = _stackFor(mode, tabIndex);
    s.undo.add(command);
    if (s.undo.length > _kMaxStackDepth) s.undo.removeAt(0);
    s.redo.clear();
    notifyListeners();
  }

  void undo(TEMode mode, int tabIndex) {
    final s = _stacks[mode]?[tabIndex];
    if (s == null || s.undo.isEmpty) return;
    final cmd = s.undo.removeLast();
    cmd.undoFn();
    s.redo.add(cmd);
    notifyListeners();
  }

  void redo(TEMode mode, int tabIndex) {
    final s = _stacks[mode]?[tabIndex];
    if (s == null || s.redo.isEmpty) return;
    final cmd = s.redo.removeLast();
    cmd.doFn();
    s.undo.add(cmd);
    notifyListeners();
  }

  /// Clear stacks for a single tab in [mode] and shift any higher-index
  /// stacks down by one (mirrors how [TETabsProvider.removeTab] reindexes
  /// the remaining tabs).
  void removeTab(TEMode mode, int tabIndex) {
    final modeStacks = _stacks[mode];
    if (modeStacks == null) return;
    modeStacks.remove(tabIndex);
    final shifted = <int, _Stack>{};
    for (final entry in modeStacks.entries) {
      if (entry.key > tabIndex) {
        shifted[entry.key - 1] = entry.value;
      } else {
        shifted[entry.key] = entry.value;
      }
    }
    modeStacks
      ..clear()
      ..addAll(shifted);
    notifyListeners();
  }

  /// Clear every stack across every mode.
  void clearAll() {
    for (final m in _stacks.values) {
      m.clear();
    }
    notifyListeners();
  }

  /// Clear stacks for a specific tab without re-indexing (used when the
  /// tab is being replaced in place rather than removed).
  void clearTab(TEMode mode, int tabIndex) {
    final s = _stacks[mode]?[tabIndex];
    if (s == null) return;
    s.undo.clear();
    s.redo.clear();
    notifyListeners();
  }
}
