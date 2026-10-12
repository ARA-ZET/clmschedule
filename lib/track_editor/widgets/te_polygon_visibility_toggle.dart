// track_editor/widgets/te_polygon_visibility_toggle.dart
//
// The Visible / Hidden chip that shows or hides a tab's work-area polygons on
// the map. Shared by the Target Areas section and the Delivery vs Letterboxes
// panel, which lists the same polygons in Processing mode.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../providers/te_map_layer_provider.dart';

class TEPolygonVisibilityToggle extends riverpod.ConsumerWidget {
  final int tabIndex;
  const TEPolygonVisibilityToggle({super.key, required this.tabIndex});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final visible = ref.watch(teMapLayerRiverpod).polygonsVisible(tabIndex);
    return Tooltip(
      message: visible ? 'Hide polygons on map' : 'Show polygons on map',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => ref.read(teMapLayerRiverpod).togglePolygons(tabIndex),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: visible ? Colors.deepPurple.shade50 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color:
                  visible ? Colors.deepPurple.shade200 : Colors.grey.shade300,
            ),
          ),
          child: Row(
            spacing: 4,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                visible ? Icons.visibility : Icons.visibility_off,
                size: 14,
                color: visible ? Colors.deepPurple.shade600 : Colors.grey,
              ),
              Text(
                visible ? 'Visible' : 'Hidden',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: visible ? Colors.deepPurple.shade600 : Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
