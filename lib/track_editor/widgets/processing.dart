// track_editor/widgets/processing.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';
import '../providers/te_tabs_provider.dart';
import '../services/file_manager.dart';
import '../services/point_in_polygon.dart';

class TEProcessing extends StatelessWidget {
  const TEProcessing({super.key});

  @override
  Widget build(BuildContext context) {
    final currentTab = context.watch<TETabsProvider>().currentTab;
    final tabData = context.watch<TETabsProvider>().tabs[currentTab];
    final List<TETargetPolygon> polygons = tabData.targetPolygons;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      width: 400,
      padding: const EdgeInsets.all(12),
      child: Column(
        spacing: 10,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Processing',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          Row(
            spacing: 8,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _StatBadge(
                  label: 'Polygons', value: tabData.polygons.length.toString()),
              _StatBadge(
                  label: 'Waypoints',
                  value: tabData.waypoints.length.toString()),
            ],
          ),
          ...polygons.map(
            (polygon) => Row(
              spacing: 6,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(polygon.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                        Text(polygon.waypoints.length.toString(),
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    if (polygon.waypoints.isNotEmpty) {
                      TEFileManager().saveGpxWaypointsFile(
                        '${polygon.name}_${polygon.waypoints.length}.gpx',
                        polygon.waypoints,
                      );
                    }
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: polygon.waypoints.isEmpty
                          ? Colors.blueGrey.shade50
                          : Colors.blueGrey,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      Icons.download,
                      color: polygon.waypoints.isEmpty
                          ? Colors.blueGrey
                          : Colors.blueGrey.shade50,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              final targetPolygons = groupWaypointsByPolygon(
                  tabData.polygons, tabData.waypoints);
              context.read<TETabsProvider>().addData(TETabItem(
                    title: tabData.title,
                    polygons: [],
                    tracks: [],
                    waypoints: [],
                    targetPolygons: targetPolygons,
                  ));
            },
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade600,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                spacing: 8,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cut, color: Colors.white, size: 18),
                  Text('Trim Waypoints and Tracks',
                      style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatBadge extends StatelessWidget {
  final String label;
  final String value;

  const _StatBadge({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade50,
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.all(10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(fontWeight: FontWeight.w500)),
            Text(value,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
