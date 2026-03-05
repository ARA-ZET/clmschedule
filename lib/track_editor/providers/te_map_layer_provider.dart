// track_editor/providers/te_map_layer_provider.dart
//
// Controls per-tab map layer visibility (waypoints and polygons).
// The TEMap reads from this provider so the toggle in the left panel
// immediately shows/hides markers without reloading data.
import 'package:flutter/material.dart';

class TEMapLayerProvider extends ChangeNotifier {
  // Map from tab index → visibility flags
  final Map<int, bool> _waypointsVisible = {};
  final Map<int, bool> _polygonsVisible = {};

  // Map from tab index → waypoint search query (empty = show all)
  final Map<int, String> _waypointFilter = {};

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

  /// Clean up state when a tab is removed (optional housekeeping).
  void removeTab(int tabIndex) {
    _waypointsVisible.remove(tabIndex);
    _waypointFilter.remove(tabIndex);
    _polygonsVisible.remove(tabIndex);
    notifyListeners();
  }
}
