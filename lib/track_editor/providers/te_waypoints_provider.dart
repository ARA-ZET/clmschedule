// track_editor/providers/te_waypoints_provider.dart
import 'package:flutter/material.dart';
import 'package:gpx/gpx.dart';

class TEWaypointsProvider extends ChangeNotifier {
  final List<Wpt> _waypoints = [];
  List<Wpt> get waypoints => _waypoints;

  void addWaypoint(Wpt waypoint) {
    _waypoints.add(waypoint);
    notifyListeners();
  }

  void addWaypoints(List<Wpt> waypoints) {
    _waypoints.addAll(waypoints);
    notifyListeners();
  }

  void removeWaypoint(Wpt waypoint) {
    _waypoints.remove(waypoint);
    notifyListeners();
  }

  void clearWaypoints() {
    _waypoints.clear();
    notifyListeners();
  }
}
