import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/undo_redo_manager.dart';

/// A widget that displays undo and redo buttons
/// Can be used in AppBars, floating action buttons, or standalone
class UndoRedoButtons extends StatefulWidget {
  final bool showLabels;
  final bool horizontal;
  final double iconSize;
  final EdgeInsets padding;
  final Color? enabledColor;
  final Color? disabledColor;

  const UndoRedoButtons({
    super.key,
    this.showLabels = false,
    this.horizontal = true,
    this.iconSize = 24.0,
    this.padding = const EdgeInsets.all(8.0),
    this.enabledColor,
    this.disabledColor,
  });

  @override
  State<UndoRedoButtons> createState() => _UndoRedoButtonsState();
}

class _UndoRedoButtonsState extends State<UndoRedoButtons> {
  @override
  Widget build(BuildContext context) {
    return Consumer<UndoRedoManager>(
      builder: (context, undoRedoManager, child) =>
          _buildButtons(context, undoRedoManager),
    );
  }

  Widget _buildButtons(BuildContext context, UndoRedoManager undoRedoManager) {
    final theme = Theme.of(context);
    final enabledColor = widget.enabledColor ?? theme.primaryColor;
    final disabledColor = widget.disabledColor ?? theme.disabledColor;

    final undoButton =
        _buildUndoButton(context, undoRedoManager, enabledColor, disabledColor);
    final redoButton =
        _buildRedoButton(context, undoRedoManager, enabledColor, disabledColor);

    if (widget.horizontal) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [undoButton, redoButton],
      );
    } else {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [undoButton, redoButton],
      );
    }
  }

  Widget _buildUndoButton(BuildContext context, UndoRedoManager undoRedoManager,
      Color enabledColor, Color disabledColor) {
    final canUndo = undoRedoManager.canUndo;
    final description = undoRedoManager.nextUndoDescription;

    return Padding(
      padding: widget.padding,
      child: Tooltip(
        message: canUndo
            ? 'Undo: $description (${_getUndoShortcut()})'
            : 'Nothing to undo',
        child: widget.showLabels
            ? TextButton.icon(
                onPressed: canUndo ? () => _performUndo(undoRedoManager) : null,
                icon: Icon(
                  Icons.undo,
                  size: widget.iconSize,
                  color: canUndo ? enabledColor : disabledColor,
                ),
                label: Text(
                  'Undo',
                  style: TextStyle(
                    color: canUndo ? enabledColor : disabledColor,
                  ),
                ),
              )
            : IconButton(
                onPressed: canUndo ? () => _performUndo(undoRedoManager) : null,
                icon: Icon(
                  Icons.undo,
                  size: widget.iconSize,
                  color: canUndo ? enabledColor : disabledColor,
                ),
              ),
      ),
    );
  }

  Widget _buildRedoButton(BuildContext context, UndoRedoManager undoRedoManager,
      Color enabledColor, Color disabledColor) {
    final canRedo = undoRedoManager.canRedo;
    final description = undoRedoManager.nextRedoDescription;

    return Padding(
      padding: widget.padding,
      child: Tooltip(
        message: canRedo
            ? 'Redo: $description (${_getRedoShortcut()})'
            : 'Nothing to redo',
        child: widget.showLabels
            ? TextButton.icon(
                onPressed: canRedo ? () => _performRedo(undoRedoManager) : null,
                icon: Icon(
                  Icons.redo,
                  size: widget.iconSize,
                  color: canRedo ? enabledColor : disabledColor,
                ),
                label: Text(
                  'Redo',
                  style: TextStyle(
                    color: canRedo ? enabledColor : disabledColor,
                  ),
                ),
              )
            : IconButton(
                onPressed: canRedo ? () => _performRedo(undoRedoManager) : null,
                icon: Icon(
                  Icons.redo,
                  size: widget.iconSize,
                  color: canRedo ? enabledColor : disabledColor,
                ),
              ),
      ),
    );
  }

  String _getUndoShortcut() {
    return Theme.of(context).platform == TargetPlatform.macOS
        ? 'Cmd+Z'
        : 'Ctrl+Z';
  }

  String _getRedoShortcut() {
    return Theme.of(context).platform == TargetPlatform.macOS
        ? 'Cmd+Y'
        : 'Ctrl+Y';
  }

  void _performUndo(UndoRedoManager undoRedoManager) async {
    try {
      final success = await undoRedoManager.undo();
      if (success && mounted) {
        _showSnackBar(
            'Undone: ${undoRedoManager.nextRedoDescription ?? 'action'}');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Undo failed: $e', isError: true);
      }
    }
  }

  void _performRedo(UndoRedoManager undoRedoManager) async {
    try {
      final success = await undoRedoManager.redo();
      if (success && mounted) {
        _showSnackBar(
            'Redone: ${undoRedoManager.nextUndoDescription ?? 'action'}');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Redo failed: $e', isError: true);
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
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

/// A floating action button with undo/redo functionality
class UndoRedoFAB extends StatefulWidget {
  final bool mini;
  final String? heroTag;

  const UndoRedoFAB({
    super.key,
    this.mini = false,
    this.heroTag,
  });

  @override
  State<UndoRedoFAB> createState() => _UndoRedoFABState();
}

class _UndoRedoFABState extends State<UndoRedoFAB> {
  bool _showRedo = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<UndoRedoManager>(
      builder: (context, undoRedoManager, child) =>
          _buildFAB(context, undoRedoManager),
    );
  }

  Widget _buildFAB(BuildContext context, UndoRedoManager undoRedoManager) {
    final canUndo = undoRedoManager.canUndo;
    final canRedo = undoRedoManager.canRedo;

    // Don't show FAB if no actions are available
    if (!canUndo && !canRedo) {
      return const SizedBox.shrink();
    }

    // Show undo by default, or redo if undo is not available
    final showUndo = !_showRedo && canUndo;

    return GestureDetector(
      onLongPress: () {
        if (!showUndo && canUndo) {
          setState(() {
            _showRedo = false;
          });
        } else if (showUndo && canRedo) {
          setState(() {
            _showRedo = true;
          });
        }
      },
      child: FloatingActionButton(
        mini: widget.mini,
        heroTag: widget.heroTag,
        onPressed: showUndo
            ? () => _performUndo(undoRedoManager)
            : () => _performRedo(undoRedoManager),
        tooltip: showUndo
            ? 'Undo: ${undoRedoManager.nextUndoDescription ?? 'action'} (long press for redo)'
            : 'Redo: ${undoRedoManager.nextRedoDescription ?? 'action'} (long press for undo)',
        child: Icon(showUndo ? Icons.undo : Icons.redo),
      ),
    );
  }

  void _performUndo(UndoRedoManager undoRedoManager) async {
    try {
      final success = await undoRedoManager.undo();
      if (success && mounted) {
        _showSnackBar(
            'Undone: ${undoRedoManager.nextRedoDescription ?? 'action'}');
        // Switch to redo if available
        if (undoRedoManager.canRedo) {
          setState(() {
            _showRedo = true;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Undo failed: $e', isError: true);
      }
    }
  }

  void _performRedo(UndoRedoManager undoRedoManager) async {
    try {
      final success = await undoRedoManager.redo();
      if (success && mounted) {
        _showSnackBar(
            'Redone: ${undoRedoManager.nextUndoDescription ?? 'action'}');
        // Switch to undo if available
        if (undoRedoManager.canUndo) {
          setState(() {
            _showRedo = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Redo failed: $e', isError: true);
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
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

/// A status widget showing the current undo/redo state
class UndoRedoStatus extends StatefulWidget {
  final bool showHistory;
  final int maxHistoryItems;

  const UndoRedoStatus({
    super.key,
    this.showHistory = false,
    this.maxHistoryItems = 5,
  });

  @override
  State<UndoRedoStatus> createState() => _UndoRedoStatusState();
}

class _UndoRedoStatusState extends State<UndoRedoStatus> {
  @override
  void initState() {
    super.initState();
    undoRedoManager.addListener(_onUndoRedoChanged);
  }

  @override
  void dispose() {
    undoRedoManager.removeListener(_onUndoRedoChanged);
    super.dispose();
  }

  void _onUndoRedoChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final undoCount = undoRedoManager.undoStackSize;
    final redoCount = undoRedoManager.redoStackSize;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Undo/Redo Status',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text('Undo: $undoCount actions available'),
            Text('Redo: $redoCount actions available'),
            if (widget.showHistory) ...[
              const SizedBox(height: 8),
              Text(
                'Recent Actions:',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              ...undoRedoManager
                  .getRecentCommands(limit: widget.maxHistoryItems)
                  .map((command) => Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: Text(
                          '• $command',
                          style: theme.textTheme.bodySmall,
                        ),
                      )),
            ],
          ],
        ),
      ),
    );
  }
}
