import 'package:flutter/material.dart';
import '../models/map_layer.dart';
import '../models/map_polyline.dart';
import '../providers/shareable_map_provider.dart';

/// Google My Maps-style info popup shown when a polyline/track is tapped.
class PolylineInfoDialog extends StatelessWidget {
  const PolylineInfoDialog({
    super.key,
    required this.provider,
    required this.layer,
    required this.polyline,
  });

  final ShareableMapProvider provider;
  final MapLayer layer;
  final MapPolyline polyline;

  // ── Helpers ──────────────────────────────────────────────────────────────

  static String _formatDate(DateTime dt) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final day = days[dt.weekday - 1];
    final month = months[dt.month - 1];
    final hour = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$day, ${dt.day} $month ${dt.year}, $hour:$min';
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _openEditDialog(BuildContext context) {
    Navigator.pop(context); // close info dialog first
    final nameController = TextEditingController(text: polyline.name);
    final descController = TextEditingController(text: polyline.description);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Track'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                minLines: 1,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final updated = polyline.copyWith(
                name: nameController.text.trim().isEmpty
                    ? polyline.name
                    : nameController.text.trim(),
                description: descController.text.trim(),
              );
              provider.updatePolyline(layer, polyline.id, updated);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    Navigator.pop(context); // close info dialog first
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Track'),
        content: Text('Delete "${polyline.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              provider.deletePolyline(layer, polyline.id);
              Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasDescription = polyline.description.trim().isNotEmpty;
    final distance = polyline.formattedDistance;
    final pointCount = polyline.points.length;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, minWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ────────────────────────────────────────────────────
            Padding(
              padding:
                  const EdgeInsets.only(left: 16, right: 8, top: 12, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Colour swatch
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: polyline.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Title
                  Expanded(
                    child: Text(
                      polyline.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Close button
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // ── Body ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasDescription) ...[
                    Text(
                      polyline.description,
                      style:
                          const TextStyle(fontSize: 13, color: Colors.black87),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Date
                  _StatRow(
                    icon: Icons.calendar_today_outlined,
                    text: _formatDate(polyline.createdAt),
                  ),
                  const SizedBox(height: 6),

                  // Distance
                  _StatRow(
                    icon: Icons.straighten,
                    text: 'Distance: $distance',
                  ),
                  const SizedBox(height: 6),

                  // Points
                  _StatRow(
                    icon: Icons.place_outlined,
                    text: '$pointCount points',
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // ── Actions ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Distance chip (bottom-left like Google My Maps)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.swap_horiz,
                            size: 16, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text(
                          distance,
                          style:
                              const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  // Action buttons
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit',
                        onPressed: () => _openEditDialog(context),
                        iconSize: 20,
                        splashRadius: 18,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.redAccent),
                        tooltip: 'Delete',
                        onPressed: () => _confirmDelete(context),
                        iconSize: 20,
                        splashRadius: 18,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Small helper widget ───────────────────────────────────────────────────────

class _StatRow extends StatelessWidget {
  const _StatRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: Colors.grey[600]),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }
}
