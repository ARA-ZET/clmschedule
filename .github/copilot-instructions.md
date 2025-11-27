# CLM Schedule - AI Coding Instructions

## Project Overview

CLM Schedule is a Flutter enterprise scheduling application for managing distributor job assignments with real-time updates, drag-and-drop functionality, offline support, and map integration using Firebase and Google Maps.

## Critical Architecture Patterns

### Daily-Based Data Storage

**Key Pattern**: Jobs are stored in daily documents (`/schedule/daily/YYYY-MM-DD`) not monthly collections.

- Use `DailyService` and `FirestoreService` for CRUD operations
- Jobs stored as arrays within daily documents for performance
- Cross-date moves require deletion from source + addition to target
- Example: Moving a job from Sept 15 to Sept 20 calls `moveJobBetweenDates()`

### Command Pattern with Undo/Redo

**Key Pattern**: All state-changing operations use the Command pattern via `UndoRedoManager`.

```dart
// Always use commands for user actions
await scheduleProvider.addJobWithUndo(job, targetDate);
// Never call FirestoreService directly:
// await firestoreService.addJob(job); // ❌ WRONG
```

- Commands in `/lib/commands/` - implement `execute()` and `undo()`
- Three contexts: `scheduleGrid`, `jobList`, `global`
- Context switches automatically based on active tab

### Provider Architecture with Multi-Stream Management

**Key Pattern**: Providers manage multiple Firebase streams (current month + next month).

```dart
// ScheduleProvider manages both months simultaneously
Stream<List<Job>> _currentMonthJobsSubscription;
Stream<List<Job>> _nextMonthJobsSubscription;
```

- Use `ChangeNotifierProxyProvider` for dependencies between providers
- Providers auto-dispose subscriptions in `dispose()`

### Environment-Based Configuration

**Key Pattern**: All API keys stored in `.env` and generated into code.

```bash
# Required workflow
cp .env.example .env  # Fill with real keys
flutter pub run build_runner build --delete-conflicting-outputs
dart run tools/replace_maps_key.dart  # For web builds
```

- `Env` class uses `envied` package for compile-time injection
- Web builds require separate `maps_config.js` generation

## Essential Commands

### Development Setup

```bash
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
dart run tools/replace_maps_key.dart  # Before web deployment
```

### Testing

```bash
flutter test  # Widget tests in /test/
flutter run test_*.dart  # Integration tests in root
```

### Build Commands

```bash
flutter build web  # Requires maps_config.js generation first
flutter build apk  # Android
flutter build ios  # iOS
```

## Key File Patterns

### Models with Migration Support

```dart
// Jobs support both new statusId and legacy status fields
factory Job.fromMap(String id, Map<String, dynamic> data) {
  String statusId = data['statusId'] ?? data['status'] ?? 'scheduled';
  // Always include backwards compatibility
}
```

### Provider State Management

```dart
// Providers use both current and optimistic state
await firestoreService.updateJob(job, targetDate);
// Stream automatically updates UI - no manual state setting needed
```

### Multi-Platform Widget Structure

```dart
// Widgets handle scale and responsive design
Consumer<ScaleProvider>(
  builder: (context, scaleProvider, child) {
    return SizedBox(
      width: 150 * scaleProvider.scale,
      // Always apply scale factor to dimensions
    );
  },
)
```

## Data Flow Conventions

### Job Operations

1. **Schedule Grid**: Jobs belong to distributors on specific dates
2. **Job List**: Independent items that can be assigned to schedule slots
3. **Collection Schedule**: Vehicle-based jobs with trailer assignments

### Cross-Component Communication

- `JobListProvider` → `CollectionScheduleProvider` (jobs flow from list to schedule)
- `AuthProvider` → All others (user permissions and state)
- `UndoRedoManager` ← All editors (command execution)

### Firebase Collections Structure

```
/distributors/{id} - Global distributor data
/workAreas/{id} - Global work area polygons
/schedule/daily/{YYYY-MM-DD} - Jobs array for specific date
/collectionSchedule/daily/{YYYY-MM-DD} - Collection jobs array
/customJobStatuses/{id} - User-defined job status configurations
```

## Common Pitfalls to Avoid

1. **Never call FirestoreService directly** - Always use Provider command methods
2. **Don't forget scale factors** - All UI dimensions must support `ScaleProvider`
3. **Handle cross-date operations** - Use `moveJobBetweenDates()` not `updateJob()`
4. **Check authentication** - Most operations require `AuthProvider.isAuthenticated`
5. **Manage subscriptions** - Always cancel streams in Provider `dispose()`

## Testing Patterns

- Use `test_*.dart` files in root for feature integration tests
- Widget tests in `/test/` directory follow standard Flutter patterns
- KML/map features have dedicated test files (e.g., `test_kml_download.dart`)

## Map Integration

- Google Maps API key injected via environment variables
- KML file parsing in `/assets/maps/` for work area definitions
- Custom polygons stored as `CustomPolygon` models within jobs
- Map views support both display and editing modes with undo/redo
