// undo/undo_shortcuts.dart
//
// Ctrl/Cmd+Z (undo) and Ctrl/Cmd+Shift+Z or Ctrl/Cmd+Y (redo) for one
// screen's history.
//
// Focus-scoped on purpose: the dashboard's IndexedStack wraps hidden tabs in
// ExcludeFocus and a pushed page takes focus from the tab beneath it, so the
// keys only ever reach the screen the user is looking at.
//
// Unlike CallbackShortcuts, keys are passed through while a text field has
// focus, so Ctrl+Z inside a field still undoes typing.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../utils/vertex_delete_key.dart';
import 'undo_actions.dart';
import 'undo_history.dart';

const _undoActivators = [
  SingleActivator(LogicalKeyboardKey.keyZ, control: true),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
];

const _redoActivators = [
  SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true),
  SingleActivator(LogicalKeyboardKey.keyY, control: true),
  SingleActivator(LogicalKeyboardKey.keyY, meta: true),
];

class UndoShortcuts extends riverpod.ConsumerStatefulWidget {
  final UndoKey undoKey;
  final Widget child;

  /// Gets first refusal on Ctrl+Z — e.g. the map editor undoing the last
  /// point of an in-progress drawing. Return true when handled.
  final bool Function()? interceptUndo;

  const UndoShortcuts({
    super.key,
    required this.undoKey,
    required this.child,
    this.interceptUndo,
  });

  @override
  riverpod.ConsumerState<UndoShortcuts> createState() => _UndoShortcutsState();
}

class _UndoShortcutsState extends riverpod.ConsumerState<UndoShortcuts> {
  final FocusNode _node = FocusNode(debugLabel: 'UndoShortcuts');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  bool _matches(List<SingleActivator> activators, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return activators.any((a) => a.accepts(event, keyboard));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (isTypingInTextField()) return KeyEventResult.ignored;
    final history = ref.read(undoHistoryRiverpod(widget.undoKey));
    // Redo first: Ctrl+Shift+Z would otherwise also match a lenient undo.
    if (_matches(_redoActivators, event)) {
      runRedo(context, history);
      return KeyEventResult.handled;
    }
    if (_matches(_undoActivators, event)) {
      if (widget.interceptUndo?.call() ?? false) return KeyEventResult.handled;
      runUndo(context, history);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Clicking a grid cell or the map doesn't move focus by itself; pull it
      // back here so the shortcut keeps reaching this screen. Skipped when
      // focus is already inside (a button, a field the user is typing in).
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_node.hasFocus) _node.requestFocus();
      },
      child: Focus(
        focusNode: _node,
        autofocus: true,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    );
  }
}
