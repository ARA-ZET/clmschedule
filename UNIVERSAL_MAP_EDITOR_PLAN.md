# Universal Map Editor Plan

## Overview

Transform the existing Shareable Map Editor into a **universal map API/engine** that can be used as the base for creating, editing, and managing map data across the entire CLM Schedule application through an **Adapter Pattern**.

## Architecture: Adapter Pattern with `MapDataAdapter`

```
┌─────────────────────────────────────────────────┐
│           ShareableMapEditor (UI)                │
│  Drawing tools, layers, vertex editing, import   │
└──────────────────────┬──────────────────────────┘
                       │
              ┌────────▼────────┐
              │ MapDataAdapter  │  ← Abstract interface
              │  (load / save)  │
              └────────┬────────┘
                       │
        ┌──────────────┼──────────────┬────────────────┐
        │              │              │                │
   ┌────▼────┐   ┌────▼────┐   ┌────▼─────┐   ┌─────▼──────┐
   │WorkArea │   │Schedule │   │JobList   │   │Standalone  │
   │Adapter  │   │Job      │   │Area      │   │Adapter     │
   │         │   │Adapter  │   │Adapter   │   │(existing)  │
   └─────────┘   └─────────┘   └──────────┘   └────────────┘
   Firestore      Firestore     Cloud Storage   In-memory
   /workAreas/    daily docs    KML/GPX files   (no persist)
```

## Current State Summary

| Component                | What Exists                                                                                                                                                           |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ShareableMapEditor**   | Full-featured widget: draw polygons/polylines/points, layers, vertex editing, import KML/GPX, export, style editing. Self-contained `Scaffold` with its own `AppBar`. |
| **ShareableMapProvider** | In-memory state only. No persistence — creates a map, you edit it, and it's gone when you leave.                                                                      |
| **WorkArea model**       | Simple: `id, name, description, polygonPoints, kmlFileName`. Stored in `/workAreas/{id}` Firestore collection. Has `WorkAreaService` for CRUD + KML import.           |
| **Job.workMaps**         | `List<CustomPolygon>` embedded inside schedule jobs (daily docs). Edited via `ScheduleProvider` polygon commands.                                                     |
| **JobListItem**          | Has `area` (String, typically a Google Maps link) and `customPolygons` (`List<CustomPolygon>`). No integrated map editor.                                             |
| **KmlParserService**     | Parses KML/KMZ/GPX → `ParsedMapResult` (polygons, polylines, points). Used by the shareable map import dialog.                                                        |
| **GpxParserService**     | Separate GPX→`GpxTrack` parser used by track editor.                                                                                                                  |

---

## Use Cases

### Use Case 1: Work Areas Collection (`/workAreas/`)

- **Data source**: Firestore collection `/workAreas/{id}`
- **Streamed via**: `StreamSubscription<List<WorkArea>>` in `ScheduleProvider`
- **Goal**: Open the map editor pre-loaded with all work area polygons; create, edit, delete them visually; save changes back to Firestore
- **Adapter**: `WorkAreaCollectionAdapter`

### Use Case 2: Schedule Job Work Maps (`Job.workMaps`)

- **Data source**: `List<CustomPolygon>` embedded in schedule `Job` objects
- **Streamed via**: Job streams in `ScheduleProvider`
- **Goal**: Edit the polygons attached to a specific schedule job
- **Adapter**: `ScheduleJobAdapter`

### Use Case 3: Job List Area (`JobListItem.area` + `JobListItem.customPolygons`)

- **Data source**: `JobListItem` with `area` field (currently a Google Maps link) and `customPolygons` list
- **Goal**: Create custom map areas, export as KML/GPX, store in Cloud Storage, generate shareable link
- **Adapter**: `JobListAreaAdapter`

### Use Case 4: Standalone (existing behavior)

- **Data source**: In-memory `ShareableMap`
- **Goal**: Create/import maps for general use
- **Adapter**: `StandaloneAdapter`

