// track_editor/widgets/tab_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/tab_item.dart';
import '../pages/track_editor_screen.dart';
import '../providers/te_cloud_save_state_provider.dart';
import '../providers/te_files_provider.dart';
import '../providers/te_map_layer_provider.dart';
import '../providers/te_mode_provider.dart';
import '../providers/te_processing_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../providers/te_tools_provider.dart';
import '../providers/te_tracks_provider.dart';
import '../providers/te_undo_provider.dart';
import '../providers/te_view_provider.dart';
import '../providers/te_wage_stats_provider.dart';
import '../providers/te_waypoints_provider.dart';
import '../providers/te_work_area_overlay_provider.dart';
import '../../providers/schedule_provider.dart';

class TETopTabBar extends riverpod.ConsumerWidget {
  const TETopTabBar({super.key});

  static const double maxTabWidth = 84;
  static const double minTabWidth = 60;

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final tabsProvider = ref.watch(teTabsRiverpod);
    final tabs = tabsProvider.tabs;
    final selectedIndex = tabsProvider.currentTab;
    final scissorsMode = ref.watch(teToolsRiverpod).scissorsMode;
    final drawingMode = ref.watch(teToolsRiverpod).drawingMode;

    // Fixed-width right-side toolbar.
    const double toolGap = 4.0;

