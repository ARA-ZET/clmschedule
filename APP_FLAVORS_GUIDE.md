# App Flavors Guide

## Overview

CLM Schedule now supports app flavors to create separate builds for different feature sets. This reduces Firebase streams, app complexity, and allows targeted functionality.

## Available Flavors

### 1. **CLM** (Default - Full Featured)

- **Package ID**: `com.example.clmschedule`
- **Version Suffix**: `-clm`
- **App Name**: CLM Schedule
- **Features**:
  - ✅ Schedule Grid (Distributor scheduling)
  - ✅ Job List Management
  - ✅ Collection Schedule
  - ✅ Happy Sun (Solar panel projects)

**Use Case**: Full-featured app with all scheduling capabilities including both distribution and solar panel management

### 2. **Happy Sun** (Specialized)

- **Package ID**: `com.example.clmschedule`
- **Version Suffix**: `-happysun`
- **App Name**: Happy Sun
- **Features**:
  - ❌ Schedule Grid (Disabled)
  - ✅ Job List Provider (filtered to window cleaning & solar panel jobs only)
  - ✅ Happy Sun (Solar panel project management)
  - ❌ Collection Schedule (Disabled)

**Use Case**: Ultra-simplified app focused exclusively on solar panel project management. Single tab interface showing only Happy Sun projects. Job List Provider runs in the background but only streams window cleaning and solar panel job types.

**Tab Count**: 1 tab (Happy Sun only)

### 3. **Maps** (Testing & Debug)

- **Package ID**: N/A (Development only)
- **Version Suffix**: `-maps`
- **App Name**: Maps Testing
- **Features**:
  - ❌ Schedule Grid (Disabled)
  - ❌ Job List Management (Disabled)
  - ❌ Collection Schedule (Disabled)
  - ❌ Happy Sun (Disabled)
  - ✅ Shareable Maps Only

**Use Case**: Ultra-lightweight testing flavor for rapid maps development. Only loads Auth + ShareableMapProvider. No heavy providers, no Firebase streams. Perfect for testing drawing operations, map layers, KML import, and maps UI without interference from other features.

**Providers Loaded**: 2 only (Auth + Maps)
**Tab Count**: None (direct maps testing screen)
**Build Time**: ~50% faster than full CLM flavor
**Memory Usage**: ~60% less than full CLM flavor

**Perfect for:**

- 🧪 Testing drawing features (polygons, polylines, points)
- 🐛 Debugging visual feedback
- 🎨 UI iteration on maps components
- 🚀 Hot reload rapid development
- 💰 Reduced Firebase reads during development

**📚 See [MAPS_FLAVOR_GUIDE.md](MAPS_FLAVOR_GUIDE.md) for detailed maps testing guide**

**Note**: The CLM and Happy Sun flavors share the same package ID for Firebase compatibility, so they cannot be installed side-by-side. Maps flavor is development-only and does not have a package ID.

### 4. **Track Editor** (KML/GPX Editor)

- **Package ID**: `com.example.clmschedule`
- **Version Suffix**: `-trackEditor`
- **App Name**: CLM Track Editor
- **Firebase**: Uses the **main `clmschedule` Firebase project** — no separate app
- **Features**:
  - ✅ KML/KMZ polygon import with style parsing
  - ✅ GPX track & waypoint import
  - ✅ Google My Maps KML downloader
  - ✅ Google Maps visualisation (polygons, tracks, waypoints)
  - ✅ Point-in-polygon analysis
  - ✅ GPX export per polygon region
  - ✅ Multi-tab workspace
  - ❌ Schedule Grid
  - ❌ Job List
  - ❌ Happy Sun
  - ❌ Collection Schedule

**Use Case**: Standalone CLM track & territory editor. Import KML/GPX files from
Google My Maps or device, visualise on a map, group waypoints by polygon, and
export filtered GPX files. All within the main Firebase project.

**Run commands:**
```bash
# Web (recommended — drag-and-drop uses browser APIs)
./build_flavors.sh trackEditor web

# Android
./build_flavors.sh trackEditor run

# Build APK
./build_flavors.sh trackEditor debug
```

**Providers Loaded**: 6 (TE-prefixed — isolated from main app providers)
**Firebase streams**: None (no Firestore listeners)

## Firebase Stream Reduction

### CLM Flavor (Full Featured)

- Schedule Provider (current + next month)
- Job List Provider
- Collection Schedule Provider
- Happy Sun Project Provider
- Inventory Provider
- Tool Settings Provider
- Auth, Chat, Status providers

