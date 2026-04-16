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

    // Fixed-width right-side toolbar (scissors + future tools).
    // Each tool button is 36 px wide with 4 px gap between them.
    const double toolBtnSize = 36.0;
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
                Tooltip(
                  message: scissorsMode ? 'Exit split mode' : 'Split track',
                  child: SizedBox(
                    width: toolBtnSize,
                    child: Material(
                      elevation: scissorsMode ? 4 : 1,
                      borderRadius: BorderRadius.circular(8),
                      color: scissorsMode ? Colors.orange : Colors.white,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => ref.read(teToolsRiverpod).toggleScissors(),
                        child: Center(
                          child: Icon(
                            Icons.content_cut,
                            size: 18,
                            color: scissorsMode
                                ? Colors.white
                                : Colors.blueGrey.shade700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
