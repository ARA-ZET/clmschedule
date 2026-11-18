// undo/undo_redo_buttons.dart
//
// The Undo / Redo button pair a screen puts in its own toolbar. Tooltips name
// the step ("Undo: Move job"); each button is disabled when its stack is empty.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import 'undo_actions.dart';
import 'undo_history.dart';

class UndoRedoButtons extends riverpod.ConsumerWidget {
  final UndoKey undoKey;
  final Color? color;
  final double iconSize;

  /// Gets first refusal on Undo, as in [UndoShortcuts.interceptUndo].
  final bool Function()? interceptUndo;

  const UndoRedoButtons({
    super.key,
    required this.undoKey,
    this.color,
    this.iconSize = 20,
    this.interceptUndo,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final history = ref.watch(undoHistoryRiverpod(undoKey));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.undo),
          iconSize: iconSize,
          color: color,
          visualDensity: VisualDensity.compact,
          tooltip: history.canUndo
              ? 'Undo: ${history.undoLabel} (Ctrl+Z)'
              : 'Nothing to undo',
          onPressed: history.canUndo
              ? () {
                  if (interceptUndo?.call() ?? false) return;
                  runUndo(context, history);
                }
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.redo),
          iconSize: iconSize,
          color: color,
          visualDensity: VisualDensity.compact,
          tooltip: history.canRedo
              ? 'Redo: ${history.redoLabel} (Ctrl+Shift+Z)'
              : 'Nothing to redo',
          onPressed: history.canRedo ? () => runRedo(context, history) : null,
        ),
      ],
    );
  }
}
