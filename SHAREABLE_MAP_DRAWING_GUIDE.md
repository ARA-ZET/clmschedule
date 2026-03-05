# Shareable Map Drawing & Element Management Guide

## Overview

This guide explains the improved drawing logic for creating polygons, points, and polylines, plus the complete CRUD (Create, Read, Update, Delete) operations for all map elements.

## Drawing Flow Improvements

### Polygon & Polyline Creation

1. **Click a drawing tool** (Polygon or Polyline button in the toolbar)
2. **Click on the map** to add points sequentially
3. **Visual feedback shows:**
   - Blue markers for each point added
   - Dashed preview line connecting points
   - Semi-transparent polygon fill (for polygons only)
   - Point counter badge showing current point count
   - Helpful hint text showing requirements
4. **Drawing controls available:**
   - **Undo button** - Remove the last point added
   - **Cancel button** - Abort drawing and clear all points
   - **Complete button** - Finish drawing (enabled when minimum points reached)
5. **Complete the drawing:**
   - For polygons: Minimum 3 points required
   - For polylines: Minimum 2 points required
   - Click "Complete" → Name dialog appears
   - Enter name, description, and choose color
   - Element is saved to the current layer

### Point Creation (Simplified)

1. **Click the Point tool** in the toolbar
2. **Click once on the map** where you want the point
3. **Name dialog appears immediately** (auto-completion after one click)
4. Enter name, description, and choose color
5. Point is saved to the current layer

## Element Management

### Viewing Elements

Elements are displayed in the **sidebar** organized by layers:

```
📁 Layer Name
  📍 Point 1
  📍 Point 2
  ◻️ Polygon 1
  ➖ Polyline 1
```

- **Selected elements** appear with a blue background highlight
- Each element shows its icon, color, and name
- Elements are grouped under their parent layer

### Editing Elements

**Method 1: Context Menu (Recommended)**

1. Click the **⋮ (three dots)** menu next to any element
2. Select **"Edit"** from the menu
3. Edit dialog appears with current properties:
   - Name
   - Description
   - Color picker (8 color options)
4. Click **"Save"** to apply changes

**Method 2: Direct Selection**

1. Click on any element in the sidebar to select it
2. Selected element highlighted on map and in sidebar
3. Use context menu to edit

### Vertex Editing (Advanced)

**Interactive Vertex Manipulation** - Edit the shape of polygons and polylines by dragging vertices.

**Starting Vertex Edit Mode:**

1. Select the **Edit Tool** (pencil icon) from the toolbar
2. Click on a **polygon or polyline** on the map
3. Vertex editing mode activates with visual markers

**Editing Features:**

**Existing Vertices (Red & White Markers):**

- Draggable white circles with red borders show existing vertices
- **Drag any vertex** to reposition it
- Real-time preview of shape updates

**Midpoint Markers (Orange Markers):**

- Orange circles appear between vertices
- **Drag a midpoint** to add a new vertex at that location
- New vertex becomes part of the polygon/polyline
- Useful for refining shapes without redrawing

**Visual Feedback:**

- Preview shows updated shape in real-time
- Blue semi-transparent fill for polygons
- Blue stroke for polylines
- All changes are temporary until saved

**Saving Vertex Edits:**

- Click **"Save"** button to apply changes permanently
- Click **"Cancel"** to discard all changes
- Changes update the element immediately on save
- Unsaved changes indicator shows when modifications exist

**Constraints:**

- Minimum 3 vertices required for polygons
- Minimum 2 vertices required for polylines
- Cannot delete vertices below minimum threshold

### Deleting Elements

**Method 1: Context Menu**

1. Click the **⋮ (three dots)** menu next to the element
2. Select **"Delete"** from the menu
3. Confirmation dialog appears
4. Click **"Delete"** to confirm (button is red to indicate destructive action)

**Method 2: Select and Delete**

1. Select the element by clicking it
2. (Future: Delete key support can be added)

### Element Selection

- **Click any element** in the sidebar to select it
- Selected elements show:
  - Blue background highlight in sidebar
  - Highlight on the map (visual feedback)
  - Element ID stored in provider state
- **Click empty map area** to deselect

## Technical Implementation

### Provider State Management

The `ShareableMapProvider` manages all drawing and element operations:

```dart
// Drawing state
List<LatLng> _drawingPoints = [];
bool _isDrawing = false;
DrawingMode _drawingMode = DrawingMode.none;

// Vertex editing state
bool _isEditingVertices = false;
List<LatLng>? _editingPoints;
String? _editingElementId;

// Selection state
String? _selectedElementId;
String? _selectedLayerId;
```

