import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../providers/shareable_map_provider.dart';
import 'map_address_search_bar.dart';

/// Toolbar widget for map drawing tools — capability-driven.
/// Hides tools that are not available for the active adapter.
class MapDrawingToolbar extends riverpod.ConsumerStatefulWidget {
  const MapDrawingToolbar({super.key});

  @override
  riverpod.ConsumerState<MapDrawingToolbar> createState() =>
      _MapDrawingToolbarState();
}

class _MapDrawingToolbarState
    extends riverpod.ConsumerState<MapDrawingToolbar> {
  bool _showSearch = false;

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    final caps = provider.capabilities;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Search panel (expands to the left of the toolbar)
        if (_showSearch)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: MapAddressSearchBar(
              alwaysExpanded: true,
              onClose: () => setState(() => _showSearch = false),
            ),
          ),
        // Toolbar buttons
        Card(
          elevation: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search button — available for all adapters
              _SearchToolButton(
                isActive: _showSearch,
                onTap: () => setState(() => _showSearch = !_showSearch),
              ),
              const Divider(height: 1),
              DrawingToolButton(
                icon: Icons.pan_tool,
                label: 'Select',
                mode: DrawingMode.none,
                tooltip: 'Select and move',
              ),
              if (caps.canDrawPolygons ||
                  caps.canDrawPolylines ||
                  caps.canDrawPoints)
                const Divider(height: 1),
              if (caps.canDrawPolygons)
                DrawingToolButton(
                  icon: Icons.pentagon_outlined,
                  label: 'Polygon',
                  mode: DrawingMode.polygon,
                  tooltip: 'Draw polygon',
                ),
              if (caps.canDrawPolylines)
                DrawingToolButton(
                  icon: Icons.timeline,
                  label: 'Polyline',
                  mode: DrawingMode.polyline,
                  tooltip: 'Draw polyline',
                ),
              if (caps.canDrawPoints)
                DrawingToolButton(
                  icon: Icons.place,
                  label: 'Point',
                  mode: DrawingMode.point,
                  tooltip: 'Add point',
                ),
              if (caps.canDrawPolygons) ...[
                const Divider(height: 1),
                _SnapToolButton(
                  isActive: provider.snapToNeighbours,
                  onTap: () =>
                      provider.setSnapToNeighbours(!provider.snapToNeighbours),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Snap toggle — makes a click land on a neighbour's corner or edge instead
/// of near it, so adjacent polygons hold the same coordinates and no sliver
/// can open up between them. On by default; switch it off to place a vertex
/// freely right next to an existing boundary.
class _SnapToolButton extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _SnapToolButton({required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = isActive ? Colors.blue : Colors.grey.shade700;
    return Tooltip(
      message: isActive
          ? 'Snapping on — new points share the neighbour\'s corners'
          : 'Snapping off — points land exactly where you click',
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          color: isActive ? Colors.blue.shade100 : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isActive ? Icons.hub : Icons.hub_outlined,
                  color: color, size: 28),
              const SizedBox(height: 4),
              Text(
                'Snap',
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Search toggle button for the toolbar
class _SearchToolButton extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _SearchToolButton({required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = isActive ? Colors.blue : Colors.grey.shade700;
    return Tooltip(
      message: 'Search address',
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          color: isActive ? Colors.blue.shade100 : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, color: color, size: 28),
              const SizedBox(height: 4),
              Text(
                'Search',
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Extracted Widget Components
// ============================================================================

/// Individual tool button widget
class DrawingToolButton extends riverpod.ConsumerWidget {
  final IconData icon;
  final String label;
  final DrawingMode mode;
  final String tooltip;

  const DrawingToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.mode,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(shareableMapRiverpod);
    final isActive = provider.drawingMode == mode;
    final isLocked = provider.isDrawing || provider.isEditingVertices;
    final effectiveColor = isLocked
        ? Colors.grey.shade400
        : isActive
            ? Colors.blue
            : Colors.grey.shade700;

    return Tooltip(
      message: isLocked ? '' : tooltip,
      child: InkWell(
        onTap: isLocked ? null : () => provider.setDrawingMode(mode),
        child: Container(
          padding: const EdgeInsets.all(12),
          color: isActive && !isLocked ? Colors.blue.shade100 : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: effectiveColor, size: 28),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: effectiveColor,
                  fontWeight: isActive && !isLocked
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Actions panel shown during vertex editing
// class VertexEditingActionsPanel extends StatelessWidget {
//   const VertexEditingActionsPanel({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return Consumer<ShareableMapProvider>(
//       builder: (context, provider, child) {
//         return Container(
//           padding: const EdgeInsets.all(12),
//           child: Column(
//             children: [
//               Row(
//                 mainAxisAlignment: MainAxisAlignment.center,
//                 children: [
//                   Icon(
//                     Icons.edit,
//                     size: 16,
//                     color: Colors.blue.shade700,
//                   ),
//                   const SizedBox(width: 4),
//                   Text(
//                     'Editing Vertices',
//                     style: TextStyle(
//                       fontSize: 12,
//                       color: Colors.blue.shade700,
//                       fontWeight: FontWeight.bold,
//                     ),
//                   ),
//                 ],
//               ),
//               const SizedBox(height: 4),
//               Text(
//                 '${provider.editingPoints?.length ?? 0} vertices',
//                 style: const TextStyle(fontSize: 11, color: Colors.grey),
//               ),
//               if (provider.hasUnsavedChanges)
//                 const Padding(
//                   padding: EdgeInsets.only(top: 4),
//                   child: Text(
//                     'Unsaved changes',
//                     style: TextStyle(
//                       fontSize: 10,
//                       color: Colors.orange,
//                       fontStyle: FontStyle.italic,
//                     ),
//                   ),
//                 ),
//               const SizedBox(height: 8),
//               SizedBox(
//                 width: double.infinity,
//                 child: ElevatedButton.icon(
//                   onPressed: provider.hasUnsavedChanges
//                       ? () => provider.saveVertexEditing()
//                       : null,
//                   icon: const Icon(Icons.check, size: 16),
//                   label: const Text('Save', style: TextStyle(fontSize: 12)),
//                   style: ElevatedButton.styleFrom(
//                     padding: const EdgeInsets.symmetric(vertical: 8),
//                   ),
//                 ),
//               ),
//               const SizedBox(height: 4),
//               SizedBox(
//                 width: double.infinity,
//                 child: OutlinedButton.icon(
//                   onPressed: () => _confirmCancelEditing(context, provider),
//                   icon: const Icon(Icons.close, size: 16),
//                   label: const Text('Cancel', style: TextStyle(fontSize: 12)),
//                   style: OutlinedButton.styleFrom(
//                     padding: const EdgeInsets.symmetric(vertical: 8),
//                   ),
//                 ),
//               ),
//             ],
//           ),
//         );
//       },
//     );
//   }

//   void _confirmCancelEditing(
//       BuildContext context, ShareableMapProvider provider) {
//     if (!provider.hasUnsavedChanges) {
//       provider.cancelVertexEditing();
//       return;
//     }

//     showDialog(
//       context: context,
//       barrierDismissible: false, // Prevent dismissing by clicking outside
//       builder: (dialogContext) => AlertDialog(
//         title: const Text('Discard Changes?'),
//         content: const Text(
//             'You have unsaved vertex changes. Are you sure you want to discard them?'),
//         actions: [
//           TextButton(
//             onPressed: () => Navigator.pop(dialogContext),
//             child: const Text('Continue Editing'),
//           ),
//           ElevatedButton(
//             onPressed: () {
//               provider.cancelVertexEditing();
//               Navigator.pop(dialogContext);
//             },
//             style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
//             child: const Text('Discard'),
//           ),
//         ],
//       ),
//     );
//   }
// }
