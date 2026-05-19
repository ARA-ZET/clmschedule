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
    loadCloudFileIntoTrackEditor(
      container: riverpod.ProviderScope.containerOf(context),
      fileName: fileName,
      bytes: bytes,
      sourcePath: sourcePath,
    );
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
          // ── Update ───────────────────────────────────────────────
          // Activated automatically when a file is opened from the cloud
          // file manager. Lets the user overwrite the original source file.
          _ModeButton(
            icon: Icons.save_as,
            label: 'Update',
            selected: mode == TEMode.update,
            onTap: () => modeProvider.setMode(TEMode.update),
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

/// Top-level helper to load a file from Cloud Storage into the Track Editor
/// from outside the [TrackEditorScreen] (e.g. the Shareable Map editor) and
/// from inside it (the Cloud Files button). When [sourcePath] is supplied
/// the editor switches to [TEMode.update] so the sidebar shows the
/// "Update File" action that overwrites the original cloud file.
/// Uses a [riverpod.ProviderContainer] obtained via
/// `ProviderScope.containerOf(context)` so it can write to the same
/// providers without a [riverpod.WidgetRef].
void loadCloudFileIntoTrackEditor({
  required riverpod.ProviderContainer container,
  required String fileName,
  required Uint8List bytes,
  String? sourcePath,
}) {
  String? folderPathOf(String? p) {
    if (p == null || p.isEmpty) return null;
    final slash = p.lastIndexOf('/');
    if (slash <= 0) return null;
    return p.substring(0, slash);
  }

  final fromCloud = sourcePath != null && sourcePath.isNotEmpty;
  final folderPath = folderPathOf(sourcePath);
  final ext = fileName.split('.').last.toLowerCase();
  try {
    if (ext == 'gpx') {
      final xml = String.fromCharCodes(bytes);
      final gpx = GpxReader().fromString(xml);
      // Switch mode FIRST so per-mode providers (waypoints, tracks, files,
      // tabs) route data into the correct bucket. If we add data first the
      // per-mode providers default to processing mode and we leak waypoints/
      // tracks/file names into Processing while the tab lives in Update.
      if (fromCloud) {
        applyTrackEditorMode(container, TEMode.update);
      }
      container.read(teWaypointsRiverpod).addWaypoints(gpx.wpts);
      container.read(teTracksRiverpod).addTracks(gpx.trks);
      container.read(teFilesRiverpod).addFileNames([fileName]);
      final tab = TETabItem(
        title: fileName,
        polygons: const [],
        tracks: gpx.trks,
        waypoints: gpx.wpts,
        targetPolygons: const [],
        sourceStoragePath: sourcePath,
        storageFolderPath: folderPath,
      );
      if (fromCloud) {
        container.read(teTabsRiverpod).addTabsBatch([tab]);
      } else {
        container.read(teTabsRiverpod).addData(tab);
      }
    } else if (ext == 'kml' || ext == 'kmz') {
      final polygons = parseKmlWithStyles(bytes);
      if (polygons.isEmpty) return;
      // Match the GPX branch: switch mode before mutating per-mode state.
      if (fromCloud) {
        applyTrackEditorMode(container, TEMode.update);
      }
      container.read(teFilesRiverpod).addFileNames([fileName]);
      final tab = TETabItem(
        polygons: polygons,
        tracks: const [],
        waypoints: const [],
        title: fileName,
        targetPolygons: const [],
        sourceStoragePath: sourcePath,
        storageFolderPath: folderPath,
      );
      if (fromCloud) {
        container.read(teTabsRiverpod).addTabsBatch([tab]);
      } else {
        container.read(teTabsRiverpod).addData(tab);
        container.read(teModeRiverpod).setMode(TEMode.import);
      }
    }
  } catch (e) {
    debugPrint('loadCloudFileIntoTrackEditor: failed for $fileName: $e');
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