    return Container(
      height: 30,
      margin: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Scrollable tabs area ───────────────────────────────────────
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // +2 accounts for the "+" button and the "clear all" button
                final itemCount = tabs.length + 2;
                const spacing = 8.0;
                double tabWidth =
                    (constraints.maxWidth - (itemCount - 1) * spacing) /
                        itemCount;
                tabWidth = tabWidth.clamp(minTabWidth, maxTabWidth);

                return ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 12),
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    if (index < tabs.length) {
                      final tab = tabs[index];
                      final isSelected = index == selectedIndex;
                      return SizedBox(
                        width: tabWidth,
                        child: TextButton(
                          onPressed: () =>
                              ref.read(teTabsRiverpod).selectTab(index),
                          style: TextButton.styleFrom(
                            backgroundColor:
                                isSelected ? Colors.blueGrey : Colors.white,
                            foregroundColor:
                                isSelected ? Colors.white : Colors.blueGrey,
                            padding: const EdgeInsets.only(left: 8, right: 2),
                            shape: RoundedRectangleBorder(
                              side: const BorderSide(
                                  color: Colors.blueGrey, width: 2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  tab.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.blueGrey.shade800,
                                  ),
                                ),
                              ),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () async {
                                  final tabsP = ref.read(teTabsRiverpod);
                                  final tabIndex = tabsP.tabs.indexOf(tab);
                                  final mode = tabsP.activeMode;
                                  // In processing mode, warn if any clients
                                  // haven't been saved yet, or if the
                                  // embedded wage-stats box has unsaved
                                  // edits not yet pushed to payroll.
                                  if (mode == TEMode.processing) {
                                    final saveState =
                                        ref.read(teCloudSaveRiverpod);
                                    final clients = saveState.clientsFor(tab);
                                    final unsaved = clients
                                        .where((c) =>
                                            !c.savedAsIs && !c.trimmedSaved)
                                        .toList();
                                    final wageStatsDirty = ref
                                        .read(teWageStatsRiverpod)
                                        .isDirty(tab);
                                    if ((unsaved.isNotEmpty ||
                                            wageStatsDirty) &&
                                        context.mounted) {
                                      final messages = <String>[];
                                      if (unsaved.isNotEmpty) {
                                        final clientNames = unsaved
                                            .map((c) => c.clientName)
                                            .join(', ');
                                        messages.add(
                                          unsaved.length == clients.length
                                              ? 'No clients have been saved yet.\n$clientNames'
                                              : '${unsaved.length} of ${clients.length} '
                                                  '${unsaved.length == 1 ? 'client has' : 'clients have'} '
                                                  'not been saved:\n$clientNames',
                                        );
                                      }
                                      if (wageStatsDirty) {
                                        messages.add(
                                          'Wage stats for this day have not '
                                          'been saved to payroll.',
                                        );
                                      }
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('Unsaved changes'),
                                          content: Text(messages.join('\n\n')),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.of(ctx).pop(false),
                                              child: const Text('Cancel'),
                                            ),
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.of(ctx).pop(true),
                                              style: TextButton.styleFrom(
                                                foregroundColor:
                                                    Colors.red.shade700,
                                              ),
                                              child: const Text('Close anyway'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirmed != true) return;
                                    }
                                  }
                                  // Clear cloud-save/wage-stats UI state for
                                  // the closing tab and drop its undo/redo
                                  // stack so the next tab in this slot
                                  // starts fresh.
                                  ref.read(teCloudSaveRiverpod).clearTab(tab);
                                  ref.read(teWageStatsRiverpod).clearTab(tab);
                                  if (tabIndex >= 0) {
                                    ref
                                        .read(teUndoRiverpod)
                                        .removeTab(mode, tabIndex);
                                    ref
                                        .read(teMapLayerRiverpod)
                                        .removeTab(tabIndex);
                                  }
                                  // If this tab was opened from the
                                  // processing flow, also drop the matching
                                  // staged GPX files so the next "Open all
                                  // matched" run won't re-open the closed
                                  // tab from leftover entries.
                                  if (mode == TEMode.processing &&
                                      tab.matchKey != null) {
                                    ref
                                        .read(teProcessingRiverpod)
                                        .removeFilesForMatchKey(tab.matchKey);
                                  }
                                  tabsP.removeTab(tab);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 2),
                                  child: Icon(
                                    Icons.close,
                                    size: 13,
                                    color: isSelected
                                        ? Colors.white70
                                        : Colors.blueGrey.shade400,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    } else if (index == tabs.length) {
                      // "+" new tab button. In Update mode a blank tab is
                      // useless — there is nothing to update — so the button
                      // opens the Cloud Files browser instead and the picked
                      // file lands in its own new tab. A long-press still
                      // gives an empty tab in every mode.
                      final isUpdateMode =
                          tabsProvider.activeMode == TEMode.update;
                      void addEmptyTab() {
                        final newTab = TETabItem(
                          title: 'untitled ${index + 1}',
                          polygons: [],
                          tracks: [],
                          waypoints: [],
                          targetPolygons: [],
                        );
                        ref.read(teTabsRiverpod)
                          ..addTab(newTab)
                          ..selectTab(index);
                      }

                      return SizedBox(
                        width: tabWidth,
                        child: Tooltip(
                          message: isUpdateMode
                              ? 'Open a cloud file in a new tab\n'
                                  '(long-press for an empty tab)'
                              : 'New empty tab',
                          child: TextButton(
                            onPressed: isUpdateMode
                                ? () => openCloudFilesForTrackEditor(context)
                                : addEmptyTab,
                            onLongPress: isUpdateMode ? addEmptyTab : null,
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.blueGrey,
                              shape: RoundedRectangleBorder(
                                side: const BorderSide(
                                    color: Colors.blueGrey, width: 2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Icon(
                                isUpdateMode
                                    ? Icons.cloud_download
                                    : Icons.create_new_folder,
                                size: 20),
                          ),
                        ),
                      );
                    } else {
                      // "Clear all" button
                      return SizedBox(
                        width: tabWidth,
                        child: Tooltip(
                          message: 'Clear all tabs and data',
                          child: TextButton(
                            onPressed: () async {
                              // Destructive: wipes every mode (Import, Trim,
                              // Processing, Update). Confirm before doing
                              // anything so the user can't lose work with
                              // a stray click.
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Clear all data?'),
                                  content: const Text(
                                    'This will close every tab and discard '
                                    'all loaded files, tracks and waypoints '
                                    'across all modes (Import, Trim, '
                                    'Processing and Update). This cannot be '
                                    'undone.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(true),
                                      style: TextButton.styleFrom(
                                        foregroundColor: Colors.red.shade700,
                                      ),
                                      child: const Text('Clear all'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true) return;
                              ref.read(teTabsRiverpod).clearAllTabs();
                              ref.read(teMapLayerRiverpod).clearAll();
                              ref.read(teFilesRiverpod).clearAll();
                              ref.read(teTracksRiverpod).clearAll();
                              ref.read(teWaypointsRiverpod).clearAll();
                              ref.read(teProcessingRiverpod).clearFiles();
                              ref.read(teUndoRiverpod).clearAll();
                            },
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.red.shade50,
                              foregroundColor: Colors.red.shade700,
                              shape: RoundedRectangleBorder(
                                side: BorderSide(
                                    color: Colors.red.shade300, width: 2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Icon(Icons.delete_sweep,
                                size: 20, color: Colors.red.shade700),
                          ),
                        ),
                      );
                    }
                  },
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                );
              },
            ),
          ),
          // ── Right-side tool buttons ────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(left: toolGap, right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              // Stretch, so every control in this row — the labelled
              // Map/Analysis switch included — is exactly as tall as the
              // icon buttons beside it.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: toolGap,
              children: [
                // Map / Analysis switch for the right-hand pane. First in the
                // row because it changes what everything to its right acts on:
                // the editing tools only apply to the map.
                Builder(builder: (_) {
                  final viewP = ref.watch(teViewRiverpod);
                  final isAnalysis = viewP.view == TEPaneView.analysis;
                  return _ViewSwitch(
                    isAnalysis: isAnalysis,
                    onTap: () => ref.read(teViewRiverpod).toggleView(),
                  );
                }),
                // Undo / Redo (per-tab) — placed just before the scissors
                // tool so the user can quickly revert an accidental cut or
                // drag without leaving the tab.
                Builder(builder: (_) {
                  final tabsP = ref.watch(teTabsRiverpod);
                  final undoP = ref.watch(teUndoRiverpod);
                  final mode = tabsP.activeMode;
                  final tabIdx = tabsP.currentTab;
                  final canUndo = undoP.canUndo(mode, tabIdx);
                  final undoDesc = undoP.nextUndoDescription(mode, tabIdx);
                  return _ToolButton(
                    icon: Icons.undo,
                    tooltip:
                        canUndo ? 'Undo: ${undoDesc ?? ''}' : 'Nothing to undo',
                    isActive: canUndo,
                    activeColor: Colors.orange.shade300,
                    isLocked: !canUndo,
                    onTap: () => ref.read(teUndoRiverpod).undo(mode, tabIdx),
                  );
                }),
                Builder(builder: (_) {
                  final tabsP = ref.watch(teTabsRiverpod);
                  final undoP = ref.watch(teUndoRiverpod);
                  final mode = tabsP.activeMode;
                  final tabIdx = tabsP.currentTab;
                  final canRedo = undoP.canRedo(mode, tabIdx);
                  final redoDesc = undoP.nextRedoDescription(mode, tabIdx);
                  return _ToolButton(
                    icon: Icons.redo,
                    tooltip:
                        canRedo ? 'Redo: ${redoDesc ?? ''}' : 'Nothing to redo',
                    isActive: canRedo,
                    activeColor: Colors.orange.shade300,
                    isLocked: !canRedo,
                    onTap: () => ref.read(teUndoRiverpod).redo(mode, tabIdx),
                  );
                }),
                // Scissors tool
                _ToolButton(
                  icon: Icons.content_cut,
                  tooltip: scissorsMode ? 'Exit split mode' : 'Split track',
                  isActive: scissorsMode,
                  activeColor: Colors.orange,
                  isLocked: drawingMode != TEDrawingMode.none,
                  onTap: () => ref.read(teToolsRiverpod).toggleScissors(),
                ),
                // Work-areas overlay: draw every saved work area on the map
                // so a round's areas can be picked by looking at the ground
                // they cover rather than by remembering their names.
                Builder(builder: (_) {
                  final overlay = ref.watch(teWorkAreaOverlayRiverpod);
                  return _LabelledToolButton(
                    icon: Icons.layers_outlined,
                    label: 'Work areas',
                    tooltip: overlay.isLoading
                        ? 'Loading work areas…'
                        : overlay.isVisible
                            ? 'Hide work areas'
                            : 'Show work areas to add',
                    isActive: overlay.isVisible,
                    isBusy: overlay.isLoading,
                    activeColor: Colors.teal,
                    isLocked: scissorsMode || drawingMode != TEDrawingMode.none,
                    onTap: () => ref
                        .read(teWorkAreaOverlayRiverpod)
                        .toggle(ref.read(scheduleRiverpod)),
                  );
                }),
                // Draw polygon tool
                _ToolButton(
                  icon: Icons.pentagon_outlined,
                  tooltip: drawingMode == TEDrawingMode.polygon
                      ? 'Exit polygon drawing'
                      : 'Draw polygon',
                  isActive: drawingMode == TEDrawingMode.polygon,
                  activeColor: Colors.blue,
                  isLocked: scissorsMode,
                  onTap: () => ref.read(teToolsRiverpod).toggleDrawPolygon(),
                ),
                // Draw point tool
                _ToolButton(
                  icon: Icons.place_outlined,
                  tooltip: drawingMode == TEDrawingMode.point
                      ? 'Exit point placement'
                      : 'Place point',
                  isActive: drawingMode == TEDrawingMode.point,
                  activeColor: Colors.blue,
                  isLocked: scissorsMode,
                  onTap: () => ref.read(teToolsRiverpod).toggleDrawPoint(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Reusable tool button for the right-side toolbar.
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final Color activeColor;
  final bool isLocked;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.activeColor,
    required this.isLocked,
    required this.onTap,
  });

  static const double _size = 36.0;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isLocked ? '' : tooltip,
      child: SizedBox(
        width: _size,
        child: Material(
          elevation: isActive ? 4 : 1,
          borderRadius: BorderRadius.circular(8),
          color: isActive ? activeColor : Colors.white,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: isLocked ? null : onTap,
            child: Center(
              child: Icon(
                icon,
                size: 18,
                color: isLocked
                    ? Colors.grey.shade400
                    : isActive
                        ? Colors.white
                        : Colors.blueGrey.shade700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two-segment Map/Analysis switch for the right-hand pane. Labelled rather
/// than icon-only: it changes what the whole pane is, not what a tool does.
class _ViewSwitch extends StatelessWidget {
  final bool isAnalysis;
  final VoidCallback onTap;

  const _ViewSwitch({required this.isAnalysis, required this.onTap});

  @override
  Widget build(BuildContext context) {
    Widget seg(IconData icon, String label, bool selected) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: selected ? Colors.blueGrey : Colors.transparent,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 14,
                  color: selected ? Colors.white : Colors.blueGrey.shade400),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: selected ? Colors.white : Colors.blueGrey.shade400,
                ),
              ),
            ],
          ),
        );

    return Tooltip(
      message: isAnalysis
          ? 'Back to the map'
          : 'Analyse this distributor\u2019s tracklog and handouts',
      child: Material(
        elevation: 1,
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                seg(Icons.map_outlined, 'Map', !isAnalysis),
                seg(Icons.insights, 'Analysis', isAnalysis),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tool button that carries its name as well as its icon.
///
/// For tools whose icon cannot carry the meaning on its own — a stack of
/// layers could be anything, while "Work areas" is the words the user already
/// has for the thing. Same shape, colours and states as [_ToolButton], just
/// wide enough for a label.
class _LabelledToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool isActive;
  final Color activeColor;
  final bool isLocked;

  /// Work still in flight — fetching every saved work area takes a moment, and
  /// the icon-only version of this button gave no sign it was doing anything.
  final bool isBusy;

  final VoidCallback onTap;

  const _LabelledToolButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.isActive,
    required this.activeColor,
    required this.isLocked,
    required this.onTap,
    this.isBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isLocked
        ? Colors.grey.shade400
        : isActive
            ? Colors.white
            : Colors.blueGrey.shade700;

    return Tooltip(
      message: isLocked ? '' : tooltip,
      child: Material(
        elevation: isActive ? 4 : 1,
        borderRadius: BorderRadius.circular(8),
        color: isActive ? activeColor : Colors.white,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: isLocked ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: isBusy
                      ? Padding(
                          padding: const EdgeInsets.all(1),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(fg),
                          ),
                        )
                      : Icon(icon, size: 16, color: fg),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