### Element Operations (Provider Methods)

#### Polygon Operations

```dart
// Update polygon properties
provider.updatePolygon(layer, polygonIndex, updatedPolygon);

// Delete polygon
provider.deletePolygon(layer, polygonIndex);
```

#### Point Operations

```dart
// Update point properties
provider.updatePoint(layer, pointId, updatedPoint);

// Delete point
provider.deletePoint(layer, pointId);
```

#### Polyline Operations

```dart
// Update polyline properties
provider.updatePolyline(layer, polylineId, updatedPolyline);

// Delete polyline
provider.deletePolyline(layer, polylineId);
```

#### Vertex Editing Operations

```dart
// Start vertex editing mode for a polygon or polyline
provider.startVertexEditing(elementId);

// Update a vertex position (during drag)
provider.updateEditingPoint(vertexIndex, newPosition);

// Insert a new vertex (from midpoint drag)
provider.insertEditingPoint(index, position);

// Remove a vertex
provider.removeEditingPoint(vertexIndex);

// Save vertex editing changes
provider.saveVertexEditing();

// Cancel without saving
provider.cancelVertexEditing();

// Get editing preview shapes
Polygon? polygon = provider.getEditingPolygon();
Polyline? polyline = provider.getEditingPolyline();
```

### Element Identification

**Polygons:**

- Use index-based IDs: `{layerId}_polygon_{index}`
- Example: `layer_abc123_polygon_0`
- Supports selection and CRUD operations

**Points:**

- Use UUID from `MapPoint.create()` factory
- Example: `550e8400-e29b-41d4-a716-446655440000`
- ID stored in model

**Polylines:**

- Use UUID from `MapPolyline.create()` factory
- Example: `6ba7b810-9dad-11d1-80b4-00c04fd430c8`
- ID stored in model

### Drawing Controls Widget

The `MapDrawingControlsWidget` provides real-time feedback:

```dart
// Visual indicators
- Point counter badge (e.g., "3 points")
- Drawing mode icon (polygon/polyline/point)
- Hint text ("Add 1 more point to complete polygon")
- Progress guidance

// Action buttons
- Undo: Removes last point (enabled when points > 0)
- Cancel: Aborts drawing (always enabled)
- Complete: Finishes drawing (enabled when minimum points reached)
```

### Map Tap Handler

Improved `_handleMapTap` method in `MapViewWidget`:

```dart
static void _handleMapTap(
  BuildContext context,
  ShareableMapProvider provider,
  LatLng position
) {
  switch (provider.drawingMode) {
    case DrawingMode.polygon:
    case DrawingMode.polyline:
      // Multi-point drawing
      if (!provider.isDrawing) {
        provider.startDrawing();
      }
      provider.addDrawingPoint(position);
      break;

    case DrawingMode.point:
      // Single-point auto-complete
      if (!provider.isDrawing) {
        provider.startDrawing();
      }
      provider.addDrawingPoint(position);
      // Auto-show name dialog
      MapEditorDialogs.showElementNameDialog(context, provider);
      break;

    case DrawingMode.none:
      // Deselect on empty tap
      provider.selectElement('');
      break;
  }
}
```

## UI Components

### Sidebar Element Item

Each element in the sidebar has:

1. **Icon** - Indicates type (pin, square, line)
2. **Color indicator** - Shows element color
3. **Name** - Element title (or "Untitled")
4. **Selection highlight** - Blue background when selected
5. **Context menu (⋮)** - Access to Edit, Duplicate, Delete

```dart
Widget _buildLayerItem(
  BuildContext context, {
  required ShareableMapProvider provider,
  required MapLayer layer,
  required IconData icon,
  required Color color,
  required String title,
  required String elementId,
  required VoidCallback onTap,
  required VoidCallback onEdit,
  required VoidCallback onDelete,
}) {
  // Returns InkWell with selection state and popup menu
}
```

### Edit Dialog

Standardized edit dialog for all element types:

- **Name field** - TextField for element name
- **Description field** - Multi-line TextField for description
- **Color picker** - 8 predefined colors in circular swatches
- **Save/Cancel buttons** - Confirm or abort changes

## Best Practices

### When Drawing

