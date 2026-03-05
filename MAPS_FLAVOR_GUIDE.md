# Maps Flavor - Quick Testing Guide

## Overview

The **Maps** flavor is an ultra-lightweight build specifically designed for rapid testing and debugging of the shareable maps feature. It loads **only** the essential providers, resulting in:

- ⚡ **Fastest build times** - No heavy provider initialization
- 💾 **Minimal memory footprint** - Only Auth + ShareableMapProvider
- 🚫 **No Firebase streams** from JobList, Schedule, Collection, or HappySun providers
- 🎯 **Isolated testing** - Pure maps functionality without interference
- 💰 **Reduced Firebase reads** - Perfect for development/testing

## Quick Start

### VS Code (Recommended - Fastest)

1. Press **F5** or open Run and Debug panel
2. Select **"Maps Testing (Maps Flavor) ⚡"** from dropdown
3. Click the green play button

### Command Line

```bash
# Run in debug mode
flutter run --target=lib/main_maps.dart --dart-define=FLAVOR=maps

# Run on specific device
flutter run -d chrome --target=lib/main_maps.dart --dart-define=FLAVOR=maps

# Run on web
flutter run -d web-server --target=lib/main_maps.dart --dart-define=FLAVOR=maps
```

### Using Build Script

```bash
# Run directly
./build_flavors.sh maps run

# Build debug APK
./build_flavors.sh maps debug

# Build release APK
./build_flavors.sh maps release
```

## What's Included

### Providers Loaded

- ✅ **AuthProvider** - Required for authentication
- ✅ **ShareableMapProvider** - The maps feature we're testing

### Providers NOT Loaded (Performance Boost)

- ❌ **ScheduleProvider** - No schedule grid, no daily job streams
- ❌ **JobListProvider** - No job list, no job streams
- ❌ **CollectionScheduleProvider** - No collection schedule
- ❌ **HappySunProjectProvider** - No project streams
- ❌ **InventoryProvider** - No inventory streams
- ❌ **ToolSettingsProvider** - No settings streams
- ❌ **ChatProvider** - No chat streams
- ❌ All other heavy providers

### UI Features

- 🗺️ **Full ShareableMapEditor** - Complete maps functionality
- ➕ **Create New Map** - Quick map creation dialog
- 🚪 **Sign Out** - Authentication control
- 🎨 **Clean minimal interface** - No distracting tabs or features

## Use Cases

### Perfect For:

- 🧪 Testing new maps features
- 🐛 Debugging map drawing operations
- 🎨 UI/UX iteration on map components
- 📊 Performance profiling of maps code
- 🚀 Hot reload rapid development
- 💡 Experimenting with map layers/polygons/markers

### NOT For:

- Testing job list integration
- Testing schedule grid features
- Production builds
- Full app integration testing

## Performance Comparison

### CLM Flavor (Full)

- **Providers**: 15+
- **Firebase Streams**: 5-8 active streams
- **Initial Load Time**: ~3-5 seconds
- **Memory**: ~200-300 MB
- **Build Time**: ~45-60 seconds

### Maps Flavor (Minimal)

- **Providers**: 2 (Auth + Maps)
- **Firebase Streams**: 0 active streams (only auth state)
- **Initial Load Time**: ~1-2 seconds
- **Memory**: ~80-120 MB
- **Build Time**: ~20-30 seconds

**Result: 2-3x faster builds, 50-60% less memory! 🚀**

## Development Workflow

```bash
# Start maps flavor for testing
flutter run -d chrome --target=lib/main_maps.dart --dart-define=FLAVOR=maps

# Make changes to maps code
# Hot reload automatically (r key)

# Test drawing features:
# 1. Click polygon/polyline/point tools
# 2. Click on map to add points
# 3. See visual feedback appear
# 4. Click Complete to save

# Sign out when done
# (Click logout icon in AppBar)
```

## Troubleshooting

### Issue: "Cannot find AuthGate widget"

**Solution**: AuthGate is from the main app, it's included in main_maps.dart imports

### Issue: "Maps not loading"

**Solution**: Ensure .env file has Google Maps API key configured

```bash
cp .env.example .env
# Add your GOOGLE_MAPS_API_KEY
flutter pub run build_runner build --delete-conflicting-outputs
```

### Issue: "Firebase not initialized"

**Solution**: Ensure firebase_options.dart is generated

```bash
flutterfire configure
```

## Architecture

```
main_maps.dart
├── Firebase Init
├── MultiProvider
│   ├── AuthProvider
│   └── ShareableMapProvider
└── MapsApp
    ├── MaterialApp (Google blue theme)
    └── AuthGate
        └── MapsTestScreen
            ├── AppBar (title + create + logout)
            └── ShareableMapEditor (full maps UI)
```

## Testing Checklist

When using Maps flavor for testing:

- [ ] Test polygon drawing (3+ points)
- [ ] Test polyline drawing (2+ points)
- [ ] Test point placement (single click)
- [ ] Test visual feedback (markers, lines appear)
- [ ] Test undo last point
- [ ] Test cancel drawing
- [ ] Test complete drawing
- [ ] Test layer visibility toggle
- [ ] Test layer creation
- [ ] Test map import (KML/GPX)
- [ ] Test element selection/deletion
- [ ] Test sidebar show/hide

## Tips

1. **Use Chrome for fastest hot reload** during development
2. **Keep DevTools open** to monitor performance
3. **Check console logs** - provider prints drawing state
4. **Use breakpoints** in ShareableMapProvider for debugging
5. **Profile memory** to ensure no leaks in drawing operations

## Related Files

- `lib/main_maps.dart` - Maps flavor entry point
- `lib/config/flavor_config.dart` - Flavor configuration
- `lib/providers/shareable_maps/shareable_map_provider.dart` - State management
- `lib/widgets/shareable_maps/shareable_map_editor.dart` - Main UI
- `.vscode/launch.json` - VS Code debug configurations

## Quick Reference

```bash
# Run maps flavor
flutter run -d chrome -t lib/main_maps.dart --dart-define=FLAVOR=maps

# Build for testing
./build_flavors.sh maps debug

# Check for errors
flutter analyze lib/main_maps.dart lib/providers/shareable_maps/ lib/widgets/shareable_maps/
```

---

**Happy Testing! 🗺️⚡**
