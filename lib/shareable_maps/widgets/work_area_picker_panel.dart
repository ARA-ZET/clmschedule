import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../../models/work_area.dart';
import '../../providers/schedule_provider.dart';
import '../providers/shareable_map_provider.dart';

/// A floating panel that lists all work areas from Firestore and lets
/// the user toggle them on/off.  Selected work areas are added as
/// polygons to a dedicated "Work Areas" layer on the map.
class WorkAreaPickerPanel extends riverpod.ConsumerStatefulWidget {
  /// Called when the user taps the close button.
  final VoidCallback onClose;

  const WorkAreaPickerPanel({super.key, required this.onClose});

  @override
  riverpod.ConsumerState<WorkAreaPickerPanel> createState() =>
      _WorkAreaPickerPanelState();
}

class _WorkAreaPickerPanelState
    extends riverpod.ConsumerState<WorkAreaPickerPanel> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final scheduleProvider = ref.watch(scheduleRiverpod);
    final mapProvider = ref.watch(shareableMapRiverpod);
    final workAreas = scheduleProvider.workAreas;

    // Filter by search query
    final filtered = _searchQuery.isEmpty
        ? workAreas
        : workAreas.where((wa) {
            final q = _searchQuery.toLowerCase();
            return wa.name.toLowerCase().contains(q) ||
                wa.description.toLowerCase().contains(q);
          }).toList();

    // Count how many are currently imported
    final importedCount =
        workAreas.where((wa) => mapProvider.isWorkAreaImported(wa.name)).length;

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white,
      child: SizedBox(
        width: 300,
        height: 420,
        child: Column(
          children: [
            // ── Header ──
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.map_outlined,
                      size: 20, color: Color(0xFF1967D2)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Work Areas',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF202124),
                      ),
                    ),
                  ),
                  if (importedCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1967D2).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$importedCount',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1967D2),
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 18, color: Color(0xFF5F6368)),
                    onPressed: widget.onClose,
                    splashRadius: 18,
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),

            // ── Search bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: TextField(
                style: const TextStyle(fontSize: 13, color: Color(0xFF202124)),
                decoration: InputDecoration(
                  hintText: 'Search work areas...',
                  hintStyle:
                      const TextStyle(fontSize: 13, color: Color(0xFF9AA0A6)),
                  prefixIcon: const Icon(Icons.search,
                      size: 18, color: Color(0xFF9AA0A6)),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  filled: true,
                  fillColor: const Color(0xFFF1F3F4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
              ),
            ),

            // ── Select All / Deselect All ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _ActionChip(
                    label: 'Select All',
                    icon: Icons.select_all,
                    onTap: () {
                      for (final wa in filtered) {
                        if (!mapProvider.isWorkAreaImported(wa.name)) {
                          mapProvider.addWorkAreaToMap(wa);
                        }
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  _ActionChip(
                    label: 'Deselect All',
                    icon: Icons.deselect,
                    onTap: () {
                      for (final wa in filtered) {
                        if (mapProvider.isWorkAreaImported(wa.name)) {
                          mapProvider.removeWorkAreaFromMap(wa.name);
                        }
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),

            const Divider(height: 1),

            // ── Work area list ──
            Expanded(
              child: workAreas.isEmpty
                  ? const Center(
                      child: Text(
                        'No work areas found',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF9AA0A6)),
                      ),
                    )
                  : filtered.isEmpty
                      ? Center(
                          child: Text(
                            'No results for "$_searchQuery"',
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF9AA0A6)),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final wa = filtered[index];
                            return _WorkAreaTile(workArea: wa);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Individual work area tile ─────────────────────────────────────────

class _WorkAreaTile extends riverpod.ConsumerWidget {
  final WorkArea workArea;
  const _WorkAreaTile({required this.workArea});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final mapProvider = ref.watch(shareableMapRiverpod);
    final isImported = mapProvider.isWorkAreaImported(workArea.name);

    return InkWell(
      onTap: () {
        if (isImported) {
          mapProvider.removeWorkAreaFromMap(workArea.name);
        } else {
          mapProvider.addWorkAreaToMap(workArea);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Checkbox-style indicator
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color:
                    isImported ? const Color(0xFF1967D2) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isImported
                      ? const Color(0xFF1967D2)
                      : const Color(0xFFDADCE0),
                  width: 1.5,
                ),
              ),
              child: isImported
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 10),

            // Color swatch
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.3),
                border: Border.all(color: Colors.orange, width: 1.5),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),

            // Name + point count
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    workArea.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isImported ? FontWeight.w600 : FontWeight.w400,
                      color: const Color(0xFF202124),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${workArea.polygonPoints.length} points',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9AA0A6),
                    ),
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

// ── Small action chip ─────────────────────────────────────────────────

class _ActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFDADCE0)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: const Color(0xFF5F6368)),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF5F6368),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