---

## Phase 1: Core Abstraction Layer

### 1.1 — `MapDataAdapter` abstract class

**File**: `lib/shareable_maps/adapters/map_data_adapter.dart`

```dart
abstract class MapDataAdapter {
  String get adapterId;
  String get displayName;
  MapEditorCapabilities get capabilities;
  Future<ShareableMap> load();
  Future<void> save(ShareableMap map);
  bool get autoSave => false;
  Future<void> dispose() async {}
}
```

### 1.2 — `MapEditorCapabilities` class

Feature flags that control which editor UI elements are available:

- `canDrawPolygons`, `canDrawPolylines`, `canDrawPoints`
- `canImportKml`, `canImportGpx`, `canExport`
- `canManageLayers`, `canEditStyle`, `canDelete`
- `showSaveButton`, `readOnly`
- Named constructors: `.full()`, `.polygonOnly()`, `.viewOnly()`

### 1.3 — Provider changes

- Add `MapDataAdapter? _adapter` field to `ShareableMapProvider`
- Add `loadFromAdapter(MapDataAdapter)` / `saveToAdapter()` methods
- Keep standalone mode working (no adapter = current behavior)

### 1.4 — Editor widget changes

- `ShareableMapEditor` conditionally shows/hides UI based on `capabilities`
- Toolbar hides polyline/point buttons when `canDrawPolylines`/`canDrawPoints` is false
- Sidebar hides layer management when `canManageLayers` is false
- AppBar shows Save button when `showSaveButton` is true
- Import buttons hidden when `canImportKml`/`canImportGpx` is false

---

## Phase 2: Concrete Adapters

### 2.1 — `WorkAreaCollectionAdapter`

**File**: `lib/shareable_maps/adapters/work_area_adapter.dart`

- **Load**: Reads all `WorkArea` docs → converts each to `CustomPolygon` on a single layer named "Work Areas"
- **Save**: Diffs current polygons vs. loaded state → creates/updates/deletes WorkArea Firestore docs
- **Capabilities**: `polygonOnly` (no polylines/points/multi-layer)
- **Conversion**: `WorkArea` ↔ `CustomPolygon`

### 2.2 — `ScheduleJobAdapter`

**File**: `lib/shareable_maps/adapters/schedule_job_adapter.dart`

- **Load**: `Job.workMaps` → single-layer `ShareableMap`
- **Save**: Extracts polygons back → updates job via `ScheduleProvider`
- **Capabilities**: Polygons + polylines, single layer, no GPX import
- Extracts polygon names to update `Job.workingAreas`

### 2.3 — `JobListAreaAdapter`

**File**: `lib/shareable_maps/adapters/job_list_area_adapter.dart`

- **Load**: `JobListItem.customPolygons` → single layer; optionally loads KML from Cloud Storage
- **Save**: Updates `customPolygons` + optionally exports to KML → Cloud Storage → stores URL in `area`
- **Capabilities**: Full features
- **Cloud Storage path**: `/maps/joblist/{itemId}/{filename}.kml`

### 2.4 — `StandaloneAdapter`

**File**: `lib/shareable_maps/adapters/standalone_adapter.dart`

- Wraps current behavior (create blank map, no persistence)
- **Capabilities**: Full features
- Optional Firestore persistence to `/shareableMaps/{id}`

---

## Phase 3: Integration Points

### 3.1 — Work Areas screen

- Button in schedule toolbar or settings: "Edit Work Areas"
- Opens `ShareableMapEditor` with `WorkAreaCollectionAdapter`
- Pre-loads all existing work areas as polygons
- On save → syncs to Firestore → streams update `ScheduleProvider._workAreas`

### 3.2 — Schedule Job map editing

- Job edit dialog → "Edit Map" button
- Opens `ShareableMapEditor` with `ScheduleJobAdapter(job)`
- On save → updates job via `ScheduleProvider.updateJobWithUndo()`

### 3.3 — Job List area editing

