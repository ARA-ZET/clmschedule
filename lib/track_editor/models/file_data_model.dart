// track_editor/models/file_data_model.dart
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';

class TEFileDataModel {
  final String name;
  final List<Polygon> polygons;
  final List<Trkseg> tracks;
  final List<Wpt> waypoints;

  TEFileDataModel({
    required this.name,
    required this.polygons,
    required this.tracks,
    required this.waypoints,
  });
}
