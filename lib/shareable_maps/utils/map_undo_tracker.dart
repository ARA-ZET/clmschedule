// shareable_maps/utils/map_undo_tracker.dart
//
// Undo/redo for the map editor, one history per map (UndoKey(clientMap, id)).
//
// Map models are immutable and share unchanged parts, so a ShareableMap
// reference is a free snapshot. The provider reports every change to
// `_currentMap` here, sorted into three kinds:
//
//   - user edits ([onUserChange], from `_notifyAndSave`) become steps, each a
//     (before → after) snapshot pair, named and coalesced automatically;
//   - local background changes ([fold]: letterbox counts, stable polygon ids,
//     thumbnails) join the latest step, so undo doesn't need a second press;
//   - remote edits ([onRemote]: another user or tab) bump a per-layer
//     revision. Undoing a step whose layers were edited remotely since is a
//     conflict and is skipped, never overwriting the newer edit.
//
// Undo restores at layer level: only the layers the step changed are put
// back, so edits to other layers since are kept.
import 'package:flutter/foundation.dart';

import '../../undo/undo_history.dart';
import '../models/map_layer.dart';
import '../models/shareable_map.dart';

class MapStep {
  ShareableMap before;
  ShareableMap after;

  /// Remote revision of each changed layer when the step was recorded.
  final Map<String, int> layerRevs;
  final int metaRev;

  MapStep(this.before, this.after, this.layerRevs, this.metaRev);

  Set<String> get changedLayerIds => changedLayers(before, after);

  bool get metaChanged =>
      before.name != after.name || before.description != after.description;
}

/// Ids of layers added, removed or replaced between [a] and [b]. Identity,
/// not ==: MapLayer equality compares ids only.
Set<String> changedLayers(ShareableMap a, ShareableMap b) {
  final byIdA = {for (final l in a.layers) l.id: l};
  final byIdB = {for (final l in b.layers) l.id: l};
  return {
    for (final id in {...byIdA.keys, ...byIdB.keys})
      if (!identical(byIdA[id], byIdB[id])) id,
  };
}

bool _orderChanged(ShareableMap a, ShareableMap b) {
  final idsB = {for (final l in b.layers) l.id};
  final common = [
    for (final l in a.layers)
      if (idsB.contains(l.id)) l.id,
  ];
  final idsA = common.toSet();
  final commonB = [
    for (final l in b.layers)
      if (idsA.contains(l.id)) l.id,
  ];
  return !listEquals(common, commonB);
}

class MapUndoTracker {
  final ScreenUndoHistory Function(UndoKey key) historyFor;

  /// The live map, and how to swap in a restored one (the provider sets
  /// `_currentMap`, clears selection and saves).
  final ShareableMap? Function() currentMap;
  final void Function(ShareableMap restored) applyRestored;

  MapUndoTracker({
    required this.historyFor,
    required this.currentMap,
    required this.applyRestored,
  });

  String? _keyId;
  ShareableMap? _base;
  MapStep? _lastStep;
  int _groupDepth = 0;
  int _backgroundDepth = 0;
  final Map<String, int> _layerRev = {};
  int _metaRev = 0;

  UndoKey? get undoKey =>
      _keyId == null ? null : UndoKey(UndoScope.clientMap, _keyId!);

  ScreenUndoHistory? get history {
    final key = undoKey;
    return key == null ? null : historyFor(key);
  }

  /// A map was opened (or closed, with null). Its history is kept per map id
  /// for the rest of the session, so reopening a map keeps its steps.
  void reset(ShareableMap? map) {
    final id = map == null ? null : (map.id.isEmpty ? 'new' : map.id);
    if (id != _keyId) {
      _layerRev.clear();
      _metaRev = 0;
    }
    _keyId = id;
    _base = map;
    _lastStep = null;
  }

