// track_editor/providers/te_map_layer_provider.dart
//
// Controls per-mode, per-tab map layer visibility (waypoints and polygons).
// The TEMap reads from this provider so the toggle in the left panel
// immediately shows/hides markers without reloading data.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'te_mode_provider.dart';

final teMapLayerRiverpod = riverpod.ChangeNotifierProvider<TEMapLayerProvider>(
    (ref) => TEMapLayerProvider());

/// Per-mode layer state holder.
class _ModeLayerState {
  final Map<int, bool> waypointsVisible = {};
  final Map<int, bool> polygonsVisible = {};
  final Map<int, String> waypointFilter = {};
  final Map<int, int?> selectedWaypoint = {};
  final Map<int, Set<int>> multiSelectedWaypoints = {};

  void clear() {
    waypointsVisible.clear();
    polygonsVisible.clear();
    waypointFilter.clear();
    selectedWaypoint.clear();
    multiSelectedWaypoints.clear();
  }

  void removeTab(int tabIndex) {
    waypointsVisible.remove(tabIndex);
    waypointFilter.remove(tabIndex);
    polygonsVisible.remove(tabIndex);
    selectedWaypoint.remove(tabIndex);
    multiSelectedWaypoints.remove(tabIndex);
    _shiftDown(waypointsVisible, tabIndex);
    _shiftDown(waypointFilter, tabIndex);
    _shiftDown(polygonsVisible, tabIndex);
    _shiftDown(selectedWaypoint, tabIndex);
    _shiftDown(multiSelectedWaypoints, tabIndex);
  }
}

void _shiftDown<V>(Map<int, V> map, int removedIndex) {
  final shifted = <int, V>{};
  for (final entry in map.entries) {
    if (entry.key > removedIndex) {
      shifted[entry.key - 1] = entry.value;
    } else {
      shifted[entry.key] = entry.value;
    }
  }
  map
    ..clear()
    ..addAll(shifted);
}

class TEMapLayerProvider extends ChangeNotifier {
  final Map<TEMode, _ModeLayerState> _stateByMode = {
    TEMode.import: _ModeLayerState(),
    TEMode.trim: _ModeLayerState(),
    TEMode.processing: _ModeLayerState(),
    TEMode.update: _ModeLayerState(),
  };
  TEMode _activeMode = TEMode.processing;
  _ModeLayerState get _s => _stateByMode[_activeMode]!;

  void setActiveMode(TEMode mode) {
    if (_activeMode == mode) return;
    _activeMode = mode;
    notifyListeners();
  }

  int? selectedWaypoint(int tabIndex) => _s.selectedWaypoint[tabIndex];

  void selectWaypoint(int tabIndex, int? waypointIndex) {
    _s.selectedWaypoint[tabIndex] = waypointIndex;
    notifyListeners();
  }

  Set<int> multiSelectedWaypoints(int tabIndex) =>
      _s.multiSelectedWaypoints[tabIndex] ?? const {};

  void setMultiSelectedWaypoints(int tabIndex, Set<int> indices) {
    _s.multiSelectedWaypoints[tabIndex] = indices;
    notifyListeners();
  }

  void clearMultiSelection(int tabIndex) {
    _s.multiSelectedWaypoints.remove(tabIndex);
    notifyListeners();
  }

  String waypointFilter(int tabIndex) => _s.waypointFilter[tabIndex] ?? '';

  void setWaypointFilter(int tabIndex, String query) {
    _s.waypointFilter[tabIndex] = query;
    notifyListeners();
  }

  bool waypointsVisible(int tabIndex) => _s.waypointsVisible[tabIndex] ?? true;

  void toggleWaypoints(int tabIndex) {
    _s.waypointsVisible[tabIndex] = !waypointsVisible(tabIndex);
    notifyListeners();
  }

  void setWaypointsVisible(int tabIndex, {required bool visible}) {
    if (_s.waypointsVisible[tabIndex] == visible) return;
    _s.waypointsVisible[tabIndex] = visible;
    notifyListeners();
  }

  bool polygonsVisible(int tabIndex) => _s.polygonsVisible[tabIndex] ?? true;

  void togglePolygons(int tabIndex) {
    _s.polygonsVisible[tabIndex] = !polygonsVisible(tabIndex);
    notifyListeners();
  }

  void removeTab(int tabIndex) {
    _s.removeTab(tabIndex);
    notifyListeners();
  }

  void clearAll() {
    for (final state in _stateByMode.values) {
      state.clear();
    }
    notifyListeners();
  }
}
