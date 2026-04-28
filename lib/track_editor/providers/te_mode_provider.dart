// track_editor/providers/te_mode_provider.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

enum TEMode {
  import, // KML/GPX/KMZ file import & file list
  trim, // Trim waypoints to polygon boundaries & download results
  processing, // Match polygons against schedule jobs (future integration)
  update, // Opened from cloud: overwrite the original source file
}

final teModeRiverpod =
    riverpod.ChangeNotifierProvider<TEModeProvider>((ref) => TEModeProvider());

class TEModeProvider extends ChangeNotifier {
  TEMode _mode = TEMode.processing;

  TEMode get mode => _mode;

  void setMode(TEMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
  }
}
