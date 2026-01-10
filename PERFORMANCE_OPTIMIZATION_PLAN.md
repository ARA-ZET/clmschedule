# CLM Schedule - Performance Optimization Plan

**Created:** January 9, 2026  
**Status:** In Progress  
**Estimated Total Time:** 5-7 days  
**Expected Overall Improvement:** 60-80% performance gain

---

## 🎯 Executive Summary

The app currently suffers from:

- **Excessive widget rebuilds** - Entire grids rebuild on minor changes
- **60+ simultaneous Firestore streams** - One per daily document
- **Broken caching logic** - Filters/sorts run on every render
- **Memory leaks** - Provider listeners not properly cleaned up
- **Monolithic widgets** - 1000+ line build methods

This plan addresses these issues in 4 phases with measurable improvements at each stage.

---

## 📊 Current Performance Issues

### Critical Issues (⚠️)

1. **Schedule Grid Rebuilds Everything**

   - Location: `lib/widgets/schedule_grid.dart:149`
   - Issue: `Consumer2<ScheduleProvider, ScaleProvider>` rebuilds entire 667-line build method
   - Impact: Every schedule change rebuilds all cells, even unchanged ones

2. **JobList Caching Bug**

   - Location: `lib/providers/job_list_provider.dart:94-165`
   - Issue: `_lastFilterHash` is final, never updated - cache never returns results
   - Impact: Filters run on every notifyListeners() call, even with no changes

3. **60+ Active Firestore Streams**
   - Location: `lib/services/firestore_service.dart:185-220`
   - Issue: Each daily document (30 current + 30 next month) has separate listener
   - Impact: Excessive Firestore reads, network traffic, battery drain

### High Priority Issues

4. **Memory Leak in CollectionScheduleProvider**

   - Location: `lib/providers/collection_schedule_provider.dart:49`
   - Issue: `addListener()` called but never removed in dispose()
   - Impact: Memory accumulates over time, app slows down

5. **No Widget Separation**

   - Location: `lib/widgets/job_card.dart` (1152 lines)
   - Issue: Monolithic widget with inline editors - entire card rebuilds
   - Impact: Typing in one field rebuilds all card sections

6. **Job List Grid - 1910 Lines**
   - Location: `lib/widgets/job_list_grid.dart`
   - Issue: Renders all rows even when not visible
   - Impact: Slow with 1000+ items

---

## 🚀 Optimization Plan - 4 Phases

### **Phase 1: Quick Wins** (4-6 hours)

Low-risk, high-impact fixes with immediate results

### **Phase 2: Widget Optimization** (1-2 days)

Structural changes to prevent unnecessary rebuilds

### **Phase 3: Advanced Optimizations** (2-3 days)

Major architectural improvements for scalability

### **Phase 4: Monitoring & Polish** (1 day)

Performance tracking and final refinements

---

## ✅ Phase 1: Quick Wins (4-6 hours)

**Goal:** 40-60% immediate improvement with minimal risk

### Task 1: Fix JobListProvider Caching Bug ⭐ START HERE

- **File:** `lib/providers/job_list_provider.dart`
- **Lines:** 94-165
- **Change:** Make `_lastFilterHash` mutable, update after filtering
- **Risk:** Very Low
- **Impact:** 40-60% faster filtering
- **Time:** 5 minutes

**Current Code (Broken):**

```dart
final String _lastFilterHash = ''; // Never changes!

List<JobListItem> _filteredJobListItems() {
  final currentHash = '${_searchQuery}_${_statusFilters.join(',')}_...';

  if (_cachedFilteredItems != null && _lastFilterHash == currentHash) {
    return _cachedFilteredItems!; // Never reaches here
  }
  // ... filtering runs every time
}
```

**Fixed Code:**

```dart
String _lastFilterHash = ''; // Mutable

List<JobListItem> _filteredJobListItems() {
  final currentHash = '${_searchQuery}_${_statusFilters.join(',')}_...';

  if (_cachedFilteredItems != null && _lastFilterHash == currentHash) {
    return _cachedFilteredItems!; // Now works!
  }

  // ... existing filtering logic ...

  _lastFilterHash = currentHash; // Update cache key
  _cachedFilteredItems = filtered;
  return filtered;
}
```

---

### Task 2: Fix Memory Leak in CollectionScheduleProvider