  /// Groups several saves into one step, e.g. a drawing that also creates
  /// its layer, or a vertex edit plus the stitch to its neighbours.
  T asOneStep<T>(T Function() run) {
    _groupDepth++;
    try {
      return run();
    } finally {
      _groupDepth--;
      if (_groupDepth == 0) {
        final map = currentMap();
        if (map != null) onUserChange(map);
      }
    }
  }

  /// Runs a background change (letterbox estimate, recount) whose save must
  /// join the latest step rather than become one.
  T inBackground<T>(T Function() run) {
    _backgroundDepth++;
    try {
      return run();
    } finally {
      _backgroundDepth--;
    }
  }

  /// Called from `_notifyAndSave` with the map as it now is.
  void onUserChange(ShareableMap current) {
    final base = _base;
    final h = history;
    if (base == null || h == null) {
      _base = current;
      return;
    }
    if (_groupDepth > 0) return;
    if (_backgroundDepth > 0 || h.isApplying) {
      fold(current);
      return;
    }
    if (identical(base, current)) return;
    final changed = changedLayers(base, current);
    final metaChanged =
        base.name != current.name || base.description != current.description;
    if (changed.isEmpty && !metaChanged) {
      // Cloud settings, thumbnails — nothing undo restores.
      _base = current;
      return;
    }
    final step = MapStep(
      base,
      current,
      {for (final id in changed) id: _layerRev[id] ?? 0},
      _metaRev,
    );
    final description = describeMapChange(base, current);
    h.record(_entryFor(step, description));
    _lastStep = step;
    _base = current;
  }

  /// A local background change: becomes part of the latest step.
  void fold(ShareableMap current) {
    final step = _lastStep;
    if (step != null && identical(step.after, _base)) step.after = current;
    _base = current;
  }

  /// A view-only change (layer visibility, expanded in the sidebar) that no
  /// step should restore or record.
  void rebase(ShareableMap current) => _base = current;

  /// Another user or tab changed the map.
  void onRemote(ShareableMap previous, ShareableMap next) {
    final prevById = {for (final l in previous.layers) l.id: l};
    final nextById = {for (final l in next.layers) l.id: l};
    for (final id in {...prevById.keys, ...nextById.keys}) {
      final a = prevById[id];
      final b = nextById[id];
      if (identical(a, b)) continue;
      if (a == null || b == null || !layerContentEquals(a, b)) {
        _layerRev[id] = (_layerRev[id] ?? 0) + 1;
      }
    }
    if (previous.name != next.name ||
        previous.description != next.description) {
      _metaRev++;
    }
    _lastStep = null;
    _base = next;
  }

  UndoEntry _entryFor(MapStep step, MapChangeDescription d) {
    final entry = UndoEntry(
      label: d.label,
      coalesceKey: d.coalesceKey,
      mergeOnto: d.coalesceKey == null
          ? null
          : (previous) {
              final older = _steps[previous];
              if (older == null) return _entryFor(step, d);
              final merged = MapStep(
                older.before,
                step.after,
                {...step.layerRevs, ...older.layerRevs},
                older.metaRev,
              );
              if (identical(_lastStep, step)) _lastStep = merged;
              return _entryFor(merged, d);
            },
      undo: () async => _restore(step, toBefore: true),
      redo: () async => _restore(step, toBefore: false),
    );
    _steps[entry] = step;
    return entry;
  }

  /// Entry → its step, so coalescing can reach the older step's "before".
  final Expando<MapStep> _steps = Expando('mapUndoStep');

  void _restore(MapStep step, {required bool toBefore}) {
    final current = currentMap();
    if (current == null) throw const UndoConflict('the map is closed');
    for (final e in step.layerRevs.entries) {
      if ((_layerRev[e.key] ?? 0) != e.value) {
        throw const UndoConflict('that part of the map was changed by '
            'someone else since');
      }
    }
    if (step.metaChanged && _metaRev != step.metaRev) {
      throw const UndoConflict('the map was renamed by someone else since');
    }
    final target = toBefore ? step.before : step.after;
    final restored = restoreLayers(
      current: current,
      target: target,
      layerIds: step.changedLayerIds,
      restoreOrder: _orderChanged(step.before, step.after),
    ).copyWith(name: target.name, description: target.description);
    _lastStep = null;
    applyRestored(restored);
  }
}

