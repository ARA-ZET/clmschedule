import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'undo_redo_manager.dart';

/// Service that handles keyboard shortcuts for undo/redo operations
/// Supports Ctrl+Z/Cmd+Z for undo and Ctrl+Y/Cmd+Y for redo
class KeyboardShortcutsService {
  static const Duration _keyDebounceDelay = Duration(milliseconds: 100);
  static DateTime? _lastKeyPress;

  /// Initialize keyboard shortcuts for the entire app
  /// Call this once in your main app widget
  static Widget initializeShortcuts({required Widget child}) {
    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: child,
    );
  }

  /// Handle keyboard events
  static void _handleKeyEvent(KeyEvent event) {
    // Only handle key down events and debounce rapid key presses
    if (event is! KeyDownEvent) return;

    final now = DateTime.now();
    if (_lastKeyPress != null &&
        now.difference(_lastKeyPress!) < _keyDebounceDelay) {
      return;
    }
    _lastKeyPress = now;

    // Check for undo/redo key combinations
    final isMetaPressed = event.logicalKey == LogicalKeyboardKey.metaLeft ||
        event.logicalKey == LogicalKeyboardKey.metaRight ||
        HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.metaLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.metaRight);

    final isControlPressed =
        event.logicalKey == LogicalKeyboardKey.controlLeft ||
            event.logicalKey == LogicalKeyboardKey.controlRight ||
            HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.controlLeft) ||
            HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.controlRight);

    final isCommandPressed = isMetaPressed || isControlPressed;

    if (isCommandPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        // Check if Shift is also pressed for redo (Cmd+Shift+Z)
        final isShiftPressed = HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.shiftLeft) ||
            HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.shiftRight);

        if (isShiftPressed) {
          _performRedo();
        } else {
          _performUndo();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.keyY) {
        // Ctrl+Y for redo (alternative to Ctrl+Shift+Z)
        _performRedo();
      }
    }
  }

  /// Perform undo operation
  static void _performUndo() async {
    if (undoRedoManager.canUndo) {
      try {
        final success = await undoRedoManager.undo();
        if (success) {
          _showUndoRedoFeedback(
              'Undone: ${undoRedoManager.nextRedoDescription ?? 'action'}');
        }
      } catch (e) {
        _showUndoRedoFeedback('Undo failed: $e', isError: true);
      }
    }
  }

  /// Perform redo operation
  static void _performRedo() async {
    if (undoRedoManager.canRedo) {
      try {
        final success = await undoRedoManager.redo();
        if (success) {
          _showUndoRedoFeedback(
              'Redone: ${undoRedoManager.nextUndoDescription ?? 'action'}');
        }
      } catch (e) {
        _showUndoRedoFeedback('Redo failed: $e', isError: true);
      }
    }
  }

  /// Show feedback when undo/redo operations are performed
  static void _showUndoRedoFeedback(String message, {bool isError = false}) {
    // Note: This is a simplified feedback mechanism
    // In a real app, you might want to use a more sophisticated notification system
    debugPrint('Undo/Redo: $message');

    // TODO: Integrate with your app's notification/snackbar system
    // For example, you could store the message and let the UI widgets display it
  }

  /// Alternative method to create a widget with shortcuts
  /// Use this if you want more control over which widgets have shortcuts
  static Widget withShortcuts({
    required Widget child,
    bool enableUndo = true,
    bool enableRedo = true,
  }) {
    final shortcuts = <LogicalKeySet, Intent>{};
    final actions = <Type, Action<Intent>>{};

    if (enableUndo) {
      // Ctrl+Z or Cmd+Z for undo
      shortcuts[LogicalKeySet(
              LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ)] =
          const UndoIntent();
      shortcuts[
              LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyZ)] =
          const UndoIntent();
      actions[UndoIntent] = CallbackAction<UndoIntent>(
        onInvoke: (intent) => _performUndo(),
      );
    }

    if (enableRedo) {
      // Ctrl+Y or Cmd+Y for redo
      shortcuts[LogicalKeySet(
              LogicalKeyboardKey.control, LogicalKeyboardKey.keyY)] =
          const RedoIntent();
      shortcuts[
              LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyY)] =
          const RedoIntent();

      // Ctrl+Shift+Z or Cmd+Shift+Z for redo (alternative)
      shortcuts[LogicalKeySet(
          LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift,
          LogicalKeyboardKey.keyZ)] = const RedoIntent();
      shortcuts[LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.shift,
          LogicalKeyboardKey.keyZ)] = const RedoIntent();

      actions[RedoIntent] = CallbackAction<RedoIntent>(
        onInvoke: (intent) => _performRedo(),
      );
    }

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: actions,
        child: child,
      ),
    );
  }
}

/// Intent for undo operations
class UndoIntent extends Intent {
  const UndoIntent();
}

/// Intent for redo operations
class RedoIntent extends Intent {
  const RedoIntent();
}

/// Mixin that provides undo/redo functionality to widgets
mixin UndoRedoMixin<T extends StatefulWidget> on State<T> {
  bool get canUndo => undoRedoManager.canUndo;
  bool get canRedo => undoRedoManager.canRedo;
  String? get nextUndoDescription => undoRedoManager.nextUndoDescription;
  String? get nextRedoDescription => undoRedoManager.nextRedoDescription;

  Future<bool> performUndo() async {
    return await undoRedoManager.undo();
  }

  Future<bool> performRedo() async {
    return await undoRedoManager.redo();
  }

  /// Show a snackbar with undo/redo feedback
  void showUndoRedoSnackBar(String message, {bool isError = false}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red : Colors.green,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }
}