- **File:** `lib/providers/collection_schedule_provider.dart`
- **Line:** 49 (addListener) + dispose method
- **Change:** Remove listener in dispose()
- **Risk:** Very Low
- **Impact:** Prevents memory accumulation
- **Time:** 2 minutes

**Add to dispose():**

```dart
@override
void dispose() {
  _jobListProvider.removeListener(_onJobListChanged); // ADD THIS
  _workAreasSubscription?.cancel();
  super.dispose();
}
```

---

### Task 3: Add Firestore Persistence Configuration

- **File:** `lib/main.dart`
- **Location:** Firebase initialization (after `Firebase.initializeApp()`)
- **Change:** Enable offline persistence
- **Risk:** Low
- **Impact:** Instant offline loads, reduced Firestore reads
- **Time:** 5 minutes

**Add after Firebase.initializeApp():**

```dart
await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

// ADD THIS:
FirebaseFirestore.instance.settings = const Settings(
  persistenceEnabled: true,
  cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
);
```

---

### Task 4: Add const Constructors to Static Widgets

- **Files:** `lib/widgets/job_list_grid.dart`, `lib/widgets/schedule_grid.dart`
- **Targets:** DataTableHeaderWidget, FrozenHeaderCell, static Text/Icon widgets
- **Change:** Add `const` keyword where possible
- **Risk:** Very Low
- **Impact:** 10-15% fewer rebuilds
- **Time:** 30-60 minutes

**Example Changes:**

```dart
// Before:
return DataTableHeaderWidget(text: 'Date');

// After:
return const DataTableHeaderWidget(text: 'Date');

// Before:
Icon(Icons.search, size: 24)

// After:
const Icon(Icons.search, size: 24)
```

---

### Task 5: Test Phase 1 Optimizations

- **Command:** `flutter run --profile`
- **Action:** Open DevTools, test filtering, navigation, search
- **Verify:** No crashes, filters work correctly, memory stable
- **Measure:** Baseline performance for comparison
- **Time:** 30 minutes

**Test Checklist:**

- [ ] Search in Job List (measure filter speed)
- [ ] Navigate between months in Schedule Grid
- [ ] Drag-drop jobs
- [ ] Open/close job cards
- [ ] Check memory usage in DevTools
- [ ] Verify Firestore read count

**Expected Results:**

- Search/filter: 40-60% faster
- Memory: Stable over time
- Firestore reads: Reduced by 20-30%

---

## ✅ Phase 2: Widget Optimization (1-2 days)

**Goal:** Eliminate cascading rebuilds through widget separation

### Task 6: Extract ScheduleJobCell to Separate Widget

- **New File:** `lib/widgets/schedule_job_cell.dart`
- **Change:** Move cell building logic from schedule_grid.dart
- **Risk:** Medium
- **Impact:** 30-50% faster grid rendering
- **Time:** 2-3 hours

**Create new widget:**

```dart
class ScheduleJobCell extends StatelessWidget {
  final String distributorId;
  final DateTime date;
  final List<Job> jobs;
  final double scale;

  const ScheduleJobCell({
    super.key,
    required this.distributorId,
    required this.date,
    required this.jobs,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    // Move cell logic here
    // Only this cell rebuilds when its data changes
  }
}
```

---

### Task 7: Implement Selector for ScheduleGrid

- **File:** `lib/widgets/schedule_grid.dart`
- **Line:** 149 (Consumer2)
- **Change:** Replace with Selector pattern
- **Risk:** Medium
- **Impact:** 50-70% fewer rebuilds
- **Time:** 3-4 hours

**Create data class:**

```dart
class _ScheduleGridData {
  final List<Distributor> distributors;
  final DateTime currentMonth;
  final bool hasJobsInNextMonth;
  final String currentMonthDisplay;

  _ScheduleGridData({
    required this.distributors,
    required this.currentMonth,
    required this.hasJobsInNextMonth,
    required this.currentMonthDisplay,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ScheduleGridData &&
          runtimeType == other.runtimeType &&
          distributors.length == other.distributors.length &&
          currentMonth == other.currentMonth &&
          hasJobsInNextMonth == other.hasJobsInNextMonth;

  @override
  int get hashCode => Object.hash(
    distributors.length,
    currentMonth,
    hasJobsInNextMonth,
  );
}
```

**Replace Consumer2:**