/// [current] with the layers in [layerIds] put back as they are in [target]
/// (removed when [target] lacks them, inserted at [target]'s position when
/// [current] lacks them). Layers not listed keep any edits made since.
ShareableMap restoreLayers({
  required ShareableMap current,
  required ShareableMap target,
  required Set<String> layerIds,
  bool restoreOrder = false,
}) {
  final targetById = {for (final l in target.layers) l.id: l};
  final layers = <MapLayer>[
    for (final l in current.layers)
      if (!layerIds.contains(l.id))
        l
      else if (targetById[l.id] != null)
        targetById[l.id]!,
  ];
  final present = {for (final l in layers) l.id};
  for (var i = 0; i < target.layers.length; i++) {
    final l = target.layers[i];
    if (layerIds.contains(l.id) && !present.contains(l.id)) {
      layers.insert(i.clamp(0, layers.length), l);
    }
  }
  if (restoreOrder) {
    final rank = {
      for (var i = 0; i < target.layers.length; i++) target.layers[i].id: i,
    };
    final ranked = layers.where((l) => rank.containsKey(l.id)).toList()
      ..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
    var next = 0;
    for (var i = 0; i < layers.length; i++) {
      if (rank.containsKey(layers[i].id)) layers[i] = ranked[next++];
    }
  }
  return current.copyWith(layers: layers);
}

/// Whether two layers hold the same content, ignoring timestamps at any
/// depth (stamped on every edit, in microseconds locally but milliseconds
/// once saved, so our own echoed save would never match) and the sidebar's
/// expanded state.
bool layerContentEquals(MapLayer a, MapLayer b) =>
    _deepEquals(a.toMap(), b.toMap());

