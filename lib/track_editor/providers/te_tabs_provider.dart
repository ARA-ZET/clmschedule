// track_editor/providers/te_tabs_provider.dart
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:gpx/gpx.dart';
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';
import 'te_mode_provider.dart';

final teTabsRiverpod =
    riverpod.ChangeNotifierProvider<TETabsProvider>((ref) => TETabsProvider());

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
    TEMode.update: _defaultTabs(),
  };
  final Map<TEMode, int> _currentByMode = {
    TEMode.import: 0,
    TEMode.trim: 0,
    TEMode.processing: 0,
    TEMode.update: 0,
  };

  TEMode _activeMode = TEMode.processing;

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

  /// Reset tabs across all modes back to a single default tab.
  void clearAllTabs() {
    for (final mode in TEMode.values) {
      _tabsByMode[mode] = _defaultTabs();
      _currentByMode[mode] = 0;
    }
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
      clientName: p.clientName,
      points: p.points,
      style: p.style,
    );
    notifyListeners();
  }

  // ── Track operations ──────────────────────────────────────────────────────

  /// Remove a track by index from the given tab.
  void removeTrack(int tabIndex, int trackIndex) {
    final list = tabs;
    if (tabIndex < 0 || tabIndex >= list.length) return;
    final tracks = list[tabIndex].tracks;
    if (trackIndex < 0 || trackIndex >= tracks.length) return;
    tracks.removeAt(trackIndex);
    notifyListeners();
  }

  /// Rename a track in the given tab. The `gpx` package's [Trk.name] is a
  /// mutable field, so we can assign the new value directly. An empty or
  /// whitespace-only name is stored as `null` so the UI will fall back to
  /// the default "Track N" label.
  void renameTrack(int tabIndex, int trackIndex, String newName) {
    final list = tabs;
    if (tabIndex < 0 || tabIndex >= list.length) return;
    final tracks = list[tabIndex].tracks;
    if (trackIndex < 0 || trackIndex >= tracks.length) return;
    final trimmed = newName.trim();
    tracks[trackIndex].name = trimmed.isEmpty ? null : trimmed;
    notifyListeners();
  }

  // ── Waypoint operations ───────────────────────────────────────────────────

  /// Remove a waypoint by index from the given tab.
  void removeWaypoint(int tabIndex, int waypointIndex) {
    final list = tabs;
    if (tabIndex < 0 || tabIndex >= list.length) return;
    final waypoints = list[tabIndex].waypoints;
    if (waypointIndex < 0 || waypointIndex >= waypoints.length) return;
    waypoints.removeAt(waypointIndex);
    notifyListeners();
  }

  /// Remove multiple waypoints by index. Indices are sorted descending
  /// so removals don't shift later indices.
  void removeWaypoints(int tabIndex, Set<int> waypointIndices) {
    final list = tabs;
    if (tabIndex < 0 || tabIndex >= list.length) return;
    final waypoints = list[tabIndex].waypoints;
    final sorted = waypointIndices.toList()..sort((a, b) => b.compareTo(a));
    for (final idx in sorted) {
      if (idx >= 0 && idx < waypoints.length) waypoints.removeAt(idx);
    }
    notifyListeners();
  }

  /// Split a track at a global trackpoint index (flattened across all segments).
  ///
  /// The original track is replaced by two new tracks: one containing all
  /// points up to and including [globalPointIndex], the other containing
  /// all points from [globalPointIndex] onward (the split point is shared
  /// by both halves so there is no gap).
  ///
  /// Returns true if the split succeeded.
  bool splitTrack(int tabIndex, int trackIndex, int globalPointIndex) {
    final list = tabs;
    if (tabIndex < 0 || tabIndex >= list.length) return false;
    final tracks = list[tabIndex].tracks;
    if (trackIndex < 0 || trackIndex >= tracks.length) return false;

    final trk = tracks[trackIndex];

    // Flatten all segments to find total point count and locate the split.
    final allPts = <Wpt>[];
    final segBoundaries = <int>[]; // start index of each segment in allPts
    for (final seg in trk.trksegs) {
      segBoundaries.add(allPts.length);
      allPts.addAll(seg.trkpts);
    }

    if (globalPointIndex <= 0 || globalPointIndex >= allPts.length - 1) {
      return false; // can't split at first or last point
    }

    // Build two halves — the split point appears in both so there's no gap.
    final firstHalf = allPts.sublist(0, globalPointIndex + 1);
    final secondHalf = allPts.sublist(globalPointIndex);

    // Derive names: drop the last word of the original name and append
    // the 1-based track position, zero-padded if < 10 (e.g. "Route 03").
    final baseName = trk.name ?? 'Track';
    final words = baseName.trim().split(RegExp(r'\s+'));
    final prefix = words.length > 1
        ? words.sublist(0, words.length - 1).join(' ')
        : baseName;
    // Total tracks after the split: current count + 1 (we replace 1 with 2).
    final totalAfter = tracks.length + 1;
    String _padIdx(int oneBasedIdx) => totalAfter < 10 && oneBasedIdx < 10
        ? oneBasedIdx.toString().padLeft(2, '0')
        : oneBasedIdx.toString();
    final nameA = '$prefix ${_padIdx(trackIndex + 1)}';
    final nameB = '$prefix ${_padIdx(trackIndex + 2)}';

    final trkA = Trk(
      name: nameA,
      cmt: trk.cmt,
      desc: trk.desc,
      src: trk.src,
      number: trk.number,
      type: trk.type,
      trksegs: [Trkseg(trkpts: firstHalf)],
    );
    final trkB = Trk(
      name: nameB,
      cmt: trk.cmt,
      desc: trk.desc,
      src: trk.src,
      number: trk.number,
      type: trk.type,
      trksegs: [Trkseg(trkpts: secondHalf)],
    );

    // Replace the original track with the two halves.
    tracks.replaceRange(trackIndex, trackIndex + 1, [trkA, trkB]);
    notifyListeners();
    return true;
  }
}
