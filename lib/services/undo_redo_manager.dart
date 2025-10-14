import 'package:flutter/foundation.dart';
import '../models/command.dart';

/// Enum representing different contexts/screens in the application
enum UndoRedoContext {
  scheduleGrid('Schedule Grid'),
  jobList('Job List'),
  editMaps('Edit Maps'),
  global('Global'); // For operations that don't belong to a specific screen

  const UndoRedoContext(this.displayName);
  final String displayName;
}

/// Context-specific undo/redo stack
class _ContextStack {
  /// Stack of executed commands (for undo)
  final List<Command> undoStack = [];

  /// Stack of undone commands (for redo)
  final List<Command> redoStack = [];

  /// Whether undo operation is available
  bool get canUndo => undoStack.isNotEmpty;

  /// Whether redo operation is available
  bool get canRedo => redoStack.isNotEmpty;

  /// Get the description of the next command that would be undone
  String? get nextUndoDescription =>
      canUndo ? undoStack.last.description : null;

  /// Get the description of the next command that would be redone
  String? get nextRedoDescription =>
      canRedo ? redoStack.last.description : null;

  /// Get the number of commands in undo stack
  int get undoStackSize => undoStack.length;

  /// Get the number of commands in redo stack
  int get redoStackSize => redoStack.length;

  /// Clear all command history for this context
  void clear() {
    undoStack.clear();
    redoStack.clear();
  }
}

/// Service that manages undo/redo operations using the Command pattern
/// Maintains separate stacks of the last 10 commands for each context/screen
class UndoRedoManager extends ChangeNotifier {
  static const int maxHistorySize = 10;

  /// Current active context - determines which stack to use
  UndoRedoContext _currentContext = UndoRedoContext.global;

  /// Map of context-specific command stacks
  final Map<UndoRedoContext, _ContextStack> _contextStacks = {
    for (var context in UndoRedoContext.values) context: _ContextStack(),
  };

  /// Get the current active context
  UndoRedoContext get currentContext => _currentContext;

  /// Set the current active context
  void setContext(UndoRedoContext context) {
    if (_currentContext != context) {
      _currentContext = context;
      notifyListeners();
    }
  }

  /// Get the stack for the current context
  _ContextStack get _currentStack => _contextStacks[_currentContext]!;

  /// Get the stack for a specific context
  _ContextStack _getStack(UndoRedoContext context) => _contextStacks[context]!;

  /// Whether undo operation is available for current context
  bool get canUndo => _currentStack.canUndo;

  /// Whether redo operation is available for current context
  bool get canRedo => _currentStack.canRedo;

  /// Get the description of the next command that would be undone for current context
  String? get nextUndoDescription => _currentStack.nextUndoDescription;

  /// Get the description of the next command that would be redone for current context
  String? get nextRedoDescription => _currentStack.nextRedoDescription;

  /// Get the number of commands in undo stack for current context
  int get undoStackSize => _currentStack.undoStackSize;

  /// Get the number of commands in redo stack for current context
  int get redoStackSize => _currentStack.redoStackSize;

  /// Get undo/redo state for a specific context
  bool canUndoForContext(UndoRedoContext context) => _getStack(context).canUndo;
  bool canRedoForContext(UndoRedoContext context) => _getStack(context).canRedo;
  String? nextUndoDescriptionForContext(UndoRedoContext context) =>
      _getStack(context).nextUndoDescription;
  String? nextRedoDescriptionForContext(UndoRedoContext context) =>
      _getStack(context).nextRedoDescription;

  /// Execute a command and add it to the undo stack for current context
  Future<void> executeCommand(Command command,
      [UndoRedoContext? context]) async {
    final targetContext = context ?? _currentContext;
    final stack = _getStack(targetContext);

    try {
      await command.execute();

      // Add to undo stack
      stack.undoStack.add(command);

      // Clear redo stack since we performed a new action
      stack.redoStack.clear();

      // Maintain max history size
      if (stack.undoStack.length > maxHistorySize) {
        stack.undoStack.removeAt(0);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Error executing command: $e');
      rethrow;
    }
  }

  /// Undo the last command for current context
  Future<bool> undo([UndoRedoContext? context]) async {
    final targetContext = context ?? _currentContext;
    final stack = _getStack(targetContext);

    if (!stack.canUndo) return false;

    try {
      final command = stack.undoStack.removeLast();
      await command.undo();

      // Add to redo stack
      stack.redoStack.add(command);

      // Maintain max history size for redo stack too
      if (stack.redoStack.length > maxHistorySize) {
        stack.redoStack.removeAt(0);
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error undoing command: $e');
      // Put the command back if undo failed
      if (stack.redoStack.isNotEmpty) {
        stack.undoStack.add(stack.redoStack.removeLast());
      }
      return false;
    }
  }

  /// Redo the last undone command for current context
  Future<bool> redo([UndoRedoContext? context]) async {
    final targetContext = context ?? _currentContext;
    final stack = _getStack(targetContext);

    if (!stack.canRedo) return false;

    try {
      final command = stack.redoStack.removeLast();
      await command.execute();

      // Add back to undo stack
      stack.undoStack.add(command);

      // Maintain max history size
      if (stack.undoStack.length > maxHistorySize) {
        stack.undoStack.removeAt(0);
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error redoing command: $e');
      // Put the command back if redo failed
      if (stack.undoStack.isNotEmpty) {
        stack.redoStack.add(stack.undoStack.removeLast());
      }
      return false;
    }
  }

  /// Clear all command history for current context or all contexts
  void clearHistory([UndoRedoContext? context]) {
    if (context != null) {
      _getStack(context).clear();
    } else {
      // Clear all contexts
      for (var stack in _contextStacks.values) {
        stack.clear();
      }
    }
    notifyListeners();
  }

  /// Get recent command history for debugging/UI display for current context
  List<String> getRecentCommands({int limit = 5, UndoRedoContext? context}) {
    final targetContext = context ?? _currentContext;
    final stack = _getStack(targetContext);

    return stack.undoStack.reversed
        .take(limit)
        .map((cmd) => '${cmd.description} (${_formatTimestamp(cmd.timestamp)})')
        .toList();
  }

  /// Get summary of all contexts and their command counts
  Map<UndoRedoContext, Map<String, int>> getContextSummary() {
    return {
      for (var entry in _contextStacks.entries)
        entry.key: {
          'undo': entry.value.undoStackSize,
          'redo': entry.value.redoStackSize,
        }
    };
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inMinutes < 1) {
      return 'just now';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }
}

/// Singleton instance for global undo/redo management
final UndoRedoManager undoRedoManager = UndoRedoManager();
