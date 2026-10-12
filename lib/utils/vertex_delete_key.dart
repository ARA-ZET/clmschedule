import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// "Hold Delete / Backspace and click points to remove them" — the quick
/// polygon cleanup gesture shared by every map that edits polygon vertices.
///
/// Vertex handles call [isVertexDeleteHeld] in their `onTap` and remove the
/// point straight away when it is true, with no confirmation.

/// Whether [key] is one of the keys that arm vertex deletion.
bool isVertexDeleteKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace;

/// Whether a text field has focus, where Backspace means "erase a letter".
bool isTypingInTextField() =>
    FocusManager.instance.primaryFocus?.context?.widget is EditableText;

/// Whether Delete or Backspace is held right now. Read from the keyboard
/// at click time rather than tracked, so a key-up lost to a window switch
/// can't leave delete mode stuck on.
bool isVertexDeleteHeld() {
  final keyboard = HardwareKeyboard.instance;
  return !isTypingInTextField() &&
      (keyboard.isLogicalKeyPressed(LogicalKeyboardKey.delete) ||
          keyboard.isLogicalKeyPressed(LogicalKeyboardKey.backspace));
}
