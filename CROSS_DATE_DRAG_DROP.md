# Cross-Date Drag and Drop Implementation

## Overview

The schedule grid now supports dragging and dropping jobs between different days and months using the daily document structure. This update ensures that jobs are properly moved between daily documents when dragged across different dates.

## Key Updates

### 1. New FirebaseService Method

- **`moveJobBetweenDates()`**: Handles moving jobs between different daily documents
- Automatically detects if it's a same-date update (uses regular update) or cross-date move
- For cross-date moves: removes job from original date and adds to new date

### 2. Enhanced Schedule Commands

- **`MoveJobBetweenDatesCommand`**: New command specifically for cross-date moves
- **`EditJobCommand`**: Updated to automatically use move command when dates differ
- **`SwapJobsCommand`**: Updated to handle swapping jobs across different dates
- **`CombineJobsCommand`**: Updated to handle combining jobs from different dates

### 3. Updated Schedule Provider

- **`updateJobWithUndo()`**: Automatically detects cross-date moves and uses appropriate command
- **`moveJobBetweenDatesWithUndo()`**: New method for explicit cross-date moves with undo support

## How It Works

### Same-Date Updates

```dart
// When dragging within the same day, uses regular update
await scheduleProvider.updateJobWithUndo(originalJob, modifiedJob, targetDate);
// → Uses EditJobCommand → updateJob()
```

### Cross-Date Moves

```dart
// When dragging between different days, automatically uses move logic
await scheduleProvider.updateJobWithUndo(originalJob, modifiedJob, targetDate);
// → Detects date change → Uses MoveJobBetweenDatesCommand → moveJobBetweenDates()
```

### Daily Document Operations

1. **Remove from original date**: Deletes job from original daily document's jobs array
2. **Add to new date**: Adds job to new daily document's jobs array
3. **Property updates**: Job properties (distributor, date, etc.) are updated during the move

## Database Structure

```
schedules/
  ├── Oct 2025/
  │   └── days/
  │       ├── 2025-10-15/     # Daily document
  │       │   └── jobs: [...]  # Jobs array for this day
  │       └── 2025-10-16/     # Daily document
  │           └── jobs: [...]  # Jobs array for this day
  └── Nov 2025/
      └── days/
          └── 2025-11-01/     # Cross-month moves work too
              └── jobs: [...]
```

## Supported Drag & Drop Operations

### 1. Simple Move

- Drag job to empty cell on different date
- Job is moved with updated distributor and date

### 2. Job Swap

- Drag job onto existing job on different date
- Both jobs swap positions (including dates)

### 3. Job Combine

- Drag job onto existing job and choose "Add to Existing"
- Jobs are combined at target date, source job is deleted

### 4. Job Copy & Combine

- Drag job onto existing job and choose "Copy"
- Jobs are combined at target date, source job is preserved

## Undo/Redo Support

All cross-date operations support full undo/redo functionality:

- Move operations can be undone to restore original position
- Swap operations restore both jobs to original positions
- Combine operations restore both original jobs
- Commands track both original and new dates for proper restoration

## Performance Benefits

- **Efficient updates**: Only affects the specific daily documents involved
- **Reduced data transfer**: No need to update entire monthly collections
- **Better scalability**: Can handle unlimited jobs across any date range
- **Real-time updates**: Changes are immediately reflected in the UI via streams

## Testing

Use `test_cross_date_movement.dart` to verify the functionality:

```bash
dart test_cross_date_movement.dart
```

This tests:

- Adding jobs to daily documents
- Moving jobs between different dates
- Verifying proper removal from source and addition to target
- Command system with undo/redo functionality
- Property updates during moves
