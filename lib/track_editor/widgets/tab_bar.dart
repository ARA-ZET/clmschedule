// track_editor/widgets/tab_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/tab_item.dart';
import '../providers/te_files_provider.dart';
import '../providers/te_map_layer_provider.dart';
import '../providers/te_processing_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../providers/te_tools_provider.dart';

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
                                onTap: () {
                                  final tabIndex = ref
                                      .read(teTabsRiverpod)
                                      .tabs
                                      .indexOf(tab);
                                  ref.read(teTabsRiverpod).removeTab(tab);
                                  if (tabIndex >= 0) {
                                    ref
                                        .read(teMapLayerRiverpod)
                                        .removeTab(tabIndex);
                                  }
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
                      // "+" new tab button
                      return SizedBox(
                        width: tabWidth,
                        child: TextButton(
                          onPressed: () {
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
                          },
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.blueGrey,
                            shape: RoundedRectangleBorder(
                              side: const BorderSide(
                                  color: Colors.blueGrey, width: 2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Icon(Icons.create_new_folder, size: 20),
                        ),
                      );
                    } else {
                      // "Clear all" button
                      return SizedBox(
                        width: tabWidth,
                        child: Tooltip(
                          message: 'Clear all tabs and data',
                          child: TextButton(
                            onPressed: () {
                              ref.read(teTabsRiverpod).clearAllTabs();
                              ref.read(teMapLayerRiverpod).clearAll();
                              ref.read(teFilesRiverpod).clearFileNames();
                              ref.read(teProcessingRiverpod).clearFiles();
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
              spacing: toolGap,
              children: [
                // Scissors tool
                _ToolButton(
                  icon: Icons.content_cut,
                  tooltip: scissorsMode ? 'Exit split mode' : 'Split track',
                  isActive: scissorsMode,
                  activeColor: Colors.orange,
                  isLocked: drawingMode != TEDrawingMode.none,
                  onTap: () => ref.read(teToolsRiverpod).toggleScissors(),
                ),
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
