// track_editor/models/tab_item.dart
import 'package:gpx/gpx.dart';
import 'styled_polygon.dart';

class TETabItem {
  final String title;
  final List<TEStyledPolygon> polygons;
  final List<Trk> tracks;
  final List<Wpt> waypoints;
  final List<TETargetPolygon> targetPolygons;

  TETabItem({
    required this.title,
    required this.polygons,
    required this.tracks,
    required this.waypoints,
    required this.targetPolygons,
  });
}
