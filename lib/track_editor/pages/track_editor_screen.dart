// track_editor/pages/track_editor_screen.dart
//
// Full-screen shell for the Track Editor. Owns the Scaffold so that the
// app bar can expose mode-switch actions (Import / Trim / Processing)
// without needing an extra bar inside the body.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../../widgets/cloud_file_manager_screen.dart';
import '../models/tab_item.dart';
import '../providers/te_files_provider.dart';
import '../providers/te_mode_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../providers/te_tracks_provider.dart';
import '../providers/te_waypoints_provider.dart';
import '../services/kml_parser.dart';
import 'package:gpx/gpx.dart';
import 'track_editor_page.dart';

class TrackEditorScreen extends riverpod.ConsumerStatefulWidget {
  const TrackEditorScreen({super.key});

  @override
  riverpod.ConsumerState<TrackEditorScreen> createState() =>
      _TrackEditorScreenState();
}

class _TrackEditorScreenState
    extends riverpod.ConsumerState<TrackEditorScreen> {
  void _openCloudFiles(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CloudFileManagerScreen(
          onOpenInTrackEditor: (fileName, bytes, sourcePath) {
            Navigator.of(context).pop(); // Close file manager
            _loadFileIntoEditor(fileName, bytes, sourcePath);
          },
        ),
      ),
    );
  }

  void _loadFileIntoEditor(
      String fileName, Uint8List bytes, String? sourcePath) {
    final ext = fileName.split('.').last.toLowerCase();
    if (ext == 'gpx') {
      _loadGpxFile(fileName, bytes, sourcePath);
    } else if (ext == 'kml' || ext == 'kmz') {
      _loadKmlFile(fileName, bytes, sourcePath);
    }
  }

  void _loadGpxFile(String fileName, Uint8List bytes, String? sourcePath) {
    try {
      final xml = String.fromCharCodes(bytes);
      final gpx = GpxReader().fromString(xml);
      ref.read(teWaypointsRiverpod).addWaypoints(gpx.wpts);
      ref.read(teTracksRiverpod).addTracks(gpx.trks);
      ref.read(teFilesRiverpod).addFileNames([fileName]);
      ref.read(teTabsRiverpod).addData(
            TETabItem(
              title: fileName,
              polygons: [],
              tracks: gpx.trks,
              waypoints: gpx.wpts,
              targetPolygons: [],
              sourceStoragePath: sourcePath,
              storageFolderPath: _folderPathOf(sourcePath),
            ),
          );
      debugPrint(
          '✅ Cloud: ${gpx.wpts.length} waypoints, ${gpx.trks.length} tracks from $fileName');
    } catch (e) {
      debugPrint('❌ Error parsing GPX $fileName: $e');
    }
  }

  void _loadKmlFile(String fileName, Uint8List bytes, String? sourcePath) {
    try {
      final polygons = parseKmlWithStyles(bytes);
      if (polygons.isNotEmpty) {
        ref.read(teFilesRiverpod).addFileNames([fileName]);
        ref.read(teTabsRiverpod).addData(
              TETabItem(
                polygons: polygons,
                tracks: [],
                waypoints: [],
                title: fileName,
                targetPolygons: [],
                sourceStoragePath: sourcePath,
                storageFolderPath: _folderPathOf(sourcePath),
              ),
            );
        ref.read(teModeRiverpod).setMode(TEMode.import);
        debugPrint('✅ Cloud: ${polygons.length} polygons from $fileName');
      }
    } catch (e) {
      debugPrint('❌ Error parsing KML $fileName: $e');
    }
  }

  /// Strip the file-name segment from a full storage path to derive the
  /// folder it lives in. Returns null if [sourcePath] is null or empty.
  String? _folderPathOf(String? sourcePath) {
    if (sourcePath == null || sourcePath.isEmpty) return null;
    final slash = sourcePath.lastIndexOf('/');
    if (slash <= 0) return null;
    return sourcePath.substring(0, slash);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(teModeRiverpod).mode;
    final modeProvider = ref.read(teModeRiverpod);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 222, 222, 222),
      appBar: AppBar(
        backgroundColor: colorScheme.inversePrimary,
        title: const Text(
          'Track Editor',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          // ── Processing ───────────────────────────────────────────
          _ModeButton(
            icon: Icons.settings_suggest,
            label: 'Processing',
            selected: mode == TEMode.processing,
            onTap: () => modeProvider.setMode(TEMode.processing),
          ),
          // ── Import ───────────────────────────────────────────────
          _ModeButton(
            icon: Icons.upload_file,
            label: 'Import',
            selected: mode == TEMode.import,
            onTap: () => modeProvider.setMode(TEMode.import),
          ),
          // ── Trim ─────────────────────────────────────────────────
          _ModeButton(
            icon: Icons.content_cut,
            label: 'Trim',
            selected: mode == TEMode.trim,
            onTap: () => modeProvider.setMode(TEMode.trim),
          ),
          const SizedBox(width: 8),
          // ── Cloud Files ──────────────────────────────────────────
          _ModeButton(
            icon: Icons.cloud,
            label: 'Cloud Files',
            selected: false,
            onTap: () => _openCloudFiles(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: const TrackEditorPage(),
    );
  }
}

// ── A labelled toggle button used in the app bar ──────────────────────────────
class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: TextButton.styleFrom(
          foregroundColor: selected ? Colors.white : Colors.black54,
          backgroundColor: selected
              ? Colors.blueGrey.shade600
              : Colors.black.withValues(alpha: 0.05),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}
