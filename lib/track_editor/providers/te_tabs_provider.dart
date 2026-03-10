// track_editor/providers/te_tabs_provider.dart
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';
import 'te_mode_provider.dart';

List<TETabItem> _defaultTabs() => [
      TETabItem(
        polygons: [],
        tracks: [],
        waypoints: [],
        title: 'Untitled 1',
        targetPolygons: [],
      )
    ];

class TETabsProvider with ChangeNotifier {
  // Per-mode independent tab lists and current-tab pointers.
  final Map<TEMode, List<TETabItem>> _tabsByMode = {
    TEMode.import: _defaultTabs(),
    TEMode.trim: _defaultTabs(),
    TEMode.processing: _defaultTabs(),
  };
  final Map<TEMode, int> _currentByMode = {
    TEMode.import: 0,
    TEMode.trim: 0,
    TEMode.processing: 0,
  };

  TEMode _activeMode = TEMode.import;

  // ── Active-mode helpers ───────────────────────────────────────────────────
  TEMode get activeMode => _activeMode;
  List<TETabItem> get tabs => _tabsByMode[_activeMode]!;
  int get currentTab => _currentByMode[_activeMode]!;

  void setActiveMode(TEMode mode) {
    if (_activeMode == mode) return;
    _activeMode = mode;
    notifyListeners();
  }

  // ── Mutations (all operate on the active mode's list) ────────────────────
  void addTab(TETabItem tab) {
    tabs.add(tab);
    notifyListeners();
  }

  /// Add multiple tabs at once with a single notification.
  void addTabsBatch(List<TETabItem> newTabs) {
    if (newTabs.isEmpty) return;
    tabs.addAll(newTabs);
    _currentByMode[_activeMode] = tabs.length - 1;
    notifyListeners();
  }

  void removeTab(TETabItem tab) {
    final list = tabs;
    final idx = list.indexOf(tab);
    if (idx == -1) return;
    list.remove(tab);
    final cur = _currentByMode[_activeMode]!;
    if (cur >= list.length) {
      _currentByMode[_activeMode] = (list.length - 1).clamp(0, list.length);
    }
    notifyListeners();
  }

  void selectTab(int index) {
    if (index >= 0 && index < tabs.length) {
      _currentByMode[_activeMode] = index;
      notifyListeners();
    }
  }

  void renameTab(int index, String newTitle) {
    final list = tabs;
    if (index >= 0 && index < list.length) {
      list[index] = TETabItem(
        title: newTitle,
        polygons: list[index].polygons,
        tracks: list[index].tracks,
        waypoints: list[index].waypoints,
        targetPolygons: list[index].targetPolygons,
      );
      notifyListeners();
    }
  }

  void clearTabs() {
    _tabsByMode[_activeMode] = _defaultTabs();
    _currentByMode[_activeMode] = 0;
    notifyListeners();
  }

  void addData(TETabItem data) {
    final list = tabs;
    final cur = _currentByMode[_activeMode]!;
    if (cur < list.length) {
      list[cur].polygons.addAll(data.polygons);
      list[cur].tracks.addAll(data.tracks);
      list[cur].waypoints.addAll(data.waypoints);
      list[cur].targetPolygons.clear();
      list[cur].targetPolygons.addAll(data.targetPolygons);
      notifyListeners();
    }
  }

  /// Replace the [LatLng] points of a single polygon in-place and notify.
  void updatePolygonPoints(
      int tabIndex, int polyIndex, List<LatLng> newPoints) {
    final list = tabs;
    if (tabIndex < 0 || tabIndex >= list.length) return;
    final polys = list[tabIndex].polygons;
    if (polyIndex < 0 || polyIndex >= polys.length) return;
    polys[polyIndex] = polys[polyIndex].copyWith(points: newPoints);
    notifyListeners();
  }

  /// Append [newPolygons] to the active tab's polygon list.
  void addPolygonsToCurrentTab(List<TEStyledPolygon> newPolygons) {
    final list = tabs;
    final cur = _currentByMode[_activeMode]!;
    if (cur < list.length) {
      list[cur].polygons.addAll(newPolygons);
      notifyListeners();
    }
  }

  /// Remove a polygon by index from the given tab.
  void removePolygon(int tabIndex, int polyIndex) {
    final list = tabs;
    if (tabIndex < 0 || tabIndex >= list.length) return;
    final polys = list[tabIndex].polygons;
    if (polyIndex < 0 || polyIndex >= polys.length) return;
    polys.removeAt(polyIndex);
    notifyListeners();
  }

  /// Rename a polygon in the given tab.
  void renamePolygon(int tabIndex, int polyIndex, String newName) {
    final list = tabs;
    if (tabIndex < 0 || tabIndex >= list.length) return;
    final polys = list[tabIndex].polygons;
    if (polyIndex < 0 || polyIndex >= polys.length) return;
    final p = polys[polyIndex];
    polys[polyIndex] = TEStyledPolygon(
      id: p.id,
      name: newName,
      points: p.points,
      style: p.style,
    );
    notifyListeners();
  }
}
