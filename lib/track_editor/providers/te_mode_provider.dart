// track_editor/providers/te_mode_provider.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import 'te_files_provider.dart';
import 'te_map_layer_provider.dart';
import 'te_tabs_provider.dart';
import 'te_tracks_provider.dart';
import 'te_waypoints_provider.dart';

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

/// Single source of truth for switching the entire track-editor stack into
/// [mode]. Sets [TEModeProvider.mode] AND the per-mode bucket on every
/// per-mode provider so they stay in lock-step. Use this anywhere outside
/// the normal mode-toggle UI (e.g. when loading a cloud file before the
/// editor page is mounted) so we never end up with data being routed into
/// the wrong bucket.
void applyTrackEditorMode(
  riverpod.ProviderContainer container,
  TEMode mode,
) {
  container.read(teModeRiverpod).setMode(mode);
  container.read(teTabsRiverpod).setActiveMode(mode);
  container.read(teFilesRiverpod).setActiveMode(mode);
  container.read(teMapLayerRiverpod).setActiveMode(mode);
  container.read(teTracksRiverpod).setActiveMode(mode);
  container.read(teWaypointsRiverpod).setActiveMode(mode);
}
