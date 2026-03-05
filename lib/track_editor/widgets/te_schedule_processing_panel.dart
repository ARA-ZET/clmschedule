// track_editor/widgets/te_schedule_processing_panel.dart
//
// Processing mode panel: reads schedule polygon data and matches it against
// imported KML/GPX files. Full schedule integration will be added in the
// next step — this is the scaffold.
import 'package:flutter/material.dart';

class TEScheduleProcessingPanel extends StatelessWidget {
  const TEScheduleProcessingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      width: 400,
      padding: const EdgeInsets.all(16),
      child: Column(
        spacing: 12,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            spacing: 8,
            children: [
              Icon(Icons.settings_suggest, color: Colors.blueGrey),
              Text(
                'Schedule Processing',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const Divider(height: 1),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blueGrey.shade100),
            ),
            child: const Column(
              spacing: 6,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  spacing: 8,
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.blueGrey),
                    Text(
                      'Coming next',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.blueGrey,
                      ),
                    ),
                  ],
                ),
                Text(
                  'This panel will read polygon work areas from the schedule, '
                  'match them against your imported KML/GPX files, and assign '
                  'waypoints to the correct distributor routes.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          // ── Placeholder action buttons (will be wired in next step) ──
          _ActionButton(
            icon: Icons.download_for_offline_outlined,
            label: 'Load polygons from schedule',
            enabled: false,
            onTap: () {},
          ),
          _ActionButton(
            icon: Icons.compare_arrows,
            label: 'Match imported files to polygons',
            enabled: false,
            onTap: () {},
          ),
          _ActionButton(
            icon: Icons.save_alt,
            label: 'Export matched routes as GPX',
            enabled: false,
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: enabled ? Colors.blueGrey.shade600 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: enabled ? Colors.transparent : Colors.grey.shade300,
          ),
        ),
        child: Row(
          spacing: 10,
          children: [
            Icon(
              icon,
              size: 18,
              color: enabled ? Colors.white : Colors.grey.shade400,
            ),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: enabled ? Colors.white : Colors.grey.shade400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
