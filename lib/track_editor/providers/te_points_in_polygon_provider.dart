// track_editor/providers/te_points_in_polygon_provider.dart
import 'package:flutter/material.dart';
import '../models/styled_polygon.dart';

class TEPointsInPolygonProvider extends ChangeNotifier {
  final List<TETargetPolygon> _polygons = [];
  List<TETargetPolygon> get polygons => _polygons;

  void addPolygon(TETargetPolygon polygon) {
    _polygons.add(polygon);
    notifyListeners();
  }

  void addPolygons(List<TETargetPolygon> polygons) {
    _polygons.clear();
    _polygons.addAll(polygons);
    notifyListeners();
  }

  void removePolygon(TETargetPolygon polygon) {
    _polygons.remove(polygon);
    notifyListeners();
  }

  void clearPolygons() {
    _polygons.clear();
    notifyListeners();
  }
}