- Job list item → tap area field → opens map editor
- Opens `ShareableMapEditor` with `JobListAreaAdapter(item)`
- On save → updates `customPolygons` + generates KML → stores in Cloud Storage

---

## Phase 4: Cloud Storage KML/GPX Service (Future)

### `MapStorageService`

**File**: `lib/shareable_maps/services/map_storage_service.dart`

- Upload/download KML/GPX to Firebase Cloud Storage
- Generate shareable download URLs
- Path convention: `/maps/{context}/{entityId}/{filename}`

---

## New File Structure

```
lib/shareable_maps/
├── adapters/
│   ├── map_data_adapter.dart          # Abstract interface + capabilities
│   ├── work_area_adapter.dart         # Use Case 1: /workAreas/ collection
│   ├── schedule_job_adapter.dart      # Use Case 2: Job.workMaps
│   ├── job_list_area_adapter.dart     # Use Case 3: JobListItem area + KML
│   └── standalone_adapter.dart        # Existing standalone behavior
├── models/          (existing)
├── providers/       (existing, modified)
├── services/        (existing + map_storage_service.dart future)
└── widgets/         (existing, modified)
```

## Modified Files

| File                          | Change                                                                             |
| ----------------------------- | ---------------------------------------------------------------------------------- |
| `shareable_map_provider.dart` | Add `adapter` field, `loadFromAdapter()`, `saveToAdapter()`, `capabilities` getter |
| `shareable_map_editor.dart`   | Capability-driven UI: show/hide tools, save button, import, layers                 |
| `map_drawing_toolbar.dart`    | Hide tools based on `capabilities`                                                 |
| `map_layers_sidebar.dart`     | Hide layer management based on `capabilities`                                      |
| `shareable_maps.dart`         | Export new adapter classes                                                         |

---

## Usage Examples

```dart
// Use Case 1: Edit Work Areas
final adapter = WorkAreaCollectionAdapter(workAreaService: workAreaService);
context.read<ShareableMapProvider>().loadFromAdapter(adapter);
Navigator.push(context, MaterialPageRoute(builder: (_) => const ShareableMapEditor()));

// Use Case 2: Edit Schedule Job Maps
final adapter = ScheduleJobAdapter(job: selectedJob, onSave: (polygons) async {
  final updated = selectedJob.copyWith(workMaps: polygons);
  await context.read<ScheduleProvider>().updateJob(updated);
});
context.read<ShareableMapProvider>().loadFromAdapter(adapter);
Navigator.push(context, MaterialPageRoute(builder: (_) => const ShareableMapEditor()));

// Use Case 3: Edit Job List Item Area
final adapter = JobListAreaAdapter(item: selectedItem, onSave: (polygons, area) async {
  await context.read<JobListProvider>().updateItem(selectedItem.id, customPolygons: polygons, area: area);
});
context.read<ShareableMapProvider>().loadFromAdapter(adapter);
Navigator.push(context, MaterialPageRoute(builder: (_) => const ShareableMapEditor()));
```

---

## Design Principles

1. **Open/Closed**: New data sources = new adapter class, zero changes to editor
2. **Single Responsibility**: Editor handles UI, adapter handles data I/O
3. **Minimal disruption**: Existing standalone behavior preserved via `StandaloneAdapter`
4. **Progressive enhancement**: Each adapter can be built and tested independently
5. **Capability-driven UI**: Editor automatically adjusts its feature set per adapter

## Implementation Order

1. `MapDataAdapter` + `MapEditorCapabilities` — abstract contract
2. `StandaloneAdapter` — wrap current behavior (nothing breaks)
3. Provider changes — `loadFromAdapter()` / `saveToAdapter()`
4. Editor widget changes — capability-driven UI
5. `WorkAreaCollectionAdapter` — first real adapter
6. `ScheduleJobAdapter` — second adapter
7. `JobListAreaAdapter` — third adapter (future: Cloud Storage)
8. Integration — wire into existing screens
