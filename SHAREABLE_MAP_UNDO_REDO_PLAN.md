# Undo/Redo Plan for ShareableMap Editor

## Current state in your codebase

- **Already exists:** [lib/services/undo_redo_manager.dart](lib/services/undo_redo_manager.dart) — a context-aware `UndoRedoManager` (singleton) with per-context stacks including `UndoRedoContext.editMaps`. Max history = 10.
- **Already exists:** [lib/models/command.dart](lib/models/command.dart) — `Command`, `DataCommand`, and `EntityCommand<T>` base classes with `execute()` / `undo()`.
- **Not yet used anywhere real** — only a stub `TestCommand` in [lib/main.dart](lib/main.dart). `ScheduleProvider` currently bypasses it. So this is a greenfield integration for the ShareableMap editor.
- **Mutation surface to cover** in [lib/shareable_maps/providers/shareable_map_provider.dart](lib/shareable_maps/providers/shareable_map_provider.dart): layer add/delete/update/reorder/toggle-visibility, polygon add/update/delete/style, polyline add/update/delete/style, point add/update/delete/category/move, `completeDrawing`, vertex edit save, work-area add/remove.

## Recommended approach: **Snapshot-based commands** (not granular per-field)

Because `ShareableMap` → `MapLayer` → polygons/polylines/points are all **immutable** (`copyWith`), and every mutation already produces a new map via `_currentMap = ...`, the cleanest pattern is:

> **One `MapSnapshotCommand` class that stores `(before, after)` copies of `ShareableMap` plus a human-readable description. `execute()` and `undo()` just assign the stored snapshot back into the provider.**

Benefits:
1. ~50 lines of new code vs. 20+ granular command classes.
2. Impossible to get out of sync — every mutation is guaranteed reversible.
3. Works uniformly for compound changes (e.g. `completeDrawing` adds a polygon AND clears drawing state AND selects it).
4. Fits `ShareableMap`'s immutable model perfectly — snapshots are just references, no deep copy cost.
5. No risk of stale state when the adapter persists async — snapshots restore the exact UI state.

Tradeoff: memory holds up to 10 `ShareableMap` references. Cheap because of structural sharing (layers/elements not mutated in place).

## Integration strategy

1. **Wrap mutations in a `_mutate(String description, void Function() change)` helper** in `ShareableMapProvider`:
   - Captures `before = _currentMap`.
   - Runs the change closure.
   - Captures `after = _currentMap`.
   - Pushes a `MapSnapshotCommand(before, after, description, this)` via `undoRedoManager.executeCommand(cmd, UndoRedoContext.editMaps)`.
   - Skip history for ephemeral state (drawing-in-progress points, selection, hover, cloud overlay loads).

2. **Skip list** (do NOT track):
   - `addDrawingPoint` / `removeLastDrawingPoint` (in-progress drawing — gets collapsed into one command at `completeDrawing`).
   - `updateEditingPoint` during a drag (track only on drag-end / vertex save).
   - Selection, hover, layer expand toggle, drawing-mode toggle.
   - Cloud overlay loads (ephemeral, not persisted).
   - Marker drag intermediate events (use drag-end only).

3. **Context switching:** Set `undoRedoManager.setContext(UndoRedoContext.editMaps)` when `ShareableMapEditor` mounts, restore previous context on dispose.

4. **Clear history** on `loadFromAdapter()` / `clearAdapter()` / `loadMap()` / `createNewMap()` — a new map means a fresh undo history.

5. **Adapter save:** snapshots capture in-memory state. The existing `adapter.save()` flow still runs — undo will restore the in-memory map, and the user can then re-save. Optionally: auto-trigger `adapter.save()` after undo/redo so persistence stays in sync (recommended; add a debounce).

## UI wiring

- Add **Undo / Redo icon buttons** in `MapEditorAppBar` (rebuild via `ListenableBuilder` on `undoRedoManager`), enabled only when `canUndoForContext(editMaps)` / `canRedoForContext(editMaps)`. Tooltips show `nextUndoDescription` / `nextRedoDescription`.
- Add **keyboard shortcuts**: `Cmd/Ctrl+Z` → undo, `Cmd/Ctrl+Shift+Z` and `Cmd/Ctrl+Y` → redo, via `Shortcuts` + `Actions` wrapping the editor Scaffold body.

## Files that will change

| File | Change |
|---|---|
| `lib/shareable_maps/commands/map_snapshot_command.dart` | **NEW** — `MapSnapshotCommand extends Command` with `(before, after, description, provider)`. Also a tiny `ProviderHook` interface so the command can call back into `ShareableMapProvider.applySnapshot(map)`. |
| [lib/shareable_maps/providers/shareable_map_provider.dart](lib/shareable_maps/providers/shareable_map_provider.dart) | Add `_mutate(description, change)` helper, `applySnapshot(ShareableMap)`, wrap ~18 mutation methods (layer/polygon/polyline/point/drawing-complete/vertex-save/work-area add-remove/metadata-update) with `_mutate`. Clear history on map load. |
| [lib/shareable_maps/widgets/shareable_map_editor.dart](lib/shareable_maps/widgets/shareable_map_editor.dart) | Set `undoRedoManager` context on mount, clear on dispose. Add `Shortcuts` + `Actions` for Cmd/Ctrl+Z / Cmd/Ctrl+Shift+Z. |
| `lib/shareable_maps/widgets/shareable_map_editor.dart → MapEditorAppBar` | Add undo / redo `IconButton`s wired to `undoRedoManager.undo/redo` with `AnimatedBuilder(animation: undoRedoManager, …)`. |
| [lib/services/undo_redo_manager.dart](lib/services/undo_redo_manager.dart) | No changes — reuse as-is. |
| [lib/models/command.dart](lib/models/command.dart) | No changes. |

**Optional (recommended for polish):**
- [lib/shareable_maps/providers/shareable_map_provider.dart](lib/shareable_maps/providers/shareable_map_provider.dart) — auto-invoke `adapter?.save(_currentMap!)` (debounced ~500 ms) after each `_mutate`/undo/redo so Firestore/Job stays in sync.
- [lib/shareable_maps/widgets/map_drawing_toolbar.dart](lib/shareable_maps/widgets/map_drawing_toolbar.dart) — optional inline undo button near drawing tools.

## Why not granular commands?

Considered one `AddPolygonCommand`, `DeletePointCommand`, etc. Rejected because:
- 15+ classes to write and maintain.
- Duplicate logic already inside each provider mutation method (each does an immutable `copyWith` already).
- `completeDrawing` would need a `CompositeCommand` anyway.
- Snapshot approach gives the same UX with a fraction of the code and zero risk of forgetting to reverse a side-effect.

## Rollout order

1. Add `MapSnapshotCommand` + `_mutate` helper + wrap the top 5 most-used mutations (add/delete layer, add/delete polygon, delete point). Test Cmd+Z end-to-end.
2. Wrap the remaining mutations.
3. Add keyboard shortcuts + app-bar buttons.
4. Wire optional debounced auto-save.
5. Add history clearing on map load.
