# Map Gesture Provider - Web Gesture Management Guide

## Overview

The `MapGestureProvider` manages dynamic gesture handling for Google Maps on web platforms, preventing conflicts between map interactions (pan, zoom) and UI widget interactions (scroll, click) by automatically disabling map gestures when the mouse hovers over overlay UI elements.

## Problem Statement

On web platforms, Google Maps captures scroll and drag events by default. When UI widgets (sidebars, toolbars, dialogs) are positioned over the map, users experience frustrating conflicts:

- **Sidebar scrolling triggers map pan**: Trying to scroll a list in the sidebar moves the map instead
- **Toolbar clicks sometimes hit map**: Click events can pass through to the map
- **Dialog interactions feel unresponsive**: Modal overlays still allow map interaction underneath

## Solution Architecture

### MapGestureProvider

A simple `ChangeNotifier` that controls Google Maps' `webGestureHandling` property:

```dart
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MapGestureProvider extends ChangeNotifier {
  WebGestureHandling _gestureHandling = WebGestureHandling.greedy;

  /// Current web gesture handling mode
  WebGestureHandling get gestureHandling => _gestureHandling;

  /// Disable map gestures (when mouse over UI widgets)
  void disableMapGestures() {
    if (_gestureHandling != WebGestureHandling.none) {
      _gestureHandling = WebGestureHandling.none;
      notifyListeners();
    }
  }

  /// Enable map gestures (when mouse over map)
  void enableMapGestures() {
    if (_gestureHandling != WebGestureHandling.greedy) {
      _gestureHandling = WebGestureHandling.greedy;
      notifyListeners();
    }
  }
}
```

**Location**: `/lib/providers/map_gesture_provider.dart`

### WebGestureHandling Modes

| Mode          | Behavior                                                 |
| ------------- | -------------------------------------------------------- |
| `greedy`      | Map captures all gestures - normal panning/zooming works |
| `none`        | Map ignores all gestures - UI widgets receive all events |
| `cooperative` | Ctrl+scroll to zoom (not used in this implementation)    |
| `auto`        | Platform default (not used in this implementation)       |

## Implementation Guide

### Step 1: Wrap Screen with ChangeNotifierProvider

In your map editor widget's `build` method:

```dart
@override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: _buildAppBar(),
    body: ChangeNotifierProvider(
      create: (_) => MapGestureProvider(),
      child: Builder(
        builder: (context) {
          return Consumer<ShareableMapProvider>(
            builder: (context, provider, child) {
              return Stack(
                children: [
                  _buildMapView(context, provider),
                  _buildSidebar(context, provider),
                  _buildToolbar(context, provider),
                ],
              );
            },
          );
        },
      ),
    ),
  );
}
```

**Key Points**:

- `ChangeNotifierProvider` creates the `MapGestureProvider` instance
- `Builder` widget provides correct context descendant from the provider
- All child widgets now have access to `MapGestureProvider` via context

### Step 2: Connect GoogleMap to Provider

In your map view widget:

```dart
Widget _buildMapView(BuildContext context, ShareableMapProvider provider) {
  return GoogleMap(
    initialCameraPosition: CameraPosition(
      target: provider.currentMap!.defaultCenter,
      zoom: provider.currentMap!.defaultZoom,
    ),
    webGestureHandling: context.watch<MapGestureProvider>().gestureHandling,
    // ... other properties
  );
}
```

**Key Points**:

- Use `context.watch<MapGestureProvider>()` to rebuild when gesture mode changes
- `webGestureHandling` property only affects web builds (ignored on mobile)
- Method signature must include `BuildContext context` parameter

### Step 3: Wrap UI Widgets with MouseRegion

For each overlay widget (sidebar, toolbar, dialogs):

```dart
Widget _buildSidebar(BuildContext context, ShareableMapProvider provider) {
  return Positioned(
    left: 0,
    top: 0,
    bottom: 0,
    child: MouseRegion(
      onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures(),
      onExit: (_) => context.read<MapGestureProvider>().enableMapGestures(),
      child: Container(
        width: 300,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
            ),
          ],
        ),
        child: YourSidebarContent(),
      ),
    ),
  );
}
```

