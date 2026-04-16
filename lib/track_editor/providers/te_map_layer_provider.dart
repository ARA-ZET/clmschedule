// track_editor/providers/te_map_layer_provider.dart
//
// Controls per-tab map layer visibility (waypoints and polygons).
// The TEMap reads from this provider so the toggle in the left panel
// immediately shows/hides markers without reloading data.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

final teMapLayerRiverpod = riverpod.ChangeNotifierProvider<TEMapLayerProvider>(
    (ref) => TEMapLayerProvider());

class TEMapLayerProvider extends ChangeNotifier {
  // Map from tab index → visibility flags
  final Map<int, bool> _waypointsVisible = {};
  final Map<int, bool> _polygonsVisible = {};

  // Map from tab index → waypoint search query (empty = show all)
  final Map<int, String> _waypointFilter = {};

  // Per-tab selected waypoint index (null = none selected)
  final Map<int, int?> _selectedWaypoint = {};

  // Per-tab multi-selected waypoint indices (lasso/rectangle selection)
  final Map<int, Set<int>> _multiSelectedWaypoints = {};

  /// Returns the selected waypoint index for [tabIndex], or null.
  int? selectedWaypoint(int tabIndex) => _selectedWaypoint[tabIndex];

  /// Select a waypoint by index. Pass null to deselect.
  void selectWaypoint(int tabIndex, int? waypointIndex) {
    _selectedWaypoint[tabIndex] = waypointIndex;
    notifyListeners();
  }

  /// Returns the set of multi-selected waypoint indices for [tabIndex].
  Set<int> multiSelectedWaypoints(int tabIndex) =>
      _multiSelectedWaypoints[tabIndex] ?? const {};

  /// Set multi-selected waypoints (from lasso/rectangle selection).
  void setMultiSelectedWaypoints(int tabIndex, Set<int> indices) {
    _multiSelectedWaypoints[tabIndex] = indices;
    notifyListeners();
  }

  /// Clear multi-selection for [tabIndex].
  void clearMultiSelection(int tabIndex) {
    _multiSelectedWaypoints.remove(tabIndex);
    notifyListeners();
  }

  /// Returns the current filter query for [tabIndex].
  String waypointFilter(int tabIndex) => _waypointFilter[tabIndex] ?? '';

  /// Set (or clear) the waypoint name filter for [tabIndex].
  void setWaypointFilter(int tabIndex, String query) {
    _waypointFilter[tabIndex] = query;
    notifyListeners();
  }

  /// Returns true (default) if waypoints are visible for [tabIndex].
  bool waypointsVisible(int tabIndex) => _waypointsVisible[tabIndex] ?? true;

  /// Toggle waypoint visibility for [tabIndex].
  void toggleWaypoints(int tabIndex) {
    _waypointsVisible[tabIndex] = !waypointsVisible(tabIndex);
    notifyListeners();
  }

  /// Set waypoint visibility explicitly.
  void setWaypointsVisible(int tabIndex, {required bool visible}) {
    if (_waypointsVisible[tabIndex] == visible) return;
    _waypointsVisible[tabIndex] = visible;
    notifyListeners();
  }

  /// Returns true (default) if polygons are visible for [tabIndex].
  bool polygonsVisible(int tabIndex) => _polygonsVisible[tabIndex] ?? true;

  /// Toggle polygon visibility for [tabIndex].
  void togglePolygons(int tabIndex) {
    _polygonsVisible[tabIndex] = !polygonsVisible(tabIndex);
    notifyListeners();
  }

  /// Clean up state when a tab is removed and shift higher indices down.
  void removeTab(int tabIndex) {
    _waypointsVisible.remove(tabIndex);
    _waypointFilter.remove(tabIndex);
    _polygonsVisible.remove(tabIndex);
    _selectedWaypoint.remove(tabIndex);
    _multiSelectedWaypoints.remove(tabIndex);

    // Shift entries with index > tabIndex down by 1
    _shiftDown(_waypointsVisible, tabIndex);
    _shiftDown(_waypointFilter, tabIndex);
    _shiftDown(_polygonsVisible, tabIndex);
    _shiftDown(_selectedWaypoint, tabIndex);
    _shiftDown(_multiSelectedWaypoints, tabIndex);

    notifyListeners();
  }

  /// Clear all per-tab state.
  void clearAll() {
    _waypointsVisible.clear();
    _waypointFilter.clear();
    _polygonsVisible.clear();
    _selectedWaypoint.clear();
    _multiSelectedWaypoints.clear();
    notifyListeners();
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
}