**All features enabled** - No stream reduction

### Happy Sun Flavor (Lighter)

- Job List Provider (Firebase-level filter: only window cleaning & solar panel job types streamed)
- Happy Sun Project Provider
- Inventory Provider
- Tool Settings Provider
- Auth, Chat, Status providers

**Excluded Providers**:

- ❌ Schedule Provider (no schedule grid)
- ❌ Collection Schedule Provider (disabled feature)

**Offline Support** (Happy Sun Only):

- ✅ **Local data storage** using Hive for offline-first operation
- ✅ **Automatic sync** when connectivity restored
- ✅ **Real-time connectivity monitoring** with visual indicators
- ✅ **Pending changes queue** for reliable data sync
- ✅ **Works in areas with poor or no internet** - field-ready
- 📚 See [OFFLINE_SUPPORT_GUIDE.md](OFFLINE_SUPPORT_GUIDE.md) for details

**Job List Filtering**: JobListProvider uses Firebase query-level filtering (`whereIn` clause) to only stream window cleaning and solar panel jobs, significantly reducing data transfer and bandwidth usage.

**Estimated Firebase Reads Saved**: ~70% reduction by:

- Removing Schedule Provider (current + next month streams)
- Removing Collection Schedule Provider
- Filtering Job List Provider to only 2 job types instead of all 11 at the Firebase query level (not just client-side)

**Tab Count**: 1 tab (Happy Sun only) vs 4 tabs in CLM flavor

**UI Simplification**:

- Single-tab interface eliminates tab navigation complexity entirely
- **No AppBar** - maximal screen space for project content
- **SafeArea protection** - content respects system UI (status bar, navigation bar)
- Sign-out button integrated directly into the project screen header (top-right)
- No TabBar, distributor management, debug buttons, or settings complexity
- Focused interface for viewing and managing window cleaning and solar panel projects only

### Maps Flavor (Minimal - Testing Only)

- Auth Provider (authentication only)
- Shareable Maps Provider (no Firebase streams, in-memory only)

**Excluded Providers**:

- ❌ Schedule Provider
- ❌ Job List Provider
- ❌ Collection Schedule Provider
- ❌ Happy Sun Project Provider
- ❌ Inventory Provider
- ❌ Tool Settings Provider
- ❌ Chat Provider
- ❌ All heavy providers with Firebase streams

**Performance Benefits**:

- ⚡ **Build Time**: ~50% faster than CLM flavor
- 💾 **Memory Usage**: ~60% less than CLM flavor
- 🚀 **Hot Reload**: Near-instant during development
- 💰 **Firebase Reads**: ~95% reduction (only auth state)

**Use Case**: Pure testing/debugging environment for shareable maps development. No interference from other features, no heavy provider initialization, maximum development speed.

**📚 See [MAPS_FLAVOR_GUIDE.md](MAPS_FLAVOR_GUIDE.md) for detailed usage guide**

## Building Flavors

### Quick Start - VS Code Shortcuts (Recommended)

The fastest way to run flavors is using VS Code's Run and Debug panel:

1. **Press `F5`** or click the Run and Debug icon in VS Code
2. **Select flavor** from the dropdown at the top:
   - "Maps Testing (Maps Flavor) ⚡" - Ultra-fast testing (recommended for maps dev)
   - "CLM Schedule (CLM Flavor)" - Full-featured app
   - "Happy Sun (Happy Sun Flavor)" - Lightweight app
3. **Click the green play button** or press `F5`

**Keyboard Shortcuts**:

- `F5` - Run selected configuration
- `Ctrl+Shift+D` (Windows/Linux) or `Cmd+Shift+D` (Mac) - Open Run and Debug panel
- Use arrow keys to switch between configurations in dropdown

**Available Configurations**:

- Maps Testing (Maps Flavor) ⚡ - Debug mode (fastest for maps testing)
- CLM Schedule (CLM Flavor) - Debug mode
- Happy Sun (Happy Sun Flavor) - Debug mode
- Maps Testing (Maps Flavor - Release) - Release mode
- CLM Schedule (CLM Flavor - Release) - Release mode
- Happy Sun (Happy Sun Flavor - Release) - Release mode

### Using Build Script (Alternative)

Use the `build_flavors.sh` script for command-line builds:

```bash
# Run Maps flavor (fastest for testing)
./build_flavors.sh maps run

# Run CLM flavor
./build_flavors.sh clm run

# Run Happy Sun flavor
./build_flavors.sh happysun run

# Build debug APK for Maps
./build_flavors.sh maps debug

# Build debug APK for CLM
./build_flavors.sh clm debug

# Build debug APK for Happy Sun
./build_flavors.sh happysun debug

# Build release APK
./build_flavors.sh clm release
./build_flavors.sh happysun release
./build_flavors.sh maps release

# Build App Bundle for Play Store
./build_flavors.sh clm bundle
./build_flavors.sh happysun bundle
```

### Android Builds

#### CLM Flavor (Production)

```bash
# Debug
flutter build apk --flavor clm --target lib/main_clm.dart --dart-define=FLAVOR=clm

# Release
flutter build apk --release --flavor clm --target lib/main_clm.dart --dart-define=FLAVOR=clm
```

#### Happy Sun Flavor (Production)

```bash
# Debug
flutter build apk --flavor happysun --target lib/main_happysun.dart --dart-define=FLAVOR=happysun

# Release
flutter build apk --release --flavor happysun --target lib/main_happysun.dart --dart-define=FLAVOR=happysun
```

### Web Builds

Web doesn't support flavors natively, but you can achieve similar results:

#### CLM Flavor

```bash
flutter build web --dart-define=FLAVOR=clm
```

#### Happy Sun Flavor

```bash
flutter build web --dart-define=FLAVOR=happysun
```

### iOS Builds

iOS flavor support can be added by creating schemes in Xcode:

1. Open `ios/Runner.xcworkspace`
2. Create schemes for `clm` and `happysun`
3. Set configuration settings per scheme

```bash
# Once iOS schemes are set up:
flutter build ios --flavor clm --target lib/main_clm.dart --dart-define=FLAVOR=clm
flutter build ios --flavor happysun --target lib/main_happysun.dart --dart-define=FLAVOR=happysun
```

## Configuration Details

### Flavor Config Location

- [lib/config/flavor_config.dart](lib/config/flavor_config.dart)

### Entry Points

- CLM Flavor: [lib/main_clm.dart](lib/main_clm.dart)
- Happy Sun Flavor: [lib/main_happysun.dart](lib/main_happysun.dart)

### Android Gradle Configuration

- [android/app/build.gradle.kts](android/app/build.gradle.kts)

### Feature Flags

```dart
// CLM Flavor (Full Featured)
FlavorConfig.instance.enableHappySun        // true - Happy Sun enabled
FlavorConfig.instance.enableCollectionSchedule  // true - Collection Schedule enabled
FlavorConfig.instance.isCLM                 // true
FlavorConfig.instance.isHappySun            // false
FlavorConfig.instance.appName              // "CLM Schedule"

// Happy Sun Flavor (Specialized)
FlavorConfig.instance.enableHappySun        // true - Happy Sun enabled
FlavorConfig.instance.enableCollectionSchedule  // false - Collection Schedule disabled
FlavorConfig.instance.isCLM                 // false
FlavorConfig.instance.isHappySun            // true
FlavorConfig.instance.appName              // "Happy Sun"
```

## Conditional Provider Setup

Providers are conditionally initialized based on flavor:

```dart
// main.dart provider setup:

// ScheduleProvider only for CLM flavor (Happy Sun doesn't use Schedule Grid)
if (FlavorConfig.instance.isCLM)
  ChangeNotifierProvider(create: (context) => ScheduleProvider()),

// All flavors get Happy Sun providers
ChangeNotifierProvider(create: (context) => InventoryProvider(...)),
ChangeNotifierProvider(create: (context) => HappySunProjectProvider()),
ChangeNotifierProvider(create: (context) => ToolSettingsProvider()),
// JobListProvider filters data based on flavor
// Happy Sun: Only window cleaning & solar panel jobs
// CLM: All job types
ChangeNotifierProvider(create: (context) => JobListProvider(...)),
// Only CLM flavor gets Collection Schedule provider
if (FlavorConfig.instance.isCLM)
  ChangeNotifierProxyProvider<JobListProvider, CollectionScheduleProvider>(...),
```

## Technical Implementation Details

### Provider Initialization

In `lib/main.dart`, the `_initializeProvidersAsync()` method conditionally initializes providers:

```dart
Future<void> _initializeProvidersAsync() async {
  final scheduleProvider = FlavorConfig.instance.isCLM
    ? context.read<ScheduleProvider>()
    : null;
  final jobListProvider = context.read<JobListProvider>();
  // ... other providers

  await Future.wait([
    if (scheduleProvider != null) scheduleProvider.initialize(),
    jobListProvider.initialize(),
    // ...
  ]);
}
```