**Key Points**:

- `MouseRegion.onEnter`: Fires when mouse cursor enters widget bounds
- `MouseRegion.onExit`: Fires when mouse cursor leaves widget bounds
- Use `context.read<MapGestureProvider>()` for actions (doesn't rebuild)
- Wrap the outermost visible widget (e.g., Container, Card, Material)

## Example Usage in ShareableMapEditor

### File Structure

```
lib/
├── providers/
│   ├── map_gesture_provider.dart          ← New provider
│   └── shareable_maps/
│       └── shareable_map_provider.dart
└── widgets/
    └── shareable_maps/
        ├── shareable_map_editor.dart      ← Updated with gesture management
        ├── map_layers_sidebar.dart
        └── map_drawing_toolbar.dart
```

### Updated Method Signatures

All `_build*` methods now accept `BuildContext context` as first parameter:

```dart
// Before
Widget _buildMapView(ShareableMapProvider provider) { ... }
Widget _buildSidebar(ShareableMapProvider provider) { ... }
Widget _buildToolbar(ShareableMapProvider provider) { ... }

// After
Widget _buildMapView(BuildContext context, ShareableMapProvider provider) { ... }
Widget _buildSidebar(BuildContext context, ShareableMapProvider provider) { ... }
Widget _buildToolbar(BuildContext context, ShareableMapProvider provider) { ... }
```

### Complete ShareableMapEditor Example

```dart
class _ShareableMapEditorState extends State<ShareableMapEditor> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: ChangeNotifierProvider(
        create: (_) => MapGestureProvider(),
        child: Builder(
          builder: (context) {
            return Consumer<ShareableMapProvider>(
              builder: (context, provider, child) {
                if (provider.currentMap == null) {
                  return _buildEmptyState(provider);
                }

                return Stack(
                  children: [
                    _buildMapView(context, provider),
                    if (provider.isSidebarVisible)
                      _buildSidebar(context, provider),
                    _buildDrawingToolbar(context, provider),
                    if (provider.isDrawing)
                      _buildDrawingControls(context, provider),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildMapView(BuildContext context, ShareableMapProvider provider) {
    return GoogleMap(
      // ... camera, markers, polygons, etc.
      webGestureHandling: context.watch<MapGestureProvider>().gestureHandling,
    );
  }

  Widget _buildSidebar(BuildContext context, ShareableMapProvider provider) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: MouseRegion(
        onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures(),
        onExit: (_) => context.read<MapGestureProvider>().enableMapGestures(),
        child: Container(
          width: 300,
          color: Colors.white,
          child: const MapLayersSidebar(),
        ),
      ),
    );
  }

  Widget _buildDrawingToolbar(BuildContext context, ShareableMapProvider provider) {
    return Positioned(
      right: 16,
      top: 16,
      child: MouseRegion(
        onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures(),
        onExit: (_) => context.read<MapGestureProvider>().enableMapGestures(),
        child: const MapDrawingToolbar(),
      ),
    );
  }

  Widget _buildDrawingControls(BuildContext context, ShareableMapProvider provider) {
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: MouseRegion(
          onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures(),
          onExit: (_) => context.read<MapGestureProvider>().enableMapGestures(),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drawing controls UI
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

## Common Patterns

### Pattern 1: Modal Dialogs

For dialogs that appear over the map:

```dart
void _showDialog(BuildContext context) {
  // Disable map gestures when dialog appears
  context.read<MapGestureProvider>().disableMapGestures();

  showDialog(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text('Example Dialog'),
        content: Text('Map gestures are disabled'),
      );
    },
  ).then((_) {
    // Re-enable map gestures when dialog closes
    context.read<MapGestureProvider>().enableMapGestures();
  });
}
```

### Pattern 2: Bottom Sheets

```dart
void _showBottomSheet(BuildContext context) {
  context.read<MapGestureProvider>().disableMapGestures();

  showModalBottomSheet(
    context: context,
    builder: (sheetContext) {
      return Container(
        height: 300,
        child: YourSheetContent(),
      );
    },
  ).whenComplete(() {
    context.read<MapGestureProvider>().enableMapGestures();
  });
}
```

### Pattern 3: Draggable Widgets

```dart
Widget _buildDraggablePanel(BuildContext context) {
  return Draggable(
    feedback: MouseRegion(
      onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures(),
      onExit: (_) => context.read<MapGestureProvider>().enableMapGestures(),
      child: YourDragFeedback(),
    ),
    child: YourChild(),
  );
}
```

## Testing

### Manual Testing Checklist

- [ ] Hover mouse over sidebar → Map pan/zoom disabled
- [ ] Move mouse back to map → Map pan/zoom enabled
- [ ] Scroll sidebar content → Doesn't move map
- [ ] Click toolbar buttons → No map click-through
- [ ] Drawing controls visible → Map gestures disabled while hovering
- [ ] Open dialog → Map gestures disabled
- [ ] Close dialog → Map gestures re-enabled

### Unit Test Example

```dart
void main() {
  group('MapGestureProvider', () {
    test('initializes with greedy gesture handling', () {
      final provider = MapGestureProvider();
      expect(provider.gestureHandling, WebGestureHandling.greedy);
    });

    test('disableMapGestures sets none and notifies', () {
      final provider = MapGestureProvider();
      var notified = false;
      provider.addListener(() => notified = true);

      provider.disableMapGestures();

      expect(provider.gestureHandling, WebGestureHandling.none);
      expect(notified, true);
    });

    test('enableMapGestures sets greedy and notifies', () {
      final provider = MapGestureProvider();
      provider.disableMapGestures();
      var notified = false;
      provider.addListener(() => notified = true);

      provider.enableMapGestures();

      expect(provider.gestureHandling, WebGestureHandling.greedy);
      expect(notified, true);
    });

    test('does not notify if mode unchanged', () {
      final provider = MapGestureProvider();
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      provider.enableMapGestures(); // Already greedy
      expect(notifyCount, 0);

      provider.disableMapGestures();
      expect(notifyCount, 1);

      provider.disableMapGestures(); // Already none
      expect(notifyCount, 1);
    });
  });
}
```

## Performance Considerations

### Optimization Tips

1. **Use `context.read()` for Actions**

   ```dart
   // Good - doesn't rebuild
   onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures()

   // Bad - triggers unnecessary rebuilds
   onEnter: (_) => context.watch<MapGestureProvider>().disableMapGestures()
   ```

2. **Use `context.watch()` for Display**

   ```dart
   // Good - rebuilds when state changes
   webGestureHandling: context.watch<MapGestureProvider>().gestureHandling

   // Bad - won't update when state changes
   webGestureHandling: context.read<MapGestureProvider>().gestureHandling
   ```

3. **Conditional Notifications**
   The provider only calls `notifyListeners()` when the mode actually changes:
   ```dart
   void disableMapGestures() {
     if (_gestureHandling != WebGestureHandling.none) {  // Check before updating
       _gestureHandling = WebGestureHandling.none;
       notifyListeners();
     }
   }
   ```

## Troubleshooting

### Issue: "Could not find Provider<MapGestureProvider>"

**Cause**: Calling `context.read<>()` or `context.watch<>()` from wrong context

**Solution**: Ensure `ChangeNotifierProvider` wraps your widget tree, and use `Builder` to get correct descendant context:

```dart
// Wrong
body: ChangeNotifierProvider(
  create: (_) => MapGestureProvider(),
  child: _buildContent(), // This context is ABOVE the provider
)

