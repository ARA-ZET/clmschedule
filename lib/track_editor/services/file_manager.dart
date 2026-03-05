// track_editor/services/file_manager.dart
import 'package:gpx/gpx.dart';
import '../utils/download_helper.dart';

class TEFileManager {
  static TEFileManager? _instance;
  TEFileManager._internal() {
    _instance = this;
  }
  factory TEFileManager() => _instance ?? TEFileManager._internal();

  static const String _gpxNamespace =
      '<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" '
      'creator="ARAZET Design CLM GPX" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 '
      'https://www.topografix.com/GPX/1/1/gpx.xsd">';

  String _fixNamespace(String xml) => xml.replaceFirst(
      '<gpx version="1.1" creator="dart-gpx library">', _gpxNamespace);

  Future<String> _toGpxString(List<Wpt> points) async {
    final gpx = Gpx()
      ..version = '1.1'
      ..creator = 'dart-gpx library'
      ..metadata = (Metadata()
        ..name = 'CLM Track Editor Export'
        ..time = DateTime.now())
      ..wpts = points;

    return _fixNamespace(GpxWriter().asString(gpx, pretty: true));
  }

  Future<String> _toGpxTracksString(List<Trk> tracks) async {
    final gpx = Gpx()
      ..version = '1.1'
      ..creator = 'dart-gpx library'
      ..metadata = (Metadata()
        ..name = 'CLM Track Editor Export'
        ..time = DateTime.now())
      ..trks = tracks;

    return _fixNamespace(GpxWriter().asString(gpx, pretty: true));
  }

  Future<void> saveGpxWaypointsFile(String fileName, List<Wpt> points) async {
    final xmlString = await _toGpxString(points);
    await downloadStringAsFile(xmlString, fileName);
  }

  Future<void> saveGpxTracksFile(String fileName, List<Trk> tracks) async {
    final xmlString = await _toGpxTracksString(tracks);
    await downloadStringAsFile(xmlString, fileName);
  }
}
