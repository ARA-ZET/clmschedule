// track_editor/providers/te_tracks_provider.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:gpx/gpx.dart';
import 'te_mode_provider.dart';

final teTracksRiverpod = riverpod.ChangeNotifierProvider<TETracksProvider>(
    (ref) => TETracksProvider());

class TETracksProvider with ChangeNotifier {
  final Map<TEMode, List<Trk>> _tracksByMode = {
    TEMode.import: [],
    TEMode.trim: [],
    TEMode.processing: [],
    TEMode.update: [],
  };
  TEMode _activeMode = TEMode.processing;

  List<Trk> get tracks => _tracksByMode[_activeMode]!;

  void setActiveMode(TEMode mode) {
    if (_activeMode == mode) return;
    _activeMode = mode;
    notifyListeners();
  }

  void addTrack(Trk track) {
    _tracksByMode[_activeMode]!.add(track);
    notifyListeners();
  }

  void addTracks(List<Trk> tracks) {
    _tracksByMode[_activeMode]!.addAll(tracks);
    notifyListeners();
  }

  void clearTracks() {
    _tracksByMode[_activeMode]!.clear();
    notifyListeners();
  }

  void clearAll() {
    for (final mode in TEMode.values) {
      _tracksByMode[mode]!.clear();
    }
    notifyListeners();
  }
}
