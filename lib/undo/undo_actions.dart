// undo/undo_actions.dart
//
// Runs an undo/redo on a screen's history and tells the user what happened.
import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';

import '../utils/friendly_error.dart';
import 'undo_history.dart';

Future<UndoResult> runUndo(
    BuildContext context, ScreenUndoHistory history) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await history.undo();
  _report(messenger, result, undo: true);
  return result;
}

Future<UndoResult> runRedo(
    BuildContext context, ScreenUndoHistory history) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await history.redo();
  _report(messenger, result, undo: false);
  return result;
}

/// A toast's "Undo" button for the step [entry] gives once recorded. It
/// undoes only while that step is still the newest one — an old toast never
/// undoes a later edit — and reports the result like Ctrl+Z.
SnackBarAction undoEntryAction(
  ScaffoldMessengerState? messenger,
  ScreenUndoHistory history,
  UndoEntry? Function() entry,
) =>
    SnackBarAction(
      label: 'Undo',
      onPressed: () async {
        final e = entry();
        if (e == null || !history.isNewest(e)) {
          messenger?.showToast(const SnackBar(
            content: Text('Already undone or changed since — use the Undo '
                'button on the Schedule'),
            backgroundColor: Colors.orange,
          ));
          return;
        }
        _report(messenger, await history.undo(), undo: true);
      },
    );

void _report(
  ScaffoldMessengerState? messenger,
  UndoResult result, {
  required bool undo,
}) {
  if (messenger == null || result.kind == UndoResultKind.nothing) return;
  final verb = undo ? 'undo' : 'redo';
  final String text;
  Color? color;
  switch (result.kind) {
    case UndoResultKind.applied:
      text = '${undo ? 'Undone' : 'Redone'}: ${result.label}';
    case UndoResultKind.conflict:
      text = "Couldn't $verb \"${result.label}\" — "
          '${result.error ?? 'it was changed since'}. Skipped.';
      color = Colors.orange.shade800;
    case UndoResultKind.failed:
      text = friendlyFirebaseError(result.error!, action: '$verb that');
      color = Colors.red.shade700;
    case UndoResultKind.nothing:
      return;
  }
  messenger
    ..hideCurrentToast()
    ..showToast(SnackBar(
      content: Text(text),
      backgroundColor: color,
      duration: Duration(seconds: result.applied ? 2 : 5),
    ));
}
