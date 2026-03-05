// track_editor/providers/te_polygons_provider.dart
import 'package:flutter/material.dart';
import '../models/styled_polygon.dart';

class TEPolygonsProvider extends ChangeNotifier {
  List<TEStyledPolygon> _polygons = [];
  List<TEStyledPolygon> get polygons => _polygons;

  void clearPolygons() {
    _polygons.clear();
    notifyListeners();
  }

  void setPolygons(List<TEStyledPolygon> polygons) {
    _polygons = polygons;
    notifyListeners();
  }

  void addPolygons(List<TEStyledPolygon> polygons) {
    _polygons.addAll(polygons);
    notifyListeners();
  }

  void removePolygon(TEStyledPolygon polygon) {
    _polygons.remove(polygon);
    notifyListeners();
  }

  void removePolygonAt(int index) {
    if (index >= 0 && index < _polygons.length) {
      _polygons.removeAt(index);
      notifyListeners();
    }
  }
}