```dart
// Before:
return Consumer2<ScheduleProvider, ScaleProvider>(
  builder: (context, scheduleProvider, scaleProvider, child) {
    // Rebuilds everything on any change
  },
);

// After:
return Selector<ScheduleProvider, _ScheduleGridData>(
  selector: (context, provider) => _ScheduleGridData(
    distributors: provider.distributors,
    currentMonth: provider.currentMonth,
    hasJobsInNextMonth: provider.hasJobsInNextMonth,
    currentMonthDisplay: provider.currentMonthDisplay,
  ),
  builder: (context, data, child) {
    final scaleProvider = context.watch<ScaleProvider>();
    // Only rebuilds when _ScheduleGridData actually changes
  },
);
```

---

### Task 8: Extract JobCard Sub-Widgets

- **File:** `lib/widgets/job_card.dart` (1152 lines)
- **New Files:** Create separate widget files
- **Change:** Split into ClientListEditor, WorkAreaSection, DetailsSection
- **Risk:** Medium-High
- **Impact:** Each section rebuilds independently
- **Time:** 4-6 hours

**New widget structure:**

```dart
// lib/widgets/job_card_widgets/client_list_editor.dart
class ClientListEditor extends StatelessWidget {
  final Job job;
  final ValueChanged<List<String>> onClientsChanged;

  const ClientListEditor({
    super.key,
    required this.job,
    required this.onClientsChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Only rebuilds when job.clients changes
  }
}

// lib/widgets/job_card_widgets/work_area_section.dart
class WorkAreaSection extends StatelessWidget {
  final Job job;
  final List<WorkArea> workAreas;

  const WorkAreaSection({
    super.key,
    required this.job,
    required this.workAreas,
  });

  @override
  Widget build(BuildContext context) {
    // Only rebuilds when job.workArea or workAreas changes
  }
}
```

---

### Task 9: Test Phase 2 Widget Extraction

- **Command:** `flutter run --profile`
- **Action:** Full UI testing with DevTools Performance tab open
- **Verify:** All interactions work, measure rebuild reduction
- **Time:** 1 hour

**Test Checklist:**

- [ ] Drag-drop jobs between cells
- [ ] Edit job clients in job card
- [ ] Change work area
- [ ] Edit job details
- [ ] Navigate between months
- [ ] Watch DevTools timeline for rebuild count

**Expected Results:**

- Cell drag-drop: 50% faster
- Job editing: Isolated rebuilds only
- Grid navigation: 70% fewer rebuilds

---

## ✅ Phase 3: Advanced Optimizations (2-3 days)

**Goal:** Scalability for large datasets

### Task 10: Add Debounced notifyListeners to Providers

- **Files:** `lib/providers/schedule_provider.dart`, `lib/providers/job_list_provider.dart`
- **Change:** Batch rapid updates
- **Risk:** Low-Medium
- **Impact:** Smooth search typing, no lag
- **Time:** 2 hours

**Implementation:**

```dart
import 'dart:async';

class JobListProvider extends ChangeNotifier {
  Timer? _debounceTimer;

  void _debouncedNotifyListeners() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      notifyListeners();
    });
  }

  // Use instead of notifyListeners() for search/filter operations
  void setSearchQuery(String query) {
    _searchQuery = query;
    _debouncedNotifyListeners(); // Batches rapid typing
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }
}
```

---

### Task 11: Implement Virtual Scrolling for JobListGrid

- **File:** `lib/widgets/job_list_grid.dart`
- **Change:** Replace table with ListView.builder
- **Risk:** High (major UI change)
- **Impact:** 80%+ faster with 1000+ items
- **Time:** 6-8 hours

**Current Issue:** Renders all 1000+ rows even when only 20 visible

**Solution:**

```dart
// Replace DataTable with:
ListView.builder(
  controller: _verticalScrollController,
  itemCount: filteredJobs.length,
  itemExtent: 56.0, // Fixed row height for better performance
  itemBuilder: (context, index) {
    final job = filteredJobs[index];
    return JobListRow(
      key: ValueKey(job.id),
      job: job,
      onEdit: () => _showEditDialog(job),
      onDelete: () => _deleteJob(job),
    );
  },
)
```

**Benefits:**

- Only renders visible rows (~20 instead of 1000+)
- Smooth scrolling
- Minimal memory usage

---

### Task 12: Optimize Firestore Stream Management

- **File:** `lib/services/firestore_service.dart`
- **Lines:** 150-220 (streamJobsForDateRange)
- **Change:** Aggregate daily streams or implement batch loading
- **Risk:** High
- **Impact:** Reduce from 60+ listeners to 2-3
- **Time:** 6-8 hours

