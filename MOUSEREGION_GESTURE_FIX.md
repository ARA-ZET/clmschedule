# MouseRegion Gesture Management Fix

## Issue Summary

The shareable map editor was experiencing "Cannot hit test a render box with no size" errors, causing tool buttons (polygon, polyline, point, edit) to be completely unresponsive. The root cause was improper placement of `MouseRegion` widgets without sized parent containers.

## Root Cause

`MouseRegion` widgets require a parent widget with defined size constraints to function properly. When placed directly inside `Positioned` or `Center` widgets without size constraints, they cannot perform hit testing, causing:

1. Console flooding with "Cannot hit test a render box with no size" errors
2. UI elements becoming unresponsive
3. Tool selection failing silently

## Incorrect Pattern

```dart
// ❌ WRONG - MouseRegion without size
Positioned(
  left: 0, top: 0,
  child: MouseRegion(
    onEnter: disableMapGestures,
    child: Widget(),
  ),
)
```

## Correct Pattern

```dart
// ✅ CORRECT - MouseRegion with sized parent
Positioned(
  left: 0, top: 0,
  child: Container(
    width: 300,  // Explicit size
    child: MouseRegion(
      onEnter: disableMapGestures,
      child: Widget(),
    ),
  ),
)
```

## Files Fixed

### 1. shareable_map_editor.dart

**MapSidebarWidget (Lines 525-548)**

- **Issue**: `Positioned → MouseRegion → Container(width: 300)`
- **Fix**: `Positioned → Container(width: 300) → MouseRegion`
- Moved MouseRegion inside Container to leverage its fixed width

**MapDrawingToolbarWidget (Lines 565-577)**

- **Issue**: `Positioned → MouseRegion → MapDrawingToolbar`
- **Fix**: `Positioned → MouseRegion → SizedBox(width: 80) → MapDrawingToolbar`
- Added SizedBox wrapper to provide explicit width for MouseRegion

**MapDrawingControlsWidget (Lines 592-703)**

- **Issue**: `Center → MouseRegion → Material → Container`
- **Fix**: `Center → Material → MouseRegion → Container`
- Moved MouseRegion inside Material widget which provides intrinsic sizing from its child Container

### 2. map_drawing_toolbar.dart

**Import Addition**

- Added `import '../../providers/shareable_maps/map_gesture_provider.dart';`

**Dialog Wrapping** - 3 dialogs wrapped with MouseRegion:

1. **\_showFinishDrawingDialog** (Line ~213)
   - Pattern: `showDialog → MouseRegion → StatefulBuilder → AlertDialog`
   - Purpose: Save polygon/polyline/point with name, description, color picker
2. **\_confirmDelete** (Line ~353)
   - Pattern: `showDialog → MouseRegion → AlertDialog`
   - Purpose: Confirm deletion of selected element
3. **\_confirmCancelEditing** (Line ~471)
   - Pattern: `showDialog → MouseRegion → AlertDialog`
   - Purpose: Confirm discarding unsaved vertex editing changes

**Fixed Syntax Issues**:

- Corrected AlertDialog structure (content and actions as named parameters)
- Removed duplicate closing parentheses from previous failed multi-replace
- Ensured proper nesting: `showDialog → builder → MouseRegion → child → AlertDialog`

### 3. map_layers_sidebar.dart

**Import Addition**

- Added `import '../../providers/shareable_maps/map_gesture_provider.dart';`

**Dialog Wrapping** - 11 dialogs wrapped with MouseRegion:

1. **\_deleteLayer** (Line ~596) - Confirm layer deletion
2. **\_showShareDialog** (Line ~617) - Share map (Phase 2 placeholder)
3. **\_showRenameMapDialog** (Line ~638) - Rename map with StatefulBuilder
4. **\_showMapStatistics** (Line ~658) - Display map statistics
5. **\_showAddLayerDialog** (Line ~682) - Add new layer with color picker (StatefulBuilder)
6. **\_showEditLayerDialog** (Line ~786) - Edit layer name/visibility/color (StatefulBuilder)
7. **\_showEditPolygonDialog** (Line ~890) - Edit polygon name/description/color (StatefulBuilder)
8. **\_deletePolygon** (Line ~987) - Confirm polygon deletion
9. **\_showEditPointDialog** (Line ~1011) - Edit point name/description/color (StatefulBuilder)
10. **\_deletePoint** (Line ~1108) - Confirm point deletion
11. **\_showEditPolylineDialog** (Line ~1132) - Edit polyline name/description/color (StatefulBuilder)
12. **\_deletePolyline** (Line ~1229) - Confirm polyline deletion

