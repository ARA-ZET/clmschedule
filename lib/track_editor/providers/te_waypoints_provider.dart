// track_editor/providers/te_waypoints_provider.dart
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:gpx/gpx.dart';
import 'te_mode_provider.dart';

final teWaypointsRiverpod =
    riverpod.ChangeNotifierProvider<TEWaypointsProvider>(
        (ref) => TEWaypointsProvider());

class TEWaypointsProvider extends ChangeNotifier {
  final Map<TEMode, List<Wpt>> _wptsByMode = {
    TEMode.import: [],
    TEMode.trim: [],
    TEMode.processing: [],
    TEMode.update: [],
  };
  TEMode _activeMode = TEMode.processing;

  /// Read-only view; mutations must go through provider methods.
  List<Wpt> get waypoints => UnmodifiableListView(_wptsByMode[_activeMode]!);

  void setActiveMode(TEMode mode) {
    if (_activeMode == mode) return;
    _activeMode = mode;
    notifyListeners();
  }

  void addWaypoint(Wpt waypoint) {
    _wptsByMode[_activeMode]!.add(waypoint);
    notifyListeners();
  }

  void addWaypoints(List<Wpt> waypoints) {
    _wptsByMode[_activeMode]!.addAll(waypoints);
    notifyListeners();
  }

  void removeWaypoint(Wpt waypoint) {
    _wptsByMode[_activeMode]!.remove(waypoint);
    notifyListeners();
  }

  void clearWaypoints() {
    _wptsByMode[_activeMode]!.clear();
    notifyListeners();
  }

  void clearAll() {
    for (final mode in TEMode.values) {
      _wptsByMode[mode]!.clear();
    }
    notifyListeners();
  }
}
