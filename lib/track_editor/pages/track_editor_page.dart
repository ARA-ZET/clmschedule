// track_editor/pages/track_editor_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/tab_item.dart';
import '../providers/te_mode_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../services/kml_parser.dart';
import '../widgets/drag_and_drop.dart';
import '../widgets/processing.dart';
import '../widgets/tab_bar.dart';
import '../widgets/te_cloud_save_panel.dart';
import '../widgets/te_processing_panel.dart';
import '../widgets/te_tab_details_panel.dart';
import '../widgets/uploaded_files.dart';
import 'track_editor_map.dart';

class TrackEditorPage extends riverpod.ConsumerStatefulWidget {
  const TrackEditorPage({super.key});

  @override
  riverpod.ConsumerState<TrackEditorPage> createState() =>
      _TrackEditorPageState();
}

class _TrackEditorPageState extends riverpod.ConsumerState<TrackEditorPage> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Sync tabs provider mode after the current frame to avoid
    // notifyListeners during build.
    final mode = ref.watch(teModeRiverpod).mode;
    final tabsProvider = ref.read(teTabsRiverpod);
    if (tabsProvider.activeMode != mode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) tabsProvider.setActiveMode(mode);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(teModeRiverpod).mode;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color.fromARGB(255, 255, 255, 255),
            Color.fromARGB(255, 233, 233, 233),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border(
          top: BorderSide(
            color: Color.fromARGB(255, 216, 216, 216),
            width: 2,
          ),
        ),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(top: 36),
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Left panel ──────────────────────────────────
                      SingleChildScrollView(
                        child: Column(
                          spacing: 12,
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            if (mode == TEMode.import) ...[
                              TEDragAndDrop(
                                onFilesPicked: (files) {
                                  for (final file in files) {
                                    final polygons =
                                        parseKmlWithStyles(file.bytes);
                                    if (polygons.isNotEmpty) {
                                      ref.read(teTabsRiverpod).addData(
                                            TETabItem(
                                              polygons: polygons,
                                              tracks: [],
                                              waypoints: [],
                                              title: file.name,
                                              targetPolygons: [],
                                            ),
                                          );
                                    }
                                  }
                                },
                              ),
                              const TEUploadedFiles(),
                              const TETabDetailsPanel(),
                            ] else if (mode == TEMode.trim) ...[
                              const TEProcessing(),
                              const TETabDetailsPanel(),
                            ] else if (mode == TEMode.processing) ...[
                              const TEProcessingPanel(),
                              const TECloudSavePanel(),
                              const TETabDetailsPanel(),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      // ── Map (always visible) ─────────────────────────
                      const Expanded(child: TEMap()),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const TETopTabBar(),
        ],
      ),
    );
  }
}
