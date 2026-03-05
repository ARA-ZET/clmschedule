// track_editor/providers/te_tracks_provider.dart
import 'package:flutter/material.dart';
import 'package:gpx/gpx.dart';

class TETracksProvider with ChangeNotifier {
  final List<Trk> _tracks = [];
  List<Trk> get tracks => _tracks;

  void addTrack(Trk track) {
    _tracks.add(track);
    notifyListeners();
  }

  void addTracks(List<Trk> tracks) {
    _tracks.addAll(tracks);
    notifyListeners();
  }

  void clearTracks() {
    _tracks.clear();
    notifyListeners();
  }
}