**Current Problem:**

```dart
// Creates 30 separate listeners for current month + 30 for next month
for (final date in dates) {
  final subscription = streamJobsForDate(date).listen(...);
  subscriptions.add(subscription);
}
```

**Option A: Aggregate Queries (Recommended)**

```dart
// Use Firestore query to get jobs for entire month range
Stream<List<Job>> streamJobsForMonth(DateTime month) {
  final monthStart = DateTime(month.year, month.month, 1);
  final monthEnd = DateTime(month.year, month.month + 1, 0);

  return _firestore
    .collection('schedule')
    .doc('daily')
    .collection('jobs')
    .where('date', isGreaterThanOrEqualTo: monthStart)
    .where('date', isLessThan: monthEnd.add(Duration(days: 1)))
    .snapshots()
    .map((snapshot) => snapshot.docs.map((doc) =>
      Job.fromMap(doc.id, doc.data())
    ).toList());
}
```

**Option B: Batch Loading**

- Load visible week initially
- Load rest of month in background
- Reduces initial load time by 70%

**Note:** Requires Firestore data structure review

---

### Task 13: Test Phase 3 Advanced Optimizations

- **Command:** `flutter run --profile`
- **Action:** Full regression testing
- **Verify:** No regressions, measure Firestore reads
- **Time:** 2-3 hours

**Full Test Suite:**

- [ ] Schedule grid drag-drop
- [ ] Job list filtering (1000+ items)
- [ ] Job list sorting
- [ ] Collection schedule navigation
- [ ] Offline mode (disconnect network)
- [ ] Firestore read count in console
- [ ] Memory usage over 30 minutes

**Expected Results:**

- Job list with 1000 items: Instant rendering
- Firestore reads: Reduced by 70-90%
- Memory usage: Flat over time
- Search typing: Zero lag

---

## ✅ Phase 4: Monitoring & Polish (1 day)

**Goal:** Track improvements and prevent regressions

### Task 14: Add Performance Monitoring Instrumentation

- **Files:** Create `lib/utils/performance_monitor.dart`
- **Change:** Add custom performance markers
- **Risk:** Low
- **Impact:** Track performance in production
- **Time:** 3-4 hours

**Implementation:**

```dart
import 'dart:developer' as developer;

class PerformanceMonitor {
  static void startMeasure(String name) {
    developer.Timeline.startSync(name);
  }

  static void endMeasure(String name) {
    developer.Timeline.finishSync();
  }

  static Future<T> measureAsync<T>(
    String name,
    Future<T> Function() operation,
  ) async {
    startMeasure(name);
    try {
      return await operation();
    } finally {
      endMeasure(name);
    }
  }
}

// Usage:
PerformanceMonitor.startMeasure('Job List Filter');
final filtered = _filteredJobListItems();
PerformanceMonitor.endMeasure('Job List Filter');
```

**Add Performance Overlay Toggle:**

```dart
// In main.dart
MaterialApp(
  showPerformanceOverlay: kDebugMode && _showPerformanceOverlay,
  // ... rest of app
)
```

---

### Task 15: Memory Profiling and Leak Detection

- **Tool:** Flutter DevTools Memory tab
- **Action:** Profile over 30-60 minutes of use
- **Verify:** No growing heap, all subscriptions cancelled
- **Time:** 2-3 hours

**Profiling Steps:**

1. Run `flutter run --profile`
2. Open DevTools → Memory tab
3. Take initial heap snapshot
4. Navigate through all screens 10x
5. Take second snapshot
6. Compare heap sizes
7. Check for retained objects

**Look For:**

- StreamSubscription not cancelled
- Provider listeners not removed
- Widget controllers not disposed
- Image caches growing unbounded

**Document findings in:** `docs/memory_profile_results.md`

---

### Task 16: Final Performance Audit and Documentation

- **Action:** Compare before/after metrics
- **Document:** Create performance best practices guide
- **Time:** 2-3 hours

**Metrics to Compare:**

| Metric                            | Before    | After       | Improvement |
| --------------------------------- | --------- | ----------- | ----------- |
| Job list filter time (1000 items) | ~500ms    | ~50ms       | 90%         |
| Schedule grid rebuild count       | Full grid | Single cell | 95%         |
| Firestore active listeners        | 60+       | 2-3         | 95%         |
| Initial load time                 | ~3s       | ~0.8s       | 73%         |
| Memory usage (30 min)             | Growing   | Stable      | ✓           |
| Search typing lag                 | 200ms     | 0ms         | 100%        |

