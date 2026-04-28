// track_editor/models/tab_item.dart
import 'package:gpx/gpx.dart';
import 'styled_polygon.dart';

class TETabItem {
  final String title;
  final List<TEStyledPolygon> polygons;
  final List<Trk> tracks;
  final List<Wpt> waypoints;
  final List<TETargetPolygon> targetPolygons;
  final String? storageFolderPath;

  /// Full Cloud Storage path this tab was originally loaded from
  /// (e.g. `Distribution/2026/Apr 2026/Client/Round 1/Route1.gpx`).
  /// When set, the Track Editor can overwrite-save back to this exact file.
  final String? sourceStoragePath;

  TETabItem({
    required this.title,
    required this.polygons,
    required this.tracks,
    required this.waypoints,
    required this.targetPolygons,
    this.storageFolderPath,
    this.sourceStoragePath,
  });
}
