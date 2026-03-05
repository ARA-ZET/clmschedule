# Vertex Editing Implementation - Copied from updated_map_view.dart

## Overview

This document explains how the vertex editing logic was copied from `updated_map_view.dart` to the shareable map editor to enable interactive polygon and polyline editing.

## Key Features Copied

### 1. Custom Marker Icons

**Vertex Markers (Red & White):**

- 16x16 pixel circular markers
- White fill with red border
- Shows existing polygon/polyline vertices
- Draggable to reposition vertices

**Midpoint Markers (Orange):**

- 12x12 pixel circular markers
- Orange fill with white border
- Appears between vertices
- Draggable to add new vertices

### 2. Marker Creation

Uses Flutter's `dart:ui` package to create custom bitmap markers:

```dart
Future<BitmapDescriptor> _createCircleMarkerIcon({
  required double size,
  required Color fillColor,
  required Color borderColor,
  required double borderWidth,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Draw circle with border
  // Convert to bitmap
  return BitmapDescriptor.bytes(pngBytes);
}
```

### 3. Midpoint Calculation

Calculates positions between vertices for adding new points:

```dart
List<LatLng> _calculateMidpoints(List<LatLng> points) {
  List<LatLng> midpoints = [];
  for (int i = 0; i < points.length; i++) {
    final current = points[i];
    final next = points[(i + 1) % points.length]; // Wrap around

    final midLat = (current.latitude + next.latitude) / 2;
    final midLng = (current.longitude + next.longitude) / 2;
    midpoints.add(LatLng(midLat, midLng));
  }
  return midpoints;
}
```

### 4. Building Editing Markers

Creates marker set for vertex editing:

```dart
Set<Marker> _buildEditingMarkers(ShareableMapProvider provider) {
  final markers = <Marker>{};

  // Add vertex markers (draggable)
  for (int i = 0; i < editingPoints.length; i++) {
    markers.add(Marker(
      markerId: MarkerId('vertex_$i'),
      icon: _vertexMarkerIcon!,
      position: editingPoints[i],
      draggable: true,
      onDrag: (newPosition) {
        provider.updateEditingPoint(i, newPosition);
      },
    ));
  }

  // Add midpoint markers
  final midpoints = _calculateMidpoints(editingPoints);
  for (int i = 0; i < midpoints.length; i++) {
    markers.add(Marker(
      markerId: MarkerId('midpoint_$i'),
      icon: _midpointMarkerIcon!,
      position: midpoints[i],
      draggable: true,
      onDragEnd: (newPosition) {
        provider.insertEditingPoint(i + 1, newPosition);
      },
    ));
  }

  return markers;
}
```

### 5. Map Tap Handling

Enhanced to support vertex editing mode:

```dart
static void _handleMapTap(
  BuildContext context,
  ShareableMapProvider provider,
  LatLng position
) {
  // Don't handle taps when editing vertices (let markers handle it)
  if (provider.isEditingVertices) {
    return;
  }

  // Handle drawing modes...
}

static void _handlePolygonTap(
  BuildContext context,
  ShareableMapProvider provider,
  String polygonId
) {
  provider.selectElement(polygonId);

  // Start vertex editing if in edit mode
  if (provider.drawingMode == DrawingMode.edit) {
    provider.startVertexEditing(polygonId);
  }
}
```

## Provider Methods Added

### Vertex Editing State

```dart
// Editing state
bool _isEditingVertices = false;
List<LatLng>? _editingPoints;
String? _editingElementId;

// Getters
bool get isEditingVertices => _isEditingVertices;
```

### Core Operations

```dart
/// Start editing vertices of a polygon or polyline
void startVertexEditing(String elementId) {
  // Find element and get its points
  // Set editing state
  _editingPoints = List<LatLng>.from(points);
  _isEditingVertices = true;
  _editingElementId = elementId;
}

/// Update a vertex position during drag
void updateEditingPoint(int index, LatLng newPosition, {bool temporary = false}) {
  _editingPoints![index] = newPosition;
  if (!temporary) {
    _hasUnsavedChanges = true;
  }
  notifyListeners();
}

/// Insert new vertex from midpoint drag
void insertEditingPoint(int index, LatLng position) {
  _editingPoints!.insert(index, position);
  _hasUnsavedChanges = true;
  notifyListeners();
}

/// Remove a vertex
void removeEditingPoint(int index) {
  if (_editingPoints!.length <= 3) return; // Maintain minimum
  _editingPoints!.removeAt(index);
  _hasUnsavedChanges = true;
  notifyListeners();
}

/// Save changes back to element
void saveVertexEditing() {
  // Update the element with new points
  // Clear editing state
  _stopVertexEditing();
}

/// Cancel without saving
void cancelVertexEditing() {
  _stopVertexEditing();
}
```

