// track_editor/widgets/processing.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';
import '../providers/te_tabs_provider.dart';
import '../services/file_manager.dart';
import '../services/point_in_polygon.dart';

class TEProcessing extends StatefulWidget {
  const TEProcessing({super.key});

  @override
  State<TEProcessing> createState() => _TEProcessingState();
}

class _TEProcessingState extends State<TEProcessing> {
  bool _processing = false;

  Future<void> _runTrimWaypoints(TETabItem tabData) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      final targetPolygons = await groupWaypointsByPolygonAsync(
          tabData.polygons, tabData.waypoints);
      if (mounted) {
        context.read<TETabsProvider>().addData(TETabItem(
              title: tabData.title,
              polygons: [],
              tracks: [],
              waypoints: [],
              targetPolygons: targetPolygons,
            ));
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTab = context.watch<TETabsProvider>().currentTab;
    final tabData = context.watch<TETabsProvider>().tabs[currentTab];
    final List<TETargetPolygon> polygons = tabData.targetPolygons;

    // Count waypoints inside any polygon vs outside all polygons.
    final totalWaypoints = tabData.waypoints.length;
    final insideCount =
        polygons.fold<int>(0, (sum, p) => sum + p.waypoints.length);
    final outsideCount = totalWaypoints - insideCount;
    final hasResults = polygons.isNotEmpty;

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
              _StatBadge(label: 'Waypoints', value: totalWaypoints.toString()),
            ],
          ),
          // ── Inside / Outside summary ────────────────────────────────────
          if (hasResults)
            Row(
              spacing: 8,
              children: [
                _StatBadge(
                  label: 'Inside',
                  value: insideCount.toString(),
                  color: Colors.green.shade50,
                  textColor: Colors.green.shade800,
                ),
                _StatBadge(
                  label: 'Outside',
                  value: outsideCount.toString(),
                  color: outsideCount > 0
                      ? Colors.orange.shade50
                      : Colors.green.shade50,
                  textColor: outsideCount > 0
                      ? Colors.orange.shade800
                      : Colors.green.shade800,
                ),
              ],
            ),
          if (hasResults && outsideCount > 0)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                spacing: 6,
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: Colors.orange.shade700),
                  Expanded(
                    child: Text(
                      '$outsideCount waypoint${outsideCount == 1 ? '' : 's'} '
                      'outside all polygons. Adjust polygon boundaries to include them.',
                      style: TextStyle(
                          fontSize: 11, color: Colors.orange.shade800),
                    ),
                  ),
                ],
              ),
            ),
          // ── Per-polygon breakdown ───────────────────────────────────────
          ...polygons.asMap().entries.map(
            (entry) {
              final polygon = entry.value;
              return Row(
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
              );
            },
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _processing ? null : () => _runTrimWaypoints(tabData),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _processing
                    ? Colors.blueGrey.shade400
                    : Colors.blueGrey.shade600,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                spacing: 8,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_processing)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  else
                    const Icon(Icons.cut, color: Colors.white, size: 18),
                  Text(
                    _processing ? 'Processing...' : 'Trim Waypoints and Tracks',
                    style: const TextStyle(color: Colors.white),
                  ),
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
  final Color? color;
  final Color? textColor;

  const _StatBadge({
    required this.label,
    required this.value,
    this.color,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: color ?? Colors.blueGrey.shade50,
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.all(10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style:
                    TextStyle(fontWeight: FontWeight.w500, color: textColor)),
            Text(value,
                style:
                    TextStyle(fontWeight: FontWeight.w500, color: textColor)),
          ],
        ),
      ),
    );
  }
}