### Firebase Query-Level Filtering

The Happy Sun flavor uses Firebase `whereIn` filtering to reduce data transfer at the source.

**Service Layer** (`lib/services/job_list_service.dart`):

```dart
Stream<List<JobListItem>> getJobListItems(DateTime month, [List<JobType>? jobTypes]) {
  var query = _monthlyService.collection
      .where('monthYear', isEqualTo: monthKey);

  // Apply job type filter at Firebase query level (not client-side)
  if (jobTypes != null && jobTypes.isNotEmpty) {
    // Use enum.name (e.g., "windowCleaning") not displayName,
    // since Firebase stores jobType as enum.name
    final jobTypeStrings = jobTypes.map((type) => type.name).toList();
    query = query.where('jobType', whereIn: jobTypeStrings);
  }

  return query.snapshots().map(...);
}
```

**Provider Layer** (`lib/providers/job_list_provider.dart`):

```dart
void _setupCurrentMonthListener() {
  // Happy Sun: Filter at Firebase level to only window cleaning & solar panel
  List<JobType>? jobTypesFilter;
  if (FlavorConfig.instance.isHappySun) {
    jobTypesFilter = [JobType.windowCleaning, JobType.solarPanelCleaning];
  }

  _jobListSubscription = _jobListService
      .getJobListItems(_currentMonth, jobTypesFilter)
      .listen(...);
}
```

**Performance Benefits**:

- ~82% reduction in Job List data transfer (2 job types vs 11)
- Lower bandwidth usage and faster load times
- Firestore only sends relevant documents over network
- Combined with removed providers: ~70% total Firebase read reduction

## Testing Flavors Locally

### Quick Test (VS Code)

1. Open Run and Debug panel (`F5` or `Cmd/Ctrl+Shift+D`)
2. Select "CLM Schedule (CLM Flavor)" or "Happy Sun (Happy Sun Flavor)"
3. Press `F5` to run

### Quick Test (Command Line)

```bash
# Using build script (recommended)
./build_flavors.sh clm run
./build_flavors.sh happysun run

# Or using Flutter CLI directly
flutter run --flavor clm -t lib/main_clm.dart --dart-define=FLAVOR=clm
flutter run --flavor happysun -t lib/main_happysun.dart --dart-define=FLAVOR=happysun
```

### Verify Flavor is Active

Check console output on app startup - you should see the flavor name in loading screen and app bar.

## Future Enhancements

- [ ] iOS scheme configuration
- [ ] Separate Firebase projects per flavor
- [ ] Flavor-specific analytics events
- [ ] Different app icons per flavor
- [ ] Deep link configuration per flavor

## Troubleshooting

### Issue: Provider not found error

**Solution**: Ensure you're using the correct flavor. Some providers only exist in specific flavors.

### Issue: Build fails with "FLAVOR not defined"

**Solution**: Always pass `--dart-define=FLAVOR=<flavor_name>` when building.

### Issue: Wrong app name displays

**Solution**: Check that `FlavorConfig.instance` is properly initialized and conditionals are working.

### Issue: Collection Schedule and Happy Sun both visible

**Solution**: In **clm flavor**, this is correct - both tabs should be visible. In **happysun flavor**, only Happy Sun should show.

### Issue: Happy Sun features not working in clm flavor

**Solution**: CLM flavor now has all features enabled. Ensure you're building with the correct flavor target.

### Issue: Firebase error "No matching client found for package name"

**Solution**: Both flavors use the same base package ID (`com.example.clmschedule`) to share the Firebase project. If you've modified `applicationIdSuffix`, remove it or add the new package variants to your Firebase project console.

**To use separate Firebase projects per flavor:**

1. Create separate Firebase projects for each flavor
2. Download `google-services.json` for each
3. Place them in flavor-specific directories:
   - `android/app/src/clm/google-services.json`
   - `android/app/src/happysun/google-services.json`
4. Re-enable `applicationIdSuffix` in `build.gradle.kts`

## Distribution

Both flavors share the same package ID (`com.example.clmschedule`) for Firebase compatibility but have different version name suffixes to distinguish between them:

**CLM Flavor**: `com.example.clmschedule` (version: x.x.x-clm)  
**Happy Sun Flavor**: `com.example.clmschedule` (version: x.x.x-happysun)

**Important**: Since they share the same package ID, you cannot install both flavors on the same device simultaneously. Installing one will replace the other. However, they use the same Firebase project, simplifying backend configuration.
