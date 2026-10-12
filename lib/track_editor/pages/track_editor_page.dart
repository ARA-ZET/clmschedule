// track_editor/pages/track_editor_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/tab_item.dart';
import '../providers/te_mode_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../providers/te_schedule_sync_provider.dart';
import '../providers/te_undo_provider.dart';
import '../providers/te_view_provider.dart';
import '../services/kml_parser.dart';
import '../widgets/drag_and_drop.dart';
import '../widgets/processing.dart';
import '../widgets/tab_bar.dart';
import '../widgets/te_cloud_save_panel.dart';
import '../widgets/te_letterbox_comparison_panel.dart';
import '../widgets/te_processing_panel.dart';
import '../widgets/te_analysis_view.dart';
import '../widgets/te_report_panel.dart';
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
  void initState() {
    super.initState();
    // Listen for mode changes and sync all per-mode providers via the
    // central helper so any new per-mode provider added later only needs
    // to be wired into [applyTrackEditorMode] in te_mode_provider.dart.
    ref.listenManual(teModeRiverpod, (previous, next) {
      applyTrackEditorMode(
        riverpod.ProviderScope.containerOf(context),
        next.mode,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(teModeRiverpod).mode;
    // Keeps open processing tabs in step with schedule edits made elsewhere.
    ref.watch(teScheduleSyncRiverpod);

    void doUndo() {
      final tabsP = ref.read(teTabsRiverpod);
      final undoP = ref.read(teUndoRiverpod);
      final idx = tabsP.currentTab;
      if (!undoP.canUndo(tabsP.activeMode, idx)) {
        debugPrint('↩️ Undo: nothing to undo on ${tabsP.activeMode} tab $idx');
        return;
      }
      debugPrint(
          '↩️ Undo: ${undoP.nextUndoDescription(tabsP.activeMode, idx)}');
      undoP.undo(tabsP.activeMode, idx);
    }

    void doRedo() {
      final tabsP = ref.read(teTabsRiverpod);
      final undoP = ref.read(teUndoRiverpod);
      final idx = tabsP.currentTab;
      if (!undoP.canRedo(tabsP.activeMode, idx)) {
        debugPrint('↪️ Redo: nothing to redo on ${tabsP.activeMode} tab $idx');
        return;
      }
      debugPrint(
          '↪️ Redo: ${undoP.nextRedoDescription(tabsP.activeMode, idx)}');
      undoP.redo(tabsP.activeMode, idx);
    }

    return CallbackShortcuts(
      bindings: {
        // Ctrl/Cmd + Z = undo (use both `control` and `meta` so the
        // shortcut works on both Windows/Linux and macOS).
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): doUndo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): doUndo,
        // Ctrl/Cmd + Y = redo.
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): doRedo,
        const SingleActivator(LogicalKeyboardKey.keyY, meta: true): doRedo,
        // Ctrl/Cmd + Shift + Z = redo (common on macOS).
        const SingleActivator(LogicalKeyboardKey.keyZ,
            control: true, shift: true): doRedo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            doRedo,
      },
      child: Focus(
        autofocus: true,
        child: _buildBody(mode),
      ),
    );
  }

  Widget _buildBody(TEMode mode) {
    // Report mode doesn't use the tab system at all — no map/analysis pane,
    // no undo stack, no top tab bar to switch between open files — so it
    // gets its own simple full-width layout rather than threading a new
    // branch through every corner of the tab-based layout below.
    if (mode == TEMode.report) {
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
        child: const Padding(
          padding: EdgeInsets.fromLTRB(12, 24, 12, 12),
          child: TEReportPanel(),
        ),
      );
    }

    // In processing mode we need the active tab to decide which panels to show.
    final tabsProvider = ref.watch(teTabsRiverpod);
    final activeTab = tabsProvider.tabs.isNotEmpty
        ? tabsProvider.tabs[tabsProvider.currentTab]
        : null;
    final tabHasDistributor = activeTab?.distributorId != null &&
        activeTab!.distributorId!.isNotEmpty;
    // A track whose file name matched no distributor still gets the
    // cloud-save panel: it is where the distributor is picked by hand.
    final tabHasTrackData = activeTab != null &&
        (activeTab.tracks.isNotEmpty || activeTab.waypoints.isNotEmpty);

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
                              // Once the tab holds a round (matched to a
                              // distributor or not — an unmatched one picks
                              // its distributor there), show the cloud-save
                              // panel and hide the file picker. With no data
                              // yet, show the file picker so the user can
                              // select files.
                              if (tabHasDistributor || tabHasTrackData) ...[
                                const TECloudSavePanel(),
                                const TELetterboxComparisonPanel(),
                                const TETabDetailsPanel(),
                              ] else ...[
                                const TEProcessingPanel(),
                                const TELetterboxComparisonPanel(),
                                const TETabDetailsPanel(),
                              ],
                            ] else if (mode == TEMode.update) ...[
                              const TETabDetailsPanel(),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      // ── Map or Analysis ──────────────────────────────
                      // Both are fed by the same tab; the analysis view is
                      // read-only, so the map keeps its state (camera,
                      // selections) while it is switched away from.
                      Expanded(
                        child: IndexedStack(
                          // The Row aligns to the top, so this pane is handed
                          // loose height. Expand pins both children to the
                          // full pane the way `Expanded(child: TEMap())` used
                          // to, instead of letting the stack shrink to
                          // whichever child happens to be shorter.
                          sizing: StackFit.expand,
                          index:
                              ref.watch(teViewRiverpod).view == TEPaneView.map
                                  ? 0
                                  : 1,
                          children: const [
                            TEMap(),
                            TEAnalysisView(),
                          ],
                        ),
                      ),
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
