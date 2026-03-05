// track_editor/widgets/tab_bar.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tab_item.dart';
import '../providers/te_mode_provider.dart';
import '../providers/te_tabs_provider.dart';

class TETopTabBar extends StatelessWidget {
  const TETopTabBar({super.key});

  static const double maxTabWidth = 84;
  static const double minTabWidth = 60;

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<TEModeProvider>().mode;
    final tabsProvider = context.watch<TETabsProvider>();
    final tabsRead = context.read<TETabsProvider>();
    // Sync active mode so tabs always reflect the current mode.
    tabsRead.setActiveMode(mode);
    final tabs = tabsProvider.tabs;
    final selectedIndex = tabsProvider.currentTab;

    return Container(
      height: 30,
      margin: const EdgeInsets.only(top: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalAvailableWidth = constraints.maxWidth;
          final itemCount = tabs.length + 1;
          const spacing = 8.0;
          double tabWidth =
              (totalAvailableWidth - (itemCount - 1) * spacing) / itemCount;
          tabWidth = tabWidth.clamp(minTabWidth, maxTabWidth);

          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (index < tabs.length) {
                final tab = tabs[index];
                final isSelected = index == selectedIndex;
                return SizedBox(
                  width: tabWidth,
                  child: TextButton(
                    onPressed: () => tabsRead.selectTab(index),
                    style: TextButton.styleFrom(
                      backgroundColor:
                          isSelected ? Colors.blueGrey : Colors.white,
                      foregroundColor:
                          isSelected ? Colors.white : Colors.blueGrey,
                      padding: const EdgeInsets.only(left: 8, right: 2),
                      shape: RoundedRectangleBorder(
                        side:
                            const BorderSide(color: Colors.blueGrey, width: 2),
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
                          onTap: () => tabsRead.removeTab(tab),
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
              } else {
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
                      tabsRead
                        ..addTab(newTab)
                        ..selectTab(index);
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.blueGrey,
                      shape: RoundedRectangleBorder(
                        side:
                            const BorderSide(color: Colors.blueGrey, width: 2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Icon(Icons.create_new_folder, size: 20),
                  ),
                );
              }
            },
            separatorBuilder: (_, __) => const SizedBox(width: 8),
          );
        },
      ),
    );
  }
}