**Skipped**:

- `_showImportDialog` (Line ~624) - Uses `MapImportDialog` custom widget, not AlertDialog

## MouseRegion Dialog Pattern

### Standard AlertDialog

```dart
showDialog(
  context: context,
  builder: (context) => MouseRegion(
    onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures(),
    onExit: (_) => context.read<MapGestureProvider>().enableMapGestures(),
    child: AlertDialog(
      title: Text('Dialog Title'),
      content: Text('Dialog content'),
      actions: [...],
    ),
  ),
);
```

### StatefulBuilder AlertDialog

```dart
showDialog(
  context: context,
  builder: (context) => MouseRegion(
    onEnter: (_) => context.read<MapGestureProvider>().disableMapGestures(),
    onExit: (_) => context.read<MapGestureProvider>().enableMapGestures(),
    child: StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Dialog Title'),
        content: Column(...),
        actions: [...],
      ),
    ),
  ),
);
```

## Benefits

1. **Fixed UI Responsiveness**: Tool buttons (Select, Polygon, Polyline, Point, Edit) now respond correctly
2. **Eliminated Console Errors**: No more "Cannot hit test a render box with no size" errors
3. **Proper Gesture Management**:
   - Map gestures disabled when mouse enters UI elements
   - Map gestures re-enabled when mouse exits UI elements
   - Prevents accidental map panning/zooming over dialogs/toolbar/sidebar
4. **Consistent Pattern**: All dialogs follow the same MouseRegion wrapping pattern

## Testing Checklist

- [x] Toolbar tool buttons respond to clicks
- [x] Sidebar opens and closes without errors
- [x] Drawing controls appear during drawing operations
- [x] All dialogs disable map gestures when open
- [x] Zero compilation errors in all files
- [x] No console errors during normal operation

## Technical Notes

### Why MouseRegion Needs Size

Flutter's hit testing system requires widgets to report their size during the render phase. `MouseRegion` delegates size calculation to its child. If the child doesn't have a size yet (e.g., inside `Positioned` without constraints), hit testing fails.

**Widget Size Hierarchy:**

- `Container(width: X)` - Intrinsic size from width/height
- `SizedBox(width: X)` - Fixed size
- `Material` - Size from child
- `Positioned(width: X)` - Explicit bounds
- `Positioned()` without size - No size until child sized

### MapGestureProvider

The `MapGestureProvider` manages the Google Maps `webGestureHandling` property:

- `disableMapGestures()` → Sets to `'none'` (map ignores all gestures)
- `enableMapGestures()` → Sets to `'greedy'` (map captures all gestures)

This prevents conflicts when users interact with UI elements overlaying the map.

## Related Files

- [shareable_map_editor.dart](lib/widgets/shareable_maps/shareable_map_editor.dart) - Main editor with toolbar/sidebar/controls
- [map_drawing_toolbar.dart](lib/widgets/shareable_maps/map_drawing_toolbar.dart) - Tool selection and drawing dialogs
- [map_layers_sidebar.dart](lib/widgets/shareable_maps/map_layers_sidebar.dart) - Layer management and element CRUD
- [map_gesture_provider.dart](lib/providers/shareable_maps/map_gesture_provider.dart) - Web gesture handling provider
- [SHAREABLE_MAP_DRAWING_GUIDE.md](SHAREABLE_MAP_DRAWING_GUIDE.md) - User guide for drawing features
- [VERTEX_EDITING_IMPLEMENTATION.md](VERTEX_EDITING_IMPLEMENTATION.md) - Technical guide for vertex editing

## Status

✅ **COMPLETE** - All MouseRegion sizing issues fixed, all dialogs wrapped, zero errors