// Correct
body: ChangeNotifierProvider(
  create: (_) => MapGestureProvider(),
  child: Builder(
    builder: (context) {  // This context is BELOW the provider
      return _buildContent(context);
    },
  ),
)
```

### Issue: Map gestures don't disable

**Causes**:

1. Missing `context.watch<>()` in GoogleMap widget
2. `webGestureHandling` property not set
3. MouseRegion callbacks not firing

**Solutions**:

1. Use `context.watch<MapGestureProvider>().gestureHandling`
2. Verify GoogleMap has `webGestureHandling:` parameter
3. Check MouseRegion actually wraps visible widget with size

### Issue: UI feels sluggish

**Cause**: Using `context.watch<>()` in too many places causes excessive rebuilds

**Solution**: Only use `watch` where you need to rebuild on state changes:

- GoogleMap widget: Use `watch`
- Button callbacks: Use `read`
- Event handlers: Use `read`

## Browser Compatibility

| Browser | MouseRegion Support | webGestureHandling Support |
| ------- | ------------------- | -------------------------- |
| Chrome  | ✅ Full             | ✅ Full                    |
| Firefox | ✅ Full             | ✅ Full                    |
| Safari  | ✅ Full             | ✅ Full                    |
| Edge    | ✅ Full             | ✅ Full                    |

## Mobile Behavior

The `webGestureHandling` property is **web-only** and has no effect on mobile builds:

- **iOS**: Ignored (uses native map gestures)
- **Android**: Ignored (uses native map gestures)
- **Web**: Active gesture management

The provider can safely be used in cross-platform code without conditional compilation.

## Migration Guide

### Updating Existing Map Screens

1. **Add import**:

   ```dart
   import '../../providers/map_gesture_provider.dart';
   ```

2. **Update build method**:
   - Wrap body with `ChangeNotifierProvider`
   - Add `Builder` widget for correct context
   - Add `context` parameter to all `_build*` methods

3. **Update GoogleMap**:

   ```dart
   webGestureHandling: context.watch<MapGestureProvider>().gestureHandling,
   ```

4. **Wrap overlay widgets**:
   - Add `MouseRegion` around sidebar, toolbars, controls
   - Set `onEnter` to `disableMapGestures()`
   - Set `onExit` to `enableMapGestures()`

### Before/After Comparison

**Before**:

```dart
body: Consumer<ShareableMapProvider>(
  builder: (context, provider, child) {
    return Stack([
      GoogleMap(webGestureHandling: WebGestureHandling.greedy),
      Container(width: 300, child: Sidebar()),
    ]);
  },
)
```

**After**:

```dart
body: ChangeNotifierProvider(
  create: (_) => MapGestureProvider(),
  child: Builder(
    builder: (context) {
      return Consumer<ShareableMapProvider>(
        builder: (context, provider, child) {
          return Stack([
            GoogleMap(
              webGestureHandling: context.watch<MapGestureProvider>().gestureHandling,
            ),
            MouseRegion(
              onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures(),
              onExit: (_) => context.read<MapGestureProvider>().enableMapGestures(),
              child: Container(width: 300, child: Sidebar()),
            ),
          ]);
        },
      );
    },
  ),
)
```

## Future Enhancements

Potential improvements for future versions:

1. **Gesture Policy Configuration**

   ```dart
   MapGestureProvider(
     defaultMode: WebGestureHandling.cooperative,
     disabledMode: WebGestureHandling.none,
   )
   ```

2. **Automatic Dialog Detection**
   Hook into Navigator to auto-disable gestures when routes pushed

3. **Performance Metrics**
   Track gesture mode change frequency for optimization

4. **Accessibility Support**
   Keyboard navigation alternatives when gestures disabled

## References

- [Google Maps Flutter Plugin](https://pub.dev/packages/google_maps_flutter_web)
- [Provider Package Documentation](https://pub.dev/packages/provider)
- [Flutter MouseRegion API](https://api.flutter.dev/flutter/widgets/MouseRegion-class.html)
- [WebGestureHandling Options](https://developers.google.com/maps/documentation/javascript/interaction#overview)

---

**Last Updated**: February 18, 2026  
**Version**: 1.0.0  
**Maintainer**: CLM Schedule Development Team