**Create Best Practices Guide:**

- Widget optimization patterns
- Provider usage guidelines
- Firestore query patterns
- Performance monitoring setup

**Files to Create:**

- `docs/PERFORMANCE_BEST_PRACTICES.md`
- `docs/BEFORE_AFTER_METRICS.md`

---

## 📈 Expected Performance Gains by Phase

### Phase 1: Quick Wins

- **Filter Speed:** 40-60% faster
- **Memory:** Stable (no leaks)
- **Firestore Reads:** 20-30% reduction
- **Risk:** Very Low
- **Time:** 4-6 hours

### Phase 2: Widget Optimization

- **Rebuild Count:** 50-70% reduction
- **UI Responsiveness:** 2-3x faster
- **Grid Performance:** 40-50% faster
- **Risk:** Medium
- **Time:** 1-2 days

### Phase 3: Advanced Optimizations

- **Large Lists:** 80%+ faster
- **Firestore Reads:** 70-90% reduction
- **Search Typing:** Zero lag
- **Risk:** High
- **Time:** 2-3 days

### Phase 4: Monitoring

- **Production Tracking:** Enabled
- **Memory Leaks:** Detected/Fixed
- **Documentation:** Complete
- **Risk:** Low
- **Time:** 1 day

---

## 🛡️ Risk Mitigation Strategy

### For Each Task:

1. **Create feature branch** before changes
2. **Test in debug mode** first
3. **Profile in release mode** for accurate metrics
4. **Commit small, atomic changes** with clear messages
5. **Test full user workflows** before next task

### Rollback Plan:

- Keep git history clean
- Tag before each phase: `pre-phase-1`, `pre-phase-2`, etc.
- Document breaking changes
- Test on multiple devices/browsers

---

## 🚦 Current Status

- [ ] **Phase 1: Quick Wins** - Not Started

  - [ ] Task 1: Fix caching bug
  - [ ] Task 2: Fix memory leak
  - [ ] Task 3: Add Firestore persistence
  - [ ] Task 4: Add const constructors
  - [ ] Task 5: Test Phase 1

- [ ] **Phase 2: Widget Optimization** - Not Started

  - [ ] Task 6: Extract ScheduleJobCell
  - [ ] Task 7: Implement Selector
  - [ ] Task 8: Extract JobCard widgets
  - [ ] Task 9: Test Phase 2

- [ ] **Phase 3: Advanced Optimizations** - Not Started

  - [ ] Task 10: Debounced notifyListeners
  - [ ] Task 11: Virtual scrolling
  - [ ] Task 12: Optimize Firestore streams
  - [ ] Task 13: Test Phase 3

- [ ] **Phase 4: Monitoring & Polish** - Not Started
  - [ ] Task 14: Performance monitoring
  - [ ] Task 15: Memory profiling
  - [ ] Task 16: Final audit

---

## 🔧 Development Commands

```bash
# Profile mode (most accurate)
flutter run --profile -d chrome

# Release mode (test production performance)
flutter run --release -d chrome

# With DevTools
flutter run --profile -d chrome
# Then open: http://127.0.0.1:9100

# Check Firestore reads (in browser console)
# Look for: "ScheduleProvider: Received X jobs"

# Memory profiling
flutter run --profile
# DevTools → Memory → Take Snapshot

# Performance profiling
flutter run --profile
# DevTools → Performance → Record
```

---

## 📝 Notes

- Always test in **profile mode** for accurate performance metrics
- Debug mode has additional overhead that skews results
- Use Flutter DevTools for visual performance analysis
- Firestore persistence requires web browser support
- Virtual scrolling changes may require UI/UX review

---

## 🎯 Success Criteria

After completing all phases, the app should:

- ✅ Filter 1000+ jobs instantly (< 50ms)
- ✅ Schedule grid rebuilds only affected cells
- ✅ Search typing has zero lag
- ✅ Memory usage stays flat over time
- ✅ Firestore reads reduced by 70%+
- ✅ Initial load time under 1 second
- ✅ Smooth 60fps scrolling on all screens

---

**Ready to start?** Begin with **Task 1: Fix JobListProvider caching bug** - it's a 5-minute change with 40-60% improvement!