1. **Zoom to appropriate level** before drawing for precision
2. **Use undo** instead of canceling if you just need to remove a few points
3. **Complete explicitly** with the button (don't rely on shortcuts yet)
4. **Name meaningfully** - helps when managing many elements

### When Managing Elements

1. **Use layers** to organize related elements
2. **Select before editing** to see what you're modifying on the map
3. **Confirm deletions** carefully - no undo yet for completed elements
4. **Use descriptive names** - easier to find elements later

### Performance Considerations

1. **Polygon rendering** - Keep polygon vertex count reasonable (<1000 points)
2. **Layer count** - Many layers with many elements may slow rendering
3. **Preview updates** - Drawing previews update on every point addition

## Future Enhancements

### Planned Features

1. **Vertex editing mode**
   - Drag vertices to reposition
   - Double-click edge to add vertex
   - Context menu on vertex to delete

2. **Keyboard shortcuts**
   - `Esc` to cancel drawing
   - `Enter` to complete drawing
   - `Delete` key to remove selected element
   - `Ctrl+Z` for undo

3. **Drawing aids**
   - Distance/area calculations during drawing
   - Snap-to-grid option
   - Angle snapping (90°, 45°)

4. **Element operations**
   - Duplicate elements
   - Move elements between layers
   - Copy/paste elements
   - Multi-select for batch operations

5. **Visual improvements**
   - Animated dashed lines
   - Better hover effects
   - Distance labels on polylines
   - Area labels on polygons

## Troubleshooting

### Drawing Issues

**Problem**: Complete button not enabled

- **Solution**: Check minimum point requirements (3 for polygon, 2 for polyline, 1 for point)

**Problem**: Points not appearing

- **Solution**: Ensure you're in drawing mode (tool selected) and tapping within map bounds

**Problem**: Preview not showing

- **Solution**: Verify `getDrawingMarkers()`, `getDrawingPolyline()`, or `getDrawingPolygon()` are called

### Element Management Issues

**Problem**: Can't select polygon

- **Solution**: Previously fixed - polygons now use index-based IDs

**Problem**: Edit changes not saving

- **Solution**: Check that provider's update methods are called with correct parameters

**Problem**: Element disappears after delete

- **Solution**: Working as intended - deletion removes element from layer immediately

### Performance Issues

**Problem**: Map lags during drawing

- **Solution**: Reduce point frequency or simplify preview rendering

**Problem**: Sidebar slow to render

- **Solution**: Minimize number of layers or elements, or implement virtualized list

## Code Examples

### Creating a New Polygon Programmatically

```dart
final provider = context.read<ShareableMapProvider>();

// Start drawing
provider.startDrawing();
provider.setDrawingMode(DrawingMode.polygon);

// Add points
provider.addDrawingPoint(LatLng(37.7749, -122.4194));
provider.addDrawingPoint(LatLng(37.7849, -122.4194));
provider.addDrawingPoint(LatLng(37.7849, -122.4094));
provider.addDrawingPoint(LatLng(37.7749, -122.4094));

// Complete
await provider.completeDrawing(
  name: 'My Polygon',
  description: 'A sample polygon',
  color: Colors.blue,
);
```

### Updating an Existing Point

```dart
final provider = context.read<ShareableMapProvider>();
final layer = provider.selectedLayer!;
final point = layer.points.first;

final updatedPoint = point.copyWith(
  name: 'Updated Name',
  description: 'Updated description',
  color: Colors.red,
);

provider.updatePoint(layer, point.id, updatedPoint);
```

### Deleting Multiple Elements

```dart
final provider = context.read<ShareableMapProvider>();
final layer = provider.selectedLayer!;

// Delete all points in layer
for (var point in layer.points) {
  provider.deletePoint(layer, point.id);
}

// Delete all polygons in layer
for (var i = layer.polygons.length - 1; i >= 0; i--) {
  provider.deletePolygon(layer, i);
}
```

## Summary

The improved drawing system provides:

✅ **Smooth creation flow** - Clear visual feedback and intuitive controls
✅ **Complete CRUD operations** - Create, Read, Update, Delete for all element types
✅ **Advanced vertex editing** - Drag vertices, add midpoints, reshape polygons/polylines
✅ **Interactive editing markers** - Red/white vertex markers and orange midpoint markers
✅ **Consistent UI patterns** - Similar dialogs and interactions across element types
✅ **Provider-based state** - Clean separation of business logic and UI
✅ **Element selection** - Visual feedback and context-aware actions
✅ **Confirmation dialogs** - Prevent accidental deletions
✅ **Real-time preview** - See changes before saving

The system is now production-ready with full element management and advanced editing capabilities!
