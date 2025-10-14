# Undo/Redo System Integration Guide

This guide shows how to integrate the undo/redo system into your CLM Schedule app.

## 1. Main App Setup

In your main.dart file, wrap your app with keyboard shortcuts:

```dart
import 'package:flutter/material.dart';
import 'services/keyboard_shortcuts_service.dart';

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CLM Schedule',
      home: KeyboardShortcutsService.initializeShortcuts(
        child: YourMainScreen(),
      ),
    );
  }
}
```

## 2. Adding Undo/Redo Buttons to Screens

### Job List Screen

```dart
import 'widgets/undo_redo_widgets.dart';

class JobListScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Job List'),
        actions: [
          UndoRedoButtons(showLabels: false),
        ],
      ),
      body: YourJobListWidget(),
      floatingActionButton: UndoRedoFAB(heroTag: "joblist"),
    );
  }
}
```

### Schedule Screen

```dart
class ScheduleScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Schedule'),
        actions: [
          UndoRedoButtons(showLabels: true, horizontal: true),
        ],
      ),
      body: YourScheduleWidget(),
    );
  }
}
```

### Map Editing Screen

```dart
class MapEditingScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit Map'),
        actions: [
          UndoRedoButtons(),
        ],
      ),
      body: YourMapWidget(),
      floatingActionButton: UndoRedoFAB(heroTag: "map", mini: true),
    );
  }
}
```

## 3. Using Undo/Redo in Your Code

### Instead of Direct Operations

```dart
// OLD WAY - Direct service calls
await jobListService.addJobListItem(newItem, DateTime.now());
await firestoreService.updateJob(modifiedJob, DateTime.now());

// NEW WAY - Using commands with undo/redo
final provider = context.read<JobListProvider>();
await provider.addJobListItemWithUndo(newItem);

final scheduleProvider = context.read<ScheduleProvider>();
await scheduleProvider.updateJobWithUndo(originalJob, modifiedJob, DateTime.now());
```

### Example: Job List Operations

```dart
class JobListWidget extends StatefulWidget {
  @override
  _JobListWidgetState createState() => _JobListWidgetState();
}

class _JobListWidgetState extends State<JobListWidget> with UndoRedoMixin {

  void _addJob() async {
    final provider = context.read<JobListProvider>();
    final newJob = JobListItem(...); // Create new job

    try {
      await provider.addJobListItemWithUndo(newJob);
      showUndoRedoSnackBar('Job added successfully');
    } catch (e) {
      showUndoRedoSnackBar('Failed to add job: $e', isError: true);
    }
  }

  void _deleteJob(JobListItem job) async {
    final provider = context.read<JobListProvider>();

    try {
      await provider.deleteJobListItemWithUndo(job);
      showUndoRedoSnackBar('Job deleted successfully');
    } catch (e) {
      showUndoRedoSnackBar('Failed to delete job: $e', isError: true);
    }
  }
}
```

## 4. Keyboard Shortcuts

The following keyboard shortcuts are automatically available:

- **Ctrl+Z** (Windows/Linux) or **Cmd+Z** (Mac): Undo last action
- **Ctrl+Y** (Windows/Linux) or **Cmd+Y** (Mac): Redo last undone action
- **Ctrl+Shift+Z** or **Cmd+Shift+Z**: Alternative redo shortcut

## 5. Features

### Automatic History Management

- Keeps track of the last 10 actions
- Automatically clears redo stack when new actions are performed
- Handles errors gracefully

### Visual Feedback

- Buttons are automatically disabled when no actions are available
- Tooltips show what action will be undone/redone
- SnackBar messages confirm successful operations

### Multiple UI Options

- **UndoRedoButtons**: Regular buttons for app bars or toolbars
- **UndoRedoFAB**: Floating action button that switches between undo/redo
- **UndoRedoStatus**: Status widget showing current state (useful for debugging)

## 6. Testing the System

Create a simple test to verify the functionality:

```dart
void testUndoRedo() async {
  final provider = JobListProvider(jobListService: JobListService());
  final testJob = JobListItem(...); // Create test job

  // Add job
  await provider.addJobListItemWithUndo(testJob);
  assert(undoRedoManager.canUndo == true);

  // Undo addition
  await undoRedoManager.undo();
  assert(undoRedoManager.canRedo == true);

  // Redo addition
  await undoRedoManager.redo();
  assert(undoRedoManager.canUndo == true);

  print('Undo/Redo system working correctly!');
}
```

## 7. Error Handling

The system includes comprehensive error handling:

```dart
try {
  await provider.addJobListItemWithUndo(newJob);
} catch (e) {
  // Command execution failed
  showUndoRedoSnackBar('Operation failed: $e', isError: true);
}
```

## 8. Debugging

Use the UndoRedoStatus widget to monitor the system:

```dart
// Add this to your debug screen or during development
UndoRedoStatus(
  showHistory: true,
  maxHistoryItems: 10,
)
```

This will show:

- Number of available undo/redo actions
- Recent command history
- Timestamps of recent actions

## Migration Notes

To gradually migrate your existing code:

1. Keep existing direct service calls for now
2. Add new `*WithUndo` methods alongside existing methods
3. Update UI to use the new methods when users explicitly want undo functionality
4. Gradually replace direct calls with undo-enabled calls
5. Remove old methods once fully migrated

This approach allows you to test the undo/redo system without breaking existing functionality.