### Preview Methods

```dart
/// Get editing polygon preview
Polygon? getEditingPolygon() {
  if (!_isEditingVertices || _editingPoints == null) return null;

  return Polygon(
    polygonId: const PolygonId('editing_preview'),
    points: _editingPoints!,
    fillColor: Colors.blue.withValues(alpha: 0.2),
    strokeColor: Colors.blue.withValues(alpha: 0.8),
    strokeWidth: 3,
  );
}

/// Get editing polyline preview
Polyline? getEditingPolyline() {
  if (!_isEditingVertices || _editingPoints == null) return null;

  return Polyline(
    polylineId: const PolylineId('editing_preview'),
    points: _editingPoints!,
    color: Colors.blue.withValues(alpha: 0.8),
    width: 3,
  );
}
```

## Widget Integration

### MapViewWidget Updated

Changed from `StatelessWidget` to `StatefulWidget` to support marker building:

```dart
class MapViewWidget extends StatefulWidget {
  final Set<Marker> Function(ShareableMapProvider)? buildEditingMarkers;

  const MapViewWidget({super.key, this.buildEditingMarkers});
}
```

### Map Rendering Logic

```dart
// Only show completed polygons if not in vertex edit mode
if (!provider.isEditingVertices)
  ...map.getAllGoogleMapsPolygons(...),

// Show editing preview
if (provider.isEditingVertices && provider.getEditingPolygon() != null)
  provider.getEditingPolygon()!,

// Add editing markers
if (widget.buildEditingMarkers != null)
  ...widget.buildEditingMarkers!(provider),
```

### Parent Widget Pass-Through

```dart
Stack(
  children: [
    MapViewWidget(buildEditingMarkers: _buildEditingMarkers),
    const MapSidebarWidget(),
    const MapDrawingToolbarWidget(),
    const MapDrawingControlsWidget(),
  ],
)
```

## User Flow

### Starting Edit Mode

1. User clicks **Edit Tool** (pencil icon) in toolbar
2. `DrawingMode.edit` is activated
3. User clicks a **polygon or polyline** on map
4. `_handlePolygonTap()` called → `provider.startVertexEditing()`
5. Vertex markers appear on polygon

### Editing Vertices

**Moving Existing Vertex:**

1. User drags a red/white vertex marker
2. `onDrag` callback fires → `provider.updateEditingPoint()`
3. Preview updates in real-time

**Adding New Vertex:**

1. User drags an orange midpoint marker
2. `onDragStart` sets `_draggingMidpointIndex`
3. `onDrag` updates temporary position
4. `onDragEnd` → `provider.insertEditingPoint()`
5. New vertex inserted, markers rebuild

### Saving Changes

1. User clicks **Save** button
2. `provider.saveVertexEditing()` called
3. Element updated with new points
4. Editing mode exits, markers removed

### Cancelling

1. User clicks **Cancel** button
2. `provider.cancelVertexEditing()` called
3. Changes discarded
4. Editing mode exits

## Benefits of This Approach

✅ **Intuitive** - Direct manipulation of vertices
✅ **Visual** - Custom markers clearly show edit points
✅ **Flexible** - Easy to add/move/remove vertices
✅ **Real-time** - Preview updates as you drag
✅ **Non-destructive** - Changes aren't saved until confirmed
✅ **Reusable** - Provider methods work for any polygon/polyline

## Differences from updated_map_view.dart

1. **State location:** Editing state in provider vs widget state
2. **Element identification:** Uses element IDs instead of WorkArea objects
3. **Multiple layers:** Supports editing across multiple layers
4. **Element types:** Works with CustomPolygon, MapPolyline, MapPoint models
5. **Integration:** Part of shareable maps system vs standalone map view

## Testing Checklist

- [ ] Vertex markers appear when entering edit mode
- [ ] Midpoint markers appear between vertices
- [ ] Dragging vertex updates position
- [ ] Dragging midpoint adds new vertex
- [ ] Preview shows changes in real-time
- [ ] Save button updates element
- [ ] Cancel button discards changes
- [ ] Minimum vertex count enforced
- [ ] Works for both polygons and polylines
- [ ] Multiple edits in sequence work correctly

## Future Enhancements

- [ ] Context menu on vertex for deletion
- [ ] Double-click vertex to delete
- [ ] Keyboard shortcuts (Delete key)
- [ ] Snap to grid option
- [ ] Angle constraints (90°, 45°)
- [ ] Distance measurements during drag
- [ ] Undo/redo for vertex operations