const _ignoredKeys = {'updatedAt', 'createdAt', 'isExpanded'};

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    final keys = {...a.keys, ...b.keys}..removeAll(_ignoredKeys);
    for (final k in keys) {
      if (a.containsKey(k) != b.containsKey(k)) return false;
      if (!_deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

class MapChangeDescription {
  final String label;

  /// Set when the step edits one element (or one layer's settings), so a
  /// slider drag or a burst of nudges on it merges into one step.
  final String? coalesceKey;
  const MapChangeDescription(this.label, [this.coalesceKey]);
}

String _quoted(String name, String fallback) =>
    name.trim().isEmpty ? fallback : '"${name.trim()}"';

/// Names the change from [before] to [after] for the Undo tooltip.
MapChangeDescription describeMapChange(
    ShareableMap before, ShareableMap after) {
  final changed = changedLayers(before, after);
  final beforeById = {for (final l in before.layers) l.id: l};
  final afterById = {for (final l in after.layers) l.id: l};

  if (changed.isEmpty) {
    if (before.name != after.name) {
      return const MapChangeDescription('Rename map');
    }
    return const MapChangeDescription('Edit map details');
  }

  final added = [
    for (final id in changed)
      if (beforeById[id] == null) afterById[id]!
  ];
  final removed = [
    for (final id in changed)
      if (afterById[id] == null) beforeById[id]!
  ];
  if (added.length == 1 && removed.isEmpty && changed.length == 1) {
    return MapChangeDescription(
        'Add layer ${_quoted(added.single.name, '')}'.trim());
  }
  if (removed.length == 1 && added.isEmpty && changed.length == 1) {
    return MapChangeDescription(
        'Delete layer ${_quoted(removed.single.name, '')}'.trim());
  }

  // Element counts across the changed layers that exist on both sides.
  int delta(int Function(MapLayer) count) => changed.fold(0, (sum, id) {
        final a = beforeById[id];
        final b = afterById[id];
        return sum + (b == null ? 0 : count(b)) - (a == null ? 0 : count(a));
      });
  final dPolygons = delta((l) => l.polygons.length);
  final dLines = delta((l) => l.polylines.length);
  final dPoints = delta((l) => l.points.length);

  if (changed.length == 2 && dPolygons == 0 && dLines == 0 && dPoints == 0) {
    final target =
        changed.map((id) => afterById[id]).whereType<MapLayer>().where((l) {
      final b = beforeById[l.id];
      return b != null &&
          l.polygons.length + l.polylines.length + l.points.length >
              b.polygons.length + b.polylines.length + b.points.length;
    }).firstOrNull;
    if (target != null) {
      return MapChangeDescription('Move to layer ${_quoted(target.name, '')}');
    }
  }

  if (changed.length == 1 && added.isEmpty && removed.isEmpty) {
    final id = changed.single;
    final a = beforeById[id]!;
    final b = afterById[id]!;
    String plural(int n, String one, String many) => n == 1 ? one : '$n $many';
    if (dPolygons > 0) {
      return MapChangeDescription(dPolygons == 1
          ? 'Add area ${_quoted(b.polygons.last.name, '')}'.trim()
          : 'Add $dPolygons areas');
    }
    if (dPolygons < 0) {
      return MapChangeDescription(
          'Delete ${plural(-dPolygons, 'area', 'areas')}');
    }
    if (dLines != 0) {
      return MapChangeDescription(dLines > 0
          ? 'Add ${plural(dLines, 'line', 'lines')}'
          : 'Delete ${plural(-dLines, 'line', 'lines')}');
    }
    if (dPoints != 0) {
      return MapChangeDescription(dPoints > 0
          ? 'Add ${plural(dPoints, 'marker', 'markers')}'
          : 'Delete ${plural(-dPoints, 'marker', 'markers')}');
    }
    // Same counts: which single element changed?
    final polys = [
      for (var i = 0; i < b.polygons.length; i++)
        if (!identical(a.polygons[i], b.polygons[i])) i,
    ];
    final lines = [
      for (var i = 0; i < b.polylines.length; i++)
        if (!identical(a.polylines[i], b.polylines[i])) i,
    ];
    final pts = [
      for (var i = 0; i < b.points.length; i++)
        if (!identical(a.points[i], b.points[i])) i,
    ];
    final edits = polys.length + lines.length + pts.length;
    if (edits == 1 && polys.length == 1) {
      final i = polys.single;
      final p0 = a.polygons[i];
      final p1 = b.polygons[i];
      final name = _quoted(p1.name, 'area');
      final label = !listEquals(p0.points, p1.points)
          ? 'Edit shape of $name'
          : p0.name != p1.name
              ? 'Rename $name'
              : 'Edit $name';
      return MapChangeDescription(label, 'polygon:$id:$i');
    }
    if (edits == 1 && pts.length == 1) {
      final i = pts.single;
      final m0 = a.points[i];
      final m1 = b.points[i];
      final name = _quoted(m1.name, 'marker');
      return MapChangeDescription(
          m0.position != m1.position ? 'Move $name' : 'Edit $name',
          'point:$id:$i');
    }
    if (edits == 1 && lines.length == 1) {
      final i = lines.single;
      return MapChangeDescription(
          'Edit ${_quoted(b.polylines[i].name, 'line')}', 'line:$id:$i');
    }
    if (edits == 0) {
      return MapChangeDescription(
          'Edit layer ${_quoted(b.name, '')}'.trim(), 'layer:$id');
    }
    return MapChangeDescription('Edit ${plural(edits, 'item', 'items')}');
  }

  if (_orderChanged(before, after) && dPolygons == 0) {
    return const MapChangeDescription('Reorder layers');
  }
  return const MapChangeDescription('Edit map');
}
